# KV-cache v0.2 audit addendum and implementation handoff

Date: 2026-08-16

Branch: `codex/kv-ip-vivado-2026`

Toolchain: Icarus Verilog and Vivado 2026.1, part `xc7a100tcsg324-1`

This is the authoritative update to the preliminary v0.2 profile note. It
reviews the newly supplied audit ZIP, extends reference analysis through all 30
BitNet layers, freezes provisional scale contracts, and compares QK arithmetic
in simulation and synthesis. Synthetic results are tensor-distortion tests,
not model-accuracy or perplexity claims.

## Executive decision

- Keep the QK baseline small: `HEAD_DIM=128`, `P=16`, INT8 Q, K4, one K scale
  per 128 values, separate data/scale planes, no Hadamard, and no dither.
- Use Q `UQ1.15` and K/V `UQ5.11`. Generate codes from the high-precision
  absmax scale; dequantize with the stored rounded scale.
- Use RTL `AUTO` multiplication. It kept one DSP and used 18.9--20.7% fewer
  LUTs than explicit SHIFT_ADD.
- Treat `PACKED5` (K4 g128, V5 g128) as the leading full-attention candidate:
  only 2 bytes/token/KV-head over `REGULAR4`, with better measured distortion.
  Do not make it the hardware baseline until packed V5/AV is synthesized.
- Optimize utilization before port or MAC width: infer synchronous score BRAM,
  then add multi-vector bursts, K/scale FIFOs, prefetch, and double buffering.
  The next distinct RTL block should be V streaming and AV accumulation.

## New ZIP review

`F:/Xilinx_WorkSpace/kv-validation-audit-addendum-20260816.zip` passed ZIP CRC
validation. SHA-256:

`7F1B2AA62F5D87481F4EC77FF56A3CAD3297326E7062C3E0D158C438615F7DDD`

Its four handoff files are preserved under
`analysis/kv_validation/audit_addendum/`. The requested three-profile, scale,
and SHIFT_ADD/DSP/AUTO comparisons are completed below. The supplied softmax
table is retained as a candidate, not implemented RTL.

The earlier `kv_rtl_prep.zip` also passed CRC validation; SHA-256:
`30C37ED63C76A47A9C4066AC9BC9232C9951C96D96FC7639CD9249DCCC2AA89A`.
Its files are preserved under `analysis/kv_validation/prep/kv_rtl_prep/`.

## ABI-v2 implementation audit corrections

The documentation/RTL cross-check found and corrected contract defects before
the next architecture revision:

| Audit finding | Correction | Regression evidence |
|---|---|---|
| `CFG` reset encoded Q8.8 1.0 (`0x0100`) although the frozen K-scale contract is UQ5.11 | Reset is `0x0800`; wrapper test reads it before writing | AXI-Lite wrapper PASS |
| The unsigned K scale was stored signed and sign-extended on readback | Register is unsigned and zero-extended | AXI-Lite wrapper PASS |
| The AXI reader exposed K5 and arbitrary P parameters although its physical unpacker is K4/P16 | Packaged engine fixes K4/P16; K5 remains standalone-core research only | all four geometry regressions PASS |
| The 16-leaf QK tree exposed a misleading lane-count parameter | Lane count is structurally fixed to 16 at the module boundary | K4/K5 golden PASS |
| A legal but excessive UQ5.11 code could truncate a scaled 32-bit logit | Conservative pre-AXI scale guard returns `0x03` | dedicated unsafe-scale test PASS |
| A non-zero high base or final context address could truncate/wrap a 32-bit M_AXI port | Pre-AXI address-range guard returns `0x04` | wrapper high-word and engine wrap tests PASS |
| Native-width INT4 unpack generated a zero-replication synthesis warning | Separate native-width/sign-extension generate branches | Icarus `-Wall`; Vivado warning removed |

The wrapper core ID is now `0x4B56_0002`, and the packaged IP version is `2.0`.
Reserved nibble `0x8` is also exercised through the full engine and returns
`0x30` without accepting a logit. These are correctness/contract fixes, not a
claim of improved model accuracy.

## Measured and simulated results

### Actual-model end-to-end injection

The runner used the local `microsoft/bitnet-b1.58-2B-4T` checkpoint and two
independent prose prompts at context 128. It streamed all 30 layers and injected
quantized Q/K/V at every attention layer. A separate seven-token layer-0 check
remained bitwise equal to pinned Transformers. This is distortion, not task
quality.

| Profile | Bytes/token/KV-head | Mean final hidden RMSE | Worst final | Mean last-token RMSE | Min last-token cosine | Mean KL | Top-1 |
|---|---:|---:|---:|---:|---:|---:|---:|
| FP reference | 512 | 0 | 0 | 0 | 1.000000 | 0 | 2/2 |
| Q8 only | -- | 3.741% | 3.981% | 3.543% | 0.999370 | 0.001349 | 2/2 |
| REGULAR4 | 146 | 8.417% | 9.521% | 9.790% | 0.995990 | 0.007953 | 2/2 |
| PACKED5 | 148 | 7.497% | 8.230% | 7.593% | 0.997509 | 0.002075 | 2/2 |
| ACCURATE5 | 164 | 6.307% | 6.980% | 5.136% | 0.998618 | 0.002215 | 2/2 |

`PACKED5` is a measured software Pareto improvement over `REGULAR4`: 1.37%
more storage reduced mean final-hidden RMSE by 10.9%, mean last-token RMSE by
22.4%, and mean KL by 73.9%. `ACCURATE5` improves hidden distortion again but
costs 16 more bytes than PACKED5. Two prompts cannot establish generation
quality or reliable top-k behavior.

Raw: `real_model/end_to_end_injection/{summary.csv,summary.json}` and per-prompt
`run.json` files.

### K/V scale contract

Ten real captures cover contexts 128/512 and layers 0/7/15/22/29. Four unsigned
fixed-point formats and both code policies were tested; no scale underflow or
overflow occurred.

| Profile | UQ5.11 mean scale-only output RMSE | Worst | Mean total output RMSE | Maximum ideal scale |
|---|---:|---:|---:|---:|
| REGULAR4 | 0.0293% | 0.0484% | 10.627% | 6.429 |
| PACKED5 | 0.0325% | 0.0586% | 8.689% | 3.000 |
| ACCURATE5 | 0.0728% | 0.1172% | 6.249% | 3.000 |

UQ4.12 is finer, but UQ5.11 error is already two orders below K/V code error
and gives more range. UQ8.8 was materially coarser. Contract: Q scale UQ1.15;
K/V scale UQ5.11; symmetric codes `-7..7` or `-15..15`; reserved minimum code
invalid; LSB-first packing; codes use high-precision absmax, while dequant uses
the stored rounded scale.

Raw: `real_model/kv_scale_contract_sweep/{all_results.csv,summary.csv,summary.json}`.

### QK RTL regression

Standalone K4/K5 cores match actual-model golden vectors. The full wrapper
passed lengths `1, 7, 63, 64, 65, 127, 128, 129, 511, 512, 513, 1023, 1024,
1025, 4095, 4096`, randomized AR/R back-pressure, short-after-4096, unaligned
or out-of-range base, invalid context, unsafe scale, reserved INT4 code, AXI
errors, timeouts, and wrapper tests. Timeouts fail.
The compatibility wrapper has no physical scale plane/FIFO yet, so scale FIFO
underflow and true scale/data synchronization remain next-revision tests.

Vivado 2026.1 IP-XACT packaging/integrity also passes for component version
2.0. The saved package defaults to head128, declares 81.25 MHz, and no longer
exposes K width, lane count, result width, or scale group combinations that the
wrapper cannot implement.

Golden: `real_model/qk_profile_golden_v0_2/`.

### Vivado 2026.1 QK-core synthesis

Post-synthesis OOC at 81.25 MHz:

| Profile | Style | LUT | FF | DSP | WNS | Estimated Fmax |
|---|---|---:|---:|---:|---:|---:|
| K4 | SHIFT_ADD | 1,036 | 176 | 1 | +4.820 ns | 133.55 MHz |
| K4 | DSP | 240 | 176 | 21 | +4.820 ns | 133.55 MHz |
| K4 | AUTO | 840 | 176 | 1 | +4.820 ns | 133.55 MHz |
| K5 | SHIFT_ADD | 1,317 | 178 | 1 | +4.820 ns | 133.55 MHz |
| K5 | DSP | 245 | 178 | 21 | +4.820 ns | 133.55 MHz |
| K5 | AUTO | 1,044 | 178 | 1 | +4.820 ns | 133.55 MHz |

AUTO dominates explicit SHIFT_ADD here: 196 fewer K4 LUTs and 273 fewer K5
LUTs with the same one DSP and timing. Forced DSP consumes 21 DSPs and is not
the small baseline. Raw reports/DCPs:
`hardware_estimates/vivado_qk_core_2026_1/`.

### Full-wrapper synthesis

| AXI | LUT | Logic LUT | LUTRAM LUT | FF | BRAM | DSP | WNS | Equivalent Fmax |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 128 | 8,783 | 5,967 | 2,816 | 1,829 | 0 | 1 | -0.175 ns | 80.11 MHz |
| 256 | 8,601 | 5,785 | 2,816 | 2,085 | 0 | 1 | +0.105 ns | 81.95 MHz |

The 256-bit wrapper meets 81.248 MHz OOC post-synthesis. The first-class
128-bit wrapper misses by 0.175 ns, so timing is not closed after the ABI guard
revision. It uses 13.85% of device LUTs, 1.44% of FFs, 0% BRAM, and 0.42% of
DSPs; the 256-bit variant uses 13.57%, 1.64%, 0%, and 0.42%. The 2,816 LUTRAM
LUTs are primarily the asynchronous 4096x32 logit store. The next score-memory
revision must retime the QK path and infer synchronous BRAM before claiming the
81.25 MHz target. These are not routed or board-DDR measurements. Raw:
`hardware_estimates/vivado_wrapper_v0_2_auto/`.

## Cycle accounting

Deterministic Icarus accounting at `HEAD_DIM=128`, P=16, 81.25 MHz:

| AXI | Keys | Total | Issue | Launch | AR | R empty | R xfer | Handoff | MAC | Result | Mkeys/s | K MB/s | MAC util. |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 128 | 512 | 11,826 | 512 | 1,024 | 978 | 1,329 | 815 | 1,536 | 4,096 | 1,536 | 3.518 | 225.1 | 34.64% |
| 128 | 4,096 | 94,912 | 4,096 | 8,192 | 8,244 | 10,589 | 6,447 | 12,288 | 32,768 | 12,288 | 3.506 | 224.4 | 34.52% |
| 256 | 512 | 10,323 | 512 | 1,024 | 1,036 | 1,076 | 531 | 512 | 4,096 | 1,536 | 4.030 | 257.9 | 39.68% |
| 256 | 4,096 | 82,489 | 4,096 | 8,192 | 8,196 | 8,518 | 4,335 | 4,096 | 32,768 | 12,288 | 4.034 | 258.2 | 39.72% |

At 4,096 keys, doubling AXI width improves keys/s by 15.1% and reduces cycles
13.1%, yet utilization stays below 40%. Per-vector launch/address phases,
R-empty time, handoff, and result bookkeeping dominate avoidable loss. Long
bursts, deeper data/scale FIFOs, prefetch, and double buffering precede more
MAC lanes.

## Effective storage and compression

Equal-dimension `HEAD_DIM=128`, combined K+V per token per KV head:

| Profile | K payload | V payload | Metadata | Total bytes | Bits/value | vs FP16 512 B | vs INT8 256 B | vs existing equal-128 bit-sliced 512 B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| REGULAR4: K4 g128, V4 g16 | 64 | 64 | 18 | 146 | 4.5625 | 3.507x | 1.753x | 3.507x |
| PACKED5: K4 g128, V5 g128 | 64 | 80 | 4 | 148 | 4.6250 | 3.459x | 1.730x | 3.459x |
| ACCURATE5: K5 g128, V5 g128 | 80 | 80 | 4 | 164 | 5.1250 | 3.122x | 1.561x | 3.122x |

At equal 128 dimensions, a row-major INT4 payload is 64 bytes per K or V and
exactly 4x smaller than the existing 256-byte physical vector before metadata.
The old 8x number compared unequal dimensions and is not an equal-dimension
compression ratio.

For the requested initial `HEAD_DIM=64` synthetic study, INT4 payload is 32
bytes per K or V. A 16-bit scale adds 2 bytes/token, group16 adds 8 bytes, and
group8 adds 16 bytes. These numbers are separate from actual-model head128.

## Recommended v0.2 memory layout

Use separate planes. For K4/head128:

```text
K_DATA_BASE + ((token * N_KV_HEADS + kv_head) << 6)   # 64-byte payload
K_SCALE_BASE + ((token * N_KV_HEADS + kv_head) << 1)  # one UQ5.11 scale
```

This preserves a power-of-two payload stride and independent metadata bursts.
A 128-bit beat carries eight scales; 256-bit carries sixteen. Interleaved
66-byte records lose simple shift addressing and complicate long bursts.

V uses separate planes too. REGULAR4 V4 stride is 64 bytes plus 16 metadata
bytes; PACKED5/ACCURATE5 use an 80-byte V5 payload plus one scale. Measure the
80-byte reader before committing the full-attention profile. The current
wrapper still replicates one scalar register scale; the physical scale reader
and FIFO are not implemented.

## Synthetic numerical experiments

The fixed-seed suite covers contexts 128/256/512/1024/2048/4096; INT8 Q; FP,
INT8, INT5, INT4, INT3 K/V; Gaussian, Laplace, Student-t, sparse outlier, and
approximately 1% x10-outlier distributions. CSV/JSON results include normalized
QK RMSE, output RMSE/cosine, bias, payload, metadata, and effective storage.
The quantizer accepts optional dither; exact deterministic `G_B` mapping remains
TODO and is not in RTL.

Scale granularity dominates representation precision; one scale/run is unsafe;
outliers hurt coarse groups most. The none/H4/H8/H16/H32/H64 by g64/g32/g16/g8
Hadamard sweep found some mean-error improvements but no clear hardware Pareto
reason to require transform logic. Hadamard remains out of baseline. Raw:
`pareto/hadamard_pareto_head64.csv`.

## Analytical estimates

The 4.7624 s/token budget is a mixed-source planning model, not one end-to-end
timing run:

| Component | Current ms | Proposed ms | Fraction | Next action |
|---|---:|---:|---:|---|
| QK logits | 573.9 | 40.7 | 12.05% | Burst/FIFO/scale-plane utilization |
| Softmax | 617.4 | 20.0 | 12.96% | Streaming block after interfaces freeze |
| Attention-weighted V | 1,035.0 | 50.9 | 21.73% | Next RTL block: V streamer + P16 AV |
| Paging/cache movement | 645.7 | 352.2 | 13.56% | Persistent CDMA/no flush |
| Normalization/quantization | 505.4 | 21.4 | 10.61% | Integrate fabric normalizer |
| QK norm/RoPE/quantize | 401.8 | 401.8 | 8.44% | Profile later |
| MLP activation | 368.5 | 368.5 | 7.74% | Profile later |
| Ternary projections | 345.9 | 345.9 | 7.26% | Page reuse/cache |
| KV write/bit-slice | 268.7 | 268.7 | 5.64% | Measure low-bit writer |

| Scenario | ms/token | tok/s | Speedup |
|---|---:|---:|---:|
| Current | 4,762.4 | 0.210 | 1.00x |
| QK only | 4,229.2 | 0.236 | 1.13x |
| QK + quantized V storage | 3,548.4 | 0.282 | 1.34x |
| QK + V accumulation | 3,245.0 | 0.308 | 1.47x |
| Full attention path | 2,647.6 | 0.378 | 1.80x |
| Full attention + known fixes | 1,870.1 | 0.535 | 2.55x |

The quantized-V row uses target64 traffic. Equal-128 sensitivity is 3,646.5
ms/token and 1.306x; it must remain separate from dimension-change benefits.

## Unverified hypotheses and required validation

- Two prompts at context128 cannot support accuracy, perplexity, generation,
  or long-context claims. Repeat on a representative set and contexts 512--4096.
- UQ5.11 did not saturate on ten captures; other models/checkpoints/outliers may
  need more range.
- PACKED5 is software-Pareto, but packed V5 reader/unpacker/AV routing, power,
  resources, and throughput are not synthesized.
- Wrapper timing is OOC and marginal. Routed Arty timing, DDR behavior, and
  board throughput are unmeasured.
- Synchronous Q8.8 score BRAM requires freezing Q-scale, `1/sqrt(HEAD_DIM)`,
  rounding, clipping, and softmax ABI.
- The supplied UQ1.15 exp LUT/restoring-divider softmax candidate is not
  independently regenerated here and is not RTL-verified.
- Deterministic dither remains an optional interface TODO.

## Next implementation order

1. Freeze score conversion/rounding, infer synchronous BRAM, then rerun Icarus
   before Vivado.
2. Add separate K-scale reader/FIFO and explicit underflow/synchronization tests.
3. Add long bursts, deeper K/scale FIFOs, and double buffering.
4. Implement and synthesize REGULAR4 and PACKED5 V streaming/AV; choose from
   combined numerical/resource/throughput Pareto results.
5. Implement softmax after score/AV interfaces stabilize.

No PR is created by this handoff.
