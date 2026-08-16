#!/usr/bin/env python3
"""Combine v0.2 wrapper Vivado reports with deterministic cycle accounting."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

from parse_vivado_synth import table_used, timing_values


CYCLES = {
    (128, 512): {
        "total": 11826, "issue": 512, "reader_launch": 1024,
        "axi_ar": 978, "axi_r_empty": 1329, "axi_r_transfer": 815,
        "beat_handoff": 1536, "mac": 4096, "result": 1536, "other": 0,
    },
    (128, 4096): {
        "total": 94912, "issue": 4096, "reader_launch": 8192,
        "axi_ar": 8244, "axi_r_empty": 10589, "axi_r_transfer": 6447,
        "beat_handoff": 12288, "mac": 32768, "result": 12288, "other": 0,
    },
    (256, 512): {
        "total": 10323, "issue": 512, "reader_launch": 1024,
        "axi_ar": 1036, "axi_r_empty": 1076, "axi_r_transfer": 531,
        "beat_handoff": 512, "mac": 4096, "result": 1536, "other": 0,
    },
    (256, 4096): {
        "total": 82489, "issue": 4096, "reader_launch": 8192,
        "axi_ar": 8196, "axi_r_empty": 8518, "axi_r_transfer": 4335,
        "beat_handoff": 4096, "mac": 32768, "result": 12288, "other": 0,
    },
}


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input", type=Path,
        default=repo / "analysis" / "kv_validation" / "hardware_estimates" /
        "vivado_wrapper_v0_2_auto")
    args = parser.parse_args()
    resource_rows = []
    for width in (128, 256):
        name = f"hd128_axi{width}"
        utilization = (args.input / f"{name}_utilization.rpt").read_text(
            "utf-8", errors="replace")
        timing = (args.input / f"{name}_timing_summary.rpt").read_text(
            "utf-8", errors="replace")
        row = {
            "evidence": "VIVADO-POST-SYNTH/OOC",
            "config": name,
            "profile": "REGULAR4/PACKED5 K4 QK wrapper",
            "head_dim": 128,
            "axi_data_width": width,
            "multiplier_style": "AUTO",
            "scale_group_size": 128,
            "slice_luts": table_used(utilization, "Slice LUTs*")[0],
            "logic_luts": table_used(utilization, "LUT as Logic")[0],
            "lutram_luts": table_used(utilization, "LUT as Memory")[0],
            "slice_registers": table_used(utilization, "Slice Registers")[0],
            "bram_tiles": table_used(utilization, "Block RAM Tile")[0],
            "dsp48e1": table_used(utilization, "DSPs")[0],
            **timing_values(timing),
        }
        resource_rows.append(row)

    cycle_rows = []
    for (width, length), counts in CYCLES.items():
        if sum(value for key, value in counts.items() if key != "total") != counts["total"]:
            raise AssertionError("cycle categories must sum to total")
        cycles_per_key = counts["total"] / length
        keys_per_second = 81.25e6 / cycles_per_key
        cycle_rows.append({
            "evidence": "IVERILOG-DETERMINISTIC-REGRESSION",
            "head_dim": 128,
            "axi_data_width": width,
            "context_length": length,
            **{f"{name}_cycles": value for name, value in counts.items()},
            "cycles_per_key": cycles_per_key,
            "keys_per_second_at_81p25mhz": keys_per_second,
            "effective_k_bandwidth_bytes_per_second": keys_per_second * 64,
            "p16_mac_utilization": (128 / 16) / cycles_per_key,
        })
    write_csv(args.input / "resource_timing_summary.csv", resource_rows)
    write_csv(args.input / "cycle_accounting.csv", cycle_rows)
    result = {
        "evidence": ["VIVADO-POST-SYNTH/OOC", "IVERILOG-DETERMINISTIC-REGRESSION"],
        "status": "PASS" if all(row["target_timing_met"] for row in resource_rows)
        else "PASS_WITH_TIMING_FAILURE",
        "tool": "Vivado 2026.1 build 6511674; Icarus Verilog",
        "part": "xc7a100tcsg324-1",
        "resources": resource_rows,
        "cycles": cycle_rows,
        "limitations": [
            "Post-synthesis OOC timing is not routed implementation timing.",
            "The wrapper still stores 4096x32 asynchronous logits in LUTRAM; Q8.8 synchronous score BRAM is not implemented.",
            "Scale plane reader/FIFO, multi-vector bursts, softmax and AV are not in this wrapper.",
            "PACKED5 has the same K4 QK wrapper; its V5 unpack/AV hardware cost is not included.",
            "ACCURATE5 was compared at QK-core level because the current AXI reader requires power-of-two vector bytes and cannot stream packed K5.",
        ],
    }
    (args.input / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", "utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
