param(
    [string]$IcarusBin = "C:\iverilog\bin",
    [switch]$KvOnly,
    [switch]$SkipPython
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$iverilog = Join-Path $IcarusBin "iverilog.exe"
$vvp = Join-Path $IcarusBin "vvp.exe"
if (-not (Test-Path -LiteralPath $iverilog)) {
    throw "Icarus compiler not found: $iverilog"
}
if (-not (Test-Path -LiteralPath $vvp)) {
    throw "Icarus runtime not found: $vvp"
}

$simTemp = Join-Path ([IO.Path]::GetTempPath()) (
    "ternarycore-iverilog-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $simTemp | Out-Null

function Invoke-IverilogTest {
    param(
        [string]$Name,
        [string[]]$Defines,
        [string[]]$RelativeFiles,
        [string[]]$RuntimeArgs = @()
    )
    $output = Join-Path $simTemp $Name
    $arguments = @("-g2012")
    foreach ($define in $Defines) {
        $arguments += "-D$define"
    }
    $arguments += @("-o", $output)
    $arguments += @($RelativeFiles | ForEach-Object { Join-Path $repo $_ })
    & $iverilog @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Name compile failed with exit code $LASTEXITCODE"
    }
    Push-Location $simTemp
    try {
        & $vvp $output @RuntimeArgs
        if ($LASTEXITCODE -ne 0) {
            throw "$Name simulation failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
    Write-Output "SIM_PASS $Name"
}

if (-not $KvOnly) {
    Invoke-IverilogTest "sim_mac" @() @(
        "tb/tb_ternary_mac.v", "rtl/ternary_mac.v", "rtl/ternary_weight.v")
    Invoke-IverilogTest "sim_dot" @() @(
        "tb/tb_ternary_dot.v", "rtl/ternary_dot.v", "rtl/ternary_weight.v")
    foreach ($depth in 4, 16, 64) {
        Invoke-IverilogTest "sim_gemm_d$depth" @("DEPTH_VAL=$depth") @(
            "tb/tb_ternary_gemm.v", "rtl/ternary_gemm.v",
            "rtl/ternary_dot.v", "rtl/ternary_weight.v")
        Invoke-IverilogTest "sim_axi_gemm_d$depth" @("DEPTH_VAL=$depth") @(
            "tb/tb_axi_gemm_wrapper.v", "rtl/axi_gemm_wrapper.v",
            "rtl/ternary_gemm.v", "rtl/ternary_dot.v",
            "rtl/ternary_weight.v")
    }
    foreach ($width in 4, 8) {
        Invoke-IverilogTest "sim_weight_bram_d$width" @(
            "ADDR_WIDTH_VAL=$width") @(
            "tb/tb_weight_bram.v", "rtl/weight_bram.v")
    }
}

$kvRtl = @(
    "rtl/kv_addr_gen.v", "rtl/int4_unpack.v", "rtl/kv_dequant.v",
    "rtl/qk_dot.v", "rtl/qk_group_dot.v", "rtl/kv_reader.v",
    "rtl/kv_cache_engine.v")
Invoke-IverilogTest "sim_int4_unpack" @() @(
    "tb/tb_int4_unpack.v", "rtl/int4_unpack.v")
Invoke-IverilogTest "sim_kv_v03_crc32" @() @(
    "tb/tb_kv_v03_crc32.v", "rtl/kv_v03_crc32.v")
Invoke-IverilogTest "sim_kv_v03_page_header" @() @(
    "tb/tb_kv_v03_page_header.v", "rtl/kv_v03_page_header.v")
Invoke-IverilogTest "sim_kv_v03_scale12_reader" @() @(
    "tb/tb_kv_v03_scale12_reader.v", "rtl/kv_v03_scale12_reader.v")
$decoderGoldenRoot = (Join-Path $repo (
    "analysis/kv_validation/v0_3/codec/decoder_goldens")).Replace("\", "/")
Invoke-IverilogTest "sim_kv_v03_decoders" @() @(
    "tb/tb_kv_v03_decoders.v", "rtl/kv_v03_symbol_decoder.v",
    "rtl/kv_v03_k4_decoder.v", "rtl/kv_v03_v5_decoder.v") @(
    "+GOLDEN_ROOT=$decoderGoldenRoot")
Invoke-IverilogTest "sim_kv_v03_decoder_cluster_2x2" @() @(
    "tb/tb_kv_v03_decoder_cluster_2x2.v",
    "rtl/kv_v03_symbol_decoder.v",
    "rtl/kv_v03_decoder_cluster_2x2.v") @(
    "+GOLDEN_ROOT=$decoderGoldenRoot")
$softmaxGoldenRoot = (Join-Path $repo (
    "analysis/kv_validation/v0_3/rtl_goldens/softmax")).Replace("\", "/")
Invoke-IverilogTest "sim_kv_v03_reciprocal" @() @(
    "tb/tb_kv_v03_reciprocal.v", "rtl/kv_v03_reciprocal.v") @(
    "+GOLDEN_ROOT=$softmaxGoldenRoot")
Invoke-IverilogTest "sim_kv_v03_score_store" @() @(
    "tb/tb_kv_v03_score_store.v", "rtl/kv_v03_score_store.v")
Invoke-IverilogTest "sim_kv_v03_softmax" @() @(
    "tb/tb_kv_v03_softmax.v", "rtl/kv_v03_score_store.v",
    "rtl/kv_v03_exp_lut.v", "rtl/kv_v03_reciprocal.v",
    "rtl/kv_v03_softmax.v") @(
    "+GOLDEN_ROOT=$softmaxGoldenRoot")
Invoke-IverilogTest "sim_kv_dequant" @() @(
    "tb/tb_kv_dequant.v", "rtl/kv_dequant.v")
Invoke-IverilogTest "sim_qk_dot" @() @(
    "tb/tb_qk_dot.v", "rtl/qk_dot.v")
$goldenRoot = Join-Path $repo (
    "analysis/kv_validation/real_model/qk_profile_golden_v0_2")
foreach ($qkProfile in @(
    @{Name="regular4"; Width=4}, @{Name="accurate5"; Width=5})) {
    $profileRoot = (Join-Path $goldenRoot $qkProfile.Name).Replace("\", "/")
    foreach ($multStyle in 0, 2) {
        Invoke-IverilogTest (
            "sim_qk_group_dot_$($qkProfile.Name)_style$multStyle") @(
            "K_WIDTH_VAL=$($qkProfile.Width)",
            "MULT_STYLE_VAL=$multStyle") @(
            "tb/tb_qk_group_dot.v", "rtl/qk_group_dot.v") @(
            "+GOLDEN_ROOT=$profileRoot")
    }
}
Invoke-IverilogTest "sim_kv_cache_engine" @() @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_kv_cache_engine_256" @(
    "AXI_DATA_WIDTH_VAL=256") @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_kv_cache_engine_hd128" @(
    "HEAD_DIM_VAL=128") @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_kv_cache_engine_hd128_256" @(
    "HEAD_DIM_VAL=128", "AXI_DATA_WIDTH_VAL=256") @(
    @("tb/tb_kv_cache_engine.v") + $kvRtl)
Invoke-IverilogTest "sim_axi_kv_cache" @() @(
    @("tb/tb_axi_kv_cache.v", "rtl/axi_kv_cache.v") + $kvRtl)
Invoke-IverilogTest "sim_axi_kv_cache_hd128" @(
    "HEAD_DIM_VAL=128") @(
    @("tb/tb_axi_kv_cache.v", "rtl/axi_kv_cache.v") + $kvRtl)

if (-not $SkipPython) {
    $env:PYTHONUTF8 = "1"
    $pythonTests = @(
        "verify/verify_mac.py", "verify/verify_dot.py",
        "verify/verify_gemm.py", "verify/verify_kv_int4.py",
        "verify/verify_kv_quant.py", "verify/verify_kv_analysis_artifacts.py")
    foreach ($test in $pythonTests) {
        & python (Join-Path $PSScriptRoot $test)
        if ($LASTEXITCODE -ne 0) {
            throw "$test failed with exit code $LASTEXITCODE"
        }
        Write-Output "PY_VERIFY_PASS $test"
    }
}

Write-Output "REGRESSION_TEMP $simTemp"
Write-Output "FULL_WINDOWS_REGRESSION_PASS"
