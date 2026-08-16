# Focused follow-up handoff

Do not add broad new features. Complete these gates in order.

## 1. End-to-end streaming-model injection

Add optional K/V quantization inside each decoder layer of the existing
low-memory `StreamingBitNet` path.

Test:

- BASE_FP
- Q8_ONLY
- REGULAR4: K4 group128, V4 group16
- PACKED5: K4/V5 group128
- ACCURATE5: K5/V5 group128

Use context 128 first and at least two genuinely different natural prompt
sequences. Do not construct both from the same repeated token cycle.

Report:

- final normalized hidden-state RMSE/cosine
- last-token hidden-state RMSE/cosine
- selected-layer weighted-V RMSE
- selected-layer post-output-projection/block-output RMSE
- last-token tied-embedding logits:
  - target-token logit delta
  - top-1/top-5 preservation
  - chunked full-vocabulary KL/JS if computationally feasible
- elapsed time and peak memory

Keep the embedding table memory-mapped and compute last-token vocabulary
logits in chunks. Do not instantiate the full Transformers model.

## 2. Confirm scale contract

Compare unsigned UQ4.12, UQ5.11, UQ6.10 and UQ8.8 using the exact intended
write-side policy. Explicitly record whether codes are computed from the
high-precision absmax/reciprocal or from the rounded stored scale.

Prefer UQ5.11 provisionally unless natural-prompt data shows overflow.

## 3. RTL v0.2 prototype

Only after the end-to-end software result is recorded:

- raw signed low-bit QK multiplication
- P=16 signed-digit/shift-add lanes
- balanced registered reduction tree
- one scale multiply after each scale group
- K group128 and V group16 in REGULAR4
- real packed V5 path for PACKED5
- synchronous 4096×16 BRAM score buffer
- signed Q8.8 scores
- subtract-max, clip [-12,0], 128-entry UQ1.15 exp LUT
- restoring divider
- 128-bit AXI first-class, 256-bit optional
- no Hadamard, dither, sparse outlier path, per-channel K, or adaptive precision

## 4. Synthesis comparison

For `xc7a100tcsg324-1`, compare REGULAR4, PACKED5 and ACCURATE5 where practical,
including SHIFT_ADD and DSP/AUTO variants.

Report LUT/LUTRAM/FF/DSP/BRAM, WNS/TNS at 81.25 MHz, routed Fmax where
available, cycles/key, initiation interval, AXI stalls and golden-vector
agreement.

Stop after the comparison report. Do not publish or open a PR.
