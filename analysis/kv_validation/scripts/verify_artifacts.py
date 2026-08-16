#!/usr/bin/env python3
"""Consistency checks for the final KV validation evidence package."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import subprocess
from pathlib import Path


def rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def main() -> None:
    repo = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path,
                        default=repo / "analysis" / "kv_validation")
    args = parser.parse_args()
    root = args.output.resolve()
    checks: list[dict[str, object]] = []

    required = (
        "environment.json", "model_config.json", "validation_summary.json",
        "real_model/model_load_attempts.json",
        "real_model/activation_context_status.csv",
        "real_model/streaming_reference_validation.json",
        "real_model/aggregate_context128_512/summary.json",
        "real_model/aggregate_context128_512/joint_kv_summary.csv",
        "real_model/aggregate_context128_512/int4_mixed_granularity_summary.csv",
        "real_model/predictor_validation_context128_512/summary.json",
        "synthetic/controlled_attention_verification.csv",
        "synthetic/k_only_results.csv", "synthetic/v_only_results.csv",
        "synthetic/joint_kv_results.csv",
        "synthetic/scale_representation_results.csv",
        "synthetic/heldout_predictor_summary.csv",
        "pareto/joint_kv_pareto.csv",
        "hardware_estimates/gqa_cache_storage.csv",
        "hardware_estimates/qk_cycle_accounting.csv",
        "hardware_estimates/qk_cycle_accounting_head64_head128.csv",
        "hardware_estimates/windows_regression_vivado_2026_1.txt",
        "hardware_estimates/vivado_2026_1_xsim_kv_default.txt",
        "hardware_estimates/vivado_2026_1_package_axi_kv_cache_final.txt",
        "hardware_estimates/toolchain_status.json",
        "hardware_estimates/vivado_synthesis_utilization.csv",
        "hardware_estimates/vivado_synthesis_summary.json",
        "adversarial/adversarial_summary.json",
        "report/FINAL_REPORT.md", "report/LIMITATIONS.md",
        "report/RESULT_INDEX.md", "report/REAL_MODEL_HANDOFF.md",
        "report/VIVADO_RESOURCE_REPORT.md",
    )
    missing = [name for name in required if not (root / name).is_file()]
    assert not missing, missing
    checks.append({"check": "required_artifacts", "status": "PASS",
                   "count": len(required)})

    controlled = rows(root / "synthetic/controlled_attention_verification.csv")
    assert len(controlled) == 300
    assert {int(row["context_len"]) for row in controlled} == {
        128, 512, 1024, 2048, 4096}
    assert {row["regime"] for row in controlled} == {
        "diffuse", "moderate", "sharp", "sink"}
    assert {row["family"] for row in controlled} == {
        "gaussian", "laplace", "student_t_df3",
        "sparse_outliers_0p1pct_x25", "outliers_1pct_x10"}
    maximum_error = max(float(row["target_attention_max_error"])
                        for row in controlled)
    assert maximum_error < 2.0e-6
    cal_seeds = {row["seed"] for row in controlled
                 if row["split"] == "calibration"}
    eval_seeds = {row["seed"] for row in controlled
                  if row["split"] == "evaluation"}
    assert cal_seeds.isdisjoint(eval_seeds)
    checks.append({"check": "controlled_attention", "status": "PASS",
                   "rows": len(controlled), "maximum_error": maximum_error,
                   "calibration_evaluation_seed_overlap": 0})

    expected_rows = {
        "k_only_results.csv": 1200,
        "v_only_results.csv": 1200,
        "joint_kv_results.csv": 2700,
        "scale_representation_results.csv": 600,
    }
    for name, count in expected_rows.items():
        actual = rows(root / "synthetic" / name)
        assert len(actual) == count, (name, len(actual))
        for row in actual:
            for key, value in row.items():
                if key.endswith(("rmse", "cosine", "bias", "error_power")):
                    assert math.isfinite(float(value)), (name, key, value)
    checks.append({"check": "raw_row_counts_and_finite_metrics",
                   "status": "PASS", **expected_rows})

    joint = rows(root / "pareto/joint_kv_pareto.csv")
    assert {(int(row["k_bits"]), int(row["v_bits"])) for row in joint} == {
        (k, v) for k in (3, 4, 5) for v in (3, 4, 5)}
    int4 = next(row for row in joint
                if row["k_bits"] == "4" and row["v_bits"] == "4")
    assert math.isclose(float(int4["effective_bits_per_value"]), 4.125)
    checks.append({"check": "joint_design_space", "status": "PASS",
                   "configurations": 9})

    scale = rows(root / "pareto/scale_representation_summary_head128.csv")
    token = next(row for row in scale if row["granularity"] == "token")
    run = next(row for row in scale if row["granularity"] == "run")
    assert float(run["mean_total_output_relative_rmse"]) > float(
        token["mean_total_output_relative_rmse"])
    assert float(token["mean_scale_representation_only_output_relative_rmse"]) < 0.01
    checks.append({"check": "scale_hypotheses", "status": "PASS",
                   "per_run_worse_than_per_token": True,
                   "q8_8_mean_scale_only_below_one_percent": True})

    config = json.loads((root / "model_config.json").read_text(encoding="utf-8"))
    derived = config["derived"]
    assert (derived["head_dim"], derived["num_attention_heads"],
            derived["num_key_value_heads"], derived["num_hidden_layers"]) == (
                128, 20, 5, 30)
    status = rows(root / "real_model/activation_context_status.csv")
    assert len(status) == 5
    status_by_context = {int(row["context_len"]): row["status"]
                         for row in status}
    assert status_by_context == {
        128: "PASS", 512: "PASS", 1024: "NOT_TESTED",
        2048: "NOT_TESTED", 4096: "NOT_TESTED"}
    reference = json.loads((root / "real_model" /
                            "streaming_reference_validation.json").read_text(
                                encoding="utf-8"))
    assert reference["status"] == "PASS"
    assert reference["bitwise_equal"] is True
    aggregate = json.loads((root / "real_model" /
                            "aggregate_context128_512" / "summary.json").read_text(
                                encoding="utf-8"))
    assert aggregate["status"] == "PASS"
    assert aggregate["contexts_tested"] == [128, 512]
    checks.append({"check": "model_geometry_and_status", "status": "PASS",
                   "activation_contexts": status_by_context,
                   "streaming_reference_bitwise_equal": True})

    environment = json.loads((root / "environment.json").read_text(
        encoding="utf-8"))
    checkpoint = Path(environment["checkpoint_path"])
    assert checkpoint.is_dir() and checkpoint.parent == repo.parent
    assert (checkpoint / "model.safetensors").stat().st_size == environment[
        "checkpoint_bytes"]
    tracked = subprocess.check_output(
        ["git", "ls-files"], cwd=repo, text=True).splitlines()
    assert not any("bitnet-b1.58-2B-4T" in name for name in tracked)
    checks.append({"check": "external_checkpoint_not_tracked", "status": "PASS"})

    tier1 = json.loads((root / "synthetic/tier1_reference.json").read_text(
        encoding="utf-8"))
    assert tier1["independent_checksum_hex"] == "0xfffff600"
    adversarial = json.loads((root / "adversarial/adversarial_summary.json").read_text(
        encoding="utf-8"))["summary"]
    assert adversarial["crashes"] == 0 and adversarial["nan_cases"] == 0
    assert adversarial["silent_wrap_cases"] == 0
    checks.append({"check": "tier1_and_adversarial", "status": "PASS",
                   "tier1_checksum": "0xfffff600", **adversarial})

    manifest = json.loads((root / "prior_evidence_manifest.json").read_text(
        encoding="utf-8"))["files"]
    for item in manifest:
        source = repo / item["source"]
        assert hashlib.sha256(source.read_bytes()).hexdigest() == item[
            "source_sha256"]
    checks.append({"check": "imported_source_hashes", "status": "PASS",
                   "files": len(manifest)})

    regression_log = (root / "hardware_estimates" /
                      "windows_regression_vivado_2026_1.txt").read_text(
                          encoding="utf-8")
    assert "FULL_WINDOWS_REGRESSION_PASS" in regression_log
    assert "TB FAIL" not in regression_log
    cycle_rows = rows(root / "hardware_estimates" /
                      "qk_cycle_accounting_head64_head128.csv")
    assert len(cycle_rows) == 8
    assert {int(row["head_dim"]) for row in cycle_rows} == {64, 128}
    checks.append({"check": "windows_rtl_regression", "status": "PASS",
                   "cycle_rows": len(cycle_rows),
                   "head_dimensions": [64, 128]})

    toolchain = json.loads((root / "hardware_estimates" /
                            "toolchain_status.json").read_text(encoding="utf-8"))
    assert toolchain["icarus"]["full_regression"] == "PASS"
    assert toolchain["vivado"]["xvlog_compile"] == "PASS"
    assert toolchain["vivado"]["xelab_elaboration"] == "PASS"
    assert toolchain["vivado"]["batch_ip_packaging"] == "PASS"
    assert toolchain["vivado"]["xsim_execution"] == "PASS"
    assert toolchain["vivado"]["ooc_synthesis"] == (
        "SYNTH_PASS_TIMING_FAIL")
    utilization = rows(root / "hardware_estimates" /
                       "vivado_synthesis_utilization.csv")
    assert len(utilization) == 4
    assert {(int(row["head_dim"]), int(row["axi_data_width"]))
            for row in utilization} == {
                (64, 128), (64, 256), (128, 128), (128, 256)}
    assert all(row["target_timing_met"] == "False" for row in utilization)
    baseline_synth = next(row for row in utilization
                          if row["config"] == "hd64_axi128")
    assert (int(baseline_synth["slice_luts"]),
            int(baseline_synth["slice_registers"]),
            int(baseline_synth["dsp48e1"]),
            int(baseline_synth["bram_tiles"])) == (7269, 1303, 17, 0)
    checks.append({"check": "toolchain_status", "status": "PASS",
                   "vivado_packaging": "PASS",
                   "vivado_xsim": "PASS", "synthesis_configurations": 4})

    rtl_status = subprocess.check_output(
        ["git", "status", "--short", "--", "rtl", "Arty7"],
        cwd=repo, text=True).strip()
    assert not rtl_status, rtl_status
    checks.append({"check": "baseline_rtl_and_arty_untouched",
                   "status": "PASS",
                   "packaging_script_only": "ip/package_axi_kv_cache.tcl"})

    verification_diff = set(subprocess.check_output(
        ["git", "diff", "--name-only", "--", "sim/Makefile", "tb"],
        cwd=repo, text=True).splitlines())
    assert verification_diff == {
        "sim/Makefile", "tb/tb_axi_kv_cache.v", "tb/tb_int4_unpack.v",
        "tb/tb_kv_cache_engine.v", "tb/tb_kv_dequant.v", "tb/tb_qk_dot.v"}
    checks.append({"check": "head_dim128_verification_changes_present",
                   "status": "PASS", "files": sorted(verification_diff)})

    report = {
        "evidence": "REPRODUCIBILITY/CONSISTENCY",
        "status": "PASS",
        "checks": checks,
    }
    (root / "verification.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"validation artifact verification PASS ({len(checks)} checks)")


if __name__ == "__main__":
    main()
