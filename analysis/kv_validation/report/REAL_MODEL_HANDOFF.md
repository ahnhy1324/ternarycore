# BitNet real-model KV validation handoff

Date: 2026-08-16  
Checkpoint revision: `04c3b9ad9361b824064a1f25ea60a8be9599b127`  
Checkpoint model SHA-256:
`8143ae115ed6babe5e5ada8fb8c5b769d8f417802b2db042ad98b4f7ed73975b`

## Decision summary

- `[REAL-MODEL-VALIDATED]` Full 30-layer inference completed at contexts 128
  and 512 for the fixed recorded token sequence. Layers 0/7/15/22/29 include
  Q and K before/after RoPE, V, causal logits, probabilities, weighted V, and
  attention block output.
- `[REAL-MODEL-VALIDATED]` The low-memory decoder-layer implementation was
  compared against the pinned Transformers `BitNetDecoderLayer` using real
  layer-0 weights and a 7-token input. The BF16 output was bitwise equal;
  maximum error and relative RMSE were both zero.
- `[REAL-MODEL-VALIDATED]` INT8 Q alone contributes 0.316% mean and 0.453%
  worst attention-output relative RMSE over ten layer/context observations.
- `[REAL-MODEL-VALIDATED]` One INT4 scale per KV vector (`group128`) is not a
  safe default on these tensors: joint K4/V4 mean output RMSE is 16.18% and
  the worst layer/context is 35.73%.
- `[REAL-MODEL-VALIDATED]` Scale granularity dominates Q8.8 representation
  error. INT4 Q8.8 scale-only tensor RMSE is about 0.15% mean and below 0.32%
  worst, with no saturation. K4/V4 output RMSE falls to 11.37%, 9.07%, and
  7.13% for group32, group16, and group8 respectively.
- `[REAL-MODEL-VALIDATED]` V is more sensitive than K to scale granularity.
  At equal metadata, spending scales on V produces consistently lower joint
  output error than spending them on K.
- `[REAL-MODEL-VALIDATED]` Per-vector K4/V5 Q8.8 is a numerical Pareto point:
  4.625 effective bits/value, 148 bytes/token/KV-head, 8.68% mean, and 12.10%
  worst output RMSE. K5/V5 is 5.125 bits/value, 164 bytes, 6.28% mean, and
  9.62% worst. Five-bit packing/dequantization cost is not yet synthesized.
- These measurements are attention-tensor distortion, not task accuracy,
  perplexity, or an acceptable-production-error determination.

## Execution method and trust boundary

The standard Hugging Face loader expands all packed ternary projections to
BF16 and exceeded the 4.16 GB host memory. The replacement execution path:

1. memory-maps `model.safetensors`;
2. gathers only referenced embedding rows;
3. expands one packed ternary projection at a time;
4. applies the checkpoint's per-token INT8 `AutoBitLinear` activation
   quantizer and BF16 operation ordering;
5. discards each expanded projection before opening the next one.

This path does not import Transformers during full execution. It is a
source-matched software reference and not an optimized runtime or RTL
bit-exact model. The separate component cross-check uses the official pinned
Transformers layer, `ActQuant`, and `unpack_weights` implementations.

| Check | Result |
|---|---:|
| official/custom layer | layer 0, 7 tokens |
| output shape/dtype | `1x7x2560`, BF16 |
| bitwise equal | yes |
| maximum absolute error | 0 |
| relative RMSE | 0 |

## Real execution runs

| Context | Layers executed | Captures | Elapsed | Peak observed working set | Status |
|---:|---:|---|---:|---:|---|
| 128 | 30 | 0/7/15/22/29 | 401.77 s | 517,812,224 B | PASS |
| 512 | 30 | 0/7/15/22/29 | 1,401.18 s | 432,644,096 B | PASS |
| 1024 | — | — | — | — | NOT TESTED |
| 2048 | — | — | — | — | NOT TESTED |
| 4096 | — | — | — | — | NOT TESTED |

The three longer contexts were not attempted in this CPU-time pass. They are
not failures.

## Joint K/V result summary

All quantized rows use symmetric per-token/head INT8 Q. K/V are symmetric
narrow-range, round-to-nearest-even, with Q8.8 scales. Means cover contexts
128 and 512 and layers 0/7/15/22/29 (ten observations). Worst is the worst of
those observations.

| K/V format | Scale groups | Effective bits/value | Bytes/token/KV-head | Mean output RMSE | Worst output RMSE | Mean cosine | FP16 compression |
|---|---:|---:|---:|---:|---:|---:|---:|
| K3/V3 | 128/128 | 3.125 | 100 | 28.47% | 44.16% | 0.95637 | 5.120x |
| K3/V5 | 128/128 | 4.125 | 132 | 13.96% | 18.39% | 0.99000 | 3.879x |
| K4/V4 | 128/128 | 4.125 | 132 | 16.18% | 35.73% | 0.98377 | 3.879x |
| K4/V4 | 32/32 | 4.500 | 144 | 11.37% | 18.55% | 0.99309 | 3.556x |
| K4/V5 | 128/128 | 4.625 | 148 | 8.68% | 12.10% | 0.99629 | 3.459x |
| K4/V4 | 16/16 | 5.000 | 160 | 9.07% | 13.92% | 0.99561 | 3.200x |
| K5/V5 | 128/128 | 5.125 | 164 | 6.28% | 9.62% | 0.99790 | 3.122x |
| K4/V4 | 8/8 | 6.000 | 192 | 7.13% | 10.35% | 0.99731 | 2.667x |

The per-vector K4/V4 failure is driven mainly by V outliers. K3/V5 beats
K4/V4 at the same 4.125 effective bits/value on both mean and worst error.
K4/V5 beats group16 K4/V4 while using fewer bytes. These are numerical Pareto
facts for the tested tensors; the irregular five-bit datapath may reverse the
hardware Pareto order.

Mean absolute quantization bias, normalized to reference-output RMS, ranges
from 0.058% (K4/V4 group8) to 0.344% (K3/V3 group128); the worst observed
configuration/layer bias is 0.733% for K4/V4 group128. Bias is recorded in the
raw CSV and is not the main error source.

Mean normalized QK-logit RMSE is 15.19% for K3 group128, 6.55% for K4
group128, 5.38/4.61/3.92% for K4 group32/16/8, and 3.10% for K5 group128.
Per-layer/context probability RMSE, top-token preservation, row p95/p99
output error, cosine, and bias remain in the machine-readable all-context CSV.

## INT4 mixed scale granularity

Q8.8 metadata is two bytes per scale. At `HEAD_DIM=128`, group128/32/16/8 use
1/4/8/16 scales per vector.

| K group | V group | Effective bits/value | Mean output RMSE | Worst output RMSE | Interpretation |
|---:|---:|---:|---:|---:|---|
| 128 | 128 | 4.125 | 16.18% | 35.73% | smallest metadata, rejected as default |
| 128 | 32 | 4.3125 | 12% class | 19% class | V scales are higher value |
| 32 | 128 | 4.3125 | 15% class | 36% class | dominated by spending scales on V |
| 32 | 32 | 4.500 | 11.37% | 18.55% | regular INT4 Pareto point |
| 128 | 16 | 4.5625 | 10% class | 15% class | asymmetric metadata candidate |
| 16 | 16 | 5.000 | 9.07% | 13.92% | aligns one scale with each `P=16` slice |
| 8 | 8 | 6.000 | 7.13% | 10.35% | too much metadata for the gain |

Use the machine-readable aggregate table for exact mixed rows. The table above
intentionally rounds non-baseline asymmetric rows so it is not mistaken for a
frozen architecture contract.

## Real-tensor predictor validation

The correction factor was fitted on context 128 and evaluated on context 512.
The longer sequence extends the same repeated prompt pattern, so this is a
context holdout but not a prompt-independent holdout.

| Predictor | Bits | Evaluation power correlation | Mean relative power residual | p95 residual | Mean vector cosine |
|---|---:|---:|---:|---:|---:|
| K first-order | 3 | 0.797 | 58.2% | 86.3% | 0.917 |
| K first-order | 4 | 0.886 | 23.7% | 50.1% | 0.960 |
| K first-order | 5 | 0.991 | 14.3% | 29.9% | 0.969 |
| V `sigma^2/N_eff` | 3 | 0.457 | 386% | 1817% | — |
| V `sigma^2/N_eff` | 4 | 0.304 | 342% | 1343% | — |
| V `sigma^2/N_eff` | 5 | 0.454 | 457% | 1718% | — |

`[REAL-MODEL-VALIDATED]` The K linearization remains useful as a ranking and
direction predictor at INT4/INT5, although it is not an error guarantee. The V
homoscedastic independence model transfers poorly to these real activations;
per-token scaling errors are structured and outliers violate its assumptions.
Do not use `sigma^2/N_eff` to size V precision or guarantee an error bound.

## Architecture handoff

No RTL was changed from the v0.1 QK engine in this validation.

For v0.2:

1. Keep the separate payload and scale planes. INT4 data remains naturally
   64-byte aligned at `HEAD_DIM=128`.
2. Replace the one-scale-per-run ABI. The reader/scale FIFO must support a
   parameterized number of scales per vector.
3. Preserve `P=16`, 128-bit AXI as first class, and 256-bit as an option.
4. For a regular INT4-only build, synthesize group32 and group16. Group32 is
   the storage-first Pareto point; group16 maps one scale to each MAC slice.
5. Also synthesize the cost of K4/V5 and K5/V5 before choosing a precision.
   Do not select them from software error alone.
6. Because V dominates the observed error and the Amdahl budget, prioritize a
   parameterized V streamer/AV accumulator after the QK FIFO/burst revision.
7. Keep Hadamard and deterministic dither disabled in the baseline.

## Vivado 2026.1 implementation evidence

`[VIVADO-POST-SYNTH]` IP packaging integrity and the HEAD_DIM64/AXI128 XSIM
boundary/error regression pass with the restored BASIC license. Timing-driven
OOC synthesis on `xc7a100tcsg324-1` gives:

| HEAD_DIM/AXI | LUT | FF | DSP | BRAM | WNS at 81.25 MHz | estimated post-synth Fmax |
|---|---:|---:|---:|---:|---:|---:|
| 64/128 | 7,269 | 1,303 | 17 | 0 | -26.962 ns | 25.46 MHz |
| 64/256 | 7,080 | 1,552 | 17 | 0 | -26.760 ns | 25.60 MHz |
| 128/128 | 9,017 | 1,822 | 17 | 0 | -26.944 ns | 25.48 MHz |
| 128/256 | 8,845 | 2,069 | 17 | 0 | -26.760 ns | 25.60 MHz |

All configurations synthesize, but none closes the target clock. The
unregistered 16-lane scaled reduction is about 39 ns. The wrapper also maps
its 4K×32 logit memory to 2,816 LUTRAM LUTs instead of BRAM. Therefore the next
RTL change should be raw INT8×INT4 group partial sums, one Q8.8 scale multiply
per group, a registered balanced reduction, and synchronous BRAM/streamed
logits. Burst K/scale FIFOs follow that timing/resource correction; wider AXI
or more lanes do not.

See `report/VIVADO_RESOURCE_REPORT.md` and the raw/parsed synthesis artifacts
for the hierarchy and caveats. The equivalent Fmax is pre-route OOC evidence,
not a timing-closed FPGA measurement.

## Reproduction

From the repository root:

```powershell
python analysis/kv_validation/scripts/validate_bitnet_streaming_reference.py

python analysis/kv_validation/scripts/run_real_model_streaming.py `
  --output analysis/kv_validation/real_model/runs/<new-c128-run> `
  --context-length 128 --layers 0,7,15,22,29 --layer-count 30

python analysis/kv_validation/scripts/analyze_real_model_captures.py `
  --input analysis/kv_validation/real_model/runs/<new-c128-run> `
  --output analysis/kv_validation/real_model/runs/<new-c128-run>/analysis
```

Use a new output path for every run; the scripts refuse to overwrite an
existing run directory. Exact token IDs are in
`real_model/prompts_and_token_ids.json`.

## Artifact map

- `real_model/streaming_reference_validation.json`: official component
  cross-check.
- `real_model/runs/20260816-streaming-full-c128/`: context-128 run, tensors,
  and raw analysis.
- `real_model/runs/20260816-streaming-full-c512/`: context-512 run, tensors,
  and raw analysis.
- `real_model/aggregate_context128_512/`: pooled raw rows, summaries, and
  Pareto flags.
- `real_model/predictor_validation_context128_512/`: compressed sample powers,
  fitted corrections, correlations, and residual summaries.
- `scripts/bitnet_streaming_reference.py`: low-memory execution arithmetic.
- `scripts/run_real_model_streaming.py`: deterministic capture driver.
- `scripts/analyze_real_model_captures.py`: quantization and attention metrics.
- `scripts/summarize_real_model_runs.py`: multi-context aggregation.

## Remaining validation gates

- Contexts 1024/2048/4096.
- More natural, non-repeated prompt sets and broader heads/layers if required.
- Task accuracy/perplexity or downstream generation evaluation.
- Synthesis and timing of group-scale readers and 5-bit alternatives.
- Routed timing and resource measurements after the group-partial/pipeline and
  BRAM-logit refactor.
- Physical DDR/MIG burst efficiency and final RTL arithmetic equivalence.
