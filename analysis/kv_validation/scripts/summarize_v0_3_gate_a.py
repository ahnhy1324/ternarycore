#!/usr/bin/env python3
"""Aggregate the complete v0.3 Gate A real-model and page-codec results."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np


REQUIRED_PROFILES = (
    "PACKED5_RAW_UQ5_11",
    "PACKED5_RAW_UQ4_8",
    "PACKED5_PAGE64_UQ4_8",
    "PACKED5_PAGE128_UQ4_8",
)
UQ4_EXECUTION = "PACKED5_PAGE128_UQ4_8"


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        raise ValueError(f"refusing to create empty CSV: {path}")
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
        "--prompt-record", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "prompts_and_token_ids.json")
    parser.add_argument(
        "--input", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "results" / "gate_a")
    args = parser.parse_args()

    prompt_data = json.loads(args.prompt_record.read_text(encoding="utf-8"))
    expected_cases = [
        (prompt["prompt_id"], int(context))
        for prompt in prompt_data["prompts"]
        for context in prompt["contexts"]
    ]
    if sum(context == 128 for _, context in expected_cases) < 8:
        raise AssertionError("Gate A requires at least eight context-128 prompts")
    if sum(context == 512 for _, context in expected_cases) < 2:
        raise AssertionError("Gate A requires at least two context-512 prompts")

    per_run = []
    per_layer = []
    page_rows = []
    source_runs = []
    for prompt, context in expected_cases:
        for execution_profile in ("PACKED5_RAW_UQ5_11", UQ4_EXECUTION):
            path = (args.input / f"context_{context:04d}" / prompt /
                    execution_profile / "run.json")
            if not path.is_file():
                raise FileNotFoundError(path)
            run = json.loads(path.read_text(encoding="utf-8"))
            if run.get("status") != "PASS":
                raise AssertionError(f"non-PASS source run: {path}")
            metrics = run["metrics"]
            codec = run["cache_codec_audit"]
            scale = codec["stored_scale_distribution"]
            profiles = run["equivalent_required_profiles"]
            if execution_profile == UQ4_EXECUTION:
                expected_aliases = {
                    "PACKED5_RAW_UQ4_8", "PACKED5_PAGE64_UQ4_8",
                    "PACKED5_PAGE128_UQ4_8"}
                if set(profiles) != expected_aliases:
                    raise AssertionError("UQ4.8 required-profile alias set is incomplete")
                for page_tokens in ("64", "128"):
                    if not codec["page_roundtrip"][page_tokens]["bit_identical"]:
                        raise AssertionError("raw/page K/V code or scale mismatch")
            selected = metrics["selected_layers"]
            selected_attention = [
                row["attention_output_relative_rmse"] for row in selected]
            selected_block = [
                row["block_output_relative_rmse"] for row in selected]
            for profile in profiles:
                is_page = "PAGE" in profile
                page_tokens = 64 if "PAGE64" in profile else 128
                page = (codec["page_roundtrip"][str(page_tokens)]
                        if is_page else None)
                row = {
                    "evidence": run["evidence"],
                    "prompt_id": prompt,
                    "context_length": context,
                    "profile": profile,
                    "execution_profile": execution_profile,
                    "metrics_reused_only_after_bit_identity": (
                        execution_profile == UQ4_EXECUTION),
                    "final_hidden_relative_rmse": metrics[
                        "final_hidden_relative_rmse"],
                    "final_hidden_cosine": metrics["final_hidden_cosine"],
                    "last_token_hidden_relative_rmse": metrics[
                        "last_token_hidden_relative_rmse"],
                    "last_token_hidden_cosine": metrics[
                        "last_token_hidden_cosine"],
                    "selected_layer_mean_attention_output_relative_rmse": float(
                        np.mean(selected_attention)),
                    "selected_layer_worst_attention_output_relative_rmse": float(
                        np.max(selected_attention)),
                    "selected_layer_mean_block_output_relative_rmse": float(
                        np.mean(selected_block)),
                    "selected_layer_worst_block_output_relative_rmse": float(
                        np.max(selected_block)),
                    "target_token_logit_delta": metrics[
                        "target_token_logit_delta"],
                    "top1_preserved": metrics["top1_preserved"],
                    "top5_exact_set_preserved": metrics[
                        "top5_exact_set_preserved"],
                    "top5_overlap_fraction": metrics["top5_overlap_fraction"],
                    "kl_reference_to_candidate": metrics[
                        "kl_reference_to_candidate"],
                    "js_divergence": metrics["js_divergence"],
                    "k_scale_min": scale["K"]["min"],
                    "k_scale_p1": scale["K"]["p1"],
                    "k_scale_p5": scale["K"]["p5"],
                    "k_scale_median": scale["K"]["median"],
                    "k_scale_p95": scale["K"]["p95"],
                    "k_scale_p99": scale["K"]["p99"],
                    "k_scale_max": scale["K"]["max"],
                    "v_scale_min": scale["V"]["min"],
                    "v_scale_p1": scale["V"]["p1"],
                    "v_scale_p5": scale["V"]["p5"],
                    "v_scale_median": scale["V"]["median"],
                    "v_scale_p95": scale["V"]["p95"],
                    "v_scale_p99": scale["V"]["p99"],
                    "v_scale_max": scale["V"]["max"],
                    "scale_underflow_rate": run["scale_audit"][
                        "kv_underflow_rate"],
                    "scale_overflow_rate": run["scale_audit"][
                        "kv_overflow_rate"],
                    "page_average_record_bytes": (
                        np.mean([
                            page["streams"]["K"]["average_record_bytes"],
                            page["streams"]["V"]["average_record_bytes"],
                        ]) if page else 0.0),
                    "page_p95_record_bytes": (
                        max(page["streams"]["K"]["p95_record_bytes"],
                            page["streams"]["V"]["p95_record_bytes"])
                        if page else 0.0),
                    "page_worst_record_bytes": (
                        max(page["streams"]["K"]["worst_record_bytes"],
                            page["streams"]["V"]["worst_record_bytes"])
                        if page else 0),
                    "page_maximum_bounded_record_bytes": (
                        max(page["streams"]["K"]["maximum_bounded_record_bytes"],
                            page["streams"]["V"]["maximum_bounded_record_bytes"])
                        if page else 0),
                    "raw_page_fallback_rate": (
                        (page["streams"]["K"]["raw_pages"] +
                         page["streams"]["V"]["raw_pages"]) /
                        (page["streams"]["K"]["pages"] +
                         page["streams"]["V"]["pages"])
                        if page else 0.0),
                    "elapsed_seconds": run["elapsed_seconds"],
                    "peak_resident_bytes": run[
                        "peak_observed_working_set_bytes"],
                }
                per_run.append(row)
                for layer in selected:
                    per_layer.append({
                        "evidence": run["evidence"],
                        "prompt_id": prompt,
                        "context_length": context,
                        "profile": profile,
                        **layer,
                    })
                if page:
                    k = page["streams"]["K"]
                    v = page["streams"]["V"]
                    page_rows.append({
                        "evidence": "REAL-MODEL-VALIDATED/v0.3-page-accounting",
                        "prompt_id": prompt,
                        "context_length": context,
                        "profile": profile,
                        "page_tokens": page_tokens,
                        "k_pages": k["pages"],
                        "v_pages": v["pages"],
                        "k_raw_pages": k["raw_pages"],
                        "v_raw_pages": v["raw_pages"],
                        "k_raw_fallback_fraction": k["raw_fallback_fraction"],
                        "v_raw_fallback_fraction": v["raw_fallback_fraction"],
                        "k_full_bytes_per_token": k["full_bytes_per_token"],
                        "v_full_bytes_per_token": v["full_bytes_per_token"],
                        "combined_full_bytes_per_token": (
                            k["full_bytes_per_token"] +
                            v["full_bytes_per_token"]),
                        "effective_bits_per_value": (
                            (k["full_bytes_per_token"] +
                             v["full_bytes_per_token"]) * 8 / 256),
                        "k_average_record_bytes": k["average_record_bytes"],
                        "v_average_record_bytes": v["average_record_bytes"],
                        "k_p95_record_bytes": k["p95_record_bytes"],
                        "v_p95_record_bytes": v["p95_record_bytes"],
                        "k_worst_record_bytes": k["worst_record_bytes"],
                        "v_worst_record_bytes": v["worst_record_bytes"],
                        "k_maximum_bounded_record_bytes": k[
                            "maximum_bounded_record_bytes"],
                        "v_maximum_bounded_record_bytes": v[
                            "maximum_bounded_record_bytes"],
                        "crc_and_metadata_included": True,
                    })
            source_runs.append(str(path.resolve()))

    summary_rows = []
    for profile in REQUIRED_PROFILES:
        rows = [row for row in per_run if row["profile"] == profile]
        if len(rows) != len(expected_cases):
            raise AssertionError(f"{profile} has {len(rows)} incomplete cases")
        summary_rows.append({
            "evidence": "REAL-MODEL-VALIDATED/v0.3-gate-a",
            "profile": profile,
            "prompt_context_cases": len(rows),
            "unique_prompts": len({row["prompt_id"] for row in rows}),
            "context128_prompts": sum(
                row["context_length"] == 128 for row in rows),
            "context512_prompts": sum(
                row["context_length"] == 512 for row in rows),
            "mean_final_hidden_relative_rmse": mean(
                rows, "final_hidden_relative_rmse"),
            "worst_final_hidden_relative_rmse": maximum(
                rows, "final_hidden_relative_rmse"),
            "minimum_final_hidden_cosine": minimum(rows, "final_hidden_cosine"),
            "mean_last_token_hidden_relative_rmse": mean(
                rows, "last_token_hidden_relative_rmse"),
            "worst_last_token_hidden_relative_rmse": maximum(
                rows, "last_token_hidden_relative_rmse"),
            "minimum_last_token_hidden_cosine": minimum(
                rows, "last_token_hidden_cosine"),
            "mean_selected_layer_attention_output_relative_rmse": mean(
                rows, "selected_layer_mean_attention_output_relative_rmse"),
            "worst_selected_layer_attention_output_relative_rmse": maximum(
                rows, "selected_layer_worst_attention_output_relative_rmse"),
            "mean_selected_layer_block_output_relative_rmse": mean(
                rows, "selected_layer_mean_block_output_relative_rmse"),
            "worst_selected_layer_block_output_relative_rmse": maximum(
                rows, "selected_layer_worst_block_output_relative_rmse"),
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
            "scale_underflow_rate": (
                sum(float(row["scale_underflow_rate"]) for row in rows) /
                len(rows)),
            "scale_overflow_rate": (
                sum(float(row["scale_overflow_rate"]) for row in rows) /
                len(rows)),
            "raw_page_fallback_rate": (
                mean(rows, "raw_page_fallback_rate") if "PAGE" in profile else 0.0),
            "total_elapsed_seconds_of_unique_execution": sum(
                float(row["elapsed_seconds"]) for row in rows),
            "peak_resident_bytes": max(
                int(row["peak_resident_bytes"]) for row in rows),
        })

    page_summary = []
    for profile in ("PACKED5_PAGE64_UQ4_8", "PACKED5_PAGE128_UQ4_8"):
        rows = [row for row in page_rows if row["profile"] == profile]
        page_summary.append({
            "evidence": "REAL-MODEL-VALIDATED/v0.3-page-accounting",
            "profile": profile,
            "cases": len(rows),
            "mean_combined_full_bytes_per_token": mean(
                rows, "combined_full_bytes_per_token"),
            "mean_k_full_bytes_per_token": mean(
                rows, "k_full_bytes_per_token"),
            "mean_v_full_bytes_per_token": mean(
                rows, "v_full_bytes_per_token"),
            "p95_case_combined_full_bytes_per_token": float(np.percentile(
                [row["combined_full_bytes_per_token"] for row in rows], 95)),
            "worst_combined_full_bytes_per_token": maximum(
                rows, "combined_full_bytes_per_token"),
            "mean_effective_bits_per_value": mean(
                rows, "effective_bits_per_value"),
            "mean_k_raw_fallback_fraction": mean(
                rows, "k_raw_fallback_fraction"),
            "mean_v_raw_fallback_fraction": mean(
                rows, "v_raw_fallback_fraction"),
            "worst_k_page_record_bytes": int(maximum(
                rows, "k_worst_record_bytes")),
            "worst_v_page_record_bytes": int(maximum(
                rows, "v_worst_record_bytes")),
            "bounded_k_page_record_bytes": int(maximum(
                rows, "k_maximum_bounded_record_bytes")),
            "bounded_v_page_record_bytes": int(maximum(
                rows, "v_maximum_bounded_record_bytes")),
        })

    write_csv(args.input / "gate_a_per_run.csv", per_run)
    write_csv(args.input / "gate_a_selected_layers.csv", per_layer)
    write_csv(args.input / "gate_a_summary.csv", summary_rows)
    write_csv(args.input / "page_accounting_per_run.csv", page_rows)
    write_csv(args.input / "page_accounting_summary.csv", page_summary)
    result = {
        "evidence": "REAL-MODEL-VALIDATED/v0.3-gate-a",
        "status": "PASS",
        "claim_scope": (
            "eight natural prompts at context 128 and two at context 512; "
            "hidden/attention/logit distortion only; not perplexity, task "
            "accuracy, or generation quality"),
        "required_profiles": list(REQUIRED_PROFILES),
        "prompt_context_cases": len(expected_cases),
        "entropy_identity_method": (
            "Every UQ4.8 K/V tensor at every layer and KV head was separately "
            "encoded/decoded through page64 and page128 before attention. "
            "Required-profile metric rows are aliased only after code and scale "
            "arrays and cumulative SHA-256 hashes match."),
        "source_runs": source_runs,
        "summary": summary_rows,
        "page_summary": page_summary,
    }
    (args.input / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
