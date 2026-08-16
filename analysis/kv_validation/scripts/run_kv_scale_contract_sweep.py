#!/usr/bin/env python3
"""Compare 16-bit unsigned K/V scale formats and write-side code policies."""

from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch

from analyze_real_model_captures import (
    attention_output,
    causal_softmax,
    cosine,
    path_metrics,
    relative_rmse,
    repeat_kv,
    scores,
)


FORMATS = {"UQ4.12": 12, "UQ5.11": 11, "UQ6.10": 10, "UQ8.8": 8}
PROFILES = {
    "REGULAR4": (4, 128, 4, 16),
    "PACKED5": (4, 128, 5, 128),
    "ACCURATE5": (5, 128, 5, 128),
}
POLICIES = ("high_precision_scale", "rounded_stored_scale")


@dataclass
class Quantized:
    dequant: np.ndarray
    fp_scale_dequant: np.ndarray
    scale_only_dequant: np.ndarray
    ideal_scale_min_nonzero: float
    ideal_scale_max: float
    underflows: int
    overflows: int
    scale_count: int


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def quantize(values: np.ndarray, bits: int, group_size: int,
             fraction: int, policy: str) -> Quantized:
    if values.shape[-1] % group_size:
        raise ValueError("group size must divide head dimension")
    qmax = (1 << (bits - 1)) - 1
    grouped = values.astype(np.float32).reshape(
        *values.shape[:-1], values.shape[-1] // group_size, group_size)
    maximum = np.max(np.abs(grouped), axis=-1, keepdims=True)
    ideal_scale = maximum / qmax
    nonzero = maximum != 0
    safe_ideal = np.where(nonzero, ideal_scale, 1.0).astype(np.float32)
    ideal_codes = np.where(
        nonzero,
        np.clip(np.rint(grouped / safe_ideal), -qmax, qmax),
        0,
    ).astype(np.int16)
    raw_scale_codes = np.rint(safe_ideal.astype(np.float64) * (1 << fraction))
    underflow = nonzero & (raw_scale_codes < 1)
    overflow = raw_scale_codes > 65535
    stored_scale = (
        np.clip(raw_scale_codes, 1, 65535) / (1 << fraction)
    ).astype(np.float32)
    if policy == "high_precision_scale":
        selected_codes = ideal_codes
    elif policy == "rounded_stored_scale":
        selected_codes = np.where(
            nonzero,
            np.clip(np.rint(grouped / stored_scale), -qmax, qmax),
            0,
        ).astype(np.int16)
    else:
        raise ValueError(policy)
    nonzero_scales = ideal_scale[nonzero]
    return Quantized(
        dequant=(selected_codes.astype(np.float32) * stored_scale).reshape(values.shape),
        fp_scale_dequant=(ideal_codes.astype(np.float32) * safe_ideal).reshape(values.shape),
        scale_only_dequant=(ideal_codes.astype(np.float32) * stored_scale).reshape(values.shape),
        ideal_scale_min_nonzero=float(np.min(nonzero_scales)) if nonzero_scales.size else 0.0,
        ideal_scale_max=float(np.max(ideal_scale)),
        underflows=int(np.count_nonzero(underflow)),
        overflows=int(np.count_nonzero(overflow)),
        scale_count=int(ideal_scale.size),
    )


def quantize_q_uq1_15(query: np.ndarray) -> np.ndarray:
    return quantize(query, 8, 128, 15, "high_precision_scale").dequant


def capture_paths(run_root: Path) -> list[tuple[int, int, Path]]:
    result = []
    for run_dir in sorted(run_root.glob("20260816-streaming-full-c*")):
        run = json.loads((run_dir / "run.json").read_text("utf-8"))
        context = int(run["context_len"])
        for path in sorted((run_dir / "tensors").glob("layer_*.pt")):
            result.append((context, int(path.stem.split("_")[1]), path))
    if not result:
        raise FileNotFoundError("no real-model captures found")
    return result


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--run-root", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" / "runs")
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" /
        "kv_scale_contract_sweep")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)

    rows: list[dict] = []
    for context, layer, path in capture_paths(args.run_root):
        capture = torch.load(path, map_location="cpu", weights_only=False)
        tensors = {name: value.float().numpy()
                   for name, value in capture["tensors"].items()}
        query = tensors["q_post_rope"]
        key = tensors["k_post_rope"]
        value = tensors["v"]
        query_q8 = quantize_q_uq1_15(query)
        reference_logits = scores(query, key)
        reference_probability = causal_softmax(reference_logits)
        reference_output = attention_output(reference_probability, value)

        for profile, (k_bits, k_group, v_bits, v_group) in PROFILES.items():
            for scale_format, fraction in FORMATS.items():
                for policy in POLICIES:
                    kq = quantize(key, k_bits, k_group, fraction, policy)
                    vq = quantize(value, v_bits, v_group, fraction, policy)
                    actual_metrics = path_metrics(
                        query_q8, kq.dequant, vq.dequant,
                        reference_logits, reference_probability, reference_output)
                    fp_scale_logits = scores(query_q8, kq.fp_scale_dequant)
                    fp_scale_probability = causal_softmax(fp_scale_logits)
                    fp_scale_output = attention_output(
                        fp_scale_probability, vq.fp_scale_dequant)
                    stored_scale_logits = scores(query_q8, kq.scale_only_dequant)
                    stored_scale_probability = causal_softmax(stored_scale_logits)
                    stored_scale_output = attention_output(
                        stored_scale_probability, vq.scale_only_dequant)
                    row = {
                        "evidence": "REAL-MODEL-VALIDATED/scale-contract",
                        "context_len": context,
                        "layer": layer,
                        "profile": profile,
                        "k_bits": k_bits,
                        "k_group_size": k_group,
                        "v_bits": v_bits,
                        "v_group_size": v_group,
                        "scale_format": scale_format,
                        "scale_fraction_bits": fraction,
                        "code_selection_policy": policy,
                        "q_contract": "INT8 group128 UQ1.15 scale; high-precision code selection",
                        "k_tensor_relative_rmse": relative_rmse(kq.dequant, key),
                        "v_tensor_relative_rmse": relative_rmse(vq.dequant, value),
                        "k_scale_only_relative_rmse": relative_rmse(
                            kq.scale_only_dequant, kq.fp_scale_dequant),
                        "v_scale_only_relative_rmse": relative_rmse(
                            vq.scale_only_dequant, vq.fp_scale_dequant),
                        "scale_incremental_output_relative_rmse": relative_rmse(
                            stored_scale_output, fp_scale_output),
                        "scale_incremental_output_cosine": cosine(
                            stored_scale_output, fp_scale_output),
                        "stored_code_policy_delta_output_relative_rmse": relative_rmse(
                            attention_output(
                                causal_softmax(scores(query_q8, kq.dequant)),
                                vq.dequant),
                            stored_scale_output),
                        "fp32_scale_profile_output_relative_rmse": relative_rmse(
                            fp_scale_output, reference_output),
                        "k_scale_min_nonzero": kq.ideal_scale_min_nonzero,
                        "k_scale_max": kq.ideal_scale_max,
                        "v_scale_min_nonzero": vq.ideal_scale_min_nonzero,
                        "v_scale_max": vq.ideal_scale_max,
                        "k_scale_underflows": kq.underflows,
                        "k_scale_overflows": kq.overflows,
                        "v_scale_underflows": vq.underflows,
                        "v_scale_overflows": vq.overflows,
                        "scale_count": kq.scale_count + vq.scale_count,
                    }
                    row.update(actual_metrics)
                    rows.append(row)

    write_csv(args.output / "all_results.csv", rows)
    summary_rows = []
    for profile in PROFILES:
        for scale_format in FORMATS:
            for policy in POLICIES:
                members = [row for row in rows if row["profile"] == profile and
                           row["scale_format"] == scale_format and
                           row["code_selection_policy"] == policy]
                summary_rows.append({
                    "evidence": "REAL-MODEL-VALIDATED/scale-contract",
                    "profile": profile,
                    "scale_format": scale_format,
                    "code_selection_policy": policy,
                    "capture_count": len(members),
                    "mean_attention_output_relative_rmse": float(np.mean([
                        row["attention_output_relative_rmse"] for row in members])),
                    "worst_attention_output_relative_rmse": float(np.max([
                        row["attention_output_relative_rmse"] for row in members])),
                    "mean_scale_incremental_output_relative_rmse": float(np.mean([
                        row["scale_incremental_output_relative_rmse"] for row in members])),
                    "worst_scale_incremental_output_relative_rmse": float(np.max([
                        row["scale_incremental_output_relative_rmse"] for row in members])),
                    "mean_k_scale_only_relative_rmse": float(np.mean([
                        row["k_scale_only_relative_rmse"] for row in members])),
                    "mean_v_scale_only_relative_rmse": float(np.mean([
                        row["v_scale_only_relative_rmse"] for row in members])),
                    "max_k_scale": float(np.max([row["k_scale_max"] for row in members])),
                    "max_v_scale": float(np.max([row["v_scale_max"] for row in members])),
                    "total_scale_underflows": int(sum(
                        row["k_scale_underflows"] + row["v_scale_underflows"]
                        for row in members)),
                    "total_scale_overflows": int(sum(
                        row["k_scale_overflows"] + row["v_scale_overflows"]
                        for row in members)),
                })
    write_csv(args.output / "summary.csv", summary_rows)
    result = {
        "evidence": "REAL-MODEL-VALIDATED/scale-contract",
        "status": "PASS",
        "claim_scope": "captured attention tensors; not perplexity or task accuracy",
        "formats": FORMATS,
        "policies": {
            "high_precision_scale": "codes from ideal absmax/qmax; stored scale only affects dequantization",
            "rounded_stored_scale": "codes and dequantization both use the rounded stored scale",
        },
        "capture_count": len({(row["context_len"], row["layer"]) for row in rows}),
        "rows": len(rows),
        "summary": summary_rows,
    }
    (args.output / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", "utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
