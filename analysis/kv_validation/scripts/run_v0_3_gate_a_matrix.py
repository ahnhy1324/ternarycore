#!/usr/bin/env python3
"""Execute the complete v0.3 Gate A matrix, resuming completed cases."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


PROFILES = (
    "BASE_FP",
    "PACKED5_RAW_UQ5_11",
    "PACKED5_PAGE128_UQ4_8",
)


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--prompt-record", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "prompts_and_token_ids.json")
    parser.add_argument(
        "--output-root", type=Path,
        default=repo / "analysis" / "kv_validation" / "v0_3" /
        "results" / "gate_a")
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()

    prompt_data = json.loads(args.prompt_record.read_text(encoding="utf-8"))
    cases = []
    for record in prompt_data["prompts"]:
        for context_text in sorted(record["contexts"], key=int):
            context = int(context_text)
            for profile in PROFILES:
                if (profile == "BASE_FP" and context == 128 and
                        record["prompt_id"] in ("engineering", "observatory")):
                    # Exact token/target hashes match the already completed v0.2
                    # BASE_FP runs; the case runner records this imported source.
                    continue
                cases.append((record["prompt_id"], context, profile))

    log_dir = args.output_root / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    runner = Path(__file__).with_name("run_v0_3_gate_a.py")
    matrix_start = time.perf_counter()
    completed = 0
    skipped = 0
    for case_index, (prompt, context, profile) in enumerate(cases, start=1):
        destination = (
            args.output_root / f"context_{context:04d}" / prompt / profile)
        run_json = destination / "run.json"
        if run_json.is_file():
            run = json.loads(run_json.read_text(encoding="utf-8"))
            if run.get("status") != "PASS":
                raise RuntimeError(f"existing case is not PASS: {run_json}")
            skipped += 1
            print(json.dumps({
                "matrix_case": case_index,
                "matrix_total": len(cases),
                "action": "skip_completed",
                "prompt": prompt,
                "context": context,
                "profile": profile,
            }), flush=True)
            continue
        if destination.exists():
            raise RuntimeError(
                f"incomplete destination exists; inspect before retry: {destination}")
        command = [
            sys.executable, str(runner),
            "--prompt-record", str(args.prompt_record),
            "--output-root", str(args.output_root),
            "--prompt-id", prompt,
            "--context-length", str(context),
            "--profile", profile,
            "--threads", str(args.threads),
        ]
        log_path = log_dir / f"c{context:04d}_{prompt}_{profile}.log"
        print(json.dumps({
            "matrix_case": case_index,
            "matrix_total": len(cases),
            "action": "start",
            "prompt": prompt,
            "context": context,
            "profile": profile,
            "log": str(log_path),
        }), flush=True)
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(
                command, cwd=repo, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, bufsize=1)
            assert process.stdout is not None
            for line in process.stdout:
                log.write(line)
                log.flush()
                if '"layer"' in line or '"status"' in line:
                    print(line.rstrip(), flush=True)
            return_code = process.wait()
        if return_code:
            raise RuntimeError(
                f"Gate A case failed with exit {return_code}; see {log_path}")
        completed += 1
        print(json.dumps({
            "matrix_case": case_index,
            "matrix_total": len(cases),
            "action": "complete",
            "prompt": prompt,
            "context": context,
            "profile": profile,
            "matrix_elapsed_seconds": time.perf_counter() - matrix_start,
        }), flush=True)

    result = {
        "status": "PASS",
        "matrix_cases": len(cases),
        "completed_this_invocation": completed,
        "skipped_completed": skipped,
        "elapsed_seconds": time.perf_counter() - matrix_start,
    }
    (args.output_root / "matrix_run.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
