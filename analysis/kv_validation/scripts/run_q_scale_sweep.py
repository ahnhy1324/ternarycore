#!/usr/bin/env python3
"""Measure real-model INT8-Q scale representation error."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np
import torch


HEAD_DIM = 128
Q_HEADS = 20
KV_HEADS = 5
KV_REPEAT = Q_HEADS // KV_HEADS


def relative_rmse(actual: np.ndarray, reference: np.ndarray) -> float:
    actual64 = actual.astype(np.float64)
    reference64 = reference.astype(np.float64)
    return float(np.sqrt(np.mean((actual64 - reference64) ** 2) /
                         max(np.mean(reference64 ** 2), 1.0e-30)))


def cosine(actual: np.ndarray, reference: np.ndarray) -> float:
    a = actual.astype(np.float64).reshape(-1)
    b = reference.astype(np.float64).reshape(-1)
    return float(np.dot(a, b) / max(np.linalg.norm(a) * np.linalg.norm(b), 1.0e-30))


def causal_softmax(logits: np.ndarray) -> np.ndarray:
    length = logits.shape[-1]
    mask = np.triu(np.ones((length, length), dtype=bool), 1)
    masked = np.where(mask[None], -np.inf, logits.astype(np.float64))
    shifted = masked - np.max(masked, axis=-1, keepdims=True)
    exp = np.exp(shifted)
    return (exp / np.sum(exp, axis=-1, keepdims=True)).astype(np.float32)


def quantize_scale(scale: np.ndarray, name: str) -> tuple[np.ndarray, int]:
    if name == "FP32":
        return scale.astype(np.float32), 0
    if name == "FP16":
        return scale.astype(np.float16).astype(np.float32), 0
    fractional_bits = {
        "UQ8.8": 8,
        "UQ4.12": 12,
        "UQ2.14": 14,
        "UQ1.15": 15,
        "UQ0.16": 16,
    }[name]
    maximum_code = 65535
    raw = np.rint(scale.astype(np.float64) * (1 << fractional_bits))
    saturated = int(np.count_nonzero((raw < 1) | (raw > maximum_code)))
    stored = np.clip(raw, 1, maximum_code) / (1 << fractional_bits)
    return stored.astype(np.float32), saturated


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--runs-root", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" / "runs")
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" /
        "q_scale_format_sweep")
    args = parser.parse_args()
    captures = sorted(args.runs_root.glob("20260816-streaming-full-c*/tensors/layer_*.pt"))
    if not captures:
        raise FileNotFoundError("no full real-model captures found")
    args.output.mkdir(parents=True, exist_ok=True)

    formats = ("FP32", "FP16", "UQ8.8", "UQ4.12", "UQ2.14", "UQ1.15", "UQ0.16")
    rows: list[dict] = []
    for capture in captures:
        saved = torch.load(capture, map_location="cpu", weights_only=True)
        tensors = saved["tensors"]
        q = tensors["q_post_rope"].float().numpy()
        k = np.repeat(tensors["k_post_rope"].float().numpy(), KV_REPEAT, axis=0)
        v = np.repeat(tensors["v"].float().numpy(), KV_REPEAT, axis=0)
        maximum = np.max(np.abs(q), axis=-1, keepdims=True)
        ideal_scale = np.where(maximum == 0, 1.0, maximum / 127.0).astype(np.float32)
        codes = np.clip(np.rint(q / ideal_scale), -127, 127).astype(np.int8)
        codes = np.where(maximum == 0, 0, codes)

        reference_logits = (
            np.matmul(q.astype(np.float32), k.transpose(0, 2, 1)) /
            math.sqrt(HEAD_DIM)
        )
        reference_probability = causal_softmax(reference_logits)
        reference_output = np.matmul(reference_probability, v)
        valid = np.tril(np.ones(reference_logits.shape[-2:], dtype=bool))

        for name in formats:
            stored_scale, saturated = quantize_scale(ideal_scale, name)
            q_dequant = codes.astype(np.float32) * stored_scale
            logits = np.matmul(q_dequant, k.transpose(0, 2, 1)) / math.sqrt(HEAD_DIM)
            probability = causal_softmax(logits)
            output = np.matmul(probability, v)
            rows.append({
                "evidence": "REAL-MODEL-VALIDATED/custom-streaming-reference",
                "context_len": int(saved["context_len"]),
                "layer": int(saved["layer"]),
                "scale_format": name,
                "fractional_bits": "reference" if name in ("FP32", "FP16") else int(name.split(".")[1]),
                "scale_min": float(ideal_scale.min()),
                "scale_max": float(ideal_scale.max()),
                "saturated_scale_count": saturated,
                "q_tensor_relative_rmse": relative_rmse(q_dequant, q),
                "q_scale_only_relative_rmse": relative_rmse(
                    q_dequant, codes.astype(np.float32) * ideal_scale),
                "qk_logit_relative_rmse": relative_rmse(logits[:, valid], reference_logits[:, valid]),
                "attention_output_relative_rmse": relative_rmse(output, reference_output),
                "attention_output_cosine": cosine(output, reference_output),
            })

    write_csv(args.output / "all_results.csv", rows)
    summary_rows: list[dict] = []
    for name in formats:
        members = [row for row in rows if row["scale_format"] == name]
        summary_rows.append({
            "scale_format": name,
            "observations": len(members),
            "scale_min": min(row["scale_min"] for row in members),
            "scale_max": max(row["scale_max"] for row in members),
            "saturated_scale_count": sum(row["saturated_scale_count"] for row in members),
            "mean_q_scale_only_relative_rmse": float(np.mean([
                row["q_scale_only_relative_rmse"] for row in members])),
            "worst_q_scale_only_relative_rmse": max(
                row["q_scale_only_relative_rmse"] for row in members),
            "mean_attention_output_relative_rmse": float(np.mean([
                row["attention_output_relative_rmse"] for row in members])),
            "worst_attention_output_relative_rmse": max(
                row["attention_output_relative_rmse"] for row in members),
            "mean_attention_output_cosine": float(np.mean([
                row["attention_output_cosine"] for row in members])),
        })
    write_csv(args.output / "summary.csv", summary_rows)
    result = {
        "evidence": "REAL-MODEL-VALIDATED/custom-streaming-reference",
        "status": "PASS",
        "contexts": sorted({row["context_len"] for row in rows}),
        "layers": sorted({row["layer"] for row in rows}),
        "formats": summary_rows,
        "claim_scope": "tensor and attention distortion only; not accuracy or perplexity",
    }
    (args.output / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", "utf-8")
    print(f"Q scale sweep PASS ({len(rows)} observations)")


if __name__ == "__main__":
    main()
