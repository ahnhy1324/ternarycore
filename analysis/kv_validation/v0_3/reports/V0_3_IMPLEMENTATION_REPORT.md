# KV-cache v0.3 analysis and isolated-RTL implementation report

- Date: 2026-08-17
- Branch: `codex/kv-v0.3-todo`
- FPGA/tool: `xc7a100tcsg324-1`, Vivado 2026.1, 81.25 MHz OOC target

## Decision summary

- **MEASURED/REAL MODEL:** The Gate A matrix completed 30/30 runs: eight
  natural prompts at context 128 and two of those prompts at context 512. The
  memory-mapped reference executes the BitNet layer equations directly; it
  does not require the Transformers model runner. A separate seven-token
  layer-0 comparison against the pinned Transformers implementation was
  bitwise equal.
- **MEASURED/REAL MODEL:** PACKED5 UQ4.8 and UQ5.11 had mean final-hidden
  relative RMSE 0.073107 and 0.072898 respectively, top-1 preservation 1.0,
  and no scale underflow/overflow across these ten prompt/context cases. This
  is distortion evidence, not model accuracy or perplexity.
- **MEASURED/REAL MODEL:** Page128 averaged 129.262 full K+V bytes/token/KV
  head (4.039 effective bits/value), slightly better than page64 at 129.633
  bytes (4.051 bits/value). Page128 is retained.
- **SYNTHETIC:** Scale granularity dominates Q8.8 representation error. The
  synthetic group16 Q8.8 knee cuts mean attention-output relative RMSE from
  0.18965 at group64 to 0.13165 at 5.0 effective bits/value. These fixed-seed
  tensors are not model-quality claims.
- **SYNTHETIC/ANALYTICAL:** Hadamard can reduce some synthetic errors, but no
  tested H4--H64 point gives a sufficiently clear error/metadata/hardware
  improvement to make it mandatory. It remains outside the baseline.
- **RTL-SIMULATED / VIVADO-OOC:** The two-dependent-lookup 2x2 decoder is
  rejected. Four independent one-symbol lanes retain four aggregate
  symbols/cycle and close the 81.25 MHz isolated target.
- **RTL-SIMULATED / VIVADO-OOC:** The score memory now infers eight RAMB36
  blocks; the exact `/24` LUT address is implemented by a proven constant
  reciprocal multiply; QK, decoder, and softmax all close routed OOC timing.
- **RTL-SIMULATED:** The V5 AV numerator uses sixteen 32x48 distributed-RAM
  banks and passes real/adversarial goldens in CSD, forced-DSP, and AUTO modes.
  The final AV mapping decision is based on the routed comparison below.
- **RECOMMENDATION:** Build the AXI-128 page scheduler, separate K/V data and
  scale prefetch, and integrate V streaming/AV next. Do not spend the next
  revision on Hadamard, dither, a wider bus, or more MAC lanes.

## Evidence boundaries

| Label | Meaning in this report |
|---|---|
| MEASURED/REAL MODEL | Local BitNet checkpoint tensors or completed injected model runs |
| RTL-SIMULATED | Bit-exact Icarus simulation, including back-pressure/fault tests |
| VIVADO-OOC | Isolated synthesis plus place/route; not a complete Arty design or board test |
| SYNTHETIC | Fixed-seed generated distributions; never an accuracy/perplexity claim |
| ANALYTICAL | Storage, schedule, bandwidth, or Amdahl calculation |
| UNVERIFIED | Requires integrated RTL, a parent design, board measurement, or broader model data |

## Numerical/reference closure

### Reproducible synthetic baseline

The checked-in reference uses `HEAD_DIM=64`, contexts
128/256/512/1024/2048/4096, fixed seeds, INT8 Q, FP reference K/V, and
symmetric INT8/INT5/INT4/INT3 K/V quantization. It records normalized QK logit
RMSE, attention-output relative RMSE and cosine, bias/scale-only error, payload
bytes, and metadata bytes. Gaussian, Laplace, Student-t, sparse-outlier, and
approximately 1% x10-outlier families are explicit strata.

The complete rows are in `../synthetic/*.csv`; compact Pareto projections are
in `../pareto/*.csv`. Machine-readable JSON summaries preserve seeds, scope, and the
synthetic-evidence label.

### INT4 scale-granularity result at head64

The table uses the Q8.8 scale representation and averages 30 fixed-seed
distribution/context experiments.

| Scale group | Metadata bytes/K or V token | Effective bits/value | Mean normalized QK RMSE | Mean attention-output relative RMSE | Mean output cosine | Mean scale-only output RMSE |
|---:|---:|---:|---:|---:|---:|---:|
| run | amortized 0.0051 | 4.0006 | 0.27348 | 0.38432 | 0.92951 | 0.00242 |
| 64 / token | 2 | 4.25 | 0.14073 | 0.18965 | 0.98087 | 0.00607 |
| 32 | 4 | 4.50 | 0.11803 | 0.15886 | 0.98659 | 0.00591 |
| 16 | 8 | 5.00 | 0.09778 | 0.13165 | 0.99087 | 0.00618 |
| 8 | 16 | 6.00 | 0.07862 | 0.10576 | 0.99411 | 0.00672 |

Q8.8 scale-only error is small compared with INT4 error at every granularity.
The recommendation is not that group16 is universally accurate; it is the
synthetic error/storage knee. Real BitNet captures later favored asymmetric
K4/V5 group128, which is why synthetic and model evidence remain separate.

### Hadamard decision

The sweep covers none/H4/H8/H16/H32/H64 against groups 64/32/16/8 using the
same tensors and seeds. Several transformed rows reduce mean error, but every
transform adds 2--6 butterfly stages and 128--384 add/sub outputs per vector.
No transformed row was marked `recommended_for_baseline` in the generated
Pareto table. Hadamard is therefore optional research, not v0.3 baseline RTL.

### Deterministic dither readiness

The software quantizer accepts an optional dither input. No dither, IID,
LFSR, raw/keyed CRC, and token-mixed CRC can be compared without altering the
quantizer API. The exact `G_B`/dither mapping is still TODO because the handoff
does not define it. No dither generator was added to RTL.

## Storage and memory layout

At head64, an INT4 payload is 32 bytes/token. A 16-bit per-token scale gives
34 bytes (4.25 bits/value); group16 gives 40 bytes (5.0 bits/value); group8
gives 48 bytes (6.0 bits/value). At equal head128, the corresponding payload is
64 bytes and a per-token scale gives 66 bytes, 3.879x compression versus
row-major FP16 or the existing equal-dimension 256-byte bit-sliced record, and
1.939x versus row-major INT8. The historical 8x number changes dimension and
is not used as an equal-dimension ratio.

The v0.3 ABI keeps payload and metadata in separate planes:

```text
K_DATA_ADDR  = K_DATA_BASE  + vector_index * (HEAD_DIM / 2)
K_SCALE_ADDR = K_SCALE_BASE + vector_index * 2
```

Thus head64 retains `token << 5`, while head128 retains `token << 6`. A
128-bit beat carries eight 16-bit scales and a 256-bit beat carries sixteen.
For head128, interleaved 66-byte token records transfer 80 bytes/token with
tokenwise AXI-128 reads and 96 bytes/token with AXI-256; separate planes retain
66 bytes/token and allow independent burst/prefetch. No measured disadvantage
justifies interleaving.

## Real-model Gate A and fixed-point Gate B

Gate A covers eight unique natural-language prompts rather than one prompt.
The two context-512 prompts are `engineering` and `observatory`; all eight run
at context 128. The 30 runs comprise BASE_FP where required plus UQ5.11 and
UQ4.8 PACKED5 candidates.

| Profile | Prompt/context cases | Mean final hidden rel. RMSE | Worst | Minimum final cosine | Top-1 preservation | Scale faults |
|---|---:|---:|---:|---:|---:|---:|
| PACKED5 raw UQ5.11 | 10 | 0.072898 | 0.082296 | 0.996608 | 1.0 | 0 |
| PACKED5 raw/page UQ4.8 | 10 | 0.073107 | 0.083708 | 0.996490 | 1.0 | 0 |

Gate B fixed-point AV has mean relative RMSE 0.005347 and worst 0.026101
against the floating PACKED5 AV reference over 200 real rows. F12 and F14 have
the same 29/128 top-1 changes in the deliberately adversarial subset, so those
changes are not caused by reciprocal precision alone. The final AV output
width, rounding, and saturation remain an ABI decision; the RTL stops at the
bit-exact 48-bit integer numerator.

## RTL changes and bug audit

- The decoder has a `SYMBOLS_PER_CYCLE` parameter. Four independent one-symbol
  lanes replace the timing-failing 2x2/two-symbol organization while retaining
  four aggregate symbols/cycle.
- Compressed/raw completion and tail validation are registered. Only the legal
  zero-to-seven byte-padding bits participate in the tail reduction.
- The score store isolates four 4096x16 rows so Vivado infers eight RAMB36
  blocks instead of 5,632 LUTRAM bitslices.
- The softmax subtract, range-limit, exact reciprocal multiply, and LUT address
  are pipelined. For integer `n` in `[0,3084]`,
  `floor(n/24) == floor(n*2731/65536)`; Icarus remains bit-exact.
- A busy softmax start now aborts explicitly. An orphaned, non-cancellable
  reciprocal blocks restart until it becomes idle; old score responses cannot
  be mistaken for a new request.
- AV busy-start now aborts and clears live pipeline-valid bits, preventing a
  pending numerator update from being applied twice.
- Each AV lane is an explicit 32x48 distributed-RAM inference boundary. This
  replaces a three-dimensional array that synthesized as 24,576 registers.
- The legal AV magnitude is
  `(2^16-1)*(2^12-1)*15*4096 < 2^44`. A signed 48-bit accumulator therefore
  has three guard bits beyond the minimum. The unreachable runtime overflow
  detector was removed because its 16-lane reduction was a real global timing
  path; legal inputs cannot overflow.
- Input-ready, completion, reciprocal, and result waits in the v0.3 tests have
  finite limits. A timeout calls the test failure path; it never reports PASS.

### Softmax simulated cycles

Cycles include deterministic output back-pressure and the correctness-first
two-pass controller.

| Case | Keys | Denominator | Underflows | Cycles |
|---|---:|---:|---:|---:|
| uniform maximum | 4096 | 134,217,728 | 0 | 37,889 |
| single sink | 65 | 32,768 | 64 | 638 |
| LUT boundary | 129 | 398,929 | 0 | 1,240 |
| real Gate A row | 128 | 34,008 | 83 | 1,229 |

## Vivado 2026.1 routed OOC comparison

`PASS` from the Tcl flow means the tool completed. Timing closure is reported
separately and requires routed WNS >= 0. The Fmax column in the machine table
is calculated from WNS and is not a direct frequency measurement. OOC
`HD.CLK_SRC` and parent `HD.PARTPIN_LOCS` are unset, so the results do not close
top-level clock skew or interface placement.

The completed runs report zero critical warnings, zero synthesis/route errors,
and zero routing-error nets. Reviewed warnings are the rounded 12.307692 ns XDC
period, constant unused upper error-code bits, OOC DRC/clock/partition-pin
advisories, and high-fanout distributed-RAM address/write-enable nets. The last
class is retained as an integration risk even where isolated timing closes.
Icarus `-Wall` is clean for softmax and AV; the decoder reports only the
expected combinational sensitivity to all 256 entries of each static lookup
table.

The authoritative current and retained-revision tables are:

- `../hardware_estimates/vivado_v0_3_blocks_2026_1/summary.csv`
- `../hardware_estimates/vivado_v0_3_blocks_2026_1/variant_comparison.csv`

| Isolated configuration | LUT | LUTRAM LUT | FF | BRAM tiles | DSP | Routed WNS | Decision |
|---|---:|---:|---:|---:|---:|---:|---|
| decoder 2x2 | 1,672 | 0 | 280 | 0 | 0 | -9.138 ns | reject |
| decoder 4x1 | 1,713 | 0 | 440 | 0 | 0 | +0.570 ns | decoder baseline |
| QK K4 AUTO | 835 | 0 | 850 | 0 | 1 | +4.628 ns | closes |
| softmax engine | 438 | 0 | 359 | 8.5 | 1 | +1.609 ns | correctness baseline |
| AV V5 CSD | 7,113 | 512 | 689 | 0 | 1 | +1.221 ns | reject on LUT cost |
| AV V5 forced DSP | 1,384 | 512 | 337 | 0 | 33 | +1.323 ns | LUT-saving option |
| AV V5 AUTO | 3,577 | 512 | 673 | 0 | 1 | +1.753 ns | default baseline |

The score-array inference failure used 7,554 LUT, including 5,632 LUTRAM, and
had post-synthesis WNS -7.793 ns. Isolating the BRAM rows plus an inferred
divide-by-24 reduced area but still routed at -0.901 ns. The final exact
constant-multiply form uses one DSP and routes at +1.609 ns.

Removing the mathematically unreachable AV overflow reduction improved AUTO
WNS from +0.001 to +1.753 ns while reducing 63 LUT and one FF. Forced DSP
improved from +0.847 to +1.323 ns and saved 16 LUT/two FF. CSD improved timing
from +0.142 to +1.221 ns but the routed mapping grew by 992 LUT and 15 FF; this
tool-dependent tradeoff is preserved rather than hidden. AUTO has the best
timing margin with one DSP. Forced DSP saves 2,193 LUT versus AUTO but consumes
33/240 DSPs (13.75%), so it remains an explicit LUT-limited build option.

## Cycle accounting and architecture choice

For the revised head128/P16 QK engine at context 4096, AXI-128 takes 82,483
cycles and AXI-256 takes 70,102 cycles: a 15.0% improvement. MAC work remains
32,768 cycles in both. The dominant counted losses are per-vector reader launch
(8,192), AR waiting (8,075/8,053), R-empty cycles (10,513/8,551), transfer
(6,543/4,338), and 128-bit beat handoff (12,288 versus 4,096). The evidence
continues to favor long multi-vector bursts, K/scale FIFOs, and double
buffering before more lanes or a mandatory wider bus.

The theoretical page128/4x1 schedule produces four aggregate symbols/cycle and
matches the 4,096-cycle arithmetic page period after warm-up. Using measured
page bytes and prior AXI-128 bandwidth, K prefetch has 18.020 us margin and V
prefetch has 9.194 us margin per page. FIFO starvation and page overlap remain
unverified until the scheduler exists.

## Amdahl planning and next block

The 4.7624 s/token baseline is mixed-source planning data, not a single current
end-to-end timing run.

| Scenario | Estimated ms/token | Speedup | Evidence status |
|---|---:|---:|---|
| current | 4,762.4 | 1.00x | mixed measured operator budget |
| QK only | 4,229.2 | 1.13x | QK replacement plus analytical composition |
| QK + quantized V storage | 3,548.4 | 1.34x | analytical composition |
| QK + V accumulation | 3,245.0 | 1.47x | analytical P16 AV target |
| full attention path | 2,647.6 | 1.80x | analytical softmax/AV targets |

Attention-weighted V is 1,035.0 ms (21.7%) of the current token budget,
softmax is 617.4 ms (13.0%), paging/cache movement is 645.7 ms (13.6%), and QK
is 573.9 ms (12.1%). The next integrated RTL should therefore be AXI-128 V5
streaming plus scale FIFO/prefetch feeding the existing AV numerator, alongside
the page scheduler. Further isolated QK parallelism has lower system leverage.

## Verification status

The Windows regression covers required context boundaries
1, 7, 63, 64, 65, 127, 128, 129, 511, 512, 513, 1023, 1024, 1025, 4095, and
4096; randomized AXI/read/output back-pressure; short-after-long and
short-after-fault; final partial words; CRC/header/format faults; invalid
contexts/addresses/scales; reserved codes; AXI stalls/responses/timeouts; and
the new data/scale/reciprocal pipeline abort cases. CSD, forced-DSP, and AUTO AV
all use the same real and adversarial golden vectors.

## Unverified hypotheses and required future data

- Ten prompt/context cases do not establish task accuracy, perplexity,
  generation quality, or long-context behavior. Contexts 1024--4096 still need
  real-model execution on a faster host.
- UQ4.8 had no faults in these captures; another model, layer, or activation
  outlier distribution may require UQ5.11 range.
- The page scheduler, offset-table reader, ping-pong page buffers, physical
  scale FIFO, and V AXI reader are not yet integrated RTL.
- Isolated OOC timing is not a full Arty implementation, DDR throughput,
  power, thermal, or board result.
- The final normalized AV output ABI, reciprocal application, rounding, and
  saturation are not frozen.
- Deterministic dither correlation/resonance has not been tested and the exact
  mapping remains undefined.

## Reproduction and artifact index

- Gate A: `results/gate_a/gate_a_summary.csv`,
  `page_accounting_summary.csv`, and `summary.json`
- Gate B: `results/fixedpoint/*.csv` and `summary.json`
- Codec: `codec/codec_fault_matrix.csv` and `codec_validation.json`
- QK cycle accounting: `results/rtl/qk_cycle_accounting.csv/.json`
- Page schedule: `results/schedule/gqa_schedule_model.csv` and `summary.json`
- Synthetic/reference results: `../synthetic/`, `../pareto/`, and
  `../hardware_estimates/`
- Vivado summaries and retained reports:
  `../hardware_estimates/vivado_v0_3_blocks_2026_1/`

Paths in this index are written from `analysis/kv_validation/v0_3`; `../`
therefore selects a sibling evidence directory. The final handoff ZIP also contains raw
completed Gate A runs, Vivado reports/checkpoints/logs, a Git bundle, the dirty
tree patch if applicable, and a SHA-256 manifest.
