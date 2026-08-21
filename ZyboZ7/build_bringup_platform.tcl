# build_bringup_platform.tcl
# One-shot build, report, and export for the temporary Zybo platform.
#
# Usage:
#   vivado -mode batch -source build_bringup_platform.tcl \
#       -tclargs <fresh-created-external-output-directory> ?jobs?

proc bringup_build_usage {} {
    error "usage: build_bringup_platform.tcl <fresh-created-external-output-directory> ?jobs?"
}

proc bringup_paths_overlap {left_path right_path} {
    set left_parts  [file split [file normalize $left_path]]
    set right_parts [file split [file normalize $right_path]]
    set common_count [expr {min([llength $left_parts], [llength $right_parts])}]
    set windows [expr {$::tcl_platform(platform) eq "windows"}]
    for {set index 0} {$index < $common_count} {incr index} {
        set left_part  [lindex $left_parts $index]
        set right_part [lindex $right_parts $index]
        set equal [expr {$windows
            ? [string equal -nocase $left_part $right_part]
            : [string equal $left_part $right_part]}]
        if {!$equal} {
            return 0
        }
    }
    return 1
}

proc bringup_paths_equal {left_path right_path} {
    set left  [file normalize $left_path]
    set right [file normalize $right_path]
    if {$::tcl_platform(platform) eq "windows"} {
        return [string equal -nocase $left $right]
    }
    return [string equal $left $right]
}

proc bringup_git {directory args} {
    if {[catch {exec git -C $directory {*}$args} result]} {
        error "Git command failed in '$directory' (git $args): $result"
    }
    return [string trim $result]
}

proc bringup_worktrees {repo_root} {
    set worktrees {}
    set listing [bringup_git $repo_root worktree list --porcelain]
    foreach line [split $listing "\n"] {
        if {[regexp {^worktree[ ]+(.+)$} [string trim $line] -> worktree]} {
            lappend worktrees [file normalize $worktree]
        }
    }
    if {[llength $worktrees] < 1} {
        error "Git reported no worktrees for repository containing '$repo_root'"
    }
    return $worktrees
}

proc bringup_require_safe_output {output_dir repo_root} {
    set normalized [file normalize $output_dir]
    set parent [file normalize [file dirname $normalized]]
    if {[bringup_paths_equal $normalized $parent]} {
        error "refusing to use a filesystem/drive root as output: $normalized"
    }
    if {$::tcl_platform(platform) eq "windows"} {
        set output_volume [string trimright [lindex [file split $normalized] 0] "/\\"]
        if {![string equal -nocase $output_volume "D:"]} {
            error "Windows build output must be on D: to protect the constrained system drive; got '$normalized'"
        }
    }
    foreach worktree [bringup_worktrees $repo_root] {
        if {[bringup_paths_overlap $normalized $worktree]} {
            error "output directory and every Git worktree must be disjoint: output='$normalized', conflicting worktree='$worktree'"
        }
    }
}

proc bringup_sha256 {path} {
    if {![file isfile $path]} {
        error "cannot hash absent file: $path"
    }
    if {[catch {exec certutil.exe -hashfile $path SHA256} output]} {
        error "certutil SHA-256 failed for '$path': $output"
    }
    if {![regexp -nocase {([0-9a-f]{64})} $output -> digest]} {
        error "certutil did not return a SHA-256 digest for '$path': $output"
    }
    return [string toupper $digest]
}

proc bringup_read_file {path} {
    set channel [open $path RDONLY]
    try {
        return [read $channel]
    } finally {
        close $channel
    }
}

proc bringup_write_exclusive {path contents} {
    set channel [open $path {WRONLY CREAT EXCL}]
    try {
        puts -nonewline $channel $contents
    } finally {
        close $channel
    }
}

proc bringup_verify_sources {repo_root identity_dir source_hashes} {
    foreach relative_path [dict keys $source_hashes] {
        set expected [dict get $source_hashes $relative_path]
        set current_path [file join $repo_root $relative_path]
        set snapshot_path [file join $identity_dir sources $relative_path]
        set current_hash [bringup_sha256 $current_path]
        set snapshot_hash [bringup_sha256 $snapshot_path]
        if {$current_hash ne $expected || $snapshot_hash ne $expected} {
            error "platform source identity mismatch for $relative_path: expected $expected, current $current_hash, snapshot $snapshot_hash"
        }
    }
}

proc bringup_gate_report {report_path label} {
    if {![file isfile $report_path] || [file size $report_path] == 0} {
        error "$label report is absent or empty: $report_path"
    }
    set report_text [bringup_read_file $report_path]
    if {![regexp -nocase {Checks[ ]+found:[ ]*([0-9]+)} $report_text -> check_count]} {
        error "$label report has no parseable 'Checks found' summary: $report_path"
    }
    if {[regexp -nocase {Critical[[:space:]]+Warning} $report_text]} {
        error "$label report contains a Critical Warning; artifact export is blocked: $report_path"
    }
    if {[regexp -nocase {\mError\M} $report_text]} {
        error "$label report contains an Error; artifact export is blocked: $report_path"
    }
    return $check_count
}

proc bringup_gate_timing_checks {report_path} {
    set report_text [bringup_read_file $report_path]
    set observed [dict create]
    foreach raw_line [split $report_text "\n"] {
        set line [string trim $raw_line]
        if {![regexp {^[0-9]+\.[ ]+checking[ ]+([a-z_]+)[ ]+\(([0-9]+)\)} \
                $line -> check_name check_count]} {
            continue
        }
        if {[dict exists $observed $check_name] &&
            [dict get $observed $check_name] != $check_count} {
            error "timing check '$check_name' has inconsistent counts in $report_path"
        }
        dict set observed $check_name $check_count
    }

    set required_checks {
        no_clock constant_clock pulse_width_clock
        unconstrained_internal_endpoints no_input_delay no_output_delay
        multiple_clock generated_clocks loops partial_input_delay
        partial_output_delay latch_loops
    }
    foreach check_name $required_checks {
        if {![dict exists $observed $check_name]} {
            error "timing summary omitted required check '$check_name': $report_path"
        }
        set count [dict get $observed $check_name]
        if {$count != 0} {
            error "timing check '$check_name' has $count violation(s): $report_path"
        }
    }
    return $observed
}

proc bringup_parse_nonnegative_metric {value label report_path} {
    set token [string trim $value]
    if {![regexp {^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$} $token]} {
        error "$label is missing or non-numeric in $report_path: '$value'"
    }
    if {[catch {set numeric [expr {double($token)}]} conversion_error]} {
        error "$label is not a finite numeric value in $report_path: '$value' ($conversion_error)"
    }
    if {$numeric < 0.0} {
        error "$label is negative in $report_path: $token"
    }
    return $token
}

proc bringup_parse_nonnegative_count {value label report_path} {
    set token [string trim $value]
    if {![regexp {^([0-9]+|[0-9]{1,3}(,[0-9]{3})+)$} $token]} {
        error "$label is missing or is not a nonnegative integer in $report_path: '$value'"
    }
    set normalized [string map {, ""} $token]
    if {[catch {set count [expr {wide($normalized)}]} conversion_error]} {
        error "$label is outside the supported integer range in $report_path: '$value' ($conversion_error)"
    }
    return $count
}

proc bringup_gate_timing_summary {report_path} {
    if {![file isfile $report_path] || [file size $report_path] == 0} {
        error "timing summary report is absent or empty: $report_path"
    }
    set report_text [bringup_read_file $report_path]
    set saw_design_summary 0
    set saw_header 0
    set header_pattern {^WNS\(ns\) TNS\(ns\) TNS Failing Endpoints TNS Total Endpoints WHS\(ns\) THS\(ns\) THS Failing Endpoints THS Total Endpoints WPWS\(ns\) TPWS\(ns\) TPWS Failing Endpoints TPWS Total Endpoints$}

    foreach raw_line [split $report_text "\n"] {
        set line [string trim $raw_line]
        set compact [regsub -all {[ \t]+} $line " "]
        if {!$saw_design_summary} {
            if {[regexp -nocase {Design Timing Summary$} $compact]} {
                set saw_design_summary 1
            }
            continue
        }
        if {!$saw_header} {
            if {[regexp $header_pattern $compact]} {
                set saw_header 1
            }
            continue
        }
        if {$compact eq "" || [string trim $compact " -\t\r"] eq ""} {
            continue
        }

        set fields [regexp -all -inline {\S+} $compact]
        if {[llength $fields] != 12} {
            error "Design Timing Summary row does not contain exactly 12 columns in $report_path: '$line'"
        }
        lassign $fields \
            wns tns setup_failing setup_total \
            whs ths hold_failing hold_total \
            wpws tpws pulse_failing pulse_total

        foreach {variable label} {
            wns WNS tns TNS whs WHS ths THS wpws WPWS tpws TPWS
        } {
            set $variable [bringup_parse_nonnegative_metric [set $variable] $label $report_path]
        }
        foreach {variable label} {
            setup_failing {TNS failing endpoints}
            setup_total   {TNS total endpoints}
            hold_failing  {THS failing endpoints}
            hold_total    {THS total endpoints}
            pulse_failing {TPWS failing endpoints}
            pulse_total   {TPWS total endpoints}
        } {
            set $variable [bringup_parse_nonnegative_count [set $variable] $label $report_path]
        }
        foreach {failing total label} [list \
            $setup_failing $setup_total setup \
            $hold_failing  $hold_total  hold \
            $pulse_failing $pulse_total pulse_width \
        ] {
            if {$failing > $total} {
                error "$label failing endpoint count exceeds its total in $report_path: failing=$failing, total=$total"
            }
            if {$failing != 0} {
                error "$label timing has $failing failing endpoint(s) in $report_path"
            }
        }

        return [dict create \
            wns_ns $wns \
            tns_ns $tns \
            setup_failing_endpoints $setup_failing \
            setup_total_endpoints $setup_total \
            whs_ns $whs \
            ths_ns $ths \
            hold_failing_endpoints $hold_failing \
            hold_total_endpoints $hold_total \
            wpws_ns $wpws \
            tpws_ns $tpws \
            pulse_width_failing_endpoints $pulse_failing \
            pulse_width_total_endpoints $pulse_total \
        ]
    }

    if {!$saw_design_summary} {
        error "timing report omitted the Design Timing Summary section: $report_path"
    }
    if {!$saw_header} {
        error "timing report omitted the 12-column min/max Design Timing Summary header: $report_path"
    }
    error "timing report omitted the 12-column Design Timing Summary data row: $report_path"
}

proc bringup_gate_cdc_report {report_path} {
    if {![file isfile $report_path] || [file size $report_path] == 0} {
        error "CDC report is absent or empty: $report_path"
    }
    set report_text [bringup_read_file $report_path]
    if {![regexp -nocase -line {^[| ]*(Report[ ]+CDC|CDC[ ]+Report)([ ]|$)} $report_text]} {
        error "CDC report omitted its CDC report identity header: $report_path"
    }
    if {[regexp -nocase -line {^[| ]*Critical([ ]|$)} $report_text]} {
        error "CDC report contains a Critical CDC entry: $report_path"
    }

    set summary_header_count 0
    set summary_rows 0
    set endpoint_count 0
    set safe_count 0
    set unsafe_count 0
    set unknown_count 0
    set no_async_reg_count 0
    set in_summary 0
    foreach raw_line [split $report_text "\n"] {
        set compact [regsub -all {[ \t]+} [string trim $raw_line] " "]
        if {[string match {|*} $compact]} {
            set compact [string trim [string range $compact 1 end]]
        }
        if {[regexp -nocase {^Severity Source Clock Destination Clock CDC Type Endpoints Safe Unsafe Unknown No ASYNC_REG$} $compact]} {
            incr summary_header_count
            set in_summary 1
            continue
        }
        if {!$in_summary || $compact eq "" || [string trim $compact " -\t\r"] eq ""} {
            continue
        }
        if {![regexp -nocase {^(Info|Warning|Critical) ([^ ]+) ([^ ]+) (.+) ([0-9][0-9,]*) ([0-9][0-9,]*) ([0-9][0-9,]*) ([0-9][0-9,]*) ([0-9][0-9,]*)$} \
                $compact -> severity source_clock destination_clock cdc_type endpoints safe unsafe unknown no_async_reg]} {
            if {[regexp -nocase {^(Info|Warning|Critical)([ ]|$)} $compact]} {
                error "CDC summary contains an unparseable severity row in $report_path: '$compact'"
            }
            continue
        }
        incr summary_rows
        foreach {variable label} {
            endpoints    {CDC endpoints}
            safe         {safe CDC endpoints}
            unsafe       {unsafe CDC endpoints}
            unknown      {unknown CDC endpoints}
            no_async_reg {CDC synchronizers without ASYNC_REG}
        } {
            set $variable [bringup_parse_nonnegative_count [set $variable] $label $report_path]
        }
        if {$endpoints != ($safe + $unsafe + $unknown)} {
            error "CDC summary endpoint accounting is inconsistent in $report_path: endpoints=$endpoints, safe=$safe, unsafe=$unsafe, unknown=$unknown"
        }
        if {[string equal -nocase $severity "Critical"] || $unsafe != 0 || $unknown != 0} {
            error "CDC acceptance failed in $report_path: severity=$severity, source=$source_clock, destination=$destination_clock, type='$cdc_type', unsafe=$unsafe, unknown=$unknown"
        }
        incr endpoint_count $endpoints
        incr safe_count $safe
        incr unsafe_count $unsafe
        incr unknown_count $unknown
        incr no_async_reg_count $no_async_reg
    }

    set explicit_safe [regexp -nocase {(\mno\M[^\n]*\m(paths|endpoints|crossings)\M|\m0\M[ ]+(CDC[ ]+)?(paths|endpoints|crossings)\M|All[ ]+paths[ ]+are[ ]+Safely[ ]+Timed)} $report_text]
    if {$summary_header_count == 0 && !$explicit_safe} {
        error "CDC report has neither the required clock-pair summary contract nor an explicit safe result: $report_path"
    }
    if {$summary_header_count > 1} {
        error "CDC report contains more than one clock-pair summary header: $report_path"
    }
    if {$summary_header_count == 1 && $summary_rows == 0 && !$explicit_safe} {
        error "CDC clock-pair summary contains no parseable rows and no explicit safe result: $report_path"
    }

    return [dict create \
        summary_rows $summary_rows \
        endpoints $endpoint_count \
        safe_endpoints $safe_count \
        unsafe_endpoints $unsafe_count \
        unknown_endpoints $unknown_count \
        synchronizers_without_async_reg $no_async_reg_count \
    ]
}

if {[llength $argv] < 1 || [llength $argv] > 2} {
    bringup_build_usage
}

set output_dir [file normalize [lindex $argv 0]]
set jobs [expr {[llength $argv] == 2 ? [lindex $argv 1] : 4}]
if {![string is integer -strict $jobs] || $jobs < 1 || $jobs > 32} {
    error "jobs must be an integer from 1 through 32; got '$jobs'"
}

set tool_version_short [version -short]
set tool_version_full [version]
if {![regexp {^2025\.1($|[._-])} $tool_version_short]} {
    error "Vivado 2025.1 is required; got '$tool_version_short'"
}
if {![info exists ::env(TERNARYCORE_BOARD_FILES)] || [string trim $::env(TERNARYCORE_BOARD_FILES)] eq ""} {
    error "TERNARYCORE_BOARD_FILES must be set for a reproducible board-part lookup"
}
set board_repo [file normalize $::env(TERNARYCORE_BOARD_FILES)]
if {![file isdirectory $board_repo]} {
    error "TERNARYCORE_BOARD_FILES is not a directory: $board_repo"
}

set script_dir   [file dirname [file normalize [info script]]]
set repo_root    [file normalize [file join $script_dir ..]]
set identity_dir [file join $output_dir identity]
set manifest     [file join $identity_dir manifest.tcl]
bringup_require_safe_output $output_dir $repo_root
if {![file isdirectory $output_dir]} {
    error "bring-up output does not exist; run create_bringup_platform.tcl first: $output_dir"
}
if {![file isfile [file join $output_dir .create_complete]]} {
    error "create completion marker is absent; never build a partial create attempt: $output_dir"
}
if {![file isfile $manifest]} {
    error "platform identity manifest is absent: $manifest"
}

unset -nocomplain ::zybo_bringup_identity
source $manifest
if {![info exists ::zybo_bringup_identity]} {
    error "identity manifest did not define ::zybo_bringup_identity: $manifest"
}
set identity $::zybo_bringup_identity
foreach required_key {
    schema_version output_dir repo_root repo_commit repo_dirty vivado_version_short
    vivado_version_full board_files_dir board_repo_root board_repo_commit
    board_part part pl_clock_mhz pl_clock_hz clock_module source_sha256
    kv_smoke_enabled kv_ip_repo kv_component_sha256 kv_transport
    kv_m_axi_data_width
    av_diag_enabled av_diag_repo av_diag_component_sha256
    av_m_axi_data_width
    raw_full_enabled raw_full_ip_repo raw_full_component_sha256
    raw_full_m_axi_data_width raw_full_scale_width
    raw_full_qk_mult_style raw_full_av_mult_style raw_full_profile
    raw_e2e_enabled raw_e2e_ip_repo
    raw_e2e_projection_component_sha256 raw_e2e_weight_component_sha256
    canned_page_enabled canned_page_ip_repo
    canned_page_component_sha256 canned_page_scale_bits
    canned_page_qk_mult_style canned_page_av_mult_style
    canned_page_profile canned_page_compiled_profile_id
    canned_page_compiled_k_codebook_id
    canned_page_compiled_v_codebook_id
} {
    if {![dict exists $identity $required_key]} {
        error "identity manifest is missing required key '$required_key'"
    }
}
if {[dict get $identity schema_version] != 2} {
    error "unsupported platform identity schema: [dict get $identity schema_version]"
}
set identity_kv_enabled [dict get $identity kv_smoke_enabled]
set identity_kv_transport [dict get $identity kv_transport]
set identity_kv_width [dict get $identity kv_m_axi_data_width]
if {$identity_kv_enabled} {
    switch -exact -- $identity_kv_transport {
        HP64_NATIVE {
            if {$identity_kv_width != 64} {
                error "HP64_NATIVE identity requires kv_m_axi_data_width=64; got $identity_kv_width"
            }
        }
        INTERNAL128_TO_HP64 {
            if {$identity_kv_width != 128} {
                error "INTERNAL128_TO_HP64 identity requires kv_m_axi_data_width=128; got $identity_kv_width"
            }
        }
        default {
            error "enabled KV identity has unsupported transport '$identity_kv_transport'"
        }
    }
} elseif {$identity_kv_transport ne "NONE" || $identity_kv_width != 0} {
    error "disabled KV identity must use transport NONE and width 0"
}
set identity_av_diag_enabled [dict get $identity av_diag_enabled]
set identity_av_diag_repo [dict get $identity av_diag_repo]
set identity_av_diag_sha256 [dict get $identity av_diag_component_sha256]
set identity_av_diag_width [dict get $identity av_m_axi_data_width]
if {$identity_av_diag_enabled} {
    if {!$identity_kv_enabled} {
        error "enabled AV diagnostic identity requires the preserved KV M02/S01 topology"
    }
    if {[string trim $identity_av_diag_repo] eq ""} {
        error "enabled AV diagnostic identity has an empty IP repository"
    }
    if {![regexp {^[0-9A-F]{64}$} $identity_av_diag_sha256]} {
        error "enabled AV diagnostic identity has an invalid component SHA-256: '$identity_av_diag_sha256'"
    }
    if {$identity_av_diag_width != 64} {
        error "enabled AV diagnostic identity requires av_m_axi_data_width=64; got $identity_av_diag_width"
    }
} elseif {$identity_av_diag_repo ne "" || $identity_av_diag_sha256 ne "" ||
          $identity_av_diag_width != 0} {
    error "disabled AV diagnostic identity must use empty repo/hash and width 0"
}
set identity_raw_full_enabled [dict get $identity raw_full_enabled]
set identity_raw_full_repo [dict get $identity raw_full_ip_repo]
set identity_raw_full_sha256 [dict get $identity raw_full_component_sha256]
set identity_raw_full_width [dict get $identity raw_full_m_axi_data_width]
set identity_raw_full_scale [dict get $identity raw_full_scale_width]
set identity_raw_full_qk_style [dict get $identity raw_full_qk_mult_style]
set identity_raw_full_av_style [dict get $identity raw_full_av_mult_style]
set identity_raw_full_profile [dict get $identity raw_full_profile]
if {$identity_raw_full_enabled} {
    if {$identity_kv_enabled || $identity_av_diag_enabled} {
        error "enabled raw-full identity cannot coexist with KV or AV diagnostic modes"
    }
    if {[string trim $identity_raw_full_repo] eq ""} {
        error "enabled raw-full identity has an empty IP repository"
    }
    if {![regexp {^[0-9A-F]{64}$} $identity_raw_full_sha256]} {
        error "enabled raw-full identity has an invalid component SHA-256: '$identity_raw_full_sha256'"
    }
    if {$identity_raw_full_width ni {64 128} ||
        $identity_raw_full_scale ni {12 16} ||
        $identity_raw_full_qk_style != 2 ||
        $identity_raw_full_av_style ni {1 2}} {
        error "invalid raw-full width/scale/styles: width=$identity_raw_full_width scale=$identity_raw_full_scale QK=$identity_raw_full_qk_style AV=$identity_raw_full_av_style"
    }
    set derived_raw_full_profile [expr {$identity_raw_full_av_style == 1 ?
        "LUT_RELIEF" : "BALANCED"}]
    if {$identity_raw_full_profile ne $derived_raw_full_profile} {
        error "raw-full profile '$identity_raw_full_profile' does not match QK/AV styles $identity_raw_full_qk_style/$identity_raw_full_av_style"
    }
} elseif {$identity_raw_full_repo ne "" || $identity_raw_full_sha256 ne "" ||
          $identity_raw_full_width != 0 || $identity_raw_full_scale != 0 ||
          $identity_raw_full_qk_style != 0 || $identity_raw_full_av_style != 0 ||
          $identity_raw_full_profile ne "NONE"} {
    error "disabled raw-full identity must use empty repo/hash, zero width/scale/styles, and profile NONE"
}
set identity_raw_e2e_enabled [dict get $identity raw_e2e_enabled]
set identity_raw_e2e_repo [dict get $identity raw_e2e_ip_repo]
set identity_raw_e2e_projection_sha [dict get $identity raw_e2e_projection_component_sha256]
set identity_raw_e2e_weight_sha [dict get $identity raw_e2e_weight_component_sha256]
if {$identity_raw_e2e_enabled} {
    if {!$identity_raw_full_enabled || $identity_raw_full_width != 64 ||
        $identity_raw_full_scale != 12 || $identity_raw_full_qk_style != 2 ||
        $identity_raw_full_av_style != 1 || $identity_raw_full_profile ne "LUT_RELIEF"} {
        error "RAW-E2E identity requires RAW_FULL HP64/SCALE12/LUT_RELIEF QK=2 AV=1"
    }
    if {[string trim $identity_raw_e2e_repo] eq "" ||
        ![regexp {^[0-9A-F]{64}$} $identity_raw_e2e_projection_sha] ||
        ![regexp {^[0-9A-F]{64}$} $identity_raw_e2e_weight_sha]} {
        error "RAW-E2E identity has an empty repo or invalid component SHA-256"
    }
} elseif {$identity_raw_e2e_repo ne "" || $identity_raw_e2e_projection_sha ne "" ||
          $identity_raw_e2e_weight_sha ne ""} {
    error "disabled RAW-E2E identity must use empty repo and hashes"
}
set identity_canned_enabled [dict get $identity canned_page_enabled]
set identity_canned_repo [dict get $identity canned_page_ip_repo]
set identity_canned_sha256 [dict get $identity canned_page_component_sha256]
set identity_canned_scale [dict get $identity canned_page_scale_bits]
set identity_canned_qk_style [dict get $identity canned_page_qk_mult_style]
set identity_canned_av_style [dict get $identity canned_page_av_mult_style]
set identity_canned_profile [dict get $identity canned_page_profile]
set identity_canned_compiled_profile \
    [dict get $identity canned_page_compiled_profile_id]
set identity_canned_compiled_k_codebook \
    [dict get $identity canned_page_compiled_k_codebook_id]
set identity_canned_compiled_v_codebook \
    [dict get $identity canned_page_compiled_v_codebook_id]
if {$identity_canned_enabled} {
    if {$identity_kv_enabled || $identity_av_diag_enabled ||
        $identity_raw_full_enabled} {
        error "enabled canned-page identity cannot coexist with KV, AV, or raw-full diagnostic modes"
    }
    if {[string trim $identity_canned_repo] eq ""} {
        error "enabled canned-page identity has an empty IP repository"
    }
    if {![regexp {^[0-9A-F]{64}$} $identity_canned_sha256]} {
        error "enabled canned-page identity has an invalid component SHA-256: '$identity_canned_sha256'"
    }
    if {$identity_canned_scale ni {12 16} ||
        $identity_canned_qk_style != 2 ||
        $identity_canned_av_style ni {1 2}} {
        error "invalid canned-page scale/styles: scale=$identity_canned_scale QK=$identity_canned_qk_style AV=$identity_canned_av_style"
    }
    set derived_canned_profile [expr {$identity_canned_av_style == 1 ?
        "LUT_RELIEF" : "BALANCED"}]
    if {$identity_canned_profile ne $derived_canned_profile} {
        error "canned-page profile '$identity_canned_profile' does not match QK/AV styles $identity_canned_qk_style/$identity_canned_av_style"
    }
    if {$identity_canned_compiled_profile != 51 ||
        $identity_canned_compiled_k_codebook != 1 ||
        $identity_canned_compiled_v_codebook != 2} {
        error "invalid canned-page compiled IDs: profile=$identity_canned_compiled_profile K=$identity_canned_compiled_k_codebook V=$identity_canned_compiled_v_codebook"
    }
} elseif {$identity_canned_repo ne "" || $identity_canned_sha256 ne "" ||
          $identity_canned_scale != 0 || $identity_canned_qk_style != 0 ||
          $identity_canned_av_style != 0 ||
          $identity_canned_profile ne "NONE" ||
          $identity_canned_compiled_profile != 0 ||
          $identity_canned_compiled_k_codebook != 0 ||
          $identity_canned_compiled_v_codebook != 0} {
    error "disabled canned-page identity must use empty repo/hash, zero scale/styles/compiled IDs, and profile NONE"
}
if {![bringup_paths_equal [dict get $identity output_dir] $output_dir]} {
    error "identity output path does not match requested output: '[dict get $identity output_dir]' versus '$output_dir'"
}
if {![bringup_paths_equal [dict get $identity repo_root] $repo_root]} {
    error "identity repository does not match the executing worktree"
}
set repo_commit [bringup_git $repo_root rev-parse HEAD]
if {$repo_commit ne [dict get $identity repo_commit]} {
    error "repository HEAD changed after create: expected [dict get $identity repo_commit], got $repo_commit"
}
if {[dict get $identity vivado_version_short] ne $tool_version_short ||
    [dict get $identity vivado_version_full] ne $tool_version_full} {
    error "Vivado version differs from create identity; create='[dict get $identity vivado_version_short]/[dict get $identity vivado_version_full]', build='$tool_version_short/$tool_version_full'"
}
if {![bringup_paths_equal [dict get $identity board_files_dir] $board_repo]} {
    error "TERNARYCORE_BOARD_FILES differs from create identity"
}
set board_repo_root [file normalize [bringup_git $board_repo rev-parse --show-toplevel]]
if {![bringup_paths_equal [dict get $identity board_repo_root] $board_repo_root]} {
    error "Digilent board repository root differs from create identity"
}
set board_repo_commit [bringup_git $board_repo_root rev-parse HEAD]
set pinned_board_repo_commit "36f34ab687b7fa9c778b779d027f3bce63b3ace9"
if {[dict get $identity board_repo_commit] ne $pinned_board_repo_commit} {
    error "create identity did not use pinned Digilent commit $pinned_board_repo_commit"
}
if {$board_repo_commit ne [dict get $identity board_repo_commit]} {
    error "Digilent board repository commit changed: expected [dict get $identity board_repo_commit], got $board_repo_commit"
}
set board_repo_status [bringup_git $board_repo_root status --porcelain=v1 --untracked-files=all]
if {$board_repo_status ne ""} {
    error "Digilent board repository became dirty after create:\n$board_repo_status"
}
bringup_verify_sources $repo_root $identity_dir [dict get $identity source_sha256]
if {[dict get $identity kv_smoke_enabled]} {
    set kv_ip_repo [file normalize [dict get $identity kv_ip_repo]]
    set kv_component [file join $kv_ip_repo axi_kv_cache component.xml]
    if {![file isfile $kv_component]} {
        error "recorded KV IP component is absent: $kv_component"
    }
    set actual_kv_component_sha256 [bringup_sha256 $kv_component]
    if {$actual_kv_component_sha256 ne [dict get $identity kv_component_sha256]} {
        error "KV IP component changed after create: expected [dict get $identity kv_component_sha256], got $actual_kv_component_sha256"
    }
}
if {[dict get $identity av_diag_enabled]} {
    set av_diag_repo [file normalize [dict get $identity av_diag_repo]]
    set av_diag_component [file join $av_diag_repo axi_v5_av_diag component.xml]
    if {![file isfile $av_diag_component]} {
        error "recorded AV diagnostic IP component is absent: $av_diag_component"
    }
    set actual_av_diag_component_sha256 [bringup_sha256 $av_diag_component]
    if {$actual_av_diag_component_sha256 ne \
        [dict get $identity av_diag_component_sha256]} {
        error "AV diagnostic IP component changed after create: expected [dict get $identity av_diag_component_sha256], got $actual_av_diag_component_sha256"
    }
}
if {[dict get $identity raw_full_enabled]} {
    set raw_full_repo [file normalize [dict get $identity raw_full_ip_repo]]
    set raw_full_component \
        [file join $raw_full_repo axi_kvq_raw_full_diag component.xml]
    if {![file isfile $raw_full_component]} {
        error "recorded raw-full IP component is absent: $raw_full_component"
    }
    set actual_raw_full_component_sha256 [bringup_sha256 $raw_full_component]
    if {$actual_raw_full_component_sha256 ne \
        [dict get $identity raw_full_component_sha256]} {
        error "raw-full IP component changed after create: expected [dict get $identity raw_full_component_sha256], got $actual_raw_full_component_sha256"
    }
}
if {[dict get $identity raw_e2e_enabled]} {
    set raw_e2e_repo [file normalize [dict get $identity raw_e2e_ip_repo]]
    foreach {relative expected label} [list \
        {axi_gemm_stream/component.xml} [dict get $identity raw_e2e_projection_component_sha256] projection \
        {weight_bram128/component.xml} [dict get $identity raw_e2e_weight_component_sha256] weight] {
        set component [file join $raw_e2e_repo {*}[split $relative /]]
        if {![file isfile $component]} { error "recorded RAW-E2E $label component absent: $component" }
        set actual [bringup_sha256 $component]
        if {$actual ne $expected} { error "RAW-E2E $label component changed: expected $expected got $actual" }
    }
}
if {[dict get $identity canned_page_enabled]} {
    set canned_page_repo \
        [file normalize [dict get $identity canned_page_ip_repo]]
    set canned_page_component \
        [file join $canned_page_repo axi_kvq_canned_page_diag component.xml]
    if {![file isfile $canned_page_component]} {
        error "recorded canned-page IP component is absent: $canned_page_component"
    }
    set actual_canned_page_component_sha256 \
        [bringup_sha256 $canned_page_component]
    if {$actual_canned_page_component_sha256 ne \
        [dict get $identity canned_page_component_sha256]} {
        error "canned-page IP component changed after create: expected [dict get $identity canned_page_component_sha256], got $actual_canned_page_component_sha256"
    }
}

set project_xpr [file join $output_dir project zybo_bringup.xpr]
set reports_dir [file join $output_dir reports]
set artifacts_dir [file join $output_dir artifacts]
set started_marker [file join $output_dir .build_started]
if {![file isfile $project_xpr]} {
    error "bring-up project does not exist: $project_xpr"
}
foreach forbidden_path [list $started_marker [file join $output_dir .build_complete] $reports_dir $artifacts_dir] {
    if {[file exists $forbidden_path]} {
        error "build output is one-shot and must be fresh; path already exists: $forbidden_path"
    }
}
bringup_write_exclusive $started_marker \
    "started_utc=[clock format [clock seconds] -gmt true -format {%Y-%m-%dT%H:%M:%SZ}]\n"
file mkdir $reports_dir
file mkdir $artifacts_dir
cd $output_dir

set_param board.repoPaths [list $board_repo]
set board_part [dict get $identity board_part]
set board_matches [get_board_parts -quiet $board_part]
if {[llength $board_matches] != 1} {
    error "expected board part $board_part exactly once under $board_repo; got: $board_matches"
}

open_project $project_xpr
set optional_ip_repos {}
if {[dict get $identity kv_smoke_enabled]} {
    lappend optional_ip_repos [dict get $identity kv_ip_repo]
}
if {[dict get $identity av_diag_enabled] &&
    [lsearch -exact $optional_ip_repos [dict get $identity av_diag_repo]] < 0} {
    lappend optional_ip_repos [dict get $identity av_diag_repo]
}
if {[dict get $identity raw_full_enabled]} {
    lappend optional_ip_repos [dict get $identity raw_full_ip_repo]
}
if {[dict get $identity canned_page_enabled]} {
    lappend optional_ip_repos [dict get $identity canned_page_ip_repo]
}
if {[dict get $identity raw_e2e_enabled]} {
    lappend optional_ip_repos [dict get $identity raw_e2e_ip_repo]
}
if {[llength $optional_ip_repos] > 0} {
    set_property ip_repo_paths $optional_ip_repos [current_project]
    update_ip_catalog -rebuild
}
if {[dict get $identity kv_smoke_enabled]} {
    set kv_defs [get_ipdefs -quiet shepherdscientific.com:user:axi_kv_cache:2.0]
    if {[llength $kv_defs] != 1} {
        error "build catalog expected one axi_kv_cache:2.0 definition; got: $kv_defs"
    }
}
if {[dict get $identity av_diag_enabled]} {
    set av_diag_defs [get_ipdefs -quiet shepherdscientific.com:user:axi_v5_av_diag:1.0]
    if {[llength $av_diag_defs] != 1} {
        error "build catalog expected one axi_v5_av_diag:1.0 definition; got: $av_diag_defs"
    }
}
if {[dict get $identity raw_full_enabled]} {
    set raw_full_defs \
        [get_ipdefs -quiet shepherdscientific.com:user:axi_kvq_raw_full_diag:1.0]
    if {[llength $raw_full_defs] != 1} {
        error "build catalog expected one axi_kvq_raw_full_diag:1.0 definition; got: $raw_full_defs"
    }
}
if {[dict get $identity canned_page_enabled]} {
    set canned_page_defs [get_ipdefs -quiet \
        shepherdscientific.com:user:axi_kvq_canned_page_diag:1.0]
    if {[llength $canned_page_defs] != 1} {
        error "build catalog expected one axi_kvq_canned_page_diag:1.0 definition; got: $canned_page_defs"
    }
}
if {[dict get $identity raw_e2e_enabled]} {
    foreach vlnv {shepherdscientific.com:user:axi_gemm_stream:1.0 shepherdscientific.com:user:weight_bram128:1.0} {
        if {[llength [get_ipdefs -quiet $vlnv]] != 1} { error "build catalog missing RAW-E2E IP $vlnv" }
    }
}
set bd_file [get_files -quiet zybo_bringup.bd]
if {[llength $bd_file] != 1} {
    error "project must contain exactly one zybo_bringup.bd; got: $bd_file"
}
open_bd_design $bd_file
set pl_clock_mhz [dict get $identity pl_clock_mhz]
validate_bd_design
    source [file join $script_dir assert_bringup_platform.tcl]
    if {[catch {assert_bringup_platform $pl_clock_mhz \
            [dict get $identity kv_m_axi_data_width] \
            [dict get $identity av_m_axi_data_width] \
            [dict get $identity raw_full_m_axi_data_width] \
            [dict get $identity raw_full_scale_width] \
             [dict get $identity raw_full_qk_mult_style] \
             [dict get $identity raw_full_av_mult_style] \
             [dict get $identity raw_full_profile] \
             [dict get $identity canned_page_scale_bits] \
             [dict get $identity canned_page_qk_mult_style] \
             [dict get $identity canned_page_av_mult_style] \
             [dict get $identity canned_page_profile] \
             [dict get $identity canned_page_compiled_profile_id] \
             [dict get $identity canned_page_compiled_k_codebook_id] \
             [dict get $identity canned_page_compiled_v_codebook_id]} \
        assertion_message assertion_options]} {
    puts stderr "ZYBO BRING-UP ASSERTION ERROR: $assertion_message"
    if {[dict exists $assertion_options -errorinfo]} {
        puts stderr [dict get $assertion_options -errorinfo]
    }
    return -options $assertion_options $assertion_message
}
save_bd_design
generate_target all $bd_file
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
set synth_progress [get_property PROGRESS [get_runs synth_1]]
if {$synth_progress ne "100%" || ![string match "*Complete*" $synth_status]} {
    error "synthesis failed or did not complete: status='$synth_status', progress='$synth_progress'"
}

reset_run impl_1
set impl_strategy Default
if {[dict get $identity canned_page_enabled]} {
    set impl_strategy Performance_ExplorePostRoutePhysOpt
    set_property strategy $impl_strategy [get_runs impl_1]
}
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
set impl_progress [get_property PROGRESS [get_runs impl_1]]
if {$impl_progress ne "100%" || ![string match "*Complete*" $impl_status]} {
    error "implementation/bitstream failed or did not complete: status='$impl_status', progress='$impl_progress'"
}

open_run impl_1
set timing_report [file join $reports_dir timing_summary.rpt]
set utilization_report [file join $reports_dir utilization.rpt]
set hierarchical_utilization_report [file join $reports_dir hierarchical_utilization.rpt]
set critical_paths_report [file join $reports_dir critical_paths.rpt]
set clock_report [file join $reports_dir clock_utilization.rpt]
set drc_report [file join $reports_dir drc.rpt]
set methodology_report [file join $reports_dir methodology.rpt]
set cdc_report [file join $reports_dir cdc.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -max_paths 20 -file $timing_report
report_utilization -hierarchical -file $utilization_report
report_utilization -hierarchical -hierarchical_depth 6 -file $hierarchical_utilization_report
report_timing -delay_type max -max_paths 100 -nworst 10 -sort_by group -file $critical_paths_report
report_clock_utilization -file $clock_report
report_drc -file $drc_report
report_methodology -file $methodology_report
report_cdc -details -no_waiver -file $cdc_report

set drc_checks [bringup_gate_report $drc_report "DRC"]
set methodology_checks [bringup_gate_report $methodology_report "methodology"]
set timing_checks [bringup_gate_timing_checks $timing_report]
set timing_summary [bringup_gate_timing_summary $timing_report]
set cdc_summary [bringup_gate_cdc_report $cdc_report]
foreach metric {wns_ns tns_ns whs_ns ths_ns wpws_ns tpws_ns} {
    set $metric [dict get $timing_summary $metric]
}

bringup_verify_sources $repo_root $identity_dir [dict get $identity source_sha256]

set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set bitstreams [glob -nocomplain -directory $impl_dir *.bit]
if {[llength $bitstreams] != 1} {
    error "expected exactly one implementation bitstream in $impl_dir; got: $bitstreams"
}
set freq_tag [string map {. p} [format "%.3f" $pl_clock_mhz]]
set bit_out [file join $artifacts_dir zybo_bringup_${freq_tag}MHz.bit]
set xsa_out [file join $artifacts_dir zybo_bringup_${freq_tag}MHz.xsa]
set ps7_init_candidates [glob -nocomplain -types f \
    [file join $output_dir project *.gen sources_1 bd * ip * ps7_init.tcl]]
if {[llength $ps7_init_candidates] != 1} {
    error "expected exactly one generated ps7_init.tcl; got: $ps7_init_candidates"
}
set ps7_init_out [file join $artifacts_dir ps7_init.tcl]
file copy [lindex $bitstreams 0] $bit_out
file copy [lindex $ps7_init_candidates 0] $ps7_init_out
write_hw_platform -fixed -include_bit $xsa_out

foreach artifact [list $bit_out $xsa_out $ps7_init_out] {
    if {![file isfile $artifact] || [file size $artifact] == 0} {
        error "required output artifact is absent or empty: $artifact"
    }
}

set evidence_files [dict create \
    "artifacts/[file tail $bit_out]" $bit_out \
    "artifacts/[file tail $xsa_out]" $xsa_out \
    "artifacts/ps7_init.tcl" $ps7_init_out \
    "reports/timing_summary.rpt" $timing_report \
    "reports/utilization.rpt" $utilization_report \
    "reports/hierarchical_utilization.rpt" $hierarchical_utilization_report \
    "reports/critical_paths.rpt" $critical_paths_report \
    "reports/clock_utilization.rpt" $clock_report \
    "reports/drc.rpt" $drc_report \
    "reports/methodology.rpt" $methodology_report \
    "reports/cdc.rpt" $cdc_report \
    "identity/manifest.tcl" $manifest \
]
set evidence_hashes [dict create]
set checksum_lines {}
foreach relative_path [lsort [dict keys $evidence_files]] {
    set digest [bringup_sha256 [dict get $evidence_files $relative_path]]
    dict set evidence_hashes $relative_path $digest
    lappend checksum_lines "$digest  $relative_path"
}
bringup_write_exclusive [file join $artifacts_dir SHA256SUMS.txt] \
    "[join $checksum_lines "\n"]\n"

set build_result [dict create \
    schema_version       3 \
    completed_utc        [clock format [clock seconds] -gmt true -format {%Y-%m-%dT%H:%M:%SZ}] \
    vivado_version_short $tool_version_short \
    vivado_version_full  $tool_version_full \
    board_repo_commit    $board_repo_commit \
    repo_commit          $repo_commit \
    repo_dirty           [dict get $identity repo_dirty] \
    source_sha256        [dict get $identity source_sha256] \
    part                 [dict get $identity part] \
    board_part           $board_part \
    implementation_strategy $impl_strategy \
    pl_clock_mhz         $pl_clock_mhz \
    pl_clock_hz          [dict get $identity pl_clock_hz] \
    clock_module         [dict get $identity clock_module] \
    kv_smoke_enabled     [dict get $identity kv_smoke_enabled] \
    kv_ip_repo           [dict get $identity kv_ip_repo] \
    kv_component_sha256  [dict get $identity kv_component_sha256] \
    kv_transport         [dict get $identity kv_transport] \
    kv_m_axi_data_width  [dict get $identity kv_m_axi_data_width] \
    av_diag_enabled      [dict get $identity av_diag_enabled] \
    av_diag_repo         [dict get $identity av_diag_repo] \
    av_diag_component_sha256 [dict get $identity av_diag_component_sha256] \
    av_m_axi_data_width  [dict get $identity av_m_axi_data_width] \
    raw_full_enabled     [dict get $identity raw_full_enabled] \
    raw_full_ip_repo     [dict get $identity raw_full_ip_repo] \
    raw_full_component_sha256 [dict get $identity raw_full_component_sha256] \
    raw_full_m_axi_data_width [dict get $identity raw_full_m_axi_data_width] \
    raw_full_scale_width [dict get $identity raw_full_scale_width] \
    raw_full_qk_mult_style [dict get $identity raw_full_qk_mult_style] \
    raw_full_av_mult_style [dict get $identity raw_full_av_mult_style] \
    raw_full_profile     [dict get $identity raw_full_profile] \
    raw_e2e_enabled      [dict get $identity raw_e2e_enabled] \
    raw_e2e_ip_repo      [dict get $identity raw_e2e_ip_repo] \
    raw_e2e_projection_component_sha256 [dict get $identity raw_e2e_projection_component_sha256] \
    raw_e2e_weight_component_sha256 [dict get $identity raw_e2e_weight_component_sha256] \
    canned_page_enabled  [dict get $identity canned_page_enabled] \
    canned_page_ip_repo  [dict get $identity canned_page_ip_repo] \
    canned_page_component_sha256 [dict get $identity canned_page_component_sha256] \
    canned_page_scale_bits [dict get $identity canned_page_scale_bits] \
    canned_page_qk_mult_style [dict get $identity canned_page_qk_mult_style] \
    canned_page_av_mult_style [dict get $identity canned_page_av_mult_style] \
    canned_page_profile  [dict get $identity canned_page_profile] \
    canned_page_compiled_profile_id [dict get $identity canned_page_compiled_profile_id] \
    canned_page_compiled_k_codebook_id [dict get $identity canned_page_compiled_k_codebook_id] \
    canned_page_compiled_v_codebook_id [dict get $identity canned_page_compiled_v_codebook_id] \
    wns_ns               $wns_ns \
    whs_ns               $whs_ns \
    tns_ns               $tns_ns \
    ths_ns               $ths_ns \
    wpws_ns              $wpws_ns \
    tpws_ns              $tpws_ns \
    setup_failing_endpoints [dict get $timing_summary setup_failing_endpoints] \
    setup_total_endpoints [dict get $timing_summary setup_total_endpoints] \
    hold_failing_endpoints [dict get $timing_summary hold_failing_endpoints] \
    hold_total_endpoints [dict get $timing_summary hold_total_endpoints] \
    pulse_width_failing_endpoints [dict get $timing_summary pulse_width_failing_endpoints] \
    pulse_width_total_endpoints [dict get $timing_summary pulse_width_total_endpoints] \
    timing_checks        $timing_checks \
    cdc_summary          $cdc_summary \
    drc_checks           $drc_checks \
    methodology_checks   $methodology_checks \
    evidence_sha256      $evidence_hashes \
]
bringup_write_exclusive [file join $artifacts_dir build_result.tcl] \
    "[list set ::zybo_bringup_build_result $build_result]\n"
close_project

bringup_write_exclusive [file join $output_dir .build_complete] \
    "completed_utc=[dict get $build_result completed_utc]\n"
puts [format "BUILT temporary Zybo bring-up platform at %.3f MHz" $pl_clock_mhz]
puts "Timing: WNS=$wns_ns ns, WHS=$whs_ns ns, TNS=$tns_ns ns, THS=$ths_ns ns, WPWS=$wpws_ns ns, TPWS=$tpws_ns ns"
puts "CDC: [dict get $cdc_summary endpoints] endpoint(s), [dict get $cdc_summary unsafe_endpoints] unsafe, [dict get $cdc_summary unknown_endpoints] unknown"
puts "DRC checks=$drc_checks; methodology checks=$methodology_checks; no Error/Critical Warning severities"
puts "Bitstream: $bit_out"
puts "Fixed XSA with bitstream: $xsa_out"
puts "This is transport bring-up only; it is not the final KVQ topology."
puts "ZYBO_PLATFORM_BUILD_PASS"
