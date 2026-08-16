# v0.3 score, softmax, and AV fixed-point ABI

Status: software reference frozen for RTL implementation. Evidence produced by
this ABI remains `[SOFTWARE-FIXED-POINT]` until compared with RTL.

## Score and exponent

- Four independent score rows are retained for the four Q heads sharing one KV
  head.
- Each row has 4096 signed 16-bit Q8.8 entries in synchronous BRAM.
- The row maximum is subtracted in signed integer arithmetic.
- A delta strictly below `-12.0` (`-3072` Q8.8) maps to exponent code zero.
- The exponent table has 128 unsigned UQ1.15 entries. Entry `i` is
  `round_even(exp(-i × 24/256) × 32768)`, saturated to `0..32768`.
- A non-underflow delta uses nearest table index
  `min(127, (-delta + 12) // 24)`. An exact half step selects the more-negative
  bin.

The theory-closure package freezes Q8.8, the `[-12,0]` domain, 128 entries, and
UQ1.15, but does not state the table address equation. The 24-code mapping
above is therefore a newly explicit ABI assumption, not a reproduced package
fact. Its separate error sweep must pass before RTL results are interpreted.

With 4096 equal maximum scores, the denominator is exactly
`4096 × 32768 = 134217728` (`2^27`), which fits unsigned 28 bits.

## Reciprocal

For a positive integer denominator `D`:

1. compute `e = floor(log2(D))`;
2. interpret `m = D / 2^e`, so `1 <= m < 2`;
3. store `round_even((1/m) × 2^F)`;
4. use F=12 for the baseline and F=14 only as a reference comparison.

The F=12 code is 13 bits because exact `1.0` is `4096`. One reciprocal is
computed per head and reused across all 128 output dimensions.

## AV accumulation

Do not normalize probabilities before AV. For each dimension:

```text
numerator[d] = sum(exp_code[t] * v_scale_code[t] * v_code[t,d])
denominator  = sum(exp_code[t])
output[d]    = numerator[d] / (denominator * 256)
```

`v_code` is signed narrow-range INT5 (`-15..15`) and `v_scale_code` is unsigned
UQ4.8. The baseline numerator is signed 48 bits. A 52-bit version is only an
implementation comparison if resources and routing allow it.

The implementation uses P16 and sixteen accumulator banks. Each of the four Q
heads sharing a KV head owns 128 numerator states, for `4 × 128 × 48 = 24576`
state bits. The banked state must map to memory or compact distributed storage,
not a fully expanded register/mux array.

The bit-exact software definitions are in
`../scripts/v0_3_fixedpoint_reference.py`. The sweep includes uniform,
near-uniform, top-2 tie, medium-sparse, single-sink, one-hot-like, long-tail,
and LUT-boundary inputs at all required regression lengths, plus real model
score rows and PACKED5 AV captures.
