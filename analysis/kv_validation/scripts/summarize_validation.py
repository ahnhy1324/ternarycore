#!/usr/bin/env python3
"""Create compact machine-readable summaries from raw validation rows."""

from __future__ import annotations

import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

import numpy as np


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields: list[str] = []
    for row in rows:
        for field in row:
            if field not in fields:
                fields.append(field)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def stats(values: list[float], prefix: str) -> dict[str, float]:
    array = np.asarray(values, dtype=np.float64)
    return {
        f"mean_{prefix}": float(np.mean(array)),
        f"p95_{prefix}": float(np.percentile(array, 95)),
        f"worst_{prefix}": float(np.max(array)),
    }


def path_summary(rows: list[dict[str, str]], tensor: str) -> list[dict[str, Any]]:
    reconstruction = (f"{tensor.lower()}_tensor_reconstruction_relative_rmse")
    output: list[dict[str, Any]] = []
    for bits in (3, 4, 5, 8):
        members = [row for row in rows
                   if row["split"] == "evaluation" and int(row["bits"]) == bits]
        record: dict[str, Any] = {
            "evidence": "SOFTWARE-SYNTHETIC",
            "path": f"{tensor}-only",
            "bits": bits,
            "evaluation_samples": len(members),
        }
        for field in (reconstruction, "qk_score_relative_rmse",
                      "attention_probability_relative_rmse",
                      "attention_output_relative_rmse"):
            record.update(stats([float(row[field]) for row in members], field))
        record["mean_attention_output_cosine"] = float(np.mean(
            [float(row["attention_output_cosine"]) for row in members]))
        record["top_attended_token_preservation_rate"] = float(np.mean(
            [row["top_attended_token_preserved"] == "True" for row in members]))
        output.append(record)
    return output


def factor_summary(rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for path_name, path_rows in (("K-only", rows[0]), ("V-only", rows[1])):
        for bits in (3, 4, 5, 8):
            selected = [row for row in path_rows
                        if row["split"] == "evaluation" and
                        int(row["bits"]) == bits]
            for factor in ("context_len", "regime", "family"):
                groups: dict[str, list[dict[str, str]]] = defaultdict(list)
                for row in selected:
                    groups[row[factor]].append(row)
                for value, members in groups.items():
                    errors = [float(row["attention_output_relative_rmse"])
                              for row in members]
                    output.append({
                        "evidence": "SOFTWARE-SYNTHETIC",
                        "path": path_name,
                        "bits": bits,
                        "factor": factor,
                        "factor_value": value,
                        "evaluation_samples": len(members),
                        **stats(errors, "attention_output_relative_rmse"),
                    })
    return output


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation")
    args = parser.parse_args()
    synthetic = args.output / "synthetic"
    pareto = args.output / "pareto"
    real_model = args.output / "real_model"
    k_rows = read_csv(synthetic / "k_only_results.csv")
    v_rows = read_csv(synthetic / "v_only_results.csv")
    k_summary = path_summary(k_rows, "K")
    v_summary = path_summary(v_rows, "V")
    factor_rows = factor_summary((k_rows, v_rows))
    write_csv(pareto / "k_only_summary.csv", k_summary)
    write_csv(pareto / "v_only_summary.csv", v_summary)
    write_csv(pareto / "kv_factor_breakdown.csv", factor_rows)

    scale_raw = read_csv(synthetic / "scale_representation_results.csv")
    scale_summary: list[dict[str, Any]] = []
    for granularity in ("token", "run"):
        members = [row for row in scale_raw
                   if row["split"] == "evaluation" and
                   row["scale_granularity"] == granularity]
        record: dict[str, Any] = {
            "evidence": "SOFTWARE-FIXED-POINT",
            "granularity": granularity,
            "evaluation_samples": len(members),
            "metadata_bytes_per_token_per_kv_head": float(
                members[0]["metadata_bytes_per_token_per_kv_head"]),
            "effective_bits_per_value": float(
                members[0]["effective_bits_per_value"]),
            "q8_8_scale_saturation_total": sum(
                int(row["q8_8_scale_saturation_count"]) for row in members),
        }
        for field in ("quantization_only_output_relative_rmse",
                      "scale_representation_only_output_relative_rmse",
                      "total_output_relative_rmse",
                      "quantization_only_qk_score_relative_rmse",
                      "scale_representation_only_qk_score_relative_rmse",
                      "total_qk_score_relative_rmse"):
            record.update(stats([float(row[field]) for row in members], field))
        scale_summary.append(record)
    write_csv(pareto / "scale_representation_summary_head128.csv", scale_summary)

    weight_rows = read_csv(real_model / "checkpoint_projection_weight_stats.csv")
    weight_summary: list[dict[str, Any]] = []
    for projection in ("q_proj", "k_proj", "v_proj"):
        members = [row for row in weight_rows if row["projection"] == projection]
        weight_summary.append({
            "evidence": "REAL-MODEL-VALIDATED/checkpoint-weight-storage",
            "projection": projection,
            "layers": len(members),
            "mean_minus_one_fraction": float(np.mean(
                [float(row["minus_one_fraction"]) for row in members])),
            "mean_zero_fraction": float(np.mean(
                [float(row["zero_fraction"]) for row in members])),
            "mean_plus_one_fraction": float(np.mean(
                [float(row["plus_one_fraction"]) for row in members])),
            "max_invalid_code3_fraction": float(np.max(
                [float(row["invalid_code3_fraction"]) for row in members])),
            "minimum_weight_scale": float(np.min(
                [float(row["weight_scale"]) for row in members])),
            "maximum_weight_scale": float(np.max(
                [float(row["weight_scale"]) for row in members])),
        })
    write_csv(real_model / "checkpoint_projection_weight_summary.csv",
              weight_summary)
    aggregate_path = real_model / "aggregate_context128_512" / "summary.json"
    aggregate_real_model = json.loads(aggregate_path.read_text(
        encoding="utf-8")) if aggregate_path.is_file() else None
    summary = {
        "evidence_boundary": {
            "k_v_numerics": "SOFTWARE-SYNTHETIC",
            "q8_8_scale_screen": "SOFTWARE-FIXED-POINT behavioral; not RTL bit-exact",
            "checkpoint_weights": "REAL-MODEL-VALIDATED stored weights only",
            "real_activations": (
                "REAL-MODEL-VALIDATED/custom-streaming-reference at contexts 128 and 512; "
                "contexts 1024/2048/4096 NOT_TESTED"
                if aggregate_real_model is not None else "NOT_TESTED"),
        },
        "k_only": k_summary,
        "v_only": v_summary,
        "scale": scale_summary,
        "checkpoint_projection_weights": weight_summary,
        "real_model": aggregate_real_model,
    }
    (args.output / "validation_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("wrote compact validation summaries")


if __name__ == "__main__":
    main()
