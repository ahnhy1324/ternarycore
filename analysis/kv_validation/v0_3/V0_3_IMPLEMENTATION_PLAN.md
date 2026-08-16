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
- AXI-128 is first class. Page128 + 2×2 is the provisional balanced point;
  page64 and 1×4/4×1 remain measured comparisons.
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
- score/denominator/numerator overflow;
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

Part `xc7a100tcsg324-1`, initial target 81.25 MHz. Every required variant gets
OOC synthesis and routed implementation reports. The page128+2×2 candidate is
run with CRC on/off. LUT, LUTRAM, FF, DSP48E1, RAMB18, RAMB36, WNS/TNS, routed
Fmax, critical paths, II, cycle counts, FIFO levels, AXI efficiency,
starvation, page distribution, fallback, CRC cost, and golden status are kept
in machine-readable summaries. Failed timing remains a reported failure; an
estimated frequency is never relabeled as timing closure.
