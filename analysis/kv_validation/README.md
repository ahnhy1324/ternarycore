# KV-cache software validation

This directory is the evidence package for the pre-RTL KV-cache validation
gate. The checkpoint is external at `../bitnet-b1.58-2B-4T` and is never part
of this repository.

The result boundary is strict:

- `[THEORETICAL]`: storage, AXI-layout, Pareto, and Amdahl arithmetic.
- `[SOFTWARE-SYNTHETIC]`: controlled-attention and Tier-1 vectors.
- `[SOFTWARE-FIXED-POINT]`: behavioral Q8.8 scale reconstruction. There is no
  frozen RTL arithmetic contract, so these results are not called bit-exact.
- `[REAL-MODEL-VALIDATED]`: checkpoint identity plus layer-streaming execution
  and Q/K/V captures at contexts 128 and 512. Longer contexts are explicitly
  `NOT_TESTED`.
- `[RTL-SIMULATED]`: Icarus coverage at head dimensions 64/128 and AXI
  widths 128/256; Vivado XSIM coverage for `HEAD_DIM=64`, AXI128.
- `[VIVADO-POST-SYNTH]`: OOC utilization and pre-route timing estimates for
  four head-dimension/AXI-width configurations on `xc7a100tcsg324-1`.

Synthetic results are not task accuracy, model accuracy, or perplexity claims.

## Reproduction

Use a new output directory so raw results are not overwritten. From the
repository root in PowerShell:

```powershell
$run = "analysis/kv_validation_reproduction/20260816-01"
python analysis/kv_validation/scripts/inspect_checkpoint.py --checkpoint ../bitnet-b1.58-2B-4T --output $run
python analysis/kv_validation/scripts/verify_tier1.py --output "$run/synthetic"
python analysis/kv_validation/scripts/run_synthetic_validation.py --output $run
python analysis/kv_validation/scripts/run_storage_analysis.py --output $run
python analysis/kv_validation/scripts/run_adversarial.py --output $run
python analysis/kv_validation/scripts/collect_architecture_evidence.py --output $run
python analysis/kv_validation/scripts/summarize_validation.py --output $run
```

The low-memory actual-model runner deliberately does not import Transformers:

```powershell
python analysis/kv_validation/scripts/validate_bitnet_streaming_reference.py
python analysis/kv_validation/scripts/run_real_model_streaming.py `
  --output analysis/kv_validation/real_model/runs/<new-run> `
  --context-length 128 --layers 0,7,15,22,29 --layer-count 30
```

Base seed is `20260816`. Calibration and evaluation seeds are derived from
different `SeedSequence` split identifiers. Exact prompt token IDs, sample
seeds, quantizer definitions, source hashes, checkpoint revision, software
versions, and host information are in the JSON/CSV artifacts.

## Result map

- `environment.json`, `model_config.json`: host/checkpoint identity.
- `real_model/`: checkpoint inspection, reference cross-check, actual Q/K/V
  captures, pooled quantization tables, and predictor validation.
- `tensors/`: compressed canonical synthetic tensors.
- `synthetic/`: raw controlled-attention, K-only, V-only, joint, scale, and
  held-out predictor rows.
- `pareto/`: compact K/V, scale-granularity, and Hadamard tables.
- `hardware_estimates/`: GQA storage, AXI layouts, cycle accounting, Amdahl
  estimates, XSIM/IP-package evidence, and Vivado synthesis utilization.
- `adversarial/`: numerical boundary and saturation cases.
- `report/`: final report, limitations, and detailed artifact index.

See `report/FINAL_REPORT.md` for conclusions and `report/RESULT_INDEX.md` for
the raw-result index.

On Windows without GNU Make, run the repository-equivalent suite with:

```powershell
sim/run_windows_regression.ps1
```

It uses `C:\iverilog\bin` by default, writes simulator executables to a unique
system temporary directory, forces UTF-8 for Python output, and covers head
dimensions 64 and 128 at AXI128/AXI256.
