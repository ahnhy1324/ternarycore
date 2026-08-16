#!/usr/bin/env python3
"""Validate the imported KV RTL preparation package and its golden vector."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path

import numpy as np


EXPECTED_ZIP_SHA256 = (
    "30c37ed63c76a47a9c4066ac9bc9232c9951c96d96fc7639cd9249dccc2aa89a"
)


def unpack_int4(payload: bytes) -> np.ndarray:
    packed = np.frombuffer(payload, dtype=np.uint8)
    nibbles = np.empty(packed.size * 2, dtype=np.uint8)
    nibbles[0::2] = packed & 0x0F
    nibbles[1::2] = packed >> 4
    if np.any(nibbles == 8):
        raise AssertionError("reserved INT4 code 0x8 appears in canonical data")
    return np.where(nibbles < 8, nibbles, nibbles.astype(np.int16) - 16).astype(
        np.int8
    )


def csv_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=repo / "analysis" / "kv_validation" / "prep" / "kv_rtl_prep",
    )
    parser.add_argument(
        "--source-zip", type=Path, default=repo.parent / "kv_rtl_prep.zip"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=repo / "analysis" / "kv_validation" / "prep_validation.json",
    )
    args = parser.parse_args()
    root = args.root.resolve()

    manifest = json.loads((root / "golden" / "manifest.json").read_text("utf-8"))
    head_dim = int(manifest["head_dim"])
    context_len = int(manifest["context_length"])
    golden = root / "golden"
    files = manifest["files"]

    q = np.fromfile(golden / files["q"], dtype=np.int8)
    k = unpack_int4((golden / files["k"]).read_bytes()).reshape(
        context_len, head_dim
    )
    v = unpack_int4((golden / files["v"]).read_bytes()).reshape(
        context_len, head_dim
    )
    k_scale = np.fromfile(golden / files["k_scale"], dtype="<u2")
    v_scale = np.fromfile(golden / files["v_scale"], dtype="<u2")
    expected_qk = np.fromfile(golden / files["expected_qk"], dtype="<i4")
    actual_qk = k.astype(np.int32) @ q.astype(np.int32)

    assert q.shape == (head_dim,)
    assert k.shape == v.shape == (context_len, head_dim)
    assert k_scale.shape == v_scale.shape == (context_len,)
    assert np.array_equal(actual_qk, expected_qk)

    signed_rows = csv_rows(root / "signed_digit" / "exhaustive.csv")
    assert len(signed_rows) == 256 * 15
    assert all(row["match"] == "True" for row in signed_rows)
    assert all(int(row["reference"]) == int(row["shift_add"]) for row in signed_rows)

    layout_rows = csv_rows(root / "layout" / "layout_comparison.csv")
    assert {int(row["axi_width_bits"]) for row in layout_rows} == {128, 256}
    assert all(float(row["split_effective_bits_per_value"]) == 4.125
               for row in layout_rows)

    lut_rows = csv_rows(root / "softmax" / "exp_lut_candidate.csv")
    x_codes = np.asarray([int(row["x_q6_10"]) for row in lut_rows])
    exp_codes = np.asarray([int(row["exp_q1_15"]) for row in lut_rows])
    assert len(lut_rows) == 257
    assert x_codes[0] == -16384 and x_codes[-1] == 0
    assert np.all(np.diff(x_codes) == 64)
    assert np.all(np.diff(exp_codes) >= 0)
    assert exp_codes[0] == 0 and exp_codes[-1] == 32768

    source_sha256 = None
    if args.source_zip.is_file():
        source_sha256 = hashlib.sha256(args.source_zip.read_bytes()).hexdigest()
        assert source_sha256 == EXPECTED_ZIP_SHA256

    result = {
        "evidence": "SOFTWARE-SYNTHETIC/imported-prep-validation",
        "status": "PASS",
        "source_zip_sha256": source_sha256,
        "transport_golden": {
            "head_dim": head_dim,
            "context_len": context_len,
            "qk_vectors_equal": True,
            "reserved_int4_codes": 0,
            "k_code_min": int(k.min()),
            "k_code_max": int(k.max()),
            "v_code_min": int(v.min()),
            "v_code_max": int(v.max()),
        },
        "signed_digit": {"cases": len(signed_rows), "mismatches": 0},
        "layout": {"axi_widths": [128, 256], "effective_bits_per_value": 4.125},
        "softmax_lut": {
            "entries": len(lut_rows),
            "monotonic": True,
            "domain_q6_10": [-16384, 0],
            "range_q1_15": [0, 32768],
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", "utf-8")
    print("RTL prep validation PASS")


if __name__ == "__main__":
    main()
