#!/usr/bin/env python3
"""Numerical adversarial cases for the behavioral KV quantizer."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

import numpy as np

from kv_common import HEAD_DIM, quantize_symmetric, relative_rmse, softmax


def case_row(name: str, values: np.ndarray, bits: int = 4,
             scale_format: str = "Q8.8") -> dict[str, Any]:
    crashed = False
    message = ""
    saturated = 0
    dequant = np.empty_like(values)
    try:
        quantized = quantize_symmetric(values, bits, scale_format,
                                       tensor_name=name)
        dequant = quantized.dequant
        saturated = quantized.saturated_scale_count
    except Exception as exc:  # Recorded as evidence, then the suite continues.
        crashed = True
        message = f"{type(exc).__name__}: {exc}"
    return {
        "evidence": "SOFTWARE-FIXED-POINT",
        "case": name,
        "bits": bits,
        "scale_format": scale_format,
        "crash": crashed,
        "exception": message,
        "input_has_nan": bool(np.isnan(values).any()),
        "output_has_nan": bool(np.isnan(dequant).any()) if not crashed else None,
        "scale_saturation_count": saturated,
        "input_absmax": float(np.max(np.abs(values))),
        "output_absmax": float(np.max(np.abs(dequant))) if not crashed else None,
        "relative_rmse": relative_rmse(dequant, values) if not crashed else None,
        "normalized_bias": (float(np.mean(dequant.astype(np.float64) - values)) /
                            max(float(np.sqrt(np.mean(values.astype(np.float64) ** 2))),
                                1.0e-30)) if not crashed else None,
    }


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation")
    args = parser.parse_args()
    output = args.output / "adversarial"
    output.mkdir(parents=True, exist_ok=True)
    epsilon = np.float32(1.0e-6)
    threshold = np.zeros((1, HEAD_DIM), dtype=np.float32)
    threshold[0, :8] = np.asarray([
        7.0, -7.0, 0.5 - epsilon, 0.5, 0.5 + epsilon,
        -0.5 + epsilon, -0.5, -0.5 - epsilon], dtype=np.float32)
    isolated = np.ones((1, HEAD_DIM), dtype=np.float32)
    isolated[0, 17] = 1000.0
    maximum_q88_representable = (32767.0 / 256.0) * 7.0
    cases = {
        "all_zero_vector": np.zeros((1, HEAD_DIM), dtype=np.float32),
        "constant_vector": np.full((1, HEAD_DIM), 3.25, dtype=np.float32),
        "threshold_plus_minus_epsilon": threshold,
        "maximum_input_at_q8_8_scale_limit": np.linspace(
            -maximum_q88_representable, maximum_q88_representable,
            HEAD_DIM, dtype=np.float32)[None, :],
        "q8_8_scale_saturation": np.linspace(
            -1.0e6, 1.0e6, HEAD_DIM, dtype=np.float32)[None, :],
        "large_isolated_outlier": isolated,
    }
    rows = [case_row(name, values) for name, values in cases.items()]

    # Attention probability edge cases use stable softmax directly.
    attention_rows: list[dict[str, Any]] = []
    for name, logits in {
        "equal_attention_logits": np.zeros(4096, dtype=np.float32),
        "extremely_sharp_attention": np.concatenate((
            np.asarray([1000.0], dtype=np.float32),
            np.full(4095, -1000.0, dtype=np.float32))),
        "extremely_diffuse_attention": np.linspace(
            -1.0e-6, 1.0e-6, 4096, dtype=np.float32),
    }.items():
        probability = softmax(logits)
        attention_rows.append({
            "evidence": "SOFTWARE-SYNTHETIC",
            "case": name,
            "crash": False,
            "nan": bool(np.isnan(probability).any()),
            "probability_sum": float(np.sum(probability, dtype=np.float64)),
            "min_probability": float(np.min(probability)),
            "max_probability": float(np.max(probability)),
            "nonzero_probabilities": int(np.count_nonzero(probability)),
        })

    q_max = np.full(HEAD_DIM, 127, dtype=np.int64)
    k_max = np.full(HEAD_DIM, 7, dtype=np.int64)
    exact_accumulator = int(np.dot(q_max, k_max))
    int32_accumulator = int(np.dot(q_max.astype(np.int32),
                                   k_max.astype(np.int32)))
    accumulator = {
        "evidence": "THEORETICAL + SOFTWARE-SYNTHETIC",
        "case": "qk_accumulator_bound",
        "head_dim": HEAD_DIM,
        "q_absmax": 127,
        "k_code_absmax": 7,
        "exact_bound": HEAD_DIM * 127 * 7,
        "software_int64_result": exact_accumulator,
        "software_int32_result": int32_accumulator,
        "silent_wrap": int32_accumulator != exact_accumulator,
        "minimum_signed_accumulator_bits_including_sign":
            int(np.ceil(np.log2(exact_accumulator + 1))) + 1,
    }

    with (output / "quantizer_adversarial.csv").open(
            "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    with (output / "attention_adversarial.csv").open(
            "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(attention_rows[0]))
        writer.writeheader()
        writer.writerows(attention_rows)
    report = {
        "evidence": "SOFTWARE-FIXED-POINT unless row says otherwise",
        "quantizer_definition": ("symmetric narrow-range INT4, ideal-scale code "
                                 "selection, Q8.8 stored dequantization scale"),
        "quantizer_cases": rows,
        "attention_cases": attention_rows,
        "accumulator": accumulator,
        "summary": {
            "crashes": sum(row["crash"] for row in rows),
            "nan_cases": sum(bool(row["output_has_nan"]) for row in rows),
            "scale_saturation_cases": sum(
                row["scale_saturation_count"] > 0 for row in rows),
            "silent_wrap_cases": int(accumulator["silent_wrap"]),
        },
    }
    (output / "adversarial_summary.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
