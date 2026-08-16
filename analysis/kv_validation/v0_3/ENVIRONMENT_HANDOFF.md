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
4. Run the reference self-checks before resuming the long matrix.
5. Resume the matrix. It skips profiles that contain a valid `run.json`.

```powershell
python analysis\kv_validation\scripts\validate_bitnet_streaming_reference.py
python analysis\kv_validation\scripts\packed5_page_codec.py --self-test
python analysis\kv_validation\scripts\validate_v0_3_codec.py
python analysis\kv_validation\scripts\run_v0_3_gate_a_matrix.py
```

If a process stopped mid-profile, the matrix refuses to overwrite that partial
directory. Move the exact incomplete profile directory into
`analysis/kv_validation/v0_3/results/gate_a/_interrupted/`, inspect its log, and
then rerun the matrix. Never label a partial profile complete merely because its
log ended.

After Gate A completes:

```powershell
python analysis\kv_validation\scripts\summarize_v0_3_gate_a.py
python analysis\kv_validation\scripts\validate_v0_3_codec.py
python analysis\kv_validation\scripts\run_v0_3_fixedpoint_sweep.py
python analysis\kv_validation\scripts\run_v0_3_schedule_model.py
```

Then use the numerical decision to implement RTL. Per `AGENTS.md`, every RTL
change must pass Icarus regression before Vivado synthesis or implementation.

## Remaining work

- Complete and summarize the eight-prompt, ten-context-case Gate A matrix.
- Decide whether UQ4.8 is acceptable using aggregate and worst-case paired
  results, not a single prompt.
- Complete Gate B fixed-point sweep and freeze explicitly unverified ABI choices.
- Implement isolated codec/CRC/fixed-point RTL only after Gate A/B.
- Run Icarus boundary/back-pressure/fault regressions.
- Run the required Vivado 2026.1 utilization/timing comparisons, with the
  128-bit Arty path as a first-class configuration.
- Update `docs/KV-IP.md` and v0.3 result documents with evidence-class labels.
- Review comments, TODOs, timeout failures, synchronization, and boundary bugs.
- Produce one final analysis ZIP with SHA-256 manifest and a local final commit.

The optional 24-32-window expansion is not part of the fast path. Run it only
if the eight-prompt paired results leave the UQ4.8 decision materially unclear.

## What must be preserved outside Git

- Completed real-model run directories and logs
- Compact NPZ/CSV/JSON evidence and generated codec pages
- Icarus transcripts
- Raw Vivado reports, journals, checkpoints, and tool-version/license-checkout
  evidence (with secrets removed)
- Final ZIP and its external SHA-256 value

Use `create_v0_3_resume_archive.ps1` to make a consistent archive. It copies only
profile directories that already contain `run.json`; an actively written
profile is listed in status output but is not treated as completed evidence.
