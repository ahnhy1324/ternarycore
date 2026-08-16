#!/usr/bin/env python3
"""Reproduce current KV-engine cycle accounting and v0.2 estimates."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any


CLOCK_HZ = 81_250_000.0
CATEGORY_PATTERN = re.compile(
    r"CYCLE_ACCOUNT width=(?P<axi_width>\d+) length=(?P<context_len>\d+) "
    r"total=(?P<total_cycles>\d+) issue=(?P<issue>\d+) "
    r"reader_launch=(?P<reader_launch>\d+) axi_ar=(?P<axi_ar>\d+) "
    r"axi_r_empty=(?P<axi_r_empty>\d+) "
    r"axi_r_transfer=(?P<axi_r_transfer>\d+) "
    r"beat_handoff=(?P<beat_handoff>\d+) mac=(?P<mac>\d+) "
    r"result=(?P<result>\d+) other=(?P<other>\d+)"
)


def executable(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    windows_candidate = Path("C:/iverilog/bin") / f"{name}.exe"
    if windows_candidate.exists():
        return str(windows_candidate)
    raise FileNotFoundError(f"{name} is required for cycle accounting")


def simulate(repo_root: Path, axi_width: int) -> tuple[str, list[dict[str, int]]]:
    iverilog = executable("iverilog")
    vvp = executable("vvp")
    sources = [
        repo_root / "tb" / "tb_kv_cache_engine.v",
        repo_root / "rtl" / "kv_addr_gen.v",
        repo_root / "rtl" / "int4_unpack.v",
        repo_root / "rtl" / "kv_dequant.v",
        repo_root / "rtl" / "qk_dot.v",
        repo_root / "rtl" / "kv_reader.v",
        repo_root / "rtl" / "kv_cache_engine.v",
    ]
    with tempfile.TemporaryDirectory(prefix="kv-cycle-") as temporary:
        image = Path(temporary) / f"kv_cycle_{axi_width}.vvp"
        command = [iverilog, "-g2012", "-DCYCLE_ACCOUNT_ONLY"]
        if axi_width != 128:
            command.append(f"-DAXI_DATA_WIDTH_VAL={axi_width}")
        command.extend(["-o", str(image), *map(str, sources)])
        subprocess.run(command, cwd=repo_root, check=True, timeout=60)
        completed = subprocess.run(
            [vvp, str(image)], cwd=repo_root, check=True, timeout=180,
            text=True, capture_output=True)
    if "TB PASS: KV cycle accounting" not in completed.stdout:
        raise RuntimeError(f"cycle-accounting test did not pass:\n{completed.stdout}")
    rows = [{key: int(value) for key, value in match.groupdict().items()}
            for match in CATEGORY_PATTERN.finditer(completed.stdout)]
    if {row["context_len"] for row in rows} != {512, 4096}:
        raise RuntimeError(f"missing cycle-accounting rows:\n{completed.stdout}")
    return completed.stdout, rows


def measured_row(raw: dict[str, int]) -> dict[str, Any]:
    categories = ("issue", "reader_launch", "axi_ar", "axi_r_empty",
                  "axi_r_transfer", "beat_handoff", "mac", "result", "other")
    if sum(raw[name] for name in categories) != raw["total_cycles"]:
        raise ValueError(f"cycle categories do not sum for {raw}")
    context_len = raw["context_len"]
    total = raw["total_cycles"]
    return {
        **raw,
        "transaction_control_cycles": (raw["issue"] + raw["reader_launch"] +
                                       raw["axi_ar"]),
        "non_mac_cycles": total - raw["mac"],
        "cycles_per_key": total / context_len,
        "latency_us": total / CLOCK_HZ * 1.0e6,
        "mac_utilization": raw["mac"] / total,
        "mkeys_per_second": context_len / (total / CLOCK_HZ) / 1.0e6,
        "effective_k_bandwidth_mb_s": (
            context_len * 32.0 / (total / CLOCK_HZ) / 1.0e6),
        "measurement_kind": "RTL simulation with deterministic randomized stalls",
    }


def option_rows(measured: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_key = {(row["axi_width"], row["context_len"]): row for row in measured}
    rows: list[dict[str, Any]] = []
    for context_len in (512, 4096):
        base = by_key[(128, context_len)]
        wide = by_key[(256, context_len)]
        total = base["total_cycles"]

        def add(option: str, estimated_cycles: float, basis: str,
                axi_width: int = 128) -> None:
            rows.append({
                "context_len": context_len,
                "option": option,
                "axi_width": axi_width,
                "estimated_cycles": estimated_cycles,
                "estimated_latency_us": estimated_cycles / CLOCK_HZ * 1.0e6,
                "estimated_mac_utilization": 4.0 * context_len / estimated_cycles,
                "speedup_vs_current_128": total / estimated_cycles,
                "basis": basis,
                "estimate_not_additive": True,
            })

        add("current_128_measured", total,
            "Measured state accounting; deterministic randomized stalls")
        add("A_256bit_bus", wide["total_cycles"],
            "Measured 256-bit parameterization under the same stall seed", 256)

        fifo_cycles = total - base["beat_handoff"]
        add("B_deeper_K_FIFO", fifo_cycles,
            "Conservative standalone estimate: remove explicit beat-handoff bubbles only")

        scale_beats = math.ceil(context_len / 8)  # eight 16-bit scales/128-bit beat
        scale_bursts = math.ceil(scale_beats / 256)
        naive_scale_cycles = scale_beats + 4 * scale_bursts
        add("C_scale_FIFO_prefetch", total,
            ("Scale traffic hidden behind K/MAC after startup; avoids approximately "
             f"{naive_scale_cycles} serialized scale cycles"))

        burst_vectors = 16
        burst_count = math.ceil(context_len / burst_vectors)
        transaction = base["transaction_control_cycles"]
        burst_transaction = transaction * burst_count / context_len
        burst_cycles = total - transaction + burst_transaction
        add("D_16vector_AXI_bursts", burst_cycles,
            "Reduce per-token issue/launch/AR cycles in proportion to transaction count; no overlap")

        memory_path = (base["transaction_control_cycles"] + base["axi_r_empty"] +
                       base["axi_r_transfer"] + base["beat_handoff"])
        double_buffer_cycles = max(base["mac"], memory_path) + base["result"]
        add("E_double_buffer", double_buffer_cycles,
            "Overlap current memory path and MAC path; retains per-token result bubbles")

        scheduled_cycles = total - base["result"]
        add("F_continuous_MAC_schedule", scheduled_cycles,
            "Remove one per-token result/control bubble; memory path unchanged")

        streamed_memory = (burst_transaction + base["axi_r_empty"] +
                           base["axi_r_transfer"])
        pipeline_overhead = 2 * burst_count + 8
        combined_cycles = max(base["mac"], streamed_memory) + pipeline_overhead
        add("B_C_D_E_F_combined", combined_cycles,
            ("Analytical v0.2 target: 16-vector bursts, K/scale FIFOs, no beat-handoff "
             "or per-token result bubbles, memory/MAC overlap; excludes implementation timing risk"))
    return rows


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
    args.output_dir.mkdir(parents=True, exist_ok=True)

    logs: dict[str, str] = {}
    raw_rows: list[dict[str, int]] = []
    for width in (128, 256):
        log, rows = simulate(repo_root, width)
        logs[str(width)] = log
        raw_rows.extend(rows)
    measured = [measured_row(row) for row in raw_rows]
    options = option_rows(measured)
    write_csv(args.output_dir / "kv-v02-cycle.csv", measured)
    write_csv(args.output_dir / "kv-v02-cycle-options.csv", options)
    report = {
        "schema_version": 1,
        "clock_hz": CLOCK_HZ,
        "warning": "Cycle options are analytical estimates unless marked measured.",
        "measured": measured,
        "options": options,
        "simulation_logs": logs,
    }
    (args.output_dir / "kv-v02-cycle.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("KV cycle accounting PASS")
    for row in measured:
        print(row["axi_width"], row["context_len"], row["total_cycles"],
              f"util={row['mac_utilization']:.3f}")


if __name__ == "__main__":
    main()
