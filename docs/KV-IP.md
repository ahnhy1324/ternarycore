# INT4 KV-cache IP v0.1

The first hardware milestone is a read-only K path:

`DDR K vector -> signed INT4 unpack -> Q8.8 dequant -> INT8 Q dot -> logits`

It is intentionally independent of V accumulation, softmax, write-side
quantization, Hadamard transforms, and deterministic dither.

## Geometry and numeric contract

| Item | v0.1 value |
|---|---:|
| `HEAD_DIM` | 64 |
| `KV_BITS` | 4, signed two's complement |
| `P` | 16 lanes |
| `MAX_CONTEXT` | 4096 |
| Query | signed INT8 |
| K scale | signed Q8.8, one scale per run (v0.1 ABI; numerically unsafe candidate) |
| Logit | signed 32-bit, binary point remains at bit 8 |
| Arty memory port | 128-bit AXI4, two beats per K vector |
| Portable handoff port | 256-bit AXI4, one beat per K vector |

Nibbles are LSB-first: byte bits `[3:0]` are the lower dimension and bits
`[7:4]` are the next dimension. One 64-element vector is 32 bytes. `K_BASE`
is the already-computed base for one layer/KV-head and must be 32-byte aligned:

`K_ADDR(token) = K_BASE + token * 32`

The executable packing reference is `sim/verify/verify_kv_int4.py`. The v0.2
analysis below does not change this v0.1 RTL contract.

## Register map

The Arty DDR block design maps the 64-KiB AXI-Lite aperture at `0x44500000`.

| Offset | Register | Meaning |
|---:|---|---|
| `0x0000` | `CTRL` | write bit 0 start; bit 1 clear status; read bit 31 done |
| `0x0004` | `STATUS` | bit 0 busy, bit 1 done, bit 2 error |
| `0x0008` | `K_BASE_LO` | lower K-region address |
| `0x000C` | `K_BASE_HI` | upper K-region address |
| `0x001C` | `CONTEXT_LEN` | runtime number of K vectors, 1..4096 |
| `0x0020` | `TOKEN_POS` | reserved metadata for later dither/control |
| `0x0024` | `CFG` | signed Q8.8 K scale in bits `[15:0]` |
| `0x0028` | `PERF_CYCLES` | cycles in the most recent/current run |
| `0x002C` | `ERROR` | error code in bits `[7:0]` |
| `0x0030` | `ID` | `0x4B560001` |
| `0x0034` | `GEOMETRY` | AXI width, head dim, lanes, KV bits |
| `0x0100..013F` | `Q` | 64 INT8 values, four per 32-bit word |
| `0x1000..4FFF` | `LOGITS` | 4096 signed 32-bit results |

Error `0x01` is an invalid context, `0x02` is an unaligned base, `0x11/0x12`
are AXI timeouts, `0x13` is an AXI error response, `0x14` is malformed RLAST,
and `0x80` is a start request while busy.

## Existing firmware incompatibility

`firmware/ddr_host.c` currently uses an INT8, bit-sliced cache with
`HEAD_DIM=128` so that the existing ternary array can execute attention. That
layout is not the row-major INT4 ABI above. Do not point this IP at the current
`KV_K` region. Integration needs a new INT4 producer/converter and a reserved
DDR region before firmware enables the block.

## Reproducible checks

From `sim/`:

```sh
make tb_kv_cache
make verify
```

The RTL regression runs lengths
`1,7,63,64,65,127,128,129,511,512,513,1023,1024,1025,4095,4096` in both 128-
and 256-bit AXI configurations. It includes randomized AXI address/data stalls,
a short run after 4096, invalid arguments, bounded timeout checks, and AXI error
propagation. Scale/data synchronization and scale-FIFO underflow cannot be
tested until the v0.2 scale path exists; they are hard requirements before that
RTL can replace v0.1.

Package and build after simulation passes:

```sh
vivado -mode batch -source ip/package_axi_kv_cache.tcl
./Arty7/build_ddr.sh
```

The packaging script generates the version-specific `ip/axi_kv_cache`
metadata locally. Keeping that generated churn out of the RTL branch allows
the same sources to be packaged later with Vivado 2025.2.

## v0.2 analysis status and reproducibility

No baseline RTL was changed for this analysis. Rebuild every machine-readable
artifact with:

```sh
cd sim
make analyze_kv
```

The numerical runner uses base seed `20260816`, records the derived seed for
every dataset, and stores tool/source provenance in JSON. The generated files
are:

- `docs/runs/kv-v02-numerical.csv` and `kv-v02-analysis.json`
- `docs/runs/kv-v02-scale-granularity.csv` and `kv-v02-int4-pareto.csv`
- `docs/runs/kv-v02-hadamard.csv` and `kv-v02-hadamard-pareto.csv`
- `docs/runs/kv-v02-storage.csv` and `kv-v02-layout.csv`
- `docs/runs/kv-v02-cycle.csv`, `kv-v02-cycle-options.csv`, and
  `kv-v02-cycle.json`
- `docs/runs/kv-v02-amdahl.csv`, `kv-v02-scenarios.csv`, and
  `kv-v02-system.json`

### Experiment definition

All numerical results in this section are **synthetic quantization
experiments, not model accuracy, task accuracy, or perplexity**. Q, K, and V
are independently generated and RMS-normalized per vector. Distributions are
Gaussian, variance-normalized Laplace, Student-t with three degrees of freedom,
0.1% sparse x25 outliers, and 1% x10 outliers. Context lengths are
`128,256,512,1024,2048,4096`; the trial count is deterministic and bounded by
the context length.

The FP32 computation is the numerical reference. Q is symmetric per-token
INT8. K and V use symmetric narrow signed ranges (`[-127,127]`, `[-15,15]`,
`[-7,7]`, or `[-3,3]`) with absmax scale and round-to-nearest-even. The
cross-bit sweep stores scales as FP16 so Q8.8 resolution cannot distort the
bit-width comparison. FP rows use FP32 arithmetic but FP16 byte counts in the
storage columns.

## Synthetic numerical experiments

### K/V bit-width baseline

Means below give equal weight to each distribution/context experiment row.
The error includes INT8 Q plus quantized K and V. Each low-bit format uses one
FP16 scale per token and per K or V vector.

| K/V format | normalized QK RMSE | attention-output relative RMSE | output cosine | bytes/vector incl. scale |
|---|---:|---:|---:|---:|
| FP reference | 0.000% | 0.000% | 1.000000 | 128 |
| INT8 Q, FP K/V | 0.781% | 0.661% | 0.999976 | 128 |
| INT8 K/V | 1.111% | 1.250% | 0.999914 | 66 |
| INT5 K/V | 6.694% | 9.189% | 0.995467 | 42 |
| INT4 K/V | 14.070% | 18.933% | 0.980917 | 34 |
| INT3 K/V | 30.502% | 41.459% | 0.915429 | 26 |

INT4 attention-output RMSE by distribution is 15.30% Gaussian, 19.23%
Laplace, 22.34% Student-t, 15.85% sparse x25 outliers, and 22.10% for 1% x10
outliers. These results show the expected outlier sensitivity but cannot select
a model format without real activation captures.

### INT4 scale granularity

The Q8.8 rows are the relevant small-hardware candidates. Metadata and total
bytes are for one K or V vector at `HEAD_DIM=64`.

| scale granularity | metadata B/token | total B/vector | effective bits/value | QK RMSE | output RMSE | output cosine |
|---|---:|---:|---:|---:|---:|---:|
| one/run | `2/context` | `32 + 2/context` | approximately 4.00 | 27.348% | 38.432% | 0.92951 |
| one/token (group64) | 2 | 34 | 4.25 | 14.073% | 18.965% | 0.98087 |
| group32 | 4 | 36 | 4.50 | 11.803% | 15.886% | 0.98659 |
| group16 | 8 | 40 | 5.00 | 9.778% | 13.165% | 0.99087 |
| group8 | 16 | 48 | 6.00 | 7.862% | 10.576% | 0.99411 |

One scale/run worsens as context/outlier exposure grows: mean output RMSE is
35.33% at context 128 and 42.42% at 4096. It is rejected for v0.2.

Group16 is the recommended **synthetic Pareto knee**, not a frozen model
decision. Compared with group64, it increases storage by 17.6% (34 to 40
bytes) and reduces mean output error by 30.6%. It also aligns exactly with
`P=16`: each MAC slice consumes one scale, so one scalar scale multiplier can
be reused each cycle. Group8 needs two scales per 16-lane slice and reaches six
effective bits/value, leaving only 1.33x compression versus row-major INT8.

### Scale representation error

Codes are selected with the same FP32 absmax scale for all representations.
The stored-scale reconstruction is compared with the same codes reconstructed
using the ideal scale, separating scale representation from low-bit rounding.
At group16:

| scale format | total output RMSE | quantization-only RMSE | scale-only RMSE | metadata B/vector |
|---|---:|---:|---:|---:|
| FP32 | 13.130% | 13.130% | 0.000% | 16 |
| FP16 | 13.129% | 13.130% | 0.045% | 8 |
| Q8.8 | 13.165% | 13.130% | 0.618% | 8 |

The non-linear errors do not add algebraically. Q8.8 changes total mean error
by only 0.035 percentage point versus ideal scale, supporting the hypothesis
that INT4 scale granularity dominates scale representation. Q8.8 is not a
universal scale format: its `2^-8` step was too coarse for typical INT8 absmax
scales, which is why the cross-bit sweep uses FP16.

### Optional Hadamard preconditioning

The sweep uses orthonormal Sylvester transforms applied in contiguous blocks to
Q, K, and V, with the inverse applied to the attention output. QK is invariant
before quantization. Estimated cost is `32*log2(block)` butterflies or
`64*log2(block)` add/sub outputs per 64-element transform; routing, registers,
bit growth, Fmax, and write-side/inverse-transform costs are not synthesized.

| transform | group64 output RMSE | group16 output RMSE | add/sub outputs/vector |
|---|---:|---:|---:|
| none | 18.965% | 13.165% | 0 |
| H4 | 16.558% | 12.491% | 128 |
| H8 | 15.336% | 11.730% | 192 |
| H16 | 14.861% | 11.635% | 256 |
| H32 | 15.249% | 11.365% | 320 |
| H64 | 14.369% | 11.724% | 384 |

Hadamard is distribution-sensitive. At group64 H4 is neutral on Gaussian data
and worsens the sparse-outlier case (15.85% to 16.69%), while larger blocks
help Laplace, Student-t, and 1% x10 outliers. It offers numerical/hardware
trade-off points but no cost-free dominance over finer scales. It remains out
of the baseline until real tensors and synthesized cost show a clear benefit.

### Dither interface

`sim/verify/kv_quant_reference.py` accepts an optional deterministic dither
provider with tensor shape/name, bit width, group size, and caller metadata.
Offsets are expressed in conventional quantizer-LSB units before rounding.
No IID, LFSR, CRC, keyed CRC, or mixed-CRC generator is selected, and no RTL is
added. The exact historical `G_B` mapping and its dither insertion rule remain
TODO because they are not recoverable from the handoff.

## Analytical storage and layout estimates

### Compression including metadata

These are equal-dimension comparisons at `HEAD_DIM=64` unless explicitly
stated otherwise. The equal-dimension existing bit-sliced INT8 layout is
modeled as two physical bytes/value, matching the current 256-byte record at
dimension 128.

| INT4 scales | total B/vector | effective bits/value | vs FP16 row-major | vs INT8 row-major | vs equal-dim bit-sliced INT8 |
|---|---:|---:|---:|---:|---:|
| group64 | 34 | 4.25 | 3.765x | 1.882x | 3.765x |
| group32 | 36 | 4.50 | 3.556x | 1.778x | 3.556x |
| group16 | 40 | 5.00 | 3.200x | 1.600x | 3.200x |
| group8 | 48 | 6.00 | 2.667x | 1.333x | 2.667x |

At equal dimension 128, payload-only row-major INT4 is 64 bytes and therefore
4x smaller than the current 256-byte physical record. A per-token 16-bit scale
makes it 66 bytes and 3.879x smaller. Comparing the target dimension-64
32-byte payload directly with that dimension-128 record gives 8x, but that is
a **dimension-changing capacity comparison, never an equal-dimension
compression ratio**.

### Recommended separate planes

For the recommended group16 candidate:

```text
K_DATA_BASE + (token << 5):  32-byte packed INT4 K
K_SCALE_BASE + (token << 3): four 16-bit Q8.8 scales
```

Group64 remains a parameterized evaluation mode with
`K_SCALE_BASE + (token << 1)`. Separate planes and a perfectly streamed
interleaved layout transfer the same useful 34 or 40 bytes/token. The separate
layout is preferred because:

- K remains 32-byte aligned and the address hot path remains `token << 5`;
- scale bursts can run independently ahead of K consumption;
- a 128-bit beat holds eight scales (two group16 token records), while a
  256-bit beat holds sixteen scales (four group16 token records);
- K and scale FIFO depths can be tuned independently;
- an interleaved 34-byte record needs multiply/add address generation and
  loses K alignment. Token-at-a-time reads transfer 48 bytes on 128-bit AXI
  and 64 bytes on 256-bit AXI; independent scale prefetch restores the
  separate-plane path to the useful 34 bytes/token.

No meaningful long-burst bandwidth disadvantage was found for either layout;
the recommendation is driven by alignment, independent prefetch, and simpler
control.

## Measured/simulated RTL results

The following are deterministic Icarus simulations of the unchanged v0.1 RTL
with randomized AXI address/data stalls. The state counters sum exactly to
`PERF_CYCLES`.

| AXI | context | total cycles | latency at 81.25 MHz | cycles/key | MAC utilization | effective K BW |
|---:|---:|---:|---:|---:|---:|---:|
| 128 | 512 | 7,379 | 90.82 us | 14.41 | 27.75% | 180.4 MB/s |
| 128 | 4096 | 59,256 | 729.30 us | 14.47 | 27.65% | 179.7 MB/s |
| 256 | 512 | 6,620 | 81.48 us | 12.93 | 30.94% | 201.1 MB/s |
| 256 | 4096 | 53,252 | 655.41 us | 13.00 | 30.77% | 200.0 MB/s |

Cycle accounting:

| AXI/context | issue | reader launch | AXI AR | R empty | R transfer | beat handoff | MAC | result/control |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 128/512 | 512 | 1,024 | 1,022 | 1,124 | 625 | 512 | 2,048 | 512 |
| 128/4096 | 4,096 | 8,192 | 8,203 | 9,101 | 5,088 | 4,096 | 16,384 | 4,096 |
| 256/512 | 512 | 1,024 | 990 | 1,022 | 512 | 0 | 2,048 | 512 |
| 256/4096 | 4,096 | 8,192 | 8,198 | 8,190 | 4,096 | 0 | 16,384 | 4,096 |

The 256-bit bus saves only 10.1-11.5% cycles. Per-token transaction/control
bubbles, not payload width, dominate.

## Analytical performance estimates

The option estimates below are not independently additive. A deeper FIFO by
itself conservatively removes only beat-handoff bubbles; long bursts need FIFO
capacity, and double buffering needs independent reader/MAC scheduling. Scale
prefetch does not speed up v0.1 because v0.1 has no scale traffic—it prevents
the v0.2 scale plane from adding visible steady-state cycles.

| option | cycles at 512 | cycles at 4096 | 512 speedup vs current 128 | basis |
|---|---:|---:|---:|---|
| current 128 measured | 7,379 | 59,256 | 1.00x | randomized-stall RTL simulation |
| A: 256-bit bus | 6,620 | 53,252 | 1.11x | measured parameterized RTL |
| B: deeper K FIFO | 6,867 | 55,160 | 1.07x | remove explicit handoff bubbles only |
| C: scale FIFO/prefetch | 7,379 | 59,256 | 1.00x | hide new scale traffic behind K/MAC |
| D: 16-vector AXI bursts | 4,981 | 40,046 | 1.48x | amortize issue/launch/AR; no overlap |
| E: double buffering | 5,331 | 42,872 | 1.38x | overlap current memory and MAC paths |
| F: continuous MAC schedule | 6,867 | 55,160 | 1.07x | remove one result bubble/token |
| B+C+D+E+F target | 2,120 | 16,904 | 3.48x | analytical combined target, 96-97% utilization |

The combined target is optimistic until implemented and tested. It establishes
the priority: burst/FIFO/double-buffer scheduling before more lanes or a wider
Arty port.

## Amdahl-style system budget

Current numbers come from `docs/runs/op-bench-fused.txt`. Proposed QK is the
v0.1 128-bit randomized-stall result. Streaming softmax and AV values are
analytical targets; paging/no-flush and fabric-normalizer values already exist
as repository measurements.

| component | current ms/token | current fraction | roadmap value | next action |
|---|---:|---:|---:|---|
| QK logits | 573.9 | 12.05% | 40.7 measured/simulated | burst K, K/scale FIFOs, double buffer |
| softmax | 617.4 | 12.96% | 20.0 analytical | streaming max/exp/sum/normalize |
| attention-weighted V | 1,035.0 | 21.73% | 50.8 analytical | INT4 V streamer + 16-lane AV MAC |
| paging/cache movement | 645.7 | 13.56% | 352.2 measured | persistent/no-flush CDMA path |
| normalization/quantization | 505.4 | 10.61% | 21.4 measured | use existing fabric normalizer |
| QK-norm/RoPE/quantize | 401.8 | 8.44% | unchanged | preserve per-token scales; reprofile later |
| MLP activation | 368.5 | 7.74% | unchanged | reprofile after attention/paging |
| ternary projections | 345.9 | 7.26% | unchanged | improve page reuse before more lanes |
| KV write/bit-slice | 268.7 | 5.64% | unchanged | row-major INT4 write quantizer later |

| scenario | estimated ms/token | speedup | status |
|---|---:|---:|---|
| current | 4,762.4 | 1.00x | measured operator budget |
| QK only | 4,229.2 | 1.13x | QK simulated |
| QK + quantized V storage | 3,548.4 | 1.34x | V bandwidth analytical, target dim64 |
| equal-dim128 V sensitivity | 3,646.5 | 1.31x | uses 256/66, not dimension-changing 256/34 |
| QK + V accumulation | 3,245.0 | 1.47x | AV analytical |
| full attention path | 2,647.6 | 1.80x | softmax and AV analytical |
| full attention + known system fixes | 1,870.1 | 2.55x | adds measured NQF/no-flush estimates |

After the QK burst/FIFO revision, the next distinct RTL block should be V
streaming/attention-weighted V accumulation, not another QK width increase.
It attacks the largest current component and reuses the same INT4 payload,
scale-plane, FIFO, and 16-lane scheduling concepts.

## Recommended v0.2 architecture (not yet RTL)

```text
AXI K reader ----> burst K FIFO -----------\
                                             -> raw INT8xINT4 P=16 MAC
scale reader ---> token scale FIFO --------/      -> group-scale accumulate
```

1. Keep `HEAD_DIM=64`, `P=16`, and first-class 128-bit AXI; retain 256-bit as a
   parameter.
2. Use separate data/scale planes. Parameterize group64 and group16, with
   group16 as the current synthetic Pareto knee.
3. Accumulate raw `INT8*INT4` within a scale group, then apply one scale to the
   partial sum. For group16 this is exactly one partial and scale per MAC cycle.
   This is algebraically equivalent to per-lane dequantization and avoids the
   current two multiplier layers per lane.
4. Issue multi-vector bursts (initial estimate: 16 vectors), prefetch scale
   bursts independently, and double-buffer FIFO/MAC consumption.
5. Keep Hadamard and deterministic dither optional and disabled by default.
6. After QK utilization is verified, reuse the readers/FIFOs for V/AV.

Before v0.2 RTL is accepted, regress every required length with randomized
back-pressure and explicitly test scale/data synchronization, scale-FIFO
underflow, AXI stalls, final burst boundaries, reset, invalid lengths, bounded
timeouts, and a short transaction immediately after 4096.

## Unverified hypotheses and required real data

- Group16 must be checked on captured Q/K/V tensors from the intended ternary
  student; synthetic RMSE does not predict perplexity or task accuracy.
- Attention masks, RoPE/QK-normalized statistics, inter-head variation, and
  real token correlation are absent from the synthetic generator.
- Per-layer/per-head fixed-point scale range must be profiled; Q8.8 resolution
  is adequate for this INT4 synthetic sweep but may clip or under-resolve real
  layers.
- Hadamard benefit is distribution-dependent and its LUT/FF/routing/Fmax cost
  is unsynthesized.
- Cycle-option estimates assume burst acceptance and sufficient MIG service;
  only v0.1 totals are RTL simulated, and no Vivado utilization/Fmax report is
  available in the current environment.
- V/softmax/Amdahl targets are architectural estimates, not end-to-end board
  measurements.
