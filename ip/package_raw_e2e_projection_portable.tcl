# Vivado 2025.1 packaging for the RAW-E2E projection-only pair.
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Usage: ... -tclargs REPO_ROOT OUTPUT_ROOT PART CLOCK_HZ

proc e2e_write {path text} {
    set fh [open $path w]
    puts -nonewline $fh $text
    close $fh
}

proc e2e_sha256 {path} {
    if {![file isfile $path]} { error "missing file for SHA-256: $path" }
    if {[catch {exec certutil -hashfile $path SHA256} output] ||
        ![regexp -nocase {([0-9a-f]{64})} $output -> digest]} {
        error "SHA-256 failed for $path: $output"
    }
    return [string toupper $digest]
}

proc e2e_git {repo args} {
    if {![info exists ::env(TERNARYCORE_GIT_EXECUTABLE)] ||
        ![file isfile $::env(TERNARYCORE_GIT_EXECUTABLE)]} {
        error "TERNARYCORE_GIT_EXECUTABLE must name the pinned absolute git.exe"
    }
    if {[catch {exec $::env(TERNARYCORE_GIT_EXECUTABLE) -C $repo {*}$args} output]} {
        error "git [join $args { }] failed: $output"
    }
    return [string trim $output]
}

proc e2e_set_parameter {core name value} {
    set user [ipx::get_user_parameters $name -of_objects $core]
    set hdl [ipx::get_hdl_parameters $name -of_objects $core]
    if {[llength $user] != 1 || [llength $hdl] != 1} {
        error "expected one user/HDL parameter $name; user=[llength $user] hdl=[llength $hdl]"
    }
    set_property value $value [lindex $user 0]
    set_property value $value [lindex $hdl 0]
}

proc e2e_package {name display description project_dir package_root part files parameters clock_hz} {
    create_project -force ${name}_pkg $project_dir -part $part
    add_files -norecurse $files
    set_property top $name [current_fileset]
    ipx::package_project -root_dir $package_root -vendor shepherdscientific.com \
        -library user -taxonomy /UserIP -import_files
    set core [ipx::current_core]
    set_property name $name $core
    set_property version 1.0 $core
    set_property display_name $display $core
    set_property description $description $core
    set_property vendor_display_name "Shepherd Scientific" $core
    set_property supported_families {zynq Production} $core
    foreach {parameter value} $parameters { e2e_set_parameter $core $parameter $value }
    foreach busif_name {s_axi clk rst_n} {
        set busif [ipx::get_bus_interfaces $busif_name -of_objects $core]
        if {[llength $busif] != 1} { error "$name expected one $busif_name interface; got [llength $busif]" }
    }
    ipx::associate_bus_interfaces -busif s_axi -clock clk $core
    ipx::associate_bus_interfaces -clock clk -reset rst_n $core
    set clk_if [ipx::get_bus_interfaces clk -of_objects $core]
    set freq [ipx::get_bus_parameters FREQ_HZ -of_objects $clk_if]
    if {[llength $freq] == 0} {
        ipx::add_bus_parameter FREQ_HZ $clk_if
        set freq [ipx::get_bus_parameters FREQ_HZ -of_objects $clk_if]
    }
    if {[llength $freq] != 1} { error "$name clock FREQ_HZ missing/duplicated" }
    set_property value $clock_hz [lindex $freq 0]
    ipx::create_xgui_files $core
    ipx::update_checksums $core
    ipx::check_integrity $core
    ipx::save_core $core
    close_project
    set component [file join $package_root component.xml]
    if {![file isfile $component]} { error "$name component.xml was not created" }
    return $component
}

if {$argc != 4} {
    error "usage: package_raw_e2e_projection_portable.tcl REPO_ROOT OUTPUT_ROOT PART CLOCK_HZ"
}
set repo_root [file normalize [lindex $argv 0]]
set output_root [file normalize [lindex $argv 1]]
set part [string trim [lindex $argv 2]]
set clock_hz [string trim [lindex $argv 3]]
if {![file isdirectory $repo_root]} { error "repo missing: $repo_root" }
if {![string equal -nocase $part xc7z020clg400-1]} { error "part must be xc7z020clg400-1" }
if {$clock_hz ni {75000000 81250000}} { error "clock must be 75000000 or 81250000" }
if {![regexp {^2025\.1($|[._-])} [version -short]]} { error "Vivado 2025.1 required" }
if {[llength [get_parts -quiet $part]] != 1} { error "part is not installed exactly once: $part" }
set volume [string trimright [lindex [file split $output_root] 0] "/\\"]
if {![string equal -nocase $volume D:]} { error "OUTPUT_ROOT must be on D:" }
if {[file exists $output_root] && [llength [glob -nocomplain -directory $output_root * .*]] > 2} {
    error "OUTPUT_ROOT must be new/empty: $output_root"
}
if {[string first [string tolower [string map {\\ /} $repo_root]] \
        [string tolower [string map {\\ /} $output_root]]] == 0} {
    error "OUTPUT_ROOT must be outside the repository"
}
set status [e2e_git $repo_root status --porcelain=v1 --untracked-files=all]
if {$status ne ""} { error "repository must be clean before packaging:\n$status" }
set commit [e2e_git $repo_root rev-parse HEAD]

set source_relpaths {
    rtl/axi_gemm_stream.v
    rtl/weight_bram128.v
    rtl/ternary_gemm.v
    rtl/ternary_dot.v
    rtl/ternary_weight.v
}
file mkdir [file join $output_root inputs]
set manifest "schema=1\nflow=raw_e2e_projection_package\ncommit=$commit\npart=$part\nclock_hz=$clock_hz\n"
set snapshot_files {}
foreach relative $source_relpaths {
    set source [file join $repo_root $relative]
    if {![file isfile $source]} { error "required source missing: $source" }
    set destination [file join $output_root inputs $relative]
    file mkdir [file dirname $destination]
    file copy $source $destination
    set digest [e2e_sha256 $destination]
    append manifest "source.$relative.sha256=$digest\n"
    dict set snapshots $relative $destination
}
set packager [file normalize [info script]]
append manifest "packager_sha256=[e2e_sha256 $packager]\n"
e2e_write [file join $output_root package_identity.txt] $manifest

cd $output_root
file mkdir [file join $output_root work]
file mkdir [file join $output_root ip]
set projection_files [list [dict get $snapshots rtl/axi_gemm_stream.v] \
    [dict get $snapshots rtl/ternary_gemm.v] [dict get $snapshots rtl/ternary_dot.v] \
    [dict get $snapshots rtl/ternary_weight.v]]
set projection_component [e2e_package axi_gemm_stream \
    "Tier2 COLS64 Projection Only" \
    "COLS64 ternary projection with legacy INT8 attention permanently disabled." \
    [file join $output_root work axi_gemm_stream_pkg] \
    [file join $output_root ip axi_gemm_stream] $part $projection_files \
    [list DEPTH_MAX 1024 COLS 64 ACC_WIDTH 32 WADDR_W 14 ENABLE_INT8 0] $clock_hz]
set weight_component [e2e_package weight_bram128 \
    "Tier2 128-bit Weight Store" \
    "256-KiB AXI4-write weight store with one-cycle 128-bit projection read port." \
    [file join $output_root work weight_bram128_pkg] \
    [file join $output_root ip weight_bram128] $part \
    [list [dict get $snapshots rtl/weight_bram128.v]] \
    [list ADDR_WIDTH 18 ID_WIDTH 4 DATA_WIDTH 32] $clock_hz]

create_project -in_memory -part $part
set_property ip_repo_paths [list [file join $output_root ip]] [current_project]
update_ip_catalog -rebuild
foreach vlnv {shepherdscientific.com:user:axi_gemm_stream:1.0 shepherdscientific.com:user:weight_bram128:1.0} {
    if {[llength [get_ipdefs -quiet $vlnv]] != 1} { error "catalog smoke failed for $vlnv" }
}
close_project
e2e_write [file join $output_root catalog_smoke.txt] \
    "status=PASS\npart=$part\nclock_hz=$clock_hz\nprojection_component_sha256=[e2e_sha256 $projection_component]\nweight_component_sha256=[e2e_sha256 $weight_component]\n"
puts "RAW_E2E_PROJECTION_PACKAGE_PASS part=$part clock_hz=$clock_hz root=[file join $output_root ip]"
