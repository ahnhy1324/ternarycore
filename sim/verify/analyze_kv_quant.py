#!/usr/bin/env python3
"""Generate reproducible synthetic KV-cache v0.2 analysis artifacts."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any

import numpy as np

from kv_quant_reference import (
    HEAD_DIM,
    hadamard_blocks,
    make_dataset,
    mean_vector_cosine,
    normalized_bias,
    qkv_reference,
    quantize_symmetric,
    relative_rmse,
    scale_metadata_bytes_per_token,
    softmax,
)


BASE_SEED = 20260816
CONTEXT_LENGTHS = (128, 256, 512, 1024, 2048, 4096)
DISTRIBUTIONS = (
    "gaussian",
    "laplace",
    "student_t_df3",
    "sparse_outliers_0p1pct_x25",
    "outliers_1pct_x10",
)
KV_BITS = (8, 5, 4, 3)
SCALE_FORMATS = ("FP32", "FP16", "Q8.8")
GRANULARITIES = (
    ("run", None, "run"),
    ("token", None, "token64"),
    ("group", 32, "group32"),
    ("group", 16, "group16"),
    ("group", 8, "group8"),
)
HADAMARD_BLOCKS = (None, 4, 8, 16, 32, 64)
HADAMARD_GROUPS = (64, 32, 16, 8)


def trials_for_context(context_len: int) -> int:
    # At least four attention problems, while bounding the largest arrays.
    return max(4, min(32, 8192 // context_len))


def dataset_seed(distribution_index: int, context_len: int) -> int:
    sequence = np.random.SeedSequence([BASE_SEED, distribution_index, context_len])
    return int(sequence.generate_state(1, dtype=np.uint32)[0])


def scale_bits(scale_format: str) -> int:
    return 32 if scale_format == "FP32" else 16


def payload_bytes(bits: int, head_dim: int = HEAD_DIM) -> float:
    return head_dim * bits / 8.0


def storage_fields(bits: int, granularity: str, group_size: int | None,
                   scale_format: str, context_len: int,
                   head_dim: int = HEAD_DIM) -> dict[str, float]:
    metadata = scale_metadata_bytes_per_token(
        granularity, head_dim, context_len, scale_bits(scale_format), group_size)
    payload = payload_bytes(bits, head_dim)
    total = payload + metadata
    return {
        "payload_bytes_per_k_or_v_token": payload,
        "metadata_bytes_per_k_or_v_token": metadata,
        "total_bytes_per_k_or_v_token": total,
        "kv_pair_bytes_per_token": 2.0 * total,
        "effective_bits_per_value": total * 8.0 / head_dim,
    }


def transformed_path(q: np.ndarray, k: np.ndarray, v: np.ndarray,
                     bits: int, granularity: str, group_size: int | None,
                     scale_format: str, hadamard_block: int | None,
                     metadata: dict[str, int | str],
                     ) -> dict[str, np.ndarray]:
    qt = hadamard_blocks(q, hadamard_block)
    kt = hadamard_blocks(k, hadamard_block)
    vt = hadamard_blocks(v, hadamard_block)

    q8 = quantize_symmetric(qt, 8, granularity="token", scale_format="FP32",
                            tensor_name="Q", dither_metadata=metadata)
    kq = quantize_symmetric(kt, bits, granularity=granularity,
                            group_size=group_size, scale_format=scale_format,
                            tensor_name="K", dither_metadata=metadata)
    vq = quantize_symmetric(vt, bits, granularity=granularity,
                            group_size=group_size, scale_format=scale_format,
                            tensor_name="V", dither_metadata=metadata)

    logits = (np.einsum("bd,btd->bt", q8.dequant, kq.dequant, optimize=True) /
              np.sqrt(q.shape[-1]))
    attention = softmax(logits)
    output_t = np.einsum("bt,btd->bd", attention, vq.dequant, optimize=True)
    output = hadamard_blocks(output_t, hadamard_block)

    quant_only_logits = (
        np.einsum("bd,btd->bt", q8.dequant, kq.ideal_scale_dequant,
                  optimize=True) / np.sqrt(q.shape[-1]))
    quant_only_attention = softmax(quant_only_logits)
    quant_only_output_t = np.einsum(
        "bt,btd->bd", quant_only_attention, vq.ideal_scale_dequant,
        optimize=True)
    quant_only_output = hadamard_blocks(quant_only_output_t, hadamard_block)

    return {
        "logits": logits.astype(np.float32),
        "output": output.astype(np.float32),
        "quant_only_logits": quant_only_logits.astype(np.float32),
        "quant_only_output": quant_only_output.astype(np.float32),
        "k": kq.dequant,
        "v": vq.dequant,
        "k_quant_only": kq.ideal_scale_dequant,
        "v_quant_only": vq.ideal_scale_dequant,
    }


def metric_fields(path: dict[str, np.ndarray], reference_logits: np.ndarray,
                  reference_output: np.ndarray, reference_k: np.ndarray,
                  reference_v: np.ndarray) -> dict[str, float]:
    return {
        "normalized_qk_logit_rmse": relative_rmse(path["logits"], reference_logits),
        "attention_output_relative_rmse": relative_rmse(path["output"], reference_output),
        "attention_output_cosine": mean_vector_cosine(path["output"], reference_output),
        "normalized_logit_bias": normalized_bias(path["logits"], reference_logits),
        "normalized_attention_output_bias": normalized_bias(path["output"], reference_output),
        "k_relative_rmse": relative_rmse(path["k"], reference_k),
        "v_relative_rmse": relative_rmse(path["v"], reference_v),
        "quant_only_qk_logit_rmse": relative_rmse(
            path["quant_only_logits"], reference_logits),
        "quant_only_attention_output_rmse": relative_rmse(
            path["quant_only_output"], reference_output),
        "scale_only_qk_logit_rmse": relative_rmse(
            path["logits"], path["quant_only_logits"]),
        "scale_only_attention_output_rmse": relative_rmse(
            path["output"], path["quant_only_output"]),
        "scale_only_k_rmse": relative_rmse(path["k"], path["k_quant_only"]),
        "scale_only_v_rmse": relative_rmse(path["v"], path["v_quant_only"]),
    }


def fp_and_q8fp_rows(q: np.ndarray, k: np.ndarray, v: np.ndarray,
                     reference_logits: np.ndarray, reference_output: np.ndarray,
                     common: dict[str, Any]) -> list[dict[str, Any]]:
    zero_metrics = {
        "normalized_qk_logit_rmse": 0.0,
        "attention_output_relative_rmse": 0.0,
        "attention_output_cosine": 1.0,
        "normalized_logit_bias": 0.0,
        "normalized_attention_output_bias": 0.0,
        "k_relative_rmse": 0.0,
        "v_relative_rmse": 0.0,
        "quant_only_qk_logit_rmse": 0.0,
        "quant_only_attention_output_rmse": 0.0,
        "scale_only_qk_logit_rmse": 0.0,
        "scale_only_attention_output_rmse": 0.0,
        "scale_only_k_rmse": 0.0,
        "scale_only_v_rmse": 0.0,
    }
    fp_storage = {
        "payload_bytes_per_k_or_v_token": float(HEAD_DIM * 2),
        "metadata_bytes_per_k_or_v_token": 0.0,
        "total_bytes_per_k_or_v_token": float(HEAD_DIM * 2),
        "kv_pair_bytes_per_token": float(HEAD_DIM * 4),
        "effective_bits_per_value": 16.0,
    }
    fp_row = {**common, "configuration": "FP_reference", "kv_bits": "FP",
              "scale_format": "none", "granularity": "none",
              "group_size": HEAD_DIM, **zero_metrics, **fp_storage}

    q8 = quantize_symmetric(q, 8, granularity="token", scale_format="FP32",
                            tensor_name="Q")
    logits = (np.einsum("bd,btd->bt", q8.dequant, k, optimize=True) /
              np.sqrt(HEAD_DIM))
    attention = softmax(logits)
    output = np.einsum("bt,btd->bd", attention, v, optimize=True)
    path = {
        "logits": logits,
        "output": output,
        "quant_only_logits": logits,
        "quant_only_output": output,
        "k": k,
        "v": v,
        "k_quant_only": k,
        "v_quant_only": v,
    }
    q8fp_row = {**common, "configuration": "Q8_FP_KV", "kv_bits": "FP",
                "scale_format": "none", "granularity": "none",
                "group_size": HEAD_DIM,
                **metric_fields(path, reference_logits, reference_output, k, v),
                **fp_storage}
    return [fp_row, q8fp_row]


def aggregate(rows: list[dict[str, Any]], keys: tuple[str, ...],
              metrics: tuple[str, ...]) -> list[dict[str, Any]]:
    groups: dict[tuple[Any, ...], list[dict[str, Any]]] = {}
    for row in rows:
        groups.setdefault(tuple(row[key] for key in keys), []).append(row)
    result = []
    for group_key, members in groups.items():
        output = dict(zip(keys, group_key))
        output["experiment_rows"] = len(members)
        for metric in metrics:
            values = np.asarray([float(row[metric]) for row in members])
            output[f"mean_{metric}"] = float(np.mean(values))
            output[f"p95_{metric}"] = float(np.percentile(values, 95))
            output[f"worst_{metric}"] = float(np.max(values))
        first = members[0]
        for field in (
            "metadata_bytes_per_k_or_v_token",
            "total_bytes_per_k_or_v_token",
            "effective_bits_per_value",
            "estimated_hadamard_stages",
            "estimated_hadamard_butterflies_per_vector",
            "estimated_hadamard_addsub_outputs_per_vector",
        ):
            if field in first:
                output[field] = float(np.mean([float(member[field])
                                               for member in members]))
        result.append(output)
    return result


def storage_table() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for head_dim in (64, 128):
        for context_len in CONTEXT_LENGTHS:
            for granularity, group_size, label in GRANULARITIES:
                if granularity == "group" and group_size > head_dim:
                    continue
                data = storage_fields(4, granularity, group_size, "Q8.8",
                                      context_len, head_dim)
                total = data["total_bytes_per_k_or_v_token"]
                equal_existing = 2.0 * head_dim
                rows.append({
                    "head_dim": head_dim,
                    "context_len": context_len,
                    "kv_bits": 4,
                    "granularity": label,
                    "scale_format": "Q8.8",
                    **data,
                    "row_major_fp16_bytes": 2.0 * head_dim,
                    "row_major_int8_bytes": float(head_dim),
                    "equal_dim_bitsliced_int8_bytes": equal_existing,
                    "compression_vs_row_major_fp16": 2.0 * head_dim / total,
                    "compression_vs_row_major_int8": head_dim / total,
                    "compression_vs_equal_dim_bitsliced_int8": equal_existing / total,
                    "actual_existing_128d_bytes": 256.0,
                    "compression_vs_actual_existing_128d": 256.0 / total,
                    "actual_existing_comparison_is_equal_dim": head_dim == 128,
                })
    return rows


def decorate_scale_pareto(rows: list[dict[str, Any]]) -> None:
    group_scales = {"run": 0.0, "token64": 1.0, "group32": 2.0,
                    "group16": 4.0, "group8": 8.0}
    format_cost = {"Q8.8": 1, "FP16": 2, "FP32": 3}
    for row in rows:
        row["scale_values_per_vector"] = group_scales[row["granularity"]]
        row["estimated_parallel_scale_multipliers"] = (
            2 if row["granularity"] == "group8" else 1)
        row["estimated_scale_decode_cost_ordinal"] = format_cost[row["scale_format"]]
        row["recommended_v02_knee"] = (
            row["granularity"] == "group16" and row["scale_format"] == "Q8.8")

    criteria = ("mean_normalized_qk_logit_rmse",
                "mean_attention_output_relative_rmse",
                "total_bytes_per_k_or_v_token",
                "estimated_parallel_scale_multipliers",
                "estimated_scale_decode_cost_ordinal")
    for candidate in rows:
        dominated = False
        for challenger in rows:
            if challenger is candidate:
                continue
            no_worse = all(float(challenger[key]) <= float(candidate[key])
                           for key in criteria)
            strictly_better = any(float(challenger[key]) < float(candidate[key])
                                  for key in criteria)
            if no_worse and strictly_better:
                dominated = True
                break
        candidate["pareto_nondominated"] = not dominated


def decorate_hadamard_pareto(rows: list[dict[str, Any]]) -> None:
    baseline = {row["granularity"]: row for row in rows
                if row["hadamard"] == "none"}
    for row in rows:
        base_error = baseline[row["granularity"]][
            "mean_attention_output_relative_rmse"]
        row["mean_output_error_change_vs_no_hadamard_pct"] = (
            (row["mean_attention_output_relative_rmse"] / base_error - 1.0) * 100.0)
        row["recommended_for_baseline"] = False

    criteria = ("mean_normalized_qk_logit_rmse",
                "mean_attention_output_relative_rmse",
                "total_bytes_per_k_or_v_token",
                "estimated_hadamard_addsub_outputs_per_vector")
    for candidate in rows:
        dominated = False
        for challenger in rows:
            if challenger is candidate:
                continue
            no_worse = all(float(challenger[key]) <= float(candidate[key])
                           for key in criteria)
            strictly_better = any(float(challenger[key]) < float(candidate[key])
                                  for key in criteria)
            if no_worse and strictly_better:
                dominated = True
                break
        candidate["pareto_nondominated"] = not dominated


def layout_table() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for context_len in CONTEXT_LENGTHS:
        for axi_width in (128, 256):
            for scales_per_token, granularity in ((1, "token64"), (4, "group16")):
                beat_bytes = axi_width // 8
                data_bytes = context_len * 32
                scale_record_bytes = scales_per_token * 2
                scale_bytes = context_len * scale_record_bytes
                record_bytes = 32 + scale_record_bytes
                separate_transfer = (
                    math.ceil(data_bytes / beat_bytes) * beat_bytes +
                    math.ceil(scale_bytes / beat_bytes) * beat_bytes)
                interleaved_stream = (
                    math.ceil(context_len * record_bytes / beat_bytes) * beat_bytes)
                per_record_transfer = 0
                for token in range(context_len):
                    start = token * record_bytes
                    first = start // beat_bytes
                    last = (start + record_bytes - 1) // beat_bytes
                    per_record_transfer += (last - first + 1) * beat_bytes
                rows.append({
                    "context_len": context_len,
                    "axi_width": axi_width,
                    "granularity": granularity,
                    "scales_per_token": scales_per_token,
                    "layout": "separate_planes",
                    "useful_bytes": context_len * record_bytes,
                    "long_burst_transferred_bytes": separate_transfer,
                    "fully_tokenwise_transaction_bytes": (
                        context_len * (32 + math.ceil(scale_record_bytes /
                                                      beat_bytes) * beat_bytes)),
                    "scale_values_per_beat": beat_bytes // 2,
                    "k_address_expression": "base+(token<<5)",
                    "scale_address_expression": (
                        "base+(token<<1)" if scales_per_token == 1
                        else "base+(token<<3)"),
                    "k_vectors_32byte_aligned": True,
                })
                rows.append({
                    "context_len": context_len,
                    "axi_width": axi_width,
                    "granularity": granularity,
                    "scales_per_token": scales_per_token,
                    "layout": f"interleaved_{record_bytes}byte",
                    "useful_bytes": context_len * record_bytes,
                    "long_burst_transferred_bytes": interleaved_stream,
                    "fully_tokenwise_transaction_bytes": per_record_transfer,
                    "scale_values_per_beat": 0,
                    "k_address_expression": f"base+token*{record_bytes}",
                    "scale_address_expression": "embedded in record",
                    "k_vectors_32byte_aligned": False,
                })
    return rows


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        raise ValueError(f"no rows for {path}")
    fieldnames: list[str] = []
    for row in rows:
        for field in row:
            if field not in fieldnames:
                fieldnames.append(field)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def git_head(repo_root: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repo_root, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def main() -> None:
    parser = argparse.ArgumentParser()
    repo_root = Path(__file__).resolve().parents[2]
    parser.add_argument("--output-dir", type=Path,
                        default=repo_root / "docs" / "runs")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    numerical_rows: list[dict[str, Any]] = []
    scale_rows: list[dict[str, Any]] = []
    hadamard_rows: list[dict[str, Any]] = []

    for distribution_index, distribution in enumerate(DISTRIBUTIONS):
        for context_len in CONTEXT_LENGTHS:
            trials = trials_for_context(context_len)
            seed = dataset_seed(distribution_index, context_len)
            q, k, v = make_dataset(seed, distribution, trials, context_len)
            reference_logits, _, reference_output = qkv_reference(q, k, v)
            common = {
                "synthetic_distribution": distribution,
                "context_len": context_len,
                "head_dim": HEAD_DIM,
                "trials": trials,
                "seed": seed,
            }

            numerical_rows.extend(fp_and_q8fp_rows(
                q, k, v, reference_logits, reference_output, common))
            for bits in KV_BITS:
                metadata = {"seed": seed, "context_len": context_len,
                            "distribution": distribution}
                # FP16 keeps the cross-bit comparison about code precision.
                # Q8.8 is swept separately for INT4; at INT8 its 2^-8 step is
                # a material fraction of a typical per-token absmax scale.
                path = transformed_path(q, k, v, bits, "token", None,
                                        "FP16", None, metadata)
                numerical_rows.append({
                    **common,
                    "configuration": f"Q8_KV{bits}",
                    "kv_bits": bits,
                    "scale_format": "FP16",
                    "granularity": "token64",
                    "group_size": HEAD_DIM,
                    **metric_fields(path, reference_logits, reference_output, k, v),
                    **storage_fields(bits, "token", None, "FP16", context_len),
                })

            for granularity, group_size, granularity_label in GRANULARITIES:
                for scale_format in SCALE_FORMATS:
                    metadata = {"seed": seed, "context_len": context_len,
                                "distribution": distribution}
                    path = transformed_path(q, k, v, 4, granularity, group_size,
                                            scale_format, None, metadata)
                    scale_rows.append({
                        **common,
                        "kv_bits": 4,
                        "scale_format": scale_format,
                        "granularity": granularity_label,
                        "group_size": (context_len * HEAD_DIM if granularity == "run"
                                       else HEAD_DIM if granularity == "token"
                                       else group_size),
                        **metric_fields(path, reference_logits, reference_output, k, v),
                        **storage_fields(4, granularity, group_size, scale_format,
                                         context_len),
                    })

            for block in HADAMARD_BLOCKS:
                for group_size in HADAMARD_GROUPS:
                    granularity = "token" if group_size == HEAD_DIM else "group"
                    metadata = {"seed": seed, "context_len": context_len,
                                "distribution": distribution}
                    path = transformed_path(q, k, v, 4, granularity,
                                            None if granularity == "token" else group_size,
                                            "Q8.8", block, metadata)
                    stages = 0 if block is None else int(math.log2(block))
                    hadamard_rows.append({
                        **common,
                        "kv_bits": 4,
                        "scale_format": "Q8.8",
                        "hadamard": "none" if block is None else f"H{block}",
                        "hadamard_block": 1 if block is None else block,
                        "granularity": f"group{group_size}",
                        "group_size": group_size,
                        **metric_fields(path, reference_logits, reference_output, k, v),
                        **storage_fields(4, granularity,
                                         None if granularity == "token" else group_size,
                                         "Q8.8", context_len),
                        "estimated_hadamard_stages": stages,
                        "estimated_hadamard_butterflies_per_vector": 32 * stages,
                        "estimated_hadamard_addsub_outputs_per_vector": 64 * stages,
                    })

    metrics = ("normalized_qk_logit_rmse",
               "attention_output_relative_rmse",
               "attention_output_cosine",
               "scale_only_qk_logit_rmse",
               "scale_only_attention_output_rmse")
    scale_pareto = aggregate(scale_rows, ("granularity", "scale_format"), metrics)
    hadamard_pareto = aggregate(hadamard_rows, ("hadamard", "granularity"), metrics)
    decorate_scale_pareto(scale_pareto)
    decorate_hadamard_pareto(hadamard_pareto)
    storage_rows = storage_table()
    layout_rows = layout_table()

    outputs = {
        "kv-v02-numerical.csv": numerical_rows,
        "kv-v02-scale-granularity.csv": scale_rows,
        "kv-v02-int4-pareto.csv": scale_pareto,
        "kv-v02-hadamard.csv": hadamard_rows,
        "kv-v02-hadamard-pareto.csv": hadamard_pareto,
        "kv-v02-storage.csv": storage_rows,
        "kv-v02-layout.csv": layout_rows,
    }
    for filename, rows in outputs.items():
        write_csv(args.output_dir / filename, rows)

    source_bytes = (Path(__file__).read_bytes() +
                    (Path(__file__).parent / "kv_quant_reference.py").read_bytes())
    report = {
        "schema_version": 1,
        "warning": "Synthetic numerical experiments; not model accuracy or perplexity.",
        "configuration": {
            "base_seed": BASE_SEED,
            "head_dim": HEAD_DIM,
            "context_lengths": CONTEXT_LENGTHS,
            "distributions": DISTRIBUTIONS,
            "kv_bits": KV_BITS,
            "scale_formats": SCALE_FORMATS,
            "granularities": [label for _, _, label in GRANULARITIES],
            "hadamard_blocks": [1 if value is None else value
                                for value in HADAMARD_BLOCKS],
            "q_quantization": "INT8 per-token symmetric absmax, FP32 scale",
            "kv_quantization": ("symmetric narrow range, round-to-nearest-even; "
                                "cross-bit sweep uses FP16 scales"),
            "vector_normalization": "synthetic Q/K/V RMS-normalized per vector",
            "dither": "disabled; provider interface only; exact G_B mapping TODO",
        },
        "provenance": {
            "git_head_before_analysis_commit": git_head(repo_root),
            "python": platform.python_version(),
            "numpy": np.__version__,
            "platform": platform.platform(),
            "analysis_source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        },
        "tables": {
            "numerical": numerical_rows,
            "scale_granularity": scale_rows,
            "int4_pareto": scale_pareto,
            "hadamard": hadamard_rows,
            "hadamard_pareto": hadamard_pareto,
            "storage": storage_rows,
            "layout": layout_rows,
        },
    }
    json_path = args.output_dir / "kv-v02-analysis.json"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n",
                         encoding="utf-8")
    print(f"wrote {sum(len(rows) for rows in outputs.values())} CSV rows")
    print(json_path)


if __name__ == "__main__":
    main()
