#!/usr/bin/env python3
"""Generate storage-aware Amdahl estimates for the KV-cache roadmap."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


CURRENT_TOKEN_MS = 4762.4
CALLS_PER_TOKEN = 448
CURRENT_COMPONENTS_MS = {
    "QK logits": 573.9,
    "softmax": 617.4,
    "attention-weighted V": 1035.0,
    "paging/cache movement": 645.7,
    "normalization/quantization": 505.4,
    "QK-norm/RoPE/quantize": 401.8,
    "MLP activation": 368.5,
    "ternary projections": 345.9,
    "KV write/bit-slice": 268.7,
}


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fields: list[str] = []
    for row in rows:
        for field in row:
            if field not in fields:
                fields.append(field)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path,
                        default=repo_root / "docs" / "runs")
    args = parser.parse_args()
    cycle_report = json.loads(
        (args.output_dir / "kv-v02-cycle.json").read_text(encoding="utf-8"))
    cycle_512_128 = next(row for row in cycle_report["measured"]
                         if row["axi_width"] == 128 and row["context_len"] == 512)
    qk_proposed_ms = cycle_512_128["latency_us"] * CALLS_PER_TOKEN / 1000.0

    # Existing V is a 256-byte physical record at HEAD_DIM=128.  The target
    # HEAD_DIM=64 INT4+Q8.8-token-scale record is 34 bytes.  Keep the equal-
    # dimension sensitivity (66 bytes at dim=128) separate.
    current_pv_call_ms = 2.310
    pv_fixed_call_ms = 0.558
    pv_variable_call_ms = current_pv_call_ms - pv_fixed_call_ms
    target64_v_ratio = 256.0 / 34.0
    equal128_v_ratio = 256.0 / 66.0
    quantized_v_target64_ms = (
        pv_fixed_call_ms + pv_variable_call_ms / target64_v_ratio) * CALLS_PER_TOKEN
    quantized_v_equal128_ms = (
        pv_fixed_call_ms + pv_variable_call_ms / equal128_v_ratio) * CALLS_PER_TOKEN

    # A 16-lane AV engine performs the same 64 MACs/key as QK.  The 25% margin
    # covers scale application and writing the 64-element result.  This is an
    # analytical target, not an RTL measurement.
    av_accumulation_ms = qk_proposed_ms * 1.25
    # Three streaming passes over 448*512 scores have an 8.47 ms raw lower
    # bound at one score/cycle and 81.25 MHz.  Use 20 ms to include LUT exp,
    # reductions, division/normalization, and control until RTL exists.
    softmax_proposed_ms = 20.0

    proposed = {
        "QK logits": (qk_proposed_ms,
                      "RTL-simulated v0.1 at HEAD_DIM=64; burst/FIFO v0.2 can improve further"),
        "softmax": (softmax_proposed_ms,
                    "Analytical streaming estimate; 8.47 ms three-pass raw lower bound"),
        "attention-weighted V": (av_accumulation_ms,
                                 "Analytical 16-lane streaming AV estimate with 25% margin"),
        "paging/cache movement": (352.2,
                                  "Measured repository no-flush paging result"),
        "normalization/quantization": (21.4,
                                       "Measured fabric NQF sum from operator budget"),
        "QK-norm/RoPE/quantize": (401.8, "No v0.2 change proposed in this analysis"),
        "MLP activation": (368.5, "No v0.2 change proposed in this analysis"),
        "ternary projections": (345.9, "No v0.2 change proposed in this analysis"),
        "KV write/bit-slice": (268.7,
                               "Hold current budget until an INT4 write quantizer is measured"),
    }
    actions = {
        "QK logits": "Separate scale plane; 16-vector bursts; K/scale FIFOs; double buffering",
        "softmax": "Streaming max/exp/sum/normalize block after QK/AV interface freezes",
        "attention-weighted V": "Next distinct RTL block: INT4 V streamer plus 16-lane AV MAC",
        "paging/cache movement": "Persistent CDMA path; remove reset/cache-flush overhead",
        "normalization/quantization": "Use existing fabric normalizer in the token path",
        "QK-norm/RoPE/quantize": "Profile after attention path; preserve per-token scales",
        "MLP activation": "Profile after attention and paging improvements",
        "ternary projections": "Weight-page reuse/caching rather than more MAC lanes",
        "KV write/bit-slice": "Replace bit-slice writer with row-major INT4 K/V producer",
    }
    component_rows = []
    for component, current_ms in CURRENT_COMPONENTS_MS.items():
        proposed_ms, basis = proposed[component]
        component_rows.append({
            "component": component,
            "current_latency_ms_per_token": current_ms,
            "current_fraction_of_token": current_ms / CURRENT_TOKEN_MS,
            "roadmap_proposed_latency_ms_per_token": proposed_ms,
            "roadmap_proposed_kind": basis,
            "next_action": actions[component],
        })

    def scenario(name: str, replacements: dict[str, float], note: str,
                 dimension_changed: bool = True) -> dict[str, Any]:
        total = CURRENT_TOKEN_MS
        for component, latency in replacements.items():
            total += latency - CURRENT_COMPONENTS_MS[component]
        return {
            "scenario": name,
            "estimated_latency_ms_per_token": total,
            "estimated_tokens_per_second": 1000.0 / total,
            "speedup_vs_current": CURRENT_TOKEN_MS / total,
            "replacements": "; ".join(f"{key}={value:.3f}ms"
                                        for key, value in replacements.items()),
            "head_dimension_changed_from_current_128_to_target_64": dimension_changed,
            "estimate_note": note,
        }

    scenarios = [
        scenario("current", {}, "Measured operator-budget baseline", False),
        scenario("QK_only", {"QK logits": qk_proposed_ms},
                 "Uses measured randomized-stall v0.1 QK latency"),
        scenario("QK_plus_quantized_V_storage",
                 {"QK logits": qk_proposed_ms,
                  "attention-weighted V": quantized_v_target64_ms},
                 "Only the measured position-dependent PV portion scales with 256B/34B traffic"),
        scenario("QK_plus_quantized_V_equal128_sensitivity",
                 {"QK logits": qk_proposed_ms,
                  "attention-weighted V": quantized_v_equal128_ms},
                 "Equal-dimension V sensitivity uses 256B/66B, not the target64 ratio",
                 False),
        scenario("QK_plus_V_accumulation",
                 {"QK logits": qk_proposed_ms,
                  "attention-weighted V": av_accumulation_ms},
                 "V accumulation is analytical, based on QK work plus 25% margin"),
        scenario("full_attention_path",
                 {"QK logits": qk_proposed_ms,
                  "softmax": softmax_proposed_ms,
                  "attention-weighted V": av_accumulation_ms},
                 "Softmax and V accumulation are analytical targets, not RTL measurements"),
        scenario("full_attention_plus_known_system_fixes",
                 {"QK logits": qk_proposed_ms,
                  "softmax": softmax_proposed_ms,
                  "attention-weighted V": av_accumulation_ms,
                  "paging/cache movement": 352.2,
                  "normalization/quantization": 21.4},
                 "Adds repository-measured paging/no-flush and fabric-normalizer results"),
    ]

    write_csv(args.output_dir / "kv-v02-amdahl.csv", component_rows)
    write_csv(args.output_dir / "kv-v02-scenarios.csv", scenarios)
    report = {
        "schema_version": 1,
        "warning": "Analytical system estimates are not end-to-end model measurements.",
        "current_token_ms": CURRENT_TOKEN_MS,
        "assumptions": {
            "calls_per_token": CALLS_PER_TOKEN,
            "qk_proposed_ms": qk_proposed_ms,
            "quantized_v_target64_ms": quantized_v_target64_ms,
            "quantized_v_equal128_ms": quantized_v_equal128_ms,
            "av_accumulation_ms": av_accumulation_ms,
            "softmax_proposed_ms": softmax_proposed_ms,
        },
        "components": component_rows,
        "scenarios": scenarios,
    }
    (args.output_dir / "kv-v02-system.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("KV system analysis PASS")
    for row in scenarios:
        print(row["scenario"], f"{row['estimated_latency_ms_per_token']:.1f} ms",
              f"{row['speedup_vs_current']:.2f}x")


if __name__ == "__main__":
    main()
