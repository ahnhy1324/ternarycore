# assert_bringup_platform.tcl
# Structural and configuration assertions for the temporary Zybo bring-up BD.
# This file defines procedures only. The create/build scripts source it and
# call assert_bringup_platform explicitly.

namespace eval ::zybo_bringup {
    variable expected_version "2025.1"
    variable expected_board   "digilentinc.com:zybo-z7-20:part0:1.2"
    variable expected_part    "xc7z020clg400-1"
}

proc ::zybo_bringup::fail {message} {
    error "ZYBO BRING-UP ASSERTION FAILED: $message"
}

proc ::zybo_bringup::require_one {objects label} {
    if {[llength $objects] != 1} {
        ::zybo_bringup::fail "$label: expected exactly one object, got [llength $objects] ($objects)"
    }
    # Preserve Vivado's typed collection. lindex converts a single design
    # object into plain text, which get_property/-of_objects then rejects.
    return $objects
}

proc ::zybo_bringup::require_equal {actual expected label} {
    if {$actual ne $expected} {
        ::zybo_bringup::fail "$label: expected '$expected', got '$actual'"
    }
}

proc ::zybo_bringup::require_absent {objects label} {
    if {[llength $objects] != 0} {
        ::zybo_bringup::fail "$label: expected no objects, got $objects"
    }
}

proc ::zybo_bringup::require_intf_connected {pin_name} {
    set pin [::zybo_bringup::require_one [get_bd_intf_pins -quiet $pin_name] "interface pin $pin_name"]
    if {[llength [get_bd_intf_nets -quiet -of_objects $pin]] != 1} {
        ::zybo_bringup::fail "interface pin $pin_name is not connected to exactly one interface net"
    }
}

proc ::zybo_bringup::require_pin_connected {pin_name} {
    set pin [::zybo_bringup::require_one [get_bd_pins -quiet $pin_name] "pin $pin_name"]
    if {[llength [get_bd_nets -quiet -of_objects $pin]] != 1} {
        ::zybo_bringup::fail "pin $pin_name is not connected to exactly one net"
    }
}

proc ::zybo_bringup::require_pin_unconnected {pin_name} {
    set pin [::zybo_bringup::require_one [get_bd_pins -quiet $pin_name] "pin $pin_name"]
    set nets [get_bd_nets -quiet -of_objects $pin]
    if {[llength $nets] != 0} {
        ::zybo_bringup::fail "pin $pin_name must be unconnected, got net(s): $nets"
    }
}

proc ::zybo_bringup::require_pins_share_net {pin_names label} {
    set expected_net ""
    foreach pin_name $pin_names {
        set pin [::zybo_bringup::require_one [get_bd_pins -quiet $pin_name] "pin $pin_name"]
        set net [::zybo_bringup::require_one \
            [get_bd_nets -quiet -of_objects $pin] "net for pin $pin_name"]
        set net_name [get_property NAME $net]
        if {$expected_net eq ""} {
            set expected_net $net_name
        } elseif {$net_name ne $expected_net} {
            ::zybo_bringup::fail "$label: pin $pin_name is on '$net_name', expected '$expected_net'"
        }
    }
}

proc ::zybo_bringup::parse_size {value label} {
    set text [string trim $value]
    if {[regexp -nocase {^0x[0-9a-f]+$} $text]} {
        return [expr {wide($text)}]
    }
    if {[string is integer -strict $text]} {
        return [expr {wide($text)}]
    }
    if {[regexp -nocase {^([0-9]+)[ ]*([kmg])$} $text -> magnitude suffix]} {
        switch -nocase -- $suffix {
            k { set multiplier 1024 }
            m { set multiplier [expr {1024 * 1024}] }
            g { set multiplier [expr {1024 * 1024 * 1024}] }
            default { ::zybo_bringup::fail "$label: unsupported size suffix in '$value'" }
        }
        return [expr {wide($magnitude) * $multiplier}]
    }
    ::zybo_bringup::fail "$label: cannot parse numeric value '$value'"
}

proc ::zybo_bringup::find_segment {space_name glob_pattern label} {
    set space [::zybo_bringup::require_one [get_bd_addr_spaces -quiet $space_name] "address space $space_name"]
    set matches {}
    foreach segment [get_bd_addr_segs -quiet -of_objects $space] {
        if {[string match $glob_pattern $segment]} {
            lappend matches $segment
        }
    }
    return [::zybo_bringup::require_one $matches $label]
}

proc ::zybo_bringup::require_address {space_name glob_pattern expected_offset expected_range label} {
    set segment [::zybo_bringup::find_segment $space_name $glob_pattern $label]
    set actual_offset [::zybo_bringup::parse_size [get_property OFFSET $segment] "$label offset"]
    set actual_range  [::zybo_bringup::parse_size [get_property RANGE  $segment] "$label range"]
    if {$actual_offset != $expected_offset} {
        ::zybo_bringup::fail [format "%s: expected offset 0x%08X, got 0x%08X" $label $expected_offset $actual_offset]
    }
    if {$actual_range != $expected_range} {
        ::zybo_bringup::fail "$label: expected range $expected_range bytes, got $actual_range bytes"
    }
    return $segment
}

proc assert_bringup_platform {expected_clock_mhz {expected_kv_data_width 64} \
        {expected_av_data_width 0} {expected_raw_data_width 0} \
        {expected_raw_scale_width 0} {expected_raw_qk_mult_style 0} \
        {expected_raw_av_mult_style 0} \
        {expected_raw_profile NONE} \
        {expected_canned_scale_bits 0} \
        {expected_canned_qk_mult_style 0} \
        {expected_canned_av_mult_style 0} \
        {expected_canned_profile NONE} \
        {expected_canned_compiled_profile_id 0} \
        {expected_canned_compiled_k_codebook_id 0} \
        {expected_canned_compiled_v_codebook_id 0}} {
    set tool_version [version -short]
    if {![regexp {^2025\.1($|[._-])} $tool_version]} {
        ::zybo_bringup::fail "Vivado release must be 2025.1, got '$tool_version'"
    }

    set project [::zybo_bringup::require_one [current_project -quiet] "current project"]
    ::zybo_bringup::require_equal [get_property PART $project] $::zybo_bringup::expected_part "project part"
    ::zybo_bringup::require_equal [get_property BOARD_PART $project] $::zybo_bringup::expected_board "project board part"

    # current_bd_design returns the design name, not a first-class object that
    # get_property accepts. Compare that command result directly.
    set design [::zybo_bringup::require_one [current_bd_design -quiet] "current block design"]
    ::zybo_bringup::require_equal $design "zybo_bringup" "block-design name"

    set native_fclk 0
    if {abs(double($expected_clock_mhz) - 75.0) < 0.000001} {
        set expected_clock_hz 75000000
        set expected_clock_module zybo_pl_clock_75
    } elseif {abs(double($expected_clock_mhz) - 81.25) < 0.000001} {
        set expected_clock_hz 81250000
        set expected_clock_module zybo_pl_clock_81p25
    } elseif {abs(double($expected_clock_mhz) - 76.923080) < 0.000001} {
        set native_fclk 1
        set expected_clock_hz 76923080
        set expected_clock_module ps7_native_fclk
    } else {
        ::zybo_bringup::fail "expected clock must be exactly 75, 76.923080 native, or 81.25 MHz, got '$expected_clock_mhz'"
    }

    set required_cells {
        ps7_0 rst_pl ctrl_sc axi_bram_ctrl_0 bram_0
        axi_cdma_0 hp_sc
    }
    if {!$native_fclk} {
        lappend required_cells pl_clock_0
    }
    foreach cell_name $required_cells {
        ::zybo_bringup::require_one [get_bd_cells -quiet $cell_name] "BD cell $cell_name"
    }
    if {$native_fclk} {
        ::zybo_bringup::require_absent [get_bd_cells -quiet pl_clock_0] "MMCM clock module in native-FCLK mode"
    }
    ::zybo_bringup::require_absent [get_bd_cells -quiet const_zero] "legacy reset constant"
    ::zybo_bringup::require_absent [get_bd_cells -quiet const_one] "legacy native-FCLK lock constant"
    ::zybo_bringup::require_absent [get_bd_cells -quiet rst_pl_ext_reset_inv] "legacy reset inverter"
    ::zybo_bringup::require_absent [get_bd_cells -quiet clk_wiz_0] "legacy Clocking Wizard cell"
    ::zybo_bringup::require_equal \
        [get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells rst_pl]] \
        0 "processor-system reset external-reset polarity"
    set kv_cells [get_bd_cells -quiet axi_kv_cache_0]
    if {[llength $kv_cells] > 1} {
        ::zybo_bringup::fail "more than one axi_kv_cache_0 cell exists: $kv_cells"
    }
    set kv_smoke_enabled [expr {[llength $kv_cells] == 1}]
    if {$kv_smoke_enabled && $expected_kv_data_width ni {64 128}} {
        ::zybo_bringup::fail "expected KV data width must be 64 or 128, got '$expected_kv_data_width'"
    }
    set av_diag_cells [get_bd_cells -quiet axi_v5_av_diag_0]
    if {[llength $av_diag_cells] > 1} {
        ::zybo_bringup::fail "more than one axi_v5_av_diag_0 cell exists: $av_diag_cells"
    }
    set av_diag_enabled [expr {[llength $av_diag_cells] == 1}]
    if {$av_diag_enabled && !$kv_smoke_enabled} {
        ::zybo_bringup::fail "AV diagnostic is additive and requires the preserved KV M02/S01 topology"
    }
    if {$av_diag_enabled && $expected_av_data_width != 64} {
        ::zybo_bringup::fail "enabled AV diagnostic requires expected data width 64, got '$expected_av_data_width'"
    }
    if {!$av_diag_enabled && $expected_av_data_width != 0} {
        ::zybo_bringup::fail "absent AV diagnostic requires expected data width 0, got '$expected_av_data_width'"
    }
    set raw_full_cells [get_bd_cells -quiet axi_kvq_raw_full_diag_0]
    if {[llength $raw_full_cells] > 1} {
        ::zybo_bringup::fail "more than one axi_kvq_raw_full_diag_0 cell exists: $raw_full_cells"
    }
    set raw_full_enabled [expr {[llength $raw_full_cells] == 1}]
    if {$raw_full_enabled && ($kv_smoke_enabled || $av_diag_enabled)} {
        ::zybo_bringup::fail "raw-full mode replaces and cannot coexist with KV or AV diagnostic cells"
    }
    if {$raw_full_enabled} {
        if {$expected_raw_data_width ni {64 128}} {
            ::zybo_bringup::fail "raw-full mode requires expected AXI data width 64 or 128, got '$expected_raw_data_width'"
        }
        if {$expected_raw_scale_width ni {12 16}} {
            ::zybo_bringup::fail "raw-full SCALE_WIDTH must be 12 or 16, got '$expected_raw_scale_width'"
        }
        if {$expected_raw_qk_mult_style != 2 ||
            $expected_raw_av_mult_style ni {1 2}} {
            ::zybo_bringup::fail "raw-full profile styles must be QK=2 and AV=1 or 2; got QK=$expected_raw_qk_mult_style AV=$expected_raw_av_mult_style"
        }
        set derived_raw_profile [expr {$expected_raw_av_mult_style == 1 ?
            "LUT_RELIEF" : "BALANCED"}]
        ::zybo_bringup::require_equal $expected_raw_profile $derived_raw_profile \
            "raw-full build profile"
    } elseif {$expected_raw_data_width != 0 || $expected_raw_scale_width != 0 ||
              $expected_raw_qk_mult_style != 0 ||
              $expected_raw_av_mult_style != 0 ||
              $expected_raw_profile ne "NONE"} {
        ::zybo_bringup::fail "absent raw-full mode requires width/scale/styles 0 and profile NONE"
    }
    set canned_page_cells [get_bd_cells -quiet axi_kvq_canned_page_diag_0]
    if {[llength $canned_page_cells] > 1} {
        ::zybo_bringup::fail "more than one axi_kvq_canned_page_diag_0 cell exists: $canned_page_cells"
    }
    set canned_page_enabled [expr {[llength $canned_page_cells] == 1}]
    if {$canned_page_enabled &&
        ($kv_smoke_enabled || $av_diag_enabled || $raw_full_enabled)} {
        ::zybo_bringup::fail "canned-page mode replaces and cannot coexist with KV, AV, or raw-full diagnostic cells"
    }
    if {$canned_page_enabled} {
        if {$expected_canned_scale_bits ni {12 16}} {
            ::zybo_bringup::fail "canned-page SCALE_BITS must be 12 or 16, got '$expected_canned_scale_bits'"
        }
        if {$expected_canned_qk_mult_style != 2 ||
            $expected_canned_av_mult_style ni {1 2}} {
            ::zybo_bringup::fail "canned-page profile styles must be QK=2 and AV=1 or 2; got QK=$expected_canned_qk_mult_style AV=$expected_canned_av_mult_style"
        }
        set derived_canned_profile [expr {
            $expected_canned_av_mult_style == 1 ? "LUT_RELIEF" : "BALANCED"}]
        ::zybo_bringup::require_equal $expected_canned_profile \
            $derived_canned_profile "canned-page build profile"
        foreach {actual expected label} [list \
                $expected_canned_compiled_profile_id 51 \
                    "canned-page compiled profile ID" \
                $expected_canned_compiled_k_codebook_id 1 \
                    "canned-page compiled K codebook ID" \
                $expected_canned_compiled_v_codebook_id 2 \
                    "canned-page compiled V codebook ID"] {
            ::zybo_bringup::require_equal $actual $expected $label
        }
    } elseif {$expected_canned_scale_bits != 0 ||
              $expected_canned_qk_mult_style != 0 ||
              $expected_canned_av_mult_style != 0 ||
              $expected_canned_profile ne "NONE" ||
              $expected_canned_compiled_profile_id != 0 ||
              $expected_canned_compiled_k_codebook_id != 0 ||
              $expected_canned_compiled_v_codebook_id != 0} {
        ::zybo_bringup::fail "absent canned-page mode requires scale/styles/compiled IDs 0 and profile NONE"
    }
    ::zybo_bringup::require_equal [get_property CONFIG.NUM_MI [get_bd_cells ctrl_sc]] \
        [expr {($raw_full_enabled || $canned_page_enabled) ? 3 : \
            ($av_diag_enabled ? 4 : ($kv_smoke_enabled ? 3 : 2))}] \
        "GP0 interconnect master count"
    ::zybo_bringup::require_equal [get_property CONFIG.NUM_SI [get_bd_cells hp_sc]] \
        [expr {$raw_full_enabled ? 3 : \
            ($av_diag_enabled ? 3 : ($kv_smoke_enabled ? 2 : 1))}] \
        "HP0 SmartConnect slave count"

    set ps [get_bd_cells ps7_0]
    foreach {property expected label} {
        CONFIG.PCW_USE_M_AXI_GP0             1             "PS GP0 enable"
        CONFIG.PCW_USE_S_AXI_HP0             1             "PS HP0 enable"
        CONFIG.PCW_S_AXI_HP0_DATA_WIDTH      64            "PS HP0 width"
        CONFIG.PCW_USE_AXI_NONSECURE         1             "PS non-secure AXI enable"
        CONFIG.PCW_UART1_PERIPHERAL_ENABLE   1             "PS UART1 enable"
        CONFIG.PCW_UART1_UART1_IO            {MIO 48 .. 49} "PS UART1 MIO"
        CONFIG.PCW_DDR_RAM_HIGHADDR          0x3FFFFFFF    "PS DDR high address"
    } {
        ::zybo_bringup::require_equal [get_property $property $ps] $expected $label
    }

    ::zybo_bringup::require_one [get_bd_intf_ports -quiet DDR] "external DDR interface"
    ::zybo_bringup::require_one [get_bd_intf_ports -quiet FIXED_IO] "external FIXED_IO interface"
    ::zybo_bringup::require_intf_connected ps7_0/DDR
    ::zybo_bringup::require_intf_connected ps7_0/FIXED_IO

    if {!$native_fclk} {
        set clock_cell [get_bd_cells pl_clock_0]
        set clock_vlnv [get_property VLNV $clock_cell]
        if {![string match "*:module_ref:${expected_clock_module}:*" $clock_vlnv]} {
            ::zybo_bringup::fail "clock module must be $expected_clock_module, got VLNV '$clock_vlnv'"
        }
    }
    set actual_fclk_mhz [get_property CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ $ps]
    set expected_fclk_mhz [expr {$native_fclk ? 76.923080 : 100.0}]
    if {![string is double -strict $actual_fclk_mhz] ||
        abs(double($actual_fclk_mhz) - $expected_fclk_mhz) > 0.000001} {
        ::zybo_bringup::fail "PS FCLK_CLK0 actual frequency is '$actual_fclk_mhz' MHz, expected [format %.6f $expected_fclk_mhz] MHz"
    }
    set input_clock_pins {ps7_0/FCLK_CLK0}
    if {!$native_fclk} {
        lappend input_clock_pins pl_clock_0/clk_in
    }
    set expected_input_hz [expr {$native_fclk ? $expected_clock_hz : 100000000}]
    foreach pin_name $input_clock_pins {
        set clock_pin [::zybo_bringup::require_one [get_bd_pins -quiet $pin_name] "clock pin $pin_name"]
        set input_hz [get_property CONFIG.FREQ_HZ $clock_pin]
        if {![string is double -strict $input_hz] || abs(double($input_hz) - double($expected_input_hz)) > 0.5} {
            ::zybo_bringup::fail "$pin_name propagated frequency is '$input_hz' Hz, expected $expected_input_hz Hz"
        }
    }
    set propagated_clock_pin [expr {$native_fclk ? "ps7_0/FCLK_CLK0" : "pl_clock_0/clk_out"}]
    set propagated_hz [get_property CONFIG.FREQ_HZ [get_bd_pins $propagated_clock_pin]]
    if {$propagated_hz eq "" ||
        [::zybo_bringup::parse_size $propagated_hz "PL clock frequency"] != $expected_clock_hz} {
        ::zybo_bringup::fail "propagated PL clock is '$propagated_hz' Hz, expected $expected_clock_hz Hz"
    }

    set required_clock_reset_pins {
        ps7_0/FCLK_CLK0 ps7_0/FCLK_RESET0_N ps7_0/M_AXI_GP0_ACLK
        ps7_0/S_AXI_HP0_ACLK rst_pl/slowest_sync_clk
        rst_pl/ext_reset_in
        ctrl_sc/ACLK ctrl_sc/ARESETN ctrl_sc/S00_ACLK ctrl_sc/S00_ARESETN
        ctrl_sc/M00_ACLK ctrl_sc/M00_ARESETN ctrl_sc/M01_ACLK ctrl_sc/M01_ARESETN
        hp_sc/aclk hp_sc/aresetn axi_bram_ctrl_0/s_axi_aclk
        axi_bram_ctrl_0/s_axi_aresetn axi_cdma_0/s_axi_lite_aclk
        axi_cdma_0/m_axi_aclk axi_cdma_0/s_axi_lite_aresetn
    }
    if {!$native_fclk} {
        lappend required_clock_reset_pins \
            pl_clock_0/clk_in pl_clock_0/clk_out pl_clock_0/resetn \
            pl_clock_0/locked rst_pl/dcm_locked
    }
    foreach pin_name $required_clock_reset_pins {
        ::zybo_bringup::require_pin_connected $pin_name
    }
    ::zybo_bringup::require_pins_share_net \
        {ps7_0/FCLK_RESET0_N rst_pl/ext_reset_in} \
        "active-low processor-system reset input"
    if {$native_fclk} {
        ::zybo_bringup::require_pin_unconnected rst_pl/dcm_locked
    } else {
        ::zybo_bringup::require_pins_share_net \
            {ps7_0/FCLK_RESET0_N pl_clock_0/resetn} \
            "MMCM reset release"
        ::zybo_bringup::require_pins_share_net \
            {pl_clock_0/locked rst_pl/dcm_locked} \
            "MMCM lock qualification"
    }
    ::zybo_bringup::require_pin_unconnected rst_pl/aux_reset_in
    ::zybo_bringup::require_pin_unconnected rst_pl/mb_debug_sys_rst
    if {$kv_smoke_enabled} {
        foreach pin_name {
            ctrl_sc/M02_ACLK ctrl_sc/M02_ARESETN
            axi_kv_cache_0/clk axi_kv_cache_0/rst_n
        } {
            ::zybo_bringup::require_pin_connected $pin_name
        }
    }
    if {$av_diag_enabled} {
        foreach pin_name {
            ctrl_sc/M03_ACLK ctrl_sc/M03_ARESETN
            axi_v5_av_diag_0/clk axi_v5_av_diag_0/rst_n
        } {
            ::zybo_bringup::require_pin_connected $pin_name
        }
    }
    if {$raw_full_enabled} {
        foreach pin_name {
            ctrl_sc/M02_ACLK ctrl_sc/M02_ARESETN
            axi_kvq_raw_full_diag_0/clk axi_kvq_raw_full_diag_0/rst_n
        } {
            ::zybo_bringup::require_pin_connected $pin_name
        }
    }
    if {$canned_page_enabled} {
        foreach pin_name {
            ctrl_sc/M02_ACLK ctrl_sc/M02_ARESETN
            axi_kvq_canned_page_diag_0/clk
            axi_kvq_canned_page_diag_0/rst_n
        } {
            ::zybo_bringup::require_pin_connected $pin_name
        }
    }

    set cdma_m_axi_reset_pins [get_bd_pins -quiet axi_cdma_0/m_axi_aresetn]
    if {[llength $cdma_m_axi_reset_pins] > 1} {
        ::zybo_bringup::fail "AXI CDMA exposes more than one m_axi_aresetn pin: $cdma_m_axi_reset_pins"
    }
    if {[llength $cdma_m_axi_reset_pins] == 1} {
        ::zybo_bringup::require_pin_connected axi_cdma_0/m_axi_aresetn
    }

    foreach pin_name {
        ps7_0/M_AXI_GP0 ctrl_sc/S00_AXI ctrl_sc/M00_AXI ctrl_sc/M01_AXI
        axi_bram_ctrl_0/S_AXI axi_bram_ctrl_0/BRAM_PORTA bram_0/BRAM_PORTA
        axi_cdma_0/S_AXI_LITE axi_cdma_0/M_AXI hp_sc/S00_AXI
        hp_sc/M00_AXI ps7_0/S_AXI_HP0
    } {
        ::zybo_bringup::require_intf_connected $pin_name
    }
    if {$kv_smoke_enabled} {
        foreach pin_name {
            ctrl_sc/M02_AXI axi_kv_cache_0/s_axi axi_kv_cache_0/m_axi
            hp_sc/S01_AXI
        } {
            ::zybo_bringup::require_intf_connected $pin_name
        }
        set kv [get_bd_cells axi_kv_cache_0]
        ::zybo_bringup::require_equal [get_property VLNV $kv] \
            shepherdscientific.com:user:axi_kv_cache:2.0 "KV IP VLNV"
        ::zybo_bringup::require_equal [get_property CONFIG.HEAD_DIM $kv] 128 \
            "KV head dimension"
        ::zybo_bringup::require_equal [get_property CONFIG.MAX_CONTEXT $kv] 4096 \
            "KV maximum context"
        ::zybo_bringup::require_equal \
            [get_property CONFIG.M_AXI_DATA_WIDTH $kv] $expected_kv_data_width \
            "KV internal AXI data width"
    }
    if {$av_diag_enabled} {
        foreach pin_name {
            ctrl_sc/M03_AXI axi_v5_av_diag_0/s_axi
            axi_v5_av_diag_0/m_axi hp_sc/S02_AXI
        } {
            ::zybo_bringup::require_intf_connected $pin_name
        }
        set av_diag [get_bd_cells axi_v5_av_diag_0]
        ::zybo_bringup::require_equal [get_property VLNV $av_diag] \
            shepherdscientific.com:user:axi_v5_av_diag:1.0 \
            "AV diagnostic IP VLNV"
        ::zybo_bringup::require_equal [get_property CONFIG.MAX_CONTEXT $av_diag] \
            128 "AV diagnostic maximum context"
        ::zybo_bringup::require_equal [get_property CONFIG.MULT_STYLE $av_diag] \
            2 "AV diagnostic multiplier style"
        ::zybo_bringup::require_equal \
            [get_property CONFIG.M_AXI_ADDR_WIDTH $av_diag] 32 \
            "AV diagnostic AXI address width"
        ::zybo_bringup::require_equal \
            [get_property CONFIG.M_AXI_DATA_WIDTH $av_diag] $expected_av_data_width \
            "AV diagnostic internal AXI data width"
    }
    if {$raw_full_enabled} {
        foreach pin_name {
            ctrl_sc/M02_AXI axi_kvq_raw_full_diag_0/s_axi
            axi_kvq_raw_full_diag_0/m_axi_k hp_sc/S01_AXI
            axi_kvq_raw_full_diag_0/m_axi_v hp_sc/S02_AXI
        } {
            ::zybo_bringup::require_intf_connected $pin_name
        }
        set raw_full [get_bd_cells axi_kvq_raw_full_diag_0]
        ::zybo_bringup::require_equal [get_property VLNV $raw_full] \
            shepherdscientific.com:user:axi_kvq_raw_full_diag:1.0 \
            "raw-full diagnostic IP VLNV"
        ::zybo_bringup::require_equal [get_property CONFIG.MAX_CONTEXT $raw_full] \
            128 "raw-full maximum context"
        ::zybo_bringup::require_equal [get_property CONFIG.SCALE_WIDTH $raw_full] \
            $expected_raw_scale_width "raw-full scale width"
        ::zybo_bringup::require_equal \
            [get_property CONFIG.QK_MULT_STYLE $raw_full] \
            $expected_raw_qk_mult_style "raw-full QK multiplier style"
        ::zybo_bringup::require_equal \
            [get_property CONFIG.AV_MULT_STYLE $raw_full] \
            $expected_raw_av_mult_style "raw-full AV multiplier style"
        ::zybo_bringup::require_equal \
            [get_property CONFIG.M_AXI_ADDR_WIDTH $raw_full] 32 \
            "raw-full AXI address width"
        ::zybo_bringup::require_equal \
            [get_property CONFIG.M_AXI_DATA_WIDTH $raw_full] $expected_raw_data_width \
            "raw-full K/V AXI data width"
        foreach interface_name {m_axi_k m_axi_v} {
            ::zybo_bringup::require_equal [get_property CONFIG.DATA_WIDTH \
                [get_bd_intf_pins axi_kvq_raw_full_diag_0/$interface_name]] \
                $expected_raw_data_width \
                "raw-full $interface_name propagated data width"
        }
        foreach interface_name {S01_AXI S02_AXI} {
            ::zybo_bringup::require_equal [get_property CONFIG.DATA_WIDTH \
                [get_bd_intf_pins hp_sc/$interface_name]] \
                $expected_raw_data_width \
                "HP0 SmartConnect $interface_name input width"
        }
        ::zybo_bringup::require_equal [get_property CONFIG.DATA_WIDTH \
            [get_bd_intf_pins hp_sc/M00_AXI]] 64 \
            "HP0 SmartConnect physical output width"
    }
    if {$canned_page_enabled} {
        foreach pin_name {
            ctrl_sc/M02_AXI axi_kvq_canned_page_diag_0/s_axi
        } {
            ::zybo_bringup::require_intf_connected $pin_name
        }
        set canned_page [get_bd_cells axi_kvq_canned_page_diag_0]
        ::zybo_bringup::require_equal [get_property VLNV $canned_page] \
            shepherdscientific.com:user:axi_kvq_canned_page_diag:1.0 \
            "canned-page diagnostic IP VLNV"
        foreach {property expected label} [list \
                CONFIG.MAX_CONTEXT 128 "canned-page maximum context" \
                CONFIG.SCALE_BITS $expected_canned_scale_bits \
                    "canned-page scale bits" \
                CONFIG.COMPILED_PROFILE_ID \
                    $expected_canned_compiled_profile_id \
                    "canned-page compiled profile ID" \
                CONFIG.COMPILED_K_CODEBOOK_ID \
                    $expected_canned_compiled_k_codebook_id \
                    "canned-page compiled K codebook ID" \
                CONFIG.COMPILED_V_CODEBOOK_ID \
                    $expected_canned_compiled_v_codebook_id \
                    "canned-page compiled V codebook ID" \
                CONFIG.QK_MULT_STYLE $expected_canned_qk_mult_style \
                    "canned-page QK multiplier style" \
                CONFIG.AV_MULT_STYLE $expected_canned_av_mult_style \
                    "canned-page AV multiplier style" \
                CONFIG.C_S_AXI_DATA_WIDTH 32 \
                    "canned-page AXI-Lite data width" \
                CONFIG.C_S_AXI_ADDR_WIDTH 16 \
                    "canned-page AXI-Lite address width"] {
            ::zybo_bringup::require_equal \
                [get_property $property $canned_page] $expected $label
        }
        ::zybo_bringup::require_absent \
            [get_bd_intf_pins -quiet axi_kvq_canned_page_diag_0/m_axi*] \
            "canned-page external AXI master interface"
        foreach unused_hp_input {S01_AXI S02_AXI} {
            ::zybo_bringup::require_absent \
                [get_bd_intf_pins -quiet hp_sc/$unused_hp_input] \
                "canned-page unused HP0 input $unused_hp_input"
        }
    }

    ::zybo_bringup::require_equal [get_property CONFIG.C_M_AXI_DATA_WIDTH [get_bd_cells axi_cdma_0]] 64 "CDMA AXI data width"
    ::zybo_bringup::require_equal [get_property CONFIG.C_INCLUDE_SG [get_bd_cells axi_cdma_0]] 0 "CDMA scatter-gather disable"
    ::zybo_bringup::require_equal [get_property CONFIG.C_INCLUDE_DRE [get_bd_cells axi_cdma_0]] 0 "CDMA DRE disable"

    set bram [get_bd_cells bram_0]
    ::zybo_bringup::require_equal [get_property VLNV $bram] xilinx.com:ip:blk_mem_gen:8.4 "BRAM generator VLNV"
    ::zybo_bringup::require_equal [get_property CONFIG.Memory_Type $bram] Single_Port_RAM "BRAM memory type"
    ::zybo_bringup::require_equal [get_property CONFIG.use_bram_block $bram] BRAM_Controller "BRAM controller mode"
    ::zybo_bringup::require_equal [get_property CONFIG.Enable_A $bram] Use_ENA_Pin "BRAM port-A enable"
    ::zybo_bringup::require_equal [get_property CONFIG.Write_Depth_A $bram] 16384 "BRAM propagated write depth"
    ::zybo_bringup::require_equal [get_property CONFIG.Write_Width_A $bram] 32 "BRAM propagated write width"
    ::zybo_bringup::require_equal [get_property CONFIG.Read_Width_A $bram] 32 "BRAM propagated read width"

    ::zybo_bringup::require_address ps7_0/Data "*axi_bram_ctrl_0*" 0x43C00000 65536 "GP0 BRAM segment"
    ::zybo_bringup::require_address ps7_0/Data "*axi_cdma_0*"      0x43C10000 65536 "GP0 CDMA segment"
    ::zybo_bringup::require_address axi_cdma_0/Data "*HP0_DDR*"   0x00000000 1073741824 "CDMA HP0 DDR segment"
    if {$kv_smoke_enabled} {
        ::zybo_bringup::require_address ps7_0/Data "*axi_kv_cache_0*" \
            0x43C20000 65536 "GP0 KV control segment"
        ::zybo_bringup::require_address axi_kv_cache_0/m_axi \
            "*HP0_DDR*" 0x00000000 1073741824 "KV HP0 DDR segment"
    }
    if {$av_diag_enabled} {
        ::zybo_bringup::require_address ps7_0/Data "*axi_v5_av_diag_0*" \
            0x43C30000 65536 "GP0 AV diagnostic control segment"
        ::zybo_bringup::require_address axi_v5_av_diag_0/m_axi \
            "*HP0_DDR*" 0x00000000 1073741824 \
            "AV diagnostic HP0 DDR segment"
    }
    if {$raw_full_enabled} {
        ::zybo_bringup::require_address ps7_0/Data \
            "*axi_kvq_raw_full_diag_0*" 0x43C20000 65536 \
            "GP0 raw-full control segment"
        ::zybo_bringup::require_address axi_kvq_raw_full_diag_0/m_axi_k \
            "*HP0_DDR*" 0x00000000 1073741824 \
            "raw-full K HP0 DDR segment"
        ::zybo_bringup::require_address axi_kvq_raw_full_diag_0/m_axi_v \
            "*HP0_DDR*" 0x00000000 1073741824 \
            "raw-full V HP0 DDR segment"
    }
    if {$canned_page_enabled} {
        ::zybo_bringup::require_address ps7_0/Data \
            "*axi_kvq_canned_page_diag_0*" 0x43C20000 65536 \
            "GP0 canned-page control segment"
    }

    puts [format "ZYBO BRING-UP ASSERTIONS PASS: %s, %.3f MHz, GP0 BRAM/CDMA%s%s%s%s, 64-bit HP0" \
        $::zybo_bringup::expected_part $expected_clock_mhz \
        [expr {$kv_smoke_enabled ? "/KV" : ""}] \
        [expr {$av_diag_enabled ? "/AV-DIAG" : ""}] \
        [expr {$raw_full_enabled ? "/RAW-FULL-$expected_raw_scale_width-$expected_raw_profile" : ""}] \
        [expr {$canned_page_enabled ? "/CANNED-PAGE-$expected_canned_scale_bits-$expected_canned_profile" : ""}]]
}
