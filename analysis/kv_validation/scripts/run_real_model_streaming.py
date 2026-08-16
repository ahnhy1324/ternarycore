#!/usr/bin/env python3
"""Capture real BitNet Q/K/V tensors with the low-memory reference path."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import sys
import time
from pathlib import Path

import psutil
import torch
from safetensors import safe_open

from bitnet_streaming_reference import BitNetGeometry, StreamingBitNet


BASE_SEED = 20260816


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(8 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path,
                        default=repo.parent / "bitnet-b1.58-2B-4T")
    parser.add_argument("--prompt-record", type=Path,
                        default=repo / "analysis" / "kv_validation" /
                        "real_model" / "prompts_and_token_ids.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--context-length", type=int, default=128)
    parser.add_argument("--layers", default="0,7,15,22,29")
    parser.add_argument("--layer-count", type=int, default=30,
                        help="Debug option; a real full-model run uses 30.")
    parser.add_argument("--threads", type=int, default=min(4, os.cpu_count() or 1))
    args = parser.parse_args()

    if args.context_length not in (128, 512, 1024, 2048, 4096):
        raise ValueError("context length must be one of 128/512/1024/2048/4096")
    if not 1 <= args.layer_count <= 30:
        raise ValueError("layer-count must be in 1..30")
    selected_layers = {int(value) for value in args.layers.split(",")}
    selected_layers = {value for value in selected_layers if value < args.layer_count}
    required = ("config.json", "model.safetensors", "tokenizer.json")
    missing = [name for name in required if not (args.checkpoint / name).is_file()]
    if missing:
        raise FileNotFoundError(f"checkpoint incomplete: {missing}")

    prompt_record = json.loads(args.prompt_record.read_text(encoding="utf-8"))
    token_ids = prompt_record["context_token_ids"][str(args.context_length)]
    if len(token_ids) != args.context_length:
        raise AssertionError("recorded token length does not match request")

    args.output.mkdir(parents=True, exist_ok=False)
    tensor_dir = args.output / "tensors"
    tensor_dir.mkdir()
    torch.manual_seed(BASE_SEED)
    torch.set_grad_enabled(False)
    torch.set_num_threads(args.threads)
    try:
        torch.set_num_interop_threads(1)
    except RuntimeError:
        pass

    process = psutil.Process()
    start = time.perf_counter()
    timings = []
    last_time = start

    def save_capture(layer: int, tensors: dict[str, torch.Tensor]) -> None:
        destination = tensor_dir / f"layer_{layer:02d}.pt"
        torch.save({
            "evidence": "REAL-MODEL-VALIDATED/custom-streaming-reference",
            "layer": layer,
            "context_len": args.context_length,
            "head_dim": 128,
            "dtype": "torch.bfloat16",
            "tensors": tensors,
        }, destination)

    def progress(layer: int) -> None:
        nonlocal last_time
        now = time.perf_counter()
        row = {
            "layer": layer,
            "layer_seconds": now - last_time,
            "elapsed_seconds": now - start,
            "working_set_bytes": process.memory_info().rss,
        }
        timings.append(row)
        last_time = now
        print(json.dumps(row), flush=True)

    geometry = BitNetGeometry()
    model_file = args.checkpoint / "model.safetensors"
    with safe_open(model_file, framework="pt", device="cpu") as handle:
        model = StreamingBitNet(handle, geometry=geometry)
        final_hidden = model.run(
            token_ids, args.layer_count, selected_layers, save_capture, progress
        )
        final_stats = {
            "shape": list(final_hidden.shape),
            "dtype": str(final_hidden.dtype),
            "min": float(final_hidden.float().min()),
            "max": float(final_hidden.float().max()),
            "mean": float(final_hidden.float().mean()),
            "rms": float(final_hidden.float().square().mean().sqrt()),
            "sha256_float32_bytes": hashlib.sha256(
                final_hidden.float().numpy().tobytes()
            ).hexdigest(),
        }

    status = {
        "evidence": "REAL-MODEL-VALIDATED/custom-streaming-reference",
        "status": "PASS",
        "implementation": "Transformers-free, layer-streaming PyTorch reference",
        "transformers_used_for_execution": False,
        "full_model_layer_count": args.layer_count,
        "context_len": args.context_length,
        "selected_capture_layers": sorted(selected_layers),
        "seed": BASE_SEED,
        "token_ids_sha256": hashlib.sha256(
            json.dumps(token_ids, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "checkpoint": str(args.checkpoint.resolve()),
        "checkpoint_model_sha256": sha256(model_file),
        "python": platform.python_version(),
        "torch": torch.__version__,
        "torch_threads": args.threads,
        "host": platform.platform(),
        "elapsed_seconds": time.perf_counter() - start,
        "peak_observed_working_set_bytes": max(
            row["working_set_bytes"] for row in timings
        ),
        "timings": timings,
        "final_hidden": final_stats,
        "limitations": [
            "The arithmetic is source-matched to the pinned Transformers implementation but uses a custom low-memory execution path.",
            "This is not a task-accuracy or perplexity measurement.",
            "This is not an optimized inference-performance measurement.",
        ],
        "python_executable": sys.executable,
    }
    (args.output / "run.json").write_text(
        json.dumps(status, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print("real model streaming capture PASS", flush=True)


if __name__ == "__main__":
    main()

