# KV-cache v0.3 implementation plan

This plan follows the theory-closure handoff. It is an execution checklist,
not evidence that a block exists or passes.

## Frozen baseline

- Q8, K4 group128, V5 group128, P16, GQA 20:5.
- UQ5.11 is the scale reference. UQ4.8/12-bit remains a candidate until Gate A
  closes on eight natural prompts at context 128 and two at context 512.
- Separate page-compressed K/V payload and scale planes, static prefix tables,
  whole-page raw fallback, 32-bit offset tables, 16-byte page alignment.
- Page CRC covers `header[0:8] || payload || scale slice`; K/V offset tables
  have independent descriptor CRC fields.
- AXI-128 is first class. Page128 + 4×1 is the selected isolated baseline;
  2×2 remains a functional but timing-rejected comparison.
- Four synchronous 4096×16 signed Q8.8 score rows, 128-entry UQ1.15 exp LUT,
  unsigned 28-bit denominator, normalized reciprocal F=12.
- V5 AV uses one `exp × V_scale` operation per token, P16, signed 48-bit banked
  numerators, and post-accumulation common-denominator normalization.

Hadamard, dither, per-channel K, outlier paths, adaptive coding, temporal scale
prediction, mixed precision, pruning, sink protection, training changes, and
new model families are excluded.

## Software gates before RTL

1. Verify the handoff ZIP CRC and every manifest hash.
2. Regenerate page64/page128 examples with the closed CRC scope.
3. Verify header/payload/scale/CRC/offset fault injection and raw fallback.
4. Execute Gate A. An UQ4.8 model case is accepted only if page64 and page128
   both decode every K/V code and scale identically before attention.
5. Freeze the fixed-point LUT address equation and generate adversarial and
   real-capture golden vectors.

No baseline RTL is changed before these steps complete.

## RTL block order

For every RTL edit, the complete relevant Icarus suite runs before Vivado.

1. `kv_v03_crc32`: reflected CRC-32/ISO-HDLC, 32 input bits/cycle, byte-valid
   mask, start/final handshakes, check-value test.
2. `kv_v03_page_header`: parse and validate the 12-byte header; output a typed
   descriptor only after CRC success. Reserved flags, IDs, lengths, and token
   counts are errors.
3. `kv_v03_scale12_reader`: contiguous LSB-reservoir 12-bit unpacker with
   ready/valid, final partial word support, underflow/overflow detection, and
   reset/restart coverage.
4. `kv_v03_k4_decoder` and `kv_v03_v5_decoder`: static 256×10 lookahead ROM,
   exact symbol count, invalid/truncated detection, raw unpack mode, and no
   speculative externally visible output before page integrity passes.
5. `kv_v03_decoder_cluster`: independent tasks for 1×4, 2×2, and 4×1. It does
   not split a page into byte-aligned substreams.
6. `qk_group_dot`: register selected Q/K lanes, then multiply and use registered
   balanced reduction stages. Accumulate the full group128 raw dot and apply
   one scale. AUTO is primary; SHIFT_ADD is an identical-result ablation.
7. `kv_v03_score_store` and `kv_v03_softmax`: four synchronous BRAM rows,
   max/subtract, zero below -12, exp accumulation, normalized reciprocal.
8. `kv_v03_av`: pipelined exp×scale, V5 AUTO/CSD/DSP comparison, sixteen banks
   of signed 48-bit numerator state, one reciprocal/head, time-multiplexed
   normalization.
9. `kv_v03_page_scheduler`: AXI-128 page/offset/scale bursts, CRC-gated
   ping-pong buffers, payload/scale FIFOs, typed faults, and all required
   starvation/utilization counters.

## Execution status — 2026-08-17

Evidence labels below distinguish Icarus RTL simulation from software and from
Vivado routed OOC results. They do not imply a complete Arty implementation.

- Steps 1-5 pass unit and full KV regression: CRC32, typed page header,
  contiguous UQ4.8 scale reader, and bit-exact K4/V5 compressed/raw decoders.
- The 2x2 decoder cluster remains bit-exact, but routed WNS is -9.138 ns at
  81.25 MHz. The selected 4x1 cluster runs four complete independent page
  tasks at one symbol/cycle each, supports runtime K4/V5 selection, passes
  concurrent compressed/raw and per-lane fault isolation, and closes routed
  OOC timing with +0.570 ns WNS.
- Step 6 arithmetic is implemented ahead of the decoder cluster: registered
  Q/K inputs, registered product/reduction levels, group128 accumulation, and
  identical K4/K5 AUTO versus SHIFT_ADD real-model golden results.
- The legacy vector FSM now overlaps the next AXI read with QK pipeline drain.
  It drains accepted AXI bursts and flushes the QK pipeline on a late format
  fault, including restart-after-long and short-after-error regression.
- Step 7 now has an isolated RTL baseline: four synchronous 4096x16 score rows,
  the frozen 128-entry UQ1.15 LUT, strictly-below -12 underflow, 28-bit
  denominator, and an iterative F12 normalized reciprocal. It is bit-exact on
  adversarial boundaries and one real Gate A score row. The current two-pass
  controller is a correctness baseline, not a final utilization result. The
  memory maps to eight RAMB36 blocks and the exact reciprocal-multiply `/24`
  address path closes routed OOC timing with +1.609 ns WNS.
- Step 8 now has a bit-exact integer-numerator baseline: P16, four heads,
  sixteen signed 48-bit distributed-RAM banks, and AUTO/CSD/forced-DSP
  equivalent V5 products. It passes
  one context-128 real capture and a short adversarial case. The final
  numerator-times-reciprocal output rounding/format remains deliberately open
  because the handoff freezes a signed 64-bit intermediate but not an output
  code format. The legal magnitude is below 2^44, so the 48-bit banks do not
  require a runtime overflow detector.
- Step 9 remains pending. The decoder `done` pulse is the page
  commit point; integration must keep streamed symbols in scratch state until
  format completion succeeds.

Machine-readable simulated cycle results are in
`results/rtl/qk_cycle_accounting.csv` and `.json`. At HEAD_DIM=64 and 4096 keys,
the overlap revision reduced 128-bit cycles from 67,832 to 55,249 and 256-bit
cycles from 61,445 to 49,231. These are RTL simulation counts; rates computed
at 81.25 MHz are projections until Vivado timing closes.

## Sticky error classes

The exact numeric register encoding is frozen with the integrated ABI, but the
typed identities must remain distinct:

- invalid request/context/address;
- AXI response or timeout;
- header magic/version/flags/length/ID;
- page CRC;
- offset-table CRC or invalid/non-monotonic offset;
- scale/data synchronization or scale FIFO underflow;
- compressed prefix invalid/truncated/trailing data;
- reserved raw K4/V5 code;
- score/denominator overflow; AV numerator width is protected by the frozen
  legal-input bound rather than an unreachable runtime fault;
- internal scheduler/FIFO protocol violation.

Any page-integrity error suppresses decoder output, aborts the affected row or
requests host reload, and never selects raw mode as recovery.

## Regression sequence

Lengths are `1, 7, 63, 64, 65, 127, 128, 129, 511, 512, 513, 1023, 1024,
1025, 4095, 4096`. Tests include randomized input bubbles/output backpressure,
short-after-long, final partial boundaries, reset/restart, CRC faults,
scale/data synchronization, FIFO underflow, AXI stalls, timeouts, and invalid
contexts. A timeout is a test failure.

## Vivado evidence

Part `xc7a100tcsg324-1`, target 81.25 MHz. Isolated decoder, QK, softmax, and AV
variants have synthesis and routed implementation reports. LUT, LUTRAM, FF,
DSP48E1, RAMB18/RAMB36, WNS/TNS, route errors, critical paths, and retained
architecture revisions are in `../hardware_estimates/` machine-readable
summaries. Failed timing remains a reported failure; an estimated frequency is
never relabeled as timing closure. OOC `HD.CLK_SRC` and parent
`HD.PARTPIN_LOCS` are unset, so top-level clock/interface placement remains a
separate integration requirement.

Selected routed OOC results are decoder 4x1 1,713 LUT/440 FF/+0.570 ns WNS,
QK 835 LUT/850 FF/1 DSP/+4.628 ns, softmax 438 LUT/359 FF/8.5 BRAM tiles/1
DSP/+1.609 ns, and AV AUTO 3,577 LUT/673 FF/1 DSP/+1.753 ns. AV forced-DSP is
the LUT-saving option at 1,384 LUT/337 FF/33 DSP/+1.323 ns. The CSD AV mapping
uses 7,113 LUT and is not selected.
