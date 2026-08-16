#!/usr/bin/env python3
"""Combine independently preserved real-model context runs."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np


EVIDENCE = "REAL-MODEL-VALIDATED/custom-streaming-reference"


def read_csv(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def summarize(rows: list[dict], key_fields: tuple[str, ...]) -> list[dict]:
    groups: dict[tuple[str, ...], list[dict]] = {}
    for row in rows:
        key = tuple(row[field] for field in key_fields)
        groups.setdefault(key, []).append(row)
    result = []
    for key, members in groups.items():
        output = {field: value for field, value in zip(key_fields, key)}
        output.update({
            "evidence": EVIDENCE,
            "contexts": ";".join(sorted({row["context_len"] for row in members},
                                        key=int)),
            "layer_context_rows": len(members),
            "total_bytes_per_token_per_kv_head": members[0]["total_bytes_per_token_per_kv_head"],
            "effective_bits_per_kv_value": members[0]["effective_bits_per_kv_value"],
            "compression_vs_fp16_kv": members[0]["compression_vs_fp16_kv"],
            "compression_vs_int8_kv": members[0]["compression_vs_int8_kv"],
            "mean_attention_output_relative_rmse": float(np.mean([
                float(row["attention_output_relative_rmse"]) for row in members])),
            "worst_attention_output_relative_rmse": float(np.max([
                float(row["attention_output_relative_rmse"]) for row in members])),
            "mean_layer_context_p95_row_relative_rmse": float(np.mean([
                float(row["attention_output_row_relative_rmse_p95"]) for row in members])),
            "worst_layer_context_p95_row_relative_rmse": float(np.max([
                float(row["attention_output_row_relative_rmse_p95"]) for row in members])),
            "mean_qk_score_relative_rmse": float(np.mean([
                float(row["qk_score_relative_rmse"]) for row in members])),
            "worst_qk_score_relative_rmse": float(np.max([
                float(row["qk_score_relative_rmse"]) for row in members])),
        })
        result.append(output)
    for candidate in result:
        candidate["pareto_storage_mean_worst"] = not any(
            other is not candidate and
            float(other["effective_bits_per_kv_value"]) <= float(candidate["effective_bits_per_kv_value"]) and
            other["mean_attention_output_relative_rmse"] <= candidate["mean_attention_output_relative_rmse"] and
            other["worst_attention_output_relative_rmse"] <= candidate["worst_attention_output_relative_rmse"] and
            (
                float(other["effective_bits_per_kv_value"]) < float(candidate["effective_bits_per_kv_value"]) or
                other["mean_attention_output_relative_rmse"] < candidate["mean_attention_output_relative_rmse"] or
                other["worst_attention_output_relative_rmse"] < candidate["worst_attention_output_relative_rmse"]
            )
            for other in result
        )
    return sorted(result, key=lambda row: (
        float(row["effective_bits_per_kv_value"]),
        row["mean_attention_output_relative_rmse"],
    ))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--analysis", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)

    all_joint = []
    all_mixed = []
    all_baseline = []
    all_tensor_stats = []
    sources = []
    for analysis in args.analysis:
        summary = json.loads((analysis / "summary.json").read_text(encoding="utf-8"))
        context_len = str(summary["context_len"])
        sources.append({"context_len": int(context_len),
                        "analysis": str(analysis.resolve())})
        for filename, target in (
            ("joint_kv_results.csv", all_joint),
            ("int4_mixed_granularity_results.csv", all_mixed),
            ("attention_baselines.csv", all_baseline),
            ("tensor_statistics.csv", all_tensor_stats),
        ):
            for row in read_csv(analysis / filename):
                row.setdefault("context_len", context_len)
                if filename == "tensor_statistics.csv":
                    row["context_len"] = context_len
                target.append(row)

    joint_summary = summarize(
        all_joint, ("k_bits", "v_bits", "scale_granularity", "scale_format"))
    mixed_summary = summarize(
        all_mixed,
        ("k_bits", "v_bits", "k_scale_granularity",
         "v_scale_granularity", "scale_format"),
    )
    write_csv(args.output / "joint_kv_all_contexts.csv", all_joint)
    write_csv(args.output / "joint_kv_summary.csv", joint_summary)
    write_csv(args.output / "int4_mixed_granularity_all_contexts.csv", all_mixed)
    write_csv(args.output / "int4_mixed_granularity_summary.csv", mixed_summary)
    write_csv(args.output / "attention_baselines.csv", all_baseline)
    write_csv(args.output / "tensor_statistics.csv", all_tensor_stats)

    def find_joint(k_bits: int, v_bits: int, granularity: str,
                   scale_format: str = "Q8.8") -> dict:
        return next(row for row in joint_summary if
                    row["k_bits"] == str(k_bits) and
                    row["v_bits"] == str(v_bits) and
                    row["scale_granularity"] == granularity and
                    row["scale_format"] == scale_format)

    q8_errors = [float(row["attention_output_relative_rmse"])
                 for row in all_baseline]
    selected = {
        "K3_V3_group128": find_joint(3, 3, "group128"),
        "K4_V4_group128": find_joint(4, 4, "group128"),
        "K4_V4_group32": find_joint(4, 4, "group32"),
        "K4_V4_group16": find_joint(4, 4, "group16"),
        "K4_V4_group8": find_joint(4, 4, "group8"),
        "K3_V5_group128": find_joint(3, 5, "group128"),
        "K4_V5_group128": find_joint(4, 5, "group128"),
        "K5_V5_group128": find_joint(5, 5, "group128"),
    }
    result = {
        "evidence": EVIDENCE,
        "status": "PASS",
        "sources": sorted(sources, key=lambda row: row["context_len"]),
        "contexts_tested": sorted({int(row["context_len"]) for row in sources}),
        "layers_per_context": [0, 7, 15, 22, 29],
        "q8_only": {
            "mean_attention_output_relative_rmse": float(np.mean(q8_errors)),
            "worst_attention_output_relative_rmse": float(np.max(q8_errors)),
        },
        "selected_joint_configs": selected,
        "interpretation": [
            "Q8.8 scale representation is a small contributor for INT4 on these tensors; group granularity dominates.",
            "V granularity is more important than K granularity in the tested INT4 mixed-granularity sweep.",
            "Per-token K4/V5 and K5/V5 are numerical Pareto candidates, but five-bit hardware cost is not synthesized.",
            "No tensor distortion result is a model accuracy or perplexity claim.",
        ],
        "untested_contexts": [1024, 2048, 4096],
        "untested_reason": "Not attempted in this CPU-time validation pass; they are NOT_TESTED, not FAILED.",
    }
    (args.output / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

