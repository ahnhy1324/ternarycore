# Vivado 2026.1 synthesis and routed OOC sweep for isolated KV v0.3 blocks.
# Usage: vivado -mode batch -source run_vivado_v03_blocks.tcl \
#          -tclargs REPO_ROOT OUT_DIR ?CONFIG_FILTERS?

if {$argc < 2 || $argc > 3} {
    error "usage: run_vivado_v03_blocks.tcl REPO_ROOT OUT_DIR ?CONFIG_FILTERS?"
}

set repo_root [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
set filters {}
if {$argc == 3} {
    set filters [split [lindex $argv 2] "+"]
}
file mkdir $out_dir

set part "xc7a100tcsg324-1"
set target_mhz 81.25
set xdc [file join $repo_root analysis kv_validation scripts \
         kv_ooc_81p25mhz.xdc]

set decoder_sources [list \
    [file join $repo_root rtl kv_v03_symbol_decoder.v] \
    [file join $repo_root rtl kv_v03_decoder_cluster_2x2.v]]
set qk_sources [list [file join $repo_root rtl qk_group_dot.v]]
set softmax_sources [list \
    [file join $repo_root rtl kv_v03_score_store.v] \
    [file join $repo_root rtl kv_v03_exp_lut.v] \
    [file join $repo_root rtl kv_v03_reciprocal.v] \
    [file join $repo_root rtl kv_v03_softmax.v] \
    [file join $repo_root rtl kv_v03_softmax_engine.v]]
set av_sources [list \
    [file join $repo_root rtl kv_v03_v5_weight_mul.v] \
    [file join $repo_root rtl kv_v03_av_accumulator.v]]

set configs [list \
    [list decoder_2x2 kv_v03_decoder_cluster_2x2 $decoder_sources {}] \
    [list qk_k4_auto qk_group_dot $qk_sources \
          {GROUP_SIZE=128 Q_WIDTH=8 K_WIDTH=4 SCALE_WIDTH=16 ACC_WIDTH=64 MULT_STYLE=2}] \
    [list softmax_engine kv_v03_softmax_engine $softmax_sources {}] \
    [list av_v5_csd kv_v03_av_accumulator $av_sources {MULT_STYLE=0}] \
    [list av_v5_auto kv_v03_av_accumulator $av_sources {MULT_STYLE=2}]]

set summary_path [file join $out_dir routed_runs.csv]
set summary [open $summary_path w]
puts $summary "config,top,part,target_clock_mhz,status,route_status,wns_ns,estimated_fmax_mhz"

foreach config $configs {
    lassign $config name top sources generics
    if {[llength $filters] > 0 && [lsearch -exact $filters $name] < 0} {
        continue
    }
    puts "V03_IMPL_BEGIN name=$name top=$top"
    set status "PASS"
    set route_status "NOT_RUN"
    set wns ""
    set fmax ""
    if {[catch {
        create_project -in_memory -part $part
        read_verilog $sources
        read_xdc $xdc
        set_property top $top [current_fileset]
        if {[llength $generics] > 0} {
            synth_design -top $top -part $part -mode out_of_context \
                -flatten_hierarchy rebuilt -generic $generics
        } else {
            synth_design -top $top -part $part -mode out_of_context \
                -flatten_hierarchy rebuilt
        }
        report_utilization -file \
            [file join $out_dir ${name}_post_synth_utilization.rpt]
        report_utilization -hierarchical -hierarchical_depth 6 -file \
            [file join $out_dir ${name}_post_synth_hierarchical.rpt]
        report_timing_summary -delay_type max -max_paths 10 \
            -report_unconstrained -file \
            [file join $out_dir ${name}_post_synth_timing_summary.rpt]
        write_checkpoint -force \
            [file join $out_dir ${name}_post_synth.dcp]

        opt_design
        place_design -directive Explore
        phys_opt_design -directive Explore
        route_design -directive Explore
        set route_status [get_property ROUTE_STATUS [current_design]]
        report_utilization -file \
            [file join $out_dir ${name}_routed_utilization.rpt]
        report_utilization -hierarchical -hierarchical_depth 6 -file \
            [file join $out_dir ${name}_routed_hierarchical.rpt]
        report_timing_summary -delay_type max -max_paths 20 \
            -report_unconstrained -file \
            [file join $out_dir ${name}_routed_timing_summary.rpt]
        report_timing -delay_type max -max_paths 20 -file \
            [file join $out_dir ${name}_routed_timing_paths.rpt]
        report_drc -file [file join $out_dir ${name}_routed_drc.rpt]
        write_checkpoint -force [file join $out_dir ${name}_routed.dcp]

        set timing_paths [get_timing_paths -delay_type max -max_paths 1 -quiet]
        if {[llength $timing_paths] > 0} {
            set wns [get_property SLACK [lindex $timing_paths 0]]
            set effective_period [expr {1000.0 / $target_mhz - $wns}]
            if {$effective_period > 0} {
                set fmax [format "%.3f" [expr {1000.0 / $effective_period}]]
            }
        }
    } message options]} {
        set status "FAIL"
        set error_file [open [file join $out_dir ${name}_error.txt] w]
        puts $error_file $message
        puts $error_file [dict get $options -errorinfo]
        close $error_file
        puts "V03_IMPL_ERROR name=$name message=$message"
    }
    puts $summary "$name,$top,$part,$target_mhz,$status,$route_status,$wns,$fmax"
    flush $summary
    catch {close_project}
    puts "V03_IMPL_END name=$name status=$status"
}

close $summary
puts "V03_IMPL_SWEEP_COMPLETE summary=$summary_path"
