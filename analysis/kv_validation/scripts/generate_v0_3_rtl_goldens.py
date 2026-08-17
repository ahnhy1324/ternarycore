#!/usr/bin/env python3
"""Generate bit-exact reciprocal and softmax vectors for v0.3 RTL."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
import torch

from run_v0_3_fixedpoint_sweep import scores_for
from v0_3_fixedpoint_reference import (
    fixed_softmax,
    normalized_reciprocal,
    quantize_symmetric,
)


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


def write_av_case(root: Path, name: str, v_codes: np.ndarray,
                  v_scale_codes: np.ndarray,
                  exp_codes: np.ndarray) -> dict:
    case_root = root / name
    case_root.mkdir(parents=True, exist_ok=True)
    codes = np.asarray(v_codes, dtype=np.int8)
    scales = np.asarray(v_scale_codes, dtype=np.uint16).reshape(-1)
    exponents = np.asarray(exp_codes, dtype=np.uint16)
    if codes.ndim != 2 or codes.shape[1] != 128:
        raise ValueError("AV V codes must be [tokens,128]")
    if exponents.shape != (4, codes.shape[0]):
        raise ValueError("AV exponents must be [4,tokens]")
    if scales.shape != (codes.shape[0],):
        raise ValueError("AV scales must be one per token")
    weights = exponents.astype(np.int64) * scales[np.newaxis, :]
    numerators = weights @ codes.astype(np.int64)
    if np.max(np.abs(numerators)) >= (1 << 47):
        raise OverflowError("AV golden exceeds signed 48-bit contract")
    write_hex(case_root / "v_codes_s5.hex", codes, 2)
    write_hex(case_root / "v_scales_u12.hex", scales, 3)
    write_hex(case_root / "exp_h4_u16.hex", exponents.T, 4)
    write_hex(case_root / "expected_numerators_s48.hex", numerators, 12)
    maximum_abs = int(np.max(np.abs(numerators)))
    return {
        "name": name,
        "context_len": int(codes.shape[0]),
        "maximum_abs_numerator": maximum_abs,
        "observed_signed_numerator_bits": maximum_abs.bit_length() + 1,
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

    av_root = args.output.parent / "av"
    av_root.mkdir(parents=True, exist_ok=True)
    capture_path = (repo / "analysis" / "kv_validation" / "real_model" /
                    "runs" / "20260816-streaming-full-c128" / "tensors" /
                    "layer_00.pt")
    saved_capture = torch.load(
        capture_path, map_location="cpu", weights_only=True)["tensors"]
    q = quantize_symmetric(
        saved_capture["q_post_rope"].float().numpy(), 8,
        scale_fraction=15, scale_width=16)
    k = quantize_symmetric(
        saved_capture["k_post_rope"].float().numpy(), 4,
        scale_fraction=8, scale_width=12)
    v = quantize_symmetric(
        saved_capture["v"].float().numpy(), 5,
        scale_fraction=8, scale_width=12)
    real_exp = []
    for head in range(4):
        scores = (k.dequant[0] @ q.dequant[head, -1] / np.sqrt(128.0))
        real_exp.append(fixed_softmax(scores).exp_codes)
    av_cases = [write_av_case(
        av_root, "real_c128_l00_kvh0",
        v.codes[0], v.scale_codes[0], np.stack(real_exp))]

    short_context = 7
    short_codes = np.fromfunction(
        lambda token, dim: ((token * 3 + dim * 5) % 31) - 15,
        (short_context, 128), dtype=int).astype(np.int8)
    short_scales = np.asarray([1, 17, 255, 256, 1023, 2048, 4095],
                              dtype=np.uint16)
    short_exp = np.asarray([
        [32768, 0, 1, 17, 1024, 8192, 16384],
        [0, 32768, 1, 31, 2048, 4096, 8192],
        [1, 2, 3, 4, 5, 6, 32768],
        [32768, 32768, 0, 0, 1, 1, 1],
    ], dtype=np.uint16)
    av_cases.append(write_av_case(
        av_root, "adversarial_c7", short_codes, short_scales, short_exp))
    av_manifest = {
        "schema": "kv-v0.3-av-rtl-goldens-v1",
        "evidence": "SOFTWARE-BIT-EXACT/v0.3-av-rtl-goldens",
        "cases": av_cases,
        "real_case_source": str(capture_path.relative_to(repo)).replace(
            "\\", "/"),
        "layout": "inputs token-major; exponents token-major/head-minor; "
                  "numerators head-major/dimension-minor",
        "claim_scope": "integer AV numerator RTL vectors; not model accuracy",
    }
    (av_root / "manifest.json").write_text(
        json.dumps(av_manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    print(json.dumps(manifest, indent=2, sort_keys=True))
    print(json.dumps(av_manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
