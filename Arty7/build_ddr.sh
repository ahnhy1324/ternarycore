#!/usr/bin/env bash
# build_ddr.sh — Phase-2 (MIG/DDR3) bitstream. Run from repo root, vivado on PATH.
# Requires: Digilent board files at ~/board-files/vivado-boards (git clone),
# packaged IPs in ip/weight_bram128 and ip/axi_gemm_stream (from build_tier2).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -d "$HOME/board-files/vivado-boards/new/board_files/arty-a7-100" ] || {
  echo 'board files missing: git clone https://github.com/Digilent/vivado-boards ~/board-files/vivado-boards' >&2; exit 1; }
[ -f "$HERE/../ip/weight_bram128/component.xml" ] || { echo 'package weight_bram128 first (build_tier2.sh does this)' >&2; exit 1; }
[ -f "$HERE/../ip/axi_gemm_stream/component.xml" ] || { echo 'package axi_gemm_stream first' >&2; exit 1; }

# Package in the active Vivado version. Do not check generated component.xml
# into the functional RTL change: this keeps 2026.1 work retestable on 2025.2.
vivado -mode batch -source "$HERE/../ip/package_axi_kv_cache.tcl"
[ -f "$HERE/../ip/axi_kv_cache/component.xml" ] || { echo 'package axi_kv_cache failed' >&2; exit 1; }

sed 's/arty_mb_gemm/arty_ddr/g' "$HERE/generate_bitstream.tcl" > "$HERE/generate_bitstream_ddr.tcl"

vivado -mode batch -source "$HERE/create_bd_ddr.tcl"
vivado -mode batch -source "$HERE/generate_bitstream_ddr.tcl"
echo 'Phase-2 build complete.'
