# run_v5_av_diag_board_smoke.tcl -- XSDB raw-V5 to AV numerator board test.
#
# Hardware use after a completed Zybo platform build:
#   xsdb ZyboZ7/run_v5_av_diag_board_smoke.tcl \
#       <build-root> <wrapper-evidence-root> ?case?
#
# Golden packing/reference checks do not connect to hardware:
#   xsdb ZyboZ7/run_v5_av_diag_board_smoke.tcl --self-test ?case?
#
# Supported cases are adversarial_c7 (default) and real_c128_l00_kvh0.

set AV_BASE             0x43c30000
set KV_BASE             0x43c20000
set BRAM_BASE           0x43c00000
set V_DDR_BASE          0x02000000
set AXI_DATA_WIDTH      64
set HEADS               4
set HEAD_DIM            128
set RESULT_COUNT        512
set V_STRIDE_BYTES      80
set DDR_CHUNK_WORDS     64

set REG_CTRL            0x0000
set REG_STATUS          0x0004
set REG_V_BASE_LO       0x0008
set REG_V_BASE_HI       0x000c
set REG_EXP_COUNT       0x0014
set REG_SCALE_COUNT     0x0018
set REG_CONTEXT         0x001c
set REG_PROGRESS        0x0020
set REG_PERF            0x0028
set REG_ERROR           0x002c
set REG_ID              0x0030
set REG_GEOMETRY        0x0034
set REG_V_STRIDE        0x0038
set REG_CAPS            0x003c
set REG_READ_BEATS      0x0040
set REG_AR_STALLS       0x0044
set REG_R_STALLS        0x0048
set REG_SCALE_FMT       0x004c
set RESULT_BASE         0x1000
set EXP_BASE            0x3000
set SCALE_BASE          0x4000

set EXPECTED_KV_ID      0x4b560002
set EXPECTED_AV_ID      0x4b560301
set EXPECTED_GEOMETRY   0x40801005
set EXPECTED_CAPS       0x0000001f
set EXPECTED_SCALE_FMT  0x00000c08
set EXPECTED_STATUS     0x00000012

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT [file dirname $SCRIPT_DIR]
set GOLDEN_ROOT [file join $REPO_ROOT analysis kv_validation v0_3 \
    rtl_goldens av]
set CASE_CONTEXT [dict create \
    adversarial_c7 7 \
    real_c128_l00_kvh0 128]

proc fail {message} {
    error "V5_AV_DIAG_BOARD_FAIL: $message"
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

proc read_hex_values {path width label} {
    if {![file isfile $path]} {
        fail "$label file is absent: $path"
    }
    set channel [open $path r]
    set contents [read $channel]
    close $channel

    set values {}
    set line_number 0
    set maximum [expr {(1 << $width) - 1}]
    foreach raw_line [split $contents "\n"] {
        incr line_number
        set line [string trim $raw_line]
        regsub {#.*$} $line {} line
        regsub {//.*$} $line {} line
        set line [string trim $line]
        if {$line eq ""} {
            continue
        }
        if {![regexp {^[0-9a-fA-F]+$} $line]} {
            fail "$label has non-hex text at $path:$line_number: '$line'"
        }
        set value [expr 0x$line]
        if {$value < 0 || $value > $maximum} {
            fail "$label value exceeds $width bits at $path:$line_number: '$line'"
        }
        lappend values $value
    }
    if {[llength $values] == 0} {
        fail "$label file is empty: $path"
    }
    return $values
}

proc load_case_data {case_name} {
    global CASE_CONTEXT GOLDEN_ROOT HEAD_DIM HEADS RESULT_COUNT

    if {![dict exists $CASE_CONTEXT $case_name]} {
        fail "unsupported case '$case_name'; choose [dict keys $CASE_CONTEXT]"
    }
    set context [dict get $CASE_CONTEXT $case_name]
    set case_root [file join $GOLDEN_ROOT $case_name]
    if {![file isdirectory $case_root]} {
        fail "golden case directory is absent: $case_root"
    }

    set v_codes [read_hex_values \
        [file join $case_root v_codes_s5.hex] 8 "V5 codes"]
    set scales [read_hex_values \
        [file join $case_root v_scales_u12.hex] 12 "V scales"]
    set exponents [read_hex_values \
        [file join $case_root exp_h4_u16.hex] 16 "exponents"]
    set expected [read_hex_values \
        [file join $case_root expected_numerators_s48.hex] 48 \
        "expected numerators"]

    if {[llength $v_codes] != $context * $HEAD_DIM} {
        fail "$case_name V5 count=[llength $v_codes] expected=[expr {$context * $HEAD_DIM}]"
    }
    if {[llength $scales] != $context} {
        fail "$case_name scale count=[llength $scales] expected=$context"
    }
    if {[llength $exponents] != $context * $HEADS} {
        fail "$case_name exponent count=[llength $exponents] expected=[expr {$context * $HEADS}]"
    }
    if {[llength $expected] != $RESULT_COUNT} {
        fail "$case_name numerator count=[llength $expected] expected=$RESULT_COUNT"
    }

    set code_index 0
    foreach raw_code $v_codes {
        set code5 [expr {$raw_code & 0x1f}]
        set canonical_byte [expr {$code5 >= 16 ? ($code5 | 0xe0) : $code5}]
        if {$raw_code != $canonical_byte} {
            fail "$case_name V5 code index=$code_index is not canonical sign-extended S5: [format 0x%02X $raw_code]"
        }
        if {$code5 == 0x10} {
            fail "$case_name V5 code index=$code_index uses reserved -16"
        }
        incr code_index
    }
    set scale_index 0
    foreach scale $scales {
        if {$scale == 0} {
            fail "$case_name scale index=$scale_index is zero"
        }
        incr scale_index
    }

    return [dict create name $case_name context $context \
        v_codes $v_codes scales $scales exponents $exponents \
        expected $expected]
}

proc pack_v_codes {v_codes} {
    set packed {}
    set bit_buffer 0
    set valid_bits 0
    foreach raw_code $v_codes {
        set bit_buffer [expr {$bit_buffer | (($raw_code & 0x1f) << $valid_bits)}]
        incr valid_bits 5
        while {$valid_bits >= 8} {
            lappend packed [expr {$bit_buffer & 0xff}]
            set bit_buffer [expr {$bit_buffer >> 8}]
            incr valid_bits -8
        }
    }
    if {$valid_bits != 0 || $bit_buffer != 0} {
        fail "V5 packing ended on a partial byte valid_bits=$valid_bits"
    }
    return $packed
}

proc packed_v_code {packed code_index} {
    set bit_index [expr {$code_index * 5}]
    set byte_index [expr {$bit_index / 8}]
    set shift [expr {$bit_index % 8}]
    set window [lindex $packed $byte_index]
    if {$byte_index + 1 < [llength $packed]} {
        set window [expr {$window | ([lindex $packed [expr {$byte_index + 1}]] << 8)}]
    }
    return [expr {($window >> $shift) & 0x1f}]
}

proc packed_bytes_to_words {packed} {
    if {[llength $packed] % 4 != 0} {
        fail "packed V5 byte count=[llength $packed] is not word aligned"
    }
    set words {}
    for {set byte_index 0} {$byte_index < [llength $packed]} \
        {incr byte_index 4} {
        set word [expr {
            [lindex $packed $byte_index] |
            ([lindex $packed [expr {$byte_index + 1}]] << 8) |
            ([lindex $packed [expr {$byte_index + 2}]] << 16) |
            ([lindex $packed [expr {$byte_index + 3}]] << 24)}]
        lappend words [expr {$word & 0xffffffff}]
    }
    return $words
}

proc vector_self_test {data} {
    global HEADS HEAD_DIM RESULT_COUNT V_STRIDE_BYTES

    set case_name [dict get $data name]
    set context [dict get $data context]
    set v_codes [dict get $data v_codes]
    set scales [dict get $data scales]
    set exponents [dict get $data exponents]
    set expected [dict get $data expected]
    set packed [pack_v_codes $v_codes]

    set expected_bytes [expr {$context * $V_STRIDE_BYTES}]
    if {[llength $packed] != $expected_bytes} {
        fail "$case_name packed bytes=[llength $packed] expected=$expected_bytes"
    }
    for {set code_index 0} {$code_index < [llength $v_codes]} \
        {incr code_index} {
        set got [packed_v_code $packed $code_index]
        set wanted [expr {[lindex $v_codes $code_index] & 0x1f}]
        if {$got != $wanted} {
            fail "$case_name packed V5 mismatch index=$code_index got=$got expected=$wanted"
        }
    }

    set result_index 0
    for {set head 0} {$head < $HEADS} {incr head} {
        for {set dim 0} {$dim < $HEAD_DIM} {incr dim} {
            set calculated 0
            for {set token 0} {$token < $context} {incr token} {
                set code [signed_bits \
                    [lindex $v_codes [expr {$token * $HEAD_DIM + $dim}]] 5]
                set weight [expr {
                    [lindex $scales $token] *
                    [lindex $exponents [expr {$token * $HEADS + $head}]]}]
                set calculated [expr {$calculated + $weight * $code}]
            }
            set wanted [signed_bits [lindex $expected $result_index] 48]
            if {$calculated != $wanted} {
                fail "$case_name numerator index=$result_index head=$head dim=$dim got=$calculated expected=$wanted"
            }
            incr result_index
        }
    }
    if {$result_index != $RESULT_COUNT} {
        fail "$case_name calculated result count=$result_index expected=$RESULT_COUNT"
    }

    set words [packed_bytes_to_words $packed]
    puts "V5_AV_DIAG_VECTOR_SELF_TEST_PASS case=$case_name context=$context v_bytes=[llength $packed] stride=$V_STRIDE_BYTES first_word=[hex32 [lindex $words 0]] numerators=$result_index"
    return [dict merge $data [dict create packed $packed words $words]]
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
    foreach key {kv_smoke_enabled av_diag_enabled av_diag_repo \
                 av_diag_component_sha256 av_m_axi_data_width} {
        if {![dict exists $::zybo_bringup_identity $key]} {
            fail "build identity is missing '$key'"
        }
    }

    set enabled [dict get $::zybo_bringup_identity av_diag_enabled]
    if {![string is boolean -strict $enabled] || ![expr {$enabled ? 1 : 0}]} {
        fail "build identity says the AV diagnostic is disabled: '$enabled'"
    }
    set kv_enabled [dict get $::zybo_bringup_identity kv_smoke_enabled]
    if {![string is boolean -strict $kv_enabled] ||
        ![expr {$kv_enabled ? 1 : 0}]} {
        fail "AV diagnostic identity requires the existing ABI-v2 KV peripheral"
    }
    set width [dict get $::zybo_bringup_identity av_m_axi_data_width]
    if {![string is integer -strict $width] || $width != $AXI_DATA_WIDTH} {
        fail "AV diagnostic identity width='$width' expected=$AXI_DATA_WIDTH"
    }
    set identity_repo_raw [dict get $::zybo_bringup_identity av_diag_repo]
    if {[string trim $identity_repo_raw] eq ""} {
        fail "AV diagnostic identity has an empty packaged-IP repo"
    }
    set identity_repo [file normalize $identity_repo_raw]
    set component_path [file join $identity_repo axi_v5_av_diag component.xml]
    if {![file isfile $component_path]} {
        fail "AV diagnostic packaged component is absent: $component_path"
    }
    set component_hash \
        [dict get $::zybo_bringup_identity av_diag_component_sha256]
    if {![regexp {^[0-9A-F]{64}$} $component_hash]} {
        fail "AV diagnostic component hash is not an uppercase SHA-256: '$component_hash'"
    }
    set actual_component_hash [sha256_file $component_path \
        "AV diagnostic component"]
    if {$actual_component_hash ne $component_hash} {
        fail "AV diagnostic component changed after build: got=$actual_component_hash expected=$component_hash"
    }

    set package_identity_path \
        [file join [file dirname $identity_repo] package_identity.txt]
    set package_identity [parse_key_value_file $package_identity_path \
        "AV diagnostic package identity"]
    set source_relpaths {
        rtl/axi_v5_av_diag.v
        rtl/kv_v03_raw_v5_av_engine.v
        rtl/kv_v03_raw_v5_axi_reader.v
        rtl/kv_v03_v5_weight_mul.v
        rtl/kv_v03_av_accumulator.v
    }
    set package_keys {
        flow vivado_version part clock_hz m_axi_data_width ip_vlnv repo_root
    }
    foreach relative_path $source_relpaths {
        lappend package_keys "source.$relative_path.sha256"
    }
    require_dict_keys $package_identity $package_keys \
        "AV diagnostic package identity"
    foreach {key expected} {
        flow axi_v5_av_diag_portable_package
        vivado_version 2025.1
        part xc7z020clg400-1
        clock_hz 76923080
        m_axi_data_width 64
        ip_vlnv shepherdscientific.com:user:axi_v5_av_diag:1.0
    } {
        if {[dict get $package_identity $key] ne $expected} {
            fail "AV diagnostic package identity '$key'='[dict get $package_identity $key]' expected='$expected'"
        }
    }
    if {![paths_equal [dict get $package_identity repo_root] $REPO_ROOT]} {
        fail "AV diagnostic package source repo='[dict get $package_identity repo_root]' expected='[file normalize $REPO_ROOT]'"
    }
    foreach relative_path $source_relpaths {
        set source_path [file join $REPO_ROOT $relative_path]
        set expected_hash [string toupper \
            [dict get $package_identity "source.$relative_path.sha256"]]
        set actual_hash [sha256_file $source_path \
            "AV diagnostic source $relative_path"]
        if {$actual_hash ne $expected_hash} {
            fail "AV diagnostic source hash mismatch for $relative_path: got=$actual_hash expected=$expected_hash"
        }
    }
    return [dict create component_hash $component_hash \
        component_path $component_path package_repo $identity_repo \
        package_identity_path $package_identity_path]
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
        av_diag_enabled av_diag_repo av_diag_component_sha256
        av_m_axi_data_width evidence_sha256
    } "build result"
    foreach {key expected} {
        schema_version 2
        part xc7z020clg400-1
        board_part digilentinc.com:zybo-z7-20:part0:1.2
        pl_clock_hz 76923080
        kv_smoke_enabled 1
        av_diag_enabled 1
        av_m_axi_data_width 64
    } {
        if {[dict get $result $key] ne $expected} {
            fail "build result '$key'='[dict get $result $key]' expected='$expected'"
        }
    }
    if {![paths_equal [dict get $result av_diag_repo] \
        [dict get $identity_info package_repo]]} {
        fail "build result AV package repo differs from the verified package repo"
    }
    if {[dict get $result av_diag_component_sha256] ne \
        [dict get $identity_info component_hash]} {
        fail "build result AV component hash differs from the platform identity"
    }

    set evidence_hashes [dict get $result evidence_sha256]
    set required_relative [list \
        "artifacts/[file tail $bit_path]" \
        "artifacts/[file tail $xsa_path]" \
        "artifacts/ps7_init.tcl" \
        "identity/manifest.tcl"]
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
        set actual_hash [sha256_file [file join $build_root $relative_path] \
            "build evidence $relative_path"]
        if {$actual_hash ne $expected_hash} {
            fail "build evidence hash mismatch for '$relative_path': got=$actual_hash expected=$expected_hash"
        }
        lappend checksum_lines "$expected_hash  $relative_path"
    }
    set expected_checksums "[join $checksum_lines "\n"]\n"
    if {[read_text_file $checksums_path "artifact checksums"] ne \
        $expected_checksums} {
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
    if {![regexp -line {^  "schema": "zybo-vivado-launch-result-v2",$} \
        $run_json] ||
        ![regexp -line {^  "result": "PASS",$} $run_json]} {
        fail "wrapper run identity is not a schema-v2 PASS: $run_identity_path"
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
    puts "V5_AV_DIAG_LOAD_PASS label={$label} base=[hex32 $address] words=$count bytes=[expr {$count * 4}]"
}

proc make_exp_words {data} {
    set exponents [dict get $data exponents]
    set words {}
    for {set index 0} {$index < [llength $exponents]} {incr index 2} {
        lappend words [expr {
            [lindex $exponents $index] |
            ([lindex $exponents [expr {$index + 1}]] << 16)}]
    }
    return $words
}

proc make_scale_words {data} {
    set scales [dict get $data scales]
    set words {}
    for {set index 0} {$index < [llength $scales]} {incr index 2} {
        set high 0
        if {$index + 1 < [llength $scales]} {
            set high [lindex $scales [expr {$index + 1}]]
        }
        lappend words [expr {
            [lindex $scales $index] | (($high & 0xfff) << 16)}]
    }
    return $words
}

proc check_results_hidden {label} {
    global AV_BASE RESULT_BASE RESULT_COUNT
    set words [read_words_chunked \
        [expr {$AV_BASE + $RESULT_BASE}] [expr {$RESULT_COUNT * 2}]]
    set index 0
    foreach word $words {
        if {$word != 0} {
            fail "$label exposed stale result word=$index value=[hex32 $word]"
        }
        incr index
    }
    puts "V5_AV_DIAG_RESULTS_HIDDEN_PASS label={$label} words=$index"
}

proc program_case {data} {
    global AV_BASE V_DDR_BASE REG_CTRL REG_STATUS REG_V_BASE_LO
    global REG_V_BASE_HI REG_CONTEXT REG_EXP_COUNT REG_SCALE_COUNT
    global REG_ERROR EXP_BASE SCALE_BASE

    set context [dict get $data context]
    set exp_words [make_exp_words $data]
    set scale_words [make_scale_words $data]

    write32 [expr {$AV_BASE + $REG_CTRL}] 0x2
    require_numeric_equal "cleared status" \
        [read32 [expr {$AV_BASE + $REG_STATUS}]] 0
    require_numeric_equal "cleared error" \
        [read32 [expr {$AV_BASE + $REG_ERROR}]] 0

    write32 [expr {$AV_BASE + $REG_V_BASE_LO}] $V_DDR_BASE
    write32 [expr {$AV_BASE + $REG_V_BASE_HI}] 0
    write32 [expr {$AV_BASE + $REG_CONTEXT}] $context
    write_words_verified [expr {$AV_BASE + $EXP_BASE}] $exp_words \
        "AXI-Lite exponent window"
    write_words_verified [expr {$AV_BASE + $SCALE_BASE}] $scale_words \
        "AXI-Lite scale window"
    write32 [expr {$AV_BASE + $REG_EXP_COUNT}] $context
    write32 [expr {$AV_BASE + $REG_SCALE_COUNT}] $context

    require_numeric_equal "V base low" \
        [read32 [expr {$AV_BASE + $REG_V_BASE_LO}]] $V_DDR_BASE
    require_numeric_equal "V base high" \
        [read32 [expr {$AV_BASE + $REG_V_BASE_HI}]] 0
    require_numeric_equal "context" \
        [read32 [expr {$AV_BASE + $REG_CONTEXT}]] $context
    require_numeric_equal "exponent count" \
        [read32 [expr {$AV_BASE + $REG_EXP_COUNT}]] $context
    require_numeric_equal "scale count" \
        [read32 [expr {$AV_BASE + $REG_SCALE_COUNT}]] $context
    puts "V5_AV_DIAG_METADATA_PASS context=$context exp_words=[llength $exp_words] scale_words=[llength $scale_words]"
}

proc compare_results {data run_label} {
    global AV_BASE RESULT_BASE RESULT_COUNT
    set expected [dict get $data expected]
    set words [read_words_chunked \
        [expr {$AV_BASE + $RESULT_BASE}] [expr {$RESULT_COUNT * 2}]]

    for {set index 0} {$index < $RESULT_COUNT} {incr index} {
        set low [lindex $words [expr {$index * 2}]]
        set high [lindex $words [expr {$index * 2 + 1}]]
        set wanted_raw [expr {[lindex $expected $index] & 0xffffffffffff}]
        set wanted_low [expr {$wanted_raw & 0xffffffff}]
        set wanted_high16 [expr {($wanted_raw >> 32) & 0xffff}]
        set wanted_high [expr {$wanted_high16 |
            (($wanted_raw & (1 << 47)) ? 0xffff0000 : 0)}]
        if {$low != $wanted_low || $high != $wanted_high} {
            set got_raw [expr {(($high & 0xffff) << 32) | $low}]
            fail "$run_label numerator index=$index got=[hex48 $got_raw] ([signed_bits $got_raw 48]) expected=[hex48 $wanted_raw] ([signed_bits $wanted_raw 48]) high_word=[hex32 $high]"
        }
    }
    puts "V5_AV_DIAG_NUMERATORS_PASS run=$run_label count=$RESULT_COUNT signed_width=48"
}

proc run_once {data run_label} {
    global AV_BASE AXI_DATA_WIDTH V_STRIDE_BYTES EXPECTED_STATUS
    global REG_CTRL REG_STATUS REG_ERROR REG_PROGRESS REG_PERF
    global REG_READ_BEATS REG_AR_STALLS REG_R_STALLS

    set context [dict get $data context]
    write32 [expr {$AV_BASE + $REG_CTRL}] 0x1

    set polls 0
    set status 0
    while {$polls < 500} {
        set status [read32 [expr {$AV_BASE + $REG_STATUS}]]
        if {($status & 0x9) == 0 && ($status & 0x16) != 0} {
            break
        }
        incr polls
        after 10
    }
    if {$status != $EXPECTED_STATUS} {
        set error_word [read32 [expr {$AV_BASE + $REG_ERROR}]]
        fail "$run_label terminal status=[hex32 $status] expected=[hex32 $EXPECTED_STATUS] error=[hex32 $error_word] polls=$polls"
    }
    require_numeric_equal "$run_label error" \
        [read32 [expr {$AV_BASE + $REG_ERROR}]] 0

    set progress [read32 [expr {$AV_BASE + $REG_PROGRESS}]]
    if {$progress != $context - 1} {
        fail "$run_label progress=[hex32 $progress] expected final token=[expr {$context - 1}] with idle/head0/group0"
    }
    set expected_beats [expr {($context * $V_STRIDE_BYTES) / ($AXI_DATA_WIDTH / 8)}]
    set read_beats [read32 [expr {$AV_BASE + $REG_READ_BEATS}]]
    if {$read_beats != $expected_beats} {
        fail "$run_label read beats=$read_beats expected=$expected_beats"
    }
    set perf [read32 [expr {$AV_BASE + $REG_PERF}]]
    if {$perf == 0 || $perf < $read_beats} {
        fail "$run_label invalid perf cycles=$perf read_beats=$read_beats"
    }
    set ar_stalls [read32 [expr {$AV_BASE + $REG_AR_STALLS}]]
    set r_stalls [read32 [expr {$AV_BASE + $REG_R_STALLS}]]
    compare_results $data $run_label
    puts "V5_AV_DIAG_RUN_PASS run=$run_label context=$context status=[hex32 $status] perf_cycles=$perf read_beats=$read_beats ar_stalls=$ar_stalls r_stalls=$r_stalls"
    return [dict create perf_cycles $perf read_beats $read_beats \
        ar_stalls $ar_stalls r_stalls $r_stalls]
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

proc run_board_smoke {build_root evidence_root data} {
    global AV_BASE KV_BASE BRAM_BASE V_DDR_BASE AXI_DATA_WIDTH
    global EXPECTED_KV_ID EXPECTED_AV_ID EXPECTED_GEOMETRY
    global EXPECTED_CAPS EXPECTED_SCALE_FMT V_STRIDE_BYTES
    global REG_ID REG_GEOMETRY REG_V_STRIDE REG_CAPS REG_SCALE_FMT
    global REG_CTRL

    set build_root [file normalize $build_root]
    if {![file isdirectory $build_root]} {
        fail "platform output directory does not exist: $build_root"
    }
    set complete_path [file join $build_root .build_complete]
    if {![file isfile $complete_path]} {
        fail "platform build is not complete: $complete_path"
    }
    # Treat generated Tcl as data only after the external wrapper has anchored
    # every executable artifact hash.  Neither manifest is sourced before this
    # preflight succeeds.
    set artifacts [locate_build_artifacts $build_root]
    set wrapper_identity [require_wrapper_pass $evidence_root $build_root \
        $artifacts]
    set identity_info [require_build_identity $build_root]
    set artifacts [require_build_artifacts $build_root $identity_info \
        $artifacts]
    set component_hash [dict get $identity_info component_hash]
    set bit_path [dict get $artifacts bit_path]
    set xsa_path [dict get $artifacts xsa_path]
    set ps7_init_path [dict get $artifacts ps7_init_path]

    puts "V5_AV_DIAG_ARTIFACT bit=$bit_path"
    puts "V5_AV_DIAG_ARTIFACT xsa=$xsa_path"
    puts "V5_AV_DIAG_ARTIFACT ps7_init=$ps7_init_path"
    puts "V5_AV_DIAG_ARTIFACT wrapper_identity=$wrapper_identity"
    puts "V5_AV_DIAG_IDENTITY component_sha256=$component_hash internal_axi_width=$AXI_DATA_WIDTH"

    connect -url tcp:127.0.0.1:3121
    set board_targets [discover_unique_zybo_targets]
    set cable_serial [dict get $board_targets serial]
    puts "V5_AV_DIAG_TARGETS_PASS cable_serial=$cable_serial board={Digilent Zybo Z7} device=xc7z020"
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
    puts "V5_AV_DIAG_PS_INIT_PASS silicon_version=$silicon_version post_config=2_0 fpga0_clk_ctrl=[hex32 $fpga_clk_ctrl] fpga_rst_ctrl=[hex32 $fpga_rst_ctrl] level_shifter=[hex32 $level_shifter]"

    # Preserve the proven probe order: GP0 BRAM, existing ABI-v2 KV, then the
    # new diagnostic.  A failure therefore names the first broken boundary.
    set bram_probe [read32 $BRAM_BASE]
    puts "V5_AV_DIAG_BRAM_PROBE_PASS base=[hex32 $BRAM_BASE] value=[hex32 $bram_probe]"
    require_numeric_equal "existing ABI-v2 KV ID" \
        [read32 [expr {$KV_BASE + $REG_ID}]] $EXPECTED_KV_ID
    puts "V5_AV_DIAG_KV_PROBE_PASS base=[hex32 $KV_BASE] id=[hex32 $EXPECTED_KV_ID]"

    require_numeric_equal "AV diagnostic ID" \
        [read32 [expr {$AV_BASE + $REG_ID}]] $EXPECTED_AV_ID
    require_numeric_equal "AV diagnostic geometry" \
        [read32 [expr {$AV_BASE + $REG_GEOMETRY}]] $EXPECTED_GEOMETRY
    require_numeric_equal "AV diagnostic V stride" \
        [read32 [expr {$AV_BASE + $REG_V_STRIDE}]] $V_STRIDE_BYTES
    require_numeric_equal "AV diagnostic capabilities" \
        [read32 [expr {$AV_BASE + $REG_CAPS}]] $EXPECTED_CAPS
    require_numeric_equal "AV diagnostic scale format" \
        [read32 [expr {$AV_BASE + $REG_SCALE_FMT}]] $EXPECTED_SCALE_FMT
    puts "V5_AV_DIAG_ABI_PASS base=[hex32 $AV_BASE] id=[hex32 $EXPECTED_AV_ID] geometry=[hex32 $EXPECTED_GEOMETRY] stride=$V_STRIDE_BYTES caps=[hex32 $EXPECTED_CAPS] scale_format=[hex32 $EXPECTED_SCALE_FMT]"

    set v_words [dict get $data words]
    write_words_verified $V_DDR_BASE $v_words "DDR dense raw V5"

    program_case $data
    check_results_hidden "before first start"
    set first [run_once $data "first"]

    # No FPGA reprogram or PS reset.  Clearing must hide the complete old bank,
    # then the same bitstream must produce and commit all 512 words again.
    write32 [expr {$AV_BASE + $REG_CTRL}] 0x2
    check_results_hidden "between same-bitstream runs"
    program_case $data
    set second [run_once $data "restart"]

    puts "V5_AV_DIAG_BOARD_SMOKE_PASS case=[dict get $data name] context=[dict get $data context] v_ddr_base=[hex32 $V_DDR_BASE] first_perf=[dict get $first perf_cycles] restart_perf=[dict get $second perf_cycles] read_beats=[dict get $second read_beats] results=512 same_bitstream_rerun=pass no_stale=pass"
}

set self_test_only 0
set build_root ""
set evidence_root ""
set case_name adversarial_c7
if {$argc == 1 && [lindex $argv 0] eq "--self-test"} {
    set self_test_only 1
} elseif {$argc == 2 && [lindex $argv 0] eq "--self-test"} {
    set self_test_only 1
    set case_name [lindex $argv 1]
} elseif {$argc == 2} {
    set build_root [lindex $argv 0]
    set evidence_root [lindex $argv 1]
} elseif {$argc == 3} {
    set build_root [lindex $argv 0]
    set evidence_root [lindex $argv 1]
    set case_name [lindex $argv 2]
} else {
    puts stderr "usage: xsdb ZyboZ7/run_v5_av_diag_board_smoke.tcl <build-root> <wrapper-evidence-root> ?adversarial_c7|real_c128_l00_kvh0?"
    puts stderr "       xsdb ZyboZ7/run_v5_av_diag_board_smoke.tcl --self-test ?adversarial_c7|real_c128_l00_kvh0?"
    exit 2
}

set run_rc [catch {
    set case_data [load_case_data $case_name]
    set case_data [vector_self_test $case_data]
    if {!$self_test_only} {
        run_board_smoke $build_root $evidence_root $case_data
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
