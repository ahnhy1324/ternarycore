# Vivado 2026.1 KV-cache resource and timing report

Date: 2026-08-16  
Evidence: `[VIVADO-POST-SYNTH]`  
Top: `axi_kv_cache`  
Part: `xc7a100tcsg324-1`  
Target: 81.25 MHz (`12.308 ns` after Vivado rounding)  
Flow: timing-driven out-of-context synthesis; no placement or routing

## Result

All four configurations synthesize with no critical warnings or errors. None
meets the 81.25 MHz timing target. The reported Fmax is only an equivalent
post-synthesis estimate derived from `target period - WNS`; it is not routed
timing closure.

| HEAD_DIM | AXI | LUT | LUT % | logic LUT | LUTRAM LUT | FF | DSP | BRAM tile | WNS | critical path | estimated Fmax |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 64 | 128 | 7,269 | 11.47% | 4,453 | 2,816 | 1,303 | 17 | 0 | -26.962 ns | 39.153 ns | 25.46 MHz |
| 64 | 256 | 7,080 | 11.17% | 4,264 | 2,816 | 1,552 | 17 | 0 | -26.760 ns | 38.951 ns | 25.60 MHz |
| 128 | 128 | 9,017 | 14.22% | 6,201 | 2,816 | 1,822 | 17 | 0 | -26.944 ns | 39.135 ns | 25.48 MHz |
| 128 | 256 | 8,845 | 13.95% | 6,029 | 2,816 | 2,069 | 17 | 0 | -26.760 ns | 38.951 ns | 25.60 MHz |

The XSIM/Icarus cycle counts remain valid functional measurements, but their
81.25 MHz latency and Mkeys/s conversions are frequency assumptions, not a
timing-closed FPGA result. For example, the HEAD_DIM64/AXI128 context-4096
run is 59,256 cycles: 729.3 us at the unclosed target, versus roughly 2.33 ms
at the 25.46 MHz post-synthesis equivalent estimate.

## Where the resources go

The first-class HEAD_DIM64/AXI128 hierarchy is:

| Instance | LUT | logic LUT | LUTRAM LUT | FF | DSP | Interpretation |
|---|---:|---:|---:|---:|---:|---|
| top total | 7,269 | 4,453 | 2,816 | 1,303 | 17 | complete AXI wrapper and QK engine |
| wrapper-local | 4,339 | 1,523 | 2,816 | 752 | 0 | AXI-Lite registers, Q/logit access |
| `u_engine` | 2,930 | 2,930 | 0 | 551 | 17 | reader, dequantization, MAC/control |
| `u_dequant` | 1,232 | 1,232 | 0 | 0 | 0 | sixteen parallel signed INT4×Q8.8 products in LUTs |
| `u_dot` | 174 | 174 | 0 | 65 | 17 | sixteen 20×8 multiplies plus unpipelined reduction |
| `u_reader` | 92 | 92 | 0 | 187 | 0 | one-vector AXI read control/buffering |

The 4,096×32 logit memory is inferred as 704 `RAM64M` instances, consuming
2,816 LUTs and zero BRAM tiles. The asynchronous AXI-Lite read behavior keeps
it out of block RAM. A synchronous read or streamed-result interface should
target BRAM/streaming in v0.2; the mathematical minimum for 131,072 bits is
four 36-Kb block-RAM tiles, but the exact mapping must be resynthesized.

The timing path is the unregistered 16-lane scaled dot-product reduction.
Vivado maps 17 DSP48E1s: sixteen Q×dequantized-K multiplies plus reduction/
accumulation structure. `P=16` is fixed, so HEAD_DIM and AXI width do not alter
the DSP count. Doubling AXI width reduces total LUTs slightly (-189 at
HEAD_DIM64) but adds 249 FFs; it does not materially improve the critical path.
Doubling HEAD_DIM at AXI128 adds 1,748 LUTs and 519 FFs, primarily wider
Q-vector access/muxing and control, while arithmetic lanes remain fixed.

## Architecture consequence

The next RTL revision should not begin by widening AXI or adding MAC lanes.
It should first change the arithmetic schedule:

1. Form signed raw `INT8 Q × INT4 K-code` products.
2. Use a balanced, registered reduction tree for one `P=16` group.
3. Multiply the group partial sum by its Q8.8 scale once, then accumulate
   scaled group results. For group16 this is one scale multiplication per MAC
   slice; group32 can reuse one scale across two slices.
4. Pipeline for initiation interval one even if result latency increases.
5. Make logit storage synchronous BRAM or stream results, then add burst K and
   scale FIFOs/double buffering.

The algebraic refactor is exact for a common group scale and aligns directly
with the real-tensor group32/group16 candidates. Expected DSP/LUT savings are
a hypothesis until this v0.2 datapath is synthesized; no projected resource
number is promoted into this report.

## Reproduction and caveats

```powershell
$env:XILINXD_LICENSE_FILE = "<local Vivado license>"
$repo = (Resolve-Path .).Path
$out = Join-Path $repo "analysis/kv_validation/hardware_estimates/vivado_synth_2026_1_timed"
& "E:\xilinx\2026.1\Vivado\bin\vivado.bat" -mode batch -nolog -nojournal `
  -source analysis/kv_validation/scripts/run_vivado_ooc_synth.tcl `
  -tclargs $repo $out
python analysis/kv_validation/scripts/parse_vivado_synth.py
```

The OOC clock port has no `HD.CLK_SRC`, so clock insertion/skew is not modeled.
Run full implementation with the Arty clock/MIG context after the arithmetic
path is pipelined. The current RTL also has no scale FIFO, group-scale ABI,
multi-vector burst FIFO, V path, softmax, Hadamard, or dither hardware.
