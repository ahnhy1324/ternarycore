if {[llength $argv] != 4} {
    error "usage: validate_vivado_2025_1.tcl <board-repo-path> <vivado-version> <board-part> <device-part>"
}

lassign $argv board_repo_path expected_version expected_board_part expected_device_part
set board_repo_path [file normalize $board_repo_path]

if {![file isdirectory $board_repo_path]} {
    error "board repository path is absent: $board_repo_path"
}

set actual_version [version -short]
if {$actual_version ne $expected_version} {
    error "Vivado version mismatch: expected $expected_version, got $actual_version"
}

set device_parts [get_parts -quiet $expected_device_part]
if {[llength $device_parts] != 1} {
    error "expected exactly one device part $expected_device_part, got: $device_parts"
}

# This parameter is session-local. The bootstrap never changes Vivado's global
# preferences and never copies board files into the AMD installation tree.
set_param board.repoPaths [list $board_repo_path]
set board_parts [get_board_parts -quiet $expected_board_part]
if {[llength $board_parts] != 1} {
    error "expected exactly one board part $expected_board_part, got: $board_parts"
}

set actual_device_part [get_property PART_NAME [lindex $board_parts 0]]
if {$actual_device_part ne $expected_device_part} {
    error "board/device mismatch: $expected_board_part maps to $actual_device_part"
}

puts "TERNARYCORE_VIVADO_GATE_PASS version=$actual_version board=$expected_board_part device=$actual_device_part"
