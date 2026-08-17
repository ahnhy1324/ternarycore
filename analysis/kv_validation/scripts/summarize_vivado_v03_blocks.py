#!/usr/bin/env python3
"""Create machine-readable summaries from the isolated v0.3 Vivado runs.

The sweep's PASS status means that the tool flow completed.  Timing closure is
reported separately and is true only when routed WNS is non-negative.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


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


def read_last_rows(path: Path) -> dict[str, dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    # A filtered continuation appends rows.  Keep the newest run for a config.
    return {row["config"]: row for row in rows}


def summarize(run_dir: Path) -> list[dict[str, object]]:
    rows = read_last_rows(run_dir / "routed_runs.csv")
    result: list[dict[str, object]] = []
    for config, run in rows.items():
        util_path = run_dir / f"{config}_routed_utilization.rpt"
        timing_path = run_dir / f"{config}_routed_timing_summary.rpt"
        route_path = run_dir / f"{config}_routed_route_status.rpt"
        util_text = util_path.read_text(errors="replace") if util_path.exists() else ""
        timing_text = (
            timing_path.read_text(errors="replace") if timing_path.exists() else ""
        )
        route_text = route_path.read_text(errors="replace") if route_path.exists() else ""

        wns = float(run["wns_ns"]) if run.get("wns_ns") else None
        fmax = (
            float(run["estimated_fmax_mhz"])
            if run.get("estimated_fmax_mhz")
            else None
        )
        route_status = run.get("route_status") or None
        if route_status is None and "Router Completed Successfully" in timing_text:
            route_status = "ROUTED"
        if route_status is None and util_path.exists() and timing_path.exists():
            # The initial pilot predates explicit report_route_status capture;
            # its routed DCP and reports were produced only after successful
            # route_design completion.  Keep this inference visibly labeled.
            route_status = "ROUTED_INFERRED_FROM_REPORTS"

        item: dict[str, object] = {
            "config": config,
            "top": run["top"],
            "part": run["part"],
            "target_clock_mhz": float(run["target_clock_mhz"]),
            "tool_flow_completed": run["status"] == "PASS",
            "route_status": route_status,
            "routed_wns_ns": wns,
            "timing_met": wns is not None and wns >= 0.0,
            "estimated_fmax_mhz_from_wns": fmax,
            "estimated_fmax_is_direct_measurement": False,
            # The shared OOC XDC creates the clock but intentionally cannot
            # choose the parent design's BUFG site, so HD.CLK_SRC is unset for
            # every isolated result and absolute clock skew is not closed.
            "ooc_hd_clk_src_unset": True,
            # OOC interface ports also have no parent-design partition-pin
            # locations.  Input/output path timing is consequently indicative;
            # internal register-to-register timing is the stronger evidence.
            "ooc_hd_partpin_locs_unset": True,
            "critical_source": first_match(
                timing_text, r"^\s*Source:\s+(.+)$"
            ),
            "critical_destination": first_match(
                timing_text, r"^\s*Destination:\s+(.+)$"
            ),
            "critical_data_path_delay_ns": first_match(
                timing_text, r"Data Path Delay:\s+([0-9.]+)ns", float
            ),
            "critical_logic_levels": first_match(
                timing_text, r"Logic Levels:\s+(\d+)", int
            ),
        }
        for field, pattern in UTIL_PATTERNS.items():
            cast = float if field == "bram_tiles" else int
            item[field] = first_match(util_text, pattern, cast)
        if route_text:
            item["routing_error_nets"] = first_match(
                route_text,
                r"# of nets with routing errors[^:]*:\s*(\d+)",
                int,
            )
        else:
            item["routing_error_nets"] = None
        result.append(item)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    args = parser.parse_args()
    rows = summarize(args.run_dir)

    json_path = args.run_dir / "summary.json"
    csv_path = args.run_dir / "summary.csv"
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
