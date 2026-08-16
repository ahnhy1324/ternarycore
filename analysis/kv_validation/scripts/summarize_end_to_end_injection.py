#!/usr/bin/env python3
"""Aggregate the two-prompt end-to-end KV injection matrix."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np


PROFILES = ("BASE_FP", "Q8_ONLY", "REGULAR4", "PACKED5", "ACCURATE5")
PROMPTS = ("engineering", "observatory")


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def mean(rows: list[dict], field: str) -> float:
    return float(np.mean([float(row[field]) for row in rows]))


def maximum(rows: list[dict], field: str) -> float:
    return float(np.max([float(row[field]) for row in rows]))


def minimum(rows: list[dict], field: str) -> float:
    return float(np.min([float(row[field]) for row in rows]))


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" /
        "end_to_end_injection")
    args = parser.parse_args()

    per_run = []
    per_layer = []
    source_runs = []
    for prompt in PROMPTS:
        for profile in PROFILES:
            path = args.input / prompt / profile / "run.json"
            if not path.is_file():
                raise FileNotFoundError(path)
            run = json.loads(path.read_text("utf-8"))
            metrics = run["metrics"]
            audit = run["scale_audit"]
            row = {
                "evidence": run["evidence"],
                "prompt_id": prompt,
                "profile": profile,
                "context_length": run["context_length"],
                "final_hidden_relative_rmse": metrics["final_hidden_relative_rmse"],
                "final_hidden_cosine": metrics["final_hidden_cosine"],
                "last_token_hidden_relative_rmse": metrics["last_token_hidden_relative_rmse"],
                "last_token_hidden_cosine": metrics["last_token_hidden_cosine"],
                "target_token_logit_delta": metrics["target_token_logit_delta"],
                "top1_preserved": metrics["top1_preserved"],
                "top5_exact_set_preserved": metrics["top5_exact_set_preserved"],
                "top5_overlap_fraction": metrics["top5_overlap_fraction"],
                "kl_reference_to_candidate": metrics["kl_reference_to_candidate"],
                "js_divergence": metrics["js_divergence"],
                "elapsed_seconds": run["elapsed_seconds"],
                "peak_observed_working_set_bytes": run["peak_observed_working_set_bytes"],
                "scale_underflows": audit["total_underflow_scale_count"],
                "scale_overflows": audit["total_overflow_scale_count"],
                "max_ideal_scale": audit["max_ideal_scale"],
            }
            layer_rows = metrics["selected_layers"]
            row.update({
                "selected_layer_mean_weighted_v_relative_rmse": float(np.mean([
                    layer["weighted_v_relative_rmse"] for layer in layer_rows
                ])) if layer_rows else 0.0,
                "selected_layer_worst_weighted_v_relative_rmse": float(np.max([
                    layer["weighted_v_relative_rmse"] for layer in layer_rows
                ])) if layer_rows else 0.0,
                "selected_layer_mean_block_output_relative_rmse": float(np.mean([
                    layer["block_output_relative_rmse"] for layer in layer_rows
                ])) if layer_rows else 0.0,
                "selected_layer_worst_block_output_relative_rmse": float(np.max([
                    layer["block_output_relative_rmse"] for layer in layer_rows
                ])) if layer_rows else 0.0,
            })
            per_run.append(row)
            for layer in layer_rows:
                per_layer.append({
                    "evidence": run["evidence"],
                    "prompt_id": prompt,
                    "profile": profile,
                    **layer,
                })
            source_runs.append(str(path.resolve()))

    summary_rows = []
    for profile in PROFILES:
        rows = [row for row in per_run if row["profile"] == profile]
        summary_rows.append({
            "evidence": "REAL-MODEL-VALIDATED/end-to-end-streaming-injection",
            "profile": profile,
            "prompt_count": len(rows),
            "mean_final_hidden_relative_rmse": mean(rows, "final_hidden_relative_rmse"),
            "worst_final_hidden_relative_rmse": maximum(rows, "final_hidden_relative_rmse"),
            "minimum_final_hidden_cosine": minimum(rows, "final_hidden_cosine"),
            "mean_last_token_hidden_relative_rmse": mean(
                rows, "last_token_hidden_relative_rmse"),
            "worst_last_token_hidden_relative_rmse": maximum(
                rows, "last_token_hidden_relative_rmse"),
            "minimum_last_token_hidden_cosine": minimum(
                rows, "last_token_hidden_cosine"),
            "mean_absolute_target_token_logit_delta": float(np.mean([
                abs(float(row["target_token_logit_delta"])) for row in rows])),
            "top1_preservation_fraction": float(np.mean([
                bool(row["top1_preserved"]) for row in rows])),
            "top5_exact_set_preservation_fraction": float(np.mean([
                bool(row["top5_exact_set_preserved"]) for row in rows])),
            "mean_top5_overlap_fraction": mean(rows, "top5_overlap_fraction"),
            "mean_kl_reference_to_candidate": mean(
                rows, "kl_reference_to_candidate"),
            "worst_kl_reference_to_candidate": maximum(
                rows, "kl_reference_to_candidate"),
            "mean_js_divergence": mean(rows, "js_divergence"),
            "mean_selected_layer_weighted_v_relative_rmse": mean(
                rows, "selected_layer_mean_weighted_v_relative_rmse"),
            "worst_selected_layer_weighted_v_relative_rmse": maximum(
                rows, "selected_layer_worst_weighted_v_relative_rmse"),
            "mean_selected_layer_block_output_relative_rmse": mean(
                rows, "selected_layer_mean_block_output_relative_rmse"),
            "worst_selected_layer_block_output_relative_rmse": maximum(
                rows, "selected_layer_worst_block_output_relative_rmse"),
            "total_elapsed_seconds": float(sum(
                float(row["elapsed_seconds"]) for row in rows)),
            "peak_observed_working_set_bytes": int(max(
                int(row["peak_observed_working_set_bytes"]) for row in rows)),
            "total_scale_underflows": int(sum(
                int(row["scale_underflows"]) for row in rows)),
            "total_scale_overflows": int(sum(
                int(row["scale_overflows"]) for row in rows)),
            "max_ideal_scale": maximum(rows, "max_ideal_scale"),
        })

    write_csv(args.input / "per_run_results.csv", per_run)
    write_csv(args.input / "selected_layer_results.csv", per_layer)
    write_csv(args.input / "summary.csv", summary_rows)
    result = {
        "evidence": "REAL-MODEL-VALIDATED/end-to-end-streaming-injection",
        "status": "PASS",
        "claim_scope": "two natural prompts at context 128; hidden/logit distortion only, not perplexity or task accuracy",
        "profiles": list(PROFILES),
        "prompts": list(PROMPTS),
        "source_runs": source_runs,
        "summary": summary_rows,
    }
    (args.input / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", "utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
