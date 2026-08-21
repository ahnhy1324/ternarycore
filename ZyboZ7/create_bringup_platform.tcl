# create_bringup_platform.tcl
# Temporary Zybo Z7-20 PS/DDR/GP0/HP0 bring-up platform for Vivado 2025.1.
# This is not the final KVQ topology.
#
# Usage:
#   vivado -mode batch -source create_bringup_platform.tcl \
#       -tclargs <fresh-external-output-directory> ?75|81.25?

proc bringup_usage {} {
    error "usage: create_bringup_platform.tcl <fresh-external-output-directory> ?75|81.25?"
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
    set windows [expr {$::tcl_platform(platform) eq "windows"}]
    set is_root [expr {$windows
        ? [string equal -nocase $normalized $parent]
        : [string equal $normalized $parent]}]
    if {$is_root} {
        error "refusing to use a filesystem/drive root as output: $normalized"
    }
    if {$windows} {
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
        error "cannot hash absent source file: $path"
    }
    if {[catch {exec certutil.exe -hashfile $path SHA256} output]} {
        error "certutil SHA-256 failed for '$path': $output"
    }
    if {![regexp -nocase {([0-9a-f]{64})} $output -> digest]} {
        error "certutil did not return a SHA-256 digest for '$path': $output"
    }
    return [string toupper $digest]
}

proc bringup_write_exclusive {path contents} {
    set channel [open $path {WRONLY CREAT EXCL}]
    try {
        puts -nonewline $channel $contents
    } finally {
        close $channel
    }
}

proc bringup_snapshot_sources {repo_root identity_dir source_relpaths} {
    set hashes [dict create]
    foreach relative_path $source_relpaths {
        set source_path [file normalize [file join $repo_root $relative_path]]
        if {![file isfile $source_path]} {
            error "required platform source is absent: $source_path"
        }
        set snapshot_path [file join $identity_dir sources $relative_path]
        file mkdir [file dirname $snapshot_path]
        file copy $source_path $snapshot_path
        set source_hash [bringup_sha256 $source_path]
        set snapshot_hash [bringup_sha256 $snapshot_path]
        if {$snapshot_hash ne $source_hash} {
            error "source snapshot hash mismatch for $relative_path"
        }
        dict set hashes $relative_path $source_hash
    }
    return $hashes
}

proc bringup_verify_source_hashes {repo_root source_hashes} {
    foreach relative_path [dict keys $source_hashes] {
        set expected [dict get $source_hashes $relative_path]
        set actual [bringup_sha256 [file join $repo_root $relative_path]]
        if {$actual ne $expected} {
            error "platform source changed during project creation: $relative_path (expected $expected, got $actual)"
        }
    }
}

if {[llength $argv] < 1 || [llength $argv] > 2} {
    bringup_usage
}

set output_dir [file normalize [lindex $argv 0]]
set clock_arg [expr {[llength $argv] == 2 ? [lindex $argv 1] : "75"}]
if {![string is double -strict $clock_arg]} {
    error "PL clock must be numeric and exactly 75 or 81.25 MHz; got '$clock_arg'"
}
set pl_clock_mhz [expr {double($clock_arg)}]
if {abs($pl_clock_mhz - 75.0) < 0.000001} {
    set pl_clock_hz 75000000
    set clock_module zybo_pl_clock_75
} elseif {abs($pl_clock_mhz - 81.25) < 0.000001} {
    set pl_clock_hz 81250000
    set clock_module zybo_pl_clock_81p25
} else {
    error "PL clock must be exactly 75 or 81.25 MHz; got '$clock_arg'"
}
set native_fclk 0
if {[info exists ::env(TERNARYCORE_NATIVE_FCLK)] &&
    [string trim $::env(TERNARYCORE_NATIVE_FCLK)] ne ""} {
    if {[string trim $::env(TERNARYCORE_NATIVE_FCLK)] ne "1"} {
        error "TERNARYCORE_NATIVE_FCLK, when set, must be exactly 1"
    }
    if {abs($pl_clock_mhz - 75.0) >= 0.000001} {
        error "the native PS FCLK diagnostic mode is supported only with the 75 MHz request"
    }
    # Zynq's integer PS divider realizes the 75 MHz request as 76.923080 MHz.
    set native_fclk 1
    set pl_clock_mhz 76.923080
    set pl_clock_hz 76923080
    set clock_module ps7_native_fclk
}

set tool_version_short [version -short]
set tool_version_full [version]
if {![regexp {^2025\.1($|[._-])} $tool_version_short]} {
    error "Vivado 2025.1 is required; got '$tool_version_short'"
}

if {![info exists ::env(TERNARYCORE_BOARD_FILES)] || [string trim $::env(TERNARYCORE_BOARD_FILES)] eq ""} {
    error "TERNARYCORE_BOARD_FILES must name the directory containing the Digilent board directories"
}
set board_repo [file normalize $::env(TERNARYCORE_BOARD_FILES)]
if {![file isdirectory $board_repo]} {
    error "TERNARYCORE_BOARD_FILES is not a directory: $board_repo"
}

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
bringup_require_safe_output $output_dir $repo_root
if {[file exists $output_dir]} {
    error "output must not already exist; use a fresh path for every create/build attempt: $output_dir"
}

set board_part "digilentinc.com:zybo-z7-20:part0:1.2"
set part       "xc7z020clg400-1"
set pinned_board_repo_commit "36f34ab687b7fa9c778b779d027f3bce63b3ace9"
set kv_smoke_enabled 0
set kv_ip_repo ""
set kv_component_sha256 ""
set kv_transport "NONE"
set kv_m_axi_data_width 0
if {[info exists ::env(TERNARYCORE_KV_IP_REPO)] &&
    [string trim $::env(TERNARYCORE_KV_IP_REPO)] ne ""} {
    set kv_ip_repo [file normalize $::env(TERNARYCORE_KV_IP_REPO)]
    set kv_component [file join $kv_ip_repo axi_kv_cache component.xml]
    if {![file isfile $kv_component]} {
        error "TERNARYCORE_KV_IP_REPO has no axi_kv_cache/component.xml: $kv_ip_repo"
    }
    set kv_component_sha256 [bringup_sha256 $kv_component]
    set kv_smoke_enabled 1
    set kv_transport "HP64_NATIVE"
    set kv_m_axi_data_width 64
    if {[info exists ::env(TERNARYCORE_KV_TRANSPORT)] &&
        [string trim $::env(TERNARYCORE_KV_TRANSPORT)] ne ""} {
        set requested_transport [string toupper \
            [string trim $::env(TERNARYCORE_KV_TRANSPORT)]]
        switch -exact -- $requested_transport {
            HP64_NATIVE {
                set kv_transport "HP64_NATIVE"
                set kv_m_axi_data_width 64
            }
            INTERNAL128_TO_HP64 {
                set kv_transport "INTERNAL128_TO_HP64"
                set kv_m_axi_data_width 128
            }
            default {
                error "TERNARYCORE_KV_TRANSPORT must be HP64_NATIVE or INTERNAL128_TO_HP64; got '$requested_transport'"
            }
        }
    }
} elseif {[info exists ::env(TERNARYCORE_KV_TRANSPORT)] &&
          [string trim $::env(TERNARYCORE_KV_TRANSPORT)] ne ""} {
    error "TERNARYCORE_KV_TRANSPORT requires TERNARYCORE_KV_IP_REPO"
}
set av_diag_enabled 0
set av_diag_repo ""
set av_diag_component_sha256 ""
set av_m_axi_data_width 0
if {[info exists ::env(TERNARYCORE_AV_DIAG_IP_REPO)] &&
    [string trim $::env(TERNARYCORE_AV_DIAG_IP_REPO)] ne ""} {
    set av_diag_repo [file normalize $::env(TERNARYCORE_AV_DIAG_IP_REPO)]
    set av_diag_component [file join $av_diag_repo axi_v5_av_diag component.xml]
    if {![file isfile $av_diag_component]} {
        error "TERNARYCORE_AV_DIAG_IP_REPO has no axi_v5_av_diag/component.xml: $av_diag_repo"
    }
    set av_diag_component_sha256 [bringup_sha256 $av_diag_component]
    set av_diag_enabled 1
    # The first raw-V5/AV board build deliberately uses the native HP0 width.
    set av_m_axi_data_width 64
}
if {$av_diag_enabled && !$kv_smoke_enabled} {
    error "TERNARYCORE_AV_DIAG_IP_REPO requires TERNARYCORE_KV_IP_REPO because the additive AV diagnostic preserves the KV M02/S01 slots and uses M03/S02"
}
set raw_full_enabled 0
set raw_full_repo ""
set raw_full_component_sha256 ""
set raw_full_m_axi_data_width 0
set raw_full_scale_width 0
set raw_full_qk_mult_style 0
set raw_full_av_mult_style 0
set raw_full_profile "NONE"
set canned_page_env_enabled [expr {
    [info exists ::env(TERNARYCORE_CANNED_PAGE_IP_REPO)] &&
    [string trim $::env(TERNARYCORE_CANNED_PAGE_IP_REPO)] ne ""}]
if {[info exists ::env(TERNARYCORE_RAW_FULL_IP_REPO)] &&
    [string trim $::env(TERNARYCORE_RAW_FULL_IP_REPO)] ne ""} {
    if {$kv_smoke_enabled || $av_diag_enabled || $canned_page_env_enabled} {
        error "TERNARYCORE_RAW_FULL_IP_REPO replaces and cannot coexist with KV, AV, or canned-page diagnostic modes"
    }
    set raw_full_repo [file normalize $::env(TERNARYCORE_RAW_FULL_IP_REPO)]
    set raw_full_component \
        [file join $raw_full_repo axi_kvq_raw_full_diag component.xml]
    if {![file isfile $raw_full_component]} {
        error "TERNARYCORE_RAW_FULL_IP_REPO has no axi_kvq_raw_full_diag/component.xml: $raw_full_repo"
    }
    set raw_full_component_sha256 [bringup_sha256 $raw_full_component]
    set raw_full_enabled 1
    set raw_full_m_axi_data_width 64
    set raw_full_scale_width 12
    set raw_full_profile "BALANCED"
    if {[info exists ::env(TERNARYCORE_RAW_FULL_SCALE_WIDTH)] &&
        [string trim $::env(TERNARYCORE_RAW_FULL_SCALE_WIDTH)] ne ""} {
        set raw_full_scale_width [string trim $::env(TERNARYCORE_RAW_FULL_SCALE_WIDTH)]
    }
    if {$raw_full_scale_width ni {12 16}} {
        error "TERNARYCORE_RAW_FULL_SCALE_WIDTH must be exactly 12 or 16; got '$raw_full_scale_width'"
    }
    if {[info exists ::env(TERNARYCORE_RAW_FULL_AXI_WIDTH)] &&
        [string trim $::env(TERNARYCORE_RAW_FULL_AXI_WIDTH)] ne ""} {
        set raw_full_m_axi_data_width \
            [string trim $::env(TERNARYCORE_RAW_FULL_AXI_WIDTH)]
    }
    if {$raw_full_m_axi_data_width ni {64 128}} {
        error "TERNARYCORE_RAW_FULL_AXI_WIDTH must be exactly 64 or 128; got '$raw_full_m_axi_data_width'"
    }
    if {[info exists ::env(TERNARYCORE_RAW_FULL_PROFILE)] &&
        [string trim $::env(TERNARYCORE_RAW_FULL_PROFILE)] ne ""} {
        set raw_full_profile \
            [string toupper [string trim $::env(TERNARYCORE_RAW_FULL_PROFILE)]]
    }
    switch -exact -- $raw_full_profile {
        BALANCED {
            set raw_full_qk_mult_style 2
            set raw_full_av_mult_style 2
        }
        LUT_RELIEF {
            set raw_full_qk_mult_style 2
            set raw_full_av_mult_style 1
        }
        default {
            error "TERNARYCORE_RAW_FULL_PROFILE must be BALANCED or LUT_RELIEF; got '$raw_full_profile'"
        }
    }
} elseif {([info exists ::env(TERNARYCORE_RAW_FULL_AXI_WIDTH)] &&
           [string trim $::env(TERNARYCORE_RAW_FULL_AXI_WIDTH)] ne "") ||
          ([info exists ::env(TERNARYCORE_RAW_FULL_SCALE_WIDTH)] &&
           [string trim $::env(TERNARYCORE_RAW_FULL_SCALE_WIDTH)] ne "") ||
          ([info exists ::env(TERNARYCORE_RAW_FULL_PROFILE)] &&
           [string trim $::env(TERNARYCORE_RAW_FULL_PROFILE)] ne "")} {
    error "TERNARYCORE_RAW_FULL_AXI_WIDTH, TERNARYCORE_RAW_FULL_SCALE_WIDTH, and TERNARYCORE_RAW_FULL_PROFILE require TERNARYCORE_RAW_FULL_IP_REPO"
}
set canned_page_enabled 0
set canned_page_repo ""
set canned_page_component_sha256 ""
set canned_page_scale_bits 0
set canned_page_qk_mult_style 0
set canned_page_av_mult_style 0
set canned_page_profile "NONE"
set canned_page_compiled_profile_id 0
set canned_page_compiled_k_codebook_id 0
set canned_page_compiled_v_codebook_id 0
if {$canned_page_env_enabled} {
    if {$kv_smoke_enabled || $av_diag_enabled || $raw_full_enabled} {
        error "TERNARYCORE_CANNED_PAGE_IP_REPO replaces and cannot coexist with KV, AV, or raw-full diagnostic modes"
    }
    set canned_page_repo \
        [file normalize $::env(TERNARYCORE_CANNED_PAGE_IP_REPO)]
    set canned_page_component [file join $canned_page_repo \
        axi_kvq_canned_page_diag component.xml]
    if {![file isfile $canned_page_component]} {
        error "TERNARYCORE_CANNED_PAGE_IP_REPO has no axi_kvq_canned_page_diag/component.xml: $canned_page_repo"
    }
    set canned_page_component_sha256 \
        [bringup_sha256 $canned_page_component]
    set canned_page_enabled 1
    set canned_page_scale_bits 12
    set canned_page_profile "BALANCED"
    set canned_page_compiled_profile_id 51
    set canned_page_compiled_k_codebook_id 1
    set canned_page_compiled_v_codebook_id 2
    if {[info exists ::env(TERNARYCORE_CANNED_PAGE_SCALE_BITS)] &&
        [string trim $::env(TERNARYCORE_CANNED_PAGE_SCALE_BITS)] ne ""} {
        set canned_page_scale_bits \
            [string trim $::env(TERNARYCORE_CANNED_PAGE_SCALE_BITS)]
    }
    if {$canned_page_scale_bits ni {12 16}} {
        error "TERNARYCORE_CANNED_PAGE_SCALE_BITS must be exactly 12 or 16; got '$canned_page_scale_bits'"
    }
    if {[info exists ::env(TERNARYCORE_CANNED_PAGE_PROFILE)] &&
        [string trim $::env(TERNARYCORE_CANNED_PAGE_PROFILE)] ne ""} {
        set canned_page_profile [string toupper \
            [string trim $::env(TERNARYCORE_CANNED_PAGE_PROFILE)]]
    }
    switch -exact -- $canned_page_profile {
        BALANCED {
            set canned_page_qk_mult_style 2
            set canned_page_av_mult_style 2
        }
        LUT_RELIEF {
            set canned_page_qk_mult_style 2
            set canned_page_av_mult_style 1
        }
        default {
            error "TERNARYCORE_CANNED_PAGE_PROFILE must be BALANCED or LUT_RELIEF; got '$canned_page_profile'"
        }
    }
} elseif {([info exists ::env(TERNARYCORE_CANNED_PAGE_SCALE_BITS)] &&
           [string trim $::env(TERNARYCORE_CANNED_PAGE_SCALE_BITS)] ne "") ||
          ([info exists ::env(TERNARYCORE_CANNED_PAGE_PROFILE)] &&
           [string trim $::env(TERNARYCORE_CANNED_PAGE_PROFILE)] ne "")} {
    error "TERNARYCORE_CANNED_PAGE_SCALE_BITS and TERNARYCORE_CANNED_PAGE_PROFILE require TERNARYCORE_CANNED_PAGE_IP_REPO"
}
set raw_e2e_enabled 0
set raw_e2e_repo ""
set raw_e2e_projection_component_sha256 ""
set raw_e2e_weight_component_sha256 ""
if {[info exists ::env(TERNARYCORE_RAW_E2E_IP_REPO)] &&
    [string trim $::env(TERNARYCORE_RAW_E2E_IP_REPO)] ne ""} {
    if {!$raw_full_enabled || $canned_page_enabled ||
        $raw_full_m_axi_data_width != 64 || $raw_full_scale_width != 12 ||
        $raw_full_qk_mult_style != 2 || $raw_full_av_mult_style != 1 ||
        $raw_full_profile ne "LUT_RELIEF"} {
        error "RAW E2E requires RAW_FULL HP64/SCALE12/LUT_RELIEF (QK=2, AV=1) and no canned frontend"
    }
    set raw_e2e_repo [file normalize $::env(TERNARYCORE_RAW_E2E_IP_REPO)]
    set projection_component [file join $raw_e2e_repo axi_gemm_stream component.xml]
    set weight_component [file join $raw_e2e_repo weight_bram128 component.xml]
    foreach {component label} [list $projection_component projection $weight_component weight] {
        if {![file isfile $component]} { error "RAW-E2E repo has no $label component: $component" }
    }
    set raw_e2e_projection_component_sha256 [bringup_sha256 $projection_component]
    set raw_e2e_weight_component_sha256 [bringup_sha256 $weight_component]
    set raw_e2e_enabled 1
}
set project_name "zybo_bringup"
set bd_name      "zybo_bringup"
set project_dir  [file join $output_dir project]
set identity_dir [file join $output_dir identity]

set board_repo_root [file normalize [bringup_git $board_repo rev-parse --show-toplevel]]
set board_repo_commit [bringup_git $board_repo_root rev-parse HEAD]
if {$board_repo_commit ne $pinned_board_repo_commit} {
    error "Digilent board repository must be pinned at $pinned_board_repo_commit; got $board_repo_commit"
}
set board_repo_status [bringup_git $board_repo_root status --porcelain=v1 --untracked-files=all]
if {$board_repo_status ne ""} {
    error "Digilent board repository must be clean for a reproducible build: $board_repo_root\n$board_repo_status"
}
set repo_commit [bringup_git $repo_root rev-parse HEAD]
set repo_dirty [expr {[bringup_git $repo_root status --porcelain=v1 --untracked-files=all] ne ""}]
set repo_worktrees [bringup_worktrees $repo_root]

file mkdir $identity_dir
cd $output_dir

set source_relpaths [list \
    ZyboZ7/Build-ZyboPlatform.ps1 \
    ZyboZ7/create_bringup_platform.tcl \
    ZyboZ7/assert_bringup_platform.tcl \
    ZyboZ7/build_bringup_platform.tcl \
    ZyboZ7/rtl/zybo_pl_clock.v \
    ZyboZ7/tb/zybo_clock_primitive_stubs.v \
    ZyboZ7/tb/tb_zybo_pl_clock.v \
]
set source_hashes [bringup_snapshot_sources $repo_root $identity_dir $source_relpaths]

set_param board.repoPaths [list $board_repo]
set board_matches [get_board_parts -quiet $board_part]
if {[llength $board_matches] != 1} {
    error "expected board part $board_part exactly once under $board_repo; got: $board_matches"
}

set identity [dict create \
    schema_version       2 \
    created_utc          [clock format [clock seconds] -gmt true -format {%Y-%m-%dT%H:%M:%SZ}] \
    output_dir           $output_dir \
    repo_root            $repo_root \
    repo_commit          $repo_commit \
    repo_dirty           $repo_dirty \
    repo_worktrees       $repo_worktrees \
    vivado_version_short $tool_version_short \
    vivado_version_full  $tool_version_full \
    board_files_dir      $board_repo \
    board_repo_root      $board_repo_root \
    board_repo_commit    $board_repo_commit \
    board_part           $board_part \
    part                 $part \
    pl_clock_mhz         [format "%.6f" $pl_clock_mhz] \
    pl_clock_hz          $pl_clock_hz \
    clock_module         $clock_module \
    kv_smoke_enabled     $kv_smoke_enabled \
    kv_ip_repo           $kv_ip_repo \
    kv_component_sha256  $kv_component_sha256 \
    kv_transport         $kv_transport \
    kv_m_axi_data_width  $kv_m_axi_data_width \
    av_diag_enabled      $av_diag_enabled \
    av_diag_repo         $av_diag_repo \
    av_diag_component_sha256 $av_diag_component_sha256 \
    av_m_axi_data_width  $av_m_axi_data_width \
    raw_full_enabled     $raw_full_enabled \
    raw_full_ip_repo     $raw_full_repo \
    raw_full_component_sha256 $raw_full_component_sha256 \
    raw_full_m_axi_data_width $raw_full_m_axi_data_width \
    raw_full_scale_width $raw_full_scale_width \
    raw_full_qk_mult_style $raw_full_qk_mult_style \
    raw_full_av_mult_style $raw_full_av_mult_style \
    raw_full_profile     $raw_full_profile \
    raw_e2e_enabled      $raw_e2e_enabled \
    raw_e2e_ip_repo      $raw_e2e_repo \
    raw_e2e_projection_component_sha256 $raw_e2e_projection_component_sha256 \
    raw_e2e_weight_component_sha256 $raw_e2e_weight_component_sha256 \
    canned_page_enabled  $canned_page_enabled \
    canned_page_ip_repo  $canned_page_repo \
    canned_page_component_sha256 $canned_page_component_sha256 \
    canned_page_scale_bits $canned_page_scale_bits \
    canned_page_qk_mult_style $canned_page_qk_mult_style \
    canned_page_av_mult_style $canned_page_av_mult_style \
    canned_page_profile  $canned_page_profile \
    canned_page_compiled_profile_id $canned_page_compiled_profile_id \
    canned_page_compiled_k_codebook_id $canned_page_compiled_k_codebook_id \
    canned_page_compiled_v_codebook_id $canned_page_compiled_v_codebook_id \
    source_sha256        $source_hashes \
]
bringup_write_exclusive [file join $identity_dir manifest.tcl] \
    "[list set ::zybo_bringup_identity $identity]\n"
bringup_write_exclusive [file join $identity_dir identity.txt] \
    [join [list \
        "schema_version=2" \
        "created_utc=[dict get $identity created_utc]" \
        "repo_root=$repo_root" \
        "repo_commit=$repo_commit" \
        "repo_dirty=$repo_dirty" \
        "vivado_version_short=$tool_version_short" \
        "vivado_version_full=$tool_version_full" \
        "board_files_dir=$board_repo" \
        "board_repo_root=$board_repo_root" \
        "board_repo_commit=$board_repo_commit" \
        "board_part=$board_part" \
        "part=$part" \
        "pl_clock_mhz=[format "%.6f" $pl_clock_mhz]" \
        "pl_clock_hz=$pl_clock_hz" \
        "clock_module=$clock_module" \
        "kv_smoke_enabled=$kv_smoke_enabled" \
        "kv_ip_repo=$kv_ip_repo" \
        "kv_component_sha256=$kv_component_sha256" \
        "kv_transport=$kv_transport" \
        "kv_m_axi_data_width=$kv_m_axi_data_width" \
        "av_diag_enabled=$av_diag_enabled" \
        "av_diag_repo=$av_diag_repo" \
        "av_diag_component_sha256=$av_diag_component_sha256" \
        "av_m_axi_data_width=$av_m_axi_data_width" \
        "raw_full_enabled=$raw_full_enabled" \
        "raw_full_ip_repo=$raw_full_repo" \
        "raw_full_component_sha256=$raw_full_component_sha256" \
        "raw_full_m_axi_data_width=$raw_full_m_axi_data_width" \
        "raw_full_scale_width=$raw_full_scale_width" \
        "raw_full_qk_mult_style=$raw_full_qk_mult_style" \
        "raw_full_av_mult_style=$raw_full_av_mult_style" \
        "raw_full_profile=$raw_full_profile" \
        "raw_e2e_enabled=$raw_e2e_enabled" \
        "raw_e2e_ip_repo=$raw_e2e_repo" \
        "raw_e2e_projection_component_sha256=$raw_e2e_projection_component_sha256" \
        "raw_e2e_weight_component_sha256=$raw_e2e_weight_component_sha256" \
        "canned_page_enabled=$canned_page_enabled" \
        "canned_page_ip_repo=$canned_page_repo" \
        "canned_page_component_sha256=$canned_page_component_sha256" \
        "canned_page_scale_bits=$canned_page_scale_bits" \
        "canned_page_qk_mult_style=$canned_page_qk_mult_style" \
        "canned_page_av_mult_style=$canned_page_av_mult_style" \
        "canned_page_profile=$canned_page_profile" \
        "canned_page_compiled_profile_id=$canned_page_compiled_profile_id" \
        "canned_page_compiled_k_codebook_id=$canned_page_compiled_k_codebook_id" \
        "canned_page_compiled_v_codebook_id=$canned_page_compiled_v_codebook_id" \
    ] "\n"]

create_project $project_name $project_dir -part $part
set_property BOARD_PART $board_part [current_project]
set_property TARGET_LANGUAGE Verilog [current_project]
set_property SOURCE_MGMT_MODE All [current_project]
set optional_ip_repos {}
if {$kv_smoke_enabled} {
    lappend optional_ip_repos $kv_ip_repo
}
if {$av_diag_enabled && [lsearch -exact $optional_ip_repos $av_diag_repo] < 0} {
    lappend optional_ip_repos $av_diag_repo
}
if {$raw_full_enabled} {
    lappend optional_ip_repos $raw_full_repo
}
if {$canned_page_enabled} {
    lappend optional_ip_repos $canned_page_repo
}
if {$raw_e2e_enabled} { lappend optional_ip_repos $raw_e2e_repo }
if {[llength $optional_ip_repos] > 0} {
    set_property ip_repo_paths $optional_ip_repos [current_project]
    update_ip_catalog -rebuild
}
if {$kv_smoke_enabled} {
    set kv_defs [get_ipdefs -quiet shepherdscientific.com:user:axi_kv_cache:2.0]
    if {[llength $kv_defs] != 1} {
        error "expected one packaged axi_kv_cache:2.0 definition; got: $kv_defs"
    }
}
if {$av_diag_enabled} {
    set av_diag_defs [get_ipdefs -quiet shepherdscientific.com:user:axi_v5_av_diag:1.0]
    if {[llength $av_diag_defs] != 1} {
        error "expected one packaged axi_v5_av_diag:1.0 definition; got: $av_diag_defs"
    }
}
if {$raw_full_enabled} {
    set raw_full_defs \
        [get_ipdefs -quiet shepherdscientific.com:user:axi_kvq_raw_full_diag:1.0]
    if {[llength $raw_full_defs] != 1} {
        error "expected one packaged axi_kvq_raw_full_diag:1.0 definition; got: $raw_full_defs"
    }
}
if {$canned_page_enabled} {
    set canned_page_defs [get_ipdefs -quiet \
        shepherdscientific.com:user:axi_kvq_canned_page_diag:1.0]
    if {[llength $canned_page_defs] != 1} {
        error "expected one packaged axi_kvq_canned_page_diag:1.0 definition; got: $canned_page_defs"
    }
}
if {$raw_e2e_enabled} {
    foreach vlnv {
        shepherdscientific.com:user:axi_gemm_stream:1.0
        shepherdscientific.com:user:weight_bram128:1.0
    } {
        set defs [get_ipdefs -quiet $vlnv]
        if {[llength $defs] != 1} { error "expected one RAW-E2E IP '$vlnv'; got: $defs" }
    }
}

set clock_rtl [file join $script_dir rtl zybo_pl_clock.v]
add_files -norecurse -fileset sources_1 $clock_rtl
update_compile_order -fileset sources_1

create_bd_design $bd_name
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7_0

# Apply the pinned Digilent preset so DDR timing and all MIO choices remain
# authoritative. Then enable only the extra PL-facing interface required here.
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {
    apply_board_preset "1"
    make_external      "FIXED_IO, DDR"
    Master             "Disable"
    Slave              "Disable"
} [get_bd_cells ps7_0]

set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0             {1} \
    CONFIG.PCW_USE_S_AXI_HP0             {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH      {64} \
    CONFIG.PCW_USE_AXI_NONSECURE         {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ  [expr {$native_fclk ? "75.000000" : "100.000000"}] \
] [get_bd_cells ps7_0]

# The normal flow generates the exact 75 or 81.25 MHz fabric clock from a
# 100 MHz PS FCLK.  The opt-in diagnostic path uses the already board-proven
# native 76.923080 MHz PS FCLK without an MMCM.
if {!$native_fclk} {
    create_bd_cell -type module -reference $clock_module pl_clock_0
    connect_bd_net [get_bd_pins ps7_0/FCLK_CLK0]      [get_bd_pins pl_clock_0/clk_in]
    connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] [get_bd_pins pl_clock_0/resetn]
}

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl

if {$native_fclk} {
    set PL_CLK [get_bd_pins ps7_0/FCLK_CLK0]
} else {
    set PL_CLK [get_bd_pins pl_clock_0/clk_out]
}
set PL_RST_N  [get_bd_pins rst_pl/peripheral_aresetn]
set AXI_RST_N [get_bd_pins rst_pl/interconnect_aresetn]

connect_bd_net $PL_CLK [get_bd_pins rst_pl/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7_0/FCLK_RESET0_N] \
    [get_bd_pins rst_pl/ext_reset_in]
if {!$native_fclk} {
    connect_bd_net [get_bd_pins pl_clock_0/locked] \
        [get_bd_pins rst_pl/dcm_locked]
}

# GP0 control fabric: one BRAM loopback window plus CDMA control registers.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ctrl_sc
set_property -dict [list CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI [expr {$raw_e2e_enabled ? 5 : \
        (($raw_full_enabled || $canned_page_enabled) ? 3 : \
        ($av_diag_enabled ? 4 : ($kv_smoke_enabled ? 3 : 2)))}]] \
    [get_bd_cells ctrl_sc]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_0
set_property -dict [list CONFIG.DATA_WIDTH {32} CONFIG.SINGLE_PORT_BRAM {1}] [get_bd_cells axi_bram_ctrl_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 bram_0
set_property -dict [list \
    CONFIG.Memory_Type    {Single_Port_RAM} \
    CONFIG.use_bram_block {BRAM_Controller} \
] [get_bd_cells bram_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_cdma:4.1 axi_cdma_0
set_property -dict [list \
    CONFIG.C_INCLUDE_SG           {0} \
    CONFIG.C_INCLUDE_DRE          {0} \
    CONFIG.C_M_AXI_DATA_WIDTH     {64} \
    CONFIG.C_M_AXI_MAX_BURST_LEN  {256} \
] [get_bd_cells axi_cdma_0]
if {$kv_smoke_enabled} {
    create_bd_cell -type ip \
        -vlnv shepherdscientific.com:user:axi_kv_cache:2.0 axi_kv_cache_0
    set_property -dict [list \
        CONFIG.HEAD_DIM         {128} \
        CONFIG.MAX_CONTEXT      {4096} \
        CONFIG.M_AXI_ADDR_WIDTH {32} \
        CONFIG.M_AXI_DATA_WIDTH $kv_m_axi_data_width \
    ] [get_bd_cells axi_kv_cache_0]
}
if {$av_diag_enabled} {
    create_bd_cell -type ip \
        -vlnv shepherdscientific.com:user:axi_v5_av_diag:1.0 axi_v5_av_diag_0
    set_property -dict [list \
        CONFIG.MAX_CONTEXT      {128} \
        CONFIG.MULT_STYLE       {2} \
        CONFIG.M_AXI_ADDR_WIDTH {32} \
        CONFIG.M_AXI_DATA_WIDTH $av_m_axi_data_width \
    ] [get_bd_cells axi_v5_av_diag_0]
}
if {$raw_full_enabled} {
    create_bd_cell -type ip \
        -vlnv shepherdscientific.com:user:axi_kvq_raw_full_diag:1.0 \
        axi_kvq_raw_full_diag_0
    set_property -dict [list \
        CONFIG.MAX_CONTEXT      {128} \
        CONFIG.SCALE_WIDTH      $raw_full_scale_width \
        CONFIG.QK_MULT_STYLE    $raw_full_qk_mult_style \
        CONFIG.AV_MULT_STYLE    $raw_full_av_mult_style \
        CONFIG.M_AXI_ADDR_WIDTH {32} \
        CONFIG.M_AXI_DATA_WIDTH $raw_full_m_axi_data_width \
    ] [get_bd_cells axi_kvq_raw_full_diag_0]
}
if {$canned_page_enabled} {
    create_bd_cell -type ip \
        -vlnv shepherdscientific.com:user:axi_kvq_canned_page_diag:1.0 \
        axi_kvq_canned_page_diag_0
    set_property -dict [list \
        CONFIG.MAX_CONTEXT            {128} \
        CONFIG.SCALE_BITS             $canned_page_scale_bits \
        CONFIG.COMPILED_PROFILE_ID     $canned_page_compiled_profile_id \
        CONFIG.COMPILED_K_CODEBOOK_ID  $canned_page_compiled_k_codebook_id \
        CONFIG.COMPILED_V_CODEBOOK_ID  $canned_page_compiled_v_codebook_id \
        CONFIG.QK_MULT_STYLE          $canned_page_qk_mult_style \
        CONFIG.AV_MULT_STYLE          $canned_page_av_mult_style \
    ] [get_bd_cells axi_kvq_canned_page_diag_0]
}
if {$raw_e2e_enabled} {
    create_bd_cell -type ip -vlnv shepherdscientific.com:user:axi_gemm_stream:1.0 axi_gemm_stream_0
    set_property -dict [list CONFIG.DEPTH_MAX {1024} CONFIG.COLS {64} \
        CONFIG.ACC_WIDTH {32} CONFIG.WADDR_W {14} CONFIG.ENABLE_INT8 {0}] \
        [get_bd_cells axi_gemm_stream_0]
    create_bd_cell -type ip -vlnv shepherdscientific.com:user:weight_bram128:1.0 weight_bram128_0
    set_property -dict [list CONFIG.ADDR_WIDTH {18} CONFIG.ID_WIDTH {4} CONFIG.DATA_WIDTH {32}] \
        [get_bd_cells weight_bram128_0]
}

connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP0] \
    [get_bd_intf_pins ctrl_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M00_AXI]     [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M01_AXI]     [get_bd_intf_pins axi_cdma_0/S_AXI_LITE]
if {$kv_smoke_enabled} {
    connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M02_AXI] \
        [get_bd_intf_pins axi_kv_cache_0/s_axi]
}
if {$av_diag_enabled} {
    connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M03_AXI] \
        [get_bd_intf_pins axi_v5_av_diag_0/s_axi]
}
if {$raw_full_enabled} {
    connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M02_AXI] \
        [get_bd_intf_pins axi_kvq_raw_full_diag_0/s_axi]
}
if {$canned_page_enabled} {
    connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M02_AXI] \
        [get_bd_intf_pins axi_kvq_canned_page_diag_0/s_axi]
}
if {$raw_e2e_enabled} {
    connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M03_AXI] [get_bd_intf_pins axi_gemm_stream_0/s_axi]
    connect_bd_intf_net [get_bd_intf_pins ctrl_sc/M04_AXI] [get_bd_intf_pins weight_bram128_0/s_axi]
    connect_bd_net [get_bd_pins axi_gemm_stream_0/w_word_addr] [get_bd_pins weight_bram128_0/w_word_addr]
    connect_bd_net [get_bd_pins weight_bram128_0/w_word] [get_bd_pins axi_gemm_stream_0/w_word]
}
connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA] [get_bd_intf_pins bram_0/BRAM_PORTA]

# CDMA data fabric: a native 64-bit AXI master and a protocol/ID adapter in
# front of the 64-bit Zynq HP0 slave. No hidden width comparison is claimed.
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 hp_sc
set_property -dict [list \
    CONFIG.NUM_SI [expr {$raw_full_enabled ? 3 : \
        ($av_diag_enabled ? 3 : ($kv_smoke_enabled ? 2 : 1))}] \
    CONFIG.NUM_MI {1}] [get_bd_cells hp_sc]
connect_bd_intf_net [get_bd_intf_pins axi_cdma_0/M_AXI] [get_bd_intf_pins hp_sc/S00_AXI]
if {$kv_smoke_enabled} {
    connect_bd_intf_net [get_bd_intf_pins axi_kv_cache_0/m_axi] \
        [get_bd_intf_pins hp_sc/S01_AXI]
}
if {$av_diag_enabled} {
    connect_bd_intf_net [get_bd_intf_pins axi_v5_av_diag_0/m_axi] \
        [get_bd_intf_pins hp_sc/S02_AXI]
}
if {$raw_full_enabled} {
    connect_bd_intf_net [get_bd_intf_pins axi_kvq_raw_full_diag_0/m_axi_k] \
        [get_bd_intf_pins hp_sc/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_kvq_raw_full_diag_0/m_axi_v] \
        [get_bd_intf_pins hp_sc/S02_AXI]
}
connect_bd_intf_net [get_bd_intf_pins hp_sc/M00_AXI]    [get_bd_intf_pins ps7_0/S_AXI_HP0]

connect_bd_net $PL_CLK \
    [get_bd_pins ps7_0/M_AXI_GP0_ACLK] \
    [get_bd_pins ps7_0/S_AXI_HP0_ACLK] \
    [get_bd_pins ctrl_sc/ACLK] \
    [get_bd_pins ctrl_sc/S00_ACLK] \
    [get_bd_pins ctrl_sc/M00_ACLK] \
    [get_bd_pins ctrl_sc/M01_ACLK] \
    [get_bd_pins hp_sc/aclk] \
    [get_bd_pins axi_bram_ctrl_0/s_axi_aclk] \
    [get_bd_pins axi_cdma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_cdma_0/m_axi_aclk]
if {$kv_smoke_enabled} {
    connect_bd_net $PL_CLK \
        [get_bd_pins ctrl_sc/M02_ACLK] \
        [get_bd_pins axi_kv_cache_0/clk]
}
if {$av_diag_enabled} {
    connect_bd_net $PL_CLK \
        [get_bd_pins ctrl_sc/M03_ACLK] \
        [get_bd_pins axi_v5_av_diag_0/clk]
}
if {$raw_full_enabled} {
    connect_bd_net $PL_CLK \
        [get_bd_pins ctrl_sc/M02_ACLK] \
        [get_bd_pins axi_kvq_raw_full_diag_0/clk]
}
if {$canned_page_enabled} {
    connect_bd_net $PL_CLK \
        [get_bd_pins ctrl_sc/M02_ACLK] \
        [get_bd_pins axi_kvq_canned_page_diag_0/clk]
}
if {$raw_e2e_enabled} {
    connect_bd_net $PL_CLK [get_bd_pins ctrl_sc/M03_ACLK] [get_bd_pins ctrl_sc/M04_ACLK] \
        [get_bd_pins axi_gemm_stream_0/clk] [get_bd_pins weight_bram128_0/clk]
}
connect_bd_net $AXI_RST_N \
    [get_bd_pins ctrl_sc/ARESETN] \
    [get_bd_pins ctrl_sc/S00_ARESETN] \
    [get_bd_pins ctrl_sc/M00_ARESETN] \
    [get_bd_pins ctrl_sc/M01_ARESETN] \
    [get_bd_pins hp_sc/aresetn]
if {$kv_smoke_enabled} {
    connect_bd_net $AXI_RST_N [get_bd_pins ctrl_sc/M02_ARESETN]
}
if {$av_diag_enabled} {
    connect_bd_net $AXI_RST_N [get_bd_pins ctrl_sc/M03_ARESETN]
}
if {$raw_full_enabled} {
    connect_bd_net $AXI_RST_N [get_bd_pins ctrl_sc/M02_ARESETN]
}
if {$canned_page_enabled} {
    connect_bd_net $AXI_RST_N [get_bd_pins ctrl_sc/M02_ARESETN]
}
if {$raw_e2e_enabled} {
    connect_bd_net $AXI_RST_N [get_bd_pins ctrl_sc/M03_ARESETN] [get_bd_pins ctrl_sc/M04_ARESETN]
}
connect_bd_net $PL_RST_N \
    [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn] \
    [get_bd_pins axi_cdma_0/s_axi_lite_aresetn]
if {$kv_smoke_enabled} {
    connect_bd_net $PL_RST_N [get_bd_pins axi_kv_cache_0/rst_n]
}
if {$av_diag_enabled} {
    connect_bd_net $PL_RST_N [get_bd_pins axi_v5_av_diag_0/rst_n]
}
if {$raw_full_enabled} {
    connect_bd_net $PL_RST_N [get_bd_pins axi_kvq_raw_full_diag_0/rst_n]
}
if {$canned_page_enabled} {
    connect_bd_net $PL_RST_N \
        [get_bd_pins axi_kvq_canned_page_diag_0/rst_n]
}
if {$raw_e2e_enabled} {
    connect_bd_net $PL_RST_N [get_bd_pins axi_gemm_stream_0/rst_n] [get_bd_pins weight_bram128_0/rst_n]
}
set cdma_m_axi_reset_pins [get_bd_pins -quiet axi_cdma_0/m_axi_aresetn]
if {[llength $cdma_m_axi_reset_pins] > 1} {
    error "expected at most one AXI CDMA master reset pin, got: $cdma_m_axi_reset_pins"
}
if {[llength $cdma_m_axi_reset_pins] == 1} {
    connect_bd_net $PL_RST_N [lindex $cdma_m_axi_reset_pins 0]
}

# Deterministic GP0 map.
assign_bd_address -target_address_space [get_bd_addr_spaces ps7_0/Data] \
    [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0]
assign_bd_address -target_address_space [get_bd_addr_spaces ps7_0/Data] \
    [get_bd_addr_segs axi_cdma_0/S_AXI_LITE/Reg]
set bram_segment [get_bd_addr_segs ps7_0/Data/SEG_axi_bram_ctrl_0_Mem0]
set cdma_segment [get_bd_addr_segs ps7_0/Data/SEG_axi_cdma_0_Reg]
set_property offset 0x43C00000 $bram_segment
set_property range  64K        $bram_segment
set_property offset 0x43C10000 $cdma_segment
set_property range  64K        $cdma_segment
if {$kv_smoke_enabled} {
    assign_bd_address -target_address_space [get_bd_addr_spaces ps7_0/Data] \
        [get_bd_addr_segs axi_kv_cache_0/s_axi/reg0]
    set kv_ctrl_segment [get_bd_addr_segs ps7_0/Data/SEG_axi_kv_cache_0_reg0]
    set_property offset 0x43C20000 $kv_ctrl_segment
    set_property range  64K        $kv_ctrl_segment
}
if {$av_diag_enabled} {
    assign_bd_address -target_address_space [get_bd_addr_spaces ps7_0/Data] \
        [get_bd_addr_segs axi_v5_av_diag_0/s_axi/reg0]
    set av_diag_ctrl_segment \
        [get_bd_addr_segs ps7_0/Data/SEG_axi_v5_av_diag_0_reg0]
    set_property offset 0x43C30000 $av_diag_ctrl_segment
    set_property range  64K        $av_diag_ctrl_segment
}
if {$raw_full_enabled} {
    assign_bd_address -target_address_space [get_bd_addr_spaces ps7_0/Data] \
        [get_bd_addr_segs axi_kvq_raw_full_diag_0/s_axi/reg0]
    set raw_full_ctrl_segment \
        [get_bd_addr_segs ps7_0/Data/SEG_axi_kvq_raw_full_diag_0_reg0]
    set_property offset 0x43C20000 $raw_full_ctrl_segment
    set_property range  64K        $raw_full_ctrl_segment
}
if {$canned_page_enabled} {
    assign_bd_address -target_address_space [get_bd_addr_spaces ps7_0/Data] \
        [get_bd_addr_segs axi_kvq_canned_page_diag_0/s_axi/reg0]
    set canned_page_ctrl_segment \
        [get_bd_addr_segs ps7_0/Data/SEG_axi_kvq_canned_page_diag_0_reg0]
    set_property offset 0x43C20000 $canned_page_ctrl_segment
    set_property range  64K        $canned_page_ctrl_segment
}
if {$raw_e2e_enabled} {
    assign_bd_address -target_address_space [get_bd_addr_spaces ps7_0/Data] [get_bd_addr_segs axi_gemm_stream_0/s_axi/reg0]
    set projection_ctrl_segment [get_bd_addr_segs ps7_0/Data/SEG_axi_gemm_stream_0_reg0]
    set_property offset 0x43C30000 $projection_ctrl_segment
    set_property range 64K $projection_ctrl_segment
    assign_bd_address -target_address_space [get_bd_addr_spaces ps7_0/Data] [get_bd_addr_segs weight_bram128_0/s_axi/reg0]
    set projection_weight_segment [get_bd_addr_segs ps7_0/Data/SEG_weight_bram128_0_reg0]
    set_property offset 0x44000000 $projection_weight_segment
    set_property range 256K $projection_weight_segment
}

# Explicitly include the PS DDR aperture in the CDMA master address space.
set hp_ddr_slave [get_bd_addr_segs -quiet ps7_0/S_AXI_HP0/HP0_DDR_LOWOCM]
if {[llength $hp_ddr_slave] != 1} {
    error "expected one PS HP0 DDR slave segment, got: $hp_ddr_slave"
}
assign_bd_address -target_address_space [get_bd_addr_spaces axi_cdma_0/Data] $hp_ddr_slave
set cdma_ddr_segments {}
foreach segment [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces axi_cdma_0/Data]] {
    if {[string match "*HP0_DDR*" $segment]} {
        lappend cdma_ddr_segments $segment
    }
}
if {[llength $cdma_ddr_segments] != 1} {
    error "CDMA must have exactly one included HP0 DDR segment; got: $cdma_ddr_segments"
}
set_property offset 0x00000000 [lindex $cdma_ddr_segments 0]
set_property range  1G         [lindex $cdma_ddr_segments 0]
if {$kv_smoke_enabled} {
    assign_bd_address -target_address_space \
        [get_bd_addr_spaces axi_kv_cache_0/m_axi] $hp_ddr_slave
    set kv_ddr_segments {}
    foreach segment [get_bd_addr_segs -quiet -of_objects \
            [get_bd_addr_spaces axi_kv_cache_0/m_axi]] {
        if {[string match "*HP0_DDR*" $segment]} {
            lappend kv_ddr_segments $segment
        }
    }
    if {[llength $kv_ddr_segments] != 1} {
        error "KV master must have exactly one included HP0 DDR segment; got: $kv_ddr_segments"
    }
    set_property offset 0x00000000 [lindex $kv_ddr_segments 0]
    set_property range  1G         [lindex $kv_ddr_segments 0]
}
if {$av_diag_enabled} {
    assign_bd_address -target_address_space \
        [get_bd_addr_spaces axi_v5_av_diag_0/m_axi] $hp_ddr_slave
    set av_diag_ddr_segments {}
    foreach segment [get_bd_addr_segs -quiet -of_objects \
            [get_bd_addr_spaces axi_v5_av_diag_0/m_axi]] {
        if {[string match "*HP0_DDR*" $segment]} {
            lappend av_diag_ddr_segments $segment
        }
    }
    if {[llength $av_diag_ddr_segments] != 1} {
        error "AV diagnostic master must have exactly one included HP0 DDR segment; got: $av_diag_ddr_segments"
    }
    set_property offset 0x00000000 [lindex $av_diag_ddr_segments 0]
    set_property range  1G         [lindex $av_diag_ddr_segments 0]
}
if {$raw_full_enabled} {
    foreach master_name {m_axi_k m_axi_v} {
        set raw_full_space \
            [get_bd_addr_spaces axi_kvq_raw_full_diag_0/$master_name]
        assign_bd_address -target_address_space $raw_full_space $hp_ddr_slave
        set raw_full_ddr_segments {}
        foreach segment [get_bd_addr_segs -quiet -of_objects $raw_full_space] {
            if {[string match "*HP0_DDR*" $segment]} {
                lappend raw_full_ddr_segments $segment
            }
        }
        if {[llength $raw_full_ddr_segments] != 1} {
            error "raw-full $master_name must have exactly one included HP0 DDR segment; got: $raw_full_ddr_segments"
        }
        set_property offset 0x00000000 [lindex $raw_full_ddr_segments 0]
        set_property range  1G         [lindex $raw_full_ddr_segments 0]
    }
}

validate_bd_design
source [file join $script_dir assert_bringup_platform.tcl]
if {[catch {assert_bringup_platform $pl_clock_mhz $kv_m_axi_data_width \
        $av_m_axi_data_width $raw_full_m_axi_data_width \
        $raw_full_scale_width $raw_full_qk_mult_style \
        $raw_full_av_mult_style $raw_full_profile \
        $canned_page_scale_bits $canned_page_qk_mult_style \
        $canned_page_av_mult_style $canned_page_profile \
        $canned_page_compiled_profile_id \
        $canned_page_compiled_k_codebook_id \
        $canned_page_compiled_v_codebook_id} \
        assertion_message assertion_options]} {
    puts stderr "ZYBO BRING-UP ASSERTION ERROR: $assertion_message"
    if {[dict exists $assertion_options -errorinfo]} {
        puts stderr [dict get $assertion_options -errorinfo]
    }
    return -options $assertion_options $assertion_message
}
save_bd_design

set bd_file [get_files -quiet ${bd_name}.bd]
if {[llength $bd_file] != 1} {
    error "expected one generated block-design file, got: $bd_file"
}
set wrappers [make_wrapper -fileset sources_1 -files $bd_file -top]
if {[llength $wrappers] != 1} {
    error "expected make_wrapper to return one generated wrapper, got: $wrappers"
}
set wrapper [lindex $wrappers 0]
if {![file exists $wrapper]} {
    error "block-design wrapper was not generated: $wrapper"
}
add_files -norecurse -fileset sources_1 $wrapper
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1
bringup_verify_source_hashes $repo_root $source_hashes
close_project

bringup_write_exclusive [file join $output_dir .create_complete] \
    "created_utc=[clock format [clock seconds] -gmt true -format {%Y-%m-%dT%H:%M:%SZ}]\n"
puts [format "CREATED temporary Zybo bring-up platform: %s at %.3f MHz" $project_dir $pl_clock_mhz]
puts "Identity and immutable source snapshots: $identity_dir"
puts "This is transport bring-up only; it is not the final KVQ topology."
puts "ZYBO_PLATFORM_CREATE_PASS"
