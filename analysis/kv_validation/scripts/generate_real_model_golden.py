#!/usr/bin/env python3
"""Generate a canonical real-model golden vector for KV attention RTL v0.2."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import torch


HEAD_DIM = 128
Q_HEADS = 20
KV_HEADS = 5
KV_REPEAT = Q_HEADS // KV_HEADS
GROUP_SIZE = 32
GROUPS = HEAD_DIM // GROUP_SIZE
Q_SCALE_FRACTION = 15
KV_SCALE_FRACTION = 8
SOFTMAX_FRACTION = 15
DELTA_FRACTION = 10
INV_SQRT_FRACTION = 15
INV_SQRT_CODE = round((1.0 / math.sqrt(HEAD_DIM)) * (1 << INV_SQRT_FRACTION))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def quantize_grouped(values: np.ndarray, bits: int, group_size: int,
                     fractional_bits: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    qmax = (1 << (bits - 1)) - 1
    shape = values.shape
    grouped = values.reshape(*shape[:-1], shape[-1] // group_size, group_size)
    maximum = np.max(np.abs(grouped), axis=-1, keepdims=True)
    ideal_scale = np.where(maximum == 0, 1.0, maximum / qmax).astype(np.float32)
    codes = np.clip(np.rint(grouped / ideal_scale), -qmax, qmax).astype(np.int8)
    codes = np.where(maximum == 0, 0, codes).astype(np.int8)
    scale_codes = np.clip(
        np.rint(ideal_scale.astype(np.float64) * (1 << fractional_bits)),
        1, 65535).astype(np.uint16)
    stored_scale = scale_codes.astype(np.float32) / (1 << fractional_bits)
    return (
        codes.reshape(shape),
        scale_codes.reshape(*shape[:-1], -1),
        stored_scale.reshape(*shape[:-1], -1),
    )


def quantize_query(values: np.ndarray) -> tuple[np.ndarray, int, float]:
    maximum = float(np.max(np.abs(values)))
    ideal_scale = 1.0 if maximum == 0 else maximum / 127.0
    codes = np.clip(np.rint(values / ideal_scale), -127, 127).astype(np.int8)
    if maximum == 0:
        codes.fill(0)
    scale_code = int(np.clip(round(ideal_scale * (1 << Q_SCALE_FRACTION)), 1, 65535))
    return codes, scale_code, scale_code / (1 << Q_SCALE_FRACTION)


def pack_int4(values: np.ndarray) -> bytes:
    flat = values.astype(np.int16).reshape(-1)
    if flat.size % 2 or np.any(flat < -7) or np.any(flat > 7):
        raise ValueError("canonical INT4 data must be an even number of -7..+7 codes")
    nibble = (flat & 0xF).astype(np.uint8)
    if np.any(nibble == 8):
        raise AssertionError("reserved INT4 code generated")
    return bytes(nibble[0::2] | (nibble[1::2] << 4))


def softmax(values: np.ndarray) -> np.ndarray:
    shifted = values.astype(np.float64) - np.max(values)
    exponent = np.exp(shifted)
    return (exponent / np.sum(exponent)).astype(np.float32)


def relative_rmse(actual: np.ndarray, reference: np.ndarray) -> float:
    a = actual.astype(np.float64)
    b = reference.astype(np.float64)
    return float(np.sqrt(np.mean((a - b) ** 2) / max(np.mean(b ** 2), 1.0e-30)))


def cosine(actual: np.ndarray, reference: np.ndarray) -> float:
    a = actual.astype(np.float64).reshape(-1)
    b = reference.astype(np.float64).reshape(-1)
    return float(np.dot(a, b) / max(np.linalg.norm(a) * np.linalg.norm(b), 1.0e-30))


def round_shift_signed(values: np.ndarray, shift: int) -> np.ndarray:
    values = values.astype(np.int64)
    magnitude = np.abs(values)
    rounded = (magnitude + (1 << (shift - 1))) >> shift
    return np.where(values < 0, -rounded, rounded).astype(np.int64)


def load_exp_lut(path: Path) -> np.ndarray:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    lut = np.asarray([int(row["exp_q1_15"]) for row in rows], dtype=np.int64)
    if lut.shape != (257,) or lut[0] != 0 or lut[-1] != 32768:
        raise AssertionError("unexpected prep exp LUT")
    return lut


def fixed_softmax(delta_q6_10: np.ndarray, lut: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    delta = np.clip(delta_q6_10.astype(np.int64), -16 << DELTA_FRACTION, 0)
    position = delta + (16 << DELTA_FRACTION)
    index = position >> 6
    remainder = position & 63
    exp_code = np.empty(delta.shape, dtype=np.int64)
    final = index == 256
    exp_code[final] = lut[256]
    normal = ~final
    exp_code[normal] = (
        lut[index[normal]] * (64 - remainder[normal]) +
        lut[index[normal] + 1] * remainder[normal] + 32
    ) >> 6
    total = int(np.sum(exp_code))
    if total <= 0:
        raise AssertionError("fixed softmax exponent sum is zero")
    probability = ((exp_code * (1 << SOFTMAX_FRACTION)) + total // 2) // total
    probability = np.clip(probability, 0, 1 << SOFTMAX_FRACTION).astype(np.uint16)
    return exp_code.astype(np.uint16), probability


def write_binary(path: Path, values: np.ndarray, dtype: str) -> None:
    np.asarray(values).astype(np.dtype(dtype), copy=False).tofile(path)


def write_hex(path: Path, values: np.ndarray, bits: int) -> None:
    mask = (1 << bits) - 1
    digits = (bits + 3) // 4
    lines = [f"{int(value) & mask:0{digits}x}" for value in np.asarray(values).reshape(-1)]
    path.write_text("\n".join(lines) + "\n", "ascii")


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--capture", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" / "runs" /
        "20260816-streaming-full-c128" / "tensors" / "layer_22.pt")
    parser.add_argument(
        "--prep-root", type=Path,
        default=repo / "analysis" / "kv_validation" / "prep" / "kv_rtl_prep")
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" / "golden_v0_2")
    args = parser.parse_args()

    saved = torch.load(args.capture, map_location="cpu", weights_only=True)
    tensors = saved["tensors"]
    context_len = int(saved["context_len"])
    query_position = context_len - 1
    q_all = tensors["q_post_rope"].float().numpy()
    k_all = tensors["k_post_rope"].float().numpy()
    v_all = tensors["v"].float().numpy()

    quantized_k: dict[int, tuple[np.ndarray, np.ndarray, np.ndarray]] = {}
    quantized_v: dict[int, tuple[np.ndarray, np.ndarray, np.ndarray]] = {}
    for kv_head in range(KV_HEADS):
        quantized_k[kv_head] = quantize_grouped(
            k_all[kv_head], 4, GROUP_SIZE, KV_SCALE_FRACTION)
        quantized_v[kv_head] = quantize_grouped(
            v_all[kv_head], 4, GROUP_SIZE, KV_SCALE_FRACTION)

    candidates: list[dict] = []
    for q_head in range(Q_HEADS):
        kv_head = q_head // KV_REPEAT
        q_reference = q_all[q_head, query_position]
        q_code, q_scale_code, q_scale = quantize_query(q_reference)
        k_code, _, k_scale = quantized_k[kv_head]
        v_code, _, v_scale = quantized_v[kv_head]
        k_dequant = (k_code.reshape(context_len, GROUPS, GROUP_SIZE).astype(np.float32) *
                     k_scale[..., None]).reshape(context_len, HEAD_DIM)
        v_dequant = (v_code.reshape(context_len, GROUPS, GROUP_SIZE).astype(np.float32) *
                     v_scale[..., None]).reshape(context_len, HEAD_DIM)
        q_dequant = q_code.astype(np.float32) * q_scale
        reference_probability = softmax(k_all[kv_head] @ q_reference / math.sqrt(HEAD_DIM))
        quant_probability = softmax(k_dequant @ q_dequant / math.sqrt(HEAD_DIM))
        reference_output = reference_probability @ v_all[kv_head]
        quant_output = quant_probability @ v_dequant
        candidates.append({
            "q_head": q_head,
            "kv_head": kv_head,
            "q_scale_code": q_scale_code,
            "output_relative_rmse": relative_rmse(quant_output, reference_output),
            "output_cosine": cosine(quant_output, reference_output),
        })

    selected = max(candidates, key=lambda row: row["output_relative_rmse"])
    q_head = int(selected["q_head"])
    kv_head = int(selected["kv_head"])
    q_reference = q_all[q_head, query_position]
    k_reference = k_all[kv_head]
    v_reference = v_all[kv_head]
    q_code, q_scale_code, q_scale = quantize_query(q_reference)
    k_code, k_scale_code, k_scale = quantized_k[kv_head]
    v_code, v_scale_code, v_scale = quantized_v[kv_head]

    q_dequant = q_code.astype(np.float32) * q_scale
    k_grouped = k_code.reshape(context_len, GROUPS, GROUP_SIZE)
    v_grouped = v_code.reshape(context_len, GROUPS, GROUP_SIZE)
    k_dequant = (k_grouped.astype(np.float32) * k_scale[..., None]).reshape(
        context_len, HEAD_DIM)
    v_dequant = (v_grouped.astype(np.float32) * v_scale[..., None]).reshape(
        context_len, HEAD_DIM)

    q_grouped = q_code.reshape(GROUPS, GROUP_SIZE).astype(np.int32)
    qk_group = np.sum(k_grouped.astype(np.int32) * q_grouped[None], axis=-1,
                      dtype=np.int32)
    qk_raw = np.sum(qk_group, axis=-1, dtype=np.int32)
    k_scaled_accum = np.sum(
        qk_group.astype(np.int64) * k_scale_code.astype(np.int64), axis=-1)
    logit_numerator = (
        k_scaled_accum * np.int64(q_scale_code) * np.int64(INV_SQRT_CODE))
    quant_logits = k_dequant @ q_dequant / math.sqrt(HEAD_DIM)
    hardware_logits = logit_numerator.astype(np.float64) / float(1 << 38)
    max_numerator = int(np.max(logit_numerator))
    delta_numerator = logit_numerator - max_numerator
    delta_q6_10 = np.clip(round_shift_signed(delta_numerator, 28), -16384, 0).astype(
        np.int32)

    lut = load_exp_lut(args.prep_root / "softmax" / "exp_lut_candidate.csv")
    exp_code, probability_code = fixed_softmax(delta_q6_10, lut)
    fixed_probability = probability_code.astype(np.float32) / (1 << SOFTMAX_FRACTION)
    quant_probability = softmax(quant_logits)
    reference_probability = softmax(k_reference @ q_reference / math.sqrt(HEAD_DIM))

    av_accum = np.sum(
        probability_code.astype(np.int64)[:, None, None] *
        v_grouped.astype(np.int64) * v_scale_code.astype(np.int64)[..., None],
        axis=0).reshape(HEAD_DIM)
    fixed_output = av_accum.astype(np.float32) / float(1 << 23)
    quant_output = quant_probability @ v_dequant
    reference_output = reference_probability @ v_reference

    args.output.mkdir(parents=True, exist_ok=True)
    files: dict[str, Path] = {
        "q": args.output / "q_int8.bin",
        "q_scale": args.output / "q_scale_u16.bin",
        "k": args.output / "k_int4.bin",
        "k_scale": args.output / "k_scale_q8_8_u16.bin",
        "v": args.output / "v_int4.bin",
        "v_scale": args.output / "v_scale_q8_8_u16.bin",
        "qk_group": args.output / "expected_qk_group_i32.bin",
        "qk_raw": args.output / "expected_qk_i32.bin",
        "k_scaled_accum": args.output / "expected_k_scaled_accum_i64.bin",
        "logit_numerator": args.output / "expected_logit_numerator_i64.bin",
        "softmax_delta": args.output / "expected_softmax_delta_q6_10_i32.bin",
        "exp": args.output / "expected_exp_q1_15_u16.bin",
        "probability": args.output / "expected_softmax_q0_15_u16.bin",
        "av_accum": args.output / "expected_av_accum_i64.bin",
        "attention_output": args.output / "expected_attention_output_fp32.bin",
        "reference_output": args.output / "reference_attention_output_fp32.bin",
    }
    files["q"].write_bytes(q_code.tobytes())
    write_binary(files["q_scale"], np.asarray([q_scale_code]), "<u2")
    files["k"].write_bytes(pack_int4(k_code))
    write_binary(files["k_scale"], k_scale_code, "<u2")
    files["v"].write_bytes(pack_int4(v_code))
    write_binary(files["v_scale"], v_scale_code, "<u2")
    write_binary(files["qk_group"], qk_group, "<i4")
    write_binary(files["qk_raw"], qk_raw, "<i4")
    write_binary(files["k_scaled_accum"], k_scaled_accum, "<i8")
    write_binary(files["logit_numerator"], logit_numerator, "<i8")
    write_binary(files["softmax_delta"], delta_q6_10, "<i4")
    write_binary(files["exp"], exp_code, "<u2")
    write_binary(files["probability"], probability_code, "<u2")
    write_binary(files["av_accum"], av_accum, "<i8")
    write_binary(files["attention_output"], fixed_output, "<f4")
    write_binary(files["reference_output"], reference_output, "<f4")

    hex_files = {
        "q": args.output / "q_int8.hex",
        "k_codes": args.output / "k_int4_codes.hex",
        "k_scale": args.output / "k_scale_q8_8_u16.hex",
        "expected_k_scaled_accum": args.output / "expected_k_scaled_accum_i64.hex",
    }
    write_hex(hex_files["q"], q_code, 8)
    write_hex(hex_files["k_codes"], k_code, 4)
    write_hex(hex_files["k_scale"], k_scale_code, 16)
    write_hex(hex_files["expected_k_scaled_accum"], k_scaled_accum, 64)

    metrics = {
        "q_int8_tensor_relative_rmse": relative_rmse(q_dequant, q_reference),
        "k_int4_tensor_relative_rmse": relative_rmse(k_dequant, k_reference),
        "v_int4_tensor_relative_rmse": relative_rmse(v_dequant, v_reference),
        "hardware_logit_vs_quantized_float_relative_rmse": relative_rmse(
            hardware_logits, quant_logits),
        "fixed_softmax_vs_quantized_float_relative_rmse": relative_rmse(
            fixed_probability, quant_probability),
        "fixed_softmax_sum": float(np.sum(fixed_probability)),
        "fixed_output_vs_quantized_float_relative_rmse": relative_rmse(
            fixed_output, quant_output),
        "fixed_output_vs_reference_relative_rmse": relative_rmse(
            fixed_output, reference_output),
        "fixed_output_vs_reference_cosine": cosine(fixed_output, reference_output),
        "quantized_float_output_vs_reference_relative_rmse": relative_rmse(
            quant_output, reference_output),
    }
    manifest = {
        "schema_version": "rtl-golden-0.2",
        "evidence": "REAL-MODEL-VALIDATED/custom-streaming-reference",
        "claim_scope": "tensor and attention distortion only; not accuracy or perplexity",
        "checkpoint_model_sha256": (
            "8143ae115ed6babe5e5ada8fb8c5b769d8f417802b2db042ad98b4f7ed73975b"),
        "source_capture": str(args.capture.resolve()),
        "source_capture_sha256": sha256(args.capture),
        "layer": int(saved["layer"]),
        "context_length": context_len,
        "query_position": query_position,
        "q_head": q_head,
        "kv_head": kv_head,
        "selection": "highest K4/V4 group32 final-query output RMSE across 20 Q heads",
        "head_dim": HEAD_DIM,
        "group_size": GROUP_SIZE,
        "groups_per_vector": GROUPS,
        "q_format": "signed INT8; symmetric -127..+127",
        "q_scale_format": "unsigned UQ1.15",
        "kv_format": "signed INT4; symmetric -7..+7; 0x8 reserved",
        "kv_scale_format": "unsigned Q8.8",
        "packing": "two INT4 values/byte; lower-index element in low nibble",
        "endianness": "little",
        "inv_sqrt_head_dim": {
            "format": "unsigned Q1.15",
            "code": INV_SQRT_CODE,
            "value": INV_SQRT_CODE / (1 << INV_SQRT_FRACTION),
        },
        "softmax_candidate": {
            "delta_format": "signed Q6.10 after subtract-max",
            "delta_clamp": [-16.0, 0.0],
            "exp_format": "unsigned Q1.15",
            "probability_format": "unsigned Q0.15",
            "normalization": "rounded exact integer division; reciprocal RTL may differ within tolerance",
        },
        "metrics": metrics,
        "head_candidates": candidates,
        "files": {
            name: {"path": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}
            for name, path in files.items()
        },
        "testbench_hex_files": {
            name: {"path": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}
            for name, path in hex_files.items()
        },
        "exact_contract": [
            "q/k/v packed codes",
            "scale codes",
            "raw group QK sums",
            "K-scaled accumulator",
            "logit numerator",
            "softmax delta clamp and LUT interpolation",
            "AV integer accumulator when probability codes match",
        ],
        "tolerance_contract": {
            "reciprocal_probability_code_lsb": 2,
            "attention_output_absolute_lsb": "derived after AV output format freeze",
        },
    }
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", "utf-8")
    print(json.dumps({
        "status": "PASS", "q_head": q_head, "kv_head": kv_head,
        "metrics": metrics,
    }, indent=2))


if __name__ == "__main__":
    main()
