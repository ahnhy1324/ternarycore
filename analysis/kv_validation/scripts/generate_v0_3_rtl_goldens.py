#!/usr/bin/env python3
"""Generate bit-exact reciprocal and softmax vectors for v0.3 RTL."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np

from run_v0_3_fixedpoint_sweep import scores_for
from v0_3_fixedpoint_reference import fixed_softmax, normalized_reciprocal


def write_hex(path: Path, values: np.ndarray, width: int) -> None:
    mask = (1 << (4 * width)) - 1
    path.write_text("".join(
        f"{int(value) & mask:0{width}x}\n" for value in values.reshape(-1)),
        encoding="ascii")


def write_softmax_case(root: Path, name: str, scores: np.ndarray) -> dict:
    case_root = root / name
    case_root.mkdir(parents=True, exist_ok=True)
    fixed = fixed_softmax(scores, reciprocal_fraction=12)
    write_hex(case_root / "scores_s16.hex",
              fixed.score_codes.astype(np.uint16), 4)
    write_hex(case_root / "exp_u16.hex", fixed.exp_codes, 4)
    maximum = int(np.max(fixed.score_codes)) & 0xFFFF
    packed_meta = (
        (maximum << 59) |
        (fixed.underflow_count << 46) |
        (fixed.reciprocal_exponent << 41) |
        (fixed.reciprocal_code << 28) |
        fixed.denominator
    )
    (case_root / "expected_meta_u75.hex").write_text(
        f"{packed_meta:019x}\n", encoding="ascii")
    return {
        "name": name,
        "length": int(fixed.score_codes.size),
        "maximum_score_code": int(np.max(fixed.score_codes)),
        "underflow_count": fixed.underflow_count,
        "denominator": fixed.denominator,
        "reciprocal_code_f12": fixed.reciprocal_code,
        "reciprocal_exponent": fixed.reciprocal_exponent,
    }


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "rtl_goldens" / "softmax")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    denominators = {1, 2, 3, 32767, 32768, 36970, 144648, 1 << 27}
    csv_path = (repo / "analysis" / "kv_validation" / "v0_3" / "results" /
                "fixedpoint" / "softmax_adversarial.csv")
    with csv_path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            if int(row["reciprocal_fraction"]) == 12:
                denominators.add(int(row["denominator"]))
    reciprocal_rows = []
    for denominator in sorted(denominators):
        code, exponent = normalized_reciprocal(denominator, 12)
        reciprocal_rows.append(
            (denominator << 18) | (exponent << 13) | code)
    write_hex(args.output / "reciprocal_cases_u46.hex",
              np.asarray(reciprocal_rows, dtype=object), 12)

    cases = []
    cases.append(write_softmax_case(
        args.output, "uniform_4096", np.zeros(4096, dtype=np.float64)))
    cases.append(write_softmax_case(
        args.output, "single_sink_65",
        scores_for("single_sink", 65, 20260816 + 65 * 17 + 4)))
    cases.append(write_softmax_case(
        args.output, "lut_boundary_129",
        scores_for("lut_boundary", 129, 20260816 + 129 * 17 + 7)))

    gate_root = (repo / "analysis" / "kv_validation" / "v0_3" / "results" /
                 "gate_a")
    candidates = sorted(gate_root.glob(
        "context_0128/*/PACKED5_PAGE128_UQ4_8/fixedpoint_inputs/"
        "layer_00_last_query_scores.npz"))
    if not candidates:
        raise FileNotFoundError("no completed context-128 Gate A score capture")
    real_path = candidates[0]
    saved = np.load(real_path)
    cases.append(write_softmax_case(
        args.output, "real_engineering_c128_l00_h0",
        saved["scores"][0].astype(np.float64)))

    manifest = {
        "schema": "kv-v0.3-softmax-rtl-goldens-v1",
        "evidence": "SOFTWARE-BIT-EXACT/v0.3-softmax-rtl-goldens",
        "reciprocal_fraction": 12,
        "reciprocal_case_count": len(reciprocal_rows),
        "cases": cases,
        "real_case_source": str(real_path.relative_to(repo)).replace("\\", "/"),
        "claim_scope": "RTL bit-exact vectors; not model-accuracy evidence",
    }
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
