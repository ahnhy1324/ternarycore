# Raw-result index

## Provenance and configuration

| Artifact | Evidence | Contents |
|---|---|---|
| `../environment.json` | `[REAL-MODEL-VALIDATED]` | Host, software, git base, checkpoint revision/SHA-256 |
| `../model_config.json` | `[REAL-MODEL-VALIDATED]` | Authoritative model and tokenizer configuration |
| `../validation_summary.json` | mixed, explicitly labeled | Compact summary of the final rows |
| `../prior_evidence_manifest.json` | provenance | Source hashes for imported v0.2 tables |
| `../verification.json` | reproducibility/consistency | Final artifact assertions and RTL-untouched check |
| `../result_manifest.json` | reproducibility | Byte size and SHA-256 of every final artifact |

## Real-model execution and inspection

| Artifact | Evidence | Contents |
|---|---|---|
| `../real_model/prompts_and_token_ids.json` | `[REAL-MODEL-VALIDATED]` tokenizer only | Exact deterministic prompts and context token IDs |
| `../real_model/checkpoint_projection_weight_stats.csv` | `[REAL-MODEL-VALIDATED]` stored weights | Per-layer Q/K/V packed ternary code and scale statistics |
| `../real_model/checkpoint_projection_weight_summary.csv` | `[REAL-MODEL-VALIDATED]` stored weights | Projection-level aggregation |
| `../real_model/model_load_attempts.json` | `[REAL-MODEL-VALIDATED]` environment attempt | Exact load blockers and evidence boundary |
| `../real_model/activation_context_status.csv` | `[REAL-MODEL-VALIDATED]` | Contexts 128/512 pass; 1024/2048/4096 remain `NOT_TESTED` |
| `../real_model/streaming_reference_validation.json` | `[REAL-MODEL-VALIDATED]` | Real layer-0 bitwise comparison with the pinned Transformers implementation |
| `../real_model/runs/20260816-streaming-full-c128/` | `[REAL-MODEL-VALIDATED]` | Full 30-layer context-128 run, five captures, raw tensors, and analysis |
| `../real_model/runs/20260816-streaming-full-c512/` | `[REAL-MODEL-VALIDATED]` | Full 30-layer context-512 run, five captures, raw tensors, and analysis |
| `../real_model/aggregate_context128_512/` | `[REAL-MODEL-VALIDATED]` | Pooled Q8-only, K/V bit-width, mixed-granularity, storage, and Pareto rows |
| `../real_model/predictor_validation_context128_512/` | `[REAL-MODEL-VALIDATED]` | Context-128 fit/context-512 evaluation of K and V error predictors |
| `../report/REAL_MODEL_HANDOFF.md` | mixed, explicitly labeled | Reproduction, conclusions, hardware handoff, and remaining gates |

## Synthetic raw data

| Artifact | Evidence | Contents |
|---|---|---|
| `../tensors/synthetic_canonical_context128.npz` | `[SOFTWARE-SYNTHETIC]` | Canonical Q/K/V, attention, and output tensors for every split/regime/family at context 128 |
| `../synthetic/controlled_attention_verification.csv` | `[SOFTWARE-SYNTHETIC]` | Seeds, `N_eff`, entropy, and target-attention reconstruction checks |
| `../synthetic/k_only_results.csv` | `[SOFTWARE-SYNTHETIC]` | Raw INT3/4/5/8 K-only metrics |
| `../synthetic/v_only_results.csv` | `[SOFTWARE-SYNTHETIC]` | Raw INT3/4/5/8 V-only metrics |
| `../synthetic/joint_kv_results.csv` | `[SOFTWARE-SYNTHETIC]` | Raw nine-point K/V design-space results |
| `../synthetic/scale_representation_results.csv` | `[SOFTWARE-FIXED-POINT]` | Per-token/run INT4 floating-vs-Q8.8 scale error separation |
| `../synthetic/theory_sample_results.csv` | `[SOFTWARE-SYNTHETIC]` | Sample-level predictor inputs and actual powers |
| `../synthetic/heldout_predictor_summary.csv` | `[SOFTWARE-SYNTHETIC]` | Calibration-only fits and held-out correlations/residuals |
| `../synthetic/synthetic_summary.json` | `[SOFTWARE-SYNTHETIC]` | Protocol, row counts, Pareto, and provenance |
| `../synthetic/tier1_reference.json` | `[SOFTWARE-SYNTHETIC / BRING-UP]` | Independent Tier-1 checksum validation |
| `../synthetic/tier1_reference_outputs.npz` | `[SOFTWARE-SYNTHETIC / BRING-UP]` | Independent Tier-1 activations/outputs |

## Pareto and compact tables

| Artifact | Evidence | Contents |
|---|---|---|
| `../pareto/joint_kv_pareto.csv` | `[SOFTWARE-SYNTHETIC]` | Storage vs mean/p95 joint K/V Pareto fronts |
| `../pareto/k_only_summary.csv` | `[SOFTWARE-SYNTHETIC]` | K-only mean/p95/worst summary |
| `../pareto/v_only_summary.csv` | `[SOFTWARE-SYNTHETIC]` | V-only mean/p95/worst summary |
| `../pareto/kv_factor_breakdown.csv` | `[SOFTWARE-SYNTHETIC]` | Context/regime/family dependence |
| `../pareto/scale_representation_summary_head128.csv` | `[SOFTWARE-FIXED-POINT]` | Q8.8 contribution and run-scale control |
| `../pareto/scale_granularity_pareto_head64.csv` | labeled per row | Imported prior group64/32/16/8 sweep |
| `../pareto/hadamard_pareto_head64.csv` | `[SOFTWARE-FIXED-POINT]` | Imported prior H4..H64 error/storage/cost sweep |

## Hardware and system estimates

| Artifact | Evidence | Contents |
|---|---|---|
| `../hardware_estimates/gqa_cache_storage.csv` | `[THEORETICAL]` | All contexts/formats with five KV heads and 30 layers |
| `../hardware_estimates/int4_scale_granularity_storage.csv` | `[THEORETICAL]` | Metadata/effective-bit/compression accounting at dimensions 64 and 128 |
| `../hardware_estimates/axi_vector_layout.csv` | `[THEORETICAL]` | 128/256-bit beats, padding, scale-plane efficiency |
| `../hardware_estimates/int4_layout_comparison.csv` | `[THEORETICAL]` | Separate-plane versus interleaved records |
| `../hardware_estimates/storage_summary.json` | `[THEORETICAL]` | Authoritative geometry and layout recommendation |
| `../hardware_estimates/qk_cycle_accounting.csv` | `[RTL-SIMULATED]` | 512/4096 cycle-state totals for 128/256-bit v0.1 |
| `../hardware_estimates/qk_cycle_accounting_head64_head128.csv` | `[RTL-SIMULATED]` | Dimension-64 and authoritative-dimension-128 cycle accounting |
| `../hardware_estimates/windows_regression_vivado_2026_1.txt` | `[RTL-SIMULATED]` | Full Windows Icarus and Python regression log |
| `../hardware_estimates/toolchain_status.json` | environment status | Vivado/Icarus versions, license, packaging, XSIM, and synthesis pass state |
| `../hardware_estimates/vivado_2026_1_xsim_kv_default.txt` | `[RTL-SIMULATED/XSIM]` | Vivado Simulator boundary/error regression transcript |
| `../hardware_estimates/vivado_2026_1_package_axi_kv_cache_final.txt` | `[VIVADO-IP-PACKAGING]` | IP integrity/package transcript |
| `../hardware_estimates/vivado_synthesis_utilization.csv` | `[VIVADO-POST-SYNTH]` | Four HEAD_DIM/AXI configurations with resource and timing estimates |
| `../hardware_estimates/vivado_synthesis_summary.json` | `[VIVADO-POST-SYNTH]` | Synthesis protocol, interpretation, and resource deltas |
| `../hardware_estimates/vivado_synth_2026_1_timed/*.rpt` | `[VIVADO-POST-SYNTH]` | Raw timing-driven utilization, hierarchy, and pre-route timing reports |
| `VIVADO_RESOURCE_REPORT.md` | `[VIVADO-POST-SYNTH]` | Human-readable resource hierarchy, timing failure, and architecture consequence |
| `../hardware_estimates/qk_cycle_options.csv` | labeled per row | Measured width option and analytical utilization options |
| `../hardware_estimates/amdahl_components.csv` | `[THEORETICAL]` mixed inputs | Component latency budget |
| `../hardware_estimates/amdahl_scenarios.csv` | `[THEORETICAL]` mixed inputs | Whole-token scenarios |

## Adversarial

| Artifact | Evidence | Contents |
|---|---|---|
| `../adversarial/quantizer_adversarial.csv` | `[SOFTWARE-FIXED-POINT]` | Zero, constant, threshold, scale-limit, saturation, outlier cases |
| `../adversarial/attention_adversarial.csv` | `[SOFTWARE-SYNTHETIC]` | Equal, extremely sharp, and diffuse softmax cases |
| `../adversarial/adversarial_summary.json` | mixed, explicitly labeled | Crash/NaN/saturation/wrap summary and accumulator bound |
