#!/usr/bin/env python3
"""Parse the reproducible Vivado OOC sweep into compact CSV/JSON evidence."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path
from typing import Any


CONFIGS = (
    ("hd64_axi128", 64, 128),
    ("hd64_axi256", 64, 256),
    ("hd128_axi128", 128, 128),
    ("hd128_axi256", 128, 256),
)


def table_used(text: str, label: str) -> tuple[int, int, float]:
    match = re.search(
        rf"^\|\s*{re.escape(label)}\s*\|\s*(\d+)\s*\|\s*\d+\s*\|"
        rf"\s*\d*\s*\|\s*(\d+)\s*\|\s*([0-9.]+)\s*\|",
        text, re.MULTILINE)
    if not match:
        raise ValueError(f"missing utilization row: {label}")
    return int(match.group(1)), int(match.group(2)), float(match.group(3))


def timing_values(text: str) -> dict[str, Any]:
    summary = re.search(
        r"^clk\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(\d+)\s+(\d+)",
        text, re.MULTILINE)
    if not summary:
        raise ValueError("missing clock timing summary")
    path = re.search(
        r"Data Path Delay:\s*([0-9.]+)ns\s*\(logic\s*([0-9.]+)ns.*?"
        r"route\s*([0-9.]+)ns", text)
    if not path:
        raise ValueError("missing critical data-path delay")
    period = re.search(
        r"^clk\s+\{[^}]+\}\s+([0-9.]+)\s+([0-9.]+)",
        text, re.MULTILINE)
    if not period:
        raise ValueError("missing target clock summary")
    wns = float(summary.group(1))
    period_ns = float(period.group(1))
    equivalent_period_ns = period_ns - wns
    return {
        "target_period_ns": period_ns,
        "target_clock_mhz": float(period.group(2)),
        "wns_ns": wns,
        "tns_ns": float(summary.group(2)),
        "failing_endpoints": int(summary.group(3)),
        "timing_endpoints": int(summary.group(4)),
        "critical_data_path_ns": float(path.group(1)),
        "critical_logic_delay_ns": float(path.group(2)),
        "critical_route_delay_ns": float(path.group(3)),
        "equivalent_period_from_wns_ns": equivalent_period_ns,
        "estimated_fmax_from_wns_mhz": 1000.0 / equivalent_period_ns,
        "target_timing_met": wns >= 0,
    }


def parse_hierarchy(text: str, config: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    pattern = re.compile(
        r"^\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"
        r"\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"
        r"\s*(\d+)\s*\|\s*(\d+)\s*\|$", re.MULTILINE)
    for match in pattern.finditer(text):
        rows.append({
            "evidence": "VIVADO-POST-SYNTH",
            "config": config,
            "instance": match.group(1).strip(),
            "module": match.group(2).strip(),
            "total_luts": int(match.group(3)),
            "logic_luts": int(match.group(4)),
            "lutram_luts": int(match.group(5)),
            "srls": int(match.group(6)),
            "flip_flops": int(match.group(7)),
            "ramb36": int(match.group(8)),
            "ramb18": int(match.group(9)),
            "dsp_blocks": int(match.group(10)),
        })
    if not rows:
        raise ValueError("missing hierarchical utilization rows")
    return rows


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=(repo / "analysis" /
                        "kv_validation" / "hardware_estimates" /
                        "vivado_synth_2026_1_timed"))
    parser.add_argument("--output", type=Path, default=(repo / "analysis" /
                        "kv_validation" / "hardware_estimates"))
    args = parser.parse_args()

    rows: list[dict[str, Any]] = []
    hierarchy: list[dict[str, Any]] = []
    for name, head_dim, axi_width in CONFIGS:
        utilization = (args.input / f"{name}_utilization.rpt").read_text(
            encoding="utf-8", errors="replace")
        timing = (args.input / f"{name}_timing_summary.rpt").read_text(
            encoding="utf-8", errors="replace")
        hierarchy_text = (args.input /
                          f"{name}_utilization_hierarchical.rpt").read_text(
                              encoding="utf-8", errors="replace")
        slice_luts = table_used(utilization, "Slice LUTs*")
        logic_luts = table_used(utilization, "LUT as Logic")
        lutram_luts = table_used(utilization, "LUT as Memory")
        registers = table_used(utilization, "Slice Registers")
        bram = table_used(utilization, "Block RAM Tile")
        dsp = table_used(utilization, "DSPs")
        rows.append({
            "evidence": "VIVADO-POST-SYNTH",
            "config": name,
            "head_dim": head_dim,
            "axi_data_width": axi_width,
            "part": "xc7a100tcsg324-1",
            "design_state": "Synthesized/OOC",
            "slice_luts": slice_luts[0],
            "slice_lut_percent": slice_luts[2],
            "logic_luts": logic_luts[0],
            "lutram_luts": lutram_luts[0],
            "slice_registers": registers[0],
            "slice_register_percent": registers[2],
            "bram_tiles": bram[0],
            "dsp48e1": dsp[0],
            "dsp_percent": dsp[2],
            **timing_values(timing),
        })
        hierarchy.extend(parse_hierarchy(hierarchy_text, name))

    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "vivado_synthesis_utilization.csv", rows)
    write_csv(args.output / "vivado_synthesis_hierarchy.csv", hierarchy)

    by_config = {row["config"]: row for row in rows}
    summary = {
        "evidence": "VIVADO-POST-SYNTH",
        "status": "PASS_WITH_TIMING_FAILURE",
        "tool": "Vivado 2026.1 build 6511674",
        "part": "xc7a100tcsg324-1",
        "protocol": {
            "flow": "out-of-context synthesis; no placement or routing",
            "target_clock_mhz": 81.25,
            "top": "axi_kv_cache",
            "p": 16,
            "max_context": 4096,
        },
        "configurations": rows,
        "observations": [
            "All four configurations synthesize successfully, but none meets the 81.25 MHz pre-route timing target.",
            "The unpipelined 16-lane q*(k*scale) reduction is the critical path; simulated 81.25 MHz throughput is not timing-closed.",
            "The 4096x32 logit memory maps to distributed LUTRAM rather than BRAM and dominates top-level LUT memory usage.",
            "AXI width and HEAD_DIM mainly change buffer/register/control cost; P=16 keeps the arithmetic lane count fixed.",
            "Next revision should accumulate raw INT8xINT4 values, apply one scale per group, pipeline the reduction, and use synchronous BRAM or streamed logits.",
        ],
        "resource_deltas": {
            "axi256_minus_axi128_at_head64": {
                field: by_config["hd64_axi256"][field] -
                by_config["hd64_axi128"][field]
                for field in ("slice_luts", "logic_luts", "lutram_luts",
                              "slice_registers", "bram_tiles", "dsp48e1")
            },
            "head128_minus_head64_at_axi128": {
                field: by_config["hd128_axi128"][field] -
                by_config["hd64_axi128"][field]
                for field in ("slice_luts", "logic_luts", "lutram_luts",
                              "slice_registers", "bram_tiles", "dsp48e1")
            },
        },
        "limitations": [
            "Timing is a post-synthesis estimate with HD.CLK_SRC unset in OOC mode; use implementation timing for closure decisions.",
            "The measured RTL has one scale per run and no scale FIFO, burst FIFO, V path, softmax, or Hadamard/dither logic.",
        ],
    }
    (args.output / "vivado_synthesis_summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("parsed 4 Vivado synthesis configurations")


if __name__ == "__main__":
    main()
