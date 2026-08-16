# KV validation independent audit addendum

Date: 2026-08-16

## Verdict

The supplied package is internally coherent. All 141 files listed in
`result_manifest.json` matched their recorded SHA-256 and byte size during an
independent package audit. The headline synthetic and real-tensor aggregates
also recomputed from the raw CSVs.

The real-model result materially changes the likely FPGA baseline:

- Per-vector K4/V4 is not a safe default on the captured tensors.
- V precision/granularity matters more than K precision/granularity.
- The current v0.1 RTL is not timing-viable at 81.25 MHz because it dequantizes
  every lane and then cascades 17 DSP48E1 blocks through an unregistered sum.
- The raw-code/group-scale refactor is the correct next arithmetic architecture.

This remains attention-tensor evidence, not task accuracy or perplexity.

## Additional independent findings

### Decode-position audit

The ranking is not an artifact of averaging only short causal rows. Averaged
over layers 0/7/15/22/29 and contexts 128/512, the last-token results are:

| Configuration | Last-token mean RMSE | Last-token worst RMSE |
|---|---:|---:|
| K5/V5 group128 | 6.30% | 9.99% |
| K4/V5 group128 | 9.35% | 17.42% |
| K4/V4, K group128 / V group16 | 11.42% | 18.82% |
| K4/V4 group16/group16 | 10.42% | 20.79% |
| K4/V4 group128/group128 | 17.04% | 39.36% |

### Pre-RoPE vs post-RoPE K quantization

For K4 group128, K-only weighted-V output RMSE was 6.323% when quantizing
post-RoPE K and 6.337% when quantizing pre-RoPE K and applying RoPE afterward.
The difference was similarly negligible across group sizes.

There is no measured accuracy benefit large enough to justify applying RoPE
during every cache read. The simple FPGA baseline should cache post-RoPE K.

### K per-channel screening

Oracle/blockwise K per-channel quantization improves K-only error, but joint
K4/V4 error remains V-dominated. At equal 4.125 effective bits/value,
block-128 pre-RoPE per-channel K reduced joint mean RMSE only from 16.18% to
about 15.39%. Allocating comparable metadata to V was much more valuable.

Per-channel K should remain optional related-work screening, not baseline RTL.

### Scale binary point

Observed scale maxima across all real captures:

- K4: 1.661
- V4: 6.429
- V3: 15.000

Q8.8 does not saturate, but its integer range is unnecessary. A 16-bit
unsigned UQ5.11 scale is the safer provisional contract: eight times finer
than UQ8.8 and still has ample range. UQ4.12 fits the observed tensors but
leaves less outlier guard. Scale-format error remains much smaller than
K/V code quantization.

### Softmax on real logits

A compact behavioral contract worked well on all ten real captures:

- signed Q8.8 score/delta
- subtract maximum
- clamp to [-12, 0]
- 128-entry nearest exp LUT
- UQ1.15 exp codes
- exact integer normalization to Q0.16

Against exact softmax on the same logits, mean weighted-V output RMSE was
0.499% and worst was 0.765%. Inserted after the tested quantized K/V paths,
incremental softmax error averaged about 0.472% and stayed below 0.749%.

For the first small-FPGA profile, a bit-serial restoring divider is preferable
to LUT+Newton-Raphson: one division per head is negligible beside a
128–4096-key sweep and avoids extra multiplier/DSP pressure.

## Recommended synthesis candidates

Do not freeze a production winner before end-to-end model-quality testing.

1. REGULAR4: K4 group128, V4 group16, 146 bytes/token/KV-head.
   Regular nibble packing; V groups align with P=16.
2. PACKED5: K4/V5 group128, 148 bytes/token/KV-head.
   Numerically better, but requires a real packed 5-bit streamer/unpacker.
3. ACCURATE5: K5/V5 group128, 164 bytes/token/KV-head.

## Recommended v0.2 datapath

- QK: raw INT8 × signed low-bit code, signed-digit/shift-add lanes, registered
  P=16 reduction, then one scale multiplication per scale group.
- Logits: signed Q8.8, 4096×16 synchronous BRAM/overwrite buffer.
- Softmax: subtract max, clip -12, 128-entry UQ1.15 exp LUT, wide sum,
  restoring divider.
- AV: compute `exp_code × V_scale` once per V group, then signed-digit
  multiply the shared scalar by the 16 V codes and accumulate 16 lanes.
- Replace the current asynchronous 4096×32 LUTRAM logit array with BRAM.

This schedule should remove the current 17-DSP serial critical path, but the
actual LUT/DSP/Fmax result must be synthesized.

## Remaining decisive gate

Current RMSE is measured on weighted V before attention sub-normalization,
output projection, residual addition, and later layers. The next run must
inject candidate K/V quantization into the low-memory streaming model and
measure final hidden-state and last-token logit changes. Perplexity/task
quality remains unmeasured.
