# KV-cache v0.3 environment handoff

This file is the restart contract for moving the v0.3 work to another Windows
environment. It intentionally contains no license server value, credential, or
machine-specific secret.

## Authority and publication policy

- Theory package: `kv-cache-v0.3-theory-closure-handoff-20260816.zip`
- Execution request: `kv-v0.3-execution-request-20260816.md`
- Local continuation branch: `codex/kv-v0.3-todo`
- Do not push, publish, or open a pull request for this work.
- Keep synthetic, analytical, simulated, and real-model evidence separated.
- Do not change the baseline RTL until software Gate A/B is complete.

Verified source hashes:

- Theory ZIP SHA-256:
  `35FB5881B7FC5FFF05AC87E9C90594C542BB2396B03DE1A4140757E07CA4525E`
- Execution request SHA-256:
  `3B435560C0AD7DBA2ECC28CF28288CEA750D70E5153BCD482F0DEB6977A87E89`
- BitNet model file SHA-256:
  `8143AE115ED6BABE5E5ADA8FB8C5B769D8F417802B2DB042AD98B4F7ED73975B`

## Required local inputs

The checkpoint is intentionally not copied into Git or the handoff archive.
Before resuming, place it at a local path and verify the model hash above. The
current environment uses:

```text
F:\Xilinx_WorkSpace\bitnet-b1.58-2B-4T
```

Expected tools in the current environment:

- Python 3.10.5 with CPU PyTorch
- Icarus Verilog under `C:\iverilog\bin`
- Vivado 2026.1 under `E:\xilinx\2026.1\Vivado\bin\vivado.bat`
- Arty target part `xc7a100tcsg324-1`

Vivado must perform a real license checkout in the new environment. Do not copy
or record a license-server value in this handoff.

## Resume procedure

1. Restore the repository and check out `codex/kv-v0.3-todo` from the Git
   bundle, or apply `working-tree.patch` if the archive says the tree was dirty.
2. Restore the completed `analysis/kv_validation/v0_3/results` directories from
   the archive.
3. Verify the theory ZIP, execution request, and checkpoint hashes.
4. Run the reference self-checks and full RTL regression before new RTL work.
5. Regenerate compact summaries. Rerun the long matrix only if a completed
   profile is absent or its recorded hash fails.

```powershell
python analysis\kv_validation\scripts\validate_bitnet_streaming_reference.py
python analysis\kv_validation\scripts\packed5_page_codec.py --self-test
python analysis\kv_validation\scripts\validate_v0_3_codec.py
.\sim\run_windows_regression.ps1
```

If a process stopped mid-profile, the matrix refuses to overwrite that partial
directory. Move the exact incomplete profile directory into
`analysis/kv_validation/v0_3/results/gate_a/_interrupted/`, inspect its log, and
then rerun the matrix. Never label a partial profile complete merely because its
log ended.

Regenerate the compact evidence and routed-report tables with:

```powershell
python analysis\kv_validation\scripts\summarize_v0_3_gate_a.py
python analysis\kv_validation\scripts\validate_v0_3_codec.py
python analysis\kv_validation\scripts\run_v0_3_fixedpoint_sweep.py
python analysis\kv_validation\scripts\run_v0_3_schedule_model.py
python analysis\kv_validation\scripts\summarize_vivado_v03_blocks.py analysis\kv_validation\hardware_estimates\vivado_v0_3_blocks_2026_1
python analysis\kv_validation\scripts\summarize_vivado_v03_variants.py analysis\kv_validation\hardware_estimates\vivado_v0_3_blocks_2026_1
```

Then use the numerical decision to implement RTL. Per `AGENTS.md`, every RTL
change must pass Icarus regression before Vivado synthesis or implementation.

## Completed state — 2026-08-17

- Gate A completed 30/30 runs: eight natural prompts at context 128 and two at
  context 512. UQ4.8 mean final-hidden relative RMSE is 0.073107 versus
  0.072898 for UQ5.11; both preserve top-1 in all ten cases and have no scale
  faults. These are distortion measurements, not accuracy/perplexity claims.
- Gate B, codec self-checks, nine fault classes, and the page64/page128 storage
  accounting pass. Page128 averages 129.262 full K+V bytes/token/KV head.
- The complete Windows regression passes, including all required boundary
  lengths, randomized back-pressure, short-after-long/fault, explicit timeout
  failures, 4x1 decoder isolation, softmax abort/orphan reciprocal behavior,
  and CSD/DSP/AUTO AV goldens.
- Routed OOC timing closes at 81.25 MHz for decoder 4x1 (+0.570 ns), QK
  (+4.628 ns), softmax (+1.609 ns), AV AUTO (+1.753 ns), AV forced DSP
  (+1.323 ns), and AV CSD (+1.221 ns). Decoder 2x2 is rejected at -9.138 ns.
- AV AUTO is the default resource balance at 3,577 LUT/673 FF/1 DSP. Forced
  DSP is a 1,384 LUT/337 FF/33 DSP option. CSD uses 7,113 LUT and is rejected.
- Current and retained-revision machine tables are under
  `analysis/kv_validation/hardware_estimates/vivado_v0_3_blocks_2026_1/`.
- The consolidated decision record is
  `analysis/kv_validation/v0_3/reports/V0_3_IMPLEMENTATION_REPORT.md`.

## Next safe implementation work

1. Build the AXI-128 page/offset scheduler with long bursts, CRC-gated
   ping-pong buffers, and starvation/utilization counters.
2. Add independent K/V scale FIFOs and prefetch with explicit data/scale tags
   and underflow tests.
3. Add the V5 AXI stream and connect it to the isolated AV AUTO baseline.
4. Integrate score/softmax/AV row commit/abort ownership.
5. Freeze normalized AV output rounding/saturation before implementing the
   reciprocal-output stage.

Do not add Hadamard or deterministic dither to the baseline. Do not switch to
the 256-bit port or add MAC lanes until integrated counters show that AXI width
or arithmetic is the dominant stall source. The optional 24--32-window model
expansion is no longer needed to decide the current UQ4.8 fast path, but longer
real-model contexts still require a faster host.

## What must be preserved outside Git

- Completed real-model run directories and logs
- Compact NPZ/CSV/JSON evidence and generated codec pages
- Icarus transcripts
- Raw Vivado reports, journals, checkpoints, and tool-version/license-checkout
  evidence (with secrets removed)
- Final ZIP and its external SHA-256 value

Use `create_v0_3_resume_archive.ps1` to make a consistent archive. It copies only
profile directories that already contain `run.json`; an actively written
profile is listed in status output but is not treated as completed evidence. It
also preserves the two imported context-128 `BASE_FP` reference directories
required to reproduce the paired engineering and observatory comparisons.
