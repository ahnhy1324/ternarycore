# Vivado 2026.1 out-of-context synthesis sweep for the KV-cache wrapper.
# Usage:
#   vivado -mode batch -source run_vivado_ooc_synth.tcl -tclargs REPO_ROOT OUT_DIR

if {$argc < 2 || $argc > 3} {
    error "usage: run_vivado_ooc_synth.tcl REPO_ROOT OUT_DIR ?CONFIG_FILTER?"
}

set repo_root [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
set config_filter ""
if {$argc == 3} {
    set config_filter [lindex $argv 2]
}
file mkdir $out_dir

set part "xc7a100tcsg324-1"
set clock_period_ns 12.307692
set sources [list \
    [file join $repo_root rtl axi_kv_cache.v] \
    [file join $repo_root rtl kv_cache_engine.v] \
    [file join $repo_root rtl kv_addr_gen.v] \
    [file join $repo_root rtl kv_reader.v] \
    [file join $repo_root rtl int4_unpack.v] \
    [file join $repo_root rtl qk_group_dot.v] \
    [file join $repo_root rtl kv_dequant.v] \
    [file join $repo_root rtl qk_dot.v]]
set timing_xdc [file join $repo_root analysis kv_validation scripts \
                kv_ooc_81p25mhz.xdc]

set summary_path [file join $out_dir synth_runs.csv]
set summary [open $summary_path w]
puts $summary "config,head_dim,axi_data_width,part,target_clock_mhz,status"

foreach config {{hd64_axi128 64 128} {hd64_axi256 64 256} \
                {hd128_axi128 128 128} {hd128_axi256 128 256}} {
    lassign $config name head_dim axi_width
    if {$config_filter ne "" && $name ne $config_filter} {
        continue
    }
    puts "SYNTH_BEGIN name=$name head_dim=$head_dim axi_width=$axi_width"
    create_project -in_memory -part $part
    read_verilog $sources
    read_xdc $timing_xdc
    set_property top axi_kv_cache [current_fileset]
    synth_design -top axi_kv_cache -part $part -mode out_of_context \
        -flatten_hierarchy rebuilt \
        -generic [list HEAD_DIM=$head_dim M_AXI_DATA_WIDTH=$axi_width]
    report_utilization -file [file join $out_dir ${name}_utilization.rpt]
    report_utilization -hierarchical -hierarchical_depth 5 \
        -file [file join $out_dir ${name}_utilization_hierarchical.rpt]
    report_timing_summary -delay_type max -max_paths 10 -report_unconstrained \
        -file [file join $out_dir ${name}_timing_summary.rpt]
    report_timing -delay_type max -max_paths 10 \
        -file [file join $out_dir ${name}_timing_paths.rpt]

    write_checkpoint -force [file join $out_dir ${name}_post_synth.dcp]
    puts $summary "$name,$head_dim,$axi_width,$part,81.25,SYNTH_PASS"
    flush $summary
    close_project
    puts "SYNTH_END name=$name"
}

close $summary
puts "SYNTH_SWEEP_PASS summary=$summary_path"
