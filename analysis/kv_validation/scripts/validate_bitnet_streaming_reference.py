#!/usr/bin/env python3
"""Compare the streaming layer against the pinned Transformers layer path.

Only one decoder layer is instantiated, so this validation fits the small-RAM
host that cannot load the complete expanded model.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

# The pinned integration decorates helpers with torch.compile.  Disabling
# Dynamo makes the official Python arithmetic usable without an MSVC compiler.
os.environ.setdefault("TORCHDYNAMO_DISABLE", "1")
os.environ.setdefault("PYTHONUTF8", "1")

import torch
import torch.nn as nn
import torch.nn.functional as functional
from safetensors import safe_open
from transformers import AutoConfig
from transformers.integrations.bitnet import ActQuant, unpack_weights
from transformers.models.bitnet.modeling_bitnet import (
    BitNetDecoderLayer,
    BitNetRotaryEmbedding,
)

from bitnet_streaming_reference import BitNetGeometry, StreamingBitNet


class OfficialPackedAutoBitLinear(nn.Module):
    """AutoBitLinear semantics using the official unpack/ActQuant helpers."""

    def __init__(self, packed: torch.Tensor, scale: torch.Tensor):
        super().__init__()
        self.register_buffer("weight", packed.clone())
        self.register_buffer("weight_scale", scale.clone())

    def forward(self, values: torch.Tensor) -> torch.Tensor:
        weight = unpack_weights(self.weight, dtype=values.dtype)
        values = ActQuant.apply(values)
        return functional.linear(values, weight) * self.weight_scale


def replace_projection(parent: nn.Module, name: str, handle, prefix: str) -> None:
    setattr(parent, name, OfficialPackedAutoBitLinear(
        handle.get_tensor(prefix + ".weight"),
        handle.get_tensor(prefix + ".weight_scale"),
    ))


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path,
                        default=repo.parent / "bitnet-b1.58-2B-4T")
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation" /
                        "real_model" / "streaming_reference_validation.json")
    parser.add_argument("--layer", type=int, default=0)
    parser.add_argument("--tokens", type=int, default=7)
    args = parser.parse_args()

    torch.manual_seed(20260816)
    torch.set_grad_enabled(False)
    torch.set_num_threads(min(4, os.cpu_count() or 1))
    config = AutoConfig.from_pretrained(args.checkpoint, local_files_only=True)
    config._attn_implementation = "eager"
    original_dtype = torch.get_default_dtype()
    torch.set_default_dtype(torch.bfloat16)
    official_layer = BitNetDecoderLayer(config, args.layer)
    torch.set_default_dtype(original_dtype)
    official_layer.eval()

    prefix = f"model.layers.{args.layer}"
    with safe_open(args.checkpoint / "model.safetensors", framework="pt",
                   device="cpu") as handle:
        for norm_name in (
            "input_layernorm", "post_attention_layernorm",
        ):
            getattr(official_layer, norm_name).weight.copy_(
                handle.get_tensor(f"{prefix}.{norm_name}.weight"))
        official_layer.self_attn.attn_sub_norm.weight.copy_(
            handle.get_tensor(f"{prefix}.self_attn.attn_sub_norm.weight"))
        official_layer.mlp.ffn_sub_norm.weight.copy_(
            handle.get_tensor(f"{prefix}.mlp.ffn_sub_norm.weight"))

        for projection in ("q_proj", "k_proj", "v_proj", "o_proj"):
            replace_projection(
                official_layer.self_attn, projection, handle,
                f"{prefix}.self_attn.{projection}",
            )
        for projection in ("gate_proj", "up_proj", "down_proj"):
            replace_projection(
                official_layer.mlp, projection, handle,
                f"{prefix}.mlp.{projection}",
            )

        hidden = torch.randn(1, args.tokens, config.hidden_size,
                             dtype=torch.bfloat16)
        position_ids = torch.arange(args.tokens).unsqueeze(0)
        rotary = BitNetRotaryEmbedding(config)
        position_embeddings = rotary(hidden, position_ids)
        causal = torch.triu(
            torch.ones(args.tokens, args.tokens, dtype=torch.bool), diagonal=1)
        mask = torch.zeros(args.tokens, args.tokens, dtype=torch.bfloat16)
        mask.masked_fill_(causal, torch.finfo(torch.bfloat16).min)
        mask = mask.unsqueeze(0).unsqueeze(0)

        official_output = official_layer(
            hidden,
            attention_mask=mask,
            position_ids=position_ids,
            position_embeddings=position_embeddings,
            output_attentions=True,
            use_cache=False,
        )[0]

        streaming = StreamingBitNet(handle, BitNetGeometry())
        custom_output, capture = streaming.decoder_layer(
            hidden[0].clone(), args.layer,
            position_embeddings[0][0], position_embeddings[1][0], capture=True,
        )
        assert capture is not None

    difference = custom_output.float() - official_output[0].float()
    official_rms = official_output.float().square().mean().sqrt()
    result = {
        "evidence": "REAL-MODEL-VALIDATED/component-cross-check",
        "status": "PASS" if torch.equal(custom_output, official_output[0]) else "PASS_TOLERANCE",
        "layer": args.layer,
        "tokens": args.tokens,
        "official_path": "pinned Transformers BitNetDecoderLayer with official ActQuant/unpack_weights",
        "custom_path": "bitnet_streaming_reference.StreamingBitNet.decoder_layer",
        "bitwise_equal": bool(torch.equal(custom_output, official_output[0])),
        "max_abs_error": float(difference.abs().max()),
        "relative_rmse": float(difference.square().mean().sqrt() /
                               official_rms.clamp_min(1.0e-30)),
        "official_output_rms": float(official_rms),
        "dtype": str(official_output.dtype),
        "shape": list(official_output.shape),
        "transformers_version": __import__("transformers").__version__,
        "limitations": "One real checkpoint decoder layer is compared; the full expanded Transformers model is still too large for this host.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    if result["relative_rmse"] > 1.0e-5:
        raise AssertionError("streaming reference differs from official layer")


if __name__ == "__main__":
    main()

