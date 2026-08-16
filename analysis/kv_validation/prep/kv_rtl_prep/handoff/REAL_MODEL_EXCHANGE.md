# Real-Model Result Exchange Gate

When real-model extraction returns, do not begin RTL feature expansion immediately.
First exchange the result package against this checklist.

## Required incoming evidence
- checkpoint/model revision and config
- extraction script revision
- layers and token positions sampled
- context lengths sampled
- Q tensors
- K pre-RoPE where available
- K post-RoPE
- V tensors
- logits/attention/output where available
- tensor shapes/dtypes/head mapping
- reconstruction/provenance report
- failure log for any requested case not completed

## Required analyses before design freeze
- BASE K3/K4/K5 x V3/V4/V5 sweep
- per-case and aggregate output error
- cosine similarity
- p50/p95/worst error
- attention entropy and N_eff
- top-1/top-2 logit margin
- K first-order predictor correlation/residual
- V predictor correlation/residual
- sink/high-entropy/outlier stratification
- scale distribution and saturation study
- candidate fixed-point scale-format sweep
- K4/V4 vs K5/V4 vs K4/V5 vs K5/V5 Pareto comparison
- estimated storage/DDR traffic for every candidate

## Freeze decision
Choose the simplest profile satisfying the real-model quality budget.
Do not add PER_CHANNEL_K, rotation, sparse outlier handling, sink protection,
or mixed precision unless BASE fails and the added feature demonstrates a
measurable quality-per-hardware-cost benefit.

## After freeze
Generate one canonical real-model golden-vector subset and regenerate:
- packed payload binaries
- scale binaries
- expected QK
- expected softmax
- expected AV/output
- RTL tolerance contract

Only then hand off to RTL implementation/synthesis.
