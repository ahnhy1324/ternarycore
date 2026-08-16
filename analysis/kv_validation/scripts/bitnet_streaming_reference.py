#!/usr/bin/env python3
"""Low-memory reference execution for the packed BitNet checkpoint.

The Hugging Face loader expands every packed ternary projection at once.  That
does not fit the validation host.  This module instead keeps the safetensors
file memory-mapped and expands one projection at a time.  Its equations and
operation ordering follow the pinned Transformers BitNet implementation, but
the module itself has no Transformers dependency.

This is a software reference, not an optimized inference runtime and not an
RTL bit-exact model.
"""

from __future__ import annotations

import gc
import math
from dataclasses import dataclass
from typing import Callable

import torch
import torch.nn.functional as functional


@dataclass(frozen=True)
class BitNetGeometry:
    hidden_size: int = 2560
    intermediate_size: int = 6912
    num_attention_heads: int = 20
    num_key_value_heads: int = 5
    head_dim: int = 128
    rms_norm_eps: float = 1.0e-5
    rope_theta: float = 500000.0

    @property
    def num_key_value_groups(self) -> int:
        return self.num_attention_heads // self.num_key_value_heads


CaptureCallback = Callable[[int, dict[str, torch.Tensor]], None]


def unpack_ternary(packed: torch.Tensor,
                   dtype: torch.dtype = torch.bfloat16) -> torch.Tensor:
    """Invert the checkpoint's four-values-per-U8 packing along axis zero."""

    parts = [((packed >> shift) & 3).to(torch.int8) for shift in (0, 2, 4, 6)]
    return torch.cat(parts, dim=0).to(dtype).sub_(1)


def activation_quant_int8(values: torch.Tensor) -> torch.Tensor:
    """Match AutoBitLinear's symmetric per-token activation fake quantizer."""

    source_dtype = values.dtype
    values_float = values.float()
    scale = 127.0 / values_float.abs().amax(dim=-1, keepdim=True).clamp_min_(1.0e-5)
    return ((values_float * scale).round().clamp_(-128, 127) / scale).to(source_dtype)


def rms_norm(values: torch.Tensor, weight: torch.Tensor,
             epsilon: float) -> torch.Tensor:
    source_dtype = values.dtype
    values_float = values.float()
    variance = values_float.square().mean(dim=-1, keepdim=True)
    normalized = values_float * torch.rsqrt(variance + epsilon)
    return weight * normalized.to(source_dtype)


def rotary_embeddings(context_len: int, head_dim: int, theta: float,
                      dtype: torch.dtype = torch.bfloat16,
                      device: torch.device | str = "cpu",
                      ) -> tuple[torch.Tensor, torch.Tensor]:
    inv_freq = 1.0 / (
        theta ** (torch.arange(0, head_dim, 2, device=device).float() / head_dim)
    )
    positions = torch.arange(context_len, device=device).float()
    frequencies = torch.outer(positions, inv_freq)
    embedding = torch.cat((frequencies, frequencies), dim=-1)
    return embedding.cos().to(dtype), embedding.sin().to(dtype)


def rotate_half(values: torch.Tensor) -> torch.Tensor:
    first = values[..., : values.shape[-1] // 2]
    second = values[..., values.shape[-1] // 2 :]
    return torch.cat((-second, first), dim=-1)


def apply_rope(values: torch.Tensor, cos: torch.Tensor,
               sin: torch.Tensor) -> torch.Tensor:
    # values: heads x tokens x head_dim; cos/sin: tokens x head_dim
    return values * cos.unsqueeze(0) + rotate_half(values) * sin.unsqueeze(0)


class StreamingBitNet:
    """Execute the checkpoint with only one expanded projection resident."""

    def __init__(self, tensor_handle, geometry: BitNetGeometry | None = None,
                 dtype: torch.dtype = torch.bfloat16):
        self.tensors = tensor_handle
        self.geometry = geometry or BitNetGeometry()
        self.dtype = dtype

    def tensor(self, name: str) -> torch.Tensor:
        return self.tensors.get_tensor(name)

    def embedding_lookup(self, token_ids: list[int]) -> torch.Tensor:
        """Gather rows without materializing the 657 MB embedding table."""

        embedding = self.tensors.get_slice("model.embed_tokens.weight")
        row_cache: dict[int, torch.Tensor] = {}
        rows = []
        for token_id in token_ids:
            if token_id not in row_cache:
                row_cache[token_id] = embedding[token_id:token_id + 1].clone()
            rows.append(row_cache[token_id])
        return torch.cat(rows, dim=0).to(self.dtype)

    def bitlinear(self, values: torch.Tensor, prefix: str,
                  quantized_input: torch.Tensor | None = None) -> torch.Tensor:
        if quantized_input is None:
            quantized_input = activation_quant_int8(values)
        packed = self.tensor(prefix + ".weight")
        weight = unpack_ternary(packed, self.dtype)
        scale = self.tensor(prefix + ".weight_scale").to(self.dtype)
        output = functional.linear(quantized_input, weight) * scale
        del packed, weight, scale
        return output

    def decoder_layer(self, hidden_states: torch.Tensor, layer: int,
                      cos: torch.Tensor, sin: torch.Tensor,
                      capture: bool = False,
                      ) -> tuple[torch.Tensor, dict[str, torch.Tensor] | None]:
        geometry = self.geometry
        layer_prefix = f"model.layers.{layer}"

        residual = hidden_states
        attention_input = rms_norm(
            hidden_states,
            self.tensor(layer_prefix + ".input_layernorm.weight"),
            geometry.rms_norm_eps,
        )
        attention_input_q8 = activation_quant_int8(attention_input)
        attention_prefix = layer_prefix + ".self_attn"
        query_pre = self.bitlinear(
            attention_input, attention_prefix + ".q_proj", attention_input_q8)
        key_pre = self.bitlinear(
            attention_input, attention_prefix + ".k_proj", attention_input_q8)
        value = self.bitlinear(
            attention_input, attention_prefix + ".v_proj", attention_input_q8)
        del attention_input, attention_input_q8

        token_count = hidden_states.shape[0]
        query_pre = query_pre.view(
            token_count, geometry.num_attention_heads, geometry.head_dim
        ).transpose(0, 1)
        key_pre = key_pre.view(
            token_count, geometry.num_key_value_heads, geometry.head_dim
        ).transpose(0, 1)
        value = value.view(
            token_count, geometry.num_key_value_heads, geometry.head_dim
        ).transpose(0, 1)
        query = apply_rope(query_pre, cos, sin)
        key = apply_rope(key_pre, cos, sin)

        repeated_key = key[:, None, :, :].expand(
            geometry.num_key_value_heads,
            geometry.num_key_value_groups,
            token_count,
            geometry.head_dim,
        ).reshape(geometry.num_attention_heads, token_count, geometry.head_dim)
        repeated_value = value[:, None, :, :].expand(
            geometry.num_key_value_heads,
            geometry.num_key_value_groups,
            token_count,
            geometry.head_dim,
        ).reshape(geometry.num_attention_heads, token_count, geometry.head_dim)

        logits = torch.matmul(query, repeated_key.transpose(1, 2)) * (
            geometry.head_dim ** -0.5
        )
        causal_mask = torch.triu(
            torch.ones(token_count, token_count, dtype=torch.bool), diagonal=1)
        logits = logits.masked_fill(causal_mask.unsqueeze(0),
                                    torch.finfo(logits.dtype).min)
        probabilities = functional.softmax(logits, dim=-1, dtype=torch.float32).to(
            query.dtype
        )
        weighted_value = torch.matmul(probabilities, repeated_value)
        attention_output = weighted_value.transpose(0, 1).contiguous().reshape(
            token_count, geometry.hidden_size
        )
        attention_output = rms_norm(
            attention_output,
            self.tensor(attention_prefix + ".attn_sub_norm.weight"),
            geometry.rms_norm_eps,
        )
        attention_output = self.bitlinear(
            attention_output, attention_prefix + ".o_proj")
        hidden_states = residual + attention_output

        capture_tensors = None
        if capture:
            capture_tensors = {
                "q_pre_rope": query_pre.detach().cpu().clone(),
                "k_pre_rope": key_pre.detach().cpu().clone(),
                "q_post_rope": query.detach().cpu().clone(),
                "k_post_rope": key.detach().cpu().clone(),
                "v": value.detach().cpu().clone(),
                "attention_logits": logits.detach().cpu().clone(),
                "attention_probabilities": probabilities.detach().cpu().clone(),
                "attention_weighted_v": weighted_value.detach().cpu().clone(),
                "attention_block_output": attention_output.detach().cpu().clone(),
            }

        # Free the quadratic attention tensors before entering the MLP.
        del repeated_key, repeated_value, logits, probabilities, weighted_value
        del query_pre, key_pre, query, key, value, attention_output, residual
        gc.collect()

        residual = hidden_states
        mlp_input = rms_norm(
            hidden_states,
            self.tensor(layer_prefix + ".post_attention_layernorm.weight"),
            geometry.rms_norm_eps,
        )
        mlp_input_q8 = activation_quant_int8(mlp_input)
        gate = self.bitlinear(
            mlp_input, layer_prefix + ".mlp.gate_proj", mlp_input_q8)
        up = self.bitlinear(
            mlp_input, layer_prefix + ".mlp.up_proj", mlp_input_q8)
        del mlp_input, mlp_input_q8
        activated = functional.relu(gate).square_() * up
        del gate, up
        activated = rms_norm(
            activated,
            self.tensor(layer_prefix + ".mlp.ffn_sub_norm.weight"),
            geometry.rms_norm_eps,
        )
        down = self.bitlinear(activated, layer_prefix + ".mlp.down_proj")
        hidden_states = residual + down
        del activated, down, residual
        gc.collect()
        return hidden_states, capture_tensors

    def run(self, token_ids: list[int], layer_count: int,
            capture_layers: set[int], capture_callback: CaptureCallback,
            progress_callback: Callable[[int], None] | None = None,
            ) -> torch.Tensor:
        hidden_states = self.embedding_lookup(token_ids)
        cos, sin = rotary_embeddings(
            len(token_ids), self.geometry.head_dim, self.geometry.rope_theta,
            dtype=self.dtype,
        )
        for layer in range(layer_count):
            hidden_states, capture = self.decoder_layer(
                hidden_states, layer, cos, sin, layer in capture_layers
            )
            if capture is not None:
                capture_callback(layer, capture)
                del capture
            if progress_callback is not None:
                progress_callback(layer)
        return rms_norm(
            hidden_states, self.tensor("model.norm.weight"),
            self.geometry.rms_norm_eps,
        )

