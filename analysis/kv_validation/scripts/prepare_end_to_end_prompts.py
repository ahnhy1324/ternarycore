#!/usr/bin/env python3
"""Create two distinct natural-prompt token sequences for injection tests."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from tokenizers import Tokenizer


PROMPTS = {
    "engineering": """
An engineer is reviewing a small FPGA accelerator intended to serve attention
requests from a compact language model. The board has limited external memory
bandwidth, so the design stores keys and values in low precision and keeps the
metadata in separate scale buffers. Before changing the hardware, the engineer
checks how scale granularity affects logits, probability distributions, and the
weighted value output. She also records every assumption about alignment,
burst length, overflow, and back pressure. During verification, long requests
are followed immediately by short requests, memory responses are delayed at
random, and malformed transfers must produce explicit errors. The objective is
not to claim model accuracy from synthetic vectors. It is to find the simplest
architecture whose numerical behavior remains stable on real activations and
whose timing report is credible on the target Artix device. Once the evidence
is collected, the team will decide whether the next block should accelerate
softmax, stream the value cache, or improve the existing query-key scheduler.
""",
    "observatory": """
Just before dawn, a student walked up the narrow stairs of an old observatory
with a notebook, a thermos, and a list of stars to measure. Clouds had covered
the valley all week, but the air was finally clear and the dome opened without
a sound. Her mentor asked her to begin with a familiar calibration star, then
move slowly toward the faint object near the eastern horizon. Between exposures
they compared timestamps, checked the tracking motor, and wrote down small
changes in temperature. A fox crossed the service road below, paused in the
headlights, and disappeared among the pines. By sunrise the final image was not
spectacular, yet it contained the clean signal they needed. The student saved
the raw frames, copied the observing log, and left a careful note for the next
shift explaining which measurements were trustworthy and which should be
repeated when the weather allowed another quiet night.
""",
}


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--tokenizer", type=Path,
                        default=repo.parent / "bitnet-b1.58-2B-4T" / "tokenizer.json")
    parser.add_argument("--context-length", type=int, default=128)
    parser.add_argument(
        "--output", type=Path,
        default=repo / "analysis" / "kv_validation" / "real_model" /
        "end_to_end_prompts.json")
    args = parser.parse_args()
    tokenizer = Tokenizer.from_file(str(args.tokenizer))
    records = []
    for prompt_id, text in PROMPTS.items():
        ids = tokenizer.encode(" ".join(text.split())).ids
        if len(ids) <= args.context_length:
            raise AssertionError(f"prompt {prompt_id} has only {len(ids)} tokens")
        context = ids[:args.context_length]
        records.append({
            "prompt_id": prompt_id,
            "text": " ".join(text.split()),
            "full_token_count": len(ids),
            "context_token_ids": context,
            "context_token_ids_sha256": hashlib.sha256(
                json.dumps(context, separators=(",", ":")).encode()).hexdigest(),
            "target_token_id": ids[args.context_length],
            "unique_context_tokens": len(set(context)),
        })
    assert records[0]["context_token_ids"] != records[1]["context_token_ids"]
    result = {
        "evidence": "REAL-MODEL-INPUT/tokenizer",
        "context_length": args.context_length,
        "construction": "independent natural prose; truncate once; no repeated token cycle",
        "prompts": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", "utf-8")
    print(json.dumps({r["prompt_id"]: {
        "full_tokens": r["full_token_count"],
        "unique_context_tokens": r["unique_context_tokens"],
        "target_token_id": r["target_token_id"],
    } for r in records}, indent=2))


if __name__ == "__main__":
    main()
