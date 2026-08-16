# TernaryCore KV-cache software-validation report

## A. Executive summary

- `[REAL-MODEL-VALIDATED]` The local Microsoft BitNet checkpoint is complete
  and identified as revision
  `04c3b9ad9361b824064a1f25ea60a8be9599b127`, model SHA-256
  `8143ae115ed6babe5e5ada8fb8c5b769d8f417802b2db042ad98b4f7ed73975b`.
  Its authoritative geometry is 30 layers, 20 Q heads, 5 KV heads, and
  `HEAD_DIM=128`.
- `[REAL-MODEL-VALIDATED]` A memory-mapped, layer-streaming reference completed
  all 30 layers at contexts 128 and 512 and captured Q/K before/after RoPE, V,
  causal logits, probabilities, weighted V, and attention output at layers
  0/7/15/22/29. A real layer-0 seven-token cross-check is bitwise equal to the
  pinned Transformers implementation. Contexts 1024/2048/4096 remain
  `NOT_TESTED` due CPU time.
- `[REAL-MODEL-VALIDATED]` Across ten layer/context captures, INT8 Q alone is
  0.316% mean/0.453% worst output RMSE. K4/V4 with one Q8.8 scale per vector is
  16.18%/35.73%; group32, group16, and group8 reduce this to 11.37/18.55%,
  9.07/13.92%, and 7.13/10.35%. V granularity matters more than K.
- `[SOFTWARE-SYNTHETIC]` On 200 held-out controlled-attention samples per bit
  width, per-token INT4/INT4 has 23.09% mean, 37.50% p95, and 50.62% worst
  attention-output relative RMSE. INT5/INT5 improves those to 10.96%, 17.03%,
  and 31.28%. These broad synthetic regimes include deliberate heavy tails and
  outliers; they are not model-accuracy or perplexity results.
- `[SOFTWARE-FIXED-POINT]` Q8.8 scale representation contributes 0.65% mean
  output relative RMSE relative to the floating-scale INT4 path, versus 23.09%
  from INT4 quantization. Granularity dominates scale representation. One
  scale per run increases total mean error from 23.10% to 48.10% and is
  rejected.
- `[THEORETICAL]` At equal `HEAD_DIM=128`, INT4 plus one 16-bit scale per K or V
  vector is 66 bytes/vector, 4.125 effective bits/value, 3.879× smaller than
  row-major FP16 or the existing equal-dimension 256-byte bit-sliced layout,
  and 1.939× smaller than row-major INT8. This is not the old dimension-changing
  8× comparison.
- `[REAL-MODEL-VALIDATED]` On a context-128 fit/context-512 evaluation, K
  first-order power correlation is 0.886 at INT4 and 0.991 at INT5. The V
  `sigma²/N_eff` model transfers poorly (INT4 correlation 0.304 with 342% mean
  relative residual) and must not select V precision.
- `[VIVADO-POST-SYNTH]` Vivado 2026.1 packages the IP and XSIM passes, but all
  four OOC configurations fail the 81.25 MHz target. The baseline 64/128 build
  uses 7,269 LUT, 1,303 FF, 17 DSP, zero BRAM and has WNS -26.962 ns. The next
  RTL priority is a pipelined raw INT8×INT4 group sum with one scale multiply,
  plus BRAM/streamed logits.
- The recommended small evaluation baseline is per-token-scale INT4 K/V in
  separate data/scale planes, `P=16`, first-class 128-bit AXI, and no mandatory
  Hadamard or dither. The real tensor sweep changes the preferred candidates
  but does not establish task accuracy/perplexity or an acceptable production
  threshold. Synthesizable RTL was not changed in this phase.

## B. Environment and model configuration

`[REAL-MODEL-VALIDATED]`

| Item | Value |
|---|---:|
| architecture | `BitNetForCausalLM` |
| hidden size | 2560 |
| layers | 30 |
| Q heads / KV heads | 20 / 5 |
| GQA ratio | 4 Q heads per KV head |
| head dimension | 128 |
| context limit | 4096 |
| RoPE theta | 500000 |
| checkpoint dtype/format | BF16 tensors plus packed U8 offline BitLinear projections |
| tokenizer vocabulary | 128256 |
| host | Windows 10, Pentium Gold G5500, 2 cores / 4 threads |
| RAM / accelerator | 4,160,401,408 bytes / no CUDA |
| Python / NumPy / Torch | 3.10.5 / 2.2.6 / 2.13.0+cpu |
| Transformers | pinned `096f25a...`, reports `4.52.0.dev0` |

Toolchain status (environment information, not numerical evidence): Vivado
2026.1 build 6511674 is installed at `E:\xilinx\2026.1`; the restored BASIC
license passed IP integrity packaging, XSIM execution, and OOC synthesis for
four HEAD_DIM/AXI configurations. Icarus Verilog 12.2022.06.11 is installed at
`C:\iverilog` and ran the complete regression.

The model has 542 safetensor entries: 332 BF16 and 210 U8. Across all 30
layers, packed projection code `3` is absent. Mean zero-code fractions are
46.75% for Q, 44.65% for K, and 37.64% for V. These are stored weight facts,
not activation statistics.

## C. TernaryCore existing-reference verification

`[SOFTWARE-SYNTHETIC / BRING-UP]` Independent reconstruction of
`firmware/tier1_bare.c` confirmed the deterministic `-1,0,+1` weight repetition,
the `-3..+3` activation repetition, first four outputs `[5,0,-5,5]`, and
checksum `0xfffff600`. These vectors are bring-up data, not LLM tensors.

## D. Synthetic validation

`[SOFTWARE-SYNTHETIC]` The corrected generator chooses target attention first,
sets logits to `log(a)+C`, and constructs K so
`q·k_i/sqrt(128)=s_i`. The maximum numerical mismatch between target and
realized softmax over all 300 samples was `5.96e-8`.

The sweep covers contexts 128, 512, 1024, 2048, and 4096; diffuse, moderate,
sharp, and sink attention; and Gaussian, Laplace, Student-t(df=3), sparse
0.1%×25, and 1%×10-outlier tensors. Each stratum has one calibration sample
and two independently seeded evaluation samples: 100 calibration and 200
held-out samples per bit width. Q is symmetric per-token INT8. K/V use signed
narrow-range absmax INT3/4/5/8 with round-to-nearest-even.

## E. Real BitNet tensor statistics

`[REAL-MODEL-VALIDATED]` Checkpoint configuration, tokenizer behavior, exact
prompt/token IDs, and packed weight storage were validated.

`[REAL-MODEL-VALIDATED]` The standard loader could not expand all packed
weights within host memory. The replacement runner memory-maps safetensors,
gathers only used embeddings, expands one ternary projection at a time, and
preserves the checkpoint BF16/INT8 order. It completed contexts 128 and 512,
all 30 layers, capturing layers 0/7/15/22/29. Full execution took 401.77 s and
1,401.18 s respectively, with observed peak working sets below 518 MB.

The custom layer was compared against the pinned Transformers
`BitNetDecoderLayer`, official `ActQuant`, and `unpack_weights` using real
layer-0 weights and seven tokens. BF16 output was bitwise equal, with zero
maximum absolute error and zero relative RMSE. This validates the component
arithmetic; it is not a task-accuracy or end-to-end generation comparison.

Pooled real-tensor joint results use INT8 Q and Q8.8 K/V scales:

| K/V and granularity | effective bits/value | bytes/token/KV-head | mean output RMSE | worst output RMSE | mean cosine |
|---|---:|---:|---:|---:|---:|
| K3/V3 group128 | 3.125 | 100 | 28.47% | 44.16% | 0.95637 |
| K3/V5 group128 | 4.125 | 132 | 13.96% | 18.39% | 0.99000 |
| K4/V4 group128 | 4.125 | 132 | 16.18% | 35.73% | 0.98377 |
| K4/V4 group32 | 4.500 | 144 | 11.37% | 18.55% | 0.99309 |
| K4/V5 group128 | 4.625 | 148 | 8.68% | 12.10% | 0.99629 |
| K4/V4 group16 | 5.000 | 160 | 9.07% | 13.92% | 0.99561 |
| K5/V5 group128 | 5.125 | 164 | 6.28% | 9.62% | 0.99790 |
| K4/V4 group8 | 6.000 | 192 | 7.13% | 10.35% | 0.99731 |

K3/V5 dominates K4/V4 at equal 4.125-bit storage, showing that V error is the
larger risk on these captures. K4/V5 is a numerical Pareto candidate, but its
five-bit packing/dequantization cost is not synthesized. Q8.8
scale-representation-only tensor RMSE is about 0.15% mean and below 0.32%
worst, with no saturation; group granularity is the dominant scale decision.

## F. K-only quantization results

`[SOFTWARE-SYNTHETIC]` Held-out results, with FP K/V as reference:

| K bits | K reconstruction RMSE | normalized QK RMSE | output RMSE mean / p95 / worst | output cosine |
|---:|---:|---:|---:|---:|
| 3 | 36.30% | 56.46% | 37.72% / 72.11% / 104.60% | 0.92558 |
| 4 | 17.48% | 25.10% | 14.96% / 28.80% / 47.09% | 0.98794 |
| 5 | 8.35% | 11.12% | 7.03% / 12.69% / 26.57% | 0.99734 |
| 8 | 0.99% | 1.29% | 0.80% / 1.43% / 1.87% | 0.99997 |

The 1%×10 family is the worst INT4 K family by mean output error (19.62%).
Raw rows also contain normalized bias, probability RMSE, max/p95/p99 output
error, entropy, `N_eff`, and top-token preservation.

## G. V-only quantization results

`[SOFTWARE-SYNTHETIC]` Held-out results, with fixed FP K/attention:

| V bits | V reconstruction RMSE | output RMSE mean / p95 / worst | output cosine |
|---:|---:|---:|---:|
| 3 | 36.21% | 35.73% / 50.13% / 63.04% | 0.93558 |
| 4 | 17.52% | 16.81% / 27.06% / 36.04% | 0.98491 |
| 5 | 8.40% | 8.04% / 12.86% / 16.87% | 0.99647 |
| 8 | 1.00% | 0.95% / 1.53% / 2.24% | 0.99995 |

The 1%×10 family is again the worst INT4 V family (22.81% mean), followed by
Student-t (20.12%). Outlier sensitivity is visible and is not discarded.

## H. Joint K/V results

`[SOFTWARE-SYNTHETIC]` Metadata assumes one 16-bit scale for each K vector and
one for each V vector.

| K/V | effective bits/value | bytes/token/KV-head | mean RMSE | p95 RMSE | worst RMSE | mean cosine | Pareto mean / p95 |
|---|---:|---:|---:|---:|---:|---:|---|
| 3/3 | 3.125 | 100 | 53.40% | 83.60% | 118.14% | 0.86652 | yes / yes |
| 3/4 | 3.625 | 116 | 42.17% | 73.72% | 108.59% | 0.91232 | no / no |
| 3/5 | 4.125 | 132 | 38.94% | 72.67% | 105.62% | 0.92236 | no / no |
| 4/3 | 3.625 | 116 | 39.17% | 54.31% | 76.71% | 0.92502 | yes / yes |
| 4/4 | 4.125 | 132 | 23.09% | 37.50% | 50.62% | 0.97328 | yes / yes |
| 4/5 | 4.625 | 148 | 17.40% | 30.60% | 48.69% | 0.98456 | yes / no |
| 5/3 | 4.125 | 132 | 36.48% | 51.71% | 62.05% | 0.93325 | no / no |
| 5/4 | 4.625 | 148 | 18.48% | 29.99% | 39.08% | 0.98228 | no / yes |
| 5/5 | 5.125 | 164 | 10.96% | 17.03% | 31.28% | 0.99379 | yes / yes |

No format is called acceptable without a model-quality criterion. The asymmetric
4/5 and 5/4 rows show why mean alone must not select a winner: 4/5 has the
better mean, while 5/4 has slightly better p95 and a substantially better
worst observation at identical storage.

## I. N_eff theory validation

`[THEORETICAL]` Under independent, zero-mean V error,
`P_V ≈ C_b sigma_V²/N_eff`.

`[SOFTWARE-SYNTHETIC]` Correction factors were fitted on 100 calibration
samples per width and evaluated on 200 disjoint samples.

| V bits | fitted C | held-out correlation | mean absolute relative residual | p95 residual |
|---:|---:|---:|---:|---:|
| 3 | 1.013 | 0.893 | 24.68% | 73.52% |
| 4 | 1.229 | 0.842 | 56.94% | 154.53% |
| 5 | 1.265 | 0.834 | 62.57% | 202.47% |
| 8 | 1.240 | 0.816 | 60.70% | 197.35% |

The synthetic correlation supports use as a ranking/trend signal. Pointwise
relative residual becomes ill-conditioned as true error power shrinks, and
sink attention is the clearest failure regime (INT4 mean relative residual
110.5%). On real context-128/512 captures, however, INT4 correlation falls to
0.304 and mean relative residual rises to 342%; this predictor is rejected for
V precision selection.

## J. K first-order theory validation

`[THEORETICAL]` The tested model is
`delta_s=delta_K q/sqrt(d)`, `delta_a≈(diag(a)-aa^T)delta_s`, and
`delta_o≈V^T delta_a`.

`[SOFTWARE-SYNTHETIC]`

| K bits | fitted power correction | held-out power correlation | mean relative power residual | p95 residual |
|---:|---:|---:|---:|---:|
| 3 | 0.205 | 0.669 | 76.64% | 92.28% |
| 4 | 0.967 | 0.985 | 20.49% | 63.26% |
| 5 | 0.962 | 0.997 | 8.45% | 22.41% |
| 8 | 1.005 | 0.99994 | 0.98% | 2.65% |

The linearization is useful at INT4 and stronger above it, but INT3 violates
the small-perturbation premise. The real context holdout gives correlations
0.797/0.886/0.991 and mean vector cosine 0.917/0.960/0.969 at INT3/4/5. It is
useful for K trend ranking at INT4/INT5, not as an error bound.

## K. Storage and bandwidth implications

`[THEORETICAL]` GQA accounting uses five KV heads, not twenty Q heads. At
context 4096 across all 30 layers:

| Format | bytes/token/layer | effective bits/value | all-layer cache | compression vs FP16 |
|---|---:|---:|---:|---:|
| FP16 | 2560 | 16.000 | 300.00 MiB | 1.000× |
| INT8 + scales | 1300 | 8.125 | 152.34 MiB | 1.969× |
| INT5 + scales | 820 | 5.125 | 96.09 MiB | 3.122× |
| INT4 + scales | 660 | 4.125 | 77.34 MiB | 3.879× |
| INT3 + scales | 500 | 3.125 | 58.59 MiB | 5.120× |

All context/format combinations are in `gqa_cache_storage.csv`.

For one `HEAD_DIM=128` INT4 K or V vector, payload is 64 bytes and a per-token
scale adds 2 bytes. Group32/group16/group8 add 8/16/32 bytes, giving
4.5/5.0/6.0 effective bits/value. Equal-dimension INT4 per-token compression
is 3.879× versus FP16 or the existing 256-byte bit-sliced record, and 1.939×
versus row-major INT8. No 8× equal-dimension claim is made.

`[THEORETICAL]` Independent payload beats at dimension 128 are:

| Format | payload | AXI128 beats/pad | AXI256 beats/pad |
|---|---:|---:|---:|
| INT8 | 128 B | 8 / 0 B | 4 / 0 B |
| INT5 | 80 B | 5 / 0 B | 3 / 16 B |
| INT4 | 64 B | 4 / 0 B | 2 / 0 B |
| INT3 | 48 B | 3 / 0 B | 2 / 16 B |

A separate 16-bit scale plane packs 8 scales per AXI128 beat or 16 per AXI256
beat. For INT4, `K_DATA_BASE + token*64` is a power-of-two stride. An
interleaved 66-byte record loses that property and tokenwise transfers expand
to 80 bytes on AXI128 or 96 bytes on AXI256. Long bursts move essentially the
same bytes, so the separate plane is preferred for independent prefetch and
simpler addressing.

## L. Recommended fixed FPGA baseline

The current RTL remains unchanged. The software-derived v0.2 evaluation
baseline is:

```text
AXI K/V data reader -> burst data FIFO --\
                                           -> dequant / P=16 QK or AV MAC
scale-plane reader -> scale FIFO ----------/
```

1. Keep the small baseline `HEAD_DIM=64`, parameterized to 128 for the actual
   checkpoint.
2. Signed INT4 K and V with group32 and group16 Q8.8 modes, separate planes.
3. `P=16`; 128-bit AXI first-class, 256-bit optional.
4. Multi-vector bursts, K/V and scale prefetch, and double buffering before
   increasing MAC parallelism.
5. No required Hadamard and no dither.

This fixes a small hardware evaluation target, not a claim that INT4 preserves
model quality. INT5 and K4/V5 remain architecture-study options because they
materially improve real-tensor distortion at modest storage cost, though
five-bit packing is less regular.

## M. Alternatives worth parameterizing

- `[SOFTWARE-SYNTHETIC]` INT5 and asymmetric K4/V5 or K5/V4 modes, because
  they occupy distinct mean/p95 trade-offs.
- `[REAL-MODEL-VALIDATED]` Group32/group16 scales. At `HEAD_DIM=128`, group32
  reduces K4/V4 mean/worst output RMSE to 11.37/18.55% at 144 bytes per
  token/KV-head; group16 reaches 9.07/13.92% at 160 bytes and aligns one scale
  with each `P=16` slice.
- `[SOFTWARE-FIXED-POINT / REAL-MODEL-VALIDATED]` FP16 scales only if broader
  real-tensor profiling exposes Q8.8 clipping/resolution problems. No Q8.8
  saturation occurred in the tested real captures.
- `[SOFTWARE-SYNTHETIC]` Optional Hadamard only. The prior dimension-64
  group16 sweep changed output RMSE from 13.17% (none) to 12.49/11.73/11.64/
  11.37/11.72% for H4/H8/H16/H32/H64, at 128/192/256/320/384 add/sub outputs
  per vector. It adds hardware cost and does not justify baseline inclusion.

## N. Failed hypotheses

- `[SOFTWARE-FIXED-POINT]` One scale per run is numerically unsafe: 48.10%
  mean output RMSE versus 23.10% per token.
- `[SOFTWARE-SYNTHETIC]` INT3 is not a small-error approximation in these
  regimes; joint worst error exceeds 100% and K first-order prediction is weak.
- `[SOFTWARE-SYNTHETIC]` `sigma²/N_eff` is not a reliable point estimate for
  sink attention despite useful aggregate correlation.
- `[SOFTWARE-SYNTHETIC]` Hadamard is not a free or universal improvement; it
  remains off the baseline Pareto recommendation.
- `[REAL-MODEL-VALIDATED]` One scale per vector is not numerically safe enough
  to freeze as the baseline on the tested real tensors; K4/V4 worst output
  distortion reaches 35.73%.
- `[VIVADO-POST-SYNTH]` The existing per-lane dequantization plus unpipelined
  16-lane reduction does not meet the 81.25 MHz synthesis target.

## O. Remaining unknowns

- Contexts 1024/2048/4096, broader heads/layers, and prompt-independent real
  pre/post-RoPE Q/K/V distributions.
- Task accuracy, perplexity, generation quality, and acceptable error bounds.
- Whether the observed group32/group16, K4/V5, and K5/V5 Pareto order persists
  across natural prompts and downstream evaluation.
- Physical DDR/MIG efficiency and routed Fmax for burst data/scale FIFOs.
- Exact deterministic-dither mapping and whether it avoids sequential-address
  correlation; no dither claim is included here.

## P. RTL handoff requirements

Before changing baseline precision, extend the recorded revision to independent
natural prompt sets and, when CPU time permits, contexts 1024/2048/4096. Keep
the official/custom layer cross-check as a gate whenever reference arithmetic
changes.

`[RTL-SIMULATED]` Existing v0.1 `HEAD_DIM=64` cycle accounting is:

| AXI/context | total cycles | issue | launch | AR | R empty | R transfer | handoff | MAC | result | MAC util. |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 128/512 | 7,379 | 512 | 1,024 | 1,022 | 1,124 | 625 | 512 | 2,048 | 512 | 27.75% |
| 128/4096 | 59,256 | 4,096 | 8,192 | 8,203 | 9,101 | 5,088 | 4,096 | 16,384 | 4,096 | 27.65% |
| 256/512 | 6,620 | 512 | 1,024 | 990 | 1,022 | 512 | 0 | 2,048 | 512 | 30.94% |
| 256/4096 | 53,252 | 4,096 | 8,192 | 8,198 | 8,190 | 4,096 | 0 | 16,384 | 4,096 | 30.77% |

`[RTL-SIMULATED]` The same parameterized RTL now also has complete regression
coverage at the checkpoint-authoritative `HEAD_DIM=128`:

| AXI/context | total cycles | cycles/key | latency at 81.25 MHz | MAC util. | Mkeys/s | K payload MB/s |
|---|---:|---:|---:|---:|---:|---:|
| 128/512 | 10,847 | 21.186 | 133.50 us | 37.76% | 3.835 | 245.45 |
| 128/4096 | 86,690 | 21.165 | 1,066.95 us | 37.80% | 3.839 | 245.69 |
| 256/512 | 9,288 | 18.141 | 114.31 us | 44.10% | 4.479 | 286.65 |
| 256/4096 | 74,299 | 18.139 | 914.45 us | 44.10% | 4.479 | 286.67 |

No datapath RTL changed to obtain these rows; testbench address/beat formulas
were parameterized and the AXI-Lite wrapper was exercised at dimension 128.
The same first-class dimension64/AXI128 boundary/error test passes XSIM 2026.1,
and testbench failures now use `$fatal` so a timeout/mismatch cannot exit as a
successful test.

`[VIVADO-POST-SYNTH]` Timing-driven OOC synthesis on
`xc7a100tcsg324-1`, with `P=16`, `MAX_CONTEXT=4096`, and an 81.25 MHz target:

| HEAD_DIM/AXI | LUT | LUTRAM LUT | FF | DSP | BRAM | WNS | critical path | equivalent Fmax |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 64/128 | 7,269 | 2,816 | 1,303 | 17 | 0 | -26.962 ns | 39.153 ns | 25.46 MHz |
| 64/256 | 7,080 | 2,816 | 1,552 | 17 | 0 | -26.760 ns | 38.951 ns | 25.60 MHz |
| 128/128 | 9,017 | 2,816 | 1,822 | 17 | 0 | -26.944 ns | 39.135 ns | 25.48 MHz |
| 128/256 | 8,845 | 2,816 | 2,069 | 17 | 0 | -26.760 ns | 38.951 ns | 25.60 MHz |

All four configurations synthesize but fail the target timing. The 16-lane
unregistered scaled dot reduction is the critical path, and the 4K×32 logit
store maps to 2,816 LUTRAM LUTs rather than BRAM. Thus the simulated 81.25 MHz
latency conversions are not timing-closed throughput. The next revision must
first compute raw INT8×INT4 group sums, apply one scale per group, register the
reduction, and make logit storage synchronous BRAM or a stream.

At dimension 64, doubling width saves only 10–11.5%; at dimension 128 it saves
about 14.4%. `[THEORETICAL]` At context 512, estimated
standalone speedups are 1.07× deeper FIFO, 1.48× 16-vector bursts, 1.38×
double buffering, and 1.07× continuous MAC scheduling. Their combined
3.48×/96.6%-utilization target is optimistic and must be RTL-simulated.

`[THEORETICAL]` Amdahl budget using mixed-source repository inputs:

| component | current ms | current fraction | proposed ms/kind | next action |
|---|---:|---:|---|---|
| QK | 573.9 | 12.05% | 40.7, v0.1 RTL simulation | burst/FIFO/double buffer |
| softmax | 617.4 | 12.96% | 20.0, analytical | streaming softmax |
| weighted V | 1035.0 | 21.73% | 50.9, analytical | INT4 V streamer + AV MAC |
| paging/cache | 645.7 | 13.56% | 352.2, repository measurement | persistent/no-flush path |
| normalization/quantization | 505.4 | 10.61% | 21.4, repository measurement | integrate fabric normalizer |
| QK norm/RoPE/quantize | 401.8 | 8.44% | unchanged | reprofile |
| MLP activation | 368.5 | 7.74% | unchanged | reprofile |
| ternary projections | 345.9 | 7.26% | unchanged | page reuse |
| KV write/bit-slice | 268.7 | 5.64% | unchanged | row-major K/V producer later |

| scenario | estimated ms/token | speedup | evidence caveat |
|---|---:|---:|---|
| current | 4762.4 | 1.00× | measured operator budget |
| QK only | 4229.2 | 1.13× | QK simulation, dimension changes to 64 |
| QK + quantized V | 3548.4 | 1.34× | analytical, dimension changes to 64 |
| QK + V accumulation | 3245.0 | 1.47× | analytical AV |
| full attention path | 2647.6 | 1.80× | analytical softmax/AV |

Therefore the immediate QK correction is arithmetic pipelining/group scaling
and BRAM/streamed logits, followed by burst/FIFO/double-buffer utilization—not
a wider bus or more lanes. The next distinct block after that should be V
streaming/attention-weighted V accumulation, the largest current component.
All new RTL must retain the existing boundary/back-pressure/timeout regression
requirements, and a timeout must fail rather than terminate a test silently.
