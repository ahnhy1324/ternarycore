#!/usr/bin/env python3
"""Independent software verification of the Tier-1 bring-up workload."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

import numpy as np


DEPTH = 768
COLS = 768
GROUPS = COLS // 4


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation" / "synthetic")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    source = repo / "firmware" / "tier1_bare.c"
    text = source.read_text(encoding="utf-8")
    required_patterns = (
        r"% 3u\) - 1",
        r"\(k % 7\) - 3",
        r"#define DEPTH\s+768",
        r"#define COLS_TOTAL\s+768",
    )
    for pattern in required_patterns:
        if not re.search(pattern, text):
            raise AssertionError(f"Tier-1 source pattern missing: {pattern}")

    activations = (np.arange(DEPTH, dtype=np.int64) % 7) - 3
    outputs = np.zeros(COLS, dtype=np.int64)
    for column in range(COLS):
        group = column // 4
        lane = column & 3
        byte_address = np.arange(DEPTH, dtype=np.int64) * GROUPS + group
        flat_weight_index = byte_address * 4 + lane
        weights = (flat_weight_index % 3) - 1
        outputs[column] = np.dot(activations, weights)

    checksum = int(np.sum(outputs * np.arange(1, COLS + 1, dtype=np.int64))) & 0xFFFFFFFF
    if outputs[:4].tolist() != [5, 0, -5, 5]:
        raise AssertionError(outputs[:4])
    if checksum != 0xFFFFF600:
        raise AssertionError(hex(checksum))
    record = {
        "evidence": "SOFTWARE-SYNTHETIC/BRING-UP",
        "representative_llm_tensor": False,
        "source": str(source.relative_to(repo)),
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "depth": DEPTH,
        "columns": COLS,
        "weight_pattern": "deterministic repetition -1,0,+1",
        "activation_pattern": "deterministic repetition -3..+3",
        "independent_output_first4": outputs[:4].tolist(),
        "independent_output_min": int(outputs.min()),
        "independent_output_max": int(outputs.max()),
        "independent_checksum_hex": f"0x{checksum:08x}",
        "documented_checksum_match": True,
    }
    (args.output / "tier1_reference.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    np.savez_compressed(args.output / "tier1_reference_outputs.npz",
                        activations=activations.astype(np.int8), outputs=outputs)
    print("Tier-1 SOFTWARE-SYNTHETIC reference PASS", hex(checksum))


if __name__ == "__main__":
    main()
