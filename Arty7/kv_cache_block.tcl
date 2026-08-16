# kv_cache_block.tcl -- attach the INT4 KV IP to DDR and MicroBlaze control.
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Sourced by create_bd_ddr.tcl after eth_dma_block.tcl.

# axi_smc currently has MicroBlaze I/D and CDMA masters. Add the KV read master.
set_property -dict [list CONFIG.NUM_SI {4} CONFIG.NUM_MI {1}] [get_bd_cells axi_smc]

# periph currently has UART, GPIO, weight BRAM, GEMM, CDMA, Ethernet and norm.
set_property CONFIG.NUM_MI {8} [get_bd_cells periph]
connect_bd_net $UICLK [get_bd_pins periph/M07_ACLK]
connect_bd_net [get_bd_pins rst_ui/peripheral_aresetn] \
    [get_bd_pins periph/M07_ARESETN]

create_bd_cell -type ip \
    -vlnv shepherdscientific.com:user:axi_kv_cache:1.0 axi_kv_cache_0
set_property -dict [list \
    CONFIG.HEAD_DIM {64} \
    CONFIG.KV_BITS {4} \
    CONFIG.P {16} \
    CONFIG.MAX_CONTEXT {4096} \
    CONFIG.M_AXI_DATA_WIDTH {128} \
] [get_bd_cells axi_kv_cache_0]

connect_bd_intf_net [get_bd_intf_pins periph/M07_AXI] \
    [get_bd_intf_pins axi_kv_cache_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_kv_cache_0/m_axi] \
    [get_bd_intf_pins axi_smc/S03_AXI]
connect_bd_net $UICLK [get_bd_pins axi_kv_cache_0/clk]
connect_bd_net [get_bd_pins rst_ui/peripheral_aresetn] \
    [get_bd_pins axi_kv_cache_0/rst_n]

puts "kv_cache_block: AXI-Lite control on periph M07, 128-bit DDR reads on axi_smc S03"
