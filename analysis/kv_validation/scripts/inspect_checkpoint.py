#!/usr/bin/env python3
"""Inspect the external checkpoint without loading the full model."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import psutil
import safetensors
import torch
import transformers
from huggingface_hub import __version__ as hub_version
from safetensors import safe_open
from transformers import AutoConfig, AutoTokenizer


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()


def metadata_identity(path: Path) -> dict[str, str | float]:
    lines = path.read_text(encoding="utf-8").splitlines()
    return {
        "revision": lines[0],
        "etag": lines[1],
        "download_timestamp": float(lines[2]),
    }


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(8 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def packed_projection_stats(checkpoint: Path) -> list[dict]:
    rows = []
    model_file = checkpoint / "model.safetensors"
    with safe_open(model_file, framework="pt", device="cpu") as handle:
        for layer in range(30):
            for projection in ("q_proj", "k_proj", "v_proj"):
                prefix = f"model.layers.{layer}.self_attn.{projection}"
                packed = handle.get_tensor(prefix + ".weight").numpy()
                counts = Counter()
                for shift in (0, 2, 4, 6):
                    values = (packed >> shift) & 0x3
                    unique, frequency = np.unique(values, return_counts=True)
                    counts.update({int(key): int(value)
                                   for key, value in zip(unique, frequency)})
                total = sum(counts.values())
                scale = float(handle.get_tensor(prefix + ".weight_scale").float()[0])
                rows.append({
                    "evidence": "REAL-MODEL-VALIDATED/checkpoint-weight-storage",
                    "layer": layer,
                    "projection": projection,
                    "packed_shape": list(packed.shape),
                    "unpacked_values": total,
                    "minus_one_fraction": counts[0] / total,
                    "zero_fraction": counts[1] / total,
                    "plus_one_fraction": counts[2] / total,
                    "invalid_code3_fraction": counts[3] / total,
                    "weight_scale": scale,
                })
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    repo = Path(__file__).resolve().parents[3]
    parser.add_argument("--checkpoint", type=Path,
                        default=repo.parent / "bitnet-b1.58-2B-4T")
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation")
    args = parser.parse_args()
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    (output / "real_model").mkdir(exist_ok=True)

    required = ("config.json", "model.safetensors", "tokenizer.json",
                "tokenizer_config.json", "special_tokens_map.json")
    missing = [name for name in required if not (args.checkpoint / name).exists()]
    if missing:
        raise FileNotFoundError(f"checkpoint incomplete: {missing}")

    config_raw = json.loads((args.checkpoint / "config.json").read_text(encoding="utf-8"))
    config = AutoConfig.from_pretrained(args.checkpoint, local_files_only=True)
    tokenizer = AutoTokenizer.from_pretrained(args.checkpoint, local_files_only=True)
    model_identity = metadata_identity(
        args.checkpoint / ".cache" / "huggingface" / "download" /
        "model.safetensors.metadata")
    config_identity = metadata_identity(
        args.checkpoint / ".cache" / "huggingface" / "download" /
        "config.json.metadata")

    with safe_open(args.checkpoint / "model.safetensors", framework="pt",
                   device="cpu") as handle:
        keys = list(handle.keys())
        dtype_counts = Counter(str(handle.get_slice(key).get_dtype()) for key in keys)
        tensor_count = len(keys)

    vm = psutil.virtual_memory()
    swap = psutil.swap_memory()
    environment = {
        "evidence": "REAL-MODEL-VALIDATED/environment-and-checkpoint-identity",
        "git_commit": git(repo, "rev-parse", "HEAD"),
        "git_branch": git(repo, "branch", "--show-current"),
        "checkpoint_path": str(args.checkpoint.resolve()),
        "checkpoint_revision": model_identity["revision"],
        "checkpoint_model_etag": model_identity["etag"],
        "checkpoint_config_revision": config_identity["revision"],
        "checkpoint_model_sha256": file_sha256(args.checkpoint / "model.safetensors"),
        "checkpoint_bytes": (args.checkpoint / "model.safetensors").stat().st_size,
        "python": platform.python_version(),
        "python_executable": sys.executable,
        "platform": platform.platform(),
        "processor": os.environ.get("PROCESSOR_IDENTIFIER", platform.processor()),
        "logical_processors": psutil.cpu_count(),
        "physical_cores": psutil.cpu_count(logical=False),
        "ram_total_bytes": vm.total,
        "ram_available_at_inspection_bytes": vm.available,
        "swap_total_bytes": swap.total,
        "swap_free_at_inspection_bytes": swap.free,
        "torch": torch.__version__,
        "torch_cuda_available": torch.cuda.is_available(),
        "transformers": transformers.__version__,
        "transformers_required_commit": "096f25ae1f501a084d8ff2dcaf25fbc2bd60eba4",
        "huggingface_hub": hub_version,
        "safetensors": safetensors.__version__,
        "numpy": np.__version__,
        "tensor_count": tensor_count,
        "tensor_dtype_counts": dict(dtype_counts),
    }
    (output / "environment.json").write_text(
        json.dumps(environment, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    model_config = {
        "evidence": "REAL-MODEL-VALIDATED/checkpoint-config",
        "raw": config_raw,
        "derived": {
            "hidden_size": config.hidden_size,
            "num_hidden_layers": config.num_hidden_layers,
            "num_attention_heads": config.num_attention_heads,
            "num_key_value_heads": config.num_key_value_heads,
            "head_dim": config.hidden_size // config.num_attention_heads,
            "gqa_query_heads_per_kv_head": (
                config.num_attention_heads // config.num_key_value_heads),
            "context_limit": config.max_position_embeddings,
            "rope_theta": config.rope_theta,
            "torch_dtype": str(config.torch_dtype),
            "checkpoint_format": "safetensors; packed U8 ternary projections plus BF16 scales/norms/embeddings",
            "selected_capture_layers": [0, 7, 15, 22, 29],
        },
        "tokenizer": {
            "class": f"{type(tokenizer).__module__}.{type(tokenizer).__name__}",
            "vocab_size": len(tokenizer),
            "bos_token_id": tokenizer.bos_token_id,
            "eos_token_id": tokenizer.eos_token_id,
            "special_tokens_map": tokenizer.special_tokens_map,
            "checkpoint_files": ["tokenizer.json", "tokenizer_config.json",
                                 "special_tokens_map.json"],
        },
    }
    (output / "model_config.json").write_text(
        json.dumps(model_config, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    prompts = [
        "The quick brown fox jumps over the lazy dog.",
        "Explain why a low-bit KV cache can reduce memory traffic.",
        "A deterministic validation prompt should be reproducible across runs.",
        "List three properties of an FPGA attention accelerator.",
    ]
    base_ids = []
    for prompt in prompts:
        base_ids.extend(tokenizer(prompt, add_special_tokens=True)["input_ids"])
    contexts = {}
    for length in (128, 512, 1024, 2048, 4096):
        repeats = (length + len(base_ids) - 1) // len(base_ids)
        contexts[str(length)] = (base_ids * repeats)[:length]
    prompt_record = {
        "evidence": "REAL-MODEL-VALIDATED/tokenizer; real activation execution NOT_TESTED",
        "seed": 20260816,
        "prompts": prompts,
        "base_token_ids": base_ids,
        "context_token_ids": contexts,
    }
    (output / "real_model" / "prompts_and_token_ids.json").write_text(
        json.dumps(prompt_record, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    rows = packed_projection_stats(args.checkpoint)
    import csv
    with (output / "real_model" / "checkpoint_projection_weight_stats.csv").open(
            "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print("checkpoint inspection PASS", model_identity["revision"])


if __name__ == "__main__":
    main()
