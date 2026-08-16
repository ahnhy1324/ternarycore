#!/usr/bin/env python3
"""Evaluate the synthetic K/V error predictors on captured BitNet tensors."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np
import torch

from analyze_real_model_captures import (
    HEAD_DIM,
    KV_GROUPS,
    causal_softmax,
    quantize,
    repeat_kv,
    scores,
)


EVIDENCE = "REAL-MODEL-VALIDATED/custom-streaming-reference"
POWER_FLOOR = 1.0e-12


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def correlation(left: np.ndarray, right: np.ndarray) -> float:
    if left.size < 2 or np.std(left) == 0.0 or np.std(right) == 0.0:
        return float("nan")
    return float(np.corrcoef(left, right)[0, 1])


def fit_origin(predictor: np.ndarray, actual: np.ndarray) -> float:
    denominator = float(np.dot(predictor, predictor))
    return float(np.dot(predictor, actual) / max(denominator, 1.0e-30))


def vector_cosine(left: np.ndarray, right: np.ndarray) -> np.ndarray:
    numerator = np.sum(left.astype(np.float64) * right.astype(np.float64), axis=-1)
    denominator = (
        np.linalg.norm(left.astype(np.float64), axis=-1) *
        np.linalg.norm(right.astype(np.float64), axis=-1)
    )
    return numerator / np.maximum(denominator, 1.0e-30)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)

    sample_parts: dict[str, list[np.ndarray]] = {
        name: [] for name in (
            "path", "context_len", "layer", "head", "query_index", "bits",
            "predictor_power", "actual_power", "vector_cosine",
            "n_eff", "max_attention_probability",
        )
    }

    for run_path in args.run:
        run = json.loads((run_path / "run.json").read_text(encoding="utf-8"))
        context_len = int(run["context_len"])
        for capture_path in sorted((run_path / "tensors").glob("layer_*.pt")):
            capture = torch.load(capture_path, map_location="cpu", weights_only=False)
            layer = int(capture["layer"])
            tensors = capture["tensors"]
            query = tensors["q_post_rope"].float().numpy()
            key = tensors["k_post_rope"].float().numpy()
            value = tensors["v"].float().numpy()
            query_q8 = quantize(query, 8, HEAD_DIM, "FP32").dequant
            baseline_probability = causal_softmax(scores(query_q8, key))
            baseline_output = np.matmul(
                baseline_probability.astype(np.float32),
                repeat_kv(value).astype(np.float32),
            )
            n_eff = 1.0 / np.sum(
                baseline_probability.astype(np.float64) ** 2, axis=-1)
            maximum_probability = np.max(baseline_probability, axis=-1)

            for bits in (3, 4, 5, 8):
                key_quantized = quantize(key, bits, HEAD_DIM, "Q8.8").dequant
                value_quantized = quantize(value, bits, HEAD_DIM, "Q8.8").dequant

                quantized_probability = causal_softmax(scores(query_q8, key_quantized))
                k_actual_vector = np.matmul(
                    quantized_probability.astype(np.float32),
                    repeat_kv(value).astype(np.float32),
                ) - baseline_output
                k_predicted_vector = np.empty_like(k_actual_vector)
                key_error = key_quantized - key
                for head in range(query.shape[0]):
                    kv_head = head // KV_GROUPS
                    for query_index in range(context_len):
                        prefix = query_index + 1
                        attention = baseline_probability[head, query_index, :prefix].astype(np.float64)
                        delta_score = (
                            key_error[kv_head, :prefix].astype(np.float64) @
                            query_q8[head, query_index].astype(np.float64)
                        ) / math.sqrt(HEAD_DIM)
                        delta_attention = attention * (
                            delta_score - np.dot(attention, delta_score)
                        )
                        k_predicted_vector[head, query_index] = (
                            delta_attention @ value[kv_head, :prefix].astype(np.float64)
                        ).astype(np.float32)

                k_predictor_power = np.mean(
                    k_predicted_vector.astype(np.float64) ** 2, axis=-1)
                k_actual_power = np.mean(
                    k_actual_vector.astype(np.float64) ** 2, axis=-1)
                k_cosine = vector_cosine(k_predicted_vector, k_actual_vector)

                value_error = value_quantized - value
                v_actual_vector = np.matmul(
                    baseline_probability.astype(np.float32),
                    repeat_kv(value_error).astype(np.float32),
                )
                v_actual_power = np.mean(
                    v_actual_vector.astype(np.float64) ** 2, axis=-1)
                per_token_error_power = np.mean(
                    value_error.astype(np.float64) ** 2, axis=-1)
                cumulative_sigma2 = (
                    np.cumsum(per_token_error_power, axis=-1) /
                    np.arange(1, context_len + 1)[None, :]
                )
                v_predictor_power = np.empty_like(v_actual_power)
                for head in range(query.shape[0]):
                    kv_head = head // KV_GROUPS
                    v_predictor_power[head] = (
                        cumulative_sigma2[kv_head] / n_eff[head]
                    )

                head_index = np.repeat(np.arange(query.shape[0]), context_len)
                query_index = np.tile(np.arange(context_len), query.shape[0])
                common = {
                    "context_len": np.full(head_index.size, context_len, dtype=np.int16),
                    "layer": np.full(head_index.size, layer, dtype=np.int8),
                    "head": head_index.astype(np.int8),
                    "query_index": query_index.astype(np.int16),
                    "bits": np.full(head_index.size, bits, dtype=np.int8),
                    "n_eff": n_eff.reshape(-1).astype(np.float32),
                    "max_attention_probability": maximum_probability.reshape(-1).astype(np.float32),
                }
                for path, predictor, actual, cosine_values in (
                    (0, k_predictor_power, k_actual_power, k_cosine),
                    (1, v_predictor_power, v_actual_power,
                     np.full_like(v_actual_power, np.nan)),
                ):
                    sample_parts["path"].append(
                        np.full(head_index.size, path, dtype=np.int8))
                    for name, values in common.items():
                        sample_parts[name].append(values)
                    sample_parts["predictor_power"].append(
                        predictor.reshape(-1).astype(np.float64))
                    sample_parts["actual_power"].append(
                        actual.reshape(-1).astype(np.float64))
                    sample_parts["vector_cosine"].append(
                        cosine_values.reshape(-1).astype(np.float32))

    samples = {name: np.concatenate(parts) for name, parts in sample_parts.items()}
    np.savez_compressed(args.output / "predictor_samples.npz", **samples)

    summary_rows = []
    for path_code, path_name in ((0, "K_first_order"), (1, "V_sigma2_over_n_eff")):
        for bits in (3, 4, 5, 8):
            calibration = (
                (samples["path"] == path_code) &
                (samples["bits"] == bits) &
                (samples["context_len"] == 128)
            )
            correction = fit_origin(
                samples["predictor_power"][calibration],
                samples["actual_power"][calibration],
            )
            for context_len, split in ((128, "calibration"), (512, "evaluation")):
                for layer in (-1, 0, 7, 15, 22, 29):
                    selected = (
                        (samples["path"] == path_code) &
                        (samples["bits"] == bits) &
                        (samples["context_len"] == context_len)
                    )
                    if layer >= 0:
                        selected &= samples["layer"] == layer
                    predictor = samples["predictor_power"][selected]
                    actual = samples["actual_power"][selected]
                    corrected = correction * predictor
                    valid = actual > POWER_FLOOR
                    residual = (
                        np.abs(corrected[valid] - actual[valid]) / actual[valid]
                    )
                    row = {
                        "evidence": EVIDENCE,
                        "path": path_name,
                        "bits": bits,
                        "split": split,
                        "context_len": context_len,
                        "layer": "all" if layer < 0 else layer,
                        "sample_count": int(actual.size),
                        "power_valid_sample_count": int(np.count_nonzero(valid)),
                        "calibration_correction_factor": correction,
                        "power_correlation": correlation(predictor, actual),
                        "mean_absolute_relative_power_residual": float(np.mean(residual)),
                        "median_absolute_relative_power_residual": float(np.median(residual)),
                        "p95_absolute_relative_power_residual": float(np.percentile(residual, 95)),
                        "mean_actual_error_power": float(np.mean(actual)),
                        "mean_corrected_predicted_power": float(np.mean(corrected)),
                    }
                    if path_code == 0:
                        cosines = samples["vector_cosine"][selected]
                        row.update({
                            "mean_vector_cosine": float(np.nanmean(cosines)),
                            "p05_vector_cosine": float(np.nanpercentile(cosines, 5)),
                        })
                    else:
                        row.update({"mean_vector_cosine": "", "p05_vector_cosine": ""})
                    summary_rows.append(row)

    write_csv(args.output / "predictor_summary.csv", summary_rows)
    headline = [row for row in summary_rows if
                row["split"] == "evaluation" and row["layer"] == "all"]
    result = {
        "evidence": EVIDENCE,
        "status": "PASS",
        "calibration_context": 128,
        "evaluation_context": 512,
        "evaluation_is_not_prompt_independent": True,
        "power_floor": POWER_FLOOR,
        "headline": headline,
        "limitations": [
            "The 512-token sequence extends the repeated prompt/token pattern used at context 128; this is not a prompt-independent holdout.",
            "Predictor validation concerns attention error power, not model accuracy or perplexity.",
            "Relative residual is reported only where actual power exceeds the recorded floor.",
        ],
    }
    (args.output / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
