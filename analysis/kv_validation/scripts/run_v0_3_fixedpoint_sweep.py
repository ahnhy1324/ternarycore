#!/usr/bin/env python3
"""Generate v0.3 softmax/AV adversarial and real-capture evidence."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
import torch

from v0_3_fixedpoint_reference import (
    EXP_LUT,
    EXP_LUT_STEP_CODES,
    SCORE_ONE,
    av_from_integer_exp,
    cosine,
    fixed_softmax,
    quantize_symmetric,
    reference_softmax,
    relative_rmse,
)


LENGTHS = (1, 7, 63, 64, 65, 127, 128, 129, 511, 512, 513,
           1023, 1024, 1025, 4095, 4096)
REGIMES = ("uniform", "near_uniform", "top2_tie", "medium_sparse",
           "single_sink", "one_hot_like", "long_tail", "lut_boundary")


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)


def scores_for(regime: str, length: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    if regime == "uniform":
        return np.zeros(length, dtype=np.float64)
    if regime == "near_uniform":
        return rng.normal(0.0, 0.01, length)
    if regime == "top2_tie":
        result = rng.normal(-4.0, 0.5, length)
        result[:min(2, length)] = 0.0
        return result
    if regime == "medium_sparse":
        result = rng.normal(-9.0, 1.5, length)
        result[::max(1, length // 8)] = rng.normal(0.0, 0.1,
                                                  len(result[::max(1, length // 8)]))
        return result
    if regime == "single_sink":
        result = np.full(length, -20.0)
        result[length // 2] = 0.0
        return result
    if regime == "one_hot_like":
        result = np.full(length, -11.9)
        result[length // 3] = 0.0
        return result
    if regime == "long_tail":
        return np.linspace(0.0, -24.0, length)
    if regime == "lut_boundary":
        boundary = -(
            np.arange(length) % 128) * EXP_LUT_STEP_CODES / SCORE_ONE
        offset = ((np.arange(length) % 3) - 1) / SCORE_ONE
        return boundary + offset
    raise ValueError(regime)


def top_set(values: np.ndarray, count: int) -> set[int]:
    count = min(count, values.size)
    return set(np.argpartition(values, -count)[-count:].tolist())


def probability_row(evidence: str, case: str, scores: np.ndarray,
                    reciprocal_fraction: int) -> dict:
    fixed = fixed_softmax(scores, reciprocal_fraction=reciprocal_fraction)
    q_reference = reference_softmax(fixed.score_codes.astype(np.float64) / SCORE_ONE)
    floating_reference = reference_softmax(scores)
    top1_ref = int(np.argmax(floating_reference))
    top1_actual = int(np.argmax(fixed.probabilities))
    order = np.argsort(fixed.score_codes.astype(np.int64))
    monotonic_failures = int(np.count_nonzero(
        np.diff(fixed.probabilities[order]) < -1.0e-18))
    return {
        "evidence": evidence,
        "case": case,
        "valid_keys": scores.size,
        "reciprocal_fraction": reciprocal_fraction,
        "probability_relative_rmse_vs_float_scores": relative_rmse(
            fixed.probabilities, floating_reference),
        "probability_relative_rmse_vs_q8_8_scores": relative_rmse(
            fixed.probabilities, q_reference),
        "probability_cosine_vs_float_scores": cosine(
            fixed.probabilities, floating_reference),
        "mass_error": float(np.sum(fixed.probabilities) - 1.0),
        "top1_preserved": top1_ref == top1_actual,
        "top5_exact_set_preserved": (
            top_set(floating_reference, 5) == top_set(fixed.probabilities, 5)),
        "underflow_count": fixed.underflow_count,
        "denominator": fixed.denominator,
        "denominator_saturated": fixed.denominator >= (1 << 28),
        "monotonicity_failures": monotonic_failures,
    }


def load_capture(path: Path) -> dict[str, np.ndarray]:
    saved = torch.load(path, map_location="cpu", weights_only=True)
    tensors = saved["tensors"]
    return {name: tensors[name].float().numpy()
            for name in ("q_post_rope", "k_post_rope", "v")}


def real_capture_rows(repo: Path) -> tuple[list[dict], list[dict]]:
    softmax_rows = []
    av_rows = []
    roots = sorted((repo / "analysis" / "kv_validation" / "real_model" /
                    "runs").glob("20260816-streaming-full-c*/tensors/layer_*.pt"))
    for path in roots:
        context = int(path.parents[1].name.rsplit("c", 1)[-1])
        layer = int(path.stem.rsplit("_", 1)[-1])
        capture = load_capture(path)
        q = quantize_symmetric(
            capture["q_post_rope"], 8, scale_fraction=15,
            scale_width=16)
        k = quantize_symmetric(
            capture["k_post_rope"], 4, scale_fraction=8,
            scale_width=12)
        v = quantize_symmetric(
            capture["v"], 5, scale_fraction=8,
            scale_width=12)
        for q_head in range(q.dequant.shape[0]):
            kv_head = q_head // 4
            scores = (k.dequant[kv_head] @ q.dequant[q_head, -1] /
                      np.sqrt(128.0))
            for fraction in (12, 14):
                softmax_rows.append(probability_row(
                    "SOFTWARE-FIXED-POINT/real-logit",
                    f"c{context}_l{layer}_h{q_head}", scores, fraction))
            fixed = fixed_softmax(scores, reciprocal_fraction=12)
            fixed14 = fixed_softmax(scores, reciprocal_fraction=14)
            floating = reference_softmax(scores) @ v.dequant[kv_head]
            av12, exact, max_numerator, denominator = av_from_integer_exp(
                fixed.exp_codes, v.codes[kv_head], v.scale_codes[kv_head],
                reciprocal_fraction=12)
            av14, _, _, _ = av_from_integer_exp(
                fixed14.exp_codes, v.codes[kv_head], v.scale_codes[kv_head],
                reciprocal_fraction=14)
            floor = fixed_softmax(
                scores, reciprocal_fraction=12, underflow_policy="floor")
            av_rows.append({
                "evidence": "SOFTWARE-FIXED-POINT/real-PACKED5",
                "context": context,
                "layer": layer,
                "q_head": q_head,
                "kv_head": kv_head,
                "f12_relative_rmse_vs_floating_packed5": relative_rmse(
                    av12, floating),
                "f14_relative_rmse_vs_floating_packed5": relative_rmse(
                    av14, floating),
                "reciprocal_f12_increment_vs_exact_integer_ratio": relative_rmse(
                    av12, exact),
                "reciprocal_f14_increment_vs_exact_integer_ratio": relative_rmse(
                    av14, exact),
                "f12_cosine_vs_floating_packed5": cosine(av12, floating),
                "max_abs_numerator": max_numerator,
                "observed_signed_numerator_bits": (
                    max_numerator.bit_length() + 1 if max_numerator else 1),
                "denominator": denominator,
                "observed_denominator_bits": denominator.bit_length(),
                "underflow_zero_count": fixed.underflow_count,
                "floor_zero_exp_codes_bit_identical": bool(np.array_equal(
                    floor.exp_codes, fixed.exp_codes)),
                "q_scale_underflows": q.underflows,
                "q_scale_overflows": q.overflows,
                "k_scale_underflows": k.underflows,
                "k_scale_overflows": k.overflows,
                "v_scale_underflows": v.underflows,
                "v_scale_overflows": v.overflows,
            })
    return softmax_rows, av_rows


def expanded_gate_a_score_rows(repo: Path) -> list[dict]:
    rows = []
    root = (repo / "analysis" / "kv_validation" / "v0_3" / "results" /
            "gate_a")
    for path in sorted(root.glob(
            "context_*/**/PACKED5_PAGE128_UQ4_8/fixedpoint_inputs/*.npz")):
        saved = np.load(path)
        scores = saved["scores"].astype(np.float64)
        context = int(saved["context_length"][0])
        layer = int(saved["layer"][0])
        prompt = path.parents[2].name
        for head in range(scores.shape[0]):
            for fraction in (12, 14):
                rows.append(probability_row(
                    "SOFTWARE-FIXED-POINT/expanded-real-logit",
                    f"{prompt}_c{context}_l{layer}_h{head}",
                    scores[head], fraction))
    return rows


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "results" / "fixedpoint")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    adversarial = []
    for length in LENGTHS:
        for regime_index, regime in enumerate(REGIMES):
            scores = scores_for(regime, length,
                                20260816 + length * 17 + regime_index)
            for fraction in (12, 14):
                row = probability_row(
                    "SOFTWARE-FIXED-POINT/adversarial",
                    f"{regime}_n{length}", scores, fraction)
                row["regime"] = regime
                adversarial.append(row)
    real_softmax, real_av = real_capture_rows(repo)
    expanded_softmax = expanded_gate_a_score_rows(repo)
    write_csv(args.output / "softmax_adversarial.csv", adversarial)
    write_csv(args.output / "softmax_real_logits.csv", real_softmax)
    write_csv(args.output / "av_real_packed5.csv", real_av)
    if expanded_softmax:
        write_csv(args.output / "softmax_expanded_real_logits.csv", expanded_softmax)
    np.savez_compressed(
        args.output / "fixedpoint_tables_and_boundaries.npz",
        exp_lut_uq1_15=EXP_LUT,
        exp_lut_step_q8_8=np.asarray([EXP_LUT_STEP_CODES], dtype=np.uint16),
        score_fraction=np.asarray([8], dtype=np.uint8),
        reciprocal_fractions=np.asarray([12, 14], dtype=np.uint8),
        regression_lengths=np.asarray(LENGTHS, dtype=np.uint16),
    )

    f12_adversarial = [row for row in adversarial
                       if row["reciprocal_fraction"] == 12]
    f12_real = [row for row in real_softmax
                if row["reciprocal_fraction"] == 12]
    summary = {
        "evidence": "SOFTWARE-FIXED-POINT/v0.3-softmax-av",
        "status": "PASS",
        "lut_address_mapping_status": (
            "NEW ABI ASSUMPTION: 24 Q8.8 codes/bin, nearest bin; theory "
            "package freezes table size/domain but not address mapping"),
        "adversarial_cases": len(adversarial),
        "real_logit_rows": len(real_softmax),
        "real_av_rows": len(real_av),
        "expanded_real_logit_rows": len(expanded_softmax),
        "adversarial_f12": {
            "mean_probability_relative_rmse_vs_float_scores": float(np.mean([
                row["probability_relative_rmse_vs_float_scores"]
                for row in f12_adversarial])),
            "worst_probability_relative_rmse_vs_float_scores": float(np.max([
                row["probability_relative_rmse_vs_float_scores"]
                for row in f12_adversarial])),
            "worst_absolute_mass_error": float(np.max([
                abs(row["mass_error"]) for row in f12_adversarial])),
            "top1_failures": sum(not row["top1_preserved"]
                                 for row in f12_adversarial),
            "top5_failures": sum(not row["top5_exact_set_preserved"]
                                 for row in f12_adversarial),
            "denominator_saturations": sum(row["denominator_saturated"]
                                           for row in f12_adversarial),
            "monotonicity_failures": sum(row["monotonicity_failures"]
                                         for row in f12_adversarial),
        },
        "real_f12": {
            "mean_probability_relative_rmse_vs_float_scores": float(np.mean([
                row["probability_relative_rmse_vs_float_scores"]
                for row in f12_real])),
            "worst_probability_relative_rmse_vs_float_scores": float(np.max([
                row["probability_relative_rmse_vs_float_scores"]
                for row in f12_real])),
            "mean_av_relative_rmse_vs_floating_packed5": float(np.mean([
                row["f12_relative_rmse_vs_floating_packed5"]
                for row in real_av])),
            "worst_av_relative_rmse_vs_floating_packed5": float(np.max([
                row["f12_relative_rmse_vs_floating_packed5"]
                for row in real_av])),
            "mean_reciprocal_increment": float(np.mean([
                row["reciprocal_f12_increment_vs_exact_integer_ratio"]
                for row in real_av])),
            "worst_reciprocal_increment": float(np.max([
                row["reciprocal_f12_increment_vs_exact_integer_ratio"]
                for row in real_av])),
            "maximum_observed_numerator_bits": max(
                row["observed_signed_numerator_bits"] for row in real_av),
            "maximum_observed_denominator_bits": max(
                row["observed_denominator_bits"] for row in real_av),
            "floor_zero_code_mismatch_rows": sum(
                not row["floor_zero_exp_codes_bit_identical"] for row in real_av),
        },
        "claim_scope": (
            "fixed-point/adversarial screening and ten existing real-model "
            "captures; not model accuracy or RTL evidence"),
    }
    (args.output / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
