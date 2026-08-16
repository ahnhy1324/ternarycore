# KV-cache IP v0.1 archive

This file records the legacy contract only. It is not an implementation guide
for ABI v2. The normative current document is [KV-IP.md](KV-IP.md).

## Why v0.1 was superseded

v0.1 was a small read-only K-path milestone with `HEAD_DIM=64`, P16, signed
Q8.8 scalar scale, and one 32-byte INT4 vector per token. It established AXI
protocol behavior, boundary/error testing, and nibble order, but its numerical
contract was not suitable for the actual BitNet head128 model.

Later software validation showed that scale granularity mattered much more
than expected, that Q and K/V require different fixed-point scale formats, and
that comparisons must keep head dimension equal. The actual-model handoff then
selected Q UQ1.15, K/V UQ5.11, K4/group128 QK, and separate metadata planes.

## Legacy/current differences

| Item | Legacy v0.1 | Current ABI v2 |
|---|---|---|
| Core ID | `0x4B56_0001` | `0x4B56_0002` |
| Primary head dimension | 64 | 128; 64 remains smoke profile |
| K scale | signed Q8.8 | unsigned UQ5.11 |
| Scale reset code | `0x0100` | `0x0800` |
| Scale layout | scalar register | scalar compatibility register; separate plane proposed |
| QK core | dequantize then dot | raw P16 dot then one scale multiply/group |
| K5 | not implemented | arithmetic core only; reader still K4-only |
| Overflow behavior | implicit 32-bit truncation risk | pre-AXI unsafe-scale rejection |

## Preserved evidence

The synthetic Q8.8, group16/group32, Hadamard, storage, and early timing tables
remain in `analysis/kv_validation/` for reproducibility. They are historical
experiments, not the current hardware contract. The full pre-cleanup narrative
is recoverable from Git commit `833915d`.

Do not copy the legacy `token << 3` group16 scale layout, Q8.8 CFG semantics,
or `HEAD_DIM=64` recommendation into new RTL or firmware.
