#!/usr/bin/env python3
"""Run one crash-safe end-to-end KV-quantization injection case."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import time
from pathlib import Path

import numpy as np
import psutil
import torch
from safetensors import safe_open

from bitnet_streaming_reference import BitNetGeometry, KVQuantProfile, StreamingBitNet


CAPTURE_LAYERS = {0, 7, 15, 22, 29}
PROFILES: dict[str, KVQuantProfile | None] = {
    "BASE_FP": None,
    "Q8_ONLY": KVQuantProfile(name="Q8_ONLY"),
    "REGULAR4": KVQuantProfile(
        name="REGULAR4", k_bits=4, k_group_size=128,
        v_bits=4, v_group_size=16),
    "PACKED5": KVQuantProfile(
        name="PACKED5", k_bits=4, k_group_size=128,
        v_bits=5, v_group_size=128),
    "ACCURATE5": KVQuantProfile(
        name="ACCURATE5", k_bits=5, k_group_size=128,
        v_bits=5, v_group_size=128),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(8 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def relative_rmse(actual: torch.Tensor, reference: torch.Tensor) -> float:
    a = actual.float().double()
    b = reference.float().double()
    return float(torch.sqrt(torch.mean((a - b).square()) /
                            torch.mean(b.square()).clamp_min(1.0e-30)))


def cosine(actual: torch.Tensor, reference: torch.Tensor) -> float:
    a = actual.float().double().reshape(-1)
    b = reference.float().double().reshape(-1)
    return float(torch.dot(a, b) /
                 (torch.linalg.vector_norm(a) * torch.linalg.vector_norm(b)).clamp_min(1.0e-30))


def chunked_vocab_logits(handle, hidden: torch.Tensor, chunk: int = 2048) -> np.ndarray:
    embedding = handle.get_slice("model.embed_tokens.weight")
    vocab_size = embedding.get_shape()[0]
    output = np.empty(vocab_size, dtype=np.float32)
    vector = hidden[-1].float()
    for start in range(0, vocab_size, chunk):
        stop = min(start + chunk, vocab_size)
        weight = embedding[start:stop].float()
        output[start:stop] = torch.mv(weight, vector).numpy()
        del weight
    return output


def distribution_metrics(actual: np.ndarray, reference: np.ndarray) -> dict[str, float | bool]:
    ref_shift = reference.astype(np.float64) - float(np.max(reference))
    act_shift = actual.astype(np.float64) - float(np.max(actual))
    p = np.exp(ref_shift); p /= np.sum(p)
    q = np.exp(act_shift); q /= np.sum(q)
    midpoint = 0.5 * (p + q)
    tiny = np.finfo(np.float64).tiny
    kl = float(np.sum(p * (np.log(np.maximum(p, tiny)) - np.log(np.maximum(q, tiny)))))
    js = float(0.5 * np.sum(p * (np.log(np.maximum(p, tiny)) - np.log(midpoint))) +
               0.5 * np.sum(q * (np.log(np.maximum(q, tiny)) - np.log(midpoint))))
    ref_top5 = np.argpartition(reference, -5)[-5:]
    act_top5 = np.argpartition(actual, -5)[-5:]
    return {
        "kl_reference_to_candidate": kl,
        "js_divergence": js,
        "top1_preserved": bool(int(np.argmax(reference)) == int(np.argmax(actual))),
        "top5_exact_set_preserved": bool(set(ref_top5.tolist()) == set(act_top5.tolist())),
        "top5_overlap_fraction": len(set(ref_top5.tolist()) & set(act_top5.tolist())) / 5.0,
    }


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path,
                        default=repo.parent / "bitnet-b1.58-2B-4T")
    parser.add_argument(
        "--prompt-record", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" /
        "end_to_end_prompts.json")
    parser.add_argument("--prompt-id", choices=("engineering", "observatory"), required=True)
    parser.add_argument("--profile", choices=tuple(PROFILES), required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=min(4, os.cpu_count() or 1))
    args = parser.parse_args()

    prompt_data = json.loads(args.prompt_record.read_text("utf-8"))
    prompt = next(row for row in prompt_data["prompts"]
                  if row["prompt_id"] == args.prompt_id)
    token_ids = prompt["context_token_ids"]
    destination = args.output_root / args.prompt_id / args.profile
    destination.mkdir(parents=True, exist_ok=False)
    capture_dir = destination / "captures"
    capture_dir.mkdir()
    torch.manual_seed(20260816)
    torch.set_grad_enabled(False)
    torch.set_num_threads(args.threads)
    try:
        torch.set_num_interop_threads(1)
    except RuntimeError:
        pass

    process = psutil.Process()
    start_time = time.perf_counter()
    peak_rss = process.memory_info().rss
    timings: list[dict] = []
    scale_audit: list[dict[str, object]] = []
    prior_time = start_time

    def save_capture(layer: int, tensors: dict[str, torch.Tensor]) -> None:
        torch.save({
            "attention_weighted_v": tensors["attention_weighted_v"],
            "attention_block_output": tensors["attention_block_output"],
        }, capture_dir / f"layer_{layer:02d}.pt")

    def progress(layer: int) -> None:
        nonlocal prior_time, peak_rss
        now = time.perf_counter()
        rss = process.memory_info().rss
        peak_rss = max(peak_rss, rss)
        row = {"layer": layer, "layer_seconds": now - prior_time,
               "elapsed_seconds": now - start_time, "working_set_bytes": rss}
        timings.append(row)
        prior_time = now
        print(json.dumps(row), flush=True)

    def observe_scale(label: str, row: dict[str, float | int]) -> None:
        scale_audit.append({"tensor": label, **row})

    model_path = args.checkpoint / "model.safetensors"
    with safe_open(model_path, framework="pt", device="cpu") as handle:
        model = StreamingBitNet(handle, geometry=BitNetGeometry())
        final_hidden = model.run(
            token_ids, 30, CAPTURE_LAYERS, save_capture, progress,
            kv_profile=PROFILES[args.profile], scale_observer=observe_scale)
        logits = chunked_vocab_logits(handle, final_hidden)
    peak_rss = max(peak_rss, process.memory_info().rss)
    torch.save(final_hidden, destination / "final_hidden.pt")
    np.save(destination / "last_token_logits.npy", logits)

    metrics: dict[str, object] = {}
    if args.profile == "BASE_FP":
        metrics = {
            "final_hidden_relative_rmse": 0.0,
            "final_hidden_cosine": 1.0,
            "last_token_hidden_relative_rmse": 0.0,
            "last_token_hidden_cosine": 1.0,
            "target_token_logit_delta": 0.0,
            "top1_preserved": True,
            "top5_exact_set_preserved": True,
            "top5_overlap_fraction": 1.0,
            "kl_reference_to_candidate": 0.0,
            "js_divergence": 0.0,
            "selected_layers": [],
        }
    else:
        base = args.output_root / args.prompt_id / "BASE_FP"
        if not (base / "run.json").is_file():
            raise FileNotFoundError("BASE_FP must complete before candidate profiles")
        base_hidden = torch.load(base / "final_hidden.pt", map_location="cpu",
                                 weights_only=True)
        base_logits = np.load(base / "last_token_logits.npy")
        metrics = {
            "final_hidden_relative_rmse": relative_rmse(final_hidden, base_hidden),
            "final_hidden_cosine": cosine(final_hidden, base_hidden),
            "last_token_hidden_relative_rmse": relative_rmse(
                final_hidden[-1], base_hidden[-1]),
            "last_token_hidden_cosine": cosine(final_hidden[-1], base_hidden[-1]),
            "target_token_logit_delta": float(
                logits[prompt["target_token_id"]] - base_logits[prompt["target_token_id"]]),
        }
        metrics.update(distribution_metrics(logits, base_logits))
        layer_rows = []
        for layer in sorted(CAPTURE_LAYERS):
            actual = torch.load(capture_dir / f"layer_{layer:02d}.pt",
                                map_location="cpu", weights_only=True)
            reference = torch.load(base / "captures" / f"layer_{layer:02d}.pt",
                                   map_location="cpu", weights_only=True)
            layer_rows.append({
                "layer": layer,
                "weighted_v_relative_rmse": relative_rmse(
                    actual["attention_weighted_v"], reference["attention_weighted_v"]),
                "weighted_v_cosine": cosine(
                    actual["attention_weighted_v"], reference["attention_weighted_v"]),
                "block_output_relative_rmse": relative_rmse(
                    actual["attention_block_output"], reference["attention_block_output"]),
                "block_output_cosine": cosine(
                    actual["attention_block_output"], reference["attention_block_output"]),
            })
        metrics["selected_layers"] = layer_rows

    elapsed = time.perf_counter() - start_time
    result = {
        "evidence": "REAL-MODEL-VALIDATED/end-to-end-streaming-injection",
        "status": "PASS",
        "claim_scope": "hidden-state and tied-logit distortion; not perplexity or task accuracy",
        "prompt_id": args.prompt_id,
        "context_length": len(token_ids),
        "target_token_id": prompt["target_token_id"],
        "token_ids_sha256": prompt["context_token_ids_sha256"],
        "profile": args.profile,
        "profile_contract": None if PROFILES[args.profile] is None else
            PROFILES[args.profile].__dict__,
        "write_side_policy": (
            "codes from high-precision absmax/reciprocal; dequantization uses rounded stored scale"),
        "scale_audit": {
            "records": scale_audit,
            "total_scale_count": sum(int(row["scale_count"]) for row in scale_audit),
            "total_underflow_scale_count": sum(
                int(row["underflow_scale_count"]) for row in scale_audit),
            "total_overflow_scale_count": sum(
                int(row["overflow_scale_count"]) for row in scale_audit),
            "max_ideal_scale": max(
                (float(row["ideal_scale_max"]) for row in scale_audit), default=0.0),
        },
        "checkpoint_model_sha256": sha256(model_path),
        "elapsed_seconds": elapsed,
        "peak_observed_working_set_bytes": peak_rss,
        "timings": timings,
        "metrics": metrics,
        "python": platform.python_version(),
        "torch": torch.__version__,
    }
    (destination / "run.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", "utf-8")
    print(json.dumps({"status": "PASS", "profile": args.profile,
                      "prompt": args.prompt_id, "elapsed_seconds": elapsed,
                      "metrics": metrics}, indent=2), flush=True)


if __name__ == "__main__":
    main()
