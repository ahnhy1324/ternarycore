# run_kv_v2_board_smoke.tcl -- XSDB-only ABI-v2 KV cache board smoke test.
#
# Usage after a successful Zybo platform build:
#   xsdb ZyboZ7/run_kv_v2_board_smoke.tcl <platform-output-directory> ?context?
#
# Vector generation can be checked without connecting to hardware:
#   xsdb ZyboZ7/run_kv_v2_board_smoke.tcl --self-test ?context?

set KV_BASE       0x43c20000
set K_DDR_BASE    0x01000000
set HEAD_DIM      128
set MAX_CONTEXT   4096
set CONTEXT       7
set SCALE_UQ5_11  0x0800

set REG_CTRL      0x0000
set REG_STATUS    0x0004
set REG_K_BASE_LO 0x0008
set REG_K_BASE_HI 0x000c
set REG_CONTEXT   0x001c
set REG_TOKEN_POS 0x0020
set REG_CFG       0x0024
set REG_PERF      0x0028
set REG_ERROR     0x002c
set REG_ID        0x0030
set REG_GEOMETRY  0x0034
set Q_BASE        0x0100
set LOGIT_BASE    0x1000

set EXPECTED_ID       0x4b560002
# The deterministic K generator repeats every five tokens.  These anchored
# values are independent of the context selected for a board run.
set EXPECTED_LOGIT_PERIOD {929792 886784 -446464 -489472 -440320}

proc fail {message} {
    error "KV_BOARD_SMOKE_FAIL: $message"
}

proc hex32 {value} {
    return [format "0x%08X" [expr {$value & 0xffffffff}]]
}

proc signed32 {value} {
    set value [expr {$value & 0xffffffff}]
    if {$value >= 0x80000000} {
        set value [expr {$value - 0x100000000}]
    }
    return $value
}

proc require_numeric_equal {label observed expected} {
    if {[expr {$observed & 0xffffffff}] !=
        [expr {$expected & 0xffffffff}]} {
        fail "$label got=[hex32 $observed] expected=[hex32 $expected]"
    }
}

proc q_at {dim} {
    return [expr {($dim % 9) - 4}]
}

proc k_at {token dim} {
    return [expr {(($token * 3 + $dim * 5) % 15) - 7}]
}

proc make_q_word {word_index} {
    set value 0
    for {set lane 0} {$lane < 4} {incr lane} {
        set q [q_at [expr {$word_index * 4 + $lane}]]
        set value [expr {$value | (($q & 0xff) << ($lane * 8))}]
    }
    return [expr {$value & 0xffffffff}]
}

proc make_k_word {token word_index} {
    set value 0
    for {set lane 0} {$lane < 8} {incr lane} {
        set dim [expr {$word_index * 8 + $lane}]
        set k [k_at $token $dim]
        if {$k < -7 || $k > 7} {
            fail "generator produced non-canonical INT4 token=$token dim=$dim value=$k"
        }
        set value [expr {$value | (($k & 0xf) << ($lane * 4))}]
    }
    return [expr {$value & 0xffffffff}]
}

proc reference_logit {token} {
    global HEAD_DIM SCALE_UQ5_11
    set sum 0
    for {set dim 0} {$dim < $HEAD_DIM} {incr dim} {
        set sum [expr {$sum + [q_at $dim] * [k_at $token $dim] *
                       $SCALE_UQ5_11}]
    }
    return $sum
}

proc expected_logit {token} {
    global EXPECTED_LOGIT_PERIOD
    return [lindex $EXPECTED_LOGIT_PERIOD \
        [expr {$token % [llength $EXPECTED_LOGIT_PERIOD]}]]
}

proc configure_context {value} {
    global CONTEXT MAX_CONTEXT
    if {![string is integer -strict $value] || $value < 1 ||
        $value > $MAX_CONTEXT} {
        fail "context must be an integer in 1..$MAX_CONTEXT; got '$value'"
    }
    set CONTEXT $value
}

proc vector_self_test {} {
    global CONTEXT

    require_numeric_equal "Q word 0"  [make_q_word 0]  0xfffefdfc
    require_numeric_equal "Q word 31" [make_q_word 31] 0xfdfc0403

    set expected_first_k_words {
        0xe93e93e9 0x1c61c61c 0x4fa4fa4f 0x72d72d72
        0xb50b50b5
    }
    for {set token 0} {$token < $CONTEXT} {incr token} {
        require_numeric_equal "K token $token word 0" \
            [make_k_word $token 0] \
            [lindex $expected_first_k_words [expr {$token % 5}]]
        set calculated [reference_logit $token]
        set expected [expected_logit $token]
        if {$calculated != $expected} {
            fail "reference token=$token got=$calculated expected=$expected"
        }
    }
    puts "KV_VECTOR_SELF_TEST_PASS context=$CONTEXT head_dim=128"
}

proc exactly_one_file {pattern label} {
    set files [glob -nocomplain $pattern]
    if {[llength $files] != 1} {
        fail "$label expected exactly one file for '$pattern'; got=$files"
    }
    set path [file normalize [lindex $files 0]]
    if {![file isfile $path] || [file size $path] <= 0} {
        fail "$label is absent or empty: $path"
    }
    return $path
}

proc expected_geometry_for_build {build_root} {
    global HEAD_DIM
    set identity_path [file join $build_root identity manifest.tcl]
    if {![file isfile $identity_path]} {
        fail "build identity manifest is absent: $identity_path"
    }
    unset -nocomplain ::zybo_bringup_identity
    uplevel #0 [list source $identity_path]
    if {![info exists ::zybo_bringup_identity]} {
        fail "build identity did not define ::zybo_bringup_identity"
    }
    foreach key {kv_smoke_enabled kv_transport kv_m_axi_data_width} {
        if {![dict exists $::zybo_bringup_identity $key]} {
            fail "build identity is missing '$key'"
        }
    }
    if {![dict get $::zybo_bringup_identity kv_smoke_enabled]} {
        fail "build identity says the KV peripheral is disabled"
    }
    set transport [dict get $::zybo_bringup_identity kv_transport]
    set data_width [dict get $::zybo_bringup_identity kv_m_axi_data_width]
    if {($transport eq "HP64_NATIVE" && $data_width != 64) ||
        ($transport eq "INTERNAL128_TO_HP64" && $data_width != 128) ||
        ($transport ni {HP64_NATIVE INTERNAL128_TO_HP64})} {
        fail "inconsistent KV transport identity transport='$transport' width='$data_width'"
    }
    set geometry [expr {(($data_width & 0xff) << 24) |
                        (($HEAD_DIM  & 0xff) << 16) |
                        (16 << 8) | 4}]
    return [list $transport $data_width $geometry]
}

proc read32 {address} {
    set raw [mrd -force [hex32 $address] 1]
    if {![regexp -nocase {([0-9a-f]{8})[ \t\r\n]*$} $raw -> value_hex]} {
        fail "cannot parse mrd result at [hex32 $address]: '$raw'"
    }
    scan $value_hex %x value
    return [expr {$value & 0xffffffff}]
}

proc write32 {address value} {
    mwr -force [hex32 $address] [hex32 $value]
}

proc write_and_verify_inputs {} {
    global KV_BASE K_DDR_BASE HEAD_DIM CONTEXT Q_BASE

    set k_words_per_token [expr {$HEAD_DIM / 8}]
    for {set token 0} {$token < $CONTEXT} {incr token} {
        for {set word 0} {$word < $k_words_per_token} {incr word} {
            set address [expr {$K_DDR_BASE + $token * 64 + $word * 4}]
            write32 $address [make_k_word $token $word]
        }
    }
    for {set token 0} {$token < $CONTEXT} {incr token} {
        for {set word 0} {$word < $k_words_per_token} {incr word} {
            set address [expr {$K_DDR_BASE + $token * 64 + $word * 4}]
            require_numeric_equal "DDR K token=$token word=$word" \
                [read32 $address] [make_k_word $token $word]
        }
    }

    for {set word 0} {$word < ($HEAD_DIM / 4)} {incr word} {
        set address [expr {$KV_BASE + $Q_BASE + $word * 4}]
        write32 $address [make_q_word $word]
    }
    for {set word 0} {$word < ($HEAD_DIM / 4)} {incr word} {
        set address [expr {$KV_BASE + $Q_BASE + $word * 4}]
        require_numeric_equal "AXI-Lite Q word=$word" \
            [read32 $address] [make_q_word $word]
    }
    puts "KV_INPUT_LOAD_PASS k_bytes=[expr {$CONTEXT * 64}] q_bytes=$HEAD_DIM"
}

proc run_kv_smoke {build_root} {
    global KV_BASE K_DDR_BASE CONTEXT SCALE_UQ5_11 EXPECTED_ID
    global REG_CTRL REG_STATUS REG_K_BASE_LO REG_K_BASE_HI REG_CONTEXT
    global REG_TOKEN_POS REG_CFG REG_PERF REG_ERROR REG_ID REG_GEOMETRY
    global LOGIT_BASE

    set build_root [file normalize $build_root]
    if {![file isdirectory $build_root]} {
        fail "platform output directory does not exist: $build_root"
    }
    if {![file isfile [file join $build_root .build_complete]]} {
        fail "platform build is not complete: [file join $build_root .build_complete]"
    }
    lassign [expected_geometry_for_build $build_root] \
        expected_transport expected_data_width expected_geometry

    set bit_path [exactly_one_file \
        [file join $build_root artifacts *.bit] "bitstream"]
    set xsa_path [exactly_one_file \
        [file join $build_root artifacts *.xsa] "XSA"]
    set ps7_init_path [file normalize [file join $build_root project \
        zybo_bringup.gen sources_1 bd zybo_bringup ip \
        zybo_bringup_ps7_0_0 ps7_init.tcl]]
    if {![file isfile $ps7_init_path] || [file size $ps7_init_path] <= 0} {
        fail "matching generated ps7_init.tcl is absent: $ps7_init_path"
    }

    puts "KV_BOARD_ARTIFACT bit=$bit_path"
    puts "KV_BOARD_ARTIFACT xsa=$xsa_path"
    puts "KV_BOARD_ARTIFACT ps7_init=$ps7_init_path"

    connect -url tcp:127.0.0.1:3121
    targets 1
    rst -system
    after 1000
    targets 4
    fpga -file $bit_path
    targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
    catch {stop}
    after 500
    targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
    # The generated file defines namespace-level silicon-version variables.
    # Source it at the Tcl global scope even though this setup runs in a proc.
    uplevel #0 [list source $ps7_init_path]
    ps7_init
    # Keep the exact generated post-config variant used by this physical
    # board's previously proven BRAM/CDMA sequence.
    if {[llength [info commands ps7_post_config_2_0]] != 1} {
        fail "generated PS init has no ps7_post_config_2_0 procedure"
    }
    ps7_post_config_2_0

    after 1000
    puts "KV_PS_INIT_PASS source=$ps7_init_path"

    set fpga_clk_ctrl [read32 0xf8000170]
    set fpga_rst_ctrl [read32 0xf8000240]
    set level_shifter [read32 0xf8000900]
    set silicon_version [ps_version]
    puts "KV_PS_REGS silicon_version=$silicon_version post_config=2_0 fpga0_clk_ctrl=[hex32 $fpga_clk_ctrl] fpga_rst_ctrl=[hex32 $fpga_rst_ctrl] level_shifter=[hex32 $level_shifter]"

    # Probe the already-proven BRAM window first. This separates a dead GP0
    # clock/reset path from a problem local to the new KV peripheral.
    set bram_probe [read32 0x43c00000]
    puts "KV_GP0_PASS bram_probe=[hex32 $bram_probe]"

    require_numeric_equal "ABI core ID" \
        [read32 [expr {$KV_BASE + $REG_ID}]] $EXPECTED_ID
    require_numeric_equal "ABI geometry" \
        [read32 [expr {$KV_BASE + $REG_GEOMETRY}]] $expected_geometry
    puts "KV_ABI_PASS id=[hex32 $EXPECTED_ID] geometry=[hex32 $expected_geometry] transport=$expected_transport internal_axi_width=$expected_data_width"

    write32 [expr {$KV_BASE + $REG_CTRL}] 0x2
    write_and_verify_inputs

    write32 [expr {$KV_BASE + $REG_K_BASE_LO}] $K_DDR_BASE
    write32 [expr {$KV_BASE + $REG_K_BASE_HI}] 0
    write32 [expr {$KV_BASE + $REG_CONTEXT}] $CONTEXT
    write32 [expr {$KV_BASE + $REG_TOKEN_POS}] [expr {$CONTEXT - 1}]
    write32 [expr {$KV_BASE + $REG_CFG}] $SCALE_UQ5_11

    require_numeric_equal "K base low" \
        [read32 [expr {$KV_BASE + $REG_K_BASE_LO}]] $K_DDR_BASE
    require_numeric_equal "K base high" \
        [read32 [expr {$KV_BASE + $REG_K_BASE_HI}]] 0
    require_numeric_equal "context" \
        [read32 [expr {$KV_BASE + $REG_CONTEXT}]] $CONTEXT
    require_numeric_equal "scale" \
        [read32 [expr {$KV_BASE + $REG_CFG}]] $SCALE_UQ5_11

    write32 [expr {$KV_BASE + $REG_CTRL}] 0x1
    set status 0
    set polls 0
    while {$polls < 200} {
        set status [read32 [expr {$KV_BASE + $REG_STATUS}]]
        if {($status & 0x6) != 0} {
            break
        }
        incr polls
        after 10
    }
    if {($status & 0x4) != 0} {
        set error_code [read32 [expr {$KV_BASE + $REG_ERROR}]]
        fail "engine error status=[hex32 $status] code=[hex32 $error_code]"
    }
    if {($status & 0x2) == 0} {
        fail "engine timeout polls=$polls status=[hex32 $status]"
    }
    if {($status & 0x1) != 0} {
        fail "engine still busy after DONE status=[hex32 $status]"
    }

    for {set token 0} {$token < $CONTEXT} {incr token} {
        set raw [read32 [expr {$KV_BASE + $LOGIT_BASE + $token * 4}]]
        set observed [signed32 $raw]
        set expected [expected_logit $token]
        puts "KV_LOGIT token=$token got=$observed expected=$expected raw=[hex32 $raw]"
        if {$observed != $expected} {
            fail "logit token=$token got=$observed expected=$expected"
        }
    }

    set perf [read32 [expr {$KV_BASE + $REG_PERF}]]
    puts "KV_BOARD_SMOKE_PASS context=$CONTEXT head_dim=128 perf_cycles=$perf status=[hex32 $status]"
}

set self_test_only 0
set build_root ""
if {$argc == 1 && [lindex $argv 0] eq "--self-test"} {
    set self_test_only 1
} elseif {$argc == 2 && [lindex $argv 0] eq "--self-test"} {
    set self_test_only 1
    configure_context [lindex $argv 1]
} elseif {$argc == 1} {
    set build_root [lindex $argv 0]
} elseif {$argc == 2} {
    set build_root [lindex $argv 0]
    configure_context [lindex $argv 1]
} else {
    puts stderr "usage: xsdb ZyboZ7/run_kv_v2_board_smoke.tcl <platform-output-directory> ?context?"
    puts stderr "       xsdb ZyboZ7/run_kv_v2_board_smoke.tcl --self-test ?context?"
    exit 2
}

vector_self_test
if {$self_test_only} {
    exit 0
}

set run_rc [catch {run_kv_smoke $build_root} run_message run_options]
catch {disconnect}
if {$run_rc != 0} {
    puts stderr $run_message
    exit 1
}
exit 0
