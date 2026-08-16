#!/usr/bin/env python3
"""Reference Q/K/V quantization primitives for KV-cache experiments.

This module deliberately implements a conventional symmetric absmax quantizer,
not the unrecovered G_B mapping mentioned in the handoff.  The optional dither
interface expresses offsets in quantizer-LSB units; candidate deterministic
generators and the exact G_B insertion rule remain TODO research items.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Mapping

import numpy as np


HEAD_DIM = 64
SUPPORTED_SCALE_FORMATS = ("FP32", "FP16", "Q8.8")


@dataclass(frozen=True)
class DitherRequest:
    """Information available to a future deterministic dither provider."""

    shape: tuple[int, ...]
    tensor_name: str
    bits: int
    group_size: int | None
    metadata: Mapping[str, int | str]


DitherProvider = Callable[[DitherRequest], np.ndarray]


@dataclass
class QuantizedTensor:
    codes: np.ndarray
    dequant: np.ndarray
    ideal_scale_dequant: np.ndarray
    ideal_scales: np.ndarray
    stored_scales: np.ndarray


def _rms_normalize_last_axis(values: np.ndarray) -> np.ndarray:
    rms = np.sqrt(np.mean(values.astype(np.float64) ** 2, axis=-1,
                          keepdims=True))
    return (values / np.maximum(rms, 1.0e-12)).astype(np.float32)


def synthetic_values(rng: np.random.Generator, shape: tuple[int, ...],
                     distribution: str) -> np.ndarray:
    """Generate explicitly synthetic, per-vector RMS-normalized activations."""

    if distribution == "gaussian":
        values = rng.normal(0.0, 1.0, shape)
    elif distribution == "laplace":
        values = rng.laplace(0.0, 1.0 / np.sqrt(2.0), shape)
    elif distribution == "student_t_df3":
        values = rng.standard_t(3.0, shape) / np.sqrt(3.0)
    elif distribution == "sparse_outliers_0p1pct_x25":
        values = rng.normal(0.0, 1.0, shape)
        mask = rng.random(shape) < 0.001
        values[mask] *= 25.0
    elif distribution == "outliers_1pct_x10":
        values = rng.normal(0.0, 1.0, shape)
        mask = rng.random(shape) < 0.01
        values[mask] *= 10.0
    else:
        raise ValueError(f"unsupported distribution: {distribution}")
    return _rms_normalize_last_axis(values.astype(np.float32))


def make_dataset(seed: int, distribution: str, trials: int,
                 context_len: int, head_dim: int = HEAD_DIM
                 ) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    q = synthetic_values(rng, (trials, head_dim), distribution)
    k = synthetic_values(rng, (trials, context_len, head_dim), distribution)
    v = synthetic_values(rng, (trials, context_len, head_dim), distribution)
    return q, k, v


def _represent_scale(scale: np.ndarray, scale_format: str) -> np.ndarray:
    if scale_format == "FP32":
        represented = scale.astype(np.float32)
    elif scale_format == "FP16":
        represented = scale.astype(np.float16).astype(np.float32)
    elif scale_format == "Q8.8":
        # Historical/synthetic format retained for comparison. ABI v2 uses
        # unsigned UQ5.11 K/V scales instead.
        represented = np.clip(np.rint(scale * 256.0), 1.0, 32767.0) / 256.0
        represented = represented.astype(np.float32)
    else:
        raise ValueError(f"unsupported scale format: {scale_format}")
    return np.maximum(represented, np.finfo(np.float32).tiny)


def quantize_symmetric(values: np.ndarray, bits: int,
                       granularity: str = "token",
                       group_size: int | None = None,
                       scale_format: str = "FP32",
                       tensor_name: str = "tensor",
                       dither: DitherProvider | None = None,
                       dither_metadata: Mapping[str, int | str] | None = None,
                       ) -> QuantizedTensor:
    """Symmetric absmax quantization with separable scale representation error.

    Codes are selected using the ideal FP32 scale.  The returned ``dequant``
    uses the requested stored scale, while ``ideal_scale_dequant`` uses the
    same codes with the ideal scale.  Their difference therefore isolates
    scale-representation error from low-bit code selection.

    Dither, when supplied, is an offset in code-bin/LSB units inserted before
    round-to-nearest-even.  No deterministic generator is selected here.
    """

    if bits < 2 or bits > 16:
        raise ValueError("bits must be in 2..16")
    if scale_format not in SUPPORTED_SCALE_FORMATS:
        raise ValueError(f"unsupported scale format: {scale_format}")
    if values.shape[-1] <= 0:
        raise ValueError("last axis must be non-empty")

    qmax = (1 << (bits - 1)) - 1
    original_shape = values.shape

    if granularity == "run":
        if values.ndim < 3:
            raise ValueError("run granularity requires [trial, token, dim]")
        grouped = values.reshape(values.shape[0], 1, -1)
        effective_group_size = values.shape[-2] * values.shape[-1]
    elif granularity == "token":
        effective_group_size = values.shape[-1]
        grouped = values.reshape(*values.shape[:-1], 1, values.shape[-1])
    elif granularity == "group":
        if group_size is None or group_size <= 0:
            raise ValueError("positive group_size required for group granularity")
        if values.shape[-1] % group_size:
            raise ValueError("group_size must divide the last dimension")
        grouped = values.reshape(*values.shape[:-1],
                                 values.shape[-1] // group_size, group_size)
        effective_group_size = group_size
    else:
        raise ValueError(f"unsupported granularity: {granularity}")

    ideal_scales = np.max(np.abs(grouped), axis=-1, keepdims=True) / qmax
    ideal_scales = np.maximum(ideal_scales.astype(np.float32),
                              np.finfo(np.float32).tiny)
    normalized = grouped / ideal_scales

    if dither is not None:
        request = DitherRequest(
            shape=normalized.shape,
            tensor_name=tensor_name,
            bits=bits,
            group_size=effective_group_size,
            metadata={} if dither_metadata is None else dither_metadata,
        )
        dither_lsb = np.asarray(dither(request), dtype=np.float32)
        try:
            normalized = normalized + np.broadcast_to(dither_lsb,
                                                       normalized.shape)
        except ValueError as exc:
            raise ValueError("dither output is not broadcastable to tensor") from exc

    codes_grouped = np.clip(np.rint(normalized), -qmax, qmax).astype(np.int16)
    stored_scales = _represent_scale(ideal_scales, scale_format)
    ideal_dequant = codes_grouped.astype(np.float32) * ideal_scales
    dequant = codes_grouped.astype(np.float32) * stored_scales

    return QuantizedTensor(
        codes=codes_grouped.reshape(original_shape),
        dequant=dequant.reshape(original_shape),
        ideal_scale_dequant=ideal_dequant.reshape(original_shape),
        ideal_scales=ideal_scales,
        stored_scales=stored_scales,
    )


def hadamard_blocks(values: np.ndarray, block_size: int | None) -> np.ndarray:
    """Apply an orthonormal Sylvester Hadamard within contiguous blocks."""

    if block_size in (None, 1):
        return values.astype(np.float32, copy=True)
    if block_size <= 0 or block_size & (block_size - 1):
        raise ValueError("Hadamard block size must be a positive power of two")
    if values.shape[-1] % block_size:
        raise ValueError("Hadamard block size must divide the last dimension")

    transformed = values.astype(np.float32, copy=True).reshape(
        *values.shape[:-1], values.shape[-1] // block_size, block_size)
    stride = 1
    while stride < block_size:
        for offset in range(0, block_size, stride * 2):
            left = transformed[..., offset:offset + stride].copy()
            right = transformed[..., offset + stride:offset + 2 * stride].copy()
            transformed[..., offset:offset + stride] = left + right
            transformed[..., offset + stride:offset + 2 * stride] = left - right
        stride *= 2
    transformed /= np.sqrt(float(block_size))
    return transformed.reshape(values.shape)


def softmax(logits: np.ndarray) -> np.ndarray:
    shifted = logits - np.max(logits, axis=-1, keepdims=True)
    exponent = np.exp(shifted.astype(np.float64))
    return (exponent / np.sum(exponent, axis=-1, keepdims=True)).astype(np.float32)


def qkv_reference(q: np.ndarray, k: np.ndarray, v: np.ndarray
                  ) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    head_dim = q.shape[-1]
    logits = np.einsum("bd,btd->bt", q, k, optimize=True) / np.sqrt(head_dim)
    attention = softmax(logits)
    output = np.einsum("bt,btd->bd", attention, v, optimize=True)
    return logits.astype(np.float32), attention, output.astype(np.float32)


def relative_rmse(actual: np.ndarray, reference: np.ndarray) -> float:
    error_power = np.mean((actual.astype(np.float64) - reference) ** 2)
    reference_power = np.mean(reference.astype(np.float64) ** 2)
    return float(np.sqrt(error_power / max(reference_power, 1.0e-30)))


def normalized_bias(actual: np.ndarray, reference: np.ndarray) -> float:
    reference_rms = np.sqrt(np.mean(reference.astype(np.float64) ** 2))
    return float(np.mean(actual.astype(np.float64) - reference) /
                 max(reference_rms, 1.0e-30))


def mean_vector_cosine(actual: np.ndarray, reference: np.ndarray) -> float:
    numerator = np.sum(actual.astype(np.float64) * reference, axis=-1)
    denominator = (np.linalg.norm(actual.astype(np.float64), axis=-1) *
                   np.linalg.norm(reference.astype(np.float64), axis=-1))
    return float(np.mean(numerator / np.maximum(denominator, 1.0e-30)))


def scale_metadata_bytes_per_token(granularity: str, head_dim: int,
                                   context_len: int, scale_bits: int,
                                   group_size: int | None = None) -> float:
    if granularity == "run":
        scales_per_token = 1.0 / context_len
    elif granularity == "token":
        scales_per_token = 1.0
    elif granularity == "group":
        if group_size is None or head_dim % group_size:
            raise ValueError("group size must divide head dimension")
        scales_per_token = head_dim / group_size
    else:
        raise ValueError(f"unsupported granularity: {granularity}")
    return scales_per_token * scale_bits / 8.0
