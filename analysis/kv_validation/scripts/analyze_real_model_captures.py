#!/usr/bin/env python3
"""Quantization analysis for tensors captured from the real BitNet model."""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch


EVIDENCE = "REAL-MODEL-VALIDATED/custom-streaming-reference"
HEAD_DIM = 128
Q_HEADS = 20
KV_HEADS = 5
KV_GROUPS = Q_HEADS // KV_HEADS


@dataclass
class Quantized:
    dequant: np.ndarray
    ideal_dequant: np.ndarray
    ideal_scale: np.ndarray
    stored_scale: np.ndarray
    saturated_scales: int
    scale_count: int


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        raise ValueError(f"no rows for {path}")
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def relative_rmse(actual: np.ndarray, reference: np.ndarray) -> float:
    actual64 = actual.astype(np.float64)
    reference64 = reference.astype(np.float64)
    return float(np.sqrt(
        np.mean((actual64 - reference64) ** 2) /
        max(np.mean(reference64 ** 2), 1.0e-30)
    ))


def normalized_bias(actual: np.ndarray, reference: np.ndarray) -> float:
    reference64 = reference.astype(np.float64)
    reference_rms = np.sqrt(np.mean(reference64 ** 2))
    return float(np.mean(actual.astype(np.float64) - reference64) /
                 max(reference_rms, 1.0e-30))


def cosine(actual: np.ndarray, reference: np.ndarray) -> float:
    actual64 = actual.astype(np.float64).reshape(-1)
    reference64 = reference.astype(np.float64).reshape(-1)
    denominator = np.linalg.norm(actual64) * np.linalg.norm(reference64)
    return float(np.dot(actual64, reference64) / max(denominator, 1.0e-30))


def quantize(values: np.ndarray, bits: int, group_size: int | None,
             scale_format: str) -> Quantized:
    qmax = (1 << (bits - 1)) - 1
    original_shape = values.shape
    if group_size is None:
        grouped = values.reshape(1, -1)
    else:
        if original_shape[-1] % group_size:
            raise ValueError("group size must divide head dimension")
        grouped = values.reshape(
            *original_shape[:-1], original_shape[-1] // group_size, group_size
        )
    maximum = np.max(np.abs(grouped), axis=-1, keepdims=True)
    ideal_scale = maximum / qmax
    safe_scale = np.where(ideal_scale == 0.0, 1.0, ideal_scale).astype(np.float32)
    codes = np.clip(np.rint(grouped / safe_scale), -qmax, qmax).astype(np.int16)
    codes = np.where(maximum == 0.0, 0, codes)
    ideal_dequant = codes.astype(np.float32) * safe_scale
    if scale_format == "FP32":
        stored_scale = safe_scale
        saturated = 0
    elif scale_format == "Q8.8":
        raw = np.rint(safe_scale.astype(np.float64) * 256.0)
        saturated = int(np.count_nonzero((raw < 1.0) | (raw > 32767.0)))
        stored_scale = (np.clip(raw, 1.0, 32767.0) / 256.0).astype(np.float32)
    else:
        raise ValueError(scale_format)
    return Quantized(
        dequant=(codes.astype(np.float32) * stored_scale).reshape(original_shape),
        ideal_dequant=ideal_dequant.reshape(original_shape),
        ideal_scale=ideal_scale,
        stored_scale=stored_scale,
        saturated_scales=saturated,
        scale_count=ideal_scale.size,
    )


def repeat_kv(values: np.ndarray) -> np.ndarray:
    return np.repeat(values, KV_GROUPS, axis=0)


def scores(query: np.ndarray, key: np.ndarray) -> np.ndarray:
    return np.matmul(query.astype(np.float32),
                     repeat_kv(key).transpose(0, 2, 1).astype(np.float32)) / math.sqrt(HEAD_DIM)


def causal_softmax(logits: np.ndarray) -> np.ndarray:
    length = logits.shape[-1]
    mask = np.triu(np.ones((length, length), dtype=bool), k=1)
    masked = np.where(mask[None, :, :], -np.inf, logits.astype(np.float64))
    shifted = masked - np.max(masked, axis=-1, keepdims=True)
    exponent = np.exp(shifted)
    return (exponent / np.sum(exponent, axis=-1, keepdims=True)).astype(np.float32)


def attention_output(probability: np.ndarray, value: np.ndarray) -> np.ndarray:
    return np.matmul(probability.astype(np.float32), repeat_kv(value).astype(np.float32))


def valid_scores(values: np.ndarray) -> np.ndarray:
    length = values.shape[-1]
    valid = np.tril(np.ones((length, length), dtype=bool))
    return values[:, valid]


def output_error_metrics(actual: np.ndarray, reference: np.ndarray) -> dict[str, float]:
    error = actual.astype(np.float64) - reference.astype(np.float64)
    reference64 = reference.astype(np.float64)
    row_relative = np.sqrt(
        np.mean(error ** 2, axis=-1) /
        np.maximum(np.mean(reference64 ** 2, axis=-1), 1.0e-30)
    ).reshape(-1)
    reference_rms = np.sqrt(np.mean(reference64 ** 2))
    absolute = np.abs(error).reshape(-1) / max(reference_rms, 1.0e-30)
    return {
        "attention_output_relative_rmse": relative_rmse(actual, reference),
        "attention_output_cosine": cosine(actual, reference),
        "attention_output_row_relative_rmse_mean": float(np.mean(row_relative)),
        "attention_output_row_relative_rmse_p95": float(np.percentile(row_relative, 95)),
        "attention_output_row_relative_rmse_worst": float(np.max(row_relative)),
        "attention_output_max_abs_error_over_ref_rms": float(np.max(absolute)),
        "attention_output_p95_abs_error_over_ref_rms": float(np.percentile(absolute, 95)),
        "attention_output_bias_over_ref_rms": float(np.mean(error) /
                                                       max(reference_rms, 1.0e-30)),
    }


def path_metrics(query: np.ndarray, key: np.ndarray, value: np.ndarray,
                 reference_logits: np.ndarray, reference_probability: np.ndarray,
                 reference_output: np.ndarray) -> dict[str, float]:
    actual_logits = scores(query, key)
    actual_probability = causal_softmax(actual_logits)
    actual_output = attention_output(actual_probability, value)
    row = {
        "qk_score_relative_rmse": relative_rmse(
            valid_scores(actual_logits), valid_scores(reference_logits)),
        "attention_probability_relative_rmse": relative_rmse(
            actual_probability, reference_probability),
        "attention_probability_max_abs_error": float(
            np.max(np.abs(actual_probability - reference_probability))),
        "top_attended_token_preservation_fraction": float(np.mean(
            np.argmax(actual_probability, axis=-1) ==
            np.argmax(reference_probability, axis=-1))),
    }
    row.update(output_error_metrics(actual_output, reference_output))
    return row


def tensor_stats(layer: int, name: str, values: np.ndarray) -> dict:
    if name == "attention_logits":
        flat = valid_scores(values).astype(np.float64).reshape(-1)
    else:
        flat = values.astype(np.float64).reshape(-1)
    rms = np.sqrt(np.mean(flat ** 2))
    absolute = np.abs(flat)
    row = {
        "evidence": EVIDENCE,
        "layer": layer,
        "tensor": name,
        "shape": "x".join(str(value) for value in values.shape),
        "dtype_in_capture": "torch.bfloat16",
        "element_count_analyzed": flat.size,
        "min": float(np.min(flat)),
        "max": float(np.max(flat)),
        "mean": float(np.mean(flat)),
        "std": float(np.std(flat)),
        "rms": float(rms),
        "absmax": float(np.max(absolute)),
        "abs_p50": float(np.percentile(absolute, 50)),
        "abs_p95": float(np.percentile(absolute, 95)),
        "abs_p99": float(np.percentile(absolute, 99)),
        "abs_p99p9": float(np.percentile(absolute, 99.9)),
        "fraction_abs_gt_5xrms": float(np.mean(absolute > 5.0 * rms)),
        "fraction_abs_gt_10xrms": float(np.mean(absolute > 10.0 * rms)),
    }
    if values.ndim >= 2 and name not in ("attention_logits", "attention_probabilities"):
        vector_absmax = np.max(np.abs(values), axis=-1).reshape(-1)
        channel_absmax = np.max(
            np.abs(values), axis=tuple(range(values.ndim - 1))
        ).reshape(-1)
        row.update({
            "per_vector_absmax_p50": float(np.percentile(vector_absmax, 50)),
            "per_vector_absmax_p95": float(np.percentile(vector_absmax, 95)),
            "per_vector_absmax_max": float(np.max(vector_absmax)),
            "per_channel_absmax_p50": float(np.percentile(channel_absmax, 50)),
            "per_channel_absmax_p95": float(np.percentile(channel_absmax, 95)),
            "per_channel_absmax_max": float(np.max(channel_absmax)),
        })
    else:
        row.update({key: "" for key in (
            "per_vector_absmax_p50", "per_vector_absmax_p95",
            "per_vector_absmax_max", "per_channel_absmax_p50",
            "per_channel_absmax_p95", "per_channel_absmax_max")})
    return row


def base_row(layer: int, context_len: int, scale_format: str,
             group_size: int | None) -> dict:
    granularity = "one-scale-per-run" if group_size is None else f"group{group_size}"
    return {
        "evidence": EVIDENCE,
        "layer": layer,
        "context_len": context_len,
        "head_dim": HEAD_DIM,
        "q_format": "INT8 symmetric per-token/head absmax",
        "scale_granularity": granularity,
        "scale_format": scale_format,
    }


def scale_bytes(scale_format: str) -> int:
    return 4 if scale_format == "FP32" else 2


def metadata_per_vector(group_size: int | None, scale_format: str,
                        context_len: int) -> float:
    if group_size is None:
        return scale_bytes(scale_format) / (context_len * KV_HEADS)
    return (HEAD_DIM // group_size) * scale_bytes(scale_format)


def add_attention_stats(row: dict, probability: np.ndarray) -> None:
    entropy = -np.sum(
        probability.astype(np.float64) *
        np.log(np.maximum(probability.astype(np.float64), 1.0e-300)), axis=-1
    ).reshape(-1)
    n_eff = (1.0 / np.sum(probability.astype(np.float64) ** 2, axis=-1)).reshape(-1)
    maximum = np.max(probability, axis=-1).reshape(-1)
    row.update({
        "attention_entropy_mean": float(np.mean(entropy)),
        "attention_entropy_p95": float(np.percentile(entropy, 95)),
        "n_eff_mean": float(np.mean(n_eff)),
        "n_eff_p05": float(np.percentile(n_eff, 5)),
        "n_eff_p50": float(np.percentile(n_eff, 50)),
        "n_eff_p95": float(np.percentile(n_eff, 95)),
        "max_attention_probability_mean": float(np.mean(maximum)),
        "max_attention_probability_p95": float(np.percentile(maximum, 95)),
    })


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)

    run = json.loads((args.input / "run.json").read_text(encoding="utf-8"))
    context_len = int(run["context_len"])
    tensor_rows: list[dict] = []
    baseline_rows: list[dict] = []
    k_rows: list[dict] = []
    v_rows: list[dict] = []
    joint_rows: list[dict] = []
    mixed_granularity_rows: list[dict] = []

    standard_configs = [
        (bits, HEAD_DIM, scale_format)
        for bits in (3, 4, 5, 8)
        for scale_format in ("FP32", "Q8.8")
    ]
    int4_granularity_configs = [
        (4, group_size, scale_format)
        for group_size in (32, 16, 8, None)
        for scale_format in ("FP32", "Q8.8")
    ]
    configs = standard_configs + int4_granularity_configs

    for capture_path in sorted((args.input / "tensors").glob("layer_*.pt")):
        capture = torch.load(capture_path, map_location="cpu", weights_only=False)
        layer = int(capture["layer"])
        tensors = {
            name: value.float().numpy()
            for name, value in capture["tensors"].items()
        }
        for name, values in tensors.items():
            tensor_rows.append(tensor_stats(layer, name, values))

        query = tensors["q_post_rope"]
        key = tensors["k_post_rope"]
        value = tensors["v"]
        reference_logits = scores(query, key)
        reference_probability = causal_softmax(reference_logits)
        reference_output = attention_output(reference_probability, value)
        q8_quantized = quantize(query, 8, HEAD_DIM, "FP32")
        query_q8 = q8_quantized.dequant
        q8_logits = scores(query_q8, key)
        q8_probability = causal_softmax(q8_logits)
        q8_output = attention_output(q8_probability, value)

        captured_probability = tensors["attention_probabilities"]
        captured_output = tensors["attention_weighted_v"]
        baseline = {
            "evidence": EVIDENCE,
            "layer": layer,
            "context_len": context_len,
            "head_dim": HEAD_DIM,
            "path": "FP32 recompute vs captured BF16 attention",
            "q_tensor_int8_reconstruction_relative_rmse": relative_rmse(
                query_q8, query),
            "q_tensor_int8_normalized_bias": normalized_bias(query_q8, query),
            "captured_probability_vs_fp32_relative_rmse": relative_rmse(
                captured_probability, reference_probability),
            "captured_output_vs_fp32_relative_rmse": relative_rmse(
                captured_output, reference_output),
        }
        baseline.update(path_metrics(
            query_q8, key, value, reference_logits,
            reference_probability, reference_output,
        ))
        add_attention_stats(baseline, reference_probability)
        baseline_rows.append(baseline)

        quantized_cache: dict[tuple[str, int, int | None, str], Quantized] = {}
        for tensor_name, source in (("K", key), ("V", value)):
            for bits, group_size, scale_format in configs:
                quantized_cache[(tensor_name, bits, group_size, scale_format)] = quantize(
                    source, bits, group_size, scale_format)

        for bits, group_size, scale_format in configs:
            key_quantized = quantized_cache[("K", bits, group_size, scale_format)]
            row = base_row(layer, context_len, scale_format, group_size)
            row.update({
                "bits": bits,
                "k_tensor_reconstruction_relative_rmse": relative_rmse(
                    key_quantized.dequant, key),
                "k_tensor_normalized_bias": normalized_bias(
                    key_quantized.dequant, key),
                "scale_only_relative_rmse": relative_rmse(
                    key_quantized.dequant, key_quantized.ideal_dequant),
                "saturated_scale_count": key_quantized.saturated_scales,
                "scale_count": key_quantized.scale_count,
            })
            row.update(path_metrics(
                query_q8, key_quantized.dequant, value,
                reference_logits, reference_probability, reference_output,
            ))
            incremental = path_metrics(
                query_q8, key_quantized.dequant, value,
                q8_logits, q8_probability, q8_output,
            )
            row.update({
                "incremental_over_q8_qk_score_relative_rmse": incremental["qk_score_relative_rmse"],
                "incremental_over_q8_attention_probability_relative_rmse": incremental["attention_probability_relative_rmse"],
                "incremental_over_q8_attention_output_relative_rmse": incremental["attention_output_relative_rmse"],
                "payload_bytes_per_token_per_kv_head": HEAD_DIM * bits / 8.0,
                "metadata_bytes_per_token_per_kv_head": metadata_per_vector(
                    group_size, scale_format, context_len),
            })
            row["effective_bits_per_k_value"] = (
                row["payload_bytes_per_token_per_kv_head"] +
                row["metadata_bytes_per_token_per_kv_head"]
            ) * 8.0 / HEAD_DIM
            k_rows.append(row)

            value_quantized = quantized_cache[("V", bits, group_size, scale_format)]
            row = base_row(layer, context_len, scale_format, group_size)
            row.update({
                "bits": bits,
                "v_tensor_reconstruction_relative_rmse": relative_rmse(
                    value_quantized.dequant, value),
                "v_tensor_normalized_bias": normalized_bias(
                    value_quantized.dequant, value),
                "scale_only_relative_rmse": relative_rmse(
                    value_quantized.dequant, value_quantized.ideal_dequant),
                "saturated_scale_count": value_quantized.saturated_scales,
                "scale_count": value_quantized.scale_count,
            })
            row.update(path_metrics(
                query_q8, key, value_quantized.dequant,
                reference_logits, reference_probability, reference_output,
            ))
            incremental = path_metrics(
                query_q8, key, value_quantized.dequant,
                q8_logits, q8_probability, q8_output,
            )
            row.update({
                "incremental_over_q8_attention_output_relative_rmse": incremental["attention_output_relative_rmse"],
                "payload_bytes_per_token_per_kv_head": HEAD_DIM * bits / 8.0,
                "metadata_bytes_per_token_per_kv_head": metadata_per_vector(
                    group_size, scale_format, context_len),
            })
            row["effective_bits_per_v_value"] = (
                row["payload_bytes_per_token_per_kv_head"] +
                row["metadata_bytes_per_token_per_kv_head"]
            ) * 8.0 / HEAD_DIM
            v_rows.append(row)

        joint_configs = [
            (k_bits, v_bits, HEAD_DIM, scale_format)
            for k_bits in (3, 4, 5)
            for v_bits in (3, 4, 5)
            for scale_format in ("FP32", "Q8.8")
        ] + [
            (4, 4, group_size, scale_format)
            for group_size in (32, 16, 8, None)
            for scale_format in ("FP32", "Q8.8")
        ]
        for k_bits, v_bits, group_size, scale_format in joint_configs:
            key_quantized = quantized_cache[("K", k_bits, group_size, scale_format)]
            value_quantized = quantized_cache[("V", v_bits, group_size, scale_format)]
            row = base_row(layer, context_len, scale_format, group_size)
            row.update({"k_bits": k_bits, "v_bits": v_bits})
            row.update(path_metrics(
                query_q8, key_quantized.dequant, value_quantized.dequant,
                reference_logits, reference_probability, reference_output,
            ))
            metadata_each = metadata_per_vector(group_size, scale_format, context_len)
            payload = HEAD_DIM * (k_bits + v_bits) / 8.0
            metadata = 2.0 * metadata_each
            total = payload + metadata
            row.update({
                "k_payload_bytes_per_token_per_kv_head": HEAD_DIM * k_bits / 8.0,
                "v_payload_bytes_per_token_per_kv_head": HEAD_DIM * v_bits / 8.0,
                "scale_metadata_bytes_per_token_per_kv_head": metadata,
                "total_bytes_per_token_per_kv_head": total,
                "effective_bits_per_kv_value": total * 8.0 / (2.0 * HEAD_DIM),
                "compression_vs_fp16_kv": (2.0 * HEAD_DIM * 2.0) / total,
                "compression_vs_int8_kv": (2.0 * HEAD_DIM) / total,
                "k_saturated_scale_count": key_quantized.saturated_scales,
                "v_saturated_scale_count": value_quantized.saturated_scales,
            })
            joint_rows.append(row)

        # Actual activations show materially different K and V sensitivity, so
        # do not force both tensors to use the same INT4 group size.
        for k_group_size in (HEAD_DIM, 32, 16, 8):
            for v_group_size in (HEAD_DIM, 32, 16, 8):
                key_quantized = quantized_cache[("K", 4, k_group_size, "Q8.8")]
                value_quantized = quantized_cache[("V", 4, v_group_size, "Q8.8")]
                row = {
                    "evidence": EVIDENCE,
                    "layer": layer,
                    "context_len": context_len,
                    "head_dim": HEAD_DIM,
                    "q_format": "INT8 symmetric per-token/head absmax",
                    "k_bits": 4,
                    "v_bits": 4,
                    "k_scale_granularity": f"group{k_group_size}",
                    "v_scale_granularity": f"group{v_group_size}",
                    "scale_format": "Q8.8",
                }
                row.update(path_metrics(
                    query_q8, key_quantized.dequant, value_quantized.dequant,
                    reference_logits, reference_probability, reference_output,
                ))
                k_metadata = metadata_per_vector(k_group_size, "Q8.8", context_len)
                v_metadata = metadata_per_vector(v_group_size, "Q8.8", context_len)
                payload = 2.0 * HEAD_DIM * 4 / 8.0
                total = payload + k_metadata + v_metadata
                row.update({
                    "k_payload_bytes_per_token_per_kv_head": HEAD_DIM * 4 / 8.0,
                    "v_payload_bytes_per_token_per_kv_head": HEAD_DIM * 4 / 8.0,
                    "k_scale_metadata_bytes_per_token_per_kv_head": k_metadata,
                    "v_scale_metadata_bytes_per_token_per_kv_head": v_metadata,
                    "total_bytes_per_token_per_kv_head": total,
                    "effective_bits_per_kv_value": total * 8.0 / (2.0 * HEAD_DIM),
                    "compression_vs_fp16_kv": (2.0 * HEAD_DIM * 2.0) / total,
                    "compression_vs_int8_kv": (2.0 * HEAD_DIM) / total,
                })
                mixed_granularity_rows.append(row)

    write_csv(args.output / "tensor_statistics.csv", tensor_rows)
    write_csv(args.output / "attention_baselines.csv", baseline_rows)
    write_csv(args.output / "k_only_results.csv", k_rows)
    write_csv(args.output / "v_only_results.csv", v_rows)
    write_csv(args.output / "joint_kv_results.csv", joint_rows)
    write_csv(args.output / "int4_mixed_granularity_results.csv",
              mixed_granularity_rows)

    def summarize_configs(rows: list[dict], key_fields: tuple[str, ...]) -> list[dict]:
        groups: dict[tuple[str, ...], list[dict]] = {}
        for row in rows:
            key = tuple(str(row[field]) for field in key_fields)
            groups.setdefault(key, []).append(row)
        result = []
        for key, members in groups.items():
            summary_row = {field: value for field, value in zip(key_fields, key)}
            summary_row.update({
                "evidence": EVIDENCE,
                "layer_count": len(members),
                "total_bytes_per_token_per_kv_head": float(
                    members[0]["total_bytes_per_token_per_kv_head"]),
                "effective_bits_per_kv_value": float(
                    members[0]["effective_bits_per_kv_value"]),
                "compression_vs_fp16_kv": float(members[0]["compression_vs_fp16_kv"]),
                "compression_vs_int8_kv": float(members[0]["compression_vs_int8_kv"]),
                "mean_attention_output_relative_rmse": float(np.mean([
                    member["attention_output_relative_rmse"] for member in members])),
                "worst_layer_attention_output_relative_rmse": float(np.max([
                    member["attention_output_relative_rmse"] for member in members])),
                "mean_layer_p95_row_relative_rmse": float(np.mean([
                    member["attention_output_row_relative_rmse_p95"] for member in members])),
                "worst_layer_p95_row_relative_rmse": float(np.max([
                    member["attention_output_row_relative_rmse_p95"] for member in members])),
                "mean_qk_score_relative_rmse": float(np.mean([
                    member["qk_score_relative_rmse"] for member in members])),
            })
            result.append(summary_row)
        for candidate in result:
            candidate["pareto_storage_mean_worst"] = not any(
                other is not candidate and
                other["effective_bits_per_kv_value"] <= candidate["effective_bits_per_kv_value"] and
                other["mean_attention_output_relative_rmse"] <= candidate["mean_attention_output_relative_rmse"] and
                other["worst_layer_attention_output_relative_rmse"] <= candidate["worst_layer_attention_output_relative_rmse"] and
                (
                    other["effective_bits_per_kv_value"] < candidate["effective_bits_per_kv_value"] or
                    other["mean_attention_output_relative_rmse"] < candidate["mean_attention_output_relative_rmse"] or
                    other["worst_layer_attention_output_relative_rmse"] < candidate["worst_layer_attention_output_relative_rmse"]
                )
                for other in result
            )
        return sorted(result, key=lambda row: (
            row["effective_bits_per_kv_value"],
            row["mean_attention_output_relative_rmse"],
        ))

    joint_summary_rows = summarize_configs(
        joint_rows, ("k_bits", "v_bits", "scale_granularity", "scale_format"))
    mixed_summary_rows = summarize_configs(
        mixed_granularity_rows,
        ("k_bits", "v_bits", "k_scale_granularity",
         "v_scale_granularity", "scale_format"),
    )
    write_csv(args.output / "joint_kv_summary.csv", joint_summary_rows)
    write_csv(args.output / "int4_mixed_granularity_summary.csv",
              mixed_summary_rows)

    def aggregate(rows: list[dict], select) -> dict[str, float]:
        selected = [row for row in rows if select(row)]
        errors = np.asarray([
            row["attention_output_relative_rmse"] for row in selected
        ], dtype=np.float64)
        p95 = np.asarray([
            row["attention_output_row_relative_rmse_p95"] for row in selected
        ], dtype=np.float64)
        return {
            "layer_count": len(selected),
            "mean_attention_output_relative_rmse": float(np.mean(errors)),
            "worst_layer_attention_output_relative_rmse": float(np.max(errors)),
            "mean_layer_p95_row_relative_rmse": float(np.mean(p95)),
            "worst_layer_p95_row_relative_rmse": float(np.max(p95)),
        }

    summary = {
        "evidence": EVIDENCE,
        "status": "PASS",
        "source_run": str(args.input.resolve()),
        "context_len": context_len,
        "layers": [int(path.stem.split("_")[1]) for path in
                   sorted((args.input / "tensors").glob("layer_*.pt"))],
        "reference": "FP32 attention recomputed from captured BF16 Q/K/V",
        "q_path": "INT8 symmetric per-token/head absmax for quantized rows",
        "q8_only": {
            "mean_attention_output_relative_rmse": float(np.mean([
                row["attention_output_relative_rmse"] for row in baseline_rows
            ])),
            "worst_attention_output_relative_rmse": float(np.max([
                row["attention_output_relative_rmse"] for row in baseline_rows
            ])),
        },
        "joint_selected": {},
        "warnings": [
            "These are tensor/attention distortion results, not accuracy or perplexity results.",
            f"Only context {context_len} is included in this run.",
            "The execution path is custom but its one-layer output was bitwise checked against the pinned Transformers implementation.",
        ],
    }
    for key, k_bits, v_bits, group_size, scale_format in (
        ("K3_V3_group128_FP32", 3, 3, 128, "FP32"),
        ("K4_V4_group128_FP32", 4, 4, 128, "FP32"),
        ("K4_V4_group128_Q8.8", 4, 4, 128, "Q8.8"),
        ("K4_V4_group32_Q8.8", 4, 4, 32, "Q8.8"),
        ("K4_V4_group16_Q8.8", 4, 4, 16, "Q8.8"),
        ("K4_V4_group8_Q8.8", 4, 4, 8, "Q8.8"),
        ("K5_V5_group128_FP32", 5, 5, 128, "FP32"),
    ):
        summary["joint_selected"][key] = aggregate(
            joint_rows,
            lambda row, kb=k_bits, vb=v_bits, gs=group_size, sf=scale_format:
                row["k_bits"] == kb and row["v_bits"] == vb and
                row["scale_granularity"] == f"group{gs}" and
                row["scale_format"] == sf,
        )
    q88_scale_errors = [
        row["scale_only_relative_rmse"] for row in k_rows + v_rows
        if row["scale_format"] == "Q8.8"
    ]
    summary["q8_8_scale_quantization"] = {
        "max_scale_only_relative_rmse": float(np.max(q88_scale_errors)),
        "mean_scale_only_relative_rmse": float(np.mean(q88_scale_errors)),
        "int4_max_scale_only_relative_rmse": float(np.max([
            row["scale_only_relative_rmse"] for row in k_rows + v_rows
            if row["scale_format"] == "Q8.8" and row["bits"] == 4
        ])),
        "int4_mean_scale_only_relative_rmse": float(np.mean([
            row["scale_only_relative_rmse"] for row in k_rows + v_rows
            if row["scale_format"] == "Q8.8" and row["bits"] == 4
        ])),
        "total_saturated_scale_count": int(sum(
            row["saturated_scale_count"] for row in k_rows + v_rows
            if row["scale_format"] == "Q8.8"
        )),
    }
    (args.output / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
