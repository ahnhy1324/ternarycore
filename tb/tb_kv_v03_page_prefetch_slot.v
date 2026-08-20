// tb_kv_v03_page_prefetch_slot.v -- one-slot HP64 prefetch/commit regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_BITS_VAL
`define SCALE_BITS_VAL 12
`endif

module tb_kv_v03_page_prefetch_slot #(
    parameter integer SCALE_BITS = `SCALE_BITS_VAL
);
    localparam integer ADDR_WIDTH = 32;
    localparam integer ID_WIDTH = 1;
    localparam integer TAG_WIDTH = 64;
    localparam integer WATCHDOG = 20000;
    localparam [31:0] DATA_ADDR = 32'h0000_0ff8;
    localparam [31:0] DATA_LIMIT = 32'h0000_1008;
    localparam [31:0] SCALE_ADDR = 32'h0000_5000;
    localparam [63:0] TAG_GOOD = 64'h5052_4546_0000_0001;
    localparam [63:0] TAG_CRC = 64'h5052_4546_0000_0002;
    localparam [63:0] TAG_AXI = 64'h5052_4546_0000_0003;
    localparam [63:0] TAG_ABORT = 64'h5052_4546_0000_0004;
    localparam [63:0] TAG_RAW_MAX = 64'h5052_4546_0000_0005;
    localparam [63:0] TAG_SHORT_AFTER_LONG = 64'h5052_4546_0000_0006;
    localparam [63:0] TAG_RESET_DATA = 64'h5052_4546_0000_0008;
    localparam [63:0] TAG_RESTART_DATA = 64'h5052_4546_0000_0009;
    localparam [63:0] TAG_RESET_SCALE = 64'h5052_4546_0000_000a;
    localparam [63:0] TAG_RESTART_SCALE = 64'h5052_4546_0000_000b;

    localparam integer RAW_PAYLOAD_BYTES =
        (SCALE_BITS == 12) ? 8192 : 10240;
    localparam integer RAW_WINDOW_BYTES =
        (SCALE_BITS == 12) ? 8208 : 10256;
    localparam integer RAW_SCALE_BYTES =
        (SCALE_BITS == 12) ? 192 : 256;
    localparam integer RAW_DATA_BEATS = RAW_WINDOW_BYTES / 8;
    localparam integer RAW_SCALE_BEATS = RAW_SCALE_BYTES / 8;
    localparam integer RAW_BURSTS = (SCALE_BITS == 12) ? 7 : 8;

    localparam [1:0] SOURCE_SLOT = 2'd1;
    localparam [1:0] SOURCE_READER = 2'd2;
    localparam [1:0] SOURCE_VALIDATOR = 2'd3;
    localparam [7:0] ERR_RRESP = 8'h13;
    localparam [7:0] ERR_HEADER_CRC = 8'h27;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg cmd_valid = 0;
    wire cmd_ready;
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
    reg cmd_stream_is_v = 0;
    reg [63:0] cmd_task_tag = 0;
    reg abort = 0;

    wire publish_valid;
    reg publish_ready = 0;
    reg slot_release = 0;
    wire slot_active;
    wire busy;
    wire [63:0] page_task_tag;
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

    wire committed;
    wire [63:0] committed_task_tag;
    wire aborted;
    wire [63:0] aborted_task_tag;
    wire [4:0] aborted_page_index;
    wire aborted_stream_is_v;
    wire error_valid;
    wire [1:0] error_source;
    wire [7:0] error_code;
    wire error_phase_is_scale;
    wire [63:0] error_task_tag;
    wire [4:0] error_page_index;
    wire error_stream_is_v;

    reg clear_counters = 0;
    wire [31:0] read_beats;
    wire [31:0] burst_count;
    wire [31:0] ar_stall_cycles;
    wire [31:0] r_wait_cycles;
    wire [31:0] output_stall_cycles;
    wire [31:0] data_scratch_bytes;
    wire [31:0] scale_scratch_bytes;
    wire [31:0] committed_pages;
    wire [31:0] failed_pages;
    wire [31:0] aborted_pages;
    wire transport_busy;
    wire transport_draining;

    wire [ID_WIDTH-1:0] m_axi_arid;
    wire [ADDR_WIDTH-1:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_arqos;
    wire m_axi_arvalid;
    wire m_axi_arready;
    reg [ID_WIDTH-1:0] m_axi_rid = 0;
    reg [63:0] m_axi_rdata = 0;
    reg [1:0] m_axi_rresp = 0;
    reg m_axi_rlast = 0;
    reg m_axi_rvalid = 0;
    wire m_axi_rready;

    reg [7:0] memory [0:65535];
    reg allow_ar = 1;
    integer inject_rresp = 0;
    reg model_active = 0;
    reg [31:0] model_addr = 0;
    integer model_beats = 0;
    integer model_index = 0;
    reg [31:0] held_araddr = 0;
    reg [7:0] held_arlen = 0;
    integer errors = 0;
    integer timeout;
    integer i;

    integer commit_pulses = 0;
    integer abort_pulses = 0;
    integer error_pulses = 0;
    reg [1:0] seen_error_source = 0;
    reg [7:0] seen_error_code = 0;
    reg seen_error_phase = 0;
    reg [63:0] seen_error_tag = 0;
    reg [63:0] seen_abort_tag = 0;
    reg [4:0] seen_abort_page = 0;
    reg seen_abort_stream = 0;

    kv_v03_page_prefetch_slot #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .TAG_WIDTH(TAG_WIDTH),
        .SCALE_BITS(SCALE_BITS),
        .TIMEOUT_CYCLES(32),
        .MAX_PAGE_BYTES(10256),
        .MAX_SCALE_BYTES(256)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_page_index(cmd_page_index), .cmd_page_count(cmd_page_count),
        .cmd_token_base(cmd_token_base), .cmd_token_count(cmd_token_count),
        .cmd_expected_symbols(cmd_expected_symbols),
        .cmd_data_addr(cmd_data_addr), .cmd_data_limit(cmd_data_limit),
        .cmd_page_window_bytes(cmd_page_window_bytes),
        .cmd_scale_addr(cmd_scale_addr),
        .cmd_scale_slice_bytes(cmd_scale_slice_bytes),
        .cmd_stream_is_v(cmd_stream_is_v), .cmd_task_tag(cmd_task_tag),
        .abort(abort), .publish_valid(publish_valid),
        .publish_ready(publish_ready), .slot_release(slot_release),
        .slot_active(slot_active), .busy(busy),
        .page_task_tag(page_task_tag), .page_index(page_index),
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
        .data_rd_byte_valid(data_rd_byte_valid),
        .data_rd_last(data_rd_last),
        .data_rd_byte_offset(data_rd_byte_offset),
        .scale_rd_en(scale_rd_en),
        .scale_rd_word_addr(scale_rd_word_addr),
        .scale_rd_valid(scale_rd_valid), .scale_rd_data(scale_rd_data),
        .scale_rd_byte_valid(scale_rd_byte_valid),
        .scale_rd_last(scale_rd_last),
        .scale_rd_byte_offset(scale_rd_byte_offset),
        .committed(committed), .committed_task_tag(committed_task_tag),
        .aborted(aborted), .aborted_task_tag(aborted_task_tag),
        .aborted_page_index(aborted_page_index),
        .aborted_stream_is_v(aborted_stream_is_v),
        .error_valid(error_valid), .error_source(error_source),
        .error_code(error_code), .error_phase_is_scale(error_phase_is_scale),
        .error_task_tag(error_task_tag),
        .error_page_index(error_page_index),
        .error_stream_is_v(error_stream_is_v),
        .clear_counters(clear_counters), .read_beats(read_beats),
        .burst_count(burst_count), .ar_stall_cycles(ar_stall_cycles),
        .r_wait_cycles(r_wait_cycles),
        .output_stall_cycles(output_stall_cycles),
        .data_scratch_bytes(data_scratch_bytes),
        .scale_scratch_bytes(scale_scratch_bytes),
        .committed_pages(committed_pages), .failed_pages(failed_pages),
        .aborted_pages(aborted_pages), .transport_busy(transport_busy),
        .transport_draining(transport_draining),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos), .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready), .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    assign m_axi_arready = allow_ar && !model_active;

    function [63:0] memory_word;
        input [31:0] address;
        integer lane;
        begin
            memory_word = 64'b0;
            for (lane = 0; lane < 8; lane = lane + 1)
                memory_word[(lane*8) +: 8] = memory[address + lane];
        end
    endfunction

    function [31:0] memory_word32;
        input [31:0] address;
        integer lane;
        begin
            memory_word32 = 32'b0;
            for (lane = 0; lane < 4; lane = lane + 1)
                memory_word32[(lane*8) +: 8] = memory[address + lane];
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

    reg [31:0] crc_work;
    task configure_short;
        begin
            cmd_page_index = 0;
            cmd_page_count = 1;
            cmd_token_base = 0;
            cmd_token_count = 1;
            cmd_expected_symbols = 128;
            cmd_data_addr = DATA_ADDR;
            cmd_data_limit = DATA_LIMIT;
            cmd_page_window_bytes = 16;
            cmd_scale_addr = SCALE_ADDR;
            cmd_scale_slice_bytes = 2;
            cmd_stream_is_v = (SCALE_BITS == 16);
        end
    endtask

    task build_short_image;
        begin
            for (i = 0; i < 32; i = i + 1) begin
                memory[DATA_ADDR+i] = 0;
                memory[SCALE_ADDR+i] = 0;
            end
            memory[DATA_ADDR+0] = 8'h03;
            memory[DATA_ADDR+1] = 8'hc3;
            memory[DATA_ADDR+2] = (SCALE_BITS == 16) ? 8'h02 : 8'h00;
            memory[DATA_ADDR+3] = 8'h00;
            memory[DATA_ADDR+4] = 8'h01;
            memory[DATA_ADDR+5] = 8'h00;
            memory[DATA_ADDR+6] = 8'h01;
            memory[DATA_ADDR+7] = (SCALE_BITS == 16) ? 8'h02 : 8'h01;
            memory[DATA_ADDR+12] = 8'h5a;
            memory[SCALE_ADDR+0] = 8'h45;
            memory[SCALE_ADDR+1] = (SCALE_BITS == 16) ? 8'h23 : 8'h03;
            crc_work = 32'hffff_ffff;
            for (i = 0; i < 8; i = i + 1)
                crc_work = crc_byte(crc_work, memory[DATA_ADDR+i]);
            crc_work = crc_byte(crc_work, memory[DATA_ADDR+12]);
            crc_work = crc_byte(crc_work, memory[SCALE_ADDR+0]);
            crc_work = crc_byte(crc_work, memory[SCALE_ADDR+1]);
            crc_work = crc_work ^ 32'hffff_ffff;
            memory[DATA_ADDR+8] = crc_work[7:0];
            memory[DATA_ADDR+9] = crc_work[15:8];
            memory[DATA_ADDR+10] = crc_work[23:16];
            memory[DATA_ADDR+11] = crc_work[31:24];
        end
    endtask

    task configure_raw_max;
        begin
            cmd_page_index = 0;
            cmd_page_count = 1;
            cmd_token_base = 0;
            cmd_token_count = 128;
            cmd_expected_symbols = 16384;
            cmd_data_addr = DATA_ADDR;
            cmd_data_limit = DATA_ADDR + RAW_WINDOW_BYTES;
            cmd_page_window_bytes = RAW_WINDOW_BYTES;
            cmd_scale_addr = SCALE_ADDR;
            cmd_scale_slice_bytes = RAW_SCALE_BYTES;
            cmd_stream_is_v = (SCALE_BITS == 16);
        end
    endtask

    task build_raw_max_image;
        begin
            for (i = 0; i < RAW_WINDOW_BYTES; i = i + 1)
                memory[DATA_ADDR+i] = 0;
            for (i = 0; i < RAW_SCALE_BYTES; i = i + 1)
                memory[SCALE_ADDR+i] = ((i * 29) + 8'h31) & 8'hff;

            memory[DATA_ADDR+0] = 8'h03;
            memory[DATA_ADDR+1] = 8'hc3;
            memory[DATA_ADDR+2] = (SCALE_BITS == 16) ? 8'h03 : 8'h01;
            memory[DATA_ADDR+3] = 8'h7f;
            memory[DATA_ADDR+4] = RAW_PAYLOAD_BYTES & 8'hff;
            memory[DATA_ADDR+5] = (RAW_PAYLOAD_BYTES >> 8) & 8'hff;
            memory[DATA_ADDR+6] = 8'h01;
            memory[DATA_ADDR+7] = (SCALE_BITS == 16) ? 8'h02 : 8'h01;
            for (i = 0; i < RAW_PAYLOAD_BYTES; i = i + 1)
                memory[DATA_ADDR+12+i] = ((i * 13) + 8'h57) & 8'hff;

            crc_work = 32'hffff_ffff;
            for (i = 0; i < 8; i = i + 1)
                crc_work = crc_byte(crc_work, memory[DATA_ADDR+i]);
            for (i = 0; i < RAW_PAYLOAD_BYTES; i = i + 1)
                crc_work = crc_byte(crc_work, memory[DATA_ADDR+12+i]);
            for (i = 0; i < RAW_SCALE_BYTES; i = i + 1)
                crc_work = crc_byte(crc_work, memory[SCALE_ADDR+i]);
            crc_work = crc_work ^ 32'hffff_ffff;
            memory[DATA_ADDR+8] = crc_work[7:0];
            memory[DATA_ADDR+9] = crc_work[15:8];
            memory[DATA_ADDR+10] = crc_work[23:16];
            memory[DATA_ADDR+11] = crc_work[31:24];
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            model_active <= 1'b0;
            model_addr <= 0;
            model_beats <= 0;
            model_index <= 0;
            m_axi_rvalid <= 1'b0;
            m_axi_rdata <= 0;
            m_axi_rresp <= 0;
            m_axi_rlast <= 0;
            m_axi_rid <= 0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                if (model_active) begin
                    $display("FAIL second outstanding AXI burst");
                    errors = errors + 1;
                end
                if (m_axi_arid != 0 || m_axi_arsize != 3'd3 ||
                    m_axi_arburst != 2'b01 || m_axi_arlock != 0 ||
                    m_axi_arcache != 4'b0010 || m_axi_arprot != 0 ||
                    m_axi_arqos != 0 || m_axi_araddr[2:0] != 0 ||
                    m_axi_araddr[11:0] + ((m_axi_arlen+1)*8) > 4096) begin
                    $display("FAIL AXI request contract addr=%08x len=%0d",
                             m_axi_araddr, m_axi_arlen);
                    errors = errors + 1;
                end
                model_active <= 1'b1;
                model_addr <= m_axi_araddr;
                model_beats <= m_axi_arlen + 1;
                model_index <= 0;
            end

            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                if (m_axi_rlast)
                    model_active <= 1'b0;
                else
                    model_index <= model_index + 1;
            end

            if (model_active && !m_axi_rvalid) begin
                m_axi_rvalid <= 1'b1;
                m_axi_rdata <= memory_word(model_addr + model_index*8);
                m_axi_rid <= 0;
                m_axi_rresp <= inject_rresp ? 2'b10 : 2'b00;
                m_axi_rlast <= (model_index == model_beats-1);
            end
        end
    end

    // Sample one-cycle status pulses after nonblocking updates have settled.
    always @(negedge clk) begin
        if (!rst_n) begin
            commit_pulses = 0;
            abort_pulses = 0;
            error_pulses = 0;
        end else begin
            if (committed) begin
                commit_pulses = commit_pulses + 1;
                if (committed_task_tag != cmd_task_tag) begin
                    $display("FAIL committed tag");
                    errors = errors + 1;
                end
            end
            if (aborted) begin
                abort_pulses = abort_pulses + 1;
                seen_abort_tag = aborted_task_tag;
                seen_abort_page = aborted_page_index;
                seen_abort_stream = aborted_stream_is_v;
            end
            if (error_valid) begin
                error_pulses = error_pulses + 1;
                seen_error_source = error_source;
                seen_error_code = error_code;
                seen_error_phase = error_phase_is_scale;
                seen_error_tag = error_task_tag;
            end
            if (abort && (publish_valid || data_rd_valid || scale_rd_valid)) begin
                $display("FAIL abort did not hide publication/read data");
                errors = errors + 1;
            end
        end
    end

    task clear_seen;
        begin
            commit_pulses = 0;
            abort_pulses = 0;
            error_pulses = 0;
            seen_error_source = 0;
            seen_error_code = 0;
            seen_error_phase = 0;
            seen_error_tag = 0;
            seen_abort_tag = 0;
            seen_abort_page = 0;
            seen_abort_stream = 0;
        end
    endtask

    task issue_command;
        input [63:0] tag;
        begin
            timeout = 0;
            while (!cmd_ready && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!cmd_ready)
                $fatal(1, "command-ready timeout");
            cmd_task_tag = tag;
            cmd_valid = 1;
            @(negedge clk);
            cmd_valid = 0;
        end
    endtask

    task wait_publication;
        input [63:0] wanted_tag;
        input wanted_raw;
        input wanted_stream;
        input [7:0] wanted_tokens;
        input [14:0] wanted_symbols;
        input [15:0] wanted_payload;
        input [7:0] wanted_scale_format;
        input [13:0] wanted_record;
        input [13:0] wanted_window;
        input [8:0] wanted_scale_bytes;
        input [13:0] wanted_padding;
        begin
            timeout = 0;
            while (!publish_valid && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!publish_valid || slot_active || !busy || cmd_ready ||
                page_task_tag != wanted_tag || page_index != 0 ||
                page_count != 1 || page_token_base != 0 ||
                page_token_count != wanted_tokens ||
                page_expected_symbols != wanted_symbols ||
                page_raw_mode != wanted_raw ||
                page_stream_is_v != wanted_stream ||
                page_payload_bytes != wanted_payload ||
                page_scale_format_id != wanted_scale_format ||
                page_record_bytes != wanted_record ||
                page_window_bytes != wanted_window ||
                page_scale_slice_bytes != wanted_scale_bytes ||
                page_padding_bytes != wanted_padding) begin
                $display("FAIL publication tag=%016x scale_bits=%0d state=%0d validator=%0d reader=%0d",
                         wanted_tag, SCALE_BITS, dut.state,
                         dut.u_validator.state, dut.u_range_reader.state);
                errors = errors + 1;
            end
        end
    endtask

    task accept_publication;
        input [63:0] wanted_tag;
        begin
            publish_ready = 1;
            @(negedge clk);
            publish_ready = 0;
            if (!slot_active || publish_valid || !busy || cmd_ready ||
                !committed || committed_task_tag != wanted_tag) begin
                $display("FAIL publication accept tag=%016x active=%0d pulse=%0d",
                         wanted_tag, slot_active, committed);
                errors = errors + 1;
            end
            @(negedge clk);
            if (commit_pulses != 1) begin
                $display("FAIL publication pulse count tag=%016x count=%0d",
                         wanted_tag, commit_pulses);
                errors = errors + 1;
            end
        end
    endtask

    task release_active_slot;
        begin
            @(negedge clk);
            slot_release = 1;
            @(negedge clk);
            slot_release = 0;
            if (slot_active || busy || !cmd_ready || publish_valid) begin
                $display("FAIL release did not free active slot");
                errors = errors + 1;
            end
        end
    endtask

    task pulse_counter_clear;
        begin
            clear_counters = 1;
            @(negedge clk);
            clear_counters = 0;
            @(negedge clk);
        end
    endtask

    task reset_and_check_idle;
        begin
            rst_n = 0;
            publish_ready = 0;
            data_rd_en = 0;
            scale_rd_en = 0;
            abort = 0;
            repeat (2) @(negedge clk);
            if (busy || slot_active || publish_valid || data_rd_valid ||
                scale_rd_valid || m_axi_arvalid || m_axi_rvalid) begin
                $display("FAIL reset did not clear slot/transport state");
                errors = errors + 1;
            end
            rst_n = 1;
            @(negedge clk);
            if (!cmd_ready || busy || slot_active || publish_valid) begin
                $display("FAIL reset restart was not command-ready");
                errors = errors + 1;
            end
        end
    endtask

    task wait_error;
        input [1:0] wanted_source;
        input [7:0] wanted_code;
        input [63:0] wanted_tag;
        input wanted_phase;
        begin
            timeout = 0;
            while (error_pulses == 0 && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (error_pulses != 1 || seen_error_source != wanted_source ||
                seen_error_code != wanted_code || seen_error_tag != wanted_tag ||
                seen_error_phase != wanted_phase) begin
                $display("FAIL error got count=%0d source=%0d code=%02x phase=%0d tag=%016x want=%0d/%02x/%0d/%016x",
                         error_pulses, seen_error_source, seen_error_code,
                         seen_error_phase, seen_error_tag, wanted_source,
                         wanted_code, wanted_phase, wanted_tag);
                errors = errors + 1;
            end
            timeout = 0;
            while (!cmd_ready && timeout < WATCHDOG) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!cmd_ready || publish_valid || slot_active) begin
                $display("FAIL fault did not retire privately");
                errors = errors + 1;
            end
        end
    endtask

    task read_data_word;
        input integer word_index;
        input [31:0] expected;
        input expected_last;
        begin
            @(negedge clk);
            data_rd_word_addr = word_index;
            data_rd_en = 1;
            @(negedge clk);
            data_rd_en = 0;
            if (!data_rd_valid || data_rd_data !== expected ||
                data_rd_byte_valid !== 4'hf ||
                data_rd_last !== expected_last ||
                data_rd_byte_offset !== word_index*4) begin
                $display("FAIL data scratch word=%0d valid=%0d data=%08x/%08x mask=%x last=%0d offset=%0d",
                         word_index, data_rd_valid, data_rd_data, expected,
                         data_rd_byte_valid, data_rd_last,
                         data_rd_byte_offset);
                errors = errors + 1;
            end
            @(negedge clk);
            if (data_rd_valid) begin
                $display("FAIL data read valid was not one cycle");
                errors = errors + 1;
            end
        end
    endtask

    task read_scale_word_at;
        input integer word_index;
        input [31:0] expected;
        input [3:0] expected_mask;
        input expected_last;
        begin
            @(negedge clk);
            scale_rd_word_addr = word_index;
            scale_rd_en = 1;
            @(negedge clk);
            scale_rd_en = 0;
            if (!scale_rd_valid || scale_rd_data !== expected ||
                scale_rd_byte_valid !== expected_mask ||
                scale_rd_last !== expected_last ||
                scale_rd_byte_offset !== word_index*4) begin
                $display("FAIL scale scratch word=%0d valid=%0d data=%08x/%08x mask=%x/%x last=%0d/%0d offset=%0d",
                         word_index, scale_rd_valid, scale_rd_data, expected,
                         scale_rd_byte_valid, expected_mask, scale_rd_last,
                         expected_last, scale_rd_byte_offset);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    task read_data_out_of_range;
        input integer word_index;
        begin
            @(negedge clk);
            data_rd_word_addr = word_index;
            data_rd_en = 1;
            @(negedge clk);
            data_rd_en = 0;
            if (data_rd_valid) begin
                $display("FAIL stale data word visible at %0d", word_index);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    task read_scale_out_of_range;
        input integer word_index;
        begin
            @(negedge clk);
            scale_rd_word_addr = word_index;
            scale_rd_en = 1;
            @(negedge clk);
            scale_rd_en = 0;
            if (scale_rd_valid) begin
                $display("FAIL stale scale word visible at %0d", word_index);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        for (i = 0; i < 65536; i = i + 1)
            memory[i] = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // A short page begins at 0xff8, so its two data beats prove that the
        // HP reader splits rather than crossing the 4 KiB boundary.
        configure_short();
        build_short_image();
        @(negedge clk);
        clear_seen();
        publish_ready = 0;
        issue_command(TAG_GOOD);
        wait_publication(TAG_GOOD, 1'b0, (SCALE_BITS == 16), 1, 128,
                         1, ((SCALE_BITS == 16) ? 2 : 1),
                         13, 16, 2, 3);
        repeat (3) begin
            @(negedge clk);
            if (!publish_valid || slot_active || data_rd_valid || scale_rd_valid)
                errors = errors + 1;
        end
        accept_publication(TAG_GOOD);
        if (read_beats != 3 || burst_count != 3 ||
            data_scratch_bytes != 16 || scale_scratch_bytes != 2 ||
            committed_pages != 1) begin
            $display("FAIL short counters beats=%0d bursts=%0d data=%0d scale=%0d pages=%0d",
                     read_beats, burst_count, data_scratch_bytes,
                     scale_scratch_bytes, committed_pages);
            errors = errors + 1;
        end
        read_data_word(0, memory_word32(DATA_ADDR+0), 0);
        read_data_word(1, memory_word32(DATA_ADDR+4), 0);
        read_data_word(2, memory_word32(DATA_ADDR+8), 0);
        read_data_word(3, memory_word32(DATA_ADDR+12), 1);
        read_scale_word_at(0, memory_word32(SCALE_ADDR), 4'h3, 1);
        release_active_slot();

        // Full 128-token RAW K4/S12 or RAW V5/S16 page.  These are the exact
        // maximum scheduler windows and scale slices for the selected profile.
        configure_raw_max();
        build_raw_max_image();
        pulse_counter_clear();
        clear_seen();
        issue_command(TAG_RAW_MAX);
        wait_publication(TAG_RAW_MAX, 1'b1, (SCALE_BITS == 16), 128,
                         16384, RAW_PAYLOAD_BYTES,
                         ((SCALE_BITS == 16) ? 2 : 1),
                         RAW_PAYLOAD_BYTES + 12, RAW_WINDOW_BYTES,
                         RAW_SCALE_BYTES, 4);
        accept_publication(TAG_RAW_MAX);
        if (read_beats != RAW_DATA_BEATS + RAW_SCALE_BEATS ||
            burst_count != RAW_BURSTS ||
            data_scratch_bytes != RAW_WINDOW_BYTES ||
            scale_scratch_bytes != RAW_SCALE_BYTES ||
            committed_pages != 1) begin
            $display("FAIL RAW max counters bits=%0d beats=%0d/%0d bursts=%0d/%0d data=%0d scale=%0d pages=%0d",
                     SCALE_BITS, read_beats,
                     RAW_DATA_BEATS + RAW_SCALE_BEATS,
                     burst_count, RAW_BURSTS, data_scratch_bytes,
                     scale_scratch_bytes, committed_pages);
            errors = errors + 1;
        end
        read_data_word(0, memory_word32(DATA_ADDR), 0);
        read_data_word(RAW_WINDOW_BYTES/8,
                       memory_word32(DATA_ADDR+(RAW_WINDOW_BYTES/8)*4), 0);
        read_data_word((RAW_WINDOW_BYTES/4)-1,
                       memory_word32(DATA_ADDR+RAW_WINDOW_BYTES-4), 1);
        read_scale_word_at(0, memory_word32(SCALE_ADDR), 4'hf, 0);
        read_scale_word_at((RAW_SCALE_BYTES/4)-1,
                           memory_word32(SCALE_ADDR+RAW_SCALE_BYTES-4),
                           4'hf, 1);
        release_active_slot();

        // A short refill after the maximum page must hide every stale word
        // outside the newly committed logical lengths.
        configure_short();
        build_short_image();
        clear_seen();
        issue_command(TAG_SHORT_AFTER_LONG);
        wait_publication(TAG_SHORT_AFTER_LONG, 1'b0, (SCALE_BITS == 16),
                         1, 128, 1, ((SCALE_BITS == 16) ? 2 : 1),
                         13, 16, 2, 3);
        accept_publication(TAG_SHORT_AFTER_LONG);
        read_data_word(3, memory_word32(DATA_ADDR+12), 1);
        read_data_out_of_range(4);
        read_scale_word_at(0, memory_word32(SCALE_ADDR), 4'h3, 1);
        read_scale_out_of_range(1);

        // Abort owns priority over an active slot and a coincident registered
        // read.  It hides both immediately, then reports the committed tag.
        clear_seen();
        @(negedge clk);
        data_rd_word_addr = 0;
        data_rd_en = 1;
        @(negedge clk);
        data_rd_en = 0;
        if (!data_rd_valid)
            $fatal(1, "active-slot read was not established before abort");
        abort = 1;
        #1;
        if (slot_active || publish_valid || data_rd_valid || scale_rd_valid ||
            cmd_ready)
            $fatal(1, "active-slot abort visibility gate failed");
        @(negedge clk);
        abort = 0;
        timeout = 0;
        while (abort_pulses == 0 && timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (abort_pulses != 1 ||
            seen_abort_tag != TAG_SHORT_AFTER_LONG ||
            seen_abort_page != 0 ||
            seen_abort_stream != (SCALE_BITS == 16) ||
            error_pulses != 0 || slot_active || publish_valid || !cmd_ready) begin
            $display("FAIL active abort count=%0d tag=%016x page=%0d stream=%0d errors=%0d ready=%0d",
                     abort_pulses, seen_abort_tag, seen_abort_page,
                     seen_abort_stream, error_pulses, cmd_ready);
            errors = errors + 1;
        end

        // CRC failure leaves all tentative bytes private.
        configure_short();
        build_short_image();
        memory[DATA_ADDR+12] = memory[DATA_ADDR+12] ^ 8'h01;
        clear_seen();
        issue_command(TAG_CRC);
        wait_error(SOURCE_VALIDATOR, ERR_HEADER_CRC, TAG_CRC, 1'b1);

        // AXI RRESP failure preserves the reader error namespace and phase.
        configure_short();
        build_short_image();
        inject_rresp = 1;
        clear_seen();
        issue_command(TAG_AXI);
        wait_error(SOURCE_READER, ERR_RRESP, TAG_AXI, 1'b0);
        inject_rresp = 0;

        // A cancelled stalled AR remains stable through eventual acceptance;
        // the reader drains its owned response before the slot retires.
        configure_short();
        build_short_image();
        allow_ar = 0;
        clear_seen();
        issue_command(TAG_ABORT);
        timeout = 0;
        while (!m_axi_arvalid && timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!m_axi_arvalid)
            $fatal(1, "stalled AR was never presented");
        held_araddr = m_axi_araddr;
        held_arlen = m_axi_arlen;
        abort = 1;
        #1;
        if (publish_valid || slot_active || data_rd_valid || scale_rd_valid)
            $fatal(1, "abort visibility gate failed");
        @(negedge clk);
        abort = 0;
        repeat (3) begin
            @(negedge clk);
            if (!m_axi_arvalid || m_axi_araddr != held_araddr ||
                m_axi_arlen != held_arlen) begin
                $display("FAIL poisoned AR was withdrawn or changed");
                errors = errors + 1;
            end
        end
        allow_ar = 1;
        timeout = 0;
        while (abort_pulses == 0 && timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (abort_pulses != 1 || seen_abort_tag != TAG_ABORT ||
            error_pulses != 0 || slot_active || publish_valid) begin
            $display("FAIL poisoned-AR abort count=%0d tag=%016x errors=%0d",
                     abort_pulses, seen_abort_tag, error_pulses);
            errors = errors + 1;
        end
        timeout = 0;
        while (!cmd_ready && timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!cmd_ready)
            errors = errors + 1;

        // Reset after at least one tentative data word, then restart from a
        // clean command boundary and prove the same slot can publish again.
        configure_short();
        build_short_image();
        pulse_counter_clear();
        clear_seen();
        issue_command(TAG_RESET_DATA);
        timeout = 0;
        while (!((dut.state == 4'd3) && data_scratch_bytes >= 4 &&
                 data_scratch_bytes < 16) && timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= WATCHDOG)
            $fatal(1, "mid-data reset point was not reached");
        reset_and_check_idle();
        configure_short();
        build_short_image();
        clear_seen();
        issue_command(TAG_RESTART_DATA);
        wait_publication(TAG_RESTART_DATA, 1'b0, (SCALE_BITS == 16),
                         1, 128, 1, ((SCALE_BITS == 16) ? 2 : 1),
                         13, 16, 2, 3);
        accept_publication(TAG_RESTART_DATA);
        read_data_word(3, memory_word32(DATA_ADDR+12), 1);
        release_active_slot();

        // Reset after the data range completes but while the scale range is
        // in flight, then restart and verify both scratch regions republish.
        configure_short();
        build_short_image();
        pulse_counter_clear();
        clear_seen();
        issue_command(TAG_RESET_SCALE);
        timeout = 0;
        while (!((dut.state == 4'd5) && transport_busy &&
                 data_scratch_bytes == 16) && timeout < WATCHDOG) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= WATCHDOG)
            $fatal(1, "mid-scale reset point was not reached");
        reset_and_check_idle();
        configure_short();
        build_short_image();
        clear_seen();
        issue_command(TAG_RESTART_SCALE);
        wait_publication(TAG_RESTART_SCALE, 1'b0, (SCALE_BITS == 16),
                         1, 128, 1, ((SCALE_BITS == 16) ? 2 : 1),
                         13, 16, 2, 3);
        accept_publication(TAG_RESTART_SCALE);
        read_data_word(3, memory_word32(DATA_ADDR+12), 1);
        read_scale_word_at(0, memory_word32(SCALE_ADDR), 4'h3, 1);
        release_active_slot();

        if (errors == 0) begin
            $display("TB PASS: page prefetch slot SCALE_BITS=%0d", SCALE_BITS);
            if (SCALE_BITS == 12)
                $display("KV_V03_PAGE_PREFETCH_SLOT_SCALE12_PASS");
            else
                $display("KV_V03_PAGE_PREFETCH_SLOT_SCALE16_PASS");
            $finish;
        end
        $fatal(1, "TB FAIL: page prefetch slot SCALE_BITS=%0d errors=%0d",
               SCALE_BITS, errors);
    end
endmodule

`default_nettype wire
