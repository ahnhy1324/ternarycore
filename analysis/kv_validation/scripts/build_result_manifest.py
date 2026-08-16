#!/usr/bin/env python3
"""Hash every final validation artifact except the manifest itself."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation")
    args = parser.parse_args()
    root = args.output.resolve()
    manifest_path = root / "result_manifest.json"
    files = []
    for path in sorted(root.rglob("*")):
        if (not path.is_file() or path == manifest_path or
                "__pycache__" in path.parts or path.suffix in {
                    ".pyc", ".dcp", ".log"} or
                "vivado_synth_2026_1" in path.parts):
            continue
        files.append({
            "path": path.relative_to(root).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    manifest_path.write_text(json.dumps({
        "evidence": "REPRODUCIBILITY/FINAL-ARTIFACT-HASHES",
        "files": files,
        "file_count": len(files),
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"hashed {len(files)} final artifacts")


if __name__ == "__main__":
    main()
