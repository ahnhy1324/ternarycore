# run_kvq_canned_page_board_smoke.tcl -- Zybo RAW/COMPRESSED page A/B test.
#
# Hardware:
#   xsdb ZyboZ7/run_kvq_canned_page_board_smoke.tcl \
#       <build-root> <wrapper-evidence-root> <exact-cable-serial>
#
# Offline image/CRC checks only:
#   xsdb ZyboZ7/run_kvq_canned_page_board_smoke.tcl --self-test ?12|16?

set BASE                 0x43c20000
set BRAM_BASE            0x43c00000
set CONTEXT              128
set RESULT_COUNT         512
set CHUNK_WORDS          64

set REG_CTRL             0x0000
set REG_STATUS           0x0004
set REG_CONTEXT          0x0008
set REG_PAGE_DESC        0x000c
set REG_EPOCH            0x0010
set REG_K_TAG_LO         0x0014
set REG_K_TAG_HI         0x0018
set REG_V_TAG_LO         0x001c
set REG_V_TAG_HI         0x0020
set REG_K_WINDOW         0x0024
set REG_V_WINDOW         0x0028
set REG_PAGE_MODES       0x002c
set REG_ERROR            0x0030
set REG_ID               0x0038
set REG_GEOMETRY         0x003c
set REG_SCALE_FORMAT     0x0040
set REG_WRAPPER_CYCLES   0x0048
set REG_K_VALID_DATA_REQ 0x004c
set REG_V_VALID_DATA_REQ 0x0050
set REG_K_COPY_DATA_REQ  0x005c
set REG_V_COPY_DATA_REQ  0x0060
set REG_K_P16_REQ        0x006c
set REG_V_P16_REQ        0x0070
set REG_K_SCALE_REQ      0x0074
set REG_V_SCALE_REQ      0x0078
set REG_K_STARVE         0x007c
set REG_V_STARVE         0x0080
set REG_K_STARVE_HIGH    0x0084
set REG_V_STARVE_HIGH    0x0088
set REG_SCORE_COUNT      0x008c
set REG_RESULT_COUNT     0x0090
set REG_RAW_PAGE_COUNT   0x0098
set REG_DECODER_FAULTS   0x009c
set REG_DENOM0           0x0100
set REG_RECIP0           0x0120

set Q_BASE               0x1000
set K_PAGE_BASE          0x2000
set V_PAGE_BASE          0x5000
set K_SCALE_BASE         0x8000
set V_SCALE_BASE         0x8400
set SCORE_BASE           0x9000
set RESULT_BASE          0xa000

set GOOD_K_TAG_LO        0x0033015a
set GOOD_K_TAG_HI        0x00030007
set GOOD_V_TAG_LO        0x0033025a
set GOOD_V_TAG_HI        0x00030007
set EXPECTED_ID          0x4b560304
set EXPECTED_GEOMETRY    0x04808010

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT [file dirname $SCRIPT_DIR]

proc fail {message} {
    error "KVQ_CANNED_PAGE_BOARD_FAIL: $message"
}

proc hex32 {value} {
    return [format "0x%08X" [expr {$value & 0xffffffff}]]
}

proc require_equal {label observed expected} {
    if {[expr {$observed & 0xffffffff}] !=
        [expr {$expected & 0xffffffff}]} {
        fail "$label got=[hex32 $observed] expected=[hex32 $expected]"
    }
}

proc read_text {path label} {
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
        fail "$label SHA-256 failed: $output"
    }
    if {![regexp -nocase {([0-9a-f]{64})} $output -> digest]} {
        fail "$label SHA-256 output is malformed: $output"
    }
    return [string toupper $digest]
}

proc paths_equal {left right} {
    set left [file normalize $left]
    set right [file normalize $right]
    if {$::tcl_platform(platform) eq "windows"} {
        return [string equal -nocase $left $right]
    }
    return [string equal $left $right]
}

proc parse_key_values {path label} {
    set values [dict create]
    set line_number 0
    foreach raw [split [read_text $path $label] "\n"] {
        incr line_number
        set line [string trim $raw]
        if {$line eq ""} {
            continue
        }
        if {![regexp {^([^=]+)=(.*)$} $line -> key value]} {
            fail "$label malformed line $line_number: '$line'"
        }
        set key [string trim $key]
        if {$key eq "" || [dict exists $values $key]} {
            fail "$label duplicate/empty key at line $line_number"
        }
        dict set values $key $value
    }
    return $values
}

proc require_keys {values keys label} {
    foreach key $keys {
        if {![dict exists $values $key]} {
            fail "$label is missing '$key'"
        }
    }
}

proc exactly_one {pattern label} {
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

proc locate_artifacts {build_root} {
    return [dict create \
        bit [exactly_one [file join $build_root artifacts *.bit] bitstream] \
        xsa [exactly_one [file join $build_root artifacts *.xsa] XSA] \
        ps7 [exactly_one [file join $build_root artifacts ps7_init.tcl] ps7_init] \
        result [exactly_one [file join $build_root artifacts build_result.tcl] build_result] \
        sums [exactly_one [file join $build_root artifacts SHA256SUMS.txt] SHA256SUMS] \
        manifest [exactly_one [file join $build_root identity manifest.tcl] manifest]]
}

proc require_wrapper_pass {evidence_root build_root artifacts} {
    set evidence_root [file normalize $evidence_root]
    set run_identity [file join $evidence_root RUN_IDENTITY.json]
    set run_inputs [file join $evidence_root RUN_INPUTS.json]
    set json [read_text $run_identity "wrapper RUN_IDENTITY"]
    if {![regexp -line {^  "schema": "zybo-vivado-launch-result-v3",$} $json] ||
        ![regexp -line {^  "result": "PASS",$} $json]} {
        fail "wrapper result is not schema-v3 PASS: $run_identity"
    }
    set native_root [file nativename [file normalize $build_root]]
    set escaped [string map [list \\ \\\\] $native_root]
    if {[string first "\"output_directory\": \"$escaped\"" $json] < 0} {
        fail "wrapper result does not name build root $build_root"
    }
    set anchored [list [file join $build_root .build_complete] \
        [dict get $artifacts manifest] [dict get $artifacts bit] \
        [dict get $artifacts xsa] [dict get $artifacts ps7] \
        [dict get $artifacts result] [dict get $artifacts sums] $run_inputs]
    set lower [string tolower $json]
    foreach path $anchored {
        set digest [string tolower [sha256_file $path "wrapper anchored file"]]
        if {[string first $digest $lower] < 0} {
            fail "wrapper PASS does not anchor '$path'"
        }
    }
    return $run_identity
}

proc require_build_identity {build_root} {
    global REPO_ROOT
    set path [file join $build_root identity manifest.tcl]
    unset -nocomplain ::zybo_bringup_identity
    uplevel #0 [list source $path]
    if {![info exists ::zybo_bringup_identity]} {
        fail "identity manifest did not define ::zybo_bringup_identity"
    }
    set identity $::zybo_bringup_identity
    require_keys $identity {
        schema_version kv_smoke_enabled av_diag_enabled raw_full_enabled
        canned_page_enabled canned_page_ip_repo
        canned_page_component_sha256 canned_page_scale_bits
        canned_page_qk_mult_style canned_page_av_mult_style
        canned_page_profile canned_page_compiled_profile_id
        canned_page_compiled_k_codebook_id
        canned_page_compiled_v_codebook_id
    } "build identity"
    if {[dict get $identity schema_version] != 2} {
        fail "canned-page smoke requires identity schema 2"
    }
    foreach key {kv_smoke_enabled av_diag_enabled raw_full_enabled} {
        if {[dict get $identity $key]} {
            fail "canned-page build requires $key=0"
        }
    }
    if {![dict get $identity canned_page_enabled]} {
        fail "build identity says canned-page diagnostic is disabled"
    }
    set scale [dict get $identity canned_page_scale_bits]
    set qk [dict get $identity canned_page_qk_mult_style]
    set av [dict get $identity canned_page_av_mult_style]
    set profile [dict get $identity canned_page_profile]
    if {$scale ni {12 16} || $qk != 2 || $av ni {1 2}} {
        fail "invalid canned-page scale/styles: scale=$scale QK=$qk AV=$av"
    }
    set expected_profile [expr {$av == 1 ? "LUT_RELIEF" : "BALANCED"}]
    if {$profile ne $expected_profile} {
        fail "profile '$profile' does not match QK/AV=$qk/$av"
    }
    foreach {key expected} {
        canned_page_compiled_profile_id 51
        canned_page_compiled_k_codebook_id 1
        canned_page_compiled_v_codebook_id 2
    } {
        if {[dict get $identity $key] != $expected} {
            fail "identity $key differs from $expected"
        }
    }
    set repo [file normalize [dict get $identity canned_page_ip_repo]]
    set component [file join $repo axi_kvq_canned_page_diag component.xml]
    set component_hash [dict get $identity canned_page_component_sha256]
    if {![regexp {^[0-9A-F]{64}$} $component_hash] ||
        [sha256_file $component "canned-page component"] ne $component_hash} {
        fail "canned-page component/hash mismatch"
    }

    set package_identity_path [file join [file dirname $repo] package_identity.txt]
    set package [parse_key_values $package_identity_path "package identity"]
    set sources {
        rtl/axi_kvq_canned_page_diag.v
        rtl/kv_v03_typed_decode_lane_bank_4x1.v
        rtl/kv_v03_symbol_decoder.v
        rtl/kv_v03_scale12_reader.v
        rtl/kv_v03_page128_record_validator.v
        rtl/kv_v03_page_header.v
        rtl/kv_v03_crc32.v
        rtl/kv_v03_canned_page_arithmetic.v
        rtl/qk_group_dot.v
        rtl/kv_v03_qk_score_quantizer.v
        rtl/kv_v03_score_row_commit_guard.v
        rtl/kv_v03_softmax_engine.v
        rtl/kv_v03_score_store.v
        rtl/kv_v03_exp_lut.v
        rtl/kv_v03_reciprocal.v
        rtl/kv_v03_softmax.v
        rtl/kv_v03_av_accumulator.v
        rtl/kv_v03_v5_weight_mul.v
        rtl/kv_v03_av_normalizer.v
    }
    set keys {
        flow vivado_version part clock_hz scale_bits qk_mult_style
        av_mult_style canned_page_profile compiled_profile_id
        compiled_k_codebook_id compiled_v_codebook_id ip_vlnv repo_root
    }
    foreach source $sources {
        lappend keys "source.$source.sha256"
    }
    require_keys $package $keys "package identity"
    foreach {key expected} [list \
        flow axi_kvq_canned_page_diag_portable_package \
        vivado_version 2025.1 part xc7z020clg400-1 \
        scale_bits $scale qk_mult_style $qk av_mult_style $av \
        canned_page_profile $profile compiled_profile_id 51 \
        compiled_k_codebook_id 1 compiled_v_codebook_id 2 \
        ip_vlnv shepherdscientific.com:user:axi_kvq_canned_page_diag:1.0] {
        if {[dict get $package $key] ne $expected} {
            fail "package identity $key='[dict get $package $key]' expected='$expected'"
        }
    }
    if {![paths_equal [dict get $package repo_root] $REPO_ROOT]} {
        fail "package source repo differs from active worktree"
    }
    foreach source $sources {
        set actual [sha256_file [file join $REPO_ROOT $source] "source $source"]
        set expected [string toupper [dict get $package "source.$source.sha256"]]
        if {$actual ne $expected} {
            fail "source hash mismatch for $source"
        }
    }
    return [dict create identity $identity package $package package_repo $repo \
        component_hash $component_hash scale $scale qk $qk av $av \
        profile $profile]
}

proc require_build_result {build_root artifacts identity_info} {
    unset -nocomplain ::zybo_bringup_build_result
    uplevel #0 [list source [dict get $artifacts result]]
    if {![info exists ::zybo_bringup_build_result]} {
        fail "build_result did not define ::zybo_bringup_build_result"
    }
    set result $::zybo_bringup_build_result
    require_keys $result {
        schema_version part board_part pl_clock_hz kv_smoke_enabled
        av_diag_enabled raw_full_enabled canned_page_enabled
        canned_page_ip_repo canned_page_component_sha256
        canned_page_scale_bits canned_page_qk_mult_style
        canned_page_av_mult_style canned_page_profile
        canned_page_compiled_profile_id
        canned_page_compiled_k_codebook_id
        canned_page_compiled_v_codebook_id evidence_sha256
    } "build result"
    foreach {key expected} {
        schema_version 3
        part xc7z020clg400-1
        board_part digilentinc.com:zybo-z7-20:part0:1.2
        kv_smoke_enabled 0
        av_diag_enabled 0
        raw_full_enabled 0
        canned_page_enabled 1
        canned_page_compiled_profile_id 51
        canned_page_compiled_k_codebook_id 1
        canned_page_compiled_v_codebook_id 2
    } {
        if {[dict get $result $key] ne $expected} {
            fail "build result $key='[dict get $result $key]' expected='$expected'"
        }
    }
    set identity [dict get $identity_info identity]
    foreach key {
        canned_page_scale_bits canned_page_qk_mult_style
        canned_page_av_mult_style canned_page_profile
        canned_page_component_sha256
    } {
        if {[dict get $result $key] ne [dict get $identity $key]} {
            fail "build result $key differs from platform identity"
        }
    }
    if {![paths_equal [dict get $result canned_page_ip_repo] \
        [dict get $identity_info package_repo]]} {
        fail "build result package path differs from verified package"
    }
    set clock [dict get $result pl_clock_hz]
    if {$clock ni {75000000 81250000}} {
        fail "board A/B smoke accepts only 75 or 81.25 MHz; got $clock"
    }
    if {[dict get [dict get $identity_info package] clock_hz] != $clock} {
        fail "package clock and platform clock differ"
    }

    set hashes [dict get $result evidence_sha256]
    foreach required [list \
        "artifacts/[file tail [dict get $artifacts bit]]" \
        "artifacts/[file tail [dict get $artifacts xsa]]" \
        "artifacts/ps7_init.tcl" "identity/manifest.tcl"] {
        if {![dict exists $hashes $required]} {
            fail "build evidence is missing '$required'"
        }
    }
    set lines {}
    foreach relative [lsort [dict keys $hashes]] {
        set expected [dict get $hashes $relative]
        set actual [sha256_file [file join $build_root $relative] \
            "build evidence $relative"]
        if {$actual ne $expected} {
            fail "build evidence hash mismatch for $relative"
        }
        lappend lines "$expected  $relative"
    }
    if {[read_text [dict get $artifacts sums] SHA256SUMS] ne \
        "[join $lines "\n"]\n"} {
        fail "SHA256SUMS does not exactly match build_result"
    }
    dict set identity_info result $result
    return $identity_info
}

proc preflight {build_root evidence_root} {
    set build_root [file normalize $build_root]
    if {![file isfile [file join $build_root .build_complete]]} {
        fail "platform build is incomplete: $build_root"
    }
    set artifacts [locate_artifacts $build_root]
    set wrapper [require_wrapper_pass $evidence_root $build_root $artifacts]
    set identity [require_build_identity $build_root]
    set identity [require_build_result $build_root $artifacts $identity]
    return [dict create artifacts $artifacts identity $identity wrapper $wrapper]
}

proc crc_byte {state value} {
    set work $state
    for {set bit 0} {$bit < 8} {incr bit} {
        if {($work & 1) ^ (($value >> $bit) & 1)} {
            set work [expr {(($work >> 1) ^ 0xedb88320) & 0xffffffff}]
        } else {
            set work [expr {($work >> 1) & 0xffffffff}]
        }
    }
    return $work
}

proc zero_bytes {count} {
    return [lrepeat $count 0]
}

proc set_byte_bit {list_name bit_index value} {
    upvar 1 $list_name bytes
    if {$value} {
        set byte_index [expr {$bit_index / 8}]
        set bit [expr {$bit_index % 8}]
        lset bytes $byte_index [expr {[lindex $bytes $byte_index] | (1 << $bit)}]
    }
}

proc make_scales {scale_width} {
    set count [expr {(128 * $scale_width + 7) / 8}]
    set k [zero_bytes $count]
    set v [zero_bytes $count]
    for {set token 0} {$token < 128} {incr token} {
        set kval [expr {($scale_width == 16 ? 8 : 1) + ($token % 3)}]
        set vval [expr {($scale_width == 16 ? 9 : 2) + ($token % 2)}]
        for {set bit 0} {$bit < $scale_width} {incr bit} {
            set position [expr {$token * $scale_width + $bit}]
            set_byte_bit k $position [expr {($kval >> $bit) & 1}]
            set_byte_bit v $position [expr {($vval >> $bit) & 1}]
        }
    }
    return [dict create k $k v $v bytes $count]
}

proc stamp_crc {record payload_bytes scale_bytes} {
    set work 0xffffffff
    for {set n 0} {$n < 8} {incr n} {
        set work [crc_byte $work [lindex $record $n]]
    }
    for {set n 0} {$n < $payload_bytes} {incr n} {
        set work [crc_byte $work [lindex $record [expr {12 + $n}]]]
    }
    foreach byte $scale_bytes {
        set work [crc_byte $work $byte]
    }
    set work [expr {$work ^ 0xffffffff}]
    lset record 8 [expr {$work & 0xff}]
    lset record 9 [expr {($work >> 8) & 0xff}]
    lset record 10 [expr {($work >> 16) & 0xff}]
    lset record 11 [expr {($work >> 24) & 0xff}]
    return [list $record $work]
}

proc make_case {scale_width raw_mode {truncate_k 0} \
                {wrong_codebook 0} {corrupt_crc 0}} {
    set scales [make_scales $scale_width]
    if {$truncate_k} {
        set k_payload [zero_bytes 1]
    } elseif {$raw_mode} {
        set k_payload [lrepeat 8192 0x11]
    } else {
        set k_payload [zero_bytes 6144]
        for {set symbol 0} {$symbol < 16384} {incr symbol} {
            set bit0 [expr {$symbol * 3}]
            set byte0 [expr {$bit0 / 8}]
            set shift0 [expr {7 - ($bit0 % 8)}]
            lset k_payload $byte0 \
                [expr {[lindex $k_payload $byte0] | (1 << $shift0)}]
            set bit1 [expr {$bit0 + 1}]
            set byte1 [expr {$bit1 / 8}]
            set shift1 [expr {7 - ($bit1 % 8)}]
            lset k_payload $byte1 \
                [expr {[lindex $k_payload $byte1] | (1 << $shift1)}]
        }
    }
    if {$raw_mode} {
        set v_payload [zero_bytes 10240]
        for {set symbol 0} {$symbol < 16384} {incr symbol} {
            for {set bit 0} {$bit < 5} {incr bit} {
                set_byte_bit v_payload [expr {$symbol * 5 + $bit}] \
                    [expr {(5 >> $bit) & 1}]
            }
        }
    } else {
        set v_payload [zero_bytes 8192]
    }
    set k_payload_bytes [llength $k_payload]
    set v_payload_bytes [llength $v_payload]
    set scale_id [expr {$scale_width == 12 ? 1 : 2}]
    set k_header [list 0x03 0xc3 [expr {$raw_mode ? 1 : 0}] 0x7f \
        [expr {$k_payload_bytes & 0xff}] \
        [expr {($k_payload_bytes >> 8) & 0xff}] \
        [expr {$wrong_codebook ? 0x7f : 1}] $scale_id 0 0 0 0]
    set v_header [list 0x03 0xc3 [expr {$raw_mode ? 3 : 2}] 0x7f \
        [expr {$v_payload_bytes & 0xff}] \
        [expr {($v_payload_bytes >> 8) & 0xff}] 2 $scale_id 0 0 0 0]
    set k_record [concat $k_header $k_payload]
    set v_record [concat $v_header $v_payload]
    lassign [stamp_crc $k_record $k_payload_bytes [dict get $scales k]] \
        k_record k_crc
    lassign [stamp_crc $v_record $v_payload_bytes [dict get $scales v]] \
        v_record v_crc
    if {$corrupt_crc} {
        lset k_record 8 [expr {[lindex $k_record 8] ^ 1}]
    }
    set k_window [expr {((12 + $k_payload_bytes + 15) / 16) * 16}]
    set v_window [expr {((12 + $v_payload_bytes + 15) / 16) * 16}]
    set k_record [concat $k_record [zero_bytes [expr {$k_window - [llength $k_record]}]]]
    set v_record [concat $v_record [zero_bytes [expr {$v_window - [llength $v_record]}]]]
    return [dict create raw $raw_mode k $k_record v $v_record \
        k_scale [dict get $scales k] v_scale [dict get $scales v] \
        scale_bytes [dict get $scales bytes] k_window $k_window \
        v_window $v_window k_crc $k_crc v_crc $v_crc]
}

proc bytes_to_words {bytes} {
    if {[llength $bytes] % 4 != 0} {
        fail "byte list is not word aligned"
    }
    set words {}
    for {set n 0} {$n < [llength $bytes]} {incr n 4} {
        lappend words [expr {
            [lindex $bytes $n] |
            ([lindex $bytes [expr {$n+1}]] << 8) |
            ([lindex $bytes [expr {$n+2}]] << 16) |
            ([lindex $bytes [expr {$n+3}]] << 24)}]
    }
    return $words
}

proc make_query_words {} {
    set bytes {}
    for {set row 0} {$row < 4} {incr row} {
        for {set dim 0} {$dim < 128} {incr dim} {
            lappend bytes [expr {((($row * 13 + $dim * 5) % 23) - 11) & 0xff}]
        }
    }
    return [bytes_to_words $bytes]
}

proc self_test_case {scale_width} {
    set raw [make_case $scale_width 1]
    set compressed [make_case $scale_width 0]
    foreach {label values expected_k expected_v} [list \
        raw $raw 8208 10256 compressed $compressed 6160 8208] {
        if {[dict get $values k_window] != $expected_k ||
            [dict get $values v_window] != $expected_v} {
            fail "$label window geometry mismatch"
        }
        if {[llength [bytes_to_words [dict get $values k]]] * 4 != $expected_k ||
            [llength [bytes_to_words [dict get $values v]]] * 4 != $expected_v} {
            fail "$label word packing mismatch"
        }
    }
    if {[llength [make_query_words]] != 128} {
        fail "query image is not 128 words"
    }
    puts "KVQ_CANNED_PAGE_VECTOR_SELF_TEST_PASS scale_width=$scale_width raw_k_crc=[hex32 [dict get $raw k_crc]] raw_v_crc=[hex32 [dict get $raw v_crc]] compressed_k_crc=[hex32 [dict get $compressed k_crc]] compressed_v_crc=[hex32 [dict get $compressed v_crc]]"
}

proc read_words {address count} {
    if {$count < 1} {
        fail "invalid read count=$count"
    }
    set raw [mrd -force -value -size w [hex32 $address] $count]
    if {[llength $raw] != $count} {
        fail "read at [hex32 $address] returned [llength $raw], expected=$count"
    }
    set values {}
    foreach value $raw {
        lappend values [expr {$value & 0xffffffff}]
    }
    return $values
}

proc read_words_chunked {address count} {
    global CHUNK_WORDS
    set values {}
    for {set offset 0} {$offset < $count} {incr offset $CHUNK_WORDS} {
        set chunk [expr {min($CHUNK_WORDS, $count - $offset)}]
        set values [concat $values \
            [read_words [expr {$address + $offset * 4}] $chunk]]
    }
    return $values
}

proc read32 {address} {
    return [lindex [read_words $address 1] 0]
}

proc write32 {address value} {
    mwr -force -size w [hex32 $address] [hex32 $value]
}

proc write_words {address words label} {
    global CHUNK_WORDS
    set count [llength $words]
    for {set offset 0} {$offset < $count} {incr offset $CHUNK_WORDS} {
        set final [expr {min($count - 1, $offset + $CHUNK_WORDS - 1)}]
        set encoded {}
        foreach value [lrange $words $offset $final] {
            lappend encoded [hex32 $value]
        }
        mwr -force -size w [hex32 [expr {$address + $offset * 4}]] $encoded
    }
    puts "KVQ_CANNED_PAGE_LOAD_PASS label={$label} base=[hex32 $address] words=$count"
}

proc configure_common {} {
    global BASE REG_CONTEXT REG_PAGE_DESC REG_EPOCH
    global REG_K_TAG_LO REG_K_TAG_HI REG_V_TAG_LO REG_V_TAG_HI
    global GOOD_K_TAG_LO GOOD_K_TAG_HI GOOD_V_TAG_LO GOOD_V_TAG_HI
    write32 [expr {$BASE + $REG_CONTEXT}] 128
    write32 [expr {$BASE + $REG_PAGE_DESC}] 0x100
    write32 [expr {$BASE + $REG_EPOCH}] 0x1234
    write32 [expr {$BASE + $REG_K_TAG_LO}] $GOOD_K_TAG_LO
    write32 [expr {$BASE + $REG_K_TAG_HI}] $GOOD_K_TAG_HI
    write32 [expr {$BASE + $REG_V_TAG_LO}] $GOOD_V_TAG_LO
    write32 [expr {$BASE + $REG_V_TAG_HI}] $GOOD_V_TAG_HI
}

proc load_case {case_data} {
    global BASE REG_K_WINDOW REG_V_WINDOW REG_PAGE_MODES
    global Q_BASE K_PAGE_BASE V_PAGE_BASE K_SCALE_BASE V_SCALE_BASE
    write32 [expr {$BASE + $REG_K_WINDOW}] [dict get $case_data k_window]
    write32 [expr {$BASE + $REG_V_WINDOW}] [dict get $case_data v_window]
    write32 [expr {$BASE + $REG_PAGE_MODES}] \
        [expr {[dict get $case_data raw] ? 3 : 0}]
    write_words [expr {$BASE + $Q_BASE}] [make_query_words] queries
    write_words [expr {$BASE + $K_PAGE_BASE}] \
        [bytes_to_words [dict get $case_data k]] K_page
    write_words [expr {$BASE + $V_PAGE_BASE}] \
        [bytes_to_words [dict get $case_data v]] V_page
    write_words [expr {$BASE + $K_SCALE_BASE}] \
        [bytes_to_words [dict get $case_data k_scale]] K_scale
    write_words [expr {$BASE + $V_SCALE_BASE}] \
        [bytes_to_words [dict get $case_data v_scale]] V_scale
    foreach {register expected label} [list \
        $REG_K_WINDOW [dict get $case_data k_window] K_window \
        $REG_V_WINDOW [dict get $case_data v_window] V_window \
        $REG_PAGE_MODES [expr {[dict get $case_data raw] ? 3 : 0}] page_modes] {
        require_equal $label [read32 [expr {$BASE + $register}]] $expected
    }
}

proc clear_status {} {
    global BASE REG_CTRL REG_STATUS REG_ERROR
    write32 [expr {$BASE + $REG_CTRL}] 2
    require_equal "CLEAR status" [read32 [expr {$BASE + $REG_STATUS}]] 0
    require_equal "CLEAR error" [read32 [expr {$BASE + $REG_ERROR}]] 0
}

proc wait_success {label} {
    global BASE REG_STATUS REG_ERROR
    set status 0
    for {set poll 0} {$poll < 20000} {incr poll} {
        set status [read32 [expr {$BASE + $REG_STATUS}]]
        if {$status & 0x0c} {
            break
        }
        after 1
    }
    if {($status & 0x2c) != 0x24} {
        fail "$label did not finish successfully: status=[hex32 $status] error=[hex32 [read32 [expr {$BASE + $REG_ERROR}]]]"
    }
    return $status
}

proc wait_fault {label expected_code} {
    global BASE REG_STATUS REG_ERROR
    set status 0
    for {set poll 0} {$poll < 10000} {incr poll} {
        set status [read32 [expr {$BASE + $REG_STATUS}]]
        if {($status & 0x1008) == 0x1008} {
            break
        }
        after 1
    }
    if {($status & 0x1008) != 0x1008 || ($status & 0x20)} {
        fail "$label fault did not drain/clear-ready: status=[hex32 $status]"
    }
    set error [read32 [expr {$BASE + $REG_ERROR}]]
    require_equal "$label error code" [expr {$error & 0xff}] $expected_code
    puts "KVQ_CANNED_PAGE_FAULT_PASS label={$label} status=[hex32 $status] error=[hex32 $error]"
}

proc require_all_zero {values label} {
    set index 0
    foreach value $values {
        if {$value != 0} {
            fail "$label exposed word=$index value=[hex32 $value]"
        }
        incr index
    }
}

proc check_hidden {label} {
    global BASE SCORE_BASE RESULT_BASE REG_DENOM0 REG_RECIP0
    require_all_zero [read_words_chunked [expr {$BASE + $SCORE_BASE}] 512] \
        "$label scores"
    require_all_zero [read_words_chunked [expr {$BASE + $RESULT_BASE}] 1536] \
        "$label results"
    require_all_zero [read_words_chunked [expr {$BASE + $REG_DENOM0}] 4] \
        "$label denominators"
    require_all_zero [read_words_chunked [expr {$BASE + $REG_RECIP0}] 4] \
        "$label reciprocals"
    puts "KVQ_CANNED_PAGE_HIDDEN_PASS label={$label}"
}

proc capture_results {label} {
    global BASE SCORE_BASE RESULT_BASE REG_DENOM0 REG_RECIP0
    set scores [read_words_chunked [expr {$BASE + $SCORE_BASE}] 512]
    set results [read_words_chunked [expr {$BASE + $RESULT_BASE}] 1536]
    set denom [read_words_chunked [expr {$BASE + $REG_DENOM0}] 4]
    set recip [read_words_chunked [expr {$BASE + $REG_RECIP0}] 4]
    set score_nonzero 0
    foreach value $scores {
        if {$value & 0xffff} {
            incr score_nonzero
        }
    }
    set numerator_nonzero 0
    for {set n 0} {$n < 512} {incr n} {
        set lo [lindex $results [expr {$n * 3}]]
        set hi [expr {[lindex $results [expr {$n * 3 + 1}]] & 0xffff}]
        if {$lo != 0 || $hi != 0} {
            incr numerator_nonzero
        }
    }
    if {$score_nonzero == 0 || $numerator_nonzero == 0} {
        fail "$label produced an arithmetically trivial result"
    }
    puts "KVQ_CANNED_PAGE_RESULTS_PASS label={$label} scores=512 numerators=512 normalized=512 nonzero_scores=$score_nonzero nonzero_numerators=$numerator_nonzero"
    return [dict create scores $scores results $results denom $denom recip $recip]
}

proc compare_lists {label observed expected} {
    if {[llength $observed] != [llength $expected]} {
        fail "$label length mismatch"
    }
    for {set n 0} {$n < [llength $expected]} {incr n} {
        if {[lindex $observed $n] != [lindex $expected $n]} {
            fail "$label mismatch index=$n got=[hex32 [lindex $observed $n]] expected=[hex32 [lindex $expected $n]]"
        }
    }
}

proc compare_results {observed expected label} {
    foreach key {scores results denom recip} {
        compare_lists "$label $key" [dict get $observed $key] [dict get $expected $key]
    }
    puts "KVQ_CANNED_PAGE_AB_EQUAL_PASS label={$label} scores=512 numerators=512 normalized=512"
}

proc check_counters {raw_mode label} {
    global BASE REG_K_VALID_DATA_REQ REG_V_VALID_DATA_REQ
    global REG_K_COPY_DATA_REQ REG_V_COPY_DATA_REQ REG_K_P16_REQ REG_V_P16_REQ
    global REG_K_SCALE_REQ REG_V_SCALE_REQ REG_K_STARVE REG_V_STARVE
    global REG_K_STARVE_HIGH REG_V_STARVE_HIGH REG_SCORE_COUNT
    global REG_RESULT_COUNT REG_RAW_PAGE_COUNT REG_WRAPPER_CYCLES
    set counters [dict create]
    foreach {name register} {
        wrapper_cycles 0x0048 k_validator 0x004c v_validator 0x0050
        k_copy 0x005c v_copy 0x0060 k_p16 0x006c v_p16 0x0070
        k_scale 0x0074 v_scale 0x0078 k_starve 0x007c v_starve 0x0080
        k_starve_high 0x0084 v_starve_high 0x0088
        score_count 0x008c result_count 0x0090 raw_pages 0x0098
    } {
        dict set counters $name [read32 [expr {$BASE + $register}]]
    }
    foreach name {wrapper_cycles k_validator v_validator k_copy v_copy
                  k_starve v_starve k_starve_high v_starve_high} {
        if {[dict get $counters $name] == 0} {
            fail "$label counter $name is zero"
        }
    }
    foreach {name expected} {
        k_p16 4096 v_p16 4096 k_scale 128 v_scale 128
        score_count 512 result_count 512
    } {
        if {[dict get $counters $name] != $expected} {
            fail "$label counter $name=[dict get $counters $name] expected=$expected"
        }
    }
    set expected_raw [expr {$raw_mode ? 2 : 0}]
    if {[dict get $counters raw_pages] != $expected_raw} {
        fail "$label raw_pages=[dict get $counters raw_pages] expected=$expected_raw"
    }
    puts "KVQ_CANNED_PAGE_COUNTERS_PASS label={$label} counters={$counters}"
}

proc run_success {case_data label {reference ""}} {
    global BASE REG_CTRL
    write32 [expr {$BASE + $REG_CTRL}] 8
    write32 [expr {$BASE + $REG_CTRL}] 1
    wait_success $label
    set snapshot [capture_results $label]
    check_counters [dict get $case_data raw] $label
    if {$reference ne ""} {
        compare_results $snapshot $reference $label
    }
    return $snapshot
}

proc discover_unique_zybo_targets {expected_serial} {
    set matches [dict create apu {} cpu {} fpga {}]
    foreach target [targets -target-properties] {
        set complete 1
        foreach key {name jtag_cable_serial jtag_cable_manufacturer
                     jtag_cable_product jtag_device_name} {
            if {![dict exists $target $key]} {
                set complete 0
            }
        }
        if {!$complete ||
            [dict get $target jtag_cable_serial] ne $expected_serial ||
            [dict get $target jtag_cable_manufacturer] ne "Digilent" ||
            [dict get $target jtag_cable_product] ne "Zybo Z7"} {
            continue
        }
        set name [dict get $target name]
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
            fail "expected exactly one Zybo $role target; got [llength [dict get $matches $role]]"
        }
    }
    return [dict create serial $expected_serial \
        apu [lindex [dict get $matches apu] 0] \
        cpu [lindex [dict get $matches cpu] 0] \
        fpga [lindex [dict get $matches fpga] 0]]
}

proc select_target {targets_info role} {
    set target [dict get $targets_info $role]
    set filter [format {name == "%s" && jtag_cable_serial == "%s"} \
        [dict get $target name] [dict get $targets_info serial]]
    targets -set -filter $filter
}

proc run_board {build_root evidence_root expected_serial} {
    global BASE BRAM_BASE REG_ID REG_GEOMETRY REG_SCALE_FORMAT
    global EXPECTED_ID EXPECTED_GEOMETRY
    global REG_CTRL REG_STATUS REG_K_TAG_LO GOOD_K_TAG_LO REG_DECODER_FAULTS
    if {![regexp {^[A-Za-z0-9_.:-]+$} $expected_serial]} {
        fail "exact cable serial is required"
    }
    set preflight [preflight $build_root $evidence_root]
    set artifacts [dict get $preflight artifacts]
    set identity_info [dict get $preflight identity]
    set scale [dict get $identity_info scale]
    set raw [make_case $scale 1]
    set compressed [make_case $scale 0]
    self_test_case $scale

    puts "KVQ_CANNED_PAGE_ARTIFACT bit=[dict get $artifacts bit]"
    puts "KVQ_CANNED_PAGE_IDENTITY scale=$scale profile=[dict get $identity_info profile] qk_style=[dict get $identity_info qk] av_style=[dict get $identity_info av] component_sha256=[dict get $identity_info component_hash]"

    connect -url tcp:127.0.0.1:3121
    set targets_info [discover_unique_zybo_targets $expected_serial]
    puts "KVQ_CANNED_PAGE_TARGETS_PASS cable_serial=$expected_serial board={Digilent Zybo Z7-20 Rev D} device=xc7z020"
    select_target $targets_info apu
    rst -system
    after 1000
    set targets_info [discover_unique_zybo_targets $expected_serial]
    select_target $targets_info fpga
    fpga -file [dict get $artifacts bit]
    set targets_info [discover_unique_zybo_targets $expected_serial]
    select_target $targets_info cpu
    catch {stop}
    after 500
    uplevel #0 [list source [dict get $artifacts ps7]]
    ps7_init
    if {[llength [info commands ps7_post_config_2_0]] != 1} {
        fail "verified ps7_init.tcl has no ps7_post_config_2_0"
    }
    ps7_post_config_2_0
    after 1000
    puts "KVQ_CANNED_PAGE_PS_INIT_PASS silicon_version=[ps_version] post_config=2_0"
    puts "KVQ_CANNED_PAGE_BRAM_PROBE_PASS base=[hex32 $BRAM_BASE] value=[hex32 [read32 $BRAM_BASE]]"

    require_equal "canned-page ID" [read32 [expr {$BASE + $REG_ID}]] 0x4b560304
    require_equal "canned-page geometry" \
        [read32 [expr {$BASE + $REG_GEOMETRY}]] 0x04808010
    set scale_format [expr {$scale == 12 ? 0x000c0801 : 0x00100802}]
    require_equal "canned-page scale format" \
        [read32 [expr {$BASE + $REG_SCALE_FORMAT}]] $scale_format
    puts "KVQ_CANNED_PAGE_ABI_PASS base=[hex32 $BASE] id=[hex32 $EXPECTED_ID] geometry=[hex32 $EXPECTED_GEOMETRY] scale_format=[hex32 $scale_format]"

    configure_common
    clear_status
    load_case $raw
    check_hidden "before RAW start"
    set raw_reference [run_success $raw RAW]
    clear_status
    check_hidden "after RAW clear"

    load_case $compressed
    set compressed_snapshot [run_success $compressed COMPRESSED $raw_reference]
    clear_status
    check_hidden "after COMPRESSED clear"

    # Profile tag mismatch.
    write32 [expr {$BASE + $REG_K_TAG_LO}] 0x0034015a
    write32 [expr {$BASE + $REG_CTRL}] 1
    wait_fault profile_mismatch 0x03
    check_hidden "profile mismatch"
    clear_status
    write32 [expr {$BASE + $REG_K_TAG_LO}] $GOOD_K_TAG_LO

    # Codebook mismatch with a valid CRC.
    set wrong_codebook [make_case $scale 0 0 1 0]
    load_case $wrong_codebook
    write32 [expr {$BASE + $REG_CTRL}] 1
    wait_fault codebook_mismatch 0x02
    check_hidden "codebook mismatch"
    clear_status

    # Explicit CRC failure.
    set bad_crc [make_case $scale 0 0 0 1]
    load_case $bad_crc
    write32 [expr {$BASE + $REG_CTRL}] 1
    wait_fault crc_mismatch 0x02
    check_hidden "CRC mismatch"
    clear_status

    # CRC-valid truncated prefix reaches the real decoder fault path.
    set truncated [make_case $scale 0 1 0 0]
    load_case $truncated
    write32 [expr {$BASE + $REG_CTRL}] 1
    wait_fault decoder_truncation 0x03
    if {[read32 [expr {$BASE + $REG_DECODER_FAULTS}]] == 0} {
        fail "decoder fault counter stayed zero"
    }
    check_hidden "decoder truncation"
    clear_status

    # Abort, drain, and restart the exact same compressed image without reset.
    load_case $compressed
    write32 [expr {$BASE + $REG_CTRL}] 1
    # Keep START -> ABORT back-to-back.  A JTAG status-read round trip is
    # slower than this short on-chip canned job and can observe DONE instead
    # of the intended in-flight abort window.
    write32 [expr {$BASE + $REG_CTRL}] 4
    wait_fault abort_drain 0x05
    check_hidden "abort drain"
    clear_status
    set restart [run_success $compressed NO_RESET_RESTART $raw_reference]
    compare_results $restart $compressed_snapshot "restart vs first compressed"

    set result [dict get $identity_info result]
    puts "KVQ_CANNED_PAGE_BOARD_SMOKE_PASS board={Zybo Z7-20 Rev D} clock_hz=[dict get $result pl_clock_hz] scale_width=$scale profile=[dict get $identity_info profile] qk_style=[dict get $identity_info qk] av_style=[dict get $identity_info av] raw_compressed_equal=512_scores+512_numerators+512_normalized faults={profile codebook crc decoder abort} no_reset_restart=pass"
}

set self_test 0
set requested_scale ""
if {$argc == 1 && [lindex $argv 0] eq "--self-test"} {
    set self_test 1
} elseif {$argc == 2 && [lindex $argv 0] eq "--self-test"} {
    set self_test 1
    set requested_scale [lindex $argv 1]
    if {$requested_scale ni {12 16}} {
        puts stderr "self-test scale must be 12 or 16"
        exit 2
    }
} elseif {$argc != 3} {
    puts stderr "usage: xsdb ZyboZ7/run_kvq_canned_page_board_smoke.tcl <build-root> <wrapper-evidence-root> <exact-cable-serial>"
    puts stderr "       xsdb ZyboZ7/run_kvq_canned_page_board_smoke.tcl --self-test ?12|16?"
    exit 2
}

set rc [catch {
    if {$self_test} {
        set scales [expr {$requested_scale eq "" ? {12 16} : [list $requested_scale]}]
        foreach scale $scales {
            self_test_case $scale
        }
        puts "KVQ_CANNED_PAGE_STATIC_ORACLE_PASS scales={$scales} context=128 raw_compressed=prepared"
    } else {
        run_board [lindex $argv 0] [lindex $argv 1] [lindex $argv 2]
    }
} message options]
if {$rc} {
    puts stderr $message
    if {[dict exists $options -errorinfo]} {
        puts stderr [dict get $options -errorinfo]
    }
    exit 1
}
exit 0
