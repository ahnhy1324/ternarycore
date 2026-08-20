# Portable Vivado 2025.1 synthesis and routed OOC sweep for KV v0.3 blocks.
# SPDX-License-Identifier: CERN-OHL-S-2.0
#
# This is intentionally separate from the frozen scripts under
# analysis/kv_validation.  It requires an explicit target part and writes all
# generated evidence outside the repository.
#
# Usage:
# Vivado opens its process log and journal before this Tcl script starts.  Put
# both at explicit external paths and archive them with OUT_DIR; do not use
# -nolog/-nojournal for evidence runs.  For example:
#   vivado -mode batch \
#     -log D:/tc-logs/kv-v03-zybo.log \
#     -journal D:/tc-logs/kv-v03-zybo.jou \
#     -source synth/run_vivado_v03_blocks_portable.tcl \
#     -tclargs REPO_ROOT OUT_DIR PART ?CONFIG_FILTERS?
#
# CONFIG_FILTERS is an optional plus-separated list, for example:
#   decoder_4x1+qk_k4_auto+softmax_engine+av_v5_auto

proc portable_compare_path {path} {
    set normalized [string trimright \
        [string map {\\ /} [file normalize $path]] "/"]
    if {$::tcl_platform(platform) eq "windows"} {
        set normalized [string tolower $normalized]
    }
    return $normalized
}

proc portable_path_is_within {candidate root} {
    set candidate_cmp [portable_compare_path $candidate]
    set root_cmp [portable_compare_path $root]
    return [expr {$candidate_cmp eq $root_cmp ||
                  [string first "${root_cmp}/" $candidate_cmp] == 0}]
}

proc portable_directory_entries {directory} {
    if {![file isdirectory $directory]} {
        return {}
    }
    set result {}
    foreach entry [glob -nocomplain -tails -directory $directory * .*] {
        if {$entry ni {. ..}} {
            lappend result $entry
        }
    }
    return [lsort -unique $result]
}

proc portable_read_file {path} {
    set handle [open $path r]
    try {
        return [read $handle]
    } finally {
        close $handle
    }
}

proc portable_gate_drc_report {path} {
    if {![file isfile $path] || [file size $path] == 0} {
        error "routed DRC report is absent or empty: $path"
    }
    set design_state ""
    foreach raw_line [split [portable_read_file $path] "\n"] {
        set line [string trim $raw_line]
        if {[regexp -nocase {^\|[ ]*Design State[ ]*:[ ]*(.+)$} \
                $line -> observed_state]} {
            set observed_state [string trim $observed_state " |\t"]
            if {$design_state ne "" &&
                ![string equal -nocase $design_state $observed_state]} {
                error "routed DRC report contains inconsistent design states: $path"
            }
            set design_state $observed_state
        }
        if {[regexp -nocase {^\|[^|]*\|[ ]*(Critical Warning|Error)[ ]*\|} \
                $line -> severity] ||
            [regexp -nocase {^[A-Za-z0-9_-]+#[0-9]+[ ]+(Critical Warning|Error)$} \
                $line -> severity]} {
            error "routed DRC report contains $severity severity: $path"
        }
    }
    if {$design_state eq ""} {
        error "routed DRC report omitted its design state: $path"
    }
    if {![string equal -nocase $design_state "Fully Routed"]} {
        error "routed DRC report design state is '$design_state', not 'Fully Routed': $path"
    }
    return $design_state
}

proc portable_gate_route_status {report_text} {
    set observed [dict create]
    foreach raw_line [split $report_text "\n"] {
        set line [string trim $raw_line]
        foreach {metric pattern} {
            routable_nets {^# of routable nets[^:]*:[ ]*([0-9,]+)[ ]*:$}
            fully_routed_nets {^# of fully routed nets[^:]*:[ ]*([0-9,]+)[ ]*:$}
            routing_error_nets {^# of nets with routing errors[^:]*:[ ]*([0-9,]+)[ ]*:$}
        } {
            if {[regexp -nocase $pattern $line -> count_text]} {
                set count_text [string map {, ""} $count_text]
                if {![string is integer -strict $count_text] || $count_text < 0} {
                    error "route-status metric '$metric' is not a nonnegative integer: '$count_text'"
                }
                if {[dict exists $observed $metric] &&
                    [dict get $observed $metric] != $count_text} {
                    error "route-status metric '$metric' has inconsistent counts"
                }
                dict set observed $metric $count_text
            }
        }
    }
    foreach metric {routable_nets fully_routed_nets routing_error_nets} {
        if {![dict exists $observed $metric]} {
            error "report_route_status omitted required metric '$metric'"
        }
    }
    if {[dict get $observed routing_error_nets] != 0} {
        error "[dict get $observed routing_error_nets] nets have routing errors"
    }
    if {[dict get $observed routable_nets] !=
        [dict get $observed fully_routed_nets]} {
        error "only [dict get $observed fully_routed_nets] of [dict get $observed routable_nets] routable nets are fully routed"
    }
    return $observed
}

proc portable_gate_timing_summary {path} {
    if {![file isfile $path] || [file size $path] == 0} {
        error "routed timing summary is absent or empty: $path"
    }
    set lines [split [portable_read_file $path] "\n"]
    set header_indexes {}
    for {set index 0} {$index < [llength $lines]} {incr index} {
        set line [lindex $lines $index]
        if {[regexp {^[ \t]*WNS\(ns\)} $line] &&
            [string first "WHS(ns)" $line] >= 0 &&
            [string first "WPWS(ns)" $line] >= 0 &&
            [string first "TPWS(ns)" $line] >= 0} {
            lappend header_indexes $index
        }
    }
    if {[llength $header_indexes] != 1} {
        error "routed timing summary must contain exactly one min/max design-summary header; found [llength $header_indexes]: $path"
    }

    set data_tokens {}
    for {set index [expr {[lindex $header_indexes 0] + 1}]} \
            {$index < [llength $lines]} {incr index} {
        set line [string trim [lindex $lines $index]]
        if {$line eq "" || [regexp {^[- ]+$} $line]} {
            continue
        }
        set data_tokens [regexp -all -inline {\S+} $line]
        break
    }
    if {[llength $data_tokens] != 12} {
        error "routed timing summary data row must contain 12 fields; got [llength $data_tokens]: $path"
    }

    set result [dict create]
    foreach {metric token_index} {
        wns_ns 0 tns_ns 1 whs_ns 4 ths_ns 5 wpws_ns 8 tpws_ns 9
    } {
        set value [lindex $data_tokens $token_index]
        if {![string is double -strict $value]} {
            error "routed timing metric '$metric' is missing or non-numeric ('$value'): $path"
        }
        if {double($value) < 0.0} {
            error "routed timing metric '$metric' is negative ($value): $path"
        }
        dict set result $metric $value
    }
    foreach {metric token_index} {
        setup_failing_endpoints 2 setup_total_endpoints 3
        hold_failing_endpoints 6 hold_total_endpoints 7
        pulse_width_failing_endpoints 10 pulse_width_total_endpoints 11
    } {
        set value [lindex $data_tokens $token_index]
        if {![string is integer -strict $value] || $value < 0} {
            error "routed timing endpoint metric '$metric' is missing or invalid ('$value'): $path"
        }
        dict set result $metric $value
    }
    foreach metric {
        setup_failing_endpoints hold_failing_endpoints
        pulse_width_failing_endpoints
    } {
        if {[dict get $result $metric] != 0} {
            error "routed timing metric '$metric' is [dict get $result $metric], not zero: $path"
        }
    }
    return $result
}

proc portable_gate_ooc_timing_checks {path} {
    set observed [dict create]
    foreach raw_line [split [portable_read_file $path] "\n"] {
        set line [string trim $raw_line]
        if {[regexp {^[0-9]+\.[ ]+checking[ ]+(no_clock|unconstrained_internal_endpoints)[ ]+\(([0-9]+)\)} \
                $line -> check_name check_count]} {
            if {[dict exists $observed $check_name] &&
                [dict get $observed $check_name] != $check_count} {
                error "OOC timing check '$check_name' has inconsistent counts in $path"
            }
            dict set observed $check_name $check_count
        }
    }
    foreach check_name {no_clock unconstrained_internal_endpoints} {
        if {![dict exists $observed $check_name]} {
            error "OOC timing summary omitted required check '$check_name': $path"
        }
        if {[dict get $observed $check_name] != 0} {
            error "OOC timing check '$check_name' has [dict get $observed $check_name] violation(s): $path"
        }
    }
}

proc portable_identity_escape {value} {
    return [string map [list \\ \\\\ \r \\r \n \\n] $value]
}

proc portable_sha256 {path} {
    if {![file isfile $path]} {
        error "cannot hash missing file: $path"
    }
    set commands {}
    if {$::tcl_platform(platform) eq "windows" &&
        [auto_execok certutil] ne ""} {
        lappend commands [list certutil -hashfile $path SHA256]
    }
    if {[auto_execok sha256sum] ne ""} {
        lappend commands [list sha256sum $path]
    }
    if {[auto_execok shasum] ne ""} {
        lappend commands [list shasum -a 256 $path]
    }
    if {[auto_execok openssl] ne ""} {
        lappend commands [list openssl dgst -sha256 $path]
    }
    foreach command $commands {
        if {![catch {exec {*}$command} output] &&
            [regexp -nocase {(^|[^0-9a-f])([0-9a-f]{64})([^0-9a-f]|$)} \
                $output -> before digest after]} {
            return [string tolower $digest]
        }
    }
    error "no working SHA-256 command is available to hash $path"
}

proc portable_repo_relative {path repo_root} {
    if {![portable_path_is_within $path $repo_root] ||
        [portable_compare_path $path] eq [portable_compare_path $repo_root]} {
        error "input is not a file below the repository root: $path"
    }
    set normalized_path [string map {\\ /} [file normalize $path]]
    set normalized_root [string trimright \
        [string map {\\ /} [file normalize $repo_root]] "/"]
    set relative [string range $normalized_path \
        [expr {[string length $normalized_root] + 1}] end]
    if {$relative eq "" || [regexp {[\r\n]} $relative]} {
        error "input has an invalid repository-relative path: $path"
    }
    return $relative
}

proc portable_collect_relative_files {directory {prefix ""}} {
    set result {}
    foreach entry [portable_directory_entries $directory] {
        set full_path [file join $directory $entry]
        set relative [expr {$prefix eq "" ? $entry : "$prefix/$entry"}]
        if {[file isdirectory $full_path]} {
            set result [concat $result \
                [portable_collect_relative_files $full_path $relative]]
        } elseif {[file isfile $full_path]} {
            lappend result [string map {\\ /} $relative]
        } else {
            error "unsupported entry in input snapshot: $full_path"
        }
    }
    return [lsort -unique $result]
}

proc portable_prepare_input_snapshot {
    repo_root output_root input_files is_new_output
} {
    set inputs_dir [file join $output_root inputs]
    set manifest_path [file join $output_root inputs.sha256]
    set entries {}
    foreach source $input_files {
        set relative [portable_repo_relative $source $repo_root]
        lappend entries [list $relative [file normalize $source] \
            [portable_sha256 $source]]
    }
    set entries [lsort -unique -index 0 $entries]
    if {[llength $entries] != [llength $input_files]} {
        error "input snapshot contains duplicate repository-relative paths"
    }

    set expected_manifest ""
    set expected_files {}
    foreach entry $entries {
        lassign $entry relative source digest
        append expected_manifest "$digest  $relative\n"
        lappend expected_files $relative
    }

    if {$is_new_output} {
        file mkdir $inputs_dir
        foreach entry $entries {
            lassign $entry relative source digest
            set destination [file join $inputs_dir $relative]
            file mkdir [file dirname $destination]
            file copy $source $destination
        }
        portable_write_file $manifest_path $expected_manifest
    } else {
        if {![file isdirectory $inputs_dir] ||
            ![file isfile $manifest_path]} {
            error "existing OUT_DIR has no complete input snapshot: $output_root"
        }
        if {[portable_read_file $manifest_path] ne $expected_manifest} {
            error "existing input manifest does not match current exact inputs: $manifest_path"
        }
    }

    set actual_files [portable_collect_relative_files $inputs_dir]
    if {$actual_files ne [lsort $expected_files]} {
        error "input snapshot file set does not match its manifest: $inputs_dir"
    }
    foreach entry $entries {
        lassign $entry relative source digest
        set snapshot [file join $inputs_dir $relative]
        if {![file isfile $snapshot] || [portable_sha256 $snapshot] ne $digest} {
            error "input snapshot hash mismatch: $snapshot"
        }
    }
    return $inputs_dir
}

proc portable_snapshot_path {repo_root inputs_dir source} {
    return [file join $inputs_dir \
        [portable_repo_relative $source $repo_root]]
}

proc portable_write_file {path contents} {
    set handle [open $path w]
    try {
        puts -nonewline $handle $contents
    } finally {
        close $handle
    }
}

proc portable_accept_git {candidate source} {
    if {[file pathtype $candidate] ne "absolute"} {
        error "Git executable selected from $source is not an absolute path: $candidate"
    }
    set executable [file normalize $candidate]
    if {![file isfile $executable]} {
        error "Git executable selected from $source is not a file: $executable"
    }
    if {[catch {exec $executable --version} version]} {
        error "Git executable selected from $source failed --version: $executable: $version"
    }
    set version [string trim $version]
    if {![regexp {^git version[ ]+[^\r\n]+$} $version]} {
        error "Git executable selected from $source returned an unexpected version: '$version'"
    }
    set ::portable_git_executable_cache $executable
    set ::portable_git_source_cache $source
    set ::portable_git_version_cache $version
    return $executable
}

proc portable_resolve_git {} {
    if {[info exists ::portable_git_executable_cache]} {
        return $::portable_git_executable_cache
    }

    if {[info exists ::env(TERNARYCORE_GIT_EXECUTABLE)]} {
        set explicit [string trim $::env(TERNARYCORE_GIT_EXECUTABLE)]
        if {$explicit eq ""} {
            error "TERNARYCORE_GIT_EXECUTABLE is set but empty"
        }
        return [portable_accept_git $explicit TERNARYCORE_GIT_EXECUTABLE]
    }

    set path_git [auto_execok git]
    if {$path_git ne ""} {
        if {[llength $path_git] != 1} {
            error "Git found on PATH resolved to an unsupported command prefix: $path_git"
        }
        return [portable_accept_git [lindex $path_git 0] PATH]
    }

    if {$::tcl_platform(platform) eq "windows" &&
        [info exists ::env(LOCALAPPDATA)] &&
        [string trim $::env(LOCALAPPDATA)] ne ""} {
        set desktop_root [file join $::env(LOCALAPPDATA) GitHubDesktop]
        set bundles [lsort -dictionary -decreasing \
            [glob -nocomplain -types d -directory $desktop_root app-*]]
        foreach bundle $bundles {
            set candidate [file join $bundle resources app git cmd git.exe]
            if {[file isfile $candidate]} {
                return [portable_accept_git $candidate GitHubDesktop]
            }
        }
    }

    error "Git was not found. Enter the Windows tool environment, put git on the process PATH, or set TERNARYCORE_GIT_EXECUTABLE to an absolute git executable path"
}

proc portable_git_value {repo args} {
    set executable [portable_resolve_git]
    if {[catch {exec $executable -C $repo {*}$args} value]} {
        error "git [join $args { }] failed for $repo using $executable: $value"
    }
    return [string trim $value]
}

proc portable_require_safe_output {output_path repo_root label} {
    set normalized [file normalize $output_path]
    set parent [file dirname $normalized]
    if {![file isdirectory $parent]} {
        error "$label parent must already exist: $parent"
    }
    if {$::tcl_platform(platform) eq "windows"} {
        set volume [string trimright [lindex [file split $normalized] 0] "/\\"]
        if {![string equal -nocase $volume "D:"]} {
            error "$label must be on D: to protect the constrained system drive: $normalized"
        }
    }
    set worktree_listing [portable_git_value $repo_root worktree list --porcelain]
    foreach line [split $worktree_listing "\n"] {
        if {[regexp {^worktree[ ]+(.+)$} [string trim $line] -> worktree] &&
            ([portable_path_is_within $normalized $worktree] ||
             [portable_path_is_within $worktree $normalized])} {
            error "$label and every Git worktree must be disjoint: output='$normalized', worktree='[file normalize $worktree]'"
        }
    }
    set ancestor $parent
    while {1} {
        if {[file type $ancestor] eq "link"} {
            error "$label parent chain contains a link/reparse path: $ancestor"
        }
        set next [file dirname $ancestor]
        if {[portable_compare_path $next] eq [portable_compare_path $ancestor]} {
            break
        }
        set ancestor $next
    }
}

if {$argc < 3 || $argc > 4} {
    error "usage: run_vivado_v03_blocks_portable.tcl REPO_ROOT OUT_DIR PART ?CONFIG_FILTERS?"
}

if {[file pathtype [lindex $argv 0]] ne "absolute" ||
    [file pathtype [lindex $argv 1]] ne "absolute"} {
    error "REPO_ROOT and OUT_DIR must both be absolute paths"
}
set repo_root [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
set requested_part [string trim [lindex $argv 2]]
set filter_text ""
if {$argc == 4} {
    set filter_text [string trim [lindex $argv 3]]
}

if {![file isdirectory $repo_root]} {
    error "repository root does not exist: $repo_root"
}
if {$requested_part eq ""} {
    error "PART must be explicit and non-empty"
}
portable_require_safe_output $out_dir $repo_root "OUT_DIR"
if {[portable_path_is_within $out_dir $repo_root] ||
    [portable_path_is_within $repo_root $out_dir]} {
    error "OUT_DIR and the repository must be disjoint directory trees: $out_dir"
}
if {[file dirname $out_dir] eq $out_dir} {
    error "refusing to use a filesystem root as OUT_DIR: $out_dir"
}
if {[file exists $out_dir] && ![file isdirectory $out_dir]} {
    error "OUT_DIR exists and is not a directory: $out_dir"
}

set vivado_version [version -short]
set vivado_full_version [string trim [version]]
if {![regexp {^2025\.1($|[._-])} $vivado_version]} {
    error "Vivado 2025.1 is required; running $vivado_version"
}

set matching_parts [get_parts -quiet $requested_part]
if {[llength $matching_parts] != 1} {
    error "PART must resolve to exactly one installed device; '$requested_part' resolved to [llength $matching_parts]"
}
set part [get_property NAME [lindex $matching_parts 0]]
if {![string equal -nocase $part $requested_part]} {
    error "PART must be an exact device name, not a pattern: requested '$requested_part', resolved '$part'"
}

set target_mhz 81.25
set decoder_sources [list \
    [file join $repo_root rtl kv_v03_symbol_decoder.v] \
    [file join $repo_root rtl kv_v03_decoder_cluster_2x2.v]]
set decoder_4x1_sources [list \
    [file join $repo_root rtl kv_v03_symbol_decoder.v] \
    [file join $repo_root rtl kv_v03_decoder_cluster_4x1.v]]
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
set xdc [file join $repo_root analysis kv_validation scripts \
         kv_ooc_81p25mhz.xdc]

set configs [list \
    [list decoder_2x2 kv_v03_decoder_cluster_2x2 $decoder_sources {}] \
    [list decoder_4x1 kv_v03_decoder_cluster_4x1 $decoder_4x1_sources {}] \
    [list qk_k4_auto qk_group_dot $qk_sources \
          {GROUP_SIZE=128 Q_WIDTH=8 K_WIDTH=4 SCALE_WIDTH=16 ACC_WIDTH=64 MULT_STYLE=2}] \
    [list softmax_engine kv_v03_softmax_engine $softmax_sources {}] \
    [list av_v5_csd kv_v03_av_accumulator $av_sources {MULT_STYLE=0}] \
    [list av_v5_dsp kv_v03_av_accumulator $av_sources {MULT_STYLE=1}] \
    [list av_v5_auto kv_v03_av_accumulator $av_sources {MULT_STYLE=2}]]

set known_names {}
set source_files [list $xdc]
foreach config $configs {
    lassign $config name top sources generics
    lappend known_names $name
    foreach source $sources {
        if {$source ni $source_files} {
            lappend source_files $source
        }
    }
}
foreach source $source_files {
    if {![file isfile $source]} {
        error "required source is missing: $source"
    }
}

set selected_names $known_names
if {$filter_text ne ""} {
    set selected_names [split $filter_text "+"]
    if {[llength $selected_names] == 0} {
        error "CONFIG_FILTERS selected no configurations"
    }
    foreach name $selected_names {
        if {$name eq "" || [lsearch -exact $known_names $name] < 0} {
            error "unknown configuration '$name'; expected one of [join $known_names {, }]"
        }
    }
    if {[llength [lsort -unique $selected_names]] != [llength $selected_names]} {
        error "CONFIG_FILTERS contains duplicate configurations: $filter_text"
    }
}

set git_commit [portable_git_value $repo_root rev-parse --verify HEAD]
set git_status [portable_git_value $repo_root status --porcelain=v1 \
                --untracked-files=all]
set git_status_crc32 [format %08x \
    [expr {[zlib crc32 $git_status] & 0xffffffff}]]
set script_path [file normalize [info script]]
set script_blob [portable_git_value $repo_root hash-object -- $script_path]
set script_sha256 [portable_sha256 $script_path]

set identity "schema=3\n"
append identity "flow=kv_v03_routed_ooc_portable\n"
append identity "evidence_scope=isolated_ooc_not_integrated_or_board_timing\n"
append identity "route_acceptance=fully_routed_drc_state,routable_equals_fully_routed,zero_routing_errors\n"
append identity "timing_acceptance=min_max_nonnegative,zero_failing_endpoints,zero_no_clock,zero_unconstrained_internal_endpoints\n"
append identity "vivado_version=$vivado_version\n"
append identity "vivado_full_version=[portable_identity_escape $vivado_full_version]\n"
append identity "part=$part\n"
append identity "target_clock_mhz=$target_mhz\n"
append identity "transcript_policy=external_vivado_log_and_journal_required\n"
append identity "repo_root=[string map {\\ /} $repo_root]\n"
append identity "git_executable=[string map {\\ /} [portable_resolve_git]]\n"
append identity "git_executable_source=$::portable_git_source_cache\n"
append identity "git_executable_sha256=[portable_sha256 [portable_resolve_git]]\n"
append identity "git_version=[portable_identity_escape $::portable_git_version_cache]\n"
append identity "git_commit=$git_commit\n"
append identity "git_dirty=[expr {$git_status ne ""}]\n"
append identity "git_status_crc32=$git_status_crc32\n"
append identity "runner_git_blob=$script_blob\n"
append identity "runner_sha256=$script_sha256\n"
foreach source $source_files {
    set relative [portable_repo_relative $source $repo_root]
    set blob [portable_git_value $repo_root hash-object -- $source]
    append identity "source.$relative.git_blob=$blob\n"
    append identity "source.$relative.sha256=[portable_sha256 $source]\n"
}

set identity_path [file join $out_dir run_identity.txt]
set existing_entries [portable_directory_entries $out_dir]
set is_new_output [expr {[llength $existing_entries] == 0}]
if {[llength $existing_entries] > 0} {
    if {![file isfile $identity_path]} {
        error "OUT_DIR is non-empty and has no portable-run identity: $out_dir"
    }
    set existing_identity [portable_read_file $identity_path]
    if {$existing_identity ne $identity} {
        error "OUT_DIR identity does not match this tool/part/source state; use a new directory: $out_dir"
    }
}

set summary_path [file join $out_dir routed_runs.csv]
set prior_names {}
if {[file isfile $summary_path]} {
    foreach line [split [portable_read_file $summary_path] "\n"] {
        if {[regexp {^([^,]+),} $line -> prior_name] &&
            $prior_name ne "config"} {
            lappend prior_names $prior_name
        }
    }
}
foreach name $selected_names {
    if {[lsearch -exact $prior_names $name] >= 0 ||
        [llength [glob -nocomplain -directory $out_dir ${name}_*]] > 0} {
        error "configuration '$name' already has output in $out_dir; use a new directory instead of overwriting evidence"
    }
}

file mkdir $out_dir
if {![file exists $identity_path]} {
    portable_write_file $identity_path $identity
}
set input_files [concat [list $script_path] $source_files]
set inputs_dir [portable_prepare_input_snapshot \
    $repo_root $out_dir $input_files $is_new_output]
set run_xdc [portable_snapshot_path $repo_root $inputs_dir $xdc]
set run_configs {}
foreach config $configs {
    lassign $config name top sources generics
    set snapshot_sources {}
    foreach source $sources {
        lappend snapshot_sources \
            [portable_snapshot_path $repo_root $inputs_dir $source]
    }
    lappend run_configs [list $name $top $snapshot_sources $generics]
}
# Vivado can emit incidental .Xil/DFX runtime files in its current directory
# even for an in-memory project.  Move into the external run root before any
# design command so those files cannot land in the source checkout.
cd $out_dir
puts "PORTABLE_TRANSCRIPT_REQUIRED preserve the external Vivado -log and -journal files with $out_dir"
set invocation [open [file join $out_dir invocations.tsv] a]
try {
    puts $invocation "[clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]\t[join $selected_names +]"
} finally {
    close $invocation
}

set summary_has_rows [expr {[file exists $summary_path] &&
                            [file size $summary_path] > 0}]
set summary [open $summary_path [expr {$summary_has_rows ? "a" : "w"}]]
if {!$summary_has_rows} {
    puts $summary "config,top,part,target_clock_mhz,status,route_status,design_route_state,routable_nets,fully_routed_nets,routing_error_nets,timing_status,wns_ns,tns_ns,setup_failing_endpoints,whs_ns,ths_ns,hold_failing_endpoints,wpws_ns,tpws_ns,pulse_width_failing_endpoints,estimated_fmax_mhz"
}

set failed_configs {}
foreach config $run_configs {
    lassign $config name top sources generics
    if {[lsearch -exact $selected_names $name] < 0} {
        continue
    }

    puts "PORTABLE_V03_IMPL_BEGIN name=$name top=$top part=$part"
    set status "PASS"
    set route_status "NOT_RUN"
    set design_route_state ""
    set routable_nets ""
    set fully_routed_nets ""
    set routing_error_nets ""
    set timing_status "NOT_RUN"
    set wns ""
    set tns ""
    set setup_failing_endpoints ""
    set whs ""
    set ths ""
    set hold_failing_endpoints ""
    set wpws ""
    set tpws ""
    set pulse_width_failing_endpoints ""
    set fmax ""
    if {[catch {
        set validation_failures {}
        create_project -in_memory -part $part
        read_verilog $sources
        read_xdc $run_xdc
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
        set route_report [report_route_status -return_string]
        portable_write_file \
            [file join $out_dir ${name}_routed_route_status.rpt] \
            "$route_report\n"
        set route_metrics [portable_gate_route_status $route_report]
        set routable_nets [dict get $route_metrics routable_nets]
        set fully_routed_nets [dict get $route_metrics fully_routed_nets]
        set routing_error_nets [dict get $route_metrics routing_error_nets]
        set route_status "ROUTE_COUNTS_COMPLETE"
        report_utilization -file \
            [file join $out_dir ${name}_routed_utilization.rpt]
        report_utilization -hierarchical -hierarchical_depth 6 -file \
            [file join $out_dir ${name}_routed_hierarchical.rpt]
        set routed_timing_report \
            [file join $out_dir ${name}_routed_timing_summary.rpt]
        report_timing_summary -delay_type min_max -max_paths 20 \
            -report_unconstrained -file $routed_timing_report
        report_timing -delay_type max -max_paths 20 -file \
            [file join $out_dir ${name}_routed_timing_paths.rpt]
        report_timing -delay_type min -max_paths 20 -file \
            [file join $out_dir ${name}_routed_hold_timing_paths.rpt]
        set routed_drc_report [file join $out_dir ${name}_routed_drc.rpt]
        report_drc -file $routed_drc_report
        set design_route_state [portable_gate_drc_report $routed_drc_report]
        set route_status "FULLY_ROUTED"
        portable_gate_ooc_timing_checks $routed_timing_report
        set timing_status "CHECKING"
        set timing_metrics [portable_gate_timing_summary $routed_timing_report]
        set report_wns [dict get $timing_metrics wns_ns]
        set tns [dict get $timing_metrics tns_ns]
        set setup_failing_endpoints \
            [dict get $timing_metrics setup_failing_endpoints]
        set report_whs [dict get $timing_metrics whs_ns]
        set ths [dict get $timing_metrics ths_ns]
        set hold_failing_endpoints \
            [dict get $timing_metrics hold_failing_endpoints]
        set wpws [dict get $timing_metrics wpws_ns]
        set tpws [dict get $timing_metrics tpws_ns]
        set pulse_width_failing_endpoints \
            [dict get $timing_metrics pulse_width_failing_endpoints]
        write_checkpoint -force [file join $out_dir ${name}_routed.dcp]

        set setup_paths [get_timing_paths -delay_type max -max_paths 1 -quiet]
        if {[llength $setup_paths] == 0} {
            error "no constrained maximum-delay setup timing path"
        }
        set wns [get_property SLACK [lindex $setup_paths 0]]
        if {![string is double -strict $wns]} {
            error "queried routed WNS is missing or non-numeric: '$wns'"
        }
        if {double($wns) < 0.0} {
            error "queried routed WNS $wns ns is below zero"
        }
        if {abs(double($wns) - double($report_wns)) > 0.001} {
            error "queried routed WNS $wns ns disagrees with timing-summary WNS $report_wns ns"
        }

        set hold_paths [get_timing_paths -delay_type min -max_paths 1 -quiet]
        if {[llength $hold_paths] == 0} {
            error "no constrained minimum-delay hold timing path"
        }
        set whs [get_property SLACK [lindex $hold_paths 0]]
        if {![string is double -strict $whs]} {
            error "queried routed WHS is missing or non-numeric: '$whs'"
        }
        if {double($whs) < 0.0} {
            error "queried routed WHS $whs ns is below zero"
        }
        if {abs(double($whs) - double($report_whs)) > 0.001} {
            error "queried routed WHS $whs ns disagrees with timing-summary WHS $report_whs ns"
        }

        set effective_period [expr {1000.0 / $target_mhz - double($wns)}]
        if {$effective_period <= 0.0} {
            error "queried routed WNS $wns ns implies a nonpositive effective period"
        }
        set fmax [format "%.3f" [expr {1000.0 / $effective_period}]]
        set timing_status "MET"
        if {[llength $validation_failures] > 0} {
            error "implementation validation failed: [join $validation_failures {; }]"
        }
    } message options]} {
        set status "FAIL"
        if {$route_status eq "ROUTE_COUNTS_COMPLETE"} {
            set route_status "INCOMPLETE"
        }
        if {$timing_status eq "CHECKING"} {
            set timing_status "FAILED"
        }
        lappend failed_configs $name
        set error_text "$message\n[dict get $options -errorinfo]\n"
        portable_write_file [file join $out_dir ${name}_error.txt] $error_text
        puts "PORTABLE_V03_IMPL_ERROR name=$name message=$message"
    }
    puts $summary "$name,$top,$part,$target_mhz,$status,$route_status,$design_route_state,$routable_nets,$fully_routed_nets,$routing_error_nets,$timing_status,$wns,$tns,$setup_failing_endpoints,$whs,$ths,$hold_failing_endpoints,$wpws,$tpws,$pulse_width_failing_endpoints,$fmax"
    flush $summary
    catch {close_project}
    puts "PORTABLE_V03_IMPL_END name=$name status=$status"
}

close $summary
if {[llength $failed_configs] > 0} {
    error "portable v0.3 OOC sweep failed: [join $failed_configs {, }]"
}
puts "PORTABLE_V03_IMPL_SWEEP_PASS scope=isolated_ooc_not_integrated_or_board_timing summary=$summary_path"
