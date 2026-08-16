# package_axi_kv_cache.tcl
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Vivado IP packaging for the portable INT4 KV-cache Q.K accelerator.
# Compatible target flow: Vivado 2025.2 or later.
#   vivado -mode batch -source ip/package_axi_kv_cache.tcl

set ip_name    "axi_kv_cache"
set ip_vendor  "shepherdscientific.com"
set ip_library "user"
set ip_version "1.1"
set ip_display "INT4 KV-cache QK Engine"
set ip_desc    "Read-only AXI INT4 K cache with INT8 Q, registered group-scale QK reduction, and AXI-Lite control/logit RAM."

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

create_project -force ${ip_name}_pkg ${ip_name}_pkg -part xc7a100tcsg324-1

foreach rtl_file {
    kv_addr_gen.v
    int4_unpack.v
    kv_dequant.v
    qk_dot.v
    qk_group_dot.v
    kv_reader.v
    kv_cache_engine.v
    axi_kv_cache.v
} {
    add_files -norecurse [file join $repo_root rtl $rtl_file]
}
set_property top axi_kv_cache [current_fileset]

ipx::package_project -root_dir [file join $repo_root ip $ip_name] \
    -vendor $ip_vendor -library $ip_library -taxonomy /UserIP -import_files

set core [ipx::current_core]
set_property name                $ip_name $core
set_property version             $ip_version $core
set_property display_name        $ip_display $core
set_property description         $ip_desc $core
set_property vendor_display_name "Shepherd Scientific" $core
set_property company_url         "https://github.com/Ternarycore/ternarycore" $core
set_property supported_families  {artix7 Production} $core

# Both buses are synchronous to the single MIG UI clock in the Arty design.
# Repeated association appends both names to the clock's ASSOCIATED_BUSIF bus
# parameter. Vivado 2026.1 infers ACTIVE_LOW from rst_n; setting POLARITY on
# the HDL port is rejected by the newer IP-XACT API.
ipx::associate_bus_interfaces -busif s_axi -clock clk $core
ipx::associate_bus_interfaces -busif m_axi -clock clk $core

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity -quiet $core
ipx::save_core $core
close_project
puts "Packaged: $ip_name"
