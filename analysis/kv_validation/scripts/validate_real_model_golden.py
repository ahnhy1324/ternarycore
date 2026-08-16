#!/usr/bin/env python3
"""Independent consistency checks for the v0.2 real-model RTL golden vector."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path

import numpy as np


def unpack_int4(payload: bytes) -> np.ndarray:
    packed = np.frombuffer(payload, dtype=np.uint8)
    nibble = np.empty(packed.size * 2, dtype=np.uint8)
    nibble[0::2] = packed & 15
    nibble[1::2] = packed >> 4
    assert not np.any(nibble == 8)
    return np.where(nibble < 8, nibble, nibble.astype(np.int16) - 16).astype(np.int8)


def round_shift_signed(values: np.ndarray, shift: int) -> np.ndarray:
    values = values.astype(np.int64)
    rounded = (np.abs(values) + (1 << (shift - 1))) >> shift
    return np.where(values < 0, -rounded, rounded).astype(np.int64)


def read_lut(path: Path) -> np.ndarray:
    with path.open(newline="", encoding="utf-8") as handle:
        return np.asarray([int(row["exp_q1_15"]) for row in csv.DictReader(handle)],
                          dtype=np.int64)


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" / "golden_v0_2")
    parser.add_argument(
        "--prep-root", type=Path,
        default=repo / "analysis" / "kv_validation" / "prep" / "kv_rtl_prep")
    args = parser.parse_args()
    manifest = json.loads((args.root / "manifest.json").read_text("utf-8"))
    dim = int(manifest["head_dim"])
    length = int(manifest["context_length"])
    group_size = int(manifest["group_size"])
    groups = dim // group_size

    for section in ("files", "testbench_hex_files"):
        for item in manifest[section].values():
            path = args.root / item["path"]
            assert path.stat().st_size == item["bytes"]
            assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"]

    q = np.fromfile(args.root / manifest["files"]["q"]["path"], dtype=np.int8)
    q_scale = np.fromfile(args.root / manifest["files"]["q_scale"]["path"], dtype="<u2")
    k = unpack_int4((args.root / manifest["files"]["k"]["path"]).read_bytes()).reshape(
        length, groups, group_size)
    v = unpack_int4((args.root / manifest["files"]["v"]["path"]).read_bytes()).reshape(
        length, groups, group_size)
    k_scale = np.fromfile(args.root / manifest["files"]["k_scale"]["path"],
                          dtype="<u2").reshape(length, groups)
    v_scale = np.fromfile(args.root / manifest["files"]["v_scale"]["path"],
                          dtype="<u2").reshape(length, groups)
    assert q.shape == (dim,) and q_scale.shape == (1,)
    assert k.shape == v.shape == (length, groups, group_size)
    assert k_scale.shape == v_scale.shape == (length, groups)

    q_group = q.astype(np.int32).reshape(groups, group_size)
    actual_group = np.sum(k.astype(np.int32) * q_group[None], axis=-1, dtype=np.int32)
    expected_group = np.fromfile(
        args.root / manifest["files"]["qk_group"]["path"], dtype="<i4").reshape(
            length, groups)
    assert np.array_equal(actual_group, expected_group)
    actual_raw = np.sum(actual_group, axis=-1, dtype=np.int32)
    expected_raw = np.fromfile(
        args.root / manifest["files"]["qk_raw"]["path"], dtype="<i4")
    assert np.array_equal(actual_raw, expected_raw)

    actual_scaled = np.sum(actual_group.astype(np.int64) * k_scale.astype(np.int64),
                           axis=-1)
    expected_scaled = np.fromfile(
        args.root / manifest["files"]["k_scaled_accum"]["path"], dtype="<i8")
    assert np.array_equal(actual_scaled, expected_scaled)
    inv_sqrt = int(manifest["inv_sqrt_head_dim"]["code"])
    numerator = actual_scaled * int(q_scale[0]) * inv_sqrt
    expected_numerator = np.fromfile(
        args.root / manifest["files"]["logit_numerator"]["path"], dtype="<i8")
    assert np.array_equal(numerator, expected_numerator)

    delta = np.clip(round_shift_signed(numerator - np.max(numerator), 28), -16384, 0)
    expected_delta = np.fromfile(
        args.root / manifest["files"]["softmax_delta"]["path"], dtype="<i4")
    assert np.array_equal(delta, expected_delta)
    lut = read_lut(args.prep_root / "softmax" / "exp_lut_candidate.csv")
    position = delta + 16384
    index = position >> 6
    remainder = position & 63
    exp_code = np.empty(length, dtype=np.int64)
    final = index == 256
    exp_code[final] = lut[256]
    normal = ~final
    exp_code[normal] = (
        lut[index[normal]] * (64 - remainder[normal]) +
        lut[index[normal] + 1] * remainder[normal] + 32) >> 6
    expected_exp = np.fromfile(
        args.root / manifest["files"]["exp"]["path"], dtype="<u2")
    assert np.array_equal(exp_code.astype(np.uint16), expected_exp)
    total = int(np.sum(exp_code))
    probability = np.clip((exp_code * 32768 + total // 2) // total, 0, 32768)
    expected_probability = np.fromfile(
        args.root / manifest["files"]["probability"]["path"], dtype="<u2")
    assert np.array_equal(probability.astype(np.uint16), expected_probability)

    av = np.sum(probability[:, None, None].astype(np.int64) * v.astype(np.int64) *
                v_scale.astype(np.int64)[..., None], axis=0).reshape(dim)
    expected_av = np.fromfile(
        args.root / manifest["files"]["av_accum"]["path"], dtype="<i8")
    assert np.array_equal(av, expected_av)
    output = np.fromfile(
        args.root / manifest["files"]["attention_output"]["path"], dtype="<f4")
    assert np.array_equal((av.astype(np.float32) / (1 << 23)), output)
    print("real-model RTL golden validation PASS")


if __name__ == "__main__":
    main()
