#!/usr/bin/env python3
"""Generate real-model QK golden vectors for K4 and K5 v0.2 cores."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch


HEAD_DIM = 128
CONTEXT = 128
Q_FRACTION = 15
K_FRACTION = 11
PROFILES = {"REGULAR4": 4, "PACKED5": 4, "ACCURATE5": 5}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def quantize(values: np.ndarray, bits: int, group_size: int,
             fraction: int) -> tuple[np.ndarray, np.ndarray]:
    qmax = (1 << (bits - 1)) - 1
    shape = values.shape
    grouped = values.reshape(*shape[:-1], shape[-1] // group_size, group_size)
    maximum = np.max(np.abs(grouped), axis=-1, keepdims=True)
    ideal = np.where(maximum == 0, 1.0, maximum / qmax).astype(np.float32)
    codes = np.where(
        maximum == 0, 0,
        np.clip(np.rint(grouped / ideal), -qmax, qmax),
    ).astype(np.int8)
    scale = np.clip(
        np.rint(ideal.astype(np.float64) * (1 << fraction)), 1, 65535,
    ).astype(np.uint16)
    return codes.reshape(shape), scale.reshape(*shape[:-1], -1)


def write_hex(path: Path, values: np.ndarray, bits: int) -> None:
    mask = (1 << bits) - 1
    digits = (bits + 3) // 4
    path.write_text("\n".join(
        f"{int(value) & mask:0{digits}x}" for value in values.reshape(-1)
    ) + "\n", "ascii")


def pack_lsb_bitstream(values: np.ndarray, bits: int) -> bytes:
    output = bytearray((values.size * bits + 7) // 8)
    bit_offset = 0
    mask = (1 << bits) - 1
    for value in values.reshape(-1):
        code = int(value) & mask
        byte_index = bit_offset >> 3
        shift = bit_offset & 7
        output[byte_index] |= (code << shift) & 0xff
        if shift + bits > 8:
            output[byte_index + 1] |= code >> (8 - shift)
        bit_offset += bits
    return bytes(output)


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--capture", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" / "runs" /
        "20260816-streaming-full-c128" / "tensors" / "layer_22.pt")
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" /
        "qk_profile_golden_v0_2")
    args = parser.parse_args()
    saved = torch.load(args.capture, map_location="cpu", weights_only=True)
    q_all = saved["tensors"]["q_post_rope"].float().numpy()
    k_all = saved["tensors"]["k_post_rope"].float().numpy()
    if int(saved["context_len"]) != CONTEXT:
        raise AssertionError("golden capture must have context 128")

    # Keep one real Q/K head pair fixed across K widths so compute variants see
    # identical Q values and source activations.
    q_head = 16
    kv_head = q_head // 4
    q_source = q_all[q_head, -1]
    k_source = k_all[kv_head]
    q_codes, q_scale = quantize(q_source, 8, HEAD_DIM, Q_FRACTION)
    args.output.mkdir(parents=True, exist_ok=True)
    write_hex(args.output / "q_int8.hex", q_codes, 8)

    profiles = {}
    for profile, k_bits in PROFILES.items():
        profile_dir = args.output / profile.lower()
        profile_dir.mkdir(parents=True, exist_ok=True)
        k_codes, k_scales = quantize(k_source, k_bits, HEAD_DIM, K_FRACTION)
        raw_dot = np.sum(
            k_codes.astype(np.int64) * q_codes.astype(np.int64)[None, :], axis=-1)
        scaled = raw_dot * k_scales[:, 0].astype(np.int64)
        write_hex(profile_dir / "k_codes.hex", k_codes, k_bits)
        write_hex(profile_dir / "k_scale_uq5_11_u16.hex", k_scales, 16)
        write_hex(profile_dir / "expected_scaled_accum_i64.hex", scaled, 64)
        payload = profile_dir / f"k_int{k_bits}_packed_lsb.bin"
        payload.write_bytes(pack_lsb_bitstream(k_codes, k_bits))
        profiles[profile] = {
            "k_bits": k_bits,
            "k_group_size": HEAD_DIM,
            "payload_bytes_per_token": HEAD_DIM * k_bits // 8,
            "metadata_bytes_per_token": 2,
            "packed_lsb_bitstream": payload.name,
            "files": {
                path.name: {"bytes": path.stat().st_size, "sha256": sha256(path)}
                for path in profile_dir.iterdir() if path.is_file()
            },
            "scale_min_code": int(k_scales.min()),
            "scale_max_code": int(k_scales.max()),
            "reserved_min_code_count": int(np.count_nonzero(
                k_codes == -(1 << (k_bits - 1)))),
        }
    manifest = {
        "schema_version": "qk-profile-golden-0.2",
        "evidence": "REAL-MODEL-VALIDATED/custom-streaming-reference",
        "claim_scope": "real captured Q/K arithmetic; not model accuracy",
        "source_capture": str(args.capture.resolve()),
        "source_capture_sha256": sha256(args.capture),
        "context_length": CONTEXT,
        "head_dim": HEAD_DIM,
        "q_head": q_head,
        "kv_head": kv_head,
        "q_format": "signed INT8 symmetric -127..127",
        "q_scale_format": "UQ1.15 (not applied inside qk_group_dot)",
        "k_scale_format": "unsigned UQ5.11",
        "code_selection_policy": "codes from high-precision absmax reciprocal; dequant uses rounded stored scale",
        "packing": "contiguous LSB-first two's-complement bitstream",
        "q_file": {
            "path": "q_int8.hex",
            "bytes": (args.output / "q_int8.hex").stat().st_size,
            "sha256": sha256(args.output / "q_int8.hex"),
        },
        "profiles": profiles,
    }
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", "utf-8")
    print(json.dumps({"status": "PASS", "profiles": profiles}, indent=2))


if __name__ == "__main__":
    main()
