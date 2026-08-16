# KV-cache v0.3 execution workspace

This directory contains the local execution of the theory-closed v0.3 handoff
from `kv-cache-v0.3-theory-closure-handoff-20260816.zip` (SHA-256
`35fb5881b7fc5fff05ac87e9c90594c542bb2396b03de1a4140757e07ca4525e`).

The authoritative order is the package root `README.md`,
`theory/00_THEORY_CLOSURE.md`, `handoff/DELTA_FROM_ORIGINAL_V0_3.md`, and
`handoff/V0_3_THEORY_CLOSED_HANDOFF.md`. The theory-closure delta supersedes
the original page64 sample's payload-only CRC.

Evidence directories are intentionally separated:

- `codec/`: static codebook, regenerated pages, CRC fault tests, and format
  notes (`[SOFTWARE-BIT-EXACT]`).
- `results/gate_a/`: expanded real-model prompt/profile runs and summaries
  (`[REAL-MODEL-VALIDATED]`).
- `results/rtl/`: isolated RTL regression logs (`[RTL-SIMULATED]`).
- `results/vivado/`: synthesis and implementation reports; synthesis and
  routed implementation remain distinct evidence classes.
- `reports/`: final results, index, limitations, and theory comparisons.

The model runs measure hidden-state, attention, and tied-logit distortion. They
are not perplexity, task-accuracy, or generation-quality measurements.

No result in this directory authorizes publishing, pushing, or opening a PR.
