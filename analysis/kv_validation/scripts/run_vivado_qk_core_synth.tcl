# Vivado 2026.1 OOC comparison of K4/K5 QK multiplier mappings.
# Usage: vivado -mode batch -source run_vivado_qk_core_synth.tcl -tclargs REPO OUT

if {$argc != 2} {
    error "usage: run_vivado_qk_core_synth.tcl REPO_ROOT OUT_DIR"
}
set repo_root [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
file mkdir $out_dir
set part "xc7a100tcsg324-1"
set source [file join $repo_root rtl qk_group_dot.v]
set xdc [file join $repo_root analysis kv_validation scripts kv_ooc_81p25mhz.xdc]

foreach config {
    {regular4_shift_add 4 0}
    {regular4_dsp 4 1}
    {regular4_auto 4 2}
    {accurate5_shift_add 5 0}
    {accurate5_dsp 5 1}
    {accurate5_auto 5 2}
} {
    lassign $config name k_width mult_style
    puts "QK_SYNTH_BEGIN name=$name k_width=$k_width mult_style=$mult_style"
    create_project -in_memory -part $part
    read_verilog $source
    read_xdc $xdc
    set_property top qk_group_dot [current_fileset]
    synth_design -top qk_group_dot -part $part -mode out_of_context \
        -flatten_hierarchy rebuilt -generic [list \
        LANES=16 GROUP_SIZE=128 Q_WIDTH=8 K_WIDTH=$k_width \
        SCALE_WIDTH=16 ACC_WIDTH=64 MULT_STYLE=$mult_style]
    report_utilization -file [file join $out_dir ${name}_utilization.rpt]
    report_timing_summary -delay_type max -max_paths 10 -report_unconstrained \
        -file [file join $out_dir ${name}_timing_summary.rpt]
    report_timing -delay_type max -max_paths 10 \
        -file [file join $out_dir ${name}_timing_paths.rpt]
    write_checkpoint -force [file join $out_dir ${name}_post_synth.dcp]
    close_project
    puts "QK_SYNTH_END name=$name"
}
puts "QK_SYNTH_SWEEP_PASS out=$out_dir"
