#!/usr/bin/env python3
"""Theory-closed v0.3 score, softmax, AV, and reciprocal reference.

The handoff freezes signed Q8.8 scores, a 128-entry UQ1.15 exponential table,
zero below -12, a 28-bit denominator, and normalized reciprocal F=12.  It does
not spell out the LUT address mapping.  This executable ABI uses the natural
Q8.8 partition of the 12-wide domain: 24 score codes (0.09375) per bin, nearest
bin with half steps rounded toward the more-negative bin.
"""

from __future__ import annotations

import dataclasses
import math

import numpy as np


SCORE_FRACTION = 8
SCORE_ONE = 1 << SCORE_FRACTION
UNDERFLOW_SCORE = -12 * SCORE_ONE
EXP_FRACTION = 15
EXP_ONE = 1 << EXP_FRACTION
EXP_LUT_ENTRIES = 128
EXP_LUT_STEP_CODES = 24
DENOMINATOR_BITS = 28
NUMERATOR_BITS = 48


@dataclasses.dataclass(frozen=True)
class QuantizedTensor:
    codes: np.ndarray
    scale_codes: np.ndarray
    dequant: np.ndarray
    ideal_scales: np.ndarray
    underflows: int
    overflows: int


@dataclasses.dataclass(frozen=True)
class FixedSoftmax:
    score_codes: np.ndarray
    delta_codes: np.ndarray
    exp_codes: np.ndarray
    denominator: int
    reciprocal_code: int
    reciprocal_exponent: int
    probabilities: np.ndarray
    underflow_count: int


def exp_lut_uq1_15() -> np.ndarray:
    distance = np.arange(EXP_LUT_ENTRIES, dtype=np.float64)
    values = np.exp(-distance * EXP_LUT_STEP_CODES / SCORE_ONE)
    return np.rint(values * EXP_ONE).clip(0, EXP_ONE).astype(np.uint16)


EXP_LUT = exp_lut_uq1_15()


def score_to_q8_8(scores: np.ndarray) -> np.ndarray:
    values = np.rint(np.asarray(scores, dtype=np.float64) * SCORE_ONE)
    return values.clip(-32768, 32767).astype(np.int16)


def exp_codes_from_scores(score_codes: np.ndarray,
                          underflow_policy: str = "zero") -> tuple[np.ndarray, np.ndarray]:
    scores = np.asarray(score_codes, dtype=np.int64)
    delta = scores - int(np.max(scores))
    distance = -delta
    index = ((distance + EXP_LUT_STEP_CODES // 2) //
             EXP_LUT_STEP_CODES).clip(0, EXP_LUT_ENTRIES - 1)
    exp_codes = EXP_LUT[index].astype(np.uint32)
    below = delta < UNDERFLOW_SCORE
    if underflow_policy == "zero":
        exp_codes[below] = 0
    elif underflow_policy == "floor":
        exp_codes[below] = EXP_LUT[-1]
    else:
        raise ValueError("underflow_policy must be zero or floor")
    return delta.astype(np.int16), exp_codes


def normalized_reciprocal(denominator: int,
                          fractional_bits: int) -> tuple[int, int]:
    if denominator <= 0:
        raise ValueError("softmax denominator must be positive")
    exponent = denominator.bit_length() - 1
    mantissa = denominator / float(1 << exponent)
    code = int(np.rint((1.0 / mantissa) * (1 << fractional_bits)))
    code = min(1 << fractional_bits, max(1, code))
    return code, exponent


def apply_normalized_reciprocal(values: np.ndarray, reciprocal_code: int,
                                exponent: int,
                                fractional_bits: int) -> np.ndarray:
    scale = math.ldexp(float(reciprocal_code),
                       -(fractional_bits + exponent))
    return np.asarray(values, dtype=np.float64) * scale


def fixed_softmax(scores: np.ndarray, *, reciprocal_fraction: int = 12,
                  underflow_policy: str = "zero") -> FixedSoftmax:
    score_codes = score_to_q8_8(scores)
    delta, exp_codes = exp_codes_from_scores(score_codes, underflow_policy)
    denominator = int(np.sum(exp_codes, dtype=np.uint64))
    if denominator <= 0 or denominator >= (1 << DENOMINATOR_BITS):
        raise OverflowError("28-bit softmax denominator contract violated")
    reciprocal_code, exponent = normalized_reciprocal(
        denominator, reciprocal_fraction)
    probabilities = apply_normalized_reciprocal(
        exp_codes, reciprocal_code, exponent, reciprocal_fraction)
    return FixedSoftmax(
        score_codes=score_codes,
        delta_codes=delta,
        exp_codes=exp_codes,
        denominator=denominator,
        reciprocal_code=reciprocal_code,
        reciprocal_exponent=exponent,
        probabilities=probabilities,
        underflow_count=int(np.count_nonzero(delta < UNDERFLOW_SCORE)),
    )


def quantize_symmetric(values: np.ndarray, bits: int, *,
                       scale_fraction: int, scale_width: int,
                       group_size: int = 128) -> QuantizedTensor:
    source = np.asarray(values, dtype=np.float32)
    if source.shape[-1] % group_size:
        raise ValueError("group_size must divide the final dimension")
    qmax = (1 << (bits - 1)) - 1
    grouped = source.reshape(
        *source.shape[:-1], source.shape[-1] // group_size, group_size)
    maximum = np.max(np.abs(grouped), axis=-1, keepdims=True)
    ideal = maximum / qmax
    safe = np.where(maximum == 0, 1.0, ideal)
    codes = np.rint(grouped / safe).clip(-qmax, qmax)
    codes = np.where(maximum == 0, 0, codes).astype(np.int8)
    raw_scale = np.rint(safe.astype(np.float64) * (1 << scale_fraction))
    scale_max = (1 << scale_width) - 1
    underflows = int(np.count_nonzero((maximum != 0) & (raw_scale < 1)))
    overflows = int(np.count_nonzero(raw_scale > scale_max))
    scale_codes = raw_scale.clip(1, scale_max).astype(np.uint16)
    stored = scale_codes.astype(np.float32) / (1 << scale_fraction)
    dequant = (codes.astype(np.float32) * stored).reshape(source.shape)
    return QuantizedTensor(
        codes=codes.reshape(source.shape),
        scale_codes=scale_codes.reshape(*source.shape[:-1], -1),
        dequant=dequant,
        ideal_scales=ideal.reshape(*source.shape[:-1], -1),
        underflows=underflows,
        overflows=overflows,
    )


def av_from_integer_exp(exp_codes: np.ndarray, value_codes: np.ndarray,
                        value_scale_codes: np.ndarray, *,
                        reciprocal_fraction: int = 12,
                        ) -> tuple[np.ndarray, np.ndarray, int, int]:
    exp_values = np.asarray(exp_codes, dtype=np.int64)
    codes = np.asarray(value_codes, dtype=np.int64)
    scales = np.asarray(value_scale_codes, dtype=np.int64).reshape(-1)
    if codes.ndim != 2 or codes.shape[0] != exp_values.size:
        raise ValueError("V codes must be [tokens,dimensions]")
    if scales.shape != (exp_values.size,):
        raise ValueError("one V scale per token is required")
    denominator = int(np.sum(exp_values, dtype=np.int64))
    weights = exp_values * scales
    numerator = weights @ codes
    if np.max(np.abs(numerator), initial=0) >= (1 << (NUMERATOR_BITS - 1)):
        raise OverflowError("signed 48-bit AV numerator overflow")
    exact = numerator.astype(np.float64) / (denominator * (1 << 8))
    reciprocal_code, exponent = normalized_reciprocal(
        denominator, reciprocal_fraction)
    fixed = apply_normalized_reciprocal(
        numerator, reciprocal_code, exponent + 8, reciprocal_fraction)
    return fixed, exact, int(np.max(np.abs(numerator), initial=0)), denominator


def reference_softmax(scores: np.ndarray) -> np.ndarray:
    values = np.asarray(scores, dtype=np.float64)
    shifted = values - np.max(values)
    exponent = np.exp(shifted)
    return exponent / np.sum(exponent)


def relative_rmse(actual: np.ndarray, reference: np.ndarray) -> float:
    a = np.asarray(actual, dtype=np.float64)
    b = np.asarray(reference, dtype=np.float64)
    return float(np.sqrt(np.mean((a - b) ** 2) /
                         max(np.mean(b ** 2), 1.0e-30)))


def cosine(actual: np.ndarray, reference: np.ndarray) -> float:
    a = np.asarray(actual, dtype=np.float64).reshape(-1)
    b = np.asarray(reference, dtype=np.float64).reshape(-1)
    return float(np.dot(a, b) /
                 max(np.linalg.norm(a) * np.linalg.norm(b), 1.0e-30))


if __name__ == "__main__":
    assert EXP_LUT.shape == (128,)
    assert int(EXP_LUT[0]) == 32768
    assert np.all(EXP_LUT[:-1] >= EXP_LUT[1:])
    uniform = fixed_softmax(np.zeros(4096))
    assert uniform.denominator == 4096 * 32768
    assert uniform.denominator < (1 << 28)
    print("v0.3 fixed-point reference self-test PASS")
