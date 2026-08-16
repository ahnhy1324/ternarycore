#!/usr/bin/env python3
"""Copy prior v0.2 evidence into the validation index with explicit labels."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
from typing import Any, Callable


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


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


def copy_table(source: Path, target: Path,
               classify: Callable[[dict[str, str]], str]) -> int:
    rows = read_csv(source)
    decorated = [{"evidence": classify(row),
                  "source_path": source.as_posix(), **row} for row in rows]
    write_csv(target, decorated)
    return len(rows)


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation")
    args = parser.parse_args()
    validation_root = args.output.resolve()
    hardware = validation_root / "hardware_estimates"
    pareto = validation_root / "pareto"
    hardware.mkdir(parents=True, exist_ok=True)
    pareto.mkdir(parents=True, exist_ok=True)
    runs = repo / "docs" / "runs"
    mapping = (
        ("kv-v02-cycle.csv", hardware / "qk_cycle_accounting.csv",
         lambda row: "RTL-SIMULATED"),
        ("kv-v02-cycle-options.csv", hardware / "qk_cycle_options.csv",
         lambda row: ("RTL-SIMULATED" if row["option"] in
                      ("current_128_measured", "A_256bit_bus")
                      else "THEORETICAL")),
        ("kv-v02-amdahl.csv", hardware / "amdahl_components.csv",
         lambda row: "THEORETICAL/MIXED-SOURCE-INPUTS"),
        ("kv-v02-scenarios.csv", hardware / "amdahl_scenarios.csv",
         lambda row: "THEORETICAL/MIXED-SOURCE-INPUTS"),
        ("kv-v02-hadamard-pareto.csv", pareto / "hadamard_pareto_head64.csv",
         lambda row: "SOFTWARE-FIXED-POINT"),
        ("kv-v02-int4-pareto.csv", pareto / "scale_granularity_pareto_head64.csv",
         lambda row: ("SOFTWARE-FIXED-POINT" if row["scale_format"] != "FP32"
                      else "SOFTWARE-SYNTHETIC")),
    )
    manifest: list[dict[str, Any]] = []
    for name, target, classifier in mapping:
        source = runs / name
        count = copy_table(source, target, classifier)
        manifest.append({
            "source": str(source.relative_to(repo)).replace("\\", "/"),
            "target": str(target.relative_to(repo)).replace("\\", "/"),
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "rows": count,
            "note": "values copied without numeric transformation; labels added",
        })
    (validation_root / "prior_evidence_manifest.json").write_text(
        json.dumps({
            "evidence": "PROVENANCE",
            "warning": ("Imported prior v0.2 evidence retains its original HEAD_DIM "
                        "and measurement class; it is not real BitNet activation data."),
            "files": manifest,
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"indexed {len(manifest)} prior evidence tables")


if __name__ == "__main__":
    main()
