// tb_kv_v03_page_pingpong.v -- ordered two-slot page prefetch regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_BITS_VAL
`define SCALE_BITS_VAL 12
`endif

module tb_kv_v03_page_pingpong #(
    parameter integer SCALE_BITS = `SCALE_BITS_VAL
);
    localparam integer WATCHDOG = 20000;
    localparam [15:0] COMPILED_PROFILE = 16'h1234;
    localparam [7:0] COMPILED_CODEBOOK = 8'h5a;
    localparam [31:0] DATA_ADDR = 32'h0000_1000;
    localparam [31:0] SCALE_ADDR = 32'h0000_5000;
    localparam integer LONG_SCALE_BYTES = (SCALE_BITS == 12) ? 192 : 256;
    localparam [7:0] SCALE_FORMAT = (SCALE_BITS == 12) ? 8'd1 : 8'd2;

    localparam [1:0] SOURCE_PAIR = 2'd0;
    localparam [1:0] SOURCE_READER = 2'd2;
    localparam [1:0] SOURCE_VALIDATOR = 2'd3;
    localparam [7:0] ERR_PROFILE = 8'h01;
    localparam [7:0] ERR_PAIR_CODEBOOK = 8'h02;
    localparam [7:0] ERR_RRESP = 8'h13;
    localparam [7:0] ERR_HEADER_CODEBOOK = 8'h25;
    localparam [7:0] ERR_HEADER_CRC = 8'h27;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg cmd_valid = 0;
    wire cmd_ready;
    reg [7:0] cmd_request_id = 0;
    reg [15:0] cmd_layer = 0;
    reg [15:0] cmd_kv_head = 0;
    reg [15:0] cmd_profile_id = COMPILED_PROFILE;
    reg [7:0] cmd_codebook_id = COMPILED_CODEBOOK;
    reg [4:0] cmd_page_index = 0;
    reg [5:0] cmd_page_count = 0;
    reg [12:0] cmd_token_base = 0;
    reg [7:0] cmd_token_count = 0;
    reg [14:0] cmd_expected_symbols = 0;
    reg [31:0] cmd_data_addr = 0;
    reg [31:0] cmd_data_limit = 0;
    reg [31:0] cmd_page_window_bytes = 0;
    reg [31:0] cmd_scale_addr = 0;
    reg [8:0] cmd_scale_slice_bytes = 0;
    reg abort = 0;
    reg clear_fault = 0;
    reg clear_counters = 0;

    wire page_valid;
    reg page_ready = 0;
    wire page_active;
    reg page_release = 0;
    wire [7:0] page_request_id;
    wire [15:0] page_layer;
    wire [15:0] page_kv_head;
    wire [15:0] page_profile_id;
    wire [7:0] page_codebook_id;
    wire [4:0] page_index;
    wire [5:0] page_count;
    wire [12:0] page_token_base;
    wire [7:0] page_token_count;
    wire [14:0] page_expected_symbols;
    wire page_raw_mode;
    wire page_stream_is_v;
    wire [15:0] page_payload_bytes;
    wire [7:0] page_scale_format_id;
    wire [13:0] page_record_bytes;
    wire [13:0] page_window_bytes;
    wire [8:0] page_scale_slice_bytes;
    wire [13:0] page_padding_bytes;

    reg data_rd_en = 0;
    reg [11:0] data_rd_word_addr = 0;
    wire data_rd_valid;
    wire [31:0] data_rd_data;
    wire [3:0] data_rd_byte_valid;
    wire data_rd_last;
    wire [13:0] data_rd_byte_offset;
    reg scale_rd_en = 0;
    reg [6:0] scale_rd_word_addr = 0;
    wire scale_rd_valid;
    wire [31:0] scale_rd_data;
    wire [3:0] scale_rd_byte_valid;
    wire scale_rd_last;
    wire [8:0] scale_rd_byte_offset;

    reg consumer_need = 0;
    wire busy;
    wire flushing;
    wire sticky_error;
    wire [1:0] sticky_error_source;
    wire [7:0] sticky_error_code;
    wire sticky_error_phase_is_scale;
    wire [7:0] sticky_request_id;
    wire [15:0] sticky_layer;
    wire [15:0] sticky_kv_head;
    wire [15:0] sticky_profile_id;
    wire [7:0] sticky_codebook_id;
    wire [4:0] sticky_page_index;
    wire row_abort;
    wire reload_required;

    wire [31:0] prefetch_commands;
    wire [31:0] pages_published;
    wire [31:0] pages_released;
    wire [31:0] raw_fallback_pages;
    wire [31:0] integrity_faults;
    wire [31:0] transport_faults;
    wire [31:0] aborted_rows;
    wire [31:0] starvation_cycles;
    wire [1:0] fifo_high_water;
    wire [31:0] read_beats;
    wire [31:0] burst_count;
    wire [31:0] ar_stall_cycles;
    wire [31:0] r_wait_cycles;
    wire [31:0] output_stall_cycles;

    wire m0_axi_arid;
    wire [31:0] m0_axi_araddr;
    wire [7:0] m0_axi_arlen;
    wire [2:0] m0_axi_arsize;
    wire [1:0] m0_axi_arburst;
    wire m0_axi_arlock;
    wire [3:0] m0_axi_arcache;
    wire [2:0] m0_axi_arprot;
    wire [3:0] m0_axi_arqos;
    wire m0_axi_arvalid;
    wire m0_axi_arready;
    reg m0_axi_rid = 0;
    reg [63:0] m0_axi_rdata = 0;
    reg [1:0] m0_axi_rresp = 0;
    reg m0_axi_rlast = 0;
    reg m0_axi_rvalid = 0;
    wire m0_axi_rready;

    wire m1_axi_arid;
    wire [31:0] m1_axi_araddr;
    wire [7:0] m1_axi_arlen;
    wire [2:0] m1_axi_arsize;
    wire [1:0] m1_axi_arburst;
    wire m1_axi_arlock;
    wire [3:0] m1_axi_arcache;
    wire [2:0] m1_axi_arprot;
    wire [3:0] m1_axi_arqos;
    wire m1_axi_arvalid;
    wire m1_axi_arready;
    reg m1_axi_rid = 0;
    reg [63:0] m1_axi_rdata = 0;
    reg [1:0] m1_axi_rresp = 0;
    reg m1_axi_rlast = 0;
    reg m1_axi_rvalid = 0;
    wire m1_axi_rready;

    reg [7:0] memory0 [0:65535];
    reg [7:0] memory1 [0:65535];
    reg model0_active = 0;
    reg model1_active = 0;
    reg [31:0] model0_addr = 0;
    reg [31:0] model1_addr = 0;
    integer model0_beats = 0;
    integer model1_beats = 0;
    integer model0_index = 0;
    integer model1_index = 0;
    integer model0_wait = 0;
    integer model1_wait = 0;
    integer response_gap0 = 0;
    integer response_gap1 = 0;
    reg allow_ar0 = 1;
    reg allow_ar1 = 1;
    reg inject_rresp0 = 0;

    integer errors = 0;
    integer timeout;
    integer i;
    integer cycle_count = 0;
    integer row_abort_pulses = 0;
    integer fault_row_before;
    integer starvation_before;
    integer abort_rows_before;
    integer commands_before;

    kv_v03_page_pingpong #(
        .ADDR_WIDTH(32),
        .ID_WIDTH(1),
        .SCALE_BITS(SCALE_BITS),
        .STREAM_IS_V(0),
        .COMPILED_PROFILE_ID(COMPILED_PROFILE),
        .COMPILED_CODEBOOK_ID(COMPILED_CODEBOOK),
        .TIMEOUT_CYCLES(128),
        .MAX_PAGE_BYTES(10256),
        .MAX_SCALE_BYTES(256)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_request_id(cmd_request_id), .cmd_layer(cmd_layer),
        .cmd_kv_head(cmd_kv_head), .cmd_profile_id(cmd_profile_id),
        .cmd_codebook_id(cmd_codebook_id), .cmd_page_index(cmd_page_index),
        .cmd_page_count(cmd_page_count), .cmd_token_base(cmd_token_base),
        .cmd_token_count(cmd_token_count),
        .cmd_expected_symbols(cmd_expected_symbols),
        .cmd_data_addr(cmd_data_addr), .cmd_data_limit(cmd_data_limit),
        .cmd_page_window_bytes(cmd_page_window_bytes),
        .cmd_scale_addr(cmd_scale_addr),
        .cmd_scale_slice_bytes(cmd_scale_slice_bytes),
        .abort(abort), .clear_fault(clear_fault),
        .clear_counters(clear_counters),
        .page_valid(page_valid), .page_ready(page_ready),
        .page_active(page_active), .page_release(page_release),
        .page_request_id(page_request_id), .page_layer(page_layer),
        .page_kv_head(page_kv_head), .page_profile_id(page_profile_id),
        .page_codebook_id(page_codebook_id), .page_index(page_index),
        .page_count(page_count), .page_token_base(page_token_base),
        .page_token_count(page_token_count),
        .page_expected_symbols(page_expected_symbols),
        .page_raw_mode(page_raw_mode), .page_stream_is_v(page_stream_is_v),
        .page_payload_bytes(page_payload_bytes),
        .page_scale_format_id(page_scale_format_id),
        .page_record_bytes(page_record_bytes),
        .page_window_bytes(page_window_bytes),
        .page_scale_slice_bytes(page_scale_slice_bytes),
        .page_padding_bytes(page_padding_bytes),
        .data_rd_en(data_rd_en), .data_rd_word_addr(data_rd_word_addr),
        .data_rd_valid(data_rd_valid), .data_rd_data(data_rd_data),
        .data_rd_byte_valid(data_rd_byte_valid), .data_rd_last(data_rd_last),
        .data_rd_byte_offset(data_rd_byte_offset),
        .scale_rd_en(scale_rd_en), .scale_rd_word_addr(scale_rd_word_addr),
        .scale_rd_valid(scale_rd_valid), .scale_rd_data(scale_rd_data),
        .scale_rd_byte_valid(scale_rd_byte_valid),
        .scale_rd_last(scale_rd_last),
        .scale_rd_byte_offset(scale_rd_byte_offset),
        .consumer_need(consumer_need), .busy(busy), .flushing(flushing),
        .sticky_error(sticky_error),
        .sticky_error_source(sticky_error_source),
        .sticky_error_code(sticky_error_code),
        .sticky_error_phase_is_scale(sticky_error_phase_is_scale),
        .sticky_request_id(sticky_request_id), .sticky_layer(sticky_layer),
        .sticky_kv_head(sticky_kv_head),
        .sticky_profile_id(sticky_profile_id),
        .sticky_codebook_id(sticky_codebook_id),
        .sticky_page_index(sticky_page_index), .row_abort(row_abort),
        .reload_required(reload_required),
        .prefetch_commands(prefetch_commands),
        .pages_published(pages_published), .pages_released(pages_released),
        .raw_fallback_pages(raw_fallback_pages),
        .integrity_faults(integrity_faults),
        .transport_faults(transport_faults), .aborted_rows(aborted_rows),
        .starvation_cycles(starvation_cycles),
        .fifo_high_water(fifo_high_water), .read_beats(read_beats),
        .burst_count(burst_count), .ar_stall_cycles(ar_stall_cycles),
        .r_wait_cycles(r_wait_cycles),
        .output_stall_cycles(output_stall_cycles),
        .m0_axi_arid(m0_axi_arid), .m0_axi_araddr(m0_axi_araddr),
        .m0_axi_arlen(m0_axi_arlen), .m0_axi_arsize(m0_axi_arsize),
        .m0_axi_arburst(m0_axi_arburst), .m0_axi_arlock(m0_axi_arlock),
        .m0_axi_arcache(m0_axi_arcache), .m0_axi_arprot(m0_axi_arprot),
        .m0_axi_arqos(m0_axi_arqos), .m0_axi_arvalid(m0_axi_arvalid),
        .m0_axi_arready(m0_axi_arready), .m0_axi_rid(m0_axi_rid),
        .m0_axi_rdata(m0_axi_rdata), .m0_axi_rresp(m0_axi_rresp),
        .m0_axi_rlast(m0_axi_rlast), .m0_axi_rvalid(m0_axi_rvalid),
        .m0_axi_rready(m0_axi_rready),
        .m1_axi_arid(m1_axi_arid), .m1_axi_araddr(m1_axi_araddr),
        .m1_axi_arlen(m1_axi_arlen), .m1_axi_arsize(m1_axi_arsize),
        .m1_axi_arburst(m1_axi_arburst), .m1_axi_arlock(m1_axi_arlock),
        .m1_axi_arcache(m1_axi_arcache), .m1_axi_arprot(m1_axi_arprot),
        .m1_axi_arqos(m1_axi_arqos), .m1_axi_arvalid(m1_axi_arvalid),
        .m1_axi_arready(m1_axi_arready), .m1_axi_rid(m1_axi_rid),
        .m1_axi_rdata(m1_axi_rdata), .m1_axi_rresp(m1_axi_rresp),
        .m1_axi_rlast(m1_axi_rlast), .m1_axi_rvalid(m1_axi_rvalid),
        .m1_axi_rready(m1_axi_rready)
    );

    assign m0_axi_arready = allow_ar0 && !model0_active;
    assign m1_axi_arready = allow_ar1 && !model1_active;

    function [63:0] memory_word0;
        input [31:0] address;
        integer lane;
        begin
            memory_word0 = 0;
            for (lane = 0; lane < 8; lane = lane + 1)
                memory_word0[(lane*8) +: 8] = memory0[address+lane];
        end
    endfunction

    function [63:0] memory_word1;
        input [31:0] address;
        integer lane;
        begin
            memory_word1 = 0;
            for (lane = 0; lane < 8; lane = lane + 1)
                memory_word1[(lane*8) +: 8] = memory1[address+lane];
        end
    endfunction

    function [31:0] memory_word32;
        input integer bank;
        input [31:0] address;
        integer lane;
        begin
            memory_word32 = 0;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (bank == 0)
                    memory_word32[(lane*8) +: 8] = memory0[address+lane];
                else
                    memory_word32[(lane*8) +: 8] = memory1[address+lane];
            end
        end
    endfunction

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

    task put_byte;
        input integer bank;
        input integer address;
        input [7:0] value;
        begin
            if (bank == 0)
                memory0[address] = value;
            else
                memory1[address] = value;
        end
    endtask

    function [7:0] get_byte;
        input integer bank;
        input integer address;
        begin
            get_byte = (bank == 0) ? memory0[address] : memory1[address];
        end
    endfunction

    task build_image;
        input integer bank;
        input integer token_count_value;
        input integer raw_value;
        input integer payload_bytes_value;
        input integer window_bytes_value;
        input integer scale_bytes_value;
        input [7:0] header_codebook;
        input [7:0] seed;
        input integer corrupt_after_crc;
        integer j;
        reg [31:0] crc_work;
        begin
            for (j = 0; j < window_bytes_value + 8; j = j + 1)
                put_byte(bank, DATA_ADDR+j, 0);
            for (j = 0; j < scale_bytes_value + 8; j = j + 1)
                put_byte(bank, SCALE_ADDR+j, 0);
            put_byte(bank, DATA_ADDR+0, 8'h03);
            put_byte(bank, DATA_ADDR+1, 8'hc3);
            put_byte(bank, DATA_ADDR+2, raw_value ? 8'h01 : 8'h00);
            put_byte(bank, DATA_ADDR+3, token_count_value-1);
            put_byte(bank, DATA_ADDR+4, payload_bytes_value & 8'hff);
            put_byte(bank, DATA_ADDR+5, (payload_bytes_value >> 8) & 8'hff);
            put_byte(bank, DATA_ADDR+6, header_codebook);
            put_byte(bank, DATA_ADDR+7, SCALE_FORMAT);
            for (j = 0; j < payload_bytes_value; j = j + 1)
                put_byte(bank, DATA_ADDR+12+j, seed + j*7);
            for (j = 0; j < scale_bytes_value; j = j + 1)
                put_byte(bank, SCALE_ADDR+j, seed + j*3 + 8'h11);
            // UQ4.8 is densely packed.  Odd scale counts leave four canonical
            // zero padding bits in the high nibble of the final byte.
            if ((SCALE_BITS == 12) && (token_count_value[0] != 0))
                put_byte(bank, SCALE_ADDR+scale_bytes_value-1,
                         get_byte(bank, SCALE_ADDR+scale_bytes_value-1) &
                         8'h0f);

            crc_work = 32'hffff_ffff;
            for (j = 0; j < 8; j = j + 1)
                crc_work = crc_byte(crc_work, get_byte(bank, DATA_ADDR+j));
            for (j = 0; j < payload_bytes_value; j = j + 1)
                crc_work = crc_byte(crc_work,
                                    get_byte(bank, DATA_ADDR+12+j));
            for (j = 0; j < scale_bytes_value; j = j + 1)
                crc_work = crc_byte(crc_work, get_byte(bank, SCALE_ADDR+j));
            crc_work = crc_work ^ 32'hffff_ffff;
            put_byte(bank, DATA_ADDR+8, crc_work[7:0]);
            put_byte(bank, DATA_ADDR+9, crc_work[15:8]);
            put_byte(bank, DATA_ADDR+10, crc_work[23:16]);
            put_byte(bank, DATA_ADDR+11, crc_work[31:24]);
            if (corrupt_after_crc)
                put_byte(bank, DATA_ADDR+12,
                         get_byte(bank, DATA_ADDR+12) ^ 8'h01);
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            model0_active <= 0;
            model0_addr <= 0;
            model0_beats <= 0;
            model0_index <= 0;
            model0_wait <= 0;
            m0_axi_rvalid <= 0;
            m0_axi_rdata <= 0;
            m0_axi_rresp <= 0;
            m0_axi_rlast <= 0;
            m0_axi_rid <= 0;
        end else begin
            if (m0_axi_arvalid && m0_axi_arready) begin
                if (m0_axi_arid != 0 || m0_axi_arsize != 3'd3 ||
                    m0_axi_arburst != 2'b01 || m0_axi_arlock != 0 ||
                    m0_axi_arcache != 4'b0010 || m0_axi_arprot != 0 ||
                    m0_axi_arqos != 0 || m0_axi_araddr[2:0] != 0 ||
                    m0_axi_araddr[11:0] + ((m0_axi_arlen+1)*8) > 4096) begin
                    $display("FAIL slot0 AXI request contract");
                    errors = errors + 1;
                end
                model0_active <= 1;
                model0_addr <= m0_axi_araddr;
                model0_beats <= m0_axi_arlen + 1;
                model0_index <= 0;
                model0_wait <= response_gap0;
            end
            if (m0_axi_rvalid && m0_axi_rready) begin
                m0_axi_rvalid <= 0;
                if (m0_axi_rlast)
                    model0_active <= 0;
                else begin
                    model0_index <= model0_index + 1;
                    model0_wait <= response_gap0;
                end
            end
            if (model0_active && !m0_axi_rvalid) begin
                if (model0_wait != 0)
                    model0_wait <= model0_wait - 1;
                else begin
                    m0_axi_rvalid <= 1;
                    m0_axi_rdata <= memory_word0(model0_addr+model0_index*8);
                    m0_axi_rid <= 0;
                    m0_axi_rresp <= inject_rresp0 ? 2'b10 : 2'b00;
                    m0_axi_rlast <= (model0_index == model0_beats-1);
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            model1_active <= 0;
            model1_addr <= 0;
            model1_beats <= 0;
            model1_index <= 0;
            model1_wait <= 0;
            m1_axi_rvalid <= 0;
            m1_axi_rdata <= 0;
            m1_axi_rresp <= 0;
            m1_axi_rlast <= 0;
            m1_axi_rid <= 0;
        end else begin
            if (m1_axi_arvalid && m1_axi_arready) begin
                if (m1_axi_arid != 0 || m1_axi_arsize != 3'd3 ||
                    m1_axi_arburst != 2'b01 || m1_axi_arlock != 0 ||
                    m1_axi_arcache != 4'b0010 || m1_axi_arprot != 0 ||
                    m1_axi_arqos != 0 || m1_axi_araddr[2:0] != 0 ||
                    m1_axi_araddr[11:0] + ((m1_axi_arlen+1)*8) > 4096) begin
                    $display("FAIL slot1 AXI request contract");
                    errors = errors + 1;
                end
                model1_active <= 1;
                model1_addr <= m1_axi_araddr;
                model1_beats <= m1_axi_arlen + 1;
                model1_index <= 0;
                model1_wait <= response_gap1;
            end
            if (m1_axi_rvalid && m1_axi_rready) begin
                m1_axi_rvalid <= 0;
                if (m1_axi_rlast)
                    model1_active <= 0;
                else begin
                    model1_index <= model1_index + 1;
                    model1_wait <= response_gap1;
                end
            end
            if (model1_active && !m1_axi_rvalid) begin
                if (model1_wait != 0)
                    model1_wait <= model1_wait - 1;
                else begin
                    m1_axi_rvalid <= 1;
                    m1_axi_rdata <= memory_word1(model1_addr+model1_index*8);
                    m1_axi_rid <= 0;
                    m1_axi_rresp <= 2'b00;
                    m1_axi_rlast <= (model1_index == model1_beats-1);
                end
            end
        end
    end

    always @(negedge clk) begin
        if (!rst_n) begin
            cycle_count = 0;
            row_abort_pulses = 0;
        end else begin
            cycle_count = cycle_count + 1;
            if (row_abort)
                row_abort_pulses = row_abort_pulses + 1;
            if ((data_rd_valid || scale_rd_valid) && !page_active) begin
                $display("FAIL scratch became visible without active ownership");
                errors = errors + 1;
            end
            if ((sticky_error || flushing || abort) &&
                (page_valid || page_active || data_rd_valid || scale_rd_valid)) begin
                $display("FAIL fault/flush/abort leaked a page or scratch data");
                errors = errors + 1;
            end
        end
    end

    task configure_command;
        input [7:0] request_id_value;
        input [15:0] layer_value;
        input [15:0] head_value;
        input [15:0] profile_value;
        input [7:0] codebook_value;
        input [4:0] page_index_value;
        input [5:0] page_count_value;
        input [12:0] token_base_value;
        input [7:0] token_count_value;
        input [14:0] symbols_value;
        input [31:0] window_value;
        input [8:0] scale_bytes_value;
        begin
            cmd_request_id = request_id_value;
            cmd_layer = layer_value;
            cmd_kv_head = head_value;
            cmd_profile_id = profile_value;
            cmd_codebook_id = codebook_value;
            cmd_page_index = page_index_value;
            cmd_page_count = page_count_value;
            cmd_token_base = token_base_value;
            cmd_token_count = token_count_value;
            cmd_expected_symbols = symbols_value;
            cmd_data_addr = DATA_ADDR;
            cmd_data_limit = DATA_ADDR + window_value;
            cmd_page_window_bytes = window_value;
            cmd_scale_addr = SCALE_ADDR;
            cmd_scale_slice_bytes = scale_bytes_value;
        end
    endtask

    task issue_current;
        begin
            timeout = 0;
            while (!cmd_ready && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!cmd_ready)
                $fatal(1, "command-ready timeout");
            cmd_valid = 1;
            @(negedge clk);
            cmd_valid = 0;
        end
    endtask

    task wait_page_valid;
        begin
            timeout = 0;
            while (!page_valid && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!page_valid)
                $fatal(1, "page-valid timeout");
        end
    endtask

    task check_page;
        input [7:0] request_value;
        input [15:0] layer_value;
        input [15:0] head_value;
        input [4:0] index_value;
        input [5:0] count_value;
        input [12:0] base_value;
        input [7:0] tokens_value;
        input [14:0] symbols_value;
        input raw_value;
        input [15:0] payload_value;
        input [13:0] record_value;
        input [13:0] window_value;
        input [8:0] scale_bytes_value;
        input [13:0] padding_value;
        begin
            if (!page_valid || page_active ||
                page_request_id != request_value || page_layer != layer_value ||
                page_kv_head != head_value ||
                page_profile_id != COMPILED_PROFILE ||
                page_codebook_id != COMPILED_CODEBOOK ||
                page_index != index_value || page_count != count_value ||
                page_token_base != base_value ||
                page_token_count != tokens_value ||
                page_expected_symbols != symbols_value ||
                page_raw_mode != raw_value || page_stream_is_v != 0 ||
                page_payload_bytes != payload_value ||
                page_scale_format_id != SCALE_FORMAT ||
                page_record_bytes != record_value ||
                page_window_bytes != window_value ||
                page_scale_slice_bytes != scale_bytes_value ||
                page_padding_bytes != padding_value) begin
                $display("FAIL typed page metadata req=%02x index=%0d raw=%0d payload=%0d",
                         page_request_id, page_index, page_raw_mode,
                         page_payload_bytes);
                errors = errors + 1;
            end
        end
    endtask

    task hidden_read_check;
        begin
            data_rd_word_addr = 0;
            scale_rd_word_addr = 0;
            data_rd_en = 1;
            scale_rd_en = 1;
            @(negedge clk);
            data_rd_en = 0;
            scale_rd_en = 0;
            if (data_rd_valid || scale_rd_valid) begin
                $display("FAIL scratch visible before page ownership");
                errors = errors + 1;
            end
            @(negedge clk);
            if (data_rd_valid || scale_rd_valid) begin
                $display("FAIL delayed hidden scratch response");
                errors = errors + 1;
            end
        end
    endtask

    task read_first_scale_word;
        input [31:0] expected;
        begin
            scale_rd_word_addr = 0;
            scale_rd_en = 1;
            @(negedge clk);
            scale_rd_en = 0;
            if (!scale_rd_valid || scale_rd_data !== expected ||
                scale_rd_byte_offset != 0) begin
                $display("FAIL owned scale scratch read got=%08x expected=%08x valid=%0d",
                         scale_rd_data, expected, scale_rd_valid);
                errors = errors + 1;
            end
            @(negedge clk);
            if (scale_rd_valid) begin
                $display("FAIL scale scratch valid exceeded one cycle");
                errors = errors + 1;
            end
        end
    endtask

    task accept_page;
        begin
            page_ready = 1;
            @(negedge clk);
            page_ready = 0;
            if (!page_active || page_valid) begin
                $display("FAIL page ownership handshake");
                errors = errors + 1;
            end
        end
    endtask

    task read_first_data_word;
        input [31:0] expected;
        begin
            data_rd_word_addr = 0;
            data_rd_en = 1;
            @(negedge clk);
            data_rd_en = 0;
            if (!data_rd_valid || data_rd_data !== expected ||
                data_rd_byte_valid !== 4'hf || data_rd_byte_offset != 0) begin
                $display("FAIL owned scratch read got=%08x expected=%08x valid=%0d",
                         data_rd_data, expected, data_rd_valid);
                errors = errors + 1;
            end
            @(negedge clk);
            if (data_rd_valid) begin
                $display("FAIL scratch read valid exceeded one cycle");
                errors = errors + 1;
            end
        end
    endtask

    task release_page;
        begin
            page_release = 1;
            #1;
            if (data_rd_valid || scale_rd_valid) begin
                $display("FAIL release did not hide registered scratch output");
                errors = errors + 1;
            end
            @(negedge clk);
            page_release = 0;
        end
    endtask

    task release_with_pending_read;
        begin
            data_rd_word_addr = 0;
            data_rd_en = 1;
            @(negedge clk);
            data_rd_en = 0;
            if (!data_rd_valid) begin
                $display("FAIL pending read was not established before release");
                errors = errors + 1;
            end
            page_release = 1;
            #1;
            if (data_rd_valid || scale_rd_valid) begin
                $display("FAIL release leaked a pending registered read");
                errors = errors + 1;
            end
            @(negedge clk);
            page_release = 0;
        end
    endtask

    task wait_empty;
        begin
            timeout = 0;
            while (busy && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (busy || page_valid || page_active)
                $fatal(1, "queue failed to become empty");
        end
    endtask

    task short_good_restart;
        input [7:0] request_value;
        input [7:0] seed;
        begin
            response_gap0 = 0;
            build_image(0, 1, 0, 1, 16, 2,
                        COMPILED_CODEBOOK, seed, 0);
            configure_command(request_value, 16'h6000+request_value,
                              16'h7000+request_value, COMPILED_PROFILE,
                              COMPILED_CODEBOOK, 0, 1, 0, 1, 128, 16, 2);
            issue_current();
            wait_page_valid();
            check_page(request_value, 16'h6000+request_value,
                       16'h7000+request_value, 0, 1, 0, 1, 128,
                       0, 1, 13, 16, 2, 3);
            hidden_read_check();
            accept_page();
            read_first_data_word(memory_word32(0, DATA_ADDR));
            release_page();
            wait_empty();
            hidden_read_check();
        end
    endtask

    task expect_sticky_fault;
        input [1:0] source_value;
        input [7:0] code_value;
        input phase_value;
        input [7:0] request_value;
        input [15:0] layer_value;
        input [15:0] head_value;
        input [15:0] profile_value;
        input [7:0] codebook_value;
        input [4:0] index_value;
        begin
            timeout = 0;
            while (!sticky_error && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            @(negedge clk);
            if (!sticky_error || sticky_error_source != source_value ||
                sticky_error_code != code_value ||
                sticky_error_phase_is_scale != phase_value ||
                sticky_request_id != request_value ||
                sticky_layer != layer_value || sticky_kv_head != head_value ||
                sticky_profile_id != profile_value ||
                sticky_codebook_id != codebook_value ||
                sticky_page_index != index_value || !reload_required ||
                row_abort_pulses != fault_row_before+1) begin
                $display("FAIL sticky fault source/code=%0d/%02x phase=%0d row=%0d/%0d",
                         sticky_error_source, sticky_error_code,
                         sticky_error_phase_is_scale, row_abort_pulses,
                         fault_row_before+1);
                errors = errors + 1;
            end
            timeout = 0;
            while (flushing && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (flushing)
                $fatal(1, "fault flush timeout");
            commands_before = prefetch_commands;
            cmd_valid = 1;
            repeat (2) begin
                @(negedge clk);
                if (cmd_ready || page_valid || page_active)
                    errors = errors + 1;
            end
            cmd_valid = 0;
            if (prefetch_commands != commands_before) begin
                $display("FAIL sticky fault accepted a blocked command");
                errors = errors + 1;
            end
            clear_fault = 1;
            @(negedge clk);
            clear_fault = 0;
            @(negedge clk);
            if (sticky_error || reload_required || !cmd_ready || busy ||
                page_valid || page_active) begin
                $display("FAIL clear_fault did not restore clean command boundary");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        for (i = 0; i < 65536; i = i + 1) begin
            memory0[i] = 0;
            memory1[i] = 0;
        end
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        if (!cmd_ready || busy || page_valid || page_active)
            $fatal(1, "reset did not establish an idle queue");

        // Count a precisely bounded demand interval with no page available.
        starvation_before = starvation_cycles;
        consumer_need = 1;
        repeat (3) @(negedge clk);
        consumer_need = 0;
        if (starvation_cycles != starvation_before+3) begin
            $display("FAIL starvation count got=%0d expected=%0d",
                     starvation_cycles, starvation_before+3);
            errors = errors + 1;
        end

        // Page 1 is deliberately long/slow and page 2 short/fast.  The second
        // slot must finish first but remain invisible behind the issue-order
        // head.  Page 2 is RAW, exercising fallback accounting.
        response_gap0 = 2;
        response_gap1 = 0;
        build_image(0, 128, 0, 4, 16, LONG_SCALE_BYTES,
                    COMPILED_CODEBOOK, 8'h21, 0);
        build_image(1, 1, 1, 64, 80, 2,
                    COMPILED_CODEBOOK, 8'h91, 0);
        configure_command(8'ha1, 16'h1111, 16'h2222, COMPILED_PROFILE,
                          COMPILED_CODEBOOK, 0, 2, 0, 128, 16384,
                          16, LONG_SCALE_BYTES);
        issue_current();
        configure_command(8'ha2, 16'h4444, 16'h5555, COMPILED_PROFILE,
                          COMPILED_CODEBOOK, 1, 2, 128, 1, 128, 80, 2);
        issue_current();
        timeout = 0;
        while (!dut.u_slot1.slot_active && timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!dut.u_slot1.slot_active || dut.u_slot0.slot_active || page_valid ||
            dut.queue_count != 2) begin
            $display("FAIL faster second slot was not privately completed first timeout=%0d s0=%0d s1=%0d q=%0d sticky=%0d/%0d/%02x flush=%0d slotstate=%0d/%0d validator=%0d/%0d reader=%0d/%0d",
                     timeout, dut.u_slot0.slot_active, dut.u_slot1.slot_active,
                     dut.queue_count, sticky_error, sticky_error_source,
                     sticky_error_code, flushing, dut.u_slot0.state,
                     dut.u_slot1.state, dut.u_slot0.u_validator.state,
                     dut.u_slot1.u_validator.state,
                     dut.u_slot0.u_range_reader.state,
                     dut.u_slot1.u_range_reader.state);
            errors = errors + 1;
        end
        wait_page_valid();
        check_page(8'ha1, 16'h1111, 16'h2222, 0, 2, 0, 128, 16384,
                   0, 4, 16, 16, LONG_SCALE_BYTES, 0);
        // The slot's commit pulse is consumed by the pair counter on the next
        // clock edge; wait for that registered diagnostic before checking it.
        timeout = 0;
        while (pages_published != 2 && timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (fifo_high_water != 2 || pages_published != 2 ||
            raw_fallback_pages != 1) begin
            $display("FAIL queue counters high=%0d published=%0d raw=%0d",
                     fifo_high_water, pages_published, raw_fallback_pages);
            errors = errors + 1;
        end
        hidden_read_check();
        accept_page();
        read_first_data_word(memory_word32(0, DATA_ADDR));
        read_first_scale_word(memory_word32(0, SCALE_ADDR));
        repeat (3) @(negedge clk);
        if (!page_active || page_request_id != 8'ha1 ||
            !dut.u_slot1.slot_active) begin
            $display("FAIL overlap was not retained while page 1 was consumed");
            errors = errors + 1;
        end
        release_page();
        wait_page_valid();
        check_page(8'ha2, 16'h4444, 16'h5555, 1, 2, 128, 1, 128,
                   1, 64, 76, 80, 2, 4);
        hidden_read_check();
        accept_page();
        read_first_data_word(memory_word32(1, DATA_ADDR));
        read_first_scale_word(memory_word32(1, SCALE_ADDR));
        release_with_pending_read();
        wait_empty();
        hidden_read_check();
        if (pages_released != 2 || fifo_high_water != 2 ||
            raw_fallback_pages != 1) begin
            $display("FAIL release/fallback counters released=%0d high=%0d raw=%0d",
                     pages_released, fifo_high_water, raw_fallback_pages);
            errors = errors + 1;
        end

        // Command profile mismatch: fail closed, sticky, reload-required, and
        // reject all further work until an explicit clear.
        configure_command(8'hb1, 16'h0101, 16'h0202, 16'hdead,
                          COMPILED_CODEBOOK, 0, 1, 0, 1, 128, 16, 2);
        fault_row_before = row_abort_pulses;
        issue_current();
        expect_sticky_fault(SOURCE_PAIR, ERR_PROFILE, 0, 8'hb1,
                            16'h0101, 16'h0202, 16'hdead,
                            COMPILED_CODEBOOK, 0);
        short_good_restart(8'hc1, 8'h31);

        // Command codebook mismatch is independent of profile mismatch.
        configure_command(8'hb2, 16'h0102, 16'h0203, COMPILED_PROFILE,
                          8'ha5, 0, 1, 0, 1, 128, 16, 2);
        fault_row_before = row_abort_pulses;
        issue_current();
        expect_sticky_fault(SOURCE_PAIR, ERR_PAIR_CODEBOOK, 0, 8'hb2,
                            16'h0102, 16'h0203, COMPILED_PROFILE,
                            8'ha5, 0);
        short_good_restart(8'hc2, 8'h32);

        // The command tag is valid, but the actual page header carries a wrong
        // codebook.  This proves parameter propagation into both validators.
        build_image(0, 1, 0, 1, 16, 2, 8'ha5, 8'h41, 0);
        configure_command(8'hb3, 16'h0103, 16'h0204, COMPILED_PROFILE,
                          COMPILED_CODEBOOK, 0, 1, 0, 1, 128, 16, 2);
        fault_row_before = row_abort_pulses;
        issue_current();
        expect_sticky_fault(SOURCE_VALIDATOR, ERR_HEADER_CODEBOOK, 0, 8'hb3,
                            16'h0103, 16'h0204, COMPILED_PROFILE,
                            COMPILED_CODEBOOK, 0);
        short_good_restart(8'hc3, 8'h33);

        // CRC corruption is detected only after scale fetch and never publishes
        // tentative scratch contents.
        build_image(0, 1, 0, 1, 16, 2,
                    COMPILED_CODEBOOK, 8'h42, 1);
        configure_command(8'hb4, 16'h0104, 16'h0205, COMPILED_PROFILE,
                          COMPILED_CODEBOOK, 0, 1, 0, 1, 128, 16, 2);
        fault_row_before = row_abort_pulses;
        issue_current();
        expect_sticky_fault(SOURCE_VALIDATOR, ERR_HEADER_CRC, 1, 8'hb4,
                            16'h0104, 16'h0205, COMPILED_PROFILE,
                            COMPILED_CODEBOOK, 0);
        short_good_restart(8'hc4, 8'h34);

        // Preserve the HP64 reader's transport error namespace and data phase.
        build_image(0, 1, 0, 1, 16, 2,
                    COMPILED_CODEBOOK, 8'h43, 0);
        configure_command(8'hb5, 16'h0105, 16'h0206, COMPILED_PROFILE,
                          COMPILED_CODEBOOK, 0, 1, 0, 1, 128, 16, 2);
        inject_rresp0 = 1;
        fault_row_before = row_abort_pulses;
        issue_current();
        expect_sticky_fault(SOURCE_READER, ERR_RRESP, 0, 8'hb5,
                            16'h0105, 16'h0206, COMPILED_PROFILE,
                            COMPILED_CODEBOOK, 0);
        inject_rresp0 = 0;
        short_good_restart(8'hc5, 8'h35);

        // Abort while both queue entries are occupied.  Both independent slots
        // must drain, all ownership must disappear, and a new page must run
        // without resetting the design.
        response_gap0 = 3;
        build_image(0, 128, 0, 4, 16, LONG_SCALE_BYTES,
                    COMPILED_CODEBOOK, 8'h51, 0);
        build_image(1, 1, 1, 64, 80, 2,
                    COMPILED_CODEBOOK, 8'ha1, 0);
        configure_command(8'hd1, 16'h0301, 16'h0401, COMPILED_PROFILE,
                          COMPILED_CODEBOOK, 0, 2, 0, 128, 16384,
                          16, LONG_SCALE_BYTES);
        issue_current();
        configure_command(8'hd2, 16'h0302, 16'h0402, COMPILED_PROFILE,
                          COMPILED_CODEBOOK, 1, 2, 128, 1, 128, 80, 2);
        issue_current();
        if (dut.queue_count != 2 || !dut.occupied0 || !dut.occupied1) begin
            $display("FAIL abort setup did not occupy both slots");
            errors = errors + 1;
        end
        abort_rows_before = aborted_rows;
        abort = 1;
        #1;
        if (page_valid || page_active || data_rd_valid || scale_rd_valid)
            errors = errors + 1;
        @(negedge clk);
        abort = 0;
        timeout = 0;
        while ((flushing || busy) && timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (flushing || busy || sticky_error || reload_required ||
            page_valid || page_active || dut.queue_count != 0 ||
            dut.occupied0 || dut.occupied1 ||
            aborted_rows != abort_rows_before+1) begin
            $display("FAIL two-slot abort drain busy=%0d flush=%0d count=%0d aborted=%0d/%0d",
                     busy, flushing, dut.queue_count, aborted_rows,
                     abort_rows_before+1);
            errors = errors + 1;
        end
        short_good_restart(8'hc6, 8'h36);

        if (integrity_faults < 4 || transport_faults < 1 ||
            fifo_high_water != 2 || raw_fallback_pages != 1 ||
            starvation_cycles < 3 || row_abort_pulses < 6) begin
            $display("FAIL final diagnostics integrity=%0d transport=%0d high=%0d raw=%0d starve=%0d row=%0d",
                     integrity_faults, transport_faults, fifo_high_water,
                     raw_fallback_pages, starvation_cycles, row_abort_pulses);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("TB PASS: page ping-pong SCALE_BITS=%0d", SCALE_BITS);
            if (SCALE_BITS == 12)
                $display("KV_V03_PAGE_PINGPONG_SCALE12_PASS");
            else
                $display("KV_V03_PAGE_PINGPONG_SCALE16_PASS");
            $finish;
        end
        $fatal(1, "TB FAIL: page ping-pong SCALE_BITS=%0d errors=%0d",
               SCALE_BITS, errors);
    end
endmodule

`default_nettype wire
