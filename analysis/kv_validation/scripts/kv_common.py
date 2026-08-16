#!/usr/bin/env python3
"""Shared numerical definitions for the KV software-validation gate.

This is a behavioral floating/fixed-point reference.  It is not called RTL
bit-exact because no v0.2 RTL arithmetic contract has been frozen.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Iterable, Mapping

import numpy as np


HEAD_DIM = 128
Q_BITS = 8
SCALE_FORMATS = ("float", "Q8.8")


@dataclass
class Quantized:
    codes: np.ndarray
    dequant: np.ndarray
    ideal_scale: np.ndarray
    stored_scale: np.ndarray
    saturated_scale_count: int


@dataclass(frozen=True)
class DitherRequest:
    """Inputs exposed to a future deterministic dither implementation.

    Dither values are conventional quantizer-LSB offsets applied before
    round-to-nearest-even.  No G_B, CRC, or other generator mapping is
    selected by this interface.
    """

    shape: tuple[int, ...]
    tensor_name: str
    bits: int
    granularity: str
    metadata: Mapping[str, int | str]


DitherProvider = Callable[[DitherRequest], np.ndarray]


def rms_normalize(values: np.ndarray) -> np.ndarray:
    power = np.mean(values.astype(np.float64) ** 2, axis=-1, keepdims=True)
    return (values / np.maximum(np.sqrt(power), 1.0e-12)).astype(np.float32)


def quantize_symmetric(values: np.ndarray, bits: int,
                       scale_format: str = "float",
                       granularity: str = "token",
                       tensor_name: str = "tensor",
                       dither: DitherProvider | None = None,
                       dither_metadata: Mapping[str, int | str] | None = None,
                       ) -> Quantized:
    """Symmetric narrow-range absmax quantization.

    Low-bit codebooks are `[-(2^(b-1)-1), +(2^(b-1)-1)]`. Codes are chosen
    with the ideal scale. Q8.8 changes only stored dequantization scale, which
    separates scale-representation error from code-selection error.
    """

    if bits < 2 or bits > 16:
        raise ValueError("bits must be in 2..16")
    qmax = (1 << (bits - 1)) - 1
    original_shape = values.shape
    if granularity == "token":
        grouped = values.reshape(*values.shape[:-1], 1, values.shape[-1])
    elif granularity == "run":
        if values.ndim < 2:
            raise ValueError("run granularity needs token and feature axes")
        grouped = values.reshape(1, -1)
    else:
        raise ValueError(f"unsupported granularity {granularity}")

    maxabs = np.max(np.abs(grouped), axis=-1, keepdims=True)
    ideal = maxabs / qmax
    safe = np.where(ideal == 0.0, 1.0, ideal).astype(np.float32)
    normalized = grouped / safe
    if dither is not None:
        request = DitherRequest(
            shape=normalized.shape,
            tensor_name=tensor_name,
            bits=bits,
            granularity=granularity,
            metadata={} if dither_metadata is None else dither_metadata,
        )
        try:
            normalized = normalized + np.broadcast_to(
                np.asarray(dither(request), dtype=np.float32), normalized.shape)
        except ValueError as exc:
            raise ValueError("dither output is not broadcastable to tensor") from exc
    codes = np.clip(np.rint(normalized), -qmax, qmax).astype(np.int16)

    if scale_format == "float":
        stored = safe
        saturated = 0
    elif scale_format == "Q8.8":
        raw = np.rint(safe.astype(np.float64) * 256.0)
        saturated = int(np.count_nonzero((raw < 1.0) | (raw > 32767.0)))
        stored = (np.clip(raw, 1.0, 32767.0) / 256.0).astype(np.float32)
    else:
        raise ValueError(f"unsupported scale format {scale_format}")

    # Preserve exact zero vectors despite the arbitrary safe scale of one.
    codes = np.where(maxabs == 0.0, 0, codes)
    return Quantized(
        codes=codes.reshape(original_shape),
        dequant=(codes.astype(np.float32) * stored).reshape(original_shape),
        ideal_scale=ideal,
        stored_scale=stored,
        saturated_scale_count=saturated,
    )


def softmax(logits: np.ndarray) -> np.ndarray:
    shifted = logits.astype(np.float64) - np.max(logits, axis=-1, keepdims=True)
    exponent = np.exp(shifted)
    return (exponent / np.sum(exponent, axis=-1, keepdims=True)).astype(np.float32)


def relative_rmse(actual: np.ndarray, reference: np.ndarray) -> float:
    error = actual.astype(np.float64) - reference.astype(np.float64)
    denominator = np.mean(reference.astype(np.float64) ** 2)
    return float(np.sqrt(np.mean(error ** 2) / max(denominator, 1.0e-30)))


def normalized_rmse(actual: np.ndarray, reference: np.ndarray) -> float:
    return relative_rmse(actual, reference)


def vector_cosine(actual: np.ndarray, reference: np.ndarray) -> float:
    a = actual.astype(np.float64).reshape(-1)
    b = reference.astype(np.float64).reshape(-1)
    return float(np.dot(a, b) /
                 max(np.linalg.norm(a) * np.linalg.norm(b), 1.0e-30))


def error_distribution(actual: np.ndarray, reference: np.ndarray) -> dict[str, float]:
    error = np.abs(actual.astype(np.float64) - reference.astype(np.float64)).reshape(-1)
    ref_rms = np.sqrt(np.mean(reference.astype(np.float64) ** 2))
    norm = max(ref_rms, 1.0e-30)
    return {
        "max_abs_error_over_ref_rms": float(np.max(error) / norm),
        "p95_abs_error_over_ref_rms": float(np.percentile(error, 95) / norm),
        "p99_abs_error_over_ref_rms": float(np.percentile(error, 99) / norm),
        "bias_over_ref_rms": float(np.mean(actual - reference) / norm),
    }


def attention_stats(attention: np.ndarray) -> dict[str, float]:
    a = attention.astype(np.float64).reshape(-1)
    entropy = -np.sum(a * np.log(np.maximum(a, 1.0e-300)))
    neff = 1.0 / np.sum(a * a)
    return {
        "attention_entropy": float(entropy),
        "max_attention_probability": float(np.max(a)),
        "n_eff": float(neff),
        "top_attention_index": int(np.argmax(a)),
    }


def tensor_family(rng: np.random.Generator, shape: tuple[int, ...],
                  family: str) -> np.ndarray:
    if family == "gaussian":
        values = rng.normal(size=shape)
    elif family == "laplace":
        values = rng.laplace(0.0, 1.0 / np.sqrt(2.0), size=shape)
    elif family == "student_t_df3":
        values = rng.standard_t(3.0, size=shape) / np.sqrt(3.0)
    elif family == "sparse_outliers_0p1pct_x25":
        values = rng.normal(size=shape)
        values[rng.random(shape) < 0.001] *= 25.0
    elif family == "outliers_1pct_x10":
        values = rng.normal(size=shape)
        values[rng.random(shape) < 0.01] *= 10.0
    else:
        raise ValueError(f"unsupported tensor family {family}")
    return rms_normalize(values.astype(np.float32))


def target_attention(rng: np.random.Generator, context_len: int,
                     regime: str) -> np.ndarray:
    if regime == "diffuse":
        target = rng.dirichlet(np.full(context_len, 10.0))
    elif regime == "moderate":
        target = softmax(rng.normal(0.0, 1.0, context_len))[0:context_len]
    elif regime == "sharp":
        target = softmax(rng.normal(0.0, 3.0, context_len))[0:context_len]
    elif regime == "sink":
        remainder = rng.dirichlet(np.ones(context_len - 1)) * 0.5
        target = np.concatenate(([0.5], remainder))
    else:
        raise ValueError(f"unsupported attention regime {regime}")
    target = np.maximum(np.asarray(target, dtype=np.float64), 1.0e-30)
    return (target / np.sum(target)).astype(np.float32)


def controlled_attention_sample(seed: int, context_len: int, regime: str,
                                family: str,
                                head_dim: int = HEAD_DIM
                                ) -> dict[str, np.ndarray | float]:
    """Construct K after target attention so QK reproduces that target."""

    rng = np.random.default_rng(seed)
    q_float = tensor_family(rng, (head_dim,), family)
    q = quantize_symmetric(q_float, Q_BITS).dequant.astype(np.float32)
    target = target_attention(rng, context_len, regime)
    logits = np.log(target.astype(np.float64))
    logits -= np.mean(logits)  # softmax-invariant C chosen for small K range.

    noise = tensor_family(rng, (context_len, head_dim), family)
    q64 = q.astype(np.float64)
    q_power = float(np.dot(q64, q64))
    projection = noise.astype(np.float64) @ q64 / q_power
    orthogonal = noise.astype(np.float64) - projection[:, None] * q64[None, :]
    coefficient = logits * np.sqrt(head_dim) / q_power
    k = (orthogonal + coefficient[:, None] * q64[None, :]).astype(np.float32)
    v = tensor_family(rng, (context_len, head_dim), family)

    realized_logits = (k.astype(np.float64) @ q64) / np.sqrt(head_dim)
    realized_attention = softmax(realized_logits)
    target_error = float(np.max(np.abs(realized_attention - target)))
    if target_error > 2.0e-6:
        raise AssertionError(f"controlled attention mismatch {target_error}")
    output = realized_attention.astype(np.float64) @ v.astype(np.float64)
    return {
        "q": q,
        "k": k,
        "v": v,
        "logits": realized_logits.astype(np.float32),
        "attention": realized_attention.astype(np.float32),
        "output": output.astype(np.float32),
        "target_attention_max_error": target_error,
    }


def first_order_k_prediction(q: np.ndarray, k_reference: np.ndarray,
                             k_quantized: np.ndarray, attention: np.ndarray,
                             v_reference: np.ndarray) -> np.ndarray:
    delta_s = ((k_quantized.astype(np.float64) - k_reference) @
               q.astype(np.float64)) / np.sqrt(q.shape[-1])
    a = attention.astype(np.float64)
    jacobian_delta = a * (delta_s - np.dot(a, delta_s))
    return (jacobian_delta @ v_reference.astype(np.float64)).astype(np.float32)


def storage_per_kv_head(head_dim: int, k_bits: int, v_bits: int,
                        scale_bytes_each: float = 2.0) -> dict[str, float]:
    k_payload = head_dim * k_bits / 8.0
    v_payload = head_dim * v_bits / 8.0
    total = k_payload + v_payload + 2.0 * scale_bytes_each
    return {
        "k_payload_bytes": k_payload,
        "v_payload_bytes": v_payload,
        "scale_metadata_bytes": 2.0 * scale_bytes_each,
        "bytes_per_token_per_kv_head": total,
        "nominal_bits_per_value": (k_bits + v_bits) / 2.0,
        "effective_bits_per_value": total * 8.0 / (2.0 * head_dim),
    }


def pearson(values_a: Iterable[float], values_b: Iterable[float]) -> float:
    a = np.asarray(list(values_a), dtype=np.float64)
    b = np.asarray(list(values_b), dtype=np.float64)
    if a.size < 2 or np.std(a) == 0.0 or np.std(b) == 0.0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])
