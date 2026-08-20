// tb_kv_v03_kv_page_prefetch.v -- atomic K/V ping-pong prefetch regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_BITS_VAL
`define SCALE_BITS_VAL 12
`endif

module tb_kv_v03_kv_page_prefetch #(
    parameter integer SCALE_BITS = `SCALE_BITS_VAL
);
    localparam integer ADDR_WIDTH = 32;
    localparam integer ID_WIDTH = 1;
    localparam integer WATCHDOG = 20000;
    localparam integer PROFILE_ID = 16'h0023;
    localparam integer K_CODEBOOK_ID = 8'h11;
    localparam integer V_CODEBOOK_ID = 8'h22;

    localparam [31:0] P0_K_DATA  = 32'h0000_1000;
    localparam [31:0] P0_K_SCALE = 32'h0000_4000;
    localparam [31:0] P0_V_DATA  = 32'h0000_5000;
    localparam [31:0] P0_V_SCALE = 32'h0000_8000;
    localparam [31:0] P1_K_DATA  = 32'h0000_9000;
    localparam [31:0] P1_K_SCALE = 32'h0000_a000;
    localparam [31:0] P1_V_DATA  = 32'h0000_b000;
    localparam [31:0] P1_V_SCALE = 32'h0000_c000;

    localparam [1:0] SOURCE_PAIR = 2'd0;
    localparam [1:0] SOURCE_READER = 2'd2;
    localparam [1:0] SOURCE_VALIDATOR = 2'd3;
    localparam [7:0] ERR_IDENTITY = 8'he0;
    localparam [7:0] ERR_EXTERNAL_ABORT = 8'he2;
    localparam [7:0] ERR_V_CODEBOOK = 8'he5;
    localparam [7:0] ERR_RRESP = 8'h13;
    localparam [7:0] ERR_HEADER_CRC = 8'h27;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg cmd_valid = 0;
    wire cmd_ready;
    reg [7:0] cmd_request_id = 0;
    reg [15:0] cmd_layer = 0;
    reg [15:0] cmd_kv_head = 0;
    reg [15:0] cmd_profile_id = PROFILE_ID;
    reg [7:0] cmd_k_codebook_id = K_CODEBOOK_ID;
    reg [7:0] cmd_v_codebook_id = V_CODEBOOK_ID;
    reg [4:0] cmd_page_index = 0;
    reg [5:0] cmd_page_count = 0;
    reg [12:0] cmd_token_base = 0;
    reg [7:0] cmd_token_count = 0;
    reg [14:0] cmd_expected_symbols = 0;
    reg [31:0] cmd_k_data_addr = 0;
    reg [31:0] cmd_k_data_limit = 0;
    reg [31:0] cmd_k_page_window_bytes = 0;
    reg [31:0] cmd_k_scale_addr = 0;
    reg [8:0] cmd_k_scale_slice_bytes = 0;
    reg [31:0] cmd_v_data_addr = 0;
    reg [31:0] cmd_v_data_limit = 0;
    reg [31:0] cmd_v_page_window_bytes = 0;
    reg [31:0] cmd_v_scale_addr = 0;
    reg [8:0] cmd_v_scale_slice_bytes = 0;

    reg abort = 0;
    reg clear_fault = 0;
    wire clear_ready;
    reg clear_counters = 0;
    wire page_valid;
    reg page_ready = 0;
    wire page_active;
    reg page_release = 0;
    wire [7:0] page_request_id;
    wire [15:0] page_layer;
    wire [15:0] page_kv_head;
    wire [15:0] page_profile_id;
    wire [7:0] page_k_codebook_id;
    wire [7:0] page_v_codebook_id;
    wire [4:0] page_index;
    wire [5:0] page_count;
    wire [12:0] page_token_base;
    wire [7:0] page_token_count;
    wire [14:0] page_expected_symbols;
    wire page_k_raw_mode, page_v_raw_mode;
    wire [15:0] page_k_payload_bytes, page_v_payload_bytes;
    wire [7:0] page_k_scale_format_id, page_v_scale_format_id;
    wire [13:0] page_k_record_bytes, page_v_record_bytes;
    wire [13:0] page_k_window_bytes, page_v_window_bytes;
    wire [8:0] page_k_scale_slice_bytes, page_v_scale_slice_bytes;
    wire [13:0] page_k_padding_bytes, page_v_padding_bytes;

    reg k_data_rd_en = 0;
    reg [11:0] k_data_rd_word_addr = 0;
    wire k_data_rd_valid;
    wire [31:0] k_data_rd_data;
    wire [3:0] k_data_rd_byte_valid;
    wire k_data_rd_last;
    wire [13:0] k_data_rd_byte_offset;
    reg k_scale_rd_en = 0;
    reg [6:0] k_scale_rd_word_addr = 0;
    wire k_scale_rd_valid;
    wire [31:0] k_scale_rd_data;
    wire [3:0] k_scale_rd_byte_valid;
    wire k_scale_rd_last;
    wire [8:0] k_scale_rd_byte_offset;

    reg v_data_rd_en = 0;
    reg [11:0] v_data_rd_word_addr = 0;
    wire v_data_rd_valid;
    wire [31:0] v_data_rd_data;
    wire [3:0] v_data_rd_byte_valid;
    wire v_data_rd_last;
    wire [13:0] v_data_rd_byte_offset;
    reg v_scale_rd_en = 0;
    reg [6:0] v_scale_rd_word_addr = 0;
    wire v_scale_rd_valid;
    wire [31:0] v_scale_rd_data;
    wire [3:0] v_scale_rd_byte_valid;
    wire v_scale_rd_last;
    wire [8:0] v_scale_rd_byte_offset;

    reg consumer_need = 0;
    wire busy, flushing, sticky_error;
    wire [1:0] sticky_error_source;
    wire [7:0] sticky_error_code;
    wire sticky_error_phase_is_scale;
    wire sticky_fault_stream_is_v;
    wire [7:0] sticky_request_id;
    wire [15:0] sticky_layer, sticky_kv_head, sticky_profile_id;
    wire [7:0] sticky_codebook_id;
    wire [4:0] sticky_page_index;
    wire row_abort, reload_required;
    wire [31:0] pair_commands, pairs_published, pairs_released;
    wire [31:0] pair_aborted_rows, pair_starvation_cycles;
    wire [1:0] pair_fifo_high_water;
    wire [31:0] k_prefetch_commands, v_prefetch_commands;
    wire [31:0] k_pages_published, v_pages_published;
    wire [31:0] k_pages_released, v_pages_released;
    wire [31:0] k_raw_fallback_pages, v_raw_fallback_pages;
    wire [31:0] k_integrity_faults, v_integrity_faults;
    wire [31:0] k_transport_faults, v_transport_faults;

    wire [ID_WIDTH-1:0] axi_arid [0:3];
    wire [ADDR_WIDTH-1:0] axi_araddr [0:3];
    wire [7:0] axi_arlen [0:3];
    wire [2:0] axi_arsize [0:3];
    wire [1:0] axi_arburst [0:3];
    wire axi_arlock [0:3];
    wire [3:0] axi_arcache [0:3];
    wire [2:0] axi_arprot [0:3];
    wire [3:0] axi_arqos [0:3];
    wire axi_arvalid [0:3];
    wire axi_arready [0:3];
    wire [ID_WIDTH-1:0] axi_rid [0:3];
    wire [63:0] axi_rdata [0:3];
    wire [1:0] axi_rresp [0:3];
    wire axi_rlast [0:3];
    wire axi_rvalid [0:3];
    wire axi_rready [0:3];
    wire [31:0] mem_addr [0:3];
    reg [63:0] mem_data [0:3];
    wire [31:0] model_errors [0:3];
    reg allow_ar [0:3];
    reg [1:0] inject_rresp [0:3];
    reg [7:0] response_delay [0:3];

    reg [7:0] memory [0:131071];
    integer errors = 0;
    integer timeout;
    integer i;
    integer before_k_commands, before_v_commands;
    integer row_abort_pulses = 0;
    integer saw_k_completion_skew = 0;
    reg [31:0] crc_work;

    kv_v03_kv_page_prefetch #(
        .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH),
        .SCALE_BITS(SCALE_BITS), .COMPILED_PROFILE_ID(PROFILE_ID),
        .COMPILED_K_CODEBOOK_ID(K_CODEBOOK_ID),
        .COMPILED_V_CODEBOOK_ID(V_CODEBOOK_ID),
        .TIMEOUT_CYCLES(128)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_request_id(cmd_request_id), .cmd_layer(cmd_layer),
        .cmd_kv_head(cmd_kv_head), .cmd_profile_id(cmd_profile_id),
        .cmd_k_codebook_id(cmd_k_codebook_id),
        .cmd_v_codebook_id(cmd_v_codebook_id),
        .cmd_page_index(cmd_page_index), .cmd_page_count(cmd_page_count),
        .cmd_token_base(cmd_token_base), .cmd_token_count(cmd_token_count),
        .cmd_expected_symbols(cmd_expected_symbols),
        .cmd_k_data_addr(cmd_k_data_addr),
        .cmd_k_data_limit(cmd_k_data_limit),
        .cmd_k_page_window_bytes(cmd_k_page_window_bytes),
        .cmd_k_scale_addr(cmd_k_scale_addr),
        .cmd_k_scale_slice_bytes(cmd_k_scale_slice_bytes),
        .cmd_v_data_addr(cmd_v_data_addr),
        .cmd_v_data_limit(cmd_v_data_limit),
        .cmd_v_page_window_bytes(cmd_v_page_window_bytes),
        .cmd_v_scale_addr(cmd_v_scale_addr),
        .cmd_v_scale_slice_bytes(cmd_v_scale_slice_bytes),
        .abort(abort), .clear_fault(clear_fault),
        .clear_ready(clear_ready), .clear_counters(clear_counters),
        .page_valid(page_valid), .page_ready(page_ready),
        .page_active(page_active), .page_release(page_release),
        .page_request_id(page_request_id), .page_layer(page_layer),
        .page_kv_head(page_kv_head), .page_profile_id(page_profile_id),
        .page_k_codebook_id(page_k_codebook_id),
        .page_v_codebook_id(page_v_codebook_id),
        .page_index(page_index), .page_count(page_count),
        .page_token_base(page_token_base),
        .page_token_count(page_token_count),
        .page_expected_symbols(page_expected_symbols),
        .page_k_raw_mode(page_k_raw_mode),
        .page_v_raw_mode(page_v_raw_mode),
        .page_k_payload_bytes(page_k_payload_bytes),
        .page_v_payload_bytes(page_v_payload_bytes),
        .page_k_scale_format_id(page_k_scale_format_id),
        .page_v_scale_format_id(page_v_scale_format_id),
        .page_k_record_bytes(page_k_record_bytes),
        .page_v_record_bytes(page_v_record_bytes),
        .page_k_window_bytes(page_k_window_bytes),
        .page_v_window_bytes(page_v_window_bytes),
        .page_k_scale_slice_bytes(page_k_scale_slice_bytes),
        .page_v_scale_slice_bytes(page_v_scale_slice_bytes),
        .page_k_padding_bytes(page_k_padding_bytes),
        .page_v_padding_bytes(page_v_padding_bytes),
        .k_data_rd_en(k_data_rd_en),
        .k_data_rd_word_addr(k_data_rd_word_addr),
        .k_data_rd_valid(k_data_rd_valid), .k_data_rd_data(k_data_rd_data),
        .k_data_rd_byte_valid(k_data_rd_byte_valid),
        .k_data_rd_last(k_data_rd_last),
        .k_data_rd_byte_offset(k_data_rd_byte_offset),
        .k_scale_rd_en(k_scale_rd_en),
        .k_scale_rd_word_addr(k_scale_rd_word_addr),
        .k_scale_rd_valid(k_scale_rd_valid),
        .k_scale_rd_data(k_scale_rd_data),
        .k_scale_rd_byte_valid(k_scale_rd_byte_valid),
        .k_scale_rd_last(k_scale_rd_last),
        .k_scale_rd_byte_offset(k_scale_rd_byte_offset),
        .v_data_rd_en(v_data_rd_en),
        .v_data_rd_word_addr(v_data_rd_word_addr),
        .v_data_rd_valid(v_data_rd_valid), .v_data_rd_data(v_data_rd_data),
        .v_data_rd_byte_valid(v_data_rd_byte_valid),
        .v_data_rd_last(v_data_rd_last),
        .v_data_rd_byte_offset(v_data_rd_byte_offset),
        .v_scale_rd_en(v_scale_rd_en),
        .v_scale_rd_word_addr(v_scale_rd_word_addr),
        .v_scale_rd_valid(v_scale_rd_valid),
        .v_scale_rd_data(v_scale_rd_data),
        .v_scale_rd_byte_valid(v_scale_rd_byte_valid),
        .v_scale_rd_last(v_scale_rd_last),
        .v_scale_rd_byte_offset(v_scale_rd_byte_offset),
        .consumer_need(consumer_need), .busy(busy), .flushing(flushing),
        .sticky_error(sticky_error),
        .sticky_error_source(sticky_error_source),
        .sticky_error_code(sticky_error_code),
        .sticky_error_phase_is_scale(sticky_error_phase_is_scale),
        .sticky_fault_stream_is_v(sticky_fault_stream_is_v),
        .sticky_request_id(sticky_request_id),
        .sticky_layer(sticky_layer), .sticky_kv_head(sticky_kv_head),
        .sticky_profile_id(sticky_profile_id),
        .sticky_codebook_id(sticky_codebook_id),
        .sticky_page_index(sticky_page_index),
        .row_abort(row_abort), .reload_required(reload_required),
        .pair_commands(pair_commands), .pairs_published(pairs_published),
        .pairs_released(pairs_released),
        .pair_aborted_rows(pair_aborted_rows),
        .pair_starvation_cycles(pair_starvation_cycles),
        .pair_fifo_high_water(pair_fifo_high_water),
        .k_prefetch_commands(k_prefetch_commands),
        .k_pages_published(k_pages_published),
        .k_pages_released(k_pages_released),
        .k_raw_fallback_pages(k_raw_fallback_pages),
        .k_integrity_faults(k_integrity_faults),
        .k_transport_faults(k_transport_faults),
        .v_prefetch_commands(v_prefetch_commands),
        .v_pages_published(v_pages_published),
        .v_pages_released(v_pages_released),
        .v_raw_fallback_pages(v_raw_fallback_pages),
        .v_integrity_faults(v_integrity_faults),
        .v_transport_faults(v_transport_faults),
        .k0_axi_arid(axi_arid[0]), .k0_axi_araddr(axi_araddr[0]),
        .k0_axi_arlen(axi_arlen[0]), .k0_axi_arsize(axi_arsize[0]),
        .k0_axi_arburst(axi_arburst[0]), .k0_axi_arlock(axi_arlock[0]),
        .k0_axi_arcache(axi_arcache[0]), .k0_axi_arprot(axi_arprot[0]),
        .k0_axi_arqos(axi_arqos[0]), .k0_axi_arvalid(axi_arvalid[0]),
        .k0_axi_arready(axi_arready[0]), .k0_axi_rid(axi_rid[0]),
        .k0_axi_rdata(axi_rdata[0]), .k0_axi_rresp(axi_rresp[0]),
        .k0_axi_rlast(axi_rlast[0]), .k0_axi_rvalid(axi_rvalid[0]),
        .k0_axi_rready(axi_rready[0]),
        .k1_axi_arid(axi_arid[1]), .k1_axi_araddr(axi_araddr[1]),
        .k1_axi_arlen(axi_arlen[1]), .k1_axi_arsize(axi_arsize[1]),
        .k1_axi_arburst(axi_arburst[1]), .k1_axi_arlock(axi_arlock[1]),
        .k1_axi_arcache(axi_arcache[1]), .k1_axi_arprot(axi_arprot[1]),
        .k1_axi_arqos(axi_arqos[1]), .k1_axi_arvalid(axi_arvalid[1]),
        .k1_axi_arready(axi_arready[1]), .k1_axi_rid(axi_rid[1]),
        .k1_axi_rdata(axi_rdata[1]), .k1_axi_rresp(axi_rresp[1]),
        .k1_axi_rlast(axi_rlast[1]), .k1_axi_rvalid(axi_rvalid[1]),
        .k1_axi_rready(axi_rready[1]),
        .v0_axi_arid(axi_arid[2]), .v0_axi_araddr(axi_araddr[2]),
        .v0_axi_arlen(axi_arlen[2]), .v0_axi_arsize(axi_arsize[2]),
        .v0_axi_arburst(axi_arburst[2]), .v0_axi_arlock(axi_arlock[2]),
        .v0_axi_arcache(axi_arcache[2]), .v0_axi_arprot(axi_arprot[2]),
        .v0_axi_arqos(axi_arqos[2]), .v0_axi_arvalid(axi_arvalid[2]),
        .v0_axi_arready(axi_arready[2]), .v0_axi_rid(axi_rid[2]),
        .v0_axi_rdata(axi_rdata[2]), .v0_axi_rresp(axi_rresp[2]),
        .v0_axi_rlast(axi_rlast[2]), .v0_axi_rvalid(axi_rvalid[2]),
        .v0_axi_rready(axi_rready[2]),
        .v1_axi_arid(axi_arid[3]), .v1_axi_araddr(axi_araddr[3]),
        .v1_axi_arlen(axi_arlen[3]), .v1_axi_arsize(axi_arsize[3]),
        .v1_axi_arburst(axi_arburst[3]), .v1_axi_arlock(axi_arlock[3]),
        .v1_axi_arcache(axi_arcache[3]), .v1_axi_arprot(axi_arprot[3]),
        .v1_axi_arqos(axi_arqos[3]), .v1_axi_arvalid(axi_arvalid[3]),
        .v1_axi_arready(axi_arready[3]), .v1_axi_rid(axi_rid[3]),
        .v1_axi_rdata(axi_rdata[3]), .v1_axi_rresp(axi_rresp[3]),
        .v1_axi_rlast(axi_rlast[3]), .v1_axi_rvalid(axi_rvalid[3]),
        .v1_axi_rready(axi_rready[3])
    );

    genvar port_index;
    generate
        for (port_index = 0; port_index < 4; port_index = port_index + 1) begin: g_mem
            // Re-evaluate only when an AXI endpoint advances its address.
            // An @* expression would conservatively wake on every byte write
            // to the shared test memory and make RAW-page construction slow.
            always @(mem_addr[port_index])
                mem_data[port_index] = memory_word(mem_addr[port_index]);
            tb_kv_v03_hp64_memory_port #(.PORT_INDEX(port_index)) u_mem (
                .clk(clk), .rst_n(rst_n), .allow_ar(allow_ar[port_index]),
                .inject_rresp(inject_rresp[port_index]),
                .response_delay(response_delay[port_index]),
                .arid(axi_arid[port_index]),
                .araddr(axi_araddr[port_index]),
                .arlen(axi_arlen[port_index]),
                .arsize(axi_arsize[port_index]),
                .arburst(axi_arburst[port_index]),
                .arlock(axi_arlock[port_index]),
                .arcache(axi_arcache[port_index]),
                .arprot(axi_arprot[port_index]),
                .arqos(axi_arqos[port_index]),
                .arvalid(axi_arvalid[port_index]),
                .arready(axi_arready[port_index]),
                .rid(axi_rid[port_index]), .rdata(axi_rdata[port_index]),
                .rresp(axi_rresp[port_index]), .rlast(axi_rlast[port_index]),
                .rvalid(axi_rvalid[port_index]),
                .rready(axi_rready[port_index]),
                .mem_addr(mem_addr[port_index]),
                .mem_data(mem_data[port_index]),
                .protocol_errors(model_errors[port_index])
            );
        end
    endgenerate

    function [31:0] crc_byte;
        input [31:0] state_in;
        input [7:0] byte_in;
        reg [31:0] work;
        integer bit_index;
        begin
            work = state_in;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (work[0] ^ byte_in[bit_index])
                    work = (work >> 1) ^ 32'hedb8_8320;
                else
                    work = work >> 1;
            end
            crc_byte = work;
        end
    endfunction

    function [63:0] memory_word;
        input [31:0] address;
        integer lane;
        begin
            memory_word = 64'd0;
            for (lane = 0; lane < 8; lane = lane + 1)
                memory_word[(lane*8) +: 8] = memory[address + lane];
        end
    endfunction

    function [31:0] memory_word32;
        input [31:0] address;
        integer lane;
        begin
            memory_word32 = 32'd0;
            for (lane = 0; lane < 4; lane = lane + 1)
                memory_word32[(lane*8) +: 8] = memory[address + lane];
        end
    endfunction

    function integer image_payload_bytes;
        input is_v;
        input raw_mode;
        begin
            image_payload_bytes = raw_mode ? (is_v ? 10240 : 8192) : 1;
        end
    endfunction

    function integer image_window_bytes;
        input is_v;
        input raw_mode;
        integer record_bytes;
        begin
            record_bytes = image_payload_bytes(is_v, raw_mode) + 12;
            image_window_bytes = (record_bytes + 7) & ~7;
        end
    endfunction

    function integer image_scale_bytes;
        input raw_mode;
        begin
            image_scale_bytes = raw_mode ?
                                ((SCALE_BITS == 12) ? 192 : 256) : 2;
        end
    endfunction

    task build_image;
        input [31:0] data_base;
        input [31:0] scale_base;
        input is_v;
        input raw_mode;
        input integer seed;
        integer payload_bytes;
        integer window_bytes;
        integer scale_bytes;
        integer token_bytes;
        begin
            payload_bytes = image_payload_bytes(is_v, raw_mode);
            window_bytes = image_window_bytes(is_v, raw_mode);
            scale_bytes = image_scale_bytes(raw_mode);
            token_bytes = raw_mode ? 128 : 1;
            for (i = 0; i < window_bytes; i = i + 1)
                memory[data_base+i] = 0;
            for (i = 0; i < ((scale_bytes + 7) & ~7); i = i + 1)
                memory[scale_base+i] = 0;
            for (i = 0; i < scale_bytes; i = i + 1)
                memory[scale_base+i] = ((i * 29) + seed + 8'h31) & 8'hff;
            if (!raw_mode && SCALE_BITS == 12)
                memory[scale_base+1] = memory[scale_base+1] & 8'h0f;

            memory[data_base+0] = 8'h03;
            memory[data_base+1] = 8'hc3;
            memory[data_base+2] = {6'd0, is_v, raw_mode};
            memory[data_base+3] = token_bytes - 1;
            memory[data_base+4] = payload_bytes & 8'hff;
            memory[data_base+5] = (payload_bytes >> 8) & 8'hff;
            memory[data_base+6] = is_v ? V_CODEBOOK_ID : K_CODEBOOK_ID;
            memory[data_base+7] = (SCALE_BITS == 12) ? 8'd1 : 8'd2;
            for (i = 0; i < payload_bytes; i = i + 1)
                memory[data_base+12+i] = ((i * 13) + seed + 8'h57) & 8'hff;

            crc_work = 32'hffff_ffff;
            for (i = 0; i < 8; i = i + 1)
                crc_work = crc_byte(crc_work, memory[data_base+i]);
            for (i = 0; i < payload_bytes; i = i + 1)
                crc_work = crc_byte(crc_work, memory[data_base+12+i]);
            for (i = 0; i < scale_bytes; i = i + 1)
                crc_work = crc_byte(crc_work, memory[scale_base+i]);
            crc_work = crc_work ^ 32'hffff_ffff;
            memory[data_base+8] = crc_work[7:0];
            memory[data_base+9] = crc_work[15:8];
            memory[data_base+10] = crc_work[23:16];
            memory[data_base+11] = crc_work[31:24];
        end
    endtask

    task issue_pair;
        input [7:0] request_id;
        input [4:0] wanted_page;
        input [5:0] wanted_pages;
        input [12:0] wanted_base;
        input [7:0] wanted_tokens;
        input [31:0] k_data;
        input [31:0] k_scale;
        input [31:0] v_data;
        input [31:0] v_scale;
        input raw_mode;
        begin
            cmd_request_id = request_id;
            cmd_layer = 16'h0042;
            cmd_kv_head = 16'h0003;
            cmd_profile_id = PROFILE_ID;
            cmd_k_codebook_id = K_CODEBOOK_ID;
            cmd_v_codebook_id = V_CODEBOOK_ID;
            cmd_page_index = wanted_page;
            cmd_page_count = wanted_pages;
            cmd_token_base = wanted_base;
            cmd_token_count = wanted_tokens;
            cmd_expected_symbols = wanted_tokens * 128;
            cmd_k_data_addr = k_data;
            cmd_k_page_window_bytes = image_window_bytes(0, raw_mode);
            cmd_k_data_limit = k_data + cmd_k_page_window_bytes;
            cmd_k_scale_addr = k_scale;
            cmd_k_scale_slice_bytes = image_scale_bytes(raw_mode);
            cmd_v_data_addr = v_data;
            cmd_v_page_window_bytes = image_window_bytes(1, raw_mode);
            cmd_v_data_limit = v_data + cmd_v_page_window_bytes;
            cmd_v_scale_addr = v_scale;
            cmd_v_scale_slice_bytes = image_scale_bytes(raw_mode);
            timeout = 0;
            while (!cmd_ready && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!cmd_ready)
                $fatal(1, "pair command-ready timeout");
            cmd_valid = 1;
            @(negedge clk);
            cmd_valid = 0;
        end
    endtask

    task wait_pair_valid;
        input [7:0] wanted_request;
        input [4:0] wanted_page;
        input [5:0] wanted_pages;
        input [12:0] wanted_base;
        input [7:0] wanted_tokens;
        input wanted_raw;
        begin
            timeout = 0;
            while (!page_valid && timeout < WATCHDOG) begin
                @(negedge clk);
                if (dut.k_page_valid_i && !dut.v_page_valid_i) begin
                    saw_k_completion_skew = 1;
                    if (page_valid || page_active)
                        errors = errors + 1;
                end
                timeout = timeout + 1;
            end
            if (!page_valid)
                $fatal(1, "paired publication timeout request=%02x", wanted_request);
            if (page_request_id != wanted_request || page_layer != 16'h0042 ||
                page_kv_head != 16'h0003 || page_profile_id != PROFILE_ID ||
                page_k_codebook_id != K_CODEBOOK_ID ||
                page_v_codebook_id != V_CODEBOOK_ID ||
                page_index != wanted_page || page_count != wanted_pages ||
                page_token_base != wanted_base ||
                page_token_count != wanted_tokens ||
                page_expected_symbols != wanted_tokens*128 ||
                page_k_raw_mode != wanted_raw ||
                page_v_raw_mode != wanted_raw) begin
                $display("FAIL pair metadata request=%02x page=%0d", wanted_request,
                         wanted_page);
                errors = errors + 1;
            end
        end
    endtask

    task accept_pair;
        begin
            page_ready = 1;
            @(negedge clk);
            page_ready = 0;
            if (!page_active || page_valid) begin
                $display("FAIL pair publication was not atomic");
                errors = errors + 1;
            end
        end
    endtask

    task release_pair;
        begin
            page_release = 1;
            @(negedge clk);
            page_release = 0;
            if (page_active) begin
                $display("FAIL pair release was not atomic");
                errors = errors + 1;
            end
        end
    endtask

    task read_data_word;
        input is_v;
        input integer word_index;
        input [31:0] expected;
        input expected_last;
        begin
            @(negedge clk);
            if (is_v) begin
                v_data_rd_word_addr = word_index;
                v_data_rd_en = 1;
            end else begin
                k_data_rd_word_addr = word_index;
                k_data_rd_en = 1;
            end
            @(negedge clk);
            k_data_rd_en = 0;
            v_data_rd_en = 0;
            if (is_v) begin
                if (!v_data_rd_valid || v_data_rd_data !== expected ||
                    v_data_rd_byte_valid !== 4'hf ||
                    v_data_rd_last !== expected_last ||
                    v_data_rd_byte_offset !== word_index*4) begin
                    $display("FAIL V data scratch word=%0d", word_index);
                    errors = errors + 1;
                end
            end else begin
                if (!k_data_rd_valid || k_data_rd_data !== expected ||
                    k_data_rd_byte_valid !== 4'hf ||
                    k_data_rd_last !== expected_last ||
                    k_data_rd_byte_offset !== word_index*4) begin
                    $display("FAIL K data scratch word=%0d", word_index);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task read_scale_word;
        input is_v;
        input integer word_index;
        input [31:0] expected;
        input [3:0] expected_mask;
        input expected_last;
        begin
            @(negedge clk);
            if (is_v) begin
                v_scale_rd_word_addr = word_index;
                v_scale_rd_en = 1;
            end else begin
                k_scale_rd_word_addr = word_index;
                k_scale_rd_en = 1;
            end
            @(negedge clk);
            k_scale_rd_en = 0;
            v_scale_rd_en = 0;
            if (is_v) begin
                if (!v_scale_rd_valid || v_scale_rd_data !== expected ||
                    v_scale_rd_byte_valid !== expected_mask ||
                    v_scale_rd_last !== expected_last ||
                    v_scale_rd_byte_offset !== word_index*4) begin
                    $display("FAIL V scale scratch word=%0d", word_index);
                    errors = errors + 1;
                end
            end else begin
                if (!k_scale_rd_valid || k_scale_rd_data !== expected ||
                    k_scale_rd_byte_valid !== expected_mask ||
                    k_scale_rd_last !== expected_last ||
                    k_scale_rd_byte_offset !== word_index*4) begin
                    $display("FAIL K scale scratch word=%0d", word_index);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task verify_exact_image;
        input is_v;
        input [31:0] data_base;
        input [31:0] scale_base;
        input raw_mode;
        integer words;
        integer scale_words;
        begin
            words = image_window_bytes(is_v, raw_mode) / 4;
            scale_words = (image_scale_bytes(raw_mode) + 3) / 4;
            // The record validator has already CRC-checked every logical
            // data and scale byte before publication.  Exercise the public
            // synchronous scratch ports at first/middle/last boundaries and
            // verify their exact data, masks, offsets and last markers.
            read_data_word(is_v, 0, memory_word32(data_base), 0);
            read_data_word(is_v, words/2,
                           memory_word32(data_base+(words/2)*4), 0);
            read_data_word(is_v, words-1,
                           memory_word32(data_base+(words-1)*4), 1);
            read_scale_word(is_v, 0, memory_word32(scale_base),
                            (!raw_mode && scale_words == 1) ? 4'h3 : 4'hf,
                            scale_words == 1);
            if (scale_words > 1)
                read_scale_word(is_v, scale_words-1,
                    memory_word32(scale_base+(scale_words-1)*4), 4'hf, 1);
        end
    endtask

    task verify_stale_hidden;
        input is_v;
        begin
            @(negedge clk);
            if (is_v) begin
                v_data_rd_word_addr = 4;
                v_data_rd_en = 1;
                v_scale_rd_word_addr = 1;
                v_scale_rd_en = 1;
            end else begin
                k_data_rd_word_addr = 4;
                k_data_rd_en = 1;
                k_scale_rd_word_addr = 1;
                k_scale_rd_en = 1;
            end
            @(negedge clk);
            k_data_rd_en = 0;
            v_data_rd_en = 0;
            k_scale_rd_en = 0;
            v_scale_rd_en = 0;
            if (is_v ? (v_data_rd_valid || v_scale_rd_valid) :
                       (k_data_rd_valid || k_scale_rd_valid)) begin
                $display("FAIL stale %s scratch visible", is_v ? "V" : "K");
                errors = errors + 1;
            end
        end
    endtask

    task wait_fault;
        input [1:0] wanted_source;
        input [7:0] wanted_code;
        input wanted_stream;
        input wanted_phase;
        begin
            timeout = 0;
            while (!sticky_error && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!sticky_error)
                $fatal(1, "pair fault timeout code=%02x", wanted_code);
            if (!reload_required || sticky_error_source != wanted_source ||
                sticky_error_code != wanted_code ||
                sticky_fault_stream_is_v != wanted_stream ||
                sticky_error_phase_is_scale != wanted_phase ||
                page_valid || page_active || cmd_ready) begin
                $display("FAIL fault got src/code/stream/phase=%0d/%02x/%0d/%0d wanted=%0d/%02x/%0d/%0d",
                         sticky_error_source, sticky_error_code,
                         sticky_fault_stream_is_v,
                         sticky_error_phase_is_scale, wanted_source,
                         wanted_code, wanted_stream, wanted_phase);
                errors = errors + 1;
            end
            timeout = 0;
            while (!clear_ready && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!clear_ready || flushing || busy) begin
                $display("FAIL fault did not drain to clear boundary code=%02x timeout=%0d clear=%0d flush=%0d busy=%0d kbusy=%0d vbusy=%0d kflush=%0d vflush=%0d ksticky=%0d vsticky=%0d",
                         wanted_code, timeout, clear_ready, flushing, busy,
                         dut.k_busy_i, dut.v_busy_i, dut.k_flushing_i,
                         dut.v_flushing_i, dut.k_sticky_i, dut.v_sticky_i);
                errors = errors + 1;
            end
        end
    endtask

    task clear_and_restart;
        begin
            clear_fault = 1;
            @(negedge clk);
            clear_fault = 0;
            @(negedge clk);
            if (sticky_error || reload_required || !cmd_ready ||
                clear_ready || page_valid || page_active) begin
                $display("FAIL no-reset clear/restart boundary sticky=%0d reload=%0d cmdready=%0d clear=%0d pagev=%0d active=%0d kbusy=%0d vbusy=%0d kflush=%0d vflush=%0d ksticky=%0d vsticky=%0d",
                         sticky_error, reload_required, cmd_ready, clear_ready,
                         page_valid, page_active, dut.k_busy_i, dut.v_busy_i,
                         dut.k_flushing_i, dut.v_flushing_i,
                         dut.k_sticky_i, dut.v_sticky_i);
                errors = errors + 1;
            end
        end
    endtask

    always @(negedge clk) begin
        if (rst_n) begin
            if (row_abort)
                row_abort_pulses = row_abort_pulses + 1;
            if ((abort || sticky_error || flushing) &&
                (page_valid || page_active || k_data_rd_valid ||
                 k_scale_rd_valid || v_data_rd_valid || v_scale_rd_valid)) begin
                $display("FAIL fail-closed visibility gate");
                errors = errors + 1;
            end
        end
    end

    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            allow_ar[i] = 1;
            inject_rresp[i] = 0;
            response_delay[i] = 0;
        end
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        if (!cmd_ready || busy || sticky_error)
            $fatal(1, "pair did not reset command-ready");

        // Queue two rows.  The first is the exact maximum RAW K4/V5 image;
        // the second deliberately finishes early in the alternate slots.
        build_image(P0_K_DATA, P0_K_SCALE, 0, 1, 8'h01);
        build_image(P0_V_DATA, P0_V_SCALE, 1, 1, 8'h02);
        build_image(P1_K_DATA, P1_K_SCALE, 0, 0, 8'h03);
        build_image(P1_V_DATA, P1_V_SCALE, 1, 0, 8'h04);
        response_delay[2] = 8;
        consumer_need = 1;
        $display("PHASE raw_overlap scale=%0d", SCALE_BITS);
        issue_pair(8'ha0, 0, 2, 0, 128, P0_K_DATA, P0_K_SCALE,
                   P0_V_DATA, P0_V_SCALE, 1);
        issue_pair(8'ha1, 1, 2, 128, 1, P1_K_DATA, P1_K_SCALE,
                   P1_V_DATA, P1_V_SCALE, 0);
        if (cmd_ready) begin
            $display("FAIL full paired FIFO still accepted commands");
            errors = errors + 1;
        end
        wait_pair_valid(8'ha0, 0, 2, 0, 128, 1);
        if (!saw_k_completion_skew) begin
            $display("FAIL K/V completion-skew case was not exercised");
            errors = errors + 1;
        end
        if (page_k_payload_bytes != 8192 || page_v_payload_bytes != 10240 ||
            page_k_window_bytes != 8208 || page_v_window_bytes != 10256 ||
            page_k_scale_slice_bytes != image_scale_bytes(1) ||
            page_v_scale_slice_bytes != image_scale_bytes(1) ||
            page_k_scale_format_id != ((SCALE_BITS == 12) ? 1 : 2) ||
            page_v_scale_format_id != ((SCALE_BITS == 12) ? 1 : 2) ||
            page_k_padding_bytes != 4 || page_v_padding_bytes != 4) begin
            $display("FAIL RAW K/V published geometry scale_bits=%0d", SCALE_BITS);
            errors = errors + 1;
        end
        accept_pair();
        verify_exact_image(0, P0_K_DATA, P0_K_SCALE, 1);
        verify_exact_image(1, P0_V_DATA, P0_V_SCALE, 1);
        release_pair();

        wait_pair_valid(8'ha1, 1, 2, 128, 1, 0);
        accept_pair();
        verify_exact_image(0, P1_K_DATA, P1_K_SCALE, 0);
        verify_exact_image(1, P1_V_DATA, P1_V_SCALE, 0);
        verify_stale_hidden(0);
        verify_stale_hidden(1);
        release_pair();
        consumer_need = 0;
        response_delay[2] = 0;
        if (pair_commands != 2 || pairs_published != 2 ||
            pairs_released != 2 || pair_fifo_high_water != 2 ||
            pair_starvation_cycles == 0 ||
            k_prefetch_commands != 2 || v_prefetch_commands != 2 ||
            k_pages_published != 2 || v_pages_published != 2 ||
            k_pages_released != 2 || v_pages_released != 2 ||
            k_raw_fallback_pages != 1 || v_raw_fallback_pages != 1) begin
            $display("FAIL paired/separate counters cmd=%0d/%0d/%0d pub=%0d/%0d/%0d rel=%0d/%0d/%0d hi=%0d starve=%0d raw=%0d/%0d",
                     pair_commands, k_prefetch_commands, v_prefetch_commands,
                     pairs_published, k_pages_published, v_pages_published,
                     pairs_released, k_pages_released, v_pages_released,
                     pair_fifo_high_water, pair_starvation_cycles,
                     k_raw_fallback_pages, v_raw_fallback_pages);
            errors = errors + 1;
        end

        // Bad V codebook is accepted as one typed command fault, but neither
        // child sees a command: this is the no-partial-accept proof.
        $display("PHASE no_partial scale=%0d", SCALE_BITS);
        before_k_commands = k_prefetch_commands;
        before_v_commands = v_prefetch_commands;
        cmd_request_id = 8'hb0;
        cmd_page_index = 0;
        cmd_page_count = 1;
        cmd_token_base = 0;
        cmd_token_count = 1;
        cmd_expected_symbols = 128;
        cmd_profile_id = PROFILE_ID;
        cmd_k_codebook_id = K_CODEBOOK_ID;
        cmd_v_codebook_id = V_CODEBOOK_ID + 1;
        cmd_k_data_addr = P1_K_DATA;
        cmd_k_data_limit = P1_K_DATA + 16;
        cmd_k_page_window_bytes = 16;
        cmd_k_scale_addr = P1_K_SCALE;
        cmd_k_scale_slice_bytes = 2;
        cmd_v_data_addr = P1_V_DATA;
        cmd_v_data_limit = P1_V_DATA + 16;
        cmd_v_page_window_bytes = 16;
        cmd_v_scale_addr = P1_V_SCALE;
        cmd_v_scale_slice_bytes = 2;
        timeout = 0;
        while (!cmd_ready && timeout < 100) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!cmd_ready)
            $fatal(1, "bad-codebook command-ready timeout pairq=%0d kq=%0d vq=%0d kbusy=%0d vbusy=%0d ksticky=%0d vsticky=%0d kflush=%0d vflush=%0d",
                   dut.pair_queue_count, dut.u_k.queue_count,
                   dut.u_v.queue_count, dut.k_busy_i, dut.v_busy_i,
                   dut.k_sticky_i, dut.v_sticky_i,
                   dut.k_flushing_i, dut.v_flushing_i);
        cmd_valid = 1;
        @(negedge clk);
        cmd_valid = 0;
        wait_fault(SOURCE_PAIR, ERR_V_CODEBOOK, 1, 0);
        if (k_prefetch_commands != before_k_commands ||
            v_prefetch_commands != before_v_commands) begin
            $display("FAIL invalid typed command partially reached child");
            errors = errors + 1;
        end
        clear_and_restart();

        // K record CRC failure aborts the already valid/in-flight V peer.
        $display("PHASE k_crc scale=%0d", SCALE_BITS);
        build_image(P0_K_DATA, P0_K_SCALE, 0, 0, 8'h10);
        build_image(P0_V_DATA, P0_V_SCALE, 1, 0, 8'h11);
        memory[P0_K_DATA+12] = memory[P0_K_DATA+12] ^ 8'h01;
        issue_pair(8'hb1, 0, 1, 0, 1, P0_K_DATA, P0_K_SCALE,
                   P0_V_DATA, P0_V_SCALE, 0);
        wait_fault(SOURCE_VALIDATOR, ERR_HEADER_CRC, 0, 1);
        if (k_integrity_faults == 0 || page_valid || page_active)
            errors = errors + 1;
        clear_and_restart();

        // V record CRC failure is attributed to V and remains private.
        $display("PHASE v_crc scale=%0d", SCALE_BITS);
        build_image(P0_K_DATA, P0_K_SCALE, 0, 0, 8'h12);
        build_image(P0_V_DATA, P0_V_SCALE, 1, 0, 8'h13);
        memory[P0_V_SCALE] = memory[P0_V_SCALE] ^ 8'h01;
        issue_pair(8'hb2, 0, 1, 0, 1, P0_K_DATA, P0_K_SCALE,
                   P0_V_DATA, P0_V_SCALE, 0);
        wait_fault(SOURCE_VALIDATOR, ERR_HEADER_CRC, 1, 1);
        if (v_integrity_faults == 0)
            errors = errors + 1;
        clear_and_restart();

        // V0 transport error preserves the child reader namespace.
        $display("PHASE v_transport scale=%0d", SCALE_BITS);
        build_image(P0_K_DATA, P0_K_SCALE, 0, 0, 8'h14);
        build_image(P0_V_DATA, P0_V_SCALE, 1, 0, 8'h15);
        inject_rresp[2] = 2'b10;
        issue_pair(8'hb3, 0, 1, 0, 1, P0_K_DATA, P0_K_SCALE,
                   P0_V_DATA, P0_V_SCALE, 0);
        wait_fault(SOURCE_READER, ERR_RRESP, 1, 0);
        inject_rresp[2] = 0;
        if (v_transport_faults == 0)
            errors = errors + 1;
        clear_and_restart();

        // Fault-inject a committed-head identity mismatch.  Publication must
        // disappear combinationally before the abort pulse is registered.
        $display("PHASE identity scale=%0d", SCALE_BITS);
        build_image(P0_K_DATA, P0_K_SCALE, 0, 0, 8'h16);
        build_image(P0_V_DATA, P0_V_SCALE, 1, 0, 8'h17);
        issue_pair(8'hb4, 0, 1, 0, 1, P0_K_DATA, P0_K_SCALE,
                   P0_V_DATA, P0_V_SCALE, 0);
        wait_pair_valid(8'hb4, 0, 1, 0, 1, 0);
        force dut.v_page_index_i = 5'd1;
        #1;
        if (page_valid || page_active)
            $fatal(1, "identity mismatch was not hidden immediately");
        @(negedge clk);
        release dut.v_page_index_i;
        wait_fault(SOURCE_PAIR, ERR_IDENTITY, 0, 0);
        clear_and_restart();

        // Abort while both physical slots in both streams are occupied.
        $display("PHASE occupied_abort scale=%0d", SCALE_BITS);
        build_image(P0_K_DATA, P0_K_SCALE, 0, 0, 8'h18);
        build_image(P0_V_DATA, P0_V_SCALE, 1, 0, 8'h19);
        build_image(P1_K_DATA, P1_K_SCALE, 0, 0, 8'h1a);
        build_image(P1_V_DATA, P1_V_SCALE, 1, 0, 8'h1b);
        issue_pair(8'hc0, 0, 2, 0, 1, P0_K_DATA, P0_K_SCALE,
                   P0_V_DATA, P0_V_SCALE, 0);
        issue_pair(8'hc1, 1, 2, 128, 1, P1_K_DATA, P1_K_SCALE,
                   P1_V_DATA, P1_V_SCALE, 0);
        timeout = 0;
        while ((dut.u_k.queue_count != 2 || dut.u_v.queue_count != 2) &&
               timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= WATCHDOG)
            $fatal(1, "both paired slots were not occupied");
        abort = 1;
        #1;
        if (page_valid || page_active || cmd_ready)
            $fatal(1, "external abort did not hide pair immediately");
        @(negedge clk);
        abort = 0;
        wait_fault(SOURCE_PAIR, ERR_EXTERNAL_ABORT, 0, 0);
        clear_and_restart();

        // No-reset restart after the occupied abort; the short image must not
        // expose stale words left by the preceding RAW/queued pages.
        $display("PHASE restart scale=%0d", SCALE_BITS);
        build_image(P0_K_DATA, P0_K_SCALE, 0, 0, 8'h20);
        build_image(P0_V_DATA, P0_V_SCALE, 1, 0, 8'h21);
        issue_pair(8'hd0, 0, 1, 0, 1, P0_K_DATA, P0_K_SCALE,
                   P0_V_DATA, P0_V_SCALE, 0);
        wait_pair_valid(8'hd0, 0, 1, 0, 1, 0);
        accept_pair();
        verify_exact_image(0, P0_K_DATA, P0_K_SCALE, 0);
        verify_exact_image(1, P0_V_DATA, P0_V_SCALE, 0);
        verify_stale_hidden(0);
        verify_stale_hidden(1);
        release_pair();

        repeat (3) @(negedge clk);
        for (i = 0; i < 4; i = i + 1) begin
            if (model_errors[i] != 0) begin
                $display("FAIL AXI model port=%0d errors=%0d", i,
                         model_errors[i]);
                errors = errors + 1;
            end
        end
        if (row_abort_pulses != 6 || pair_aborted_rows != 6) begin
            $display("FAIL abort accounting pulses=%0d counter=%0d",
                     row_abort_pulses, pair_aborted_rows);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("KV_V03_KV_PAGE_PREFETCH_SCALE%0d_PASS", SCALE_BITS);
            $finish;
        end
        $fatal(1, "KV pair prefetch SCALE_BITS=%0d errors=%0d",
               SCALE_BITS, errors);
    end
endmodule

// One independent, single-outstanding HP64 memory endpoint.  Four instances
// prove there is no hidden arbitration between K0/K1/V0/V1.
module tb_kv_v03_hp64_memory_port #(
    parameter integer PORT_INDEX = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        allow_ar,
    input  wire [1:0]  inject_rresp,
    input  wire [7:0]  response_delay,
    input  wire        arid,
    input  wire [31:0] araddr,
    input  wire [7:0]  arlen,
    input  wire [2:0]  arsize,
    input  wire [1:0]  arburst,
    input  wire        arlock,
    input  wire [3:0]  arcache,
    input  wire [2:0]  arprot,
    input  wire [3:0]  arqos,
    input  wire        arvalid,
    output wire        arready,
    output reg         rid,
    output reg  [63:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rlast,
    output reg         rvalid,
    input  wire        rready,
    output wire [31:0] mem_addr,
    input  wire [63:0] mem_data,
    output reg  [31:0] protocol_errors
);
    reg active;
    reg [31:0] base_addr;
    reg [8:0] beats;
    reg [8:0] beat_index;
    reg [7:0] wait_cycles;
    assign arready = allow_ar && !active;
    assign mem_addr = base_addr + beat_index*8;

    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 0;
            base_addr <= 0;
            beats <= 0;
            beat_index <= 0;
            wait_cycles <= 0;
            rid <= 0;
            rdata <= 0;
            rresp <= 0;
            rlast <= 0;
            rvalid <= 0;
            protocol_errors <= 0;
        end else begin
            if (arvalid && arready) begin
                if (arid != 0 || arsize != 3'd3 || arburst != 2'b01 ||
                    arlock != 0 || arcache != 4'b0010 || arprot != 0 ||
                    arqos != 0 || araddr[2:0] != 0 ||
                    araddr[11:0] + ((arlen+1)*8) > 4096)
                    protocol_errors <= protocol_errors + 1'b1;
                active <= 1;
                base_addr <= araddr;
                beats <= arlen + 1'b1;
                beat_index <= 0;
                wait_cycles <= response_delay;
            end

            if (rvalid && rready) begin
                rvalid <= 0;
                if (rlast)
                    active <= 0;
                else
                    beat_index <= beat_index + 1'b1;
            end

            if (active && !rvalid) begin
                if (wait_cycles != 0)
                    wait_cycles <= wait_cycles - 1'b1;
                else begin
                    rvalid <= 1;
                    rid <= 0;
                    rdata <= mem_data;
                    rresp <= inject_rresp;
                    rlast <= (beat_index == beats-1);
                end
            end
        end
    end

    wire unused = PORT_INDEX[0];
endmodule

`default_nettype wire
