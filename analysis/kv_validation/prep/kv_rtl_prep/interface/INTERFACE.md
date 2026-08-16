# KV Attention Sidecar Interface v0.1

## Boundary
The core owns:
- packed low-bit K/V read
- scale metadata read
- QK accumulation
- fixed-point softmax
- AV accumulation
- attention output write/stream

The core does NOT own:
- transformer scheduling
- tokenizer/model execution
- RoPE generation
- RMSNorm
- model-specific head allocation policy
- experimental rotation/outlier/token-pruning algorithms

## Interfaces
- AXI4-Lite control/status register bank
- AXI4 master for K/V payload, scale metadata, and optional Q/output buffers
- optional streaming Q input and attention-output ports may be compile-time integration wrappers

## Compile-time profile knobs
- HEAD_DIM
- LANES / parallelism
- AXI data width
- MULT_IMPL = AUTO | DSP | SHIFT_ADD
- softmax LUT depth
- supported K/V bit profile

## Runtime knobs
Keep runtime configuration small: context length, head mapping, buffer addresses,
and only those format choices physically supported by the synthesized profile.

This preserves one reusable IP while preventing the research ablation matrix from
turning into runtime hardware complexity.
