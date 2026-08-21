# Portable Vivado 2025.1 IP packaging for the canned page128 KVQ diagnostic.
# SPDX-License-Identifier: CERN-OHL-S-2.0
#
# This board-gated packager writes only to a fresh external D: directory.  It
# snapshots and hashes the exact inputs before Vivado imports them, packages a
# Zynq-7000 Production AXI-Lite core with exact parameter provenance, and
# rediscovers the core in an xc7z020 project.
#
# Vivado opens its log and journal before this script starts.  Put both at
# explicit external paths and archive them with OUTPUT_ROOT.  Example:
#   vivado -mode batch \
#     -log D:/tc-logs/axi-kvq-canned-page-package.log \
#     -journal D:/tc-logs/axi-kvq-canned-page-package.jou \
#     -source ip/package_axi_kvq_canned_page_diag_portable.tcl \
#     -tclargs REPO_ROOT OUTPUT_ROOT PART CLOCK_HZ SCALE_BITS DECODE_LANES QK_MULT_STYLE AV_MULT_STYLE

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

proc portable_write_file {path contents} {
    set handle [open $path w]
    try {
        puts -nonewline $handle $contents
    } finally {
        close $handle
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

proc portable_prepare_input_snapshot {repo_root output_root input_files} {
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

    set manifest ""
    set expected_files {}
    foreach entry $entries {
        lassign $entry relative source digest
        append manifest "$digest  $relative\n"
        lappend expected_files $relative
    }

    file mkdir $inputs_dir
    foreach entry $entries {
        lassign $entry relative source digest
        set destination [file join $inputs_dir $relative]
        file mkdir [file dirname $destination]
        file copy $source $destination
    }
    portable_write_file $manifest_path $manifest

    set actual_files [portable_collect_relative_files $inputs_dir]
    if {$actual_files ne [lsort $expected_files]} {
        error "input snapshot file set does not match its manifest: $inputs_dir"
    }
    foreach entry $entries {
        lassign $entry relative source digest
        set snapshot [file join $inputs_dir $relative]
        if {![file isfile $snapshot] ||
            [portable_sha256 $snapshot] ne $digest} {
            error "input snapshot hash mismatch: $snapshot"
        }
    }
    return $inputs_dir
}

proc portable_snapshot_path {repo_root inputs_dir source} {
    return [file join $inputs_dir \
        [portable_repo_relative $source $repo_root]]
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

    # Reject symbolic-link/reparse paths in the existing output chain.  This
    # prevents an apparently external path from redirecting back into a Git
    # worktree or another constrained location.
    set ancestor [expr {[file exists $normalized] ? $normalized : $parent}]
    while {1} {
        if {[file type $ancestor] eq "link"} {
            error "$label path chain contains a link/reparse path: $ancestor"
        }
        set next [file dirname $ancestor]
        if {[portable_compare_path $next] eq [portable_compare_path $ancestor]} {
            break
        }
        set ancestor $next
    }
}

if {$argc != 8} {
    error "usage: package_axi_kvq_canned_page_diag_portable.tcl REPO_ROOT OUTPUT_ROOT PART CLOCK_HZ SCALE_BITS DECODE_LANES QK_MULT_STYLE AV_MULT_STYLE"
}
if {[file pathtype [lindex $argv 0]] ne "absolute" ||
    [file pathtype [lindex $argv 1]] ne "absolute"} {
    error "REPO_ROOT and OUTPUT_ROOT must both be absolute paths"
}

set repo_root [file normalize [lindex $argv 0]]
set output_root [file normalize [lindex $argv 1]]
set requested_part [string trim [lindex $argv 2]]
set clock_hz [string trim [lindex $argv 3]]
set scale_bits [string trim [lindex $argv 4]]
set decode_lanes [string trim [lindex $argv 5]]
set qk_mult_style [string trim [lindex $argv 6]]
set av_mult_style [string trim [lindex $argv 7]]

if {![file isdirectory $repo_root]} {
    error "repository root does not exist: $repo_root"
}
if {![string equal -nocase $requested_part "xc7z020clg400-1"]} {
    error "PART must be exactly xc7z020clg400-1 for the Zybo Z7-20 board gate; got '$requested_part'"
}
if {![string is integer -strict $clock_hz] ||
    $clock_hz ni {75000000 76923080 81250000}} {
    error "CLOCK_HZ must be exactly 75000000, 76923080, or 81250000; got '$clock_hz'"
}
if {![string is integer -strict $scale_bits] ||
    $scale_bits ni {12 16}} {
    error "SCALE_BITS must be exactly 12 or 16; got '$scale_bits'"
}
if {![string is integer -strict $decode_lanes] ||
    $decode_lanes ni {2 4}} {
    error "DECODE_LANES must be exactly 2 or 4; got '$decode_lanes'"
}
if {![string is integer -strict $qk_mult_style] || $qk_mult_style != 2} {
    error "QK_MULT_STYLE must be exactly 2 (AUTO) for the Zybo canned-page profiles; got '$qk_mult_style'"
}
if {![string is integer -strict $av_mult_style] ||
    $av_mult_style ni {1 2}} {
    error "AV_MULT_STYLE must be exactly 1 (DSP) or 2 (AUTO); got '$av_mult_style'"
}
set canned_page_profile \
    [expr {$av_mult_style == 1 ? "LUT_RELIEF" : "BALANCED"}]

portable_require_safe_output $output_root $repo_root "OUTPUT_ROOT"
if {[portable_path_is_within $output_root $repo_root] ||
    [portable_path_is_within $repo_root $output_root]} {
    error "OUTPUT_ROOT and the repository must be disjoint directory trees: $output_root"
}
if {[file dirname $output_root] eq $output_root} {
    error "refusing to use a filesystem root as OUTPUT_ROOT: $output_root"
}
if {[file exists $output_root] && ![file isdirectory $output_root]} {
    error "OUTPUT_ROOT exists and is not a directory: $output_root"
}
set existing_entries [portable_directory_entries $output_root]
if {[llength $existing_entries] > 0} {
    error "OUTPUT_ROOT must be new or empty; refusing to overwrite [join $existing_entries {, }]"
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

set ip_name "axi_kvq_canned_page_diag"
set ip_vendor "shepherdscientific.com"
set ip_library "user"
set ip_version "1.0"
set ip_vlnv "${ip_vendor}:${ip_library}:${ip_name}:${ip_version}"
set ip_display "Canned Page KVQ Diagnostic"
set ip_desc "Host-loaded CRC-gated RAW/COMPRESSED page128 decode and checkpoint-independent KVQ arithmetic diagnostic over AXI-Lite."
set supported_families {zynq Production}
set catalog_smoke_parts [list $part]

set rtl_files {}
foreach rtl_name {
    axi_kvq_canned_page_diag.v
    kv_v03_typed_decode_lane_bank_4x1.v
    kv_v03_symbol_decoder.v
    kv_v03_scale12_reader.v
    kv_v03_page128_record_validator.v
    kv_v03_page_header.v
    kv_v03_crc32.v
    kv_v03_canned_page_arithmetic.v
    qk_group_dot.v
    kv_v03_qk_score_quantizer.v
    kv_v03_score_row_commit_guard.v
    kv_v03_softmax_engine.v
    kv_v03_score_store.v
    kv_v03_exp_lut.v
    kv_v03_reciprocal.v
    kv_v03_softmax.v
    kv_v03_av_accumulator.v
    kv_v03_v5_weight_mul.v
    kv_v03_av_normalizer.v
} {
    set rtl_path [file join $repo_root rtl $rtl_name]
    if {![file isfile $rtl_path]} {
        error "required RTL source is missing: $rtl_path"
    }
    lappend rtl_files $rtl_path
}

set git_commit [portable_git_value $repo_root rev-parse --verify HEAD]
set git_status [portable_git_value $repo_root status --porcelain=v1 \
                --untracked-files=all]
set git_status_crc32 [format %08x \
    [expr {[zlib crc32 $git_status] & 0xffffffff}]]
set script_path [file normalize [info script]]
set script_blob [portable_git_value $repo_root hash-object -- $script_path]
set script_sha256 [portable_sha256 $script_path]

set identity "schema=2\n"
append identity "flow=axi_kvq_canned_page_diag_portable_package\n"
append identity "vivado_version=$vivado_version\n"
append identity "vivado_full_version=[portable_identity_escape $vivado_full_version]\n"
append identity "part=$part\n"
append identity "clock_hz=$clock_hz\n"
append identity "scale_bits=$scale_bits\n"
append identity "decode_lanes=$decode_lanes\n"
append identity "qk_mult_style=$qk_mult_style\n"
append identity "av_mult_style=$av_mult_style\n"
append identity "canned_page_profile=$canned_page_profile\n"
append identity "compiled_profile_id=51\n"
append identity "compiled_k_codebook_id=1\n"
append identity "compiled_v_codebook_id=2\n"
append identity "ip_vlnv=$ip_vlnv\n"
append identity "supported_families=[join $supported_families ,]\n"
append identity "catalog_smoke_parts=[join $catalog_smoke_parts ,]\n"
append identity "transcript_policy=external_vivado_log_and_journal_required\n"
append identity "repo_root=[string map {\\ /} $repo_root]\n"
append identity "git_executable=[string map {\\ /} [portable_resolve_git]]\n"
append identity "git_executable_source=$::portable_git_source_cache\n"
append identity "git_executable_sha256=[portable_sha256 [portable_resolve_git]]\n"
append identity "git_version=[portable_identity_escape $::portable_git_version_cache]\n"
append identity "git_commit=$git_commit\n"
append identity "git_dirty=[expr {$git_status ne ""}]\n"
append identity "git_status_crc32=$git_status_crc32\n"
append identity "packager_git_blob=$script_blob\n"
append identity "packager_sha256=$script_sha256\n"
foreach source $rtl_files {
    set relative [portable_repo_relative $source $repo_root]
    set blob [portable_git_value $repo_root hash-object -- $source]
    append identity "source.$relative.git_blob=$blob\n"
    append identity "source.$relative.sha256=[portable_sha256 $source]\n"
}

file mkdir $output_root
portable_write_file [file join $output_root package_identity.txt] $identity
set input_files [concat [list $script_path] $rtl_files]
set inputs_dir [portable_prepare_input_snapshot \
    $repo_root $output_root $input_files]
set package_rtl_files {}
foreach source $rtl_files {
    lappend package_rtl_files \
        [portable_snapshot_path $repo_root $inputs_dir $source]
}

# Keep incidental Vivado runtime files beside the external package output.
# The launcher log and journal must use explicit external paths because they
# are opened before this script can change directory.
cd $output_root
puts "PORTABLE_TRANSCRIPT_REQUIRED preserve the external Vivado -log and -journal files with $output_root"

set work_root [file join $output_root work]
set project_dir [file join $work_root ${ip_name}_pkg]
set ip_repo_dir [file join $output_root ip]
set package_root [file join $ip_repo_dir $ip_name]
file mkdir $work_root
file mkdir $ip_repo_dir

create_project -force ${ip_name}_pkg $project_dir -part $part
add_files -norecurse $package_rtl_files
set_property top $ip_name [current_fileset]

ipx::package_project -root_dir $package_root \
    -vendor $ip_vendor -library $ip_library -taxonomy /UserIP -import_files

set core [ipx::current_core]
set_property name $ip_name $core
set_property version $ip_version $core
set_property display_name $ip_display $core
set_property description $ip_desc $core
set_property vendor_display_name "Shepherd Scientific" $core
set_property company_url "https://github.com/ahnhy1324/ternarycore" $core
set_property supported_families $supported_families $core

# The Verilog parameters are imported into both the HDL model and the user
# customization model.  Require every top-level parameter to be present so a
# source/signature mismatch fails closed instead of producing a misleading IP.
set parameter_names {
    MAX_CONTEXT
    SCALE_BITS
    DECODE_LANES
    COMPILED_PROFILE_ID
    COMPILED_K_CODEBOOK_ID
    COMPILED_V_CODEBOOK_ID
    QK_MULT_STYLE
    AV_MULT_STYLE
    C_S_AXI_DATA_WIDTH
    C_S_AXI_ADDR_WIDTH
}
foreach parameter_name $parameter_names {
    set user_parameter [ipx::get_user_parameters $parameter_name \
        -of_objects $core]
    set hdl_parameter [ipx::get_hdl_parameters $parameter_name \
        -of_objects $core]
    if {[llength $user_parameter] != 1 || [llength $hdl_parameter] != 1} {
        error "expected exactly one exposed user/HDL parameter '$parameter_name'; found user=[llength $user_parameter] hdl=[llength $hdl_parameter]"
    }
}
foreach {parameter_name value} [list \
    MAX_CONTEXT 128 \
    SCALE_BITS $scale_bits \
    DECODE_LANES $decode_lanes \
    COMPILED_PROFILE_ID 51 \
    COMPILED_K_CODEBOOK_ID 1 \
    COMPILED_V_CODEBOOK_ID 2 \
    QK_MULT_STYLE $qk_mult_style \
    AV_MULT_STYLE $av_mult_style] {
    set user_parameter [ipx::get_user_parameters $parameter_name -of_objects $core]
    set hdl_parameter [ipx::get_hdl_parameters $parameter_name -of_objects $core]
    set_property value $value [lindex $user_parameter 0]
    set_property value $value [lindex $hdl_parameter 0]
}

# The AXI-Lite control interface shares the board fabric clock/reset.
foreach busif_name {s_axi clk rst_n} {
    set busif [ipx::get_bus_interfaces $busif_name -of_objects $core]
    if {[llength $busif] != 1} {
        error "expected exactly one packaged '$busif_name' interface; found [llength $busif]"
    }
}
ipx::associate_bus_interfaces -busif s_axi -clock clk $core
ipx::associate_bus_interfaces -clock clk -reset rst_n $core

set clk_if [ipx::get_bus_interfaces clk -of_objects $core]
set freq_hz [ipx::get_bus_parameters FREQ_HZ -of_objects $clk_if]
if {[llength $freq_hz] == 0} {
    ipx::add_bus_parameter FREQ_HZ $clk_if
    set freq_hz [ipx::get_bus_parameters FREQ_HZ -of_objects $clk_if]
}
if {[llength $freq_hz] != 1} {
    error "expected exactly one clk FREQ_HZ parameter; found [llength $freq_hz]"
}
set_property value $clock_hz [lindex $freq_hz 0]

set associated_busif [ipx::get_bus_parameters ASSOCIATED_BUSIF \
    -of_objects $clk_if]
if {[llength $associated_busif] != 1} {
    error "expected exactly one clk ASSOCIATED_BUSIF parameter; found [llength $associated_busif]"
}
set associated_busif_names [split \
    [get_property VALUE [lindex $associated_busif 0]] :]
foreach required_busif {s_axi} {
    if {[lsearch -exact $associated_busif_names $required_busif] < 0} {
        error "clk ASSOCIATED_BUSIF omits required interface '$required_busif': $associated_busif_names"
    }
}
set associated_reset [ipx::get_bus_parameters ASSOCIATED_RESET \
    -of_objects $clk_if]
if {[llength $associated_reset] != 1} {
    error "expected exactly one clk ASSOCIATED_RESET parameter; found [llength $associated_reset]"
}
set associated_reset_names [split \
    [get_property VALUE [lindex $associated_reset 0]] :]
if {[lsearch -exact $associated_reset_names rst_n] < 0} {
    error "clk ASSOCIATED_RESET omits rst_n: $associated_reset_names"
}
set rst_if [ipx::get_bus_interfaces rst_n -of_objects $core]
set reset_polarity [ipx::get_bus_parameters POLARITY -of_objects $rst_if]
if {[llength $reset_polarity] != 1 ||
    ![string equal -nocase \
        [get_property VALUE [lindex $reset_polarity 0]] ACTIVE_LOW]} {
    error "packaged rst_n interface is not explicitly ACTIVE_LOW"
}

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
close_project

set component_xml [file join $package_root component.xml]
if {![file isfile $component_xml]} {
    error "packaging did not create component.xml: $component_xml"
}

# get_ipdefs without -all excludes definitions unsupported by the active part.
set catalog_result "vivado_version=$vivado_version\n"
append catalog_result \
    "vivado_full_version=[portable_identity_escape $vivado_full_version]\n"
append catalog_result "ip_vlnv=$ip_vlnv\n"
append catalog_result "clock_hz=$clock_hz\n"
append catalog_result "scale_bits=$scale_bits\n"
append catalog_result "decode_lanes=$decode_lanes\n"
append catalog_result "qk_mult_style=$qk_mult_style\n"
append catalog_result "av_mult_style=$av_mult_style\n"
append catalog_result "canned_page_profile=$canned_page_profile\n"
foreach smoke_part $catalog_smoke_parts {
    create_project -in_memory -part $smoke_part
    set_property ip_repo_paths [list $ip_repo_dir] [current_project]
    update_ip_catalog -rebuild
    set discovered [get_ipdefs -quiet $ip_vlnv]
    if {[llength $discovered] != 1} {
        error "catalog smoke expected one '$ip_vlnv' definition for $smoke_part; found [llength $discovered]"
    }
    append catalog_result \
        "part.$smoke_part.definition=[lindex $discovered 0]\n"
    append catalog_result "part.$smoke_part.status=PASS\n"
    close_project
}
append catalog_result "status=PASS\n"
portable_write_file [file join $output_root catalog_smoke.txt] $catalog_result

puts "PORTABLE_IP_PACKAGE_PASS vlnv=$ip_vlnv part=$part clock_hz=$clock_hz scale_bits=$scale_bits decode_lanes=$decode_lanes qk_mult_style=$qk_mult_style av_mult_style=$av_mult_style canned_page_profile=$canned_page_profile compiled_profile_id=51 k_codebook_id=1 v_codebook_id=2 root=$package_root"
