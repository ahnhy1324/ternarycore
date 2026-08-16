#!/usr/bin/env python3
"""Compare v0.3 GQA page/decode schedules against measured page bytes."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


CLOCK_HZ = 81_250_000
MEASURED_AXI128_MBPS = 224.77052345546727
ORGANIZATIONS = (
    ("1x4", 1, 4, "high"),
    ("2x2", 2, 2, "medium"),
    ("4x1", 4, 1, "low"),
)
BUFFER_RAMB36 = {
    (64, "1x4"): 3, (64, "2x2"): 5, (64, "4x1"): 9,
    (128, "1x4"): 5, (128, "2x2"): 9, (128, "4x1"): 18,
}


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--page-summary", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "results" / "gate_a" / "page_accounting_summary.csv")
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "results" / "schedule")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with args.page_summary.open(newline="", encoding="utf-8") as handle:
        page_rows = list(csv.DictReader(handle))
    pages = {int(row["profile"].split("PAGE", 1)[1].split("_", 1)[0]): row
             for row in page_rows}
    if set(pages) != {64, 128}:
        raise AssertionError("page64/page128 accounting rows are required")

    rows = []
    for page_tokens in (64, 128):
        measured_bytes = float(
            pages[page_tokens]["mean_combined_full_bytes_per_token"])
        k_bytes = float(pages[page_tokens]["mean_k_full_bytes_per_token"])
        v_bytes = float(pages[page_tokens]["mean_v_full_bytes_per_token"])
        arithmetic_page_cycles = page_tokens * 32
        arithmetic_page_us = arithmetic_page_cycles / CLOCK_HZ * 1.0e6
        k_required_mbps = k_bytes * CLOCK_HZ / 32 / 1.0e6
        v_required_mbps = v_bytes * CLOCK_HZ / 32 / 1.0e6
        k_prefetch_us = k_bytes * page_tokens / MEASURED_AXI128_MBPS
        v_prefetch_us = v_bytes * page_tokens / MEASURED_AXI128_MBPS
        for name, engines, symbols_per_engine, risk in ORGANIZATIONS:
            per_engine_cycles = page_tokens * 128 / symbols_per_engine
            steady_period = per_engine_cycles / engines
            rows.append({
                "evidence": "THEORETICAL/v0.3-GQA-schedule-with-measured-page-rate",
                "page_tokens": page_tokens,
                "organization": name,
                "decoder_engines": engines,
                "symbols_per_cycle_per_engine": symbols_per_engine,
                "aggregate_symbols_per_cycle": engines * symbols_per_engine,
                "cold_first_page_decode_cycles": int(per_engine_cycles),
                "steady_page_period_cycles": int(steady_period),
                "arithmetic_page_period_cycles": arithmetic_page_cycles,
                "keeps_up_single_P16_GQA4": steady_period <= arithmetic_page_cycles,
                "measured_combined_full_bytes_per_token": measured_bytes,
                "measured_k_full_bytes_per_token": k_bytes,
                "measured_v_full_bytes_per_token": v_bytes,
                "required_k_bandwidth_MBps": k_required_mbps,
                "required_v_bandwidth_MBps": v_required_mbps,
                "k_prefetch_us_at_prior_measured_AXI128": k_prefetch_us,
                "v_prefetch_us_at_prior_measured_AXI128": v_prefetch_us,
                "arithmetic_page_us": arithmetic_page_us,
                "k_prefetch_overlap_margin_us": arithmetic_page_us - k_prefetch_us,
                "v_prefetch_overlap_margin_us": arithmetic_page_us - v_prefetch_us,
                "compressed_pingpong_RAMB36_estimate": BUFFER_RAMB36[
                    (page_tokens, name)],
                "four_score_rows_RAMB36_estimate": 8,
                "combined_buffer_score_RAMB36_estimate": (
                    BUFFER_RAMB36[(page_tokens, name)] + 8),
                "decoder_timing_risk": risk,
                "compression_penalty": "none; independent page tasks",
            })
    write_csv(args.output / "gqa_schedule_model.csv", rows)
    recommended = next(row for row in rows
                       if row["page_tokens"] == 128 and
                       row["organization"] == "2x2")
    result = {
        "evidence": "THEORETICAL/v0.3-GQA-schedule-with-measured-page-rate",
        "status": "PASS",
        "clock_hz": CLOCK_HZ,
        "prior_measured_AXI128_MBps": MEASURED_AXI128_MBPS,
        "gqa_ratio": 4,
        "P": 16,
        "cycles_per_vector_across_four_q_heads": 32,
        "required_decoder_symbols_per_cycle": 4,
        "provisional_recommended": recommended,
        "limitations": (
            "Page bytes are real-model software measurements. Bandwidth is a "
            "calculation using prior v0.2 AXI throughput; starvation, FIFO "
            "levels, and overlap remain unmeasured until RTL simulation."),
    }
    (args.output / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
