#!/usr/bin/env python3
"""Extract labeled cycle rows from the Windows Icarus regression log."""

from __future__ import annotations

import argparse
import csv
import hashlib
import re
from pathlib import Path


FREQUENCY_HZ = 81_250_000.0
P = 16
LINE = re.compile(
    r"CYCLE_ACCOUNT width=(?P<axi_width>\d+) length=(?P<context_len>\d+) "
    r"total=(?P<total_cycles>\d+) issue=(?P<issue>\d+) "
    r"reader_launch=(?P<reader_launch>\d+) axi_ar=(?P<axi_ar>\d+) "
    r"axi_r_empty=(?P<axi_r_empty>\d+) "
    r"axi_r_transfer=(?P<axi_r_transfer>\d+) "
    r"beat_handoff=(?P<beat_handoff>\d+) mac=(?P<mac>\d+) "
    r"result=(?P<result>\d+) other=(?P<other>\d+)")


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation")
    args = parser.parse_args()
    hardware = args.output / "hardware_estimates"
    log = hardware / "windows_regression_vivado_2026_1.txt"
    pending: list[dict[str, str]] = []
    rows: list[dict[str, object]] = []
    for text in log.read_text(encoding="utf-8").splitlines():
        match = LINE.fullmatch(text.strip())
        if match:
            pending.append(match.groupdict())
            continue
        if text.startswith("SIM_PASS sim_kv_cache_engine"):
            head_dim = 128 if "hd128" in text else 64
            for raw in pending:
                numeric = {key: int(value) for key, value in raw.items()}
                context = numeric["context_len"]
                cycles = numeric["total_cycles"]
                keys_per_second = FREQUENCY_HZ * context / cycles
                rows.append({
                    "evidence": "RTL-SIMULATED",
                    "head_dim": head_dim,
                    **numeric,
                    "cycles_per_key": cycles / context,
                    "latency_us_at_81_25mhz": cycles / FREQUENCY_HZ * 1.0e6,
                    "mac_utilization": numeric["mac"] / cycles,
                    "mkeys_per_second_at_81_25mhz": keys_per_second / 1.0e6,
                    "effective_k_payload_mb_s":
                        keys_per_second * head_dim * 4 / 8 / 1.0e6,
                    "measurement_kind":
                        "Icarus RTL simulation with deterministic randomized stalls",
                    "source_log_sha256": hashlib.sha256(log.read_bytes()).hexdigest(),
                })
            pending.clear()
    assert not pending, "unassigned CYCLE_ACCOUNT rows"
    assert len(rows) == 8, len(rows)
    assert {(row["head_dim"], row["axi_width"], row["context_len"])
            for row in rows} == {
        (head_dim, width, context)
        for head_dim in (64, 128) for width in (128, 256)
        for context in (512, 4096)}
    target = hardware / "qk_cycle_accounting_head64_head128.csv"
    with target.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"extracted {len(rows)} cycle-accounting rows")


if __name__ == "__main__":
    main()
