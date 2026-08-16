#!/usr/bin/env python3
"""Run held-out controlled-attention KV quantization experiments.

All tensors produced here are SOFTWARE-SYNTHETIC.  They are deliberately not
presented as model accuracy, task accuracy, perplexity, or real activations.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import subprocess
from collections import defaultdict
from pathlib import Path
from typing import Any

import numpy as np

from kv_common import (
    HEAD_DIM,
    attention_stats,
    controlled_attention_sample,
    error_distribution,
    first_order_k_prediction,
    pearson,
    quantize_symmetric,
    relative_rmse,
    softmax,
    storage_per_kv_head,
    vector_cosine,
)


BASE_SEED = 20260816
CONTEXT_LENGTHS = (128, 512, 1024, 2048, 4096)
REGIMES = ("diffuse", "moderate", "sharp", "sink")
FAMILIES = (
    "gaussian",
    "laplace",
    "student_t_df3",
    "sparse_outliers_0p1pct_x25",
    "outliers_1pct_x10",
)
BITS = (3, 4, 5, 8)
JOINT_BITS = (3, 4, 5)
SAMPLES_PER_SPLIT = {"calibration": 1, "evaluation": 2}


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        raise ValueError(f"no rows for {path}")
    fields: list[str] = []
    for row in rows:
        for field in row:
            if field not in fields:
                fields.append(field)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def derived_seed(split: str, context: int, regime_index: int,
                 family_index: int, sample_index: int) -> int:
    split_id = 1 if split == "calibration" else 2
    sequence = np.random.SeedSequence(
        [BASE_SEED, split_id, context, regime_index, family_index, sample_index])
    return int(sequence.generate_state(1, dtype=np.uint32)[0])


def path(q: np.ndarray, k: np.ndarray, v: np.ndarray
         ) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    logits = (k.astype(np.float64) @ q.astype(np.float64)) / np.sqrt(q.size)
    attention = softmax(logits)
    output = attention.astype(np.float64) @ v.astype(np.float64)
    return logits.astype(np.float32), attention.astype(np.float32), output.astype(np.float32)


def normalized_bias(actual: np.ndarray, reference: np.ndarray) -> float:
    reference_rms = np.sqrt(np.mean(reference.astype(np.float64) ** 2))
    return float(np.mean(actual.astype(np.float64) - reference) /
                 max(reference_rms, 1.0e-30))


def quality_fields(logits: np.ndarray, attention: np.ndarray, output: np.ndarray,
                   reference_logits: np.ndarray,
                   reference_attention: np.ndarray,
                   reference_output: np.ndarray) -> dict[str, float | int | bool]:
    result: dict[str, float | int | bool] = {
        "qk_score_relative_rmse": relative_rmse(logits, reference_logits),
        "attention_probability_relative_rmse": relative_rmse(
            attention, reference_attention),
        "attention_output_relative_rmse": relative_rmse(output, reference_output),
        "attention_output_cosine": vector_cosine(output, reference_output),
        "top_attended_token_preserved": bool(
            np.argmax(attention) == np.argmax(reference_attention)),
        "attention_probability_max_abs_error": float(
            np.max(np.abs(attention.astype(np.float64) - reference_attention))),
    }
    result.update(error_distribution(output, reference_output))
    return result


def ideal_dequant(quantized: Any, original_shape: tuple[int, ...]) -> np.ndarray:
    return (quantized.codes.reshape(*quantized.codes.shape[:-1], 1,
                                    quantized.codes.shape[-1]).astype(np.float32) *
            quantized.ideal_scale).reshape(original_shape)


def predictor_summary(rows: list[dict[str, Any]], predictor: str,
                      x_field: str, y_field: str) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for bits in BITS:
        calibration = [row for row in rows
                       if row["split"] == "calibration" and row["bits"] == bits]
        evaluation = [row for row in rows
                      if row["split"] == "evaluation" and row["bits"] == bits]
        x_cal = np.asarray([row[x_field] for row in calibration], dtype=np.float64)
        y_cal = np.asarray([row[y_field] for row in calibration], dtype=np.float64)
        correction = float(np.dot(x_cal, y_cal) /
                           max(np.dot(x_cal, x_cal), 1.0e-30))
        for grouping, name in ((None, "all"), ("context_len", "context"),
                               ("regime", "attention_regime"),
                               ("family", "tensor_family")):
            groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
            for row in evaluation:
                groups["all" if grouping is None else str(row[grouping])].append(row)
            for group_value, members in groups.items():
                x = np.asarray([row[x_field] for row in members], dtype=np.float64)
                y = np.asarray([row[y_field] for row in members], dtype=np.float64)
                predicted = correction * x
                residual = predicted - y
                relative_residual = np.abs(residual) / np.maximum(y, 1.0e-30)
                output.append({
                    "evidence": "SOFTWARE-SYNTHETIC",
                    "predictor": predictor,
                    "bits": bits,
                    "calibration_samples": len(calibration),
                    "evaluation_samples": len(members),
                    "fitted_correction_factor_calibration_only": correction,
                    "grouping": name,
                    "group_value": group_value,
                    "heldout_pearson_correlation": pearson(x, y),
                    "heldout_mean_absolute_relative_residual": float(
                        np.mean(relative_residual)),
                    "heldout_p95_absolute_relative_residual": float(
                        np.percentile(relative_residual, 95)),
                    "heldout_signed_residual_mean": float(np.mean(residual)),
                    "heldout_actual_power_mean": float(np.mean(y)),
                    "heldout_predicted_power_mean": float(np.mean(predicted)),
                })
    return output


def aggregate_joint(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    evaluation = [row for row in rows if row["split"] == "evaluation"]
    grouped: dict[tuple[int, int], list[dict[str, Any]]] = defaultdict(list)
    for row in evaluation:
        grouped[(row["k_bits"], row["v_bits"])].append(row)
    result: list[dict[str, Any]] = []
    for (k_bits, v_bits), members in sorted(grouped.items()):
        errors = np.asarray([row["attention_output_relative_rmse"]
                             for row in members], dtype=np.float64)
        cosines = np.asarray([row["attention_output_cosine"]
                              for row in members], dtype=np.float64)
        storage = storage_per_kv_head(HEAD_DIM, k_bits, v_bits)
        result.append({
            "evidence": "SOFTWARE-SYNTHETIC",
            "k_bits": k_bits,
            "v_bits": v_bits,
            "samples": len(members),
            **storage,
            "mean_attention_output_relative_rmse": float(np.mean(errors)),
            "p95_attention_output_relative_rmse": float(np.percentile(errors, 95)),
            "worst_attention_output_relative_rmse": float(np.max(errors)),
            "mean_attention_output_cosine": float(np.mean(cosines)),
            "p05_attention_output_cosine": float(np.percentile(cosines, 5)),
        })
    for error_field, flag in (("mean_attention_output_relative_rmse",
                               "pareto_storage_vs_mean"),
                              ("p95_attention_output_relative_rmse",
                               "pareto_storage_vs_p95")):
        for candidate in result:
            candidate[flag] = not any(
                challenger is not candidate and
                challenger["bytes_per_token_per_kv_head"] <=
                candidate["bytes_per_token_per_kv_head"] and
                challenger[error_field] <= candidate[error_field] and
                (challenger["bytes_per_token_per_kv_head"] <
                 candidate["bytes_per_token_per_kv_head"] or
                 challenger[error_field] < candidate[error_field])
                for challenger in result)
    return result


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation")
    args = parser.parse_args()
    synthetic_dir = args.output / "synthetic"
    pareto_dir = args.output / "pareto"
    tensors_dir = args.output / "tensors"
    for directory in (synthetic_dir, pareto_dir, tensors_dir):
        directory.mkdir(parents=True, exist_ok=True)

    k_rows: list[dict[str, Any]] = []
    v_rows: list[dict[str, Any]] = []
    joint_rows: list[dict[str, Any]] = []
    scale_rows: list[dict[str, Any]] = []
    theory_rows: list[dict[str, Any]] = []
    verification_rows: list[dict[str, Any]] = []
    canonical: dict[str, np.ndarray] = {}

    for split, count in SAMPLES_PER_SPLIT.items():
        for context_len in CONTEXT_LENGTHS:
            for regime_index, regime in enumerate(REGIMES):
                for family_index, family in enumerate(FAMILIES):
                    for sample_index in range(count):
                        seed = derived_seed(split, context_len, regime_index,
                                            family_index, sample_index)
                        sample = controlled_attention_sample(
                            seed, context_len, regime, family)
                        q = np.asarray(sample["q"])
                        k = np.asarray(sample["k"])
                        v = np.asarray(sample["v"])
                        ref_logits = np.asarray(sample["logits"])
                        ref_attention = np.asarray(sample["attention"])
                        ref_output = np.asarray(sample["output"])
                        sample_id = (f"{split}-c{context_len}-{regime}-{family}-"
                                     f"n{sample_index}")
                        common = {
                            "evidence": "SOFTWARE-SYNTHETIC",
                            "sample_id": sample_id,
                            "split": split,
                            "seed": seed,
                            "context_len": context_len,
                            "head_dim": HEAD_DIM,
                            "regime": regime,
                            "family": family,
                            "sample_index": sample_index,
                            "q_format": "INT8 symmetric per-token absmax",
                            "scale_granularity": "per-token",
                            "scale_format": "floating reference",
                        }
                        stats = attention_stats(ref_attention)
                        verification_rows.append({
                            **common,
                            "target_attention_max_error": sample[
                                "target_attention_max_error"],
                            **stats,
                        })
                        if context_len == 128 and sample_index == 0:
                            prefix = f"{split}_{regime}_{family}"
                            canonical[prefix + "_q_int8_dequant"] = q
                            canonical[prefix + "_k_fp32"] = k
                            canonical[prefix + "_v_fp32"] = v
                            canonical[prefix + "_attention_fp32"] = ref_attention
                            canonical[prefix + "_output_fp32"] = ref_output

                        k_quantized: dict[int, Any] = {}
                        v_quantized: dict[int, Any] = {}
                        for bits in BITS:
                            kq = quantize_symmetric(k, bits, tensor_name="K")
                            vq = quantize_symmetric(v, bits, tensor_name="V")
                            k_quantized[bits] = kq
                            v_quantized[bits] = vq

                            k_logits, k_attention, k_output = path(q, kq.dequant, v)
                            k_quality = quality_fields(
                                k_logits, k_attention, k_output, ref_logits,
                                ref_attention, ref_output)
                            k_recon = relative_rmse(kq.dequant, k)
                            predicted_k_delta = first_order_k_prediction(
                                q, k, kq.dequant, ref_attention, v)
                            actual_k_delta = k_output - ref_output
                            k_predicted_power = float(np.mean(
                                predicted_k_delta.astype(np.float64) ** 2))
                            k_actual_power = float(np.mean(
                                actual_k_delta.astype(np.float64) ** 2))
                            k_residual = relative_rmse(
                                predicted_k_delta, actual_k_delta)
                            k_rows.append({
                                **common,
                                "bits": bits,
                                "k_tensor_reconstruction_relative_rmse": k_recon,
                                "k_tensor_normalized_bias": normalized_bias(
                                    kq.dequant, k),
                                **k_quality,
                                "first_order_vector_cosine": vector_cosine(
                                    predicted_k_delta, actual_k_delta),
                                "first_order_relative_prediction_residual": k_residual,
                                "first_order_predicted_output_error_power":
                                    k_predicted_power,
                                "actual_output_error_power": k_actual_power,
                                **stats,
                            })
                            theory_rows.append({
                                **common,
                                "predictor": "K_first_order",
                                "bits": bits,
                                "predictor_x": k_predicted_power,
                                "actual_output_error_power": k_actual_power,
                                "vector_cosine": vector_cosine(
                                    predicted_k_delta, actual_k_delta),
                                "relative_prediction_residual": k_residual,
                                **stats,
                            })

                            v_logits, v_attention, v_output = path(q, k, vq.dequant)
                            v_quality = quality_fields(
                                v_logits, v_attention, v_output, ref_logits,
                                ref_attention, ref_output)
                            v_error_variance = float(np.mean(
                                (vq.dequant.astype(np.float64) - v) ** 2))
                            v_actual_power = float(np.mean(
                                (v_output.astype(np.float64) - ref_output) ** 2))
                            theory_x = v_error_variance / stats["n_eff"]
                            v_rows.append({
                                **common,
                                "bits": bits,
                                "v_tensor_reconstruction_relative_rmse":
                                    relative_rmse(vq.dequant, v),
                                "v_tensor_normalized_bias": normalized_bias(
                                    vq.dequant, v),
                                **v_quality,
                                "v_error_variance": v_error_variance,
                                "theory_sigma2_over_n_eff": theory_x,
                                "actual_output_error_power": v_actual_power,
                                **stats,
                            })
                            theory_rows.append({
                                **common,
                                "predictor": "V_sigma2_over_Neff",
                                "bits": bits,
                                "predictor_x": theory_x,
                                "actual_output_error_power": v_actual_power,
                                **stats,
                            })

                        for k_bits in JOINT_BITS:
                            for v_bits in JOINT_BITS:
                                logits, attention, output = path(
                                    q, k_quantized[k_bits].dequant,
                                    v_quantized[v_bits].dequant)
                                joint_rows.append({
                                    **common,
                                    "k_bits": k_bits,
                                    "v_bits": v_bits,
                                    **quality_fields(
                                        logits, attention, output, ref_logits,
                                        ref_attention, ref_output),
                                    **storage_per_kv_head(
                                        HEAD_DIM, k_bits, v_bits),
                                    **stats,
                                })

                        # Scale representation screen and one-scale/run control.
                        for granularity in ("token", "run"):
                            float_k = quantize_symmetric(
                                k, 4, "float", granularity, "K")
                            float_v = quantize_symmetric(
                                v, 4, "float", granularity, "V")
                            q88_k = quantize_symmetric(
                                k, 4, "Q8.8", granularity, "K")
                            q88_v = quantize_symmetric(
                                v, 4, "Q8.8", granularity, "V")
                            float_logits, float_attention, float_output = path(
                                q, float_k.dequant, float_v.dequant)
                            q88_logits, q88_attention, q88_output = path(
                                q, q88_k.dequant, q88_v.dequant)
                            metadata_bytes = (4.0 if granularity == "token"
                                              else 4.0 / context_len)
                            scale_rows.append({
                                **common,
                                "evidence": "SOFTWARE-FIXED-POINT",
                                "scale_granularity": granularity,
                                "scale_format": "Q8.8",
                                "k_bits": 4,
                                "v_bits": 4,
                                "payload_bytes_per_token_per_kv_head": 128.0,
                                "metadata_bytes_per_token_per_kv_head":
                                    metadata_bytes,
                                "effective_bits_per_value":
                                    (128.0 + metadata_bytes) * 8.0 /
                                    (2.0 * HEAD_DIM),
                                "quantization_only_output_relative_rmse":
                                    relative_rmse(float_output, ref_output),
                                "scale_representation_only_output_relative_rmse":
                                    relative_rmse(q88_output, float_output),
                                "total_output_relative_rmse":
                                    relative_rmse(q88_output, ref_output),
                                "quantization_only_qk_score_relative_rmse":
                                    relative_rmse(float_logits, ref_logits),
                                "scale_representation_only_qk_score_relative_rmse":
                                    relative_rmse(q88_logits, float_logits),
                                "total_qk_score_relative_rmse":
                                    relative_rmse(q88_logits, ref_logits),
                                "q8_8_scale_saturation_count":
                                    q88_k.saturated_scale_count +
                                    q88_v.saturated_scale_count,
                                "attention_output_cosine": vector_cosine(
                                    q88_output, ref_output),
                                "top_attended_token_preserved": bool(
                                    np.argmax(q88_attention) ==
                                    np.argmax(ref_attention)),
                            })

    write_csv(synthetic_dir / "controlled_attention_verification.csv",
              verification_rows)
    write_csv(synthetic_dir / "k_only_results.csv", k_rows)
    write_csv(synthetic_dir / "v_only_results.csv", v_rows)
    write_csv(synthetic_dir / "joint_kv_results.csv", joint_rows)
    write_csv(synthetic_dir / "scale_representation_results.csv", scale_rows)
    write_csv(synthetic_dir / "theory_sample_results.csv", theory_rows)
    np.savez_compressed(tensors_dir / "synthetic_canonical_context128.npz",
                        **canonical)

    v_theory = [row for row in theory_rows
                if row["predictor"] == "V_sigma2_over_Neff"]
    k_theory = [row for row in theory_rows
                if row["predictor"] == "K_first_order"]
    predictor_rows = (
        predictor_summary(v_theory, "V_sigma2_over_Neff", "predictor_x",
                          "actual_output_error_power") +
        predictor_summary(k_theory, "K_first_order_power", "predictor_x",
                          "actual_output_error_power"))
    write_csv(synthetic_dir / "heldout_predictor_summary.csv", predictor_rows)

    pareto = aggregate_joint(joint_rows)
    write_csv(pareto_dir / "joint_kv_pareto.csv", pareto)
    summary = {
        "schema_version": 1,
        "evidence": "SOFTWARE-SYNTHETIC",
        "warning": ("Synthetic controlled-attention tensors; not model accuracy, "
                    "perplexity, or representative real-model tensors."),
        "base_seed": BASE_SEED,
        "head_dim": HEAD_DIM,
        "context_lengths": CONTEXT_LENGTHS,
        "attention_regimes": REGIMES,
        "tensor_families": FAMILIES,
        "splits": SAMPLES_PER_SPLIT,
        "quantizer": {
            "q": "INT8 symmetric narrow-range per-token absmax",
            "k_v": "INT3/4/5/8 symmetric narrow-range per-token absmax",
            "rounding": "NumPy round-to-nearest-even",
            "primary_scale": "floating reference",
            "screened_scale": "signed positive-use Q8.8",
            "dither": "disabled; interface present; exact G_B mapping TODO",
        },
        "row_counts": {
            "controlled_samples": len(verification_rows),
            "k_only": len(k_rows),
            "v_only": len(v_rows),
            "joint": len(joint_rows),
            "scale": len(scale_rows),
        },
        "maximum_controlled_attention_error": max(
            row["target_attention_max_error"] for row in verification_rows),
        "pareto": pareto,
        "heldout_predictor_summary": predictor_rows,
        "provenance": {
            "git_commit_before_validation_changes": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
            "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "numpy": np.__version__,
        },
    }
    (synthetic_dir / "synthetic_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary["row_counts"], sort_keys=True))


if __name__ == "__main__":
    main()
