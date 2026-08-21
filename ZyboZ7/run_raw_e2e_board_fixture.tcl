# run_kvq_raw_full_board_smoke.tcl -- XSDB raw K4/QK/softmax/V5/AV board test.
#
# Hardware use after a completed Zybo platform build:
#   xsdb ZyboZ7/run_kvq_raw_full_board_smoke.tcl \
#       <build-root> <wrapper-evidence-root> <expected-cable-serial>
#
# Golden packing/reference checks do not connect to hardware:
#   xsdb ZyboZ7/run_kvq_raw_full_board_smoke.tcl --self-test ?12|16?
#
# The hardware path is intentionally not entered without an explicit cable
# serial. The canned c7 vector/oracle self-test never connects to hardware.

set RAW_BASE            0x43c20000
set PROJECTION_BASE     0x43c30000
set WEIGHT_BASE         0x44000000
set BRAM_BASE           0x43c00000
set K_DDR_BASE          0x02000000
set V_DDR_BASE          0x02100000
set AXI_DATA_WIDTH      64
set HEADS               4
set HEAD_DIM            128
set RESULT_COUNT        512
set CONTEXT             7
set K_STRIDE_BYTES      64
set V_STRIDE_BYTES      80
set DDR_CHUNK_WORDS     64

set REG_CTRL            0x0000
set REG_STATUS          0x0004
set REG_K_BASE_LO       0x0008
set REG_K_BASE_HI       0x000c
set REG_V_BASE_LO       0x0010
set REG_V_BASE_HI       0x0014
set REG_CONTEXT         0x0018
set REG_Q_COUNT         0x001c
set REG_K_SCALE_COUNT   0x0020
set REG_V_SCALE_COUNT   0x0024
set REG_ERROR           0x0028
set REG_ERROR_INFO      0x002c
set REG_ID              0x0030
set REG_GEOMETRY        0x0034
set REG_SCALE_FMT       0x0038
set REG_PROGRESS        0x003c
set REG_PERF            0x0040
set REG_QK_READ_BEATS   0x0044
set REG_QK_BURSTS       0x0048
set REG_QK_AR_STALLS    0x004c
set REG_QK_R_STALLS     0x0050
set REG_QK_META_WAIT    0x0054
set REG_QK_DOT_CYCLES   0x0058
set REG_QK_SCORE_COUNT  0x005c
set REG_AV_READ_BEATS   0x0060
set REG_AV_BURSTS       0x0064
set REG_AV_AR_STALLS    0x0068
set REG_AV_R_STALLS     0x006c
set REG_SAT_COUNT       0x0070
set REG_SINK_CTRL       0x0074
set REG_GENERATION      0x0078
set REG_MULT_STYLE      0x007c
set REG_DENOM0          0x0080
set REG_RECIP0          0x0090
set Q_BASE              0x1000
set K_SCALE_BASE        0x2000
set V_SCALE_BASE        0x2400
set SCORE_BASE          0x3000
set RESULT_BASE         0x4000

set PROJ_REG_CTRL       0x00
set PROJ_REG_STATUS     0x04
set PROJ_REG_ACT_WR     0x08
set PROJ_REG_CT         0x0c
set PROJ_REG_DEPTH      0x10
set PROJ_REG_RIDX       0x14
set PROJ_REG_RDATA      0x18
set PROJ_REG_ID         0x1c
set PROJ_REG_CYCLES     0x20
set PROJ_EXPECTED_ID    0x7c0de002

set EXPECTED_ID         0x4b560303
set EXPECTED_GEOMETRY   0x40801204
set EXPECTED_STATUS     0x00000012

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT [file dirname $SCRIPT_DIR]

proc fail {message} {
    error "KVQ_RAW_FULL_BOARD_FAIL: $message"
}

proc hex32 {value} {
    return [format "0x%08X" [expr {$value & 0xffffffff}]]
}

proc hex48 {value} {
    return [format "0x%012X" [expr {$value & 0xffffffffffff}]]
}

proc signed_bits {value width} {
    set modulus [expr {1 << $width}]
    set masked [expr {$value & ($modulus - 1)}]
    if {$masked >= ($modulus >> 1)} {
        return [expr {$masked - $modulus}]
    }
    return $masked
}

proc require_numeric_equal {label observed expected} {
    if {[expr {$observed & 0xffffffff}] !=
        [expr {$expected & 0xffffffff}]} {
        fail "$label got=[hex32 $observed] expected=[hex32 $expected]"
    }
}

proc read_text_file {path label} {
    if {![file isfile $path]} {
        fail "$label is absent: $path"
    }
    set channel [open $path r]
    try {
        return [read $channel]
    } finally {
        close $channel
    }
}

proc sha256_file {path label} {
    if {![file isfile $path] || [file size $path] <= 0} {
        fail "$label is absent or empty: $path"
    }
    if {[catch {exec certutil.exe -hashfile $path SHA256} output]} {
        fail "$label SHA-256 failed for '$path': $output"
    }
    if {![regexp -nocase {([0-9a-f]{64})} $output -> digest]} {
        fail "$label SHA-256 output is malformed for '$path': $output"
    }
    return [string toupper $digest]
}

proc paths_equal {left right} {
    set left_path [file normalize $left]
    set right_path [file normalize $right]
    if {$::tcl_platform(platform) eq "windows"} {
        return [string equal -nocase $left_path $right_path]
    }
    return [string equal $left_path $right_path]
}

proc parse_key_value_file {path label} {
    set values [dict create]
    set line_number 0
    foreach raw_line [split [read_text_file $path $label] "\n"] {
        incr line_number
        set line [string trim $raw_line]
        if {$line eq ""} {
            continue
        }
        if {![regexp {^([^=]+)=(.*)$} $line -> key value]} {
            fail "$label has malformed line $line_number: '$line'"
        }
        set key [string trim $key]
        if {$key eq "" || [dict exists $values $key]} {
            fail "$label has an empty or duplicate key at line $line_number: '$key'"
        }
        dict set values $key $value
    }
    return $values
}

proc require_dict_keys {values keys label} {
    foreach key $keys {
        if {![dict exists $values $key]} {
            fail "$label is missing '$key'"
        }
    }
}

proc round_even_div {numerator denominator} {
    if {$numerator < 0 || $denominator <= 0} {
        fail "round_even_div requires numerator>=0 and denominator>0"
    }
    set quotient [expr {$numerator / $denominator}]
    set remainder [expr {$numerator % $denominator}]
    set doubled [expr {$remainder * 2}]
    if {$doubled > $denominator ||
        ($doubled == $denominator && ($quotient & 1))} {
        incr quotient
    }
    return $quotient
}

proc quantize_q8_8 {scaled scale_width} {
    set negative [expr {$scaled < 0}]
    set magnitude [expr {$negative ? -$scaled : $scaled}]
    if {$scale_width == 16} {
        set rounded [round_even_div $magnitude 8]
    } else {
        set rounded $magnitude
    }
    set saturated 0
    if {!$negative && $rounded > 32767} {
        set value 32767
        set saturated 1
    } elseif {$negative && $rounded > 32768} {
        set value -32768
        set saturated 1
    } else {
        set value [expr {$negative ? -$rounded : $rounded}]
    }
    return [list $value $saturated]
}

proc reciprocal_oracle {denominator} {
    if {$denominator <= 0} {
        fail "reciprocal denominator must be positive"
    }
    set exponent 0
    set scan $denominator
    while {$scan > 1} {
        set scan [expr {$scan >> 1}]
        incr exponent
    }
    set dividend [expr {1 << ($exponent + 12)}]
    set code [round_even_div $dividend $denominator]
    if {$code <= 0 || $code > 8191 || $exponent > 27} {
        fail "reciprocal is out of frozen F12 range denominator=$denominator code=$code exponent=$exponent"
    }
    return [list $code $exponent]
}

proc normalize_oracle {numerator reciprocal exponent scale_width} {
    set product [expr {$numerator * $reciprocal}]
    set negative [expr {$product < 0}]
    set magnitude [expr {$negative ? -$product : $product}]
    set scale_fraction [expr {$scale_width == 12 ? 8 : 11}]
    set shift [expr {$exponent + 12 + $scale_fraction - 8}]
    set rounded [round_even_div $magnitude [expr {1 << $shift}]]
    set saturated 0
    if {!$negative && $rounded > 131071} {
        set value 131071
        set saturated 1
    } elseif {$negative && $rounded > 131072} {
        set value -131072
        set saturated 1
    } else {
        set value [expr {$negative ? -$rounded : $rounded}]
    }
    return [list $value $saturated]
}

proc pack_codes {codes width} {
    set mask [expr {(1 << $width) - 1}]
    set packed {}
    set bit_buffer 0
    set valid_bits 0
    foreach code $codes {
        set bit_buffer [expr {$bit_buffer | (($code & $mask) << $valid_bits)}]
        incr valid_bits $width
        while {$valid_bits >= 8} {
            lappend packed [expr {$bit_buffer & 0xff}]
            set bit_buffer [expr {$bit_buffer >> 8}]
            incr valid_bits -8
        }
    }
    if {$valid_bits != 0 || $bit_buffer != 0} {
        fail "packed width=$width stream ended on a partial nonzero byte"
    }
    return $packed
}

proc packed_code {packed code_index width} {
    set bit_index [expr {$code_index * $width}]
    set byte_index [expr {$bit_index / 8}]
    set shift [expr {$bit_index % 8}]
    set window [lindex $packed $byte_index]
    if {$byte_index + 1 < [llength $packed]} {
        set window [expr {$window |
            ([lindex $packed [expr {$byte_index + 1}]] << 8)}]
    }
    return [expr {($window >> $shift) & ((1 << $width) - 1)}]
}

proc packed_bytes_to_words {packed} {
    if {[llength $packed] % 4 != 0} {
        fail "packed byte count=[llength $packed] is not word aligned"
    }
    set words {}
    for {set index 0} {$index < [llength $packed]} {incr index 4} {
        lappend words [expr {
            [lindex $packed $index] |
            ([lindex $packed [expr {$index + 1}]] << 8) |
            ([lindex $packed [expr {$index + 2}]] << 16) |
            ([lindex $packed [expr {$index + 3}]] << 24)}]
    }
    return $words
}

proc make_canned_data {scale_width} {
    global CONTEXT HEADS HEAD_DIM RESULT_COUNT K_STRIDE_BYTES V_STRIDE_BYTES

    if {$scale_width ni {12 16}} {
        fail "canned oracle scale width must be 12 or 16, got '$scale_width'"
    }
    set scale_fraction [expr {$scale_width == 12 ? 8 : 11}]
    set unit_scale [expr {1 << $scale_fraction}]
    set q_multipliers {1 2 -1 -2}
    set q_values {}
    for {set head 0} {$head < $HEADS} {incr head} {
        set multiplier [lindex $q_multipliers $head]
        for {set dim 0} {$dim < $HEAD_DIM} {incr dim} {
            lappend q_values [expr {
                ($dim & 1) ? -$multiplier : $multiplier}]
        }
    }

    set k_pattern {1 -1 2 -2 3 -3 7}
    set k_codes {}
    set v_codes {}
    set k_scales {}
    set v_scales {}
    for {set token 0} {$token < $CONTEXT} {incr token} {
        set k_code [lindex $k_pattern $token]
        lappend k_scales $unit_scale
        lappend v_scales [expr {$unit_scale + $token * 5}]
        for {set dim 0} {$dim < $HEAD_DIM} {incr dim} {
            # The token-specific uniform component cancels against every
            # alternating Q vector.  Decrementing odd dimension 1 contributes
            # exactly one multiplier, so each head has a distinct signed score
            # while all tokens within that head remain softmax-equal.
            lappend k_codes [expr {$k_code - ($dim == 1 ? 1 : 0)}]
            lappend v_codes [expr {(($token * 11 + $dim * 7) % 31) - 15}]
        }
    }

    set scores {}
    set score_saturations 0
    for {set head 0} {$head < $HEADS} {incr head} {
        for {set token 0} {$token < $CONTEXT} {incr token} {
            set dot 0
            for {set dim 0} {$dim < $HEAD_DIM} {incr dim} {
                set q [lindex $q_values [expr {$head * $HEAD_DIM + $dim}]]
                set k [lindex $k_codes [expr {$token * $HEAD_DIM + $dim}]]
                set dot [expr {$dot + $q * $k}]
            }
            lassign [quantize_q8_8                 [expr {$dot * [lindex $k_scales $token]}] $scale_width]                 score saturated
            set expected_score [expr {
                [lindex $q_multipliers $head] * 256}]
            if {$score != $expected_score} {
                fail "canned equal-score invariant failed head=$head token=$token score=$score expected=$expected_score"
            }
            incr score_saturations $saturated
            lappend scores $score
        }
    }

    set exponent_codes {}
    set denominators {}
    set reciprocal_codes {}
    set reciprocal_exponents {}
    for {set head 0} {$head < $HEADS} {incr head} {
        # Each head is constant across tokens, so every independently
        # calculated score-minus-row-max is exactly zero and exp(0) is the
        # exact UQ1.15 representation of one.
        set denominator 0
        for {set token 0} {$token < $CONTEXT} {incr token} {
            set score [lindex $scores [expr {$head * $CONTEXT + $token}]]
            if {$score != [lindex $scores [expr {$head * $CONTEXT}]]} {
                fail "nonuniform score reached canned softmax oracle"
            }
            lappend exponent_codes 32768
            incr denominator 32768
        }
        lappend denominators $denominator
        lassign [reciprocal_oracle $denominator] reciprocal exponent
        lappend reciprocal_codes $reciprocal
        lappend reciprocal_exponents $exponent
    }

    set numerators {}
    set normalized {}
    set result_saturation_flags {}
    set result_saturations 0
    for {set head 0} {$head < $HEADS} {incr head} {
        for {set dim 0} {$dim < $HEAD_DIM} {incr dim} {
            set numerator 0
            for {set token 0} {$token < $CONTEXT} {incr token} {
                set exp_code [lindex $exponent_codes                     [expr {$head * $CONTEXT + $token}]]
                set v_scale [lindex $v_scales $token]
                set v_code [lindex $v_codes                     [expr {$token * $HEAD_DIM + $dim}]]
                set numerator [expr {
                    $numerator + $exp_code * $v_scale * $v_code}]
            }
            lappend numerators $numerator
            lassign [normalize_oracle $numerator                 [lindex $reciprocal_codes $head]                 [lindex $reciprocal_exponents $head] $scale_width]                 output_code saturated
            lappend normalized $output_code
            lappend result_saturation_flags $saturated
            incr result_saturations $saturated
        }
    }

    set k_packed [pack_codes $k_codes 4]
    set v_packed [pack_codes $v_codes 5]
    if {[llength $k_packed] != $CONTEXT * $K_STRIDE_BYTES ||
        [llength $v_packed] != $CONTEXT * $V_STRIDE_BYTES ||
        [llength $q_values] != $RESULT_COUNT ||
        [llength $scores] != $HEADS * $CONTEXT ||
        [llength $numerators] != $RESULT_COUNT ||
        [llength $normalized] != $RESULT_COUNT} {
        fail "canned vector geometry mismatch"
    }

    return [dict create context $CONTEXT scale_width $scale_width         q_values $q_values k_codes $k_codes v_codes $v_codes         k_scales $k_scales v_scales $v_scales scores $scores         denominators $denominators reciprocal_codes $reciprocal_codes         reciprocal_exponents $reciprocal_exponents         numerators $numerators normalized $normalized         score_saturations $score_saturations         result_saturation_flags $result_saturation_flags         result_saturations $result_saturations         k_packed $k_packed v_packed $v_packed         k_words [packed_bytes_to_words $k_packed]         v_words [packed_bytes_to_words $v_packed]]
}

proc vector_self_test {data} {
    global CONTEXT HEADS HEAD_DIM RESULT_COUNT K_STRIDE_BYTES V_STRIDE_BYTES
    set k_codes [dict get $data k_codes]
    set v_codes [dict get $data v_codes]
    set k_packed [dict get $data k_packed]
    set v_packed [dict get $data v_packed]

    for {set index 0} {$index < [llength $k_codes]} {incr index} {
        if {[packed_code $k_packed $index 4] !=
            ([lindex $k_codes $index] & 0xf)} {
            fail "K4 packing mismatch index=$index"
        }
    }
    for {set index 0} {$index < [llength $v_codes]} {incr index} {
        if {[packed_code $v_packed $index 5] !=
            ([lindex $v_codes $index] & 0x1f)} {
            fail "V5 packing mismatch index=$index"
        }
    }
    if {[dict get $data denominators] ne [lrepeat $HEADS         [expr {$CONTEXT * 32768}]]} {
        fail "canned denominator oracle mismatch"
    }
    if {[dict get $data reciprocal_codes] ne [lrepeat $HEADS 2341] ||
        [dict get $data reciprocal_exponents] ne [lrepeat $HEADS 17]} {
        fail "canned reciprocal oracle mismatch"
    }
    set expected_scores {}
    foreach multiplier {1 2 -1 -2} {
        for {set token 0} {$token < $CONTEXT} {incr token} {
            lappend expected_scores [expr {$multiplier * 256}]
        }
    }
    if {[dict get $data scores] ne $expected_scores} {
        fail "canned head-major signed score oracle mismatch"
    }
    set saturation_sum 0
    foreach saturated [dict get $data result_saturation_flags] {
        incr saturation_sum $saturated
    }
    if {[dict get $data score_saturations] != 0 ||
        [dict get $data result_saturations] != $saturation_sum} {
        fail "canned saturation oracle accounting mismatch"
    }
    puts "KVQ_RAW_FULL_VECTOR_SELF_TEST_PASS context=$CONTEXT scale_width=[dict get $data scale_width] k_bytes=[llength $k_packed] v_bytes=[llength $v_packed] scores=[llength [dict get $data scores]] results=$RESULT_COUNT"
    return $data
}

proc exactly_one_file {pattern label} {
    set files [glob -nocomplain -types f $pattern]
    if {[llength $files] != 1} {
        fail "$label expected exactly one file for '$pattern'; got=$files"
    }
    set path [file normalize [lindex $files 0]]
    if {[file size $path] <= 0} {
        fail "$label is empty: $path"
    }
    return $path
}

proc locate_build_artifacts {build_root} {
    set bit_path [exactly_one_file \
        [file join $build_root artifacts *.bit] "bitstream"]
    set xsa_path [exactly_one_file \
        [file join $build_root artifacts *.xsa] "XSA"]
    set ps7_init_path [exactly_one_file \
        [file join $build_root artifacts ps7_init.tcl] \
        "verified ps7_init.tcl"]
    set build_result_path [exactly_one_file \
        [file join $build_root artifacts build_result.tcl] "build result"]
    set checksums_path [exactly_one_file \
        [file join $build_root artifacts SHA256SUMS.txt] \
        "artifact checksums"]
    set identity_path [exactly_one_file \
        [file join $build_root identity manifest.tcl] \
        "build identity manifest"]

    return [dict create bit_path $bit_path xsa_path $xsa_path \
        ps7_init_path $ps7_init_path build_result_path $build_result_path \
        checksums_path $checksums_path identity_path $identity_path]
}

proc require_build_identity {build_root} {
    global REPO_ROOT AXI_DATA_WIDTH

    set identity_path [file join $build_root identity manifest.tcl]
    if {![file isfile $identity_path]} {
        fail "build identity manifest is absent: $identity_path"
    }
    unset -nocomplain ::zybo_bringup_identity
    uplevel #0 [list source $identity_path]
    if {![info exists ::zybo_bringup_identity]} {
        fail "build identity did not define ::zybo_bringup_identity"
    }
    set identity $::zybo_bringup_identity
    require_dict_keys $identity {
        schema_version pl_clock_hz kv_smoke_enabled av_diag_enabled raw_full_enabled
        raw_full_ip_repo raw_full_component_sha256
        raw_full_m_axi_data_width raw_full_scale_width
        raw_full_qk_mult_style raw_full_av_mult_style raw_full_profile
        raw_e2e_enabled raw_e2e_ip_repo
        raw_e2e_projection_component_sha256 raw_e2e_weight_component_sha256
    } "build identity"
    if {[dict get $identity schema_version] != 2} {
        fail "RAW-full smoke requires platform identity schema 2"
    }
    foreach disabled_key {kv_smoke_enabled av_diag_enabled} {
        set value [dict get $identity $disabled_key]
        if {![string is boolean -strict $value] || [expr {$value ? 1 : 0}]} {
            fail "RAW-full replacement build requires $disabled_key=0, got '$value'"
        }
    }
    set enabled [dict get $identity raw_full_enabled]
    if {![string is boolean -strict $enabled] || ![expr {$enabled ? 1 : 0}]} {
        fail "build identity says RAW-full is disabled: '$enabled'"
    }

    set width [dict get $identity raw_full_m_axi_data_width]
    set clock_hz [dict get $identity pl_clock_hz]
    set scale_width [dict get $identity raw_full_scale_width]
    set qk_style [dict get $identity raw_full_qk_mult_style]
    set av_style [dict get $identity raw_full_av_mult_style]
    set profile [dict get $identity raw_full_profile]
    if {$clock_hz ni {75000000 81250000} ||
        $width ni {64 128} || $scale_width ni {12 16} ||
        $qk_style != 2 || $av_style ni {1 2}} {
        fail "invalid RAW-full identity width/scale/styles: width=$width scale=$scale_width QK=$qk_style AV=$av_style"
    }
    set expected_profile [expr {$av_style == 1 ? "LUT_RELIEF" : "BALANCED"}]
    if {$profile ne $expected_profile} {
        fail "RAW-full identity profile='$profile' does not match QK/AV=$qk_style/$av_style"
    }
    if {$width != 64 || $scale_width != 12 || $qk_style != 2 ||
        $av_style != 1 || $profile ne "LUT_RELIEF" ||
        ![dict get $identity raw_e2e_enabled]} {
        fail "combined RAW-E2E requires HP64/SCALE12/LUT_RELIEF QK=2 AV=1 and raw_e2e_enabled=1"
    }

    set identity_repo_raw [dict get $identity raw_full_ip_repo]
    if {[string trim $identity_repo_raw] eq ""} {
        fail "RAW-full identity has an empty packaged-IP repo"
    }
    set identity_repo [file normalize $identity_repo_raw]
    set component_path         [file join $identity_repo axi_kvq_raw_full_diag component.xml]
    if {![file isfile $component_path]} {
        fail "RAW-full packaged component is absent: $component_path"
    }
    set component_hash [dict get $identity raw_full_component_sha256]
    if {![regexp {^[0-9A-F]{64}$} $component_hash]} {
        fail "RAW-full component hash is not an uppercase SHA-256: '$component_hash'"
    }
    set actual_component_hash [sha256_file $component_path         "RAW-full component"]
    if {$actual_component_hash ne $component_hash} {
        fail "RAW-full component changed after build: got=$actual_component_hash expected=$component_hash"
    }

    set package_identity_path         [file join [file dirname $identity_repo] package_identity.txt]
    set package_identity [parse_key_value_file $package_identity_path         "RAW-full package identity"]
    set source_relpaths {
        rtl/axi_kvq_raw_full_diag.v
        rtl/kv_v03_raw_k4_qk_engine.v
        rtl/kv_v03_hp64_range_reader.v
        rtl/qk_group_dot.v
        rtl/kv_v03_qk_score_quantizer.v
        rtl/kv_v03_score_row_commit_guard.v
        rtl/kv_v03_softmax_av_pipeline.v
        rtl/kv_v03_softmax_engine.v
        rtl/kv_v03_softmax.v
        rtl/kv_v03_score_store.v
        rtl/kv_v03_exp_lut.v
        rtl/kv_v03_reciprocal.v
        rtl/kv_v03_raw_v5_av_engine.v
        rtl/kv_v03_raw_v5_axi_reader.v
        rtl/kv_v03_av_accumulator.v
        rtl/kv_v03_v5_weight_mul.v
        rtl/kv_v03_av_normalizer.v
    }
    set package_keys {
        flow vivado_version part clock_hz m_axi_data_width scale_width
        qk_mult_style av_mult_style raw_full_profile ip_vlnv repo_root
    }
    foreach relative_path $source_relpaths {
        lappend package_keys "source.$relative_path.sha256"
    }
    require_dict_keys $package_identity $package_keys         "RAW-full package identity"
    foreach {key expected} [list         flow axi_kvq_raw_full_diag_portable_package         vivado_version 2025.1         part xc7z020clg400-1         clock_hz $clock_hz         m_axi_data_width $width         scale_width $scale_width         qk_mult_style $qk_style         av_mult_style $av_style         raw_full_profile $profile         ip_vlnv shepherdscientific.com:user:axi_kvq_raw_full_diag:1.0] {
        if {[dict get $package_identity $key] ne $expected} {
            fail "RAW-full package identity '$key'='[dict get $package_identity $key]' expected='$expected'"
        }
    }
    if {![paths_equal [dict get $package_identity repo_root] $REPO_ROOT]} {
        fail "RAW-full package source repo='[dict get $package_identity repo_root]' expected='[file normalize $REPO_ROOT]'"
    }
    foreach relative_path $source_relpaths {
        set source_path [file join $REPO_ROOT $relative_path]
        set expected_hash [string toupper             [dict get $package_identity "source.$relative_path.sha256"]]
        set actual_hash [sha256_file $source_path             "RAW-full source $relative_path"]
        if {$actual_hash ne $expected_hash} {
            fail "RAW-full source hash mismatch for $relative_path: got=$actual_hash expected=$expected_hash"
        }
    }
    set e2e_repo [file normalize [dict get $identity raw_e2e_ip_repo]]
    set e2e_package_identity_path [file join [file dirname $e2e_repo] package_identity.txt]
    set e2e_package_identity [parse_key_value_file $e2e_package_identity_path "RAW-E2E package identity"]
    require_dict_keys $e2e_package_identity {flow commit part clock_hz
        source.rtl/axi_gemm_stream.v.sha256 source.rtl/weight_bram128.v.sha256
        source.rtl/ternary_gemm.v.sha256 source.rtl/ternary_dot.v.sha256
        source.rtl/ternary_weight.v.sha256} "RAW-E2E package identity"
    foreach {key expected} [list flow raw_e2e_projection_package part xc7z020clg400-1 clock_hz $clock_hz] {
        if {[dict get $e2e_package_identity $key] ne $expected} {
            fail "RAW-E2E package identity $key='[dict get $e2e_package_identity $key]' expected='$expected'"
        }
    }
    foreach {relative key} {
        rtl/axi_gemm_stream.v source.rtl/axi_gemm_stream.v.sha256
        rtl/weight_bram128.v source.rtl/weight_bram128.v.sha256
        rtl/ternary_gemm.v source.rtl/ternary_gemm.v.sha256
        rtl/ternary_dot.v source.rtl/ternary_dot.v.sha256
        rtl/ternary_weight.v source.rtl/ternary_weight.v.sha256
    } {
        set actual [sha256_file [file join $REPO_ROOT $relative] "RAW-E2E source $relative"]
        if {$actual ne [dict get $e2e_package_identity $key]} { fail "RAW-E2E source hash mismatch: $relative" }
    }
    set projection_component [file join $e2e_repo axi_gemm_stream component.xml]
    set weight_component [file join $e2e_repo weight_bram128 component.xml]
    set projection_hash [sha256_file $projection_component "projection component"]
    set weight_hash [sha256_file $weight_component "weight component"]
    if {$projection_hash ne [dict get $identity raw_e2e_projection_component_sha256] ||
        $weight_hash ne [dict get $identity raw_e2e_weight_component_sha256]} {
        fail "RAW-E2E component hashes differ from build identity"
    }
    return [dict create component_hash $component_hash component_path $component_path \
        package_repo $identity_repo package_identity_path $package_identity_path \
        clock_hz $clock_hz width $width scale_width $scale_width qk_style $qk_style \
        av_style $av_style profile $profile e2e_repo $e2e_repo \
        projection_hash $projection_hash weight_hash $weight_hash]
}

proc require_build_artifacts {build_root identity_info artifacts} {
    set bit_path [dict get $artifacts bit_path]
    set xsa_path [dict get $artifacts xsa_path]
    set ps7_init_path [dict get $artifacts ps7_init_path]
    set build_result_path [dict get $artifacts build_result_path]
    set checksums_path [dict get $artifacts checksums_path]

    unset -nocomplain ::zybo_bringup_build_result
    uplevel #0 [list source $build_result_path]
    if {![info exists ::zybo_bringup_build_result]} {
        fail "build result did not define ::zybo_bringup_build_result"
    }
    set result $::zybo_bringup_build_result
    require_dict_keys $result {
        schema_version part board_part pl_clock_hz kv_smoke_enabled
        av_diag_enabled raw_full_enabled raw_full_ip_repo
        raw_full_component_sha256 raw_full_m_axi_data_width
        raw_full_scale_width raw_full_qk_mult_style
        raw_full_av_mult_style raw_full_profile evidence_sha256
        raw_e2e_enabled raw_e2e_ip_repo raw_e2e_projection_component_sha256
        raw_e2e_weight_component_sha256
    } "build result"
    foreach {key expected} {
        schema_version 3
        part xc7z020clg400-1
        board_part digilentinc.com:zybo-z7-20:part0:1.2
        kv_smoke_enabled 0
        av_diag_enabled 0
        raw_full_enabled 1
        raw_e2e_enabled 1
    } {
        if {[dict get $result $key] ne $expected} {
            fail "build result '$key'='[dict get $result $key]' expected='$expected'"
        }
    }
    set clock_hz [dict get $result pl_clock_hz]
    if {$clock_hz ni {75000000 81250000}} {
        fail "RAW-full board smoke accepts only 75 or 81.25 MHz builds; got pl_clock_hz=$clock_hz"
    }
    foreach {result_key identity_key} {
        raw_full_m_axi_data_width width
        raw_full_scale_width scale_width
        raw_full_qk_mult_style qk_style
        raw_full_av_mult_style av_style
        raw_full_profile profile
    } {
        if {[dict get $result $result_key] ne             [dict get $identity_info $identity_key]} {
            fail "build result $result_key differs from verified identity"
        }
    }
    if {![paths_equal [dict get $result raw_full_ip_repo]         [dict get $identity_info package_repo]]} {
        fail "build result RAW-full package repo differs from verified package repo"
    }
    if {[dict get $result raw_full_component_sha256] ne         [dict get $identity_info component_hash]} {
        fail "build result RAW-full component hash differs from platform identity"
    }
    if {![paths_equal [dict get $result raw_e2e_ip_repo] [dict get $identity_info e2e_repo]] ||
        [dict get $result raw_e2e_projection_component_sha256] ne [dict get $identity_info projection_hash] ||
        [dict get $result raw_e2e_weight_component_sha256] ne [dict get $identity_info weight_hash]} {
        fail "build result RAW-E2E package identity differs from verified components"
    }

    set evidence_hashes [dict get $result evidence_sha256]
    set required_relative [list         "artifacts/[file tail $bit_path]"         "artifacts/[file tail $xsa_path]"         "artifacts/ps7_init.tcl"         "identity/manifest.tcl"]
    foreach relative_path $required_relative {
        if {![dict exists $evidence_hashes $relative_path]} {
            fail "build evidence is missing '$relative_path'"
        }
    }
    set checksum_lines {}
    foreach relative_path [lsort [dict keys $evidence_hashes]] {
        if {[file pathtype $relative_path] ne "relative" ||
            [lsearch -exact [file split $relative_path] ..] >= 0} {
            fail "build evidence has unsafe relative path '$relative_path'"
        }
        set expected_hash [dict get $evidence_hashes $relative_path]
        if {![regexp {^[0-9A-F]{64}$} $expected_hash]} {
            fail "build evidence has malformed SHA-256 for '$relative_path': '$expected_hash'"
        }
        set actual_hash [sha256_file [file join $build_root $relative_path]             "build evidence $relative_path"]
        if {$actual_hash ne $expected_hash} {
            fail "build evidence hash mismatch for '$relative_path': got=$actual_hash expected=$expected_hash"
        }
        lappend checksum_lines "$expected_hash  $relative_path"
    }
    set expected_checksums "[join $checksum_lines "\n"]\n"
    if {[read_text_file $checksums_path "artifact checksums"] ne         $expected_checksums} {
        fail "SHA256SUMS.txt does not exactly match build_result evidence_sha256"
    }

    return $artifacts
}

proc require_wrapper_pass {evidence_root build_root artifacts} {
    set evidence_root [file normalize $evidence_root]
    if {![file isdirectory $evidence_root]} {
        fail "wrapper evidence directory does not exist: $evidence_root"
    }
    set run_identity_path [file join $evidence_root RUN_IDENTITY.json]
    set run_inputs_path [file join $evidence_root RUN_INPUTS.json]
    set run_json [read_text_file $run_identity_path "wrapper run identity"]
    if {![regexp -line {^  "schema": "zybo-vivado-launch-result-v3",$} \
        $run_json] ||
        ![regexp -line {^  "result": "PASS",$} $run_json]} {
        fail "wrapper run identity is not a schema-v3 PASS: $run_identity_path"
    }
    set native_build_root [file nativename [file normalize $build_root]]
    set escaped_build_root [string map [list \\ \\\\] $native_build_root]
    if {[string first \
        "\"output_directory\": \"$escaped_build_root\"" $run_json] < 0} {
        fail "wrapper PASS does not name this build output: $build_root"
    }

    set anchored_paths [list \
        [file join $build_root .build_complete] \
        [dict get $artifacts identity_path] \
        [dict get $artifacts bit_path] \
        [dict get $artifacts xsa_path] \
        [dict get $artifacts ps7_init_path] \
        [dict get $artifacts build_result_path] \
        [dict get $artifacts checksums_path] \
        $run_inputs_path]
    set lower_json [string tolower $run_json]
    foreach path $anchored_paths {
        set digest [string tolower [sha256_file $path "wrapper-anchored file"]]
        if {[string first $digest $lower_json] < 0} {
            fail "wrapper PASS does not anchor SHA-256 $digest for '$path'"
        }
    }
    return $run_identity_path
}

proc read_words {address count} {
    if {$count < 1} {
        fail "invalid read count=$count at [hex32 $address]"
    }
    set raw [mrd -force -value -size w [hex32 $address] $count]
    if {[llength $raw] != $count} {
        fail "memory read at [hex32 $address] returned [llength $raw] words expected=$count raw='$raw'"
    }
    set values {}
    foreach value $raw {
        lappend values [expr {$value & 0xffffffff}]
    }
    return $values
}

proc read32 {address} {
    return [lindex [read_words $address 1] 0]
}

proc write32 {address value} {
    mwr -force -size w [hex32 $address] [hex32 $value]
}

proc make_projection_data {} {
    set activations {}
    set expected [lrepeat 64 0]
    set weight_rows {}
    for {set k 0} {$k < 1024} {incr k} {
        set activation [expr {(($k * 7) % 11) - 5}]
        lappend activations $activation
        set words [lrepeat 4 0]
        for {set c 0} {$c < 64} {incr c} {
            set weight [expr {(($k * 5 + $c * 7 + ($c >> 2)) % 3) - 1}]
            set code [expr {$weight < 0 ? 2 : ($weight > 0 ? 1 : 0)}]
            set wi [expr {$c >> 4}]
            set shift [expr {($c & 15) * 2}]
            lset words $wi [expr {([lindex $words $wi] | ($code << $shift)) & 0xffffffff}]
            lset expected $c [expr {[lindex $expected $c] + $activation * $weight}]
        }
        lappend weight_rows $words
    }
    return [dict create activations $activations weight_rows $weight_rows expected $expected]
}

proc projection_self_test {projection} {
    if {[llength [dict get $projection activations]] != 1024 ||
        [llength [dict get $projection weight_rows]] != 1024 ||
        [llength [dict get $projection expected]] != 64} {
        fail "projection fixture geometry is invalid"
    }
    set nonzero 0
    foreach value [dict get $projection expected] { if {$value != 0} { incr nonzero } }
    if {$nonzero < 32} { fail "projection fixture lacks column diversity: nonzero=$nonzero" }
    puts "RAW_E2E_PROJECTION_VECTOR_SELF_TEST_PASS depth=1024 outputs=64 nonzero=$nonzero"
}

proc run_projection {projection} {
    global PROJECTION_BASE WEIGHT_BASE PROJ_REG_CTRL PROJ_REG_STATUS
    global PROJ_REG_ACT_WR PROJ_REG_CT PROJ_REG_DEPTH PROJ_REG_RIDX
    global PROJ_REG_RDATA PROJ_REG_ID PROJ_REG_CYCLES PROJ_EXPECTED_ID
    require_numeric_equal "projection ID" \
        [read32 [expr {$PROJECTION_BASE + $PROJ_REG_ID}]] $PROJ_EXPECTED_ID
    set rows [dict get $projection weight_rows]
    for {set k 0} {$k < 1024} {incr k} {
        set address [expr {$WEIGHT_BASE + (($k << 4) * 16)}]
        set encoded {}
        foreach word [lindex $rows $k] { lappend encoded [hex32 $word] }
        mwr -force -size w [hex32 $address] $encoded
    }
    write32 [expr {$PROJECTION_BASE + $PROJ_REG_CTRL}] 4
    foreach activation [dict get $projection activations] {
        write32 [expr {$PROJECTION_BASE + $PROJ_REG_ACT_WR}] [expr {$activation & 0xff}]
    }
    write32 [expr {$PROJECTION_BASE + $PROJ_REG_CT}] 0
    write32 [expr {$PROJECTION_BASE + $PROJ_REG_DEPTH}] 1024
    # CTRL[3] is deliberately asserted. ENABLE_INT8=0 must make it inert.
    write32 [expr {$PROJECTION_BASE + $PROJ_REG_CTRL}] 9
    set status 0
    for {set poll 0} {$poll < 2000} {incr poll} {
        set status [read32 [expr {$PROJECTION_BASE + $PROJ_REG_STATUS}]]
        if {$status & 2} { break }
        after 1
    }
    require_numeric_equal "projection status" $status 2
    set cycles [read32 [expr {$PROJECTION_BASE + $PROJ_REG_CYCLES}]]
    require_numeric_equal "Tier2 projection cycles" $cycles 1031
    set mismatches 0
    set expected [dict get $projection expected]
    for {set c 0} {$c < 64} {incr c} {
        write32 [expr {$PROJECTION_BASE + $PROJ_REG_RIDX}] $c
        set observed [signed_bits [read32 [expr {$PROJECTION_BASE + $PROJ_REG_RDATA}]] 32]
        if {$observed != [lindex $expected $c]} {
            puts stderr "PROJECTION_MISMATCH column=$c got=$observed expected=[lindex $expected $c]"
            incr mismatches
        }
    }
    if {$mismatches != 0} { fail "projection mismatches=$mismatches" }
    puts "RAW_E2E_PROJECTION_BOARD_PASS outputs=64 depth=1024 cycles=$cycles legacy_int8_disabled=1"
    return $cycles
}

proc read_words_chunked {address count} {
    global DDR_CHUNK_WORDS
    set values {}
    for {set offset 0} {$offset < $count} {incr offset $DDR_CHUNK_WORDS} {
        set chunk_count [expr {min($DDR_CHUNK_WORDS, $count - $offset)}]
        set chunk [read_words [expr {$address + $offset * 4}] $chunk_count]
        set values [concat $values $chunk]
    }
    return $values
}

proc write_words_verified {address words label} {
    global DDR_CHUNK_WORDS
    set count [llength $words]
    for {set offset 0} {$offset < $count} {incr offset $DDR_CHUNK_WORDS} {
        set final [expr {min($count - 1, $offset + $DDR_CHUNK_WORDS - 1)}]
        set chunk [lrange $words $offset $final]
        set encoded {}
        foreach value $chunk {
            lappend encoded [hex32 $value]
        }
        set chunk_address [expr {$address + $offset * 4}]
        mwr -force -size w [hex32 $chunk_address] $encoded
        set observed [read_words $chunk_address [llength $chunk]]
        for {set index 0} {$index < [llength $chunk]} {incr index} {
            if {[expr {[lindex $observed $index] & 0xffffffff}] !=
                [expr {[lindex $chunk $index] & 0xffffffff}]} {
                fail "$label readback word=[expr {$offset + $index}] address=[hex32 [expr {$chunk_address + $index * 4}]] got=[hex32 [lindex $observed $index]] expected=[hex32 [lindex $chunk $index]]"
            }
        }
    }
    puts "KVQ_RAW_FULL_LOAD_PASS label={$label} base=[hex32 $address] words=$count bytes=[expr {$count * 4}]"
}

proc write_mmio_words {address words label} {
    set index 0
    foreach value $words {
        write32 [expr {$address + $index * 4}] $value
        incr index
    }
    puts "KVQ_RAW_FULL_LOAD_PASS label={$label} base=[hex32 $address] words=$index"
}

proc clear_status {} {
    global RAW_BASE REG_CTRL REG_STATUS REG_ERROR
    write32 [expr {$RAW_BASE + $REG_CTRL}] 0x2
    require_numeric_equal "CLEAR status"         [read32 [expr {$RAW_BASE + $REG_STATUS}]] 0
    require_numeric_equal "CLEAR error"         [read32 [expr {$RAW_BASE + $REG_ERROR}]] 0
}

proc load_case_inputs {data} {
    global RAW_BASE K_DDR_BASE V_DDR_BASE
    global REG_K_BASE_LO REG_K_BASE_HI REG_V_BASE_LO REG_V_BASE_HI
    global REG_CONTEXT REG_Q_COUNT REG_K_SCALE_COUNT REG_V_SCALE_COUNT
    global REG_SINK_CTRL Q_BASE K_SCALE_BASE V_SCALE_BASE RESULT_COUNT

    set context [dict get $data context]
    write_words_verified $K_DDR_BASE [dict get $data k_words]         "DDR dense raw K4"
    write_words_verified $V_DDR_BASE [dict get $data v_words]         "DDR dense raw V5"

    set q_words {}
    foreach value [dict get $data q_values] {
        lappend q_words [expr {$value & 0xff}]
    }
    write_mmio_words [expr {$RAW_BASE + $Q_BASE}] $q_words         "AXI-Lite four Q vectors"

    set token 0
    foreach scale [dict get $data k_scales] {
        write32 [expr {$RAW_BASE + $K_SCALE_BASE + $token * 4}] $scale
        incr token
    }
    set token 0
    foreach scale [dict get $data v_scales] {
        write32 [expr {$RAW_BASE + $V_SCALE_BASE + $token * 4}] $scale
        incr token
    }

    write32 [expr {$RAW_BASE + $REG_K_BASE_LO}] $K_DDR_BASE
    write32 [expr {$RAW_BASE + $REG_K_BASE_HI}] 0
    write32 [expr {$RAW_BASE + $REG_V_BASE_LO}] $V_DDR_BASE
    write32 [expr {$RAW_BASE + $REG_V_BASE_HI}] 0
    write32 [expr {$RAW_BASE + $REG_CONTEXT}] $context
    write32 [expr {$RAW_BASE + $REG_Q_COUNT}] $RESULT_COUNT
    write32 [expr {$RAW_BASE + $REG_K_SCALE_COUNT}] $context
    write32 [expr {$RAW_BASE + $REG_V_SCALE_COUNT}] $context
    write32 [expr {$RAW_BASE + $REG_SINK_CTRL}] 1

    foreach {label register expected} [list         "K base low" $REG_K_BASE_LO $K_DDR_BASE         "K base high" $REG_K_BASE_HI 0         "V base low" $REG_V_BASE_LO $V_DDR_BASE         "V base high" $REG_V_BASE_HI 0         context $REG_CONTEXT $context         "Q count" $REG_Q_COUNT $RESULT_COUNT         "K scale count" $REG_K_SCALE_COUNT $context         "V scale count" $REG_V_SCALE_COUNT $context         "sink ready" $REG_SINK_CTRL 1] {
        require_numeric_equal $label             [read32 [expr {$RAW_BASE + $register}]] $expected
    }
    puts "KVQ_RAW_FULL_METADATA_PASS context=$context q_count=$RESULT_COUNT scale_width=[dict get $data scale_width]"
}

proc check_outputs_hidden {label} {
    global RAW_BASE SCORE_BASE RESULT_BASE RESULT_COUNT
    set score_words [read_words_chunked         [expr {$RAW_BASE + $SCORE_BASE}] $RESULT_COUNT]
    set result_words [read_words_chunked         [expr {$RAW_BASE + $RESULT_BASE}] [expr {$RESULT_COUNT * 4}]]
    set index 0
    foreach word [concat $score_words $result_words] {
        if {$word != 0} {
            fail "$label exposed stale output word=$index value=[hex32 $word]"
        }
        incr index
    }
    puts "KVQ_RAW_FULL_OUTPUTS_HIDDEN_PASS label={$label} score_words=$RESULT_COUNT result_words=[expr {$RESULT_COUNT * 4}]"
}

proc wait_terminal {label} {
    global RAW_BASE REG_STATUS REG_ERROR
    set status 0
    set polls 0
    while {$polls < 1000} {
        set status [read32 [expr {$RAW_BASE + $REG_STATUS}]]
        if {($status & 0x1) == 0 && ($status & 0x0e) != 0} {
            return $status
        }
        incr polls
        after 10
    }
    set error_word [read32 [expr {$RAW_BASE + $REG_ERROR}]]
    fail "$label terminal timeout status=[hex32 $status] error=[hex32 $error_word] polls=$polls"
}

proc compare_scores {data run_label} {
    global RAW_BASE SCORE_BASE HEADS HEAD_DIM CONTEXT RESULT_COUNT
    set scores [dict get $data scores]
    set words [read_words_chunked         [expr {$RAW_BASE + $SCORE_BASE}] $RESULT_COUNT]
    for {set head 0} {$head < $HEADS} {incr head} {
        for {set token 0} {$token < $HEAD_DIM} {incr token} {
            set flat [expr {$head * $HEAD_DIM + $token}]
            set wanted 0
            if {$token < $CONTEXT} {
                set score [lindex $scores [expr {$head * $CONTEXT + $token}]]
                set wanted [expr {$score & 0xffff}]
                if {$score < 0} {
                    set wanted [expr {$wanted | 0xffff0000}]
                }
            }
            if {[lindex $words $flat] != [expr {$wanted & 0xffffffff}]} {
                fail "$run_label score head=$head token=$token got=[hex32 [lindex $words $flat]] expected=[hex32 $wanted]"
            }
        }
    }
    puts "KVQ_RAW_FULL_SCORES_PASS run=$run_label active=[expr {$HEADS * $CONTEXT}] hidden_padding=[expr {$RESULT_COUNT - $HEADS * $CONTEXT}]"
}

proc compare_softmax_metadata {data run_label} {
    global RAW_BASE REG_DENOM0 REG_RECIP0 HEADS
    for {set head 0} {$head < $HEADS} {incr head} {
        set wanted_denom [lindex [dict get $data denominators] $head]
        require_numeric_equal "$run_label denominator head=$head"             [read32 [expr {$RAW_BASE + $REG_DENOM0 + $head * 4}]]             $wanted_denom
        set reciprocal [lindex [dict get $data reciprocal_codes] $head]
        set exponent [lindex [dict get $data reciprocal_exponents] $head]
        set wanted_word [expr {($exponent << 13) | $reciprocal}]
        require_numeric_equal "$run_label reciprocal head=$head"             [read32 [expr {$RAW_BASE + $REG_RECIP0 + $head * 4}]]             $wanted_word
    }
    puts "KVQ_RAW_FULL_SOFTMAX_META_PASS run=$run_label heads=$HEADS"
}

proc compare_results {data run_label} {
    global RAW_BASE RESULT_BASE RESULT_COUNT
    set words [read_words_chunked         [expr {$RAW_BASE + $RESULT_BASE}] [expr {$RESULT_COUNT * 4}]]
    set numerators [dict get $data numerators]
    set normalized [dict get $data normalized]
    set saturated_flags [dict get $data result_saturation_flags]
    for {set index 0} {$index < $RESULT_COUNT} {incr index} {
        set low [lindex $words [expr {$index * 4}]]
        set high [lindex $words [expr {$index * 4 + 1}]]
        set codeword [lindex $words [expr {$index * 4 + 2}]]
        set reserved [lindex $words [expr {$index * 4 + 3}]]
        set numerator [lindex $numerators $index]
        set wanted_raw [expr {$numerator & 0xffffffffffff}]
        set wanted_low [expr {$wanted_raw & 0xffffffff}]
        set wanted_high [expr {($wanted_raw >> 32) & 0xffff}]
        if {$numerator < 0} {
            set wanted_high [expr {$wanted_high | 0xffff0000}]
        }
        set output_code [lindex $normalized $index]
        set wanted_codeword [expr {
            (([lindex $saturated_flags $index] & 1) << 31) |
            ($output_code & 0x3ffff)}]
        if {$low != $wanted_low || $high != ($wanted_high & 0xffffffff) ||
            $codeword != $wanted_codeword || $reserved != 0} {
            set got_raw [expr {(($high & 0xffff) << 32) | $low}]
            fail "$run_label result index=$index numerator_got=[hex48 $got_raw] numerator_expected=[hex48 $wanted_raw] code_got=[hex32 $codeword] code_expected=[hex32 $wanted_codeword] reserved=[hex32 $reserved]"
        }
    }
    puts "KVQ_RAW_FULL_RESULTS_PASS run=$run_label numerators=$RESULT_COUNT normalized=$RESULT_COUNT"
}

proc collect_counters {data run_label} {
    global RAW_BASE REG_PERF REG_QK_READ_BEATS REG_QK_BURSTS
    global REG_QK_AR_STALLS REG_QK_R_STALLS REG_QK_META_WAIT
    global REG_QK_DOT_CYCLES REG_QK_SCORE_COUNT REG_AV_READ_BEATS
    global REG_AV_BURSTS REG_AV_AR_STALLS REG_AV_R_STALLS REG_SAT_COUNT
    global CONTEXT HEADS K_STRIDE_BYTES V_STRIDE_BYTES AXI_DATA_WIDTH

    set counters [dict create]
    foreach {name offset} [list         perf $REG_PERF         qk_read_beats $REG_QK_READ_BEATS         qk_bursts $REG_QK_BURSTS         qk_ar_stalls $REG_QK_AR_STALLS         qk_r_stalls $REG_QK_R_STALLS         qk_meta_wait $REG_QK_META_WAIT         qk_dot_cycles $REG_QK_DOT_CYCLES         qk_score_count $REG_QK_SCORE_COUNT         av_read_beats $REG_AV_READ_BEATS         av_bursts $REG_AV_BURSTS         av_ar_stalls $REG_AV_AR_STALLS         av_r_stalls $REG_AV_R_STALLS         saturation $REG_SAT_COUNT] {
        dict set counters $name [read32 [expr {$RAW_BASE + $offset}]]
    }
    set expected_qk_beats         [expr {$CONTEXT * $K_STRIDE_BYTES / ($AXI_DATA_WIDTH / 8)}]
    set expected_av_beats         [expr {$CONTEXT * $V_STRIDE_BYTES / ($AXI_DATA_WIDTH / 8)}]
    foreach {name expected} [list         qk_read_beats $expected_qk_beats         qk_bursts $CONTEXT         qk_score_count [expr {$HEADS * $CONTEXT}]         av_read_beats $expected_av_beats         av_bursts $CONTEXT] {
        if {[dict get $counters $name] != $expected} {
            fail "$run_label counter $name=[dict get $counters $name] expected=$expected"
        }
    }
    set wanted_sat [expr {
        ([dict get $data result_saturations] << 16) |
        [dict get $data score_saturations]}]
    if {[dict get $counters saturation] != $wanted_sat} {
        fail "$run_label saturation=[hex32 [dict get $counters saturation]] expected=[hex32 $wanted_sat]"
    }
    if {[dict get $counters perf] == 0 ||
        [dict get $counters qk_dot_cycles] == 0} {
        fail "$run_label performance counters did not advance"
    }
    puts "KVQ_RAW_FULL_COUNTERS_PASS run=$run_label counters={$counters}"
    return $counters
}

proc run_success {data run_label previous_generation} {
    global RAW_BASE REG_CTRL REG_STATUS REG_ERROR REG_SINK_CTRL
    global REG_GENERATION EXPECTED_STATUS
    write32 [expr {$RAW_BASE + $REG_SINK_CTRL}] 1
    write32 [expr {$RAW_BASE + $REG_CTRL}] 1
    set status [wait_terminal $run_label]
    require_numeric_equal "$run_label status" $status $EXPECTED_STATUS
    require_numeric_equal "$run_label error"         [read32 [expr {$RAW_BASE + $REG_ERROR}]] 0
    compare_scores $data $run_label
    compare_softmax_metadata $data $run_label
    compare_results $data $run_label
    set counters [collect_counters $data $run_label]
    set generation [read32 [expr {$RAW_BASE + $REG_GENERATION}]]
    if {$generation <= $previous_generation} {
        fail "$run_label generation=$generation did not advance past $previous_generation"
    }
    puts "KVQ_RAW_FULL_RUN_PASS run=$run_label status=[hex32 $status] generation=$generation"
    return [dict merge $counters [dict create generation $generation]]
}

proc run_abort_gate {data} {
    global RAW_BASE REG_CTRL REG_STATUS REG_ERROR REG_SINK_CTRL REG_GENERATION
    write32 [expr {$RAW_BASE + $REG_SINK_CTRL}] 0
    write32 [expr {$RAW_BASE + $REG_CTRL}] 1
    set active_status [read32 [expr {$RAW_BASE + $REG_STATUS}]]
    if {($active_status & 1) == 0} {
        fail "abort gate did not hold the RAW-full job busy status=[hex32 $active_status]"
    }
    check_outputs_hidden "while busy before RESULT_VALID"
    write32 [expr {$RAW_BASE + $REG_CTRL}] 4
    set status [wait_terminal "abort"]
    require_numeric_equal "abort terminal status" $status 0x8
    require_numeric_equal "abort error"         [read32 [expr {$RAW_BASE + $REG_ERROR}]] 0
    check_outputs_hidden "after abort"
    write32 [expr {$RAW_BASE + $REG_SINK_CTRL}] 1
    set generation [read32 [expr {$RAW_BASE + $REG_GENERATION}]]
    puts "KVQ_RAW_FULL_ABORT_PASS status=[hex32 $status] generation=$generation no_reset=1"
    return $generation
}

proc run_reserved_k_fault {data} {
    global RAW_BASE K_DDR_BASE REG_CTRL REG_STATUS REG_ERROR REG_ERROR_INFO
    global REG_GENERATION
    clear_status
    set original [lindex [dict get $data k_words] 0]
    set corrupted [expr {($original & 0xfffffff0) | 0x8}]
    write_words_verified $K_DDR_BASE [list $corrupted]         "DDR reserved-K4 fault injection"
    write32 [expr {$RAW_BASE + $REG_CTRL}] 1
    set status [wait_terminal "reserved K4 fault"]
    require_numeric_equal "reserved K4 status" $status 0x4
    require_numeric_equal "reserved K4 error"         [read32 [expr {$RAW_BASE + $REG_ERROR}]] 0x21
    set info [read32 [expr {$RAW_BASE + $REG_ERROR_INFO}]]
    # QK source=2; make_error_tag(ST_DOT_WAIT=3, head=0, token=0).
    require_numeric_equal "reserved K4 error source/tag" $info 0x00023000
    check_outputs_hidden "after reserved K4 fault"
    write_words_verified $K_DDR_BASE [list $original]         "DDR K4 restoration"
    set generation [read32 [expr {$RAW_BASE + $REG_GENERATION}]]
    puts "KVQ_RAW_FULL_FAULT_PASS status=[hex32 $status] error=0x21 source=2 tag=0x3000 generation=$generation no_reset=1"
    return $generation
}

proc discover_unique_zybo_targets {{expected_serial ""}} {
    set properties [targets -target-properties]
    set matches [dict create apu {} cpu {} fpga {}]
    foreach target $properties {
        set complete 1
        foreach key {name jtag_cable_serial jtag_cable_manufacturer \
                     jtag_cable_product jtag_device_name} {
            if {![dict exists $target $key]} {
                set complete 0
            }
        }
        if {!$complete} {
            continue
        }
        set name [dict get $target name]
        set serial [dict get $target jtag_cable_serial]
        if {$expected_serial ne "" && $serial ne $expected_serial} {
            continue
        }
        if {[dict get $target jtag_cable_manufacturer] ne "Digilent" ||
            [dict get $target jtag_cable_product] ne "Zybo Z7"} {
            continue
        }
        if {$name eq "APU" &&
            [dict get $target jtag_device_name] eq "arm_dap"} {
            dict lappend matches apu $target
        } elseif {$name eq "ARM Cortex-A9 MPCore #0" &&
                  [dict get $target jtag_device_name] eq "arm_dap" &&
                  [dict exists $target parent] &&
                  [dict get $target parent] eq "APU"} {
            dict lappend matches cpu $target
        } elseif {$name eq "xc7z020" &&
                  [dict get $target jtag_device_name] eq "xc7z020"} {
            dict lappend matches fpga $target
        }
    }
    foreach role {apu cpu fpga} {
        if {[llength [dict get $matches $role]] != 1} {
            fail "expected exactly one Digilent Zybo Z7 $role target, got [llength [dict get $matches $role]]"
        }
    }
    set apu [lindex [dict get $matches apu] 0]
    set cpu [lindex [dict get $matches cpu] 0]
    set fpga [lindex [dict get $matches fpga] 0]
    set serial [dict get $apu jtag_cable_serial]
    if {$serial eq "" || [dict get $cpu jtag_cable_serial] ne $serial ||
        [dict get $fpga jtag_cable_serial] ne $serial} {
        fail "APU/CPU/FPGA targets do not share one nonempty cable serial"
    }
    return [dict create serial $serial apu $apu cpu $cpu fpga $fpga]
}

proc select_discovered_target {targets_info role} {
    set target [dict get $targets_info $role]
    set name [dict get $target name]
    set serial [dict get $targets_info serial]
    set filter [format {name == "%s" && jtag_cable_serial == "%s"} \
        $name $serial]
    targets -set -filter $filter
}

proc run_board_smoke {build_root evidence_root expected_serial} {
    global RAW_BASE BRAM_BASE K_DDR_BASE V_DDR_BASE AXI_DATA_WIDTH
    global EXPECTED_ID EXPECTED_GEOMETRY REG_ID REG_GEOMETRY
    global REG_SCALE_FMT REG_MULT_STYLE REG_GENERATION

    set build_root [file normalize $build_root]
    if {![file isdirectory $build_root]} {
        fail "platform output directory does not exist: $build_root"
    }
    set complete_path [file join $build_root .build_complete]
    if {![file isfile $complete_path]} {
        fail "platform build is not complete: $complete_path"
    }
    if {![regexp {^[A-Za-z0-9_.:-]+$} $expected_serial]} {
        fail "an exact nonempty cable serial containing only A-Z, a-z, 0-9, _, ., :, or - is required before connecting"
    }

    # Generated Tcl is executable only after the external wrapper, build
    # result, package identity, component, RTL sources, and every artifact hash
    # have all been verified.
    set artifacts [locate_build_artifacts $build_root]
    set wrapper_identity [require_wrapper_pass $evidence_root $build_root         $artifacts]
    set identity_info [require_build_identity $build_root]
    set AXI_DATA_WIDTH [dict get $identity_info width]
    set artifacts [require_build_artifacts $build_root $identity_info         $artifacts]
    set data [vector_self_test         [make_canned_data [dict get $identity_info scale_width]]]
    set projection [make_projection_data]
    projection_self_test $projection
    set component_hash [dict get $identity_info component_hash]
    set bit_path [dict get $artifacts bit_path]
    set xsa_path [dict get $artifacts xsa_path]
    set ps7_init_path [dict get $artifacts ps7_init_path]

    puts "KVQ_RAW_FULL_ARTIFACT bit=$bit_path"
    puts "KVQ_RAW_FULL_ARTIFACT xsa=$xsa_path"
    puts "KVQ_RAW_FULL_ARTIFACT ps7_init=$ps7_init_path"
    puts "KVQ_RAW_FULL_ARTIFACT wrapper_identity=$wrapper_identity"
    puts "KVQ_RAW_FULL_IDENTITY component_sha256=$component_hash axi_width=$AXI_DATA_WIDTH scale_width=[dict get $identity_info scale_width] profile=[dict get $identity_info profile] qk_style=[dict get $identity_info qk_style] av_style=[dict get $identity_info av_style]"

    connect -url tcp:127.0.0.1:3121
    set board_targets [discover_unique_zybo_targets $expected_serial]
    set cable_serial [dict get $board_targets serial]
    if {$cable_serial ne $expected_serial} {
        fail "discovered cable serial '$cable_serial' differs from requested '$expected_serial'"
    }
    puts "KVQ_RAW_FULL_TARGETS_PASS cable_serial=$cable_serial board={Digilent Zybo Z7} device=xc7z020"
    select_discovered_target $board_targets apu
    rst -system
    after 1000
    set board_targets [discover_unique_zybo_targets $cable_serial]
    select_discovered_target $board_targets fpga
    fpga -file $bit_path
    set board_targets [discover_unique_zybo_targets $cable_serial]
    select_discovered_target $board_targets cpu
    catch {stop}
    after 500
    set board_targets [discover_unique_zybo_targets $cable_serial]
    select_discovered_target $board_targets cpu
    uplevel #0 [list source $ps7_init_path]
    ps7_init
    if {[llength [info commands ps7_post_config_2_0]] != 1} {
        fail "generated PS init has no ps7_post_config_2_0 procedure"
    }
    ps7_post_config_2_0
    after 1000

    set fpga_clk_ctrl [read32 0xf8000170]
    set fpga_rst_ctrl [read32 0xf8000240]
    set level_shifter [read32 0xf8000900]
    set silicon_version [ps_version]
    puts "KVQ_RAW_FULL_PS_INIT_PASS silicon_version=$silicon_version post_config=2_0 fpga0_clk_ctrl=[hex32 $fpga_clk_ctrl] fpga_rst_ctrl=[hex32 $fpga_rst_ctrl] level_shifter=[hex32 $level_shifter]"

    set bram_probe [read32 $BRAM_BASE]
    puts "KVQ_RAW_FULL_BRAM_PROBE_PASS base=[hex32 $BRAM_BASE] value=[hex32 $bram_probe]"
    set tier2_cycles [run_projection $projection]

    set scale_width [dict get $identity_info scale_width]
    set expected_scale_fmt [expr {$scale_width == 12 ? 0x00000c08 :
                                                        0x0000100b}]
    set expected_mult_style [expr {
        ([dict get $identity_info av_style] << 4) |
        [dict get $identity_info qk_style]}]
    require_numeric_equal "RAW-full ID"         [read32 [expr {$RAW_BASE + $REG_ID}]] $EXPECTED_ID
    require_numeric_equal "RAW-full geometry"         [read32 [expr {$RAW_BASE + $REG_GEOMETRY}]] $EXPECTED_GEOMETRY
    require_numeric_equal "RAW-full scale format"         [read32 [expr {$RAW_BASE + $REG_SCALE_FMT}]] $expected_scale_fmt
    require_numeric_equal "RAW-full multiplier styles"         [read32 [expr {$RAW_BASE + $REG_MULT_STYLE}]] $expected_mult_style
    puts "KVQ_RAW_FULL_ABI_PASS base=[hex32 $RAW_BASE] id=[hex32 $EXPECTED_ID] geometry=[hex32 $EXPECTED_GEOMETRY] axi_width=$AXI_DATA_WIDTH scale_format=[hex32 $expected_scale_fmt] mult_style=[hex32 $expected_mult_style]"

    clear_status
    load_case_inputs $data
    check_outputs_hidden "before first RESULT_VALID"
    set initial_generation [read32 [expr {$RAW_BASE + $REG_GENERATION}]]
    set first [run_success $data "first" $initial_generation]

    clear_status
    check_outputs_hidden "after CLEAR"
    set abort_generation [run_abort_gate $data]
    if {$abort_generation <= [dict get $first generation]} {
        fail "abort generation did not advance"
    }

    set fault_generation [run_reserved_k_fault $data]
    if {$fault_generation <= $abort_generation} {
        fail "fault generation did not advance"
    }

    clear_status
    check_outputs_hidden "before no-reset restart"
    set restart [run_success $data "no_reset_restart" $fault_generation]

    puts "RAW_E2E_BOARD_PASS projection_outputs=64 tier2_cycles=$tier2_cycles context=[dict get $data context] scores=[expr {4 * [dict get $data context]}] denominators=4 reciprocals=4 numerators=512 normalized=512 saturation=[hex32 [dict get $first saturation]] qk_beats=[dict get $first qk_read_beats] qk_bursts=[dict get $first qk_bursts] qk_ar_stalls=[dict get $first qk_ar_stalls] qk_r_stalls=[dict get $first qk_r_stalls] av_beats=[dict get $first av_read_beats] av_bursts=[dict get $first av_bursts] av_ar_stalls=[dict get $first av_ar_stalls] av_r_stalls=[dict get $first av_r_stalls] raw_total_cycles=[dict get $first perf] no_reset_restart=pass"
}

set self_test_only 0
set build_root ""
set evidence_root ""
set expected_serial ""
set requested_scale ""
if {$argc == 1 && [lindex $argv 0] eq "--self-test"} {
    set self_test_only 1
} elseif {$argc == 2 && [lindex $argv 0] eq "--self-test"} {
    set self_test_only 1
    set requested_scale [lindex $argv 1]
    if {$requested_scale ni {12 16}} {
        puts stderr "self-test SCALE_WIDTH must be 12 or 16"
        exit 2
    }
} elseif {$argc == 3} {
    set build_root [lindex $argv 0]
    set evidence_root [lindex $argv 1]
    set expected_serial [lindex $argv 2]
} else {
    puts stderr "usage: xsdb ZyboZ7/run_raw_e2e_board_fixture.tcl <build-root> <wrapper-evidence-root> <expected-cable-serial>"
    puts stderr "       xsdb ZyboZ7/run_raw_e2e_board_fixture.tcl --self-test ?12|16?"
    exit 2
}

set run_rc [catch {
    if {$self_test_only} {
        projection_self_test [make_projection_data]
        set scale_widths [expr {$requested_scale eq "" ? {12 16} :
                                                         [list $requested_scale]}]
        foreach scale_width $scale_widths {
            vector_self_test [make_canned_data $scale_width]
        }
        foreach axi_width {64 128} {
            set bytes_per_beat [expr {$axi_width / 8}]
            if {$K_STRIDE_BYTES % $bytes_per_beat != 0 ||
                $V_STRIDE_BYTES % $bytes_per_beat != 0} {
                fail "canned DDR strides do not divide AXI width=$axi_width"
            }
            puts "KVQ_RAW_FULL_AXI_WIDTH_SELF_TEST_PASS axi_width=$axi_width k_beats=[expr {$CONTEXT * $K_STRIDE_BYTES / $bytes_per_beat}] v_beats=[expr {$CONTEXT * $V_STRIDE_BYTES / $bytes_per_beat}]"
        }
        puts "KVQ_RAW_FULL_STATIC_ORACLE_PASS scale_widths={$scale_widths} axi_widths={64 128} context=7 score_heads={256 512 -256 -512}"
    } else {
        run_board_smoke $build_root $evidence_root $expected_serial
    }
} run_message run_options]
if {!$self_test_only} {
    catch {disconnect}
}
if {$run_rc != 0} {
    puts stderr $run_message
    exit 1
}
exit 0
