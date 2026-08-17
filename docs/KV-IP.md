# INT4/PACKED5 KV-cache IP v0.2 contract and v0.3 development

The v0.2 sections of this document are the normative implementation contract
for the packaged KV-cache QK sidecar. The v0.3 sections record isolated codec,
softmax, and AV development and do not silently extend the packaged ABI.
Historical v0.1 material and superseded group32/Q8.8
recommendations are not part of this contract; see
[KV-IP-v0.1-ARCHIVE.md](KV-IP-v0.1-ARCHIVE.md).

The IP is a read-only K-path accelerator. It reads row-major INT4 K vectors,
computes an INT8-by-INT4 dot product with 16 lanes, applies one unsigned UQ5.11
K scale per configured group, and stores signed 32-bit scaled logits. It does
not yet implement the physical scale-plane reader, Q-scale application,
softmax, V streaming, attention-weighted V accumulation, or write-side
quantization.

## Evidence labels and normative language

Results in this document use four labels:

- **MEASURED/SIMULATED**: produced by the checked-in Python reference, Icarus
  regression, or Vivado report identified beside the claim.
- **ANALYTICAL**: derived storage, throughput, or Amdahl estimates.
- **SYNTHETIC**: fixed-seed tensor-distribution experiments; never model
  accuracy or perplexity claims.
- **UNVERIFIED**: a hypothesis or proposed block that still needs real tensors,
  RTL, routed implementation, or board measurement.

`Must` and `shall` define the current ABI. `Proposed` and `candidate` do not.

## Release identity and supported configuration

| Item | v0.2 contract |
|---|---|
| AXI-Lite core ID | `0x4B56_0002` (`"KV"`, ABI v2) |
| Packaged IP version | `2.0` |
| FPGA target used for OOC evidence | `xc7a100tcsg324-1` |
| Primary/default actual-model geometry | `HEAD_DIM=128` |
| Smoke/portable geometry | `HEAD_DIM=64` |
| Q data | signed INT8 |
| K data | signed two's-complement INT4, row-major |
| K canonical range | `-7..+7`; nibble `0x8` is invalid |
| MAC width | fixed `P=16` |
| K scale | unsigned UQ5.11, 16 bits |
| Scale group | fixed per vector in packaged wrapper (`GROUP_SIZE=HEAD_DIM`) |
| Result | signed 32-bit K-scaled integer dot product |
| Context | runtime `1..4096` |
| AXI data ports verified | 128 and 256 bits |
| Arithmetic mapping | `MULT_STYLE=2` (`AUTO`) |

The packaged AXI reader is deliberately K4/P16-only. The standalone
`qk_group_dot` arithmetic core is verified for K4 and K5, but K5 is not a legal
cache-engine or packaged-IP format because no 5-bit packer/reader exists yet.

## Implementation boundary

| Component | Status | Evidence/constraint |
|---|---|---|
| INT4 row-major K AXI reader | Implemented | 128/256-bit Icarus and Vivado OOC |
| P16 raw INT8×INT4 reduction | Implemented | actual-model golden, K4 |
| Group-scale UQ5.11 multiply | Implemented | one DSP in AUTO baseline |
| Reserved `0x8` detection | Implemented | error `0x30` |
| Conservative scale overflow guard | Implemented | error `0x03` before AXI traffic |
| AXI-Lite Q/config/logit windows | Implemented | ABI-v2 wrapper test |
| Physical K scale plane reader/FIFO | Not implemented | compatibility scalar is replicated |
| Q UQ1.15 scale and `1/sqrt(HEAD_DIM)` | Not implemented | host/post-stage responsibility |
| Four-row Q8.8 score BRAM | Isolated v0.3 RTL | 8 RAMB36, Icarus and routed OOC |
| Softmax | Isolated v0.3 RTL | bit-exact Icarus and routed OOC; not integrated |
| V5 AV integer numerator | Isolated v0.3 RTL | banked P16 real/adversarial golden |
| V AXI reader and final AV normalization | Not implemented | recommended next distinct block |
| PACKED5 compressed K/V decoder | Isolated v0.3 RTL | 4x1 baseline; page scheduler pending |
| Hadamard | Excluded from baseline | no clear hardware Pareto justification |
| Deterministic dither | Interface research only | exact mapping remains TODO |

## Numeric contract

### Q and K codes

Q values are signed INT8. K values are signed two's-complement nibbles packed
LSB-first. Byte bits `[3:0]` hold the lower dimension and `[7:4]` the next
dimension. The legal K range is `-7..+7`; `0x8` is reserved and terminates the
transaction with error `0x30`.

The software quantizer computes symmetric codes from a high-precision absmax
scale. The scale written to hardware is the independently rounded unsigned
UQ5.11 value. This policy matched the rounded-code alternative within the
measured noise while keeping the producer contract straightforward.

### K scale

UQ5.11 encodes:

```text
real_k_scale = scale_code / 2048
```

`0x0800` is 1.0 and is the reset value of `CFG`. `CFG` is unsigned and reads
back zero-extended. The current wrapper owns one compatibility scalar and
replicates it to all configured groups. This is not the final memory ABI.

### QK result

For group `g`:

```text
raw_g       = sum(q_code[i] * k_code[i])
scaled_g    = raw_g * k_scale_code[g]
result_code = sum(scaled_g)
```

`result_code` retains 11 fractional scale bits inherited from UQ5.11. The
wrapper does not apply the per-query UQ1.15 scale or `1/sqrt(HEAD_DIM)`.
Physical scores for a later softmax stage therefore require:

```text
score = result_code * q_scale / (2048 * sqrt(HEAD_DIM))
```

Rounding, clipping, and conversion to the proposed signed Q8.8 score format
are not frozen and must not be inferred from this compatibility result window.

### 32-bit overflow guard

The compatibility result is signed 32-bit. Before issuing AXI traffic, the
engine rejects any group scale larger than:

```text
floor((2^31 - 1) / (HEAD_DIM * 128 * 7))
```

| `HEAD_DIM` | Maximum accepted code | Maximum accepted UQ5.11 value |
|---:|---:|---:|
| 64 | 37,449 | 18.2856 |
| 128 | 18,724 | 9.1426 |

The bound is conservative and guarantees no wrap for any legal INT8/INT4
vector. The largest K scale in the ten-capture real-model audit was 6.429, well
inside the head128 limit. A larger scale requires a wider result design, not
silent truncation.

## Current K memory ABI

The current reader receives `K_BASE` already specialized for one layer and one
KV head. Vector sizes and addresses are:

| `HEAD_DIM` | K payload | Required alignment | Address |
|---:|---:|---:|---|
| 64 | 32 bytes | 32 bytes | `K_BASE + (token << 5)` |
| 128 | 64 bytes | 64 bytes | `K_BASE + (token << 6)` |

Every AXI burst reads exactly one vector. This per-vector transaction model is
correct but is not the utilization target for the next reader.

### Proposed separate-plane system ABI

The next memory revision shall keep payload and metadata separate. For the
actual-model K4/head128 profile:

```text
K_DATA_ADDR  = K_DATA_BASE
             + ((token * N_KV_HEADS + kv_head) << 6)

K_SCALE_ADDR = K_SCALE_BASE
             + ((token * N_KV_HEADS + kv_head) << 1)
```

The data stride remains 64 bytes and the single UQ5.11 scale record is 2 bytes.
A 128-bit AXI beat carries eight scales; a 256-bit beat carries sixteen.
Independent scale bursts preserve simple payload addressing and allow scale
prefetch. Interleaved 66-byte K records are not recommended.

V shall use independent data and scale planes. The `REGULAR4` V4 payload is 64
bytes plus 16 metadata bytes for group16. `PACKED5`/`ACCURATE5` V5 payload is
80 bytes plus one 2-byte group128 scale. The 80-byte V5 stream is not an
implemented or synthesized hardware format.

## AXI behavior

The M_AXI interface is read-only, INCR burst, one K vector per burst. The
reader tolerates independent address/data back-pressure and validates RRESP
and RLAST. `TIMEOUT_CYCLES` bounds address and data waits; a timeout is an
error, never a successful completion shortcut.

The AXI-Lite slave accepts AW and W independently, commits only after both are
captured, and holds BVALID/RVALID until accepted. All control and data ports
share `clk`; reset is active-low `rst_n`.

## AXI-Lite register map

The Arty integration reserves a 64-KiB aperture, historically based at
`0x4450_0000`. Offsets below are relative to the IP base.

| Offset | Name | Access | ABI-v2 meaning |
|---:|---|---|---|
| `0x0000` | `CTRL` | RW | write bit0 start, bit1 clear sticky status; read bit31 done, bit2 error, bit1 busy |
| `0x0004` | `STATUS` | RO | bit0 busy, bit1 done, bit2 error |
| `0x0008` | `K_BASE_LO` | RW | K payload base low word |
| `0x000C` | `K_BASE_HI` | RW | K payload base high word; must be zero with 32-bit M_AXI |
| `0x001C` | `CONTEXT_LEN` | RW | runtime length, legal `1..4096` |
| `0x0020` | `TOKEN_POS` | RW | reserved metadata; no dither behavior |
| `0x0024` | `CFG` | RW | low 16 bits: unsigned UQ5.11 compatibility K scale |
| `0x0028` | `PERF_CYCLES` | RO | busy cycles for current/last run |
| `0x002C` | `ERROR` | RO | error code in bits `[7:0]` |
| `0x0030` | `ID` | RO | `0x4B56_0002` |
| `0x0034` | `GEOMETRY` | RO | `[31:24]` AXI width, `[23:16]` head dim, `[15:8]` lanes, `[7:0]` K bits |
| `0x0100...` | `Q` | RW | `HEAD_DIM` signed INT8 values, four per aligned word |
| `0x1000..0x4FFF` | `LOGITS` | RO | 4096 signed 32-bit UQ5.11-scaled results |

The planned scale-plane base/configuration registers are not allocated in ABI
v2. They must be added without reinterpreting existing offsets.

## Error codes

| Code | Meaning | AXI traffic issued? |
|---:|---|---|
| `0x01` | context is zero or exceeds `MAX_CONTEXT` | No |
| `0x02` | K base is not vector-aligned | No |
| `0x03` | UQ5.11 scale can overflow the signed 32-bit result | No |
| `0x04` | K address is not representable or the context would wrap M_AXI | No |
| `0x05` | restart requested while an aborted AXI read is draining | Outstanding read only |
| `0x11` | AXI address timeout | Attempted |
| `0x12` | AXI read-data timeout | Attempted |
| `0x13` | non-OKAY RRESP | Yes |
| `0x14` | malformed RLAST | Yes |
| `0x30` | reserved INT4 code `0x8` encountered | Yes |
| `0x80` | start requested while busy | Existing run continues |

Errors and done are sticky in the wrapper until CTRL bit1 is written or a new
accepted start clears them. The engine-level outputs pulse for one cycle.

## Programming sequence

1. Verify `ID == 0x4B56_0002` and inspect `GEOMETRY`.
2. Write the aligned row-major K payload base and ensure the final context
   vector remains representable on the configured M_AXI address width.
3. Write `CONTEXT_LEN` in `1..4096`.
4. Write `HEAD_DIM` Q bytes through the Q window.
5. Write the unsigned UQ5.11 K scale to `CFG`.
6. Write CTRL bit0.
7. Poll STATUS until done or error. A software timeout must fail the call.
8. On error, read `ERROR`; on success, read `CONTEXT_LEN` logit words.
9. Apply Q scale and `1/sqrt(HEAD_DIM)` in software or a later hardware stage.

## RTL datapath and scheduling

```text
AXI K reader -> one-vector beat buffer -> INT4 unpack -> P16 raw products
                                                       |
                                                       v
registered 16-lane reduction -> raw group accumulator -> UQ5.11 scale DSP
                                                       |
                                                       v
                                             signed 32-bit logit RAM
```

`qk_group_dot` registers the raw 16-lane reduction before group accumulation
and applies exactly one scale multiplication at each group boundary. AUTO is
the baseline mapping. The v0.2 cycle baseline serialized read, handoff, MAC,
and result phases; the v0.3 utilization revision below overlaps the result
drain with the next vector read.

### v0.3 registered-tree utilization revision

The current development branch registers selected Q/K lanes, products, and
each balanced reduction level. AUTO and SHIFT_ADD are bit-identical against the
same 128-token real-model K4 and K5 golden vectors. The vector controller also
issues the next AXI read while the previous tree drains, so the deeper timing
pipeline does not impose a per-key result-wait bubble.

The overlap required two explicit recovery rules. An accepted AXI burst is
drained rather than cancelled after a late reserved-code fault, and the QK
pipeline is flushed before a new job. Both an active-drain restart rejection
and a clean short transaction after the fault are regression-tested.

| Head dim | AXI | Keys | Previous cycles | Revised cycles | Reduction |
|---:|---:|---:|---:|---:|---:|
| 64 | 128 | 512 | 8,446 | 6,863 | 18.7% |
| 64 | 128 | 4,096 | 67,832 | 55,249 | 18.6% |
| 64 | 256 | 512 | 7,631 | 6,131 | 19.7% |
| 64 | 256 | 4,096 | 61,445 | 49,231 | 19.9% |
| 128 | 128 | 512 | 11,826 | 10,306 | 12.9% |
| 128 | 128 | 4,096 | 94,912 | 82,483 | 13.1% |
| 128 | 256 | 512 | 10,323 | 8,702 | 15.7% |
| 128 | 256 | 4,096 | 82,489 | 70,102 | 15.0% |

Evidence: `RTL-SIMULATED/Icarus-v0.3-overlap`. The isolated QK arithmetic block
subsequently closed routed OOC timing at 81.25 MHz, but the rates in this table
still project that clock onto RTL-simulated cycles. The compressed page
scheduler, decoder cluster, and scale prefetch are not part of these cycle
measurements.

## Parameters and legal combinations

The packaged top exposes only parameters that have a defined v0.2 behavior:

| Parameter | Verified/legal values | Constraint |
|---|---|---|
| `HEAD_DIM` | 64, 128 | multiple of 16; vector bytes must be power of two |
| `MAX_CONTEXT` | 4096 baseline | register/logit aperture assumes 4096 maximum |
| `MULT_STYLE` | 0 SHIFT_ADD, 1 DSP, 2 AUTO | AUTO baseline |
| `M_AXI_DATA_WIDTH` | 128, 256 | divides one K4 vector and contains whole P16 slices |
| `TIMEOUT_CYCLES` | positive integer | sized for platform worst-case stall |

K bits, P, result width, and packaged scale group are fixed internally to 4,
16, 32, and `HEAD_DIM`. This avoids advertising combinations that the physical
reader, scalar scale register, or result ABI cannot implement. The standalone
engine retains verified group-size parameters for research, and `qk_group_dot`
remains separately parameterized for the K5 comparison.

## Measured/simulated numerical results

Two independent context-128 prose prompts were streamed through all 30 layers
of the local `microsoft/bitnet-b1.58-2B-4T` checkpoint with Q/K/V injection at
every attention layer. A seven-token layer-0 comparison against pinned
Transformers remained bitwise equal. These are distortion measurements only.

| Profile | Bytes/token/KV-head | Mean final hidden relative RMSE | Mean last-token relative RMSE | Minimum last-token cosine | Mean KL |
|---|---:|---:|---:|---:|---:|
| Q8 only | -- | 3.741% | 3.543% | 0.999370 | 0.001349 |
| REGULAR4 | 146 | 8.417% | 9.790% | 0.995990 | 0.007953 |
| PACKED5 | 148 | 7.497% | 7.593% | 0.997509 | 0.002075 |
| ACCURATE5 | 164 | 6.307% | 5.136% | 0.998618 | 0.002215 |

PACKED5 is the leading software Pareto candidate, but that does not make V5 a
hardware baseline. The current QK wrapper implements the K4 portion shared by
REGULAR4 and PACKED5.

Across ten real captures at contexts 128/512 and layers 0/7/15/22/29, UQ5.11
scale-only output error was 0.0293%, 0.0325%, and 0.0728% mean for REGULAR4,
PACKED5, and ACCURATE5. No underflow or overflow occurred. Broader model
validation remains required.

## Analytical storage

Equal-dimension head128, combined K+V per token per KV head:

| Profile | Payload bytes | Metadata bytes | Total bytes | Effective bits/value | vs FP16 or existing 512-byte physical layout | vs INT8 256 bytes |
|---|---:|---:|---:|---:|---:|---:|
| REGULAR4 | 128 | 18 | 146 | 4.5625 | 3.507x | 1.753x |
| PACKED5 | 144 | 4 | 148 | 4.6250 | 3.459x | 1.730x |
| ACCURATE5 | 160 | 4 | 164 | 5.1250 | 3.122x | 1.561x |

At equal head128, one row-major INT4 payload vector is 64 bytes and exactly 4x
smaller than the existing 256-byte physical K or V vector before metadata. An
8x claim mixes head64 with head128 and is not an equal-dimension ratio.

## Synthetic numerical experiments

Fixed-seed software sweeps cover contexts 128/256/512/1024/2048/4096; INT8 Q;
FP/INT8/INT5/INT4/INT3 K/V; per-run, per-token, group32/group16/group8 scales;
FP32/FP16/Q8.8 representations; and Gaussian, Laplace, Student-t, sparse, and
approximately 1% x10-outlier distributions.

The synthetic conclusion is that scale granularity matters more than small
scale-representation changes, one scale per run is unsafe, and coarse groups
are vulnerable to outliers. The none/H4/H8/H16/H32/H64 sweep did not provide a
clear enough numerical/hardware Pareto improvement to require Hadamard.

The quantizer accepts optional deterministic dither input. No IID/LFSR/CRC/
keyed-CRC mapping is selected, and dither is not part of baseline operation.

## Cycle accounting and utilization

Deterministic Icarus accounting at head128/P16 and 81.25 MHz:

| AXI | Keys | Cycles | Cycles/key | Mkeys/s | K payload MB/s | P16 utilization |
|---:|---:|---:|---:|---:|---:|---:|
| 128 | 512 | 11,826 | 23.098 | 3.518 | 225.1 | 34.64% |
| 128 | 4096 | 94,912 | 23.172 | 3.506 | 224.4 | 34.52% |
| 256 | 512 | 10,323 | 20.162 | 4.030 | 257.9 | 39.68% |
| 256 | 4096 | 82,489 | 20.139 | 4.034 | 258.2 | 39.72% |

Doubling AXI width improves 4096-key rate by 15.1%, while utilization remains
below 40%. Optimize per-vector address/launch bubbles, R-empty cycles, beat
handoff, and result bookkeeping before adding MAC lanes.

## Vivado 2026.1 evidence

The standalone K4 AUTO core uses 840 LUT, 176 FF, and one DSP with +4.820 ns
WNS at 81.25 MHz. K5 AUTO uses 1,044 LUT, 178 FF, and one DSP. Forced-DSP uses
21 DSPs and is not the small baseline.

The newer isolated v0.3 blocks were synthesized and routed with the same part
and 81.25 MHz OOC target:

| Block/configuration | LUT | LUTRAM LUT | FF | BRAM tiles | DSP | Routed WNS | Status |
|---|---:|---:|---:|---:|---:|---:|---|
| decoder 2x2 | 1,672 | 0 | 280 | 0 | 0 | -9.138 ns | rejected |
| decoder 4x1 | 1,713 | 0 | 440 | 0 | 0 | +0.570 ns | baseline |
| QK K4 AUTO registered tree | 835 | 0 | 850 | 0 | 1 | +4.628 ns | closes |
| softmax engine | 438 | 0 | 359 | 8.5 | 1 | +1.609 ns | closes |
| V5 AV CSD | 7,113 | 512 | 689 | 0 | 1 | +1.221 ns | LUT-heavy, rejected |
| V5 AV forced DSP | 1,384 | 512 | 337 | 0 | 33 | +1.323 ns | LUT-saving option |
| V5 AV AUTO | 3,577 | 512 | 673 | 0 | 1 | +1.753 ns | default |

AUTO is the AV baseline because it has the largest routed margin while using
one DSP. Forced DSP saves 2,193 LUT but consumes 33 of 240 DSPs, so it remains
available for a LUT-limited parent design. CSD is not on the hardware Pareto
frontier. These are isolated OOC results: `HD.CLK_SRC` and parent
`HD.PARTPIN_LOCS` remain unset, and no board-frequency claim is made.

Current head128 wrapper OOC results after the ABI-v2 guard revision:

| AXI width | LUT (% device) | Logic LUT | LUTRAM LUT | FF (% device) | BRAM | DSP | WNS at 81.248 MHz | Status |
|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 128 | 8,783 (13.85%) | 5,967 | 2,816 | 1,829 (1.44%) | 0 | 1 | -0.175 ns | timing not closed |
| 256 | 8,601 (13.57%) | 5,785 | 2,816 | 2,085 (1.64%) | 0 | 1 | +0.105 ns | meets OOC target |

The 128-bit configuration therefore remains functionally first-class but does
not currently have a timing-closure claim. The critical OOC path is the
INT8×INT4 reduction from Q storage into the registered slice sum, not the AXI
port or scale guard. Retime that path and replace the asynchronous score array
with synchronous BRAM before treating 81.25 MHz as closed.

The warning audit found no critical warnings. Remaining synthesis warnings are
intentional: AXI-Lite BRESP/RRESP are constant OKAY, AWPROT/ARPROT are unused,
RID is ignored because the reader permits one outstanding constant-ID request,
and the OOC clock has no top-level `HD.CLK_SRC`. The XDC period is rounded from
12.307692 ns to Vivado's 1-ps resolution. Any new warning class requires review.

Full-wrapper post-audit OOC numbers are refreshed after every RTL contract
change and stored in
`analysis/kv_validation/hardware_estimates/vivado_wrapper_v0_2_auto/`.
Post-synthesis OOC timing is not routed implementation timing or board DDR
throughput.

## Amdahl planning estimate

The 4.7624 s/token system budget is mixed-source planning data, not one
end-to-end timing run.

| Scenario | Estimated ms/token | Estimated speedup |
|---|---:|---:|
| Current | 4,762.4 | 1.00x |
| QK only | 4,229.2 | 1.13x |
| QK + quantized V storage | 3,548.4 | 1.34x |
| QK + V accumulation | 3,245.0 | 1.47x |
| Full attention path | 2,647.6 | 1.80x |
| Full attention + known system fixes | 1,870.1 | 2.55x |

Attention-weighted V is the largest current attention component. The next
distinct block should therefore be V streaming/AV accumulation while QK work
focuses on utilization.

## v0.3 isolated decoder, softmax, and AV RTL

The baseline decoder is now an isolated 4x1 cluster: four independent
whole-page tasks, one symbol/cycle per task, and four aggregate symbols/cycle.
The engines select K4 or V5 at task start, so compressed and raw K/V pages can
be assigned without splitting a prefix stream. Concurrent compressed/raw K/V,
random back-pressure, and per-lane integrity-fault isolation pass Icarus. The
original 2x2/two-symbol cluster remains regression-tested but is rejected for
implementation because its dependent second prefix lookup has routed WNS
-9.138 ns at 81.25 MHz. The final 4x1 cluster has +0.570 ns routed OOC WNS.

The isolated softmax baseline implements four synchronous 4096x16 signed Q8.8
score rows, max/subtract, the frozen 128-entry UQ1.15 exponent table, strict
zero below -12, a 28-bit denominator, and an iterative normalized F12
reciprocal. It is bit-exact against 87 reciprocal cases plus these score rows:

| Case | Keys | Denominator | Underflows | Simulated cycles |
|---|---:|---:|---:|---:|
| uniform maximum | 4,096 | 134,217,728 | 0 | 37,889 |
| single sink | 65 | 32,768 | 64 | 638 |
| LUT boundary | 129 | 398,929 | 0 | 1,240 |
| real Gate A row | 128 | 34,008 | 83 | 1,229 |

Evidence: `RTL-SIMULATED/Icarus-v0.3-softmax`. Cycles include deterministic
random output back-pressure and the current conservative two-pass/single-read
controller. They are not a synthesized throughput claim. Missing score-memory
responses raise a timeout error; a timeout never ends the test successfully.

The isolated AV numerator block now maintains four heads × 128 dimensions in
sixteen signed 48-bit banks and accepts one P16 `(exp × V-scale × V5)` update
per cycle. AUTO, forced DSP, and explicit CSD multiplication are bit-identical for a real
context-128 layer-0 capture, a seven-token adversarial case, and 279 exhaustive
legal-code/boundary-weight multiplier cases. Schedule mismatch, reserved -16,
and zero scale have distinct fault paths. Legal accumulator magnitude is below
`2^44`; the 48-bit signed banks have three guard bits beyond the minimum, so an
unreachable runtime overflow reduction is deliberately not synthesized.

This AV evidence stops at the integer numerator. The handoff specifies a
signed 64-bit numerator-times-reciprocal intermediate but does not freeze the
final output code width, rounding, or saturation. Those details remain an ABI
TODO and were not invented for the RTL test.

## Verification requirements

Required lengths:

```text
1, 7, 63, 64, 65,
127, 128, 129,
511, 512, 513,
1023, 1024, 1025,
4095, 4096
```

Every RTL change must pass:

- K4 and K5 standalone actual-model golden vectors;
- 128/256-bit, head64/head128 boundary regressions;
- randomized AXI address/read-data back-pressure;
- a short transaction immediately after the maximum transaction;
- invalid length, unaligned/high/wrapping base, unsafe scale, reserved nibble,
  RRESP, RLAST, address timeout, and data timeout behavior;
- AXI-Lite split AW/W, status, ID, geometry, CFG reset/readback, Q window, and
  logit window checks;
- Python numerical/analysis artifact verification;
- Icarus before Vivado.

Windows:

```powershell
cd sim
.\run_windows_regression.ps1
```

Linux/WSL:

```sh
cd sim
make all
make verify
```

Vivado OOC wrapper comparison:

```powershell
vivado -mode batch `
  -source analysis/kv_validation/scripts/run_vivado_ooc_synth.tcl `
  -tclargs F:/Xilinx_WorkSpace/ternarycore <output-directory>
```

Packaging, only after simulation passes:

```powershell
vivado -mode batch -source ip/package_axi_kv_cache.tcl
```

The Vivado 2026.1 IP-XACT integrity check passes. The saved component is version
2.0, defaults to head128, exposes no unsupported scale-group parameter, and
declares `FREQ_HZ=81250000`. `package_project` emits advisory warnings before
the script applies final metadata (temporary v1 name/description and missing
clock frequency) plus a missing embedded Product Guide warning. This Markdown
file is the maintained external product guide; those import-time advisories do
not indicate an integrity failure.

## Next implementation order

1. Add separate K/V scale readers, FIFOs, prefetch, and explicit data/scale
   synchronization and underflow tests.
2. Build the AXI128 page scheduler with long bursts, CRC-gated ping-pong page
   buffers, offsets, typed faults, and starvation/utilization counters.
3. Add the V5 AXI streamer and connect it to the verified banked AV numerator.
4. Integrate score/softmax/AV row ownership and page commit/abort semantics,
   then freeze normalized AV output rounding and saturation.
5. Optimize the correctness-first softmax reader toward one score/cycle only
   after the integrated page/V path exposes measured starvation counters.

## Unverified hypotheses and known limitations

- Eight context-128 prompts plus two context-512 cases do not establish
  accuracy, perplexity, generation quality, or long-context behavior.
- UQ5.11 did not saturate in ten captures; other models or activation outliers
  may need more range.
- PACKED5 is software-Pareto and its isolated V5 decoder/AV numerator are
  synthesized, but its AXI V reader and normalized AV output are not built.
- OOC timing is not placed-and-routed Arty timing, power, or board throughput.
- The head128/128-bit wrapper currently misses the 81.248 MHz OOC target by
  0.175 ns; timing closure is an explicit next-revision requirement.
- The compatibility scalar is not evidence that scale-plane synchronization is
  solved.
- The Q8.8 score/LUT/reciprocal/softmax path is bit-exact and routed in
  isolation, but is not integrated into the page/V system.
- Deterministic dither mapping remains deliberately undefined.

## Artifact index

- [v0.3 implementation report](../analysis/kv_validation/v0_3/reports/V0_3_IMPLEMENTATION_REPORT.md)
- [v0.3 Gate A real-model summary](../analysis/kv_validation/v0_3/results/gate_a/gate_a_summary.csv)
- [v0.3 current routed block summary](../analysis/kv_validation/hardware_estimates/vivado_v0_3_blocks_2026_1/summary.csv)
- [v0.3 retained architecture comparison](../analysis/kv_validation/hardware_estimates/vivado_v0_3_blocks_2026_1/variant_comparison.csv)
- [Authoritative audit report](../analysis/kv_validation/report/V0_2_AUDIT_ADDENDUM_REPORT.md)
- [Actual-model end-to-end summary](../analysis/kv_validation/real_model/end_to_end_injection/summary.csv)
- [K/V UQ5.11 contract sweep](../analysis/kv_validation/real_model/kv_scale_contract_sweep/summary.csv)
- [Q-scale sweep](../analysis/kv_validation/real_model/q_scale_format_sweep/summary.csv)
- [Actual-model QK golden manifest](../analysis/kv_validation/real_model/qk_profile_golden_v0_2/manifest.json)
- [QK-core Vivado summary](../analysis/kv_validation/hardware_estimates/vivado_qk_core_2026_1/summary.csv)
- [Wrapper cycle accounting](../analysis/kv_validation/hardware_estimates/vivado_wrapper_v0_2_auto/cycle_accounting.csv)
- [Wrapper resource/timing summary](../analysis/kv_validation/hardware_estimates/vivado_wrapper_v0_2_auto/resource_timing_summary.csv)
- [Hadamard Pareto table](../analysis/kv_validation/pareto/hadamard_pareto_head64.csv)
- [Imported audit addendum](../analysis/kv_validation/audit_addendum/kv_validation_audit_addendum/kv_validation_audit_addendum/AUDIT_ADDENDUM.md)

## ABI-v2 change log

- Replaced the legacy signed Q8.8 compatibility scale with unsigned UQ5.11.
- Corrected reset scale from legacy `0x0100` to UQ5.11 1.0 (`0x0800`).
- Zero-extended CFG readback and bumped core ID/IP version.
- Made head128 the packaged default; head64 remains a verified smoke profile.
- Removed unsupported K5 and non-P16 parameter exposure from the AXI reader.
- Removed scale-group exposure from the scalar-scale packaged wrapper; it is
  fixed per vector until the physical metadata plane exists.
- Fixed the standalone reduction tree at its structural 16-lane width instead
  of exposing a misleading lane parameter.
- Added conservative 32-bit scale overflow rejection (`0x03`).
- Added high-base and final-context address wrap rejection (`0x04`).
- Removed the native-width INT4 sign-extension synthesis warning and added
  full-engine reserved-code coverage.
- Kept K5 only in the separately verified arithmetic research core.
