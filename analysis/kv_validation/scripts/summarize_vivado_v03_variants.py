#!/usr/bin/env python3
"""Summarize retained v0.3 implementation revisions.

The current sweep summary intentionally contains only the newest result for
each configuration.  This companion table reads the explicitly retained
report prefixes so architecture decisions remain reproducible.  An estimated
Fmax derived from routed WNS is labeled as an estimate, never as a direct
measurement or board result.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


TARGET_MHZ = 81.25
TARGET_PERIOD_NS = 1000.0 / TARGET_MHZ

VARIANTS = (
    ("decoder_2x2", "decoder", "2x2 / two symbols per lane", "routed"),
    ("decoder_4x1_prefinalize", "decoder", "4x1 initial", "routed"),
    ("decoder_4x1_finalize_pending", "decoder", "4x1 registered finalize", "routed"),
    ("decoder_4x1", "decoder", "4x1 direct registered completion", "routed"),
    ("qk_k4_auto", "qk", "K4 AUTO registered tree", "routed"),
    ("softmax_engine_prebram", "softmax", "3-D score array, inference failure", "post_synth"),
    ("softmax_engine_div24", "softmax", "BRAM rows and inferred divide-by-24", "routed"),
    ("softmax_engine", "softmax", "BRAM rows and exact reciprocal multiply", "routed"),
    ("av_v5_csd_overflow_guard", "av", "CSD with runtime overflow guard", "routed"),
    ("av_v5_dsp_overflow_guard", "av", "forced DSP with runtime overflow guard", "routed"),
    ("av_v5_auto_overflow_guard", "av", "AUTO with runtime overflow guard", "routed"),
    ("av_v5_csd", "av", "CSD with analytical width bound", "routed"),
    ("av_v5_dsp", "av", "forced DSP with analytical width bound", "routed"),
    ("av_v5_auto", "av", "AUTO with analytical width bound", "routed"),
)

UTIL_PATTERNS = {
    "slice_luts": r"^\| Slice LUTs\*?\s+\|\s*(\d+)",
    "lut_as_logic": r"^\|\s+LUT as Logic\s+\|\s*(\d+)",
    "lut_as_memory": r"^\|\s+LUT as Memory\s+\|\s*(\d+)",
    "slice_registers": r"^\| Slice Registers\s+\|\s*(\d+)",
    "bram_tiles": r"^\| Block RAM Tile\s+\|\s*([0-9.]+)",
    "dsps": r"^\| DSPs\s+\|\s*(\d+)",
}


def first_match(text: str, pattern: str, cast=str):
    match = re.search(pattern, text, flags=re.MULTILINE)
    return cast(match.group(1)) if match else None


def timing_wns(text: str) -> float | None:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if "WNS(ns)" not in line:
            continue
        for candidate in lines[index + 1 : index + 5]:
            match = re.match(r"^\s*(-?\d+\.\d+)\s+", candidate)
            if match:
                return float(match.group(1))
    return None


def summarize(run_dir: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for prefix, block, revision, phase in VARIANTS:
        util_path = run_dir / f"{prefix}_{phase}_utilization.rpt"
        timing_path = run_dir / f"{prefix}_{phase}_timing_summary.rpt"
        if not util_path.exists() and not timing_path.exists():
            continue
        util_text = util_path.read_text(errors="replace") if util_path.exists() else ""
        timing_text = timing_path.read_text(errors="replace") if timing_path.exists() else ""
        wns = timing_wns(timing_text)
        fmax = None
        if wns is not None:
            effective_period = TARGET_PERIOD_NS - wns
            if effective_period > 0:
                fmax = 1000.0 / effective_period
        item: dict[str, object] = {
            "report_prefix": prefix,
            "block": block,
            "revision": revision,
            "implementation_phase": phase,
            "target_clock_mhz": TARGET_MHZ,
            "wns_ns": wns,
            "timing_met": phase == "routed" and wns is not None and wns >= 0,
            "estimated_fmax_mhz_from_wns": round(fmax, 3) if fmax else None,
            "estimated_fmax_is_direct_measurement": False,
            "route_completed": phase == "routed",
            "ooc_hd_clk_src_unset": True,
            "ooc_hd_partpin_locs_unset": True,
        }
        for field, pattern in UTIL_PATTERNS.items():
            cast = float if field == "bram_tiles" else int
            item[field] = first_match(util_text, pattern, cast)
        rows.append(item)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    args = parser.parse_args()
    rows = summarize(args.run_dir)
    json_path = args.run_dir / "variant_comparison.json"
    csv_path = args.run_dir / "variant_comparison.csv"
    json_path.write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    fieldnames = list(rows[0]) if rows else []
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {csv_path}")
    print(f"wrote {json_path}")


if __name__ == "__main__":
    main()
