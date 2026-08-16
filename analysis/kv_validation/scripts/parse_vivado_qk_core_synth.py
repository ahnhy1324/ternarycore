#!/usr/bin/env python3
"""Parse the QK K4/K5 SHIFT_ADD/DSP/AUTO synthesis comparison."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


CONFIGS = (
    ("regular4_shift_add", "REGULAR4/PACKED5", 4, "SHIFT_ADD"),
    ("regular4_dsp", "REGULAR4/PACKED5", 4, "DSP"),
    ("regular4_auto", "REGULAR4/PACKED5", 4, "AUTO"),
    ("accurate5_shift_add", "ACCURATE5", 5, "SHIFT_ADD"),
    ("accurate5_dsp", "ACCURATE5", 5, "DSP"),
    ("accurate5_auto", "ACCURATE5", 5, "AUTO"),
)


def used(text: str, label: str) -> int:
    match = re.search(rf"^\|\s*{re.escape(label)}\s*\|\s*(\d+)\s*\|",
                      text, re.MULTILINE)
    if not match:
        raise ValueError(f"missing utilization row {label}")
    return int(match.group(1))


def timing(text: str) -> dict:
    summary = re.search(
        r"^clk\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(\d+)\s+(\d+)",
        text, re.MULTILINE)
    period = re.search(r"^clk\s+\{[^}]+\}\s+([0-9.]+)\s+([0-9.]+)",
                       text, re.MULTILINE)
    path = re.search(r"Data Path Delay:\s*([0-9.]+)ns", text)
    if not summary or not period or not path:
        raise ValueError("incomplete timing report")
    wns = float(summary.group(1))
    period_ns = float(period.group(1))
    return {
        "target_period_ns": period_ns,
        "wns_ns": wns,
        "tns_ns": float(summary.group(2)),
        "failing_endpoints": int(summary.group(3)),
        "timing_endpoints": int(summary.group(4)),
        "critical_data_path_ns": float(path.group(1)),
        "estimated_fmax_from_wns_mhz": 1000.0 / (period_ns - wns),
        "target_timing_met": wns >= 0,
    }


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input", type=Path,
        default=repo / "analysis" / "kv_validation" / "hardware_estimates" /
        "vivado_qk_core_2026_1")
    args = parser.parse_args()
    rows = []
    for name, profile, k_bits, style in CONFIGS:
        utilization = (args.input / f"{name}_utilization.rpt").read_text(
            "utf-8", errors="replace")
        timing_text = (args.input / f"{name}_timing_summary.rpt").read_text(
            "utf-8", errors="replace")
        row = {
            "evidence": "VIVADO-POST-SYNTH/OOC",
            "config": name,
            "profile": profile,
            "k_bits": k_bits,
            "multiplier_style": style,
            "part": "xc7a100tcsg324-1",
            "target_clock_mhz": 81.25,
            "slice_luts": used(utilization, "Slice LUTs*"),
            "logic_luts": used(utilization, "LUT as Logic"),
            "lutram_luts": used(utilization, "LUT as Memory"),
            "slice_registers": used(utilization, "Slice Registers"),
            "bram_tiles": used(utilization, "Block RAM Tile"),
            "dsp48e1": used(utilization, "DSPs"),
            **timing(timing_text),
        }
        rows.append(row)
    with (args.input / "summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    result = {
        "evidence": "VIVADO-POST-SYNTH/OOC",
        "status": "PASS" if all(row["target_timing_met"] for row in rows)
        else "PASS_WITH_TIMING_FAILURE",
        "tool": "Vivado 2026.1",
        "part": "xc7a100tcsg324-1",
        "top": "qk_group_dot",
        "protocol": "P16, group128, registered slice reduction, one UQ5.11 scale multiply/group",
        "configurations": rows,
        "limitations": [
            "OOC post-synthesis estimates are not routed implementation Fmax.",
            "REGULAR4 and PACKED5 share the same K4 QK core; packed V5 streaming/AV cost is outside this core comparison.",
            "Score BRAM, softmax, AV, AXI and FIFOs are outside this core-only report.",
        ],
    }
    (args.input / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", "utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
