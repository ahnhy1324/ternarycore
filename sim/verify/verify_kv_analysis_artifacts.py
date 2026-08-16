#!/usr/bin/env python3
"""Validate committed KV v0.2 analysis artifacts and table coverage."""

from __future__ import annotations

import csv
import json
import math
from pathlib import Path


EXPECTED_CONTEXTS = {128, 256, 512, 1024, 2048, 4096}
EXPECTED_DISTRIBUTIONS = {
    "gaussian",
    "laplace",
    "student_t_df3",
    "sparse_outliers_0p1pct_x25",
    "outliers_1pct_x10",
}


def csv_count(path: Path) -> int:
    with path.open(newline="", encoding="utf-8") as handle:
        return sum(1 for _ in csv.DictReader(handle))


def assert_finite(rows: list[dict]) -> None:
    for row in rows:
        for value in row.values():
            if isinstance(value, float):
                assert math.isfinite(value)


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    runs = repo_root / "docs" / "runs"
    numerical = json.loads((runs / "kv-v02-analysis.json").read_text(
        encoding="utf-8"))
    tables = numerical["tables"]
    assert "not model accuracy" in numerical["warning"]
    expected_counts = {
        "numerical": 180,
        "scale_granularity": 450,
        "int4_pareto": 15,
        "hadamard": 720,
        "hadamard_pareto": 24,
        "storage": 60,
        "layout": 48,
    }
    for name, count in expected_counts.items():
        assert len(tables[name]) == count, (name, len(tables[name]))
        assert_finite(tables[name])
    assert {row["context_len"] for row in tables["numerical"]} == EXPECTED_CONTEXTS
    assert {row["synthetic_distribution"]
            for row in tables["numerical"]} == EXPECTED_DISTRIBUTIONS
    assert any(row["recommended_v02_knee"] for row in tables["int4_pareto"])
    assert not any(row["recommended_for_baseline"]
                   for row in tables["hadamard_pareto"])

    csv_tables = {
        "kv-v02-numerical.csv": "numerical",
        "kv-v02-scale-granularity.csv": "scale_granularity",
        "kv-v02-int4-pareto.csv": "int4_pareto",
        "kv-v02-hadamard.csv": "hadamard",
        "kv-v02-hadamard-pareto.csv": "hadamard_pareto",
        "kv-v02-storage.csv": "storage",
        "kv-v02-layout.csv": "layout",
    }
    for filename, table in csv_tables.items():
        assert csv_count(runs / filename) == len(tables[table])

    cycle = json.loads((runs / "kv-v02-cycle.json").read_text(encoding="utf-8"))
    assert len(cycle["measured"]) == 4
    for row in cycle["measured"]:
        categories = ("issue", "reader_launch", "axi_ar", "axi_r_empty",
                      "axi_r_transfer", "beat_handoff", "mac", "result", "other")
        assert sum(row[key] for key in categories) == row["total_cycles"]
        assert row["mac"] == 4 * row["context_len"]

    system = json.loads((runs / "kv-v02-system.json").read_text(encoding="utf-8"))
    assert len(system["components"]) == 9
    assert {row["scenario"] for row in system["scenarios"]} >= {
        "QK_only", "QK_plus_quantized_V_storage",
        "QK_plus_V_accumulation", "full_attention_path",
    }
    print("KV v0.2 analysis artifacts PASS")


if __name__ == "__main__":
    main()
