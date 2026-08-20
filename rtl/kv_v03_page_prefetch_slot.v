// kv_v03_page_prefetch_slot.v -- one fail-closed Zybo HP64 page scratch slot.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// This block is deliberately one slot, not the ping-pong scheduler.  It owns
// one HP64 reader, sequences the page-data and scale ranges, converts the
// reader's 64-bit stream to the validator's logical 32-bit stream, and keeps
// all accepted bytes private until both transport and record validation pass.
// A publish handshake transfers ownership of the committed scratch image; the
// slot cannot be overwritten until release.  No profile field or decoder
// semantic is invented here.
module kv_v03_page_prefetch_slot #(
    parameter integer ADDR_WIDTH       = 32,
    parameter integer ID_WIDTH         = 1,
    parameter integer TAG_WIDTH        = 64,
    parameter integer SCALE_BITS       = 12,
    parameter integer COMPILED_CODEBOOK_ID = 1,
    parameter integer TIMEOUT_CYCLES   = 65536,
    parameter integer MAX_PAGE_BYTES   = 10256,
    parameter integer MAX_SCALE_BYTES  = 256
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // Directly compatible with one 32-bit-address scheduler descriptor.
    input  wire                     cmd_valid,
    output wire                     cmd_ready,
    input  wire [4:0]               cmd_page_index,
    input  wire [5:0]               cmd_page_count,
    input  wire [12:0]              cmd_token_base,
    input  wire [7:0]               cmd_token_count,
    input  wire [14:0]              cmd_expected_symbols,
    input  wire [ADDR_WIDTH-1:0]    cmd_data_addr,
    input  wire [ADDR_WIDTH-1:0]    cmd_data_limit,
    input  wire [31:0]              cmd_page_window_bytes,
    input  wire [ADDR_WIDTH-1:0]    cmd_scale_addr,
    input  wire [8:0]               cmd_scale_slice_bytes,
    input  wire                     cmd_stream_is_v,
    input  wire [TAG_WIDTH-1:0]     cmd_task_tag,
    input  wire                     abort,

    // Publication is an ownership transfer.  Scratch reads become visible
    // only after publish_valid && publish_ready.  slot_release retires it
    // and is required before another command can be accepted.
    output wire                     publish_valid,
    input  wire                     publish_ready,
    input  wire                     slot_release,
    output wire                     slot_active,
    output wire                     busy,

    output wire [TAG_WIDTH-1:0]     page_task_tag,
    output wire [4:0]               page_index,
    output wire [5:0]               page_count,
    output wire [12:0]              page_token_base,
    output wire [7:0]               page_token_count,
    output wire [14:0]              page_expected_symbols,
    output wire                     page_raw_mode,
    output wire                     page_stream_is_v,
    output wire [15:0]              page_payload_bytes,
    output wire [7:0]               page_scale_format_id,
    output wire [13:0]              page_record_bytes,
    output wire [13:0]              page_window_bytes,
    output wire [8:0]               page_scale_slice_bytes,
    output wire [13:0]              page_padding_bytes,

    // Synchronous committed-scratch read ports.  Word addresses are logical
    // offsets divided by four.  Invalid/out-of-range requests return no valid
    // pulse.  The byte-valid mask makes final partial words explicit.
    input  wire                     data_rd_en,
    input  wire [11:0]              data_rd_word_addr,
    output wire                     data_rd_valid,
    output reg  [31:0]              data_rd_data,
    output reg  [3:0]               data_rd_byte_valid,
    output reg                      data_rd_last,
    output reg  [13:0]              data_rd_byte_offset,

    input  wire                     scale_rd_en,
    input  wire [6:0]               scale_rd_word_addr,
    output wire                     scale_rd_valid,
    output reg  [31:0]              scale_rd_data,
    output reg  [3:0]               scale_rd_byte_valid,
    output reg                      scale_rd_last,
    output reg  [8:0]               scale_rd_byte_offset,

    output reg                      committed,
    output reg  [TAG_WIDTH-1:0]     committed_task_tag,
    output reg                      aborted,
    output reg  [TAG_WIDTH-1:0]     aborted_task_tag,
    output reg  [4:0]               aborted_page_index,
    output reg                      aborted_stream_is_v,

    // error_source: 1=slot/adapter, 2=HP64 reader, 3=validator.  Child error
    // codes are preserved verbatim; error_phase_is_scale disambiguates the
    // reused reader.
    output reg                      error_valid,
    output reg  [1:0]               error_source,
    output reg  [7:0]               error_code,
    output reg                      error_phase_is_scale,
    output reg  [TAG_WIDTH-1:0]     error_task_tag,
    output reg  [4:0]               error_page_index,
    output reg                      error_stream_is_v,

    input  wire                     clear_counters,
    output wire [31:0]              read_beats,
    output wire [31:0]              burst_count,
    output wire [31:0]              ar_stall_cycles,
    output wire [31:0]              r_wait_cycles,
    output wire [31:0]              output_stall_cycles,
    output reg  [31:0]              data_scratch_bytes,
    output reg  [31:0]              scale_scratch_bytes,
    output reg  [31:0]              committed_pages,
    output reg  [31:0]              failed_pages,
    output reg  [31:0]              aborted_pages,
    output wire                     transport_busy,
    output wire                     transport_draining,

    output wire [ID_WIDTH-1:0]      m_axi_arid,
    output wire [ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [7:0]               m_axi_arlen,
    output wire [2:0]               m_axi_arsize,
    output wire [1:0]               m_axi_arburst,
    output wire                     m_axi_arlock,
    output wire [3:0]               m_axi_arcache,
    output wire [2:0]               m_axi_arprot,
    output wire [3:0]               m_axi_arqos,
    output wire                     m_axi_arvalid,
    input  wire                     m_axi_arready,

    input  wire [ID_WIDTH-1:0]      m_axi_rid,
    input  wire [63:0]              m_axi_rdata,
    input  wire [1:0]               m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire                     m_axi_rvalid,
    output wire                     m_axi_rready
);
    localparam integer DATA_WORDS  = (MAX_PAGE_BYTES + 3) / 4;
    localparam integer SCALE_WORDS = (MAX_SCALE_BYTES + 3) / 4;

    localparam [3:0] ST_IDLE         = 4'd0,
                     ST_VALIDATE     = 4'd1,
                     ST_DATA_CMD     = 4'd2,
                     ST_DATA_STREAM  = 4'd3,
                     ST_SCALE_CMD    = 4'd4,
                     ST_SCALE_STREAM = 4'd5,
                     ST_VERIFY       = 4'd6,
                     ST_FAIL_WAIT    = 4'd7,
                     ST_ABORT_WAIT   = 4'd8,
                     ST_ACTIVE       = 4'd9;

    localparam [1:0] ERROR_SOURCE_SLOT      = 2'd1;
    localparam [1:0] ERROR_SOURCE_READER    = 2'd2;
    localparam [1:0] ERROR_SOURCE_VALIDATOR = 2'd3;

    localparam [7:0] ERR_DATA_LIMIT     = 8'h01;
    localparam [7:0] ERR_ADAPTER        = 8'h02;
    localparam [7:0] ERR_CHILD_TAG      = 8'h03;
    localparam [7:0] ERR_CHILD_PROTOCOL = 8'h04;

    reg [3:0] state;
    reg half_upper;

    reg [4:0] page_index_reg;
    reg [5:0] page_count_reg;
    reg [12:0] token_base_reg;
    reg [7:0] token_count_reg;
    reg [14:0] expected_symbols_reg;
    reg [ADDR_WIDTH-1:0] data_addr_reg;
    reg [13:0] page_window_reg;
    reg [ADDR_WIDTH-1:0] scale_addr_reg;
    reg [8:0] scale_slice_reg;
    reg stream_is_v_reg;
    reg [TAG_WIDTH-1:0] task_tag_reg;

    reg [TAG_WIDTH-1:0] committed_tag_reg;
    reg [4:0] committed_page_index_reg;
    reg [5:0] committed_page_count_reg;
    reg [12:0] committed_token_base_reg;
    reg [7:0] committed_token_count_reg;
    reg [14:0] committed_expected_symbols_reg;
    reg committed_raw_mode_reg;
    reg committed_stream_is_v_reg;
    reg [15:0] committed_payload_bytes_reg;
    reg [7:0] committed_scale_format_reg;
    reg [13:0] committed_record_bytes_reg;
    reg [13:0] committed_window_bytes_reg;
    reg [8:0] committed_scale_bytes_reg;
    reg [13:0] committed_padding_bytes_reg;

    (* ram_style = "block" *) reg [31:0] data_scratch [0:DATA_WORDS-1];
    (* ram_style = "distributed" *) reg [3:0] data_scratch_mask [0:DATA_WORDS-1];
    (* ram_style = "block" *) reg [31:0] scale_scratch [0:SCALE_WORDS-1];
    (* ram_style = "distributed" *) reg [3:0] scale_scratch_mask [0:SCALE_WORDS-1];

    function valid_keep8;
        input [7:0] keep;
        begin
            valid_keep8 = (keep == 8'h01) || (keep == 8'h03) ||
                          (keep == 8'h07) || (keep == 8'h0f) ||
                          (keep == 8'h1f) || (keep == 8'h3f) ||
                          (keep == 8'h7f) || (keep == 8'hff);
        end
    endfunction

    function [3:0] keep8_count;
        input [7:0] keep;
        begin
            case (keep)
                8'h01: keep8_count = 4'd1;
                8'h03: keep8_count = 4'd2;
                8'h07: keep8_count = 4'd3;
                8'h0f: keep8_count = 4'd4;
                8'h1f: keep8_count = 4'd5;
                8'h3f: keep8_count = 4'd6;
                8'h7f: keep8_count = 4'd7;
                8'hff: keep8_count = 4'd8;
                default: keep8_count = 4'd0;
            endcase
        end
    endfunction

    function [2:0] keep4_count;
        input [3:0] keep;
        begin
            case (keep)
                4'h1: keep4_count = 3'd1;
                4'h3: keep4_count = 3'd2;
                4'h7: keep4_count = 3'd3;
                4'hf: keep4_count = 3'd4;
                default: keep4_count = 3'd0;
            endcase
        end
    endfunction

    wire [32:0] cmd_data_end_ext = {1'b0, cmd_data_addr} +
                                           {1'b0, cmd_page_window_bytes};
    wire local_cmd_bad = cmd_data_end_ext[32] ||
                         (cmd_data_end_ext[ADDR_WIDTH-1:0] != cmd_data_limit);

    wire validator_cmd_ready;
    wire validator_cmd_valid;
    wire validator_busy;
    wire validator_aborted;
    wire [TAG_WIDTH-1:0] validator_aborted_tag;
    wire [4:0] validator_aborted_page;
    wire validator_aborted_stream;
    wire validator_error_valid;
    wire [7:0] validator_error_code;
    wire [TAG_WIDTH-1:0] validator_error_tag;
    wire [4:0] validator_error_page;
    wire validator_error_stream;

    wire validator_data_ready;
    wire validator_scale_ready;
    wire validator_verified_valid;
    wire validator_verified_ready;
    wire [TAG_WIDTH-1:0] validator_verified_tag;
    wire [4:0] validator_verified_page;
    wire [5:0] validator_verified_page_count;
    wire [12:0] validator_verified_token_base;
    wire [7:0] validator_verified_token_count;
    wire [14:0] validator_verified_symbols;
    wire validator_verified_raw;
    wire validator_verified_stream;
    wire [15:0] validator_verified_payload;
    wire [7:0] validator_verified_scale_format;
    wire [13:0] validator_verified_record;
    wire [13:0] validator_verified_window;
    wire [8:0] validator_verified_scale_bytes;
    wire [13:0] validator_verified_padding;

    wire reader_cmd_ready;
    wire reader_cmd_valid;
    wire [ADDR_WIDTH-1:0] reader_cmd_addr;
    wire [13:0] reader_cmd_bytes;
    wire reader_abort;
    wire reader_data_valid;
    wire reader_data_ready;
    wire [63:0] reader_data;
    wire [7:0] reader_data_keep;
    wire reader_data_last;
    wire [13:0] reader_data_offset;
    wire [TAG_WIDTH-1:0] reader_data_tag;
    wire reader_busy;
    wire reader_draining;
    wire reader_done;
    wire [TAG_WIDTH-1:0] reader_done_tag;
    wire reader_aborted;
    wire [TAG_WIDTH-1:0] reader_aborted_tag;
    wire reader_error_valid;
    wire [7:0] reader_error_code;
    wire [TAG_WIDTH-1:0] reader_error_tag;

    assign slot_active = (state == ST_ACTIVE) && !abort;
    assign busy = (state != ST_IDLE);
    assign transport_busy = reader_busy;
    assign transport_draining = reader_draining;

    assign cmd_ready = (state == ST_IDLE) && validator_cmd_ready &&
                       reader_cmd_ready && !abort;
    wire cmd_fire = cmd_valid && cmd_ready;
    assign validator_cmd_valid = cmd_fire && !local_cmd_bad;

    assign reader_cmd_valid = ((state == ST_DATA_CMD) ||
                               (state == ST_SCALE_CMD)) && !abort;
    assign reader_cmd_addr = (state == ST_SCALE_CMD) ? scale_addr_reg :
                                                            data_addr_reg;
    assign reader_cmd_bytes = (state == ST_SCALE_CMD) ?
                              {5'b0, scale_slice_reg} : page_window_reg;

    wire stream_is_scale = (state == ST_SCALE_STREAM);
    wire stream_active = (state == ST_DATA_STREAM) || stream_is_scale;
    wire [13:0] phase_bytes = stream_is_scale ?
                             {5'b0, scale_slice_reg} : page_window_reg;
    wire [3:0] reader_bytes = keep8_count(reader_data_keep);
    wire [14:0] reader_end_offset = {1'b0, reader_data_offset} +
                                           {11'b0, reader_bytes};
    wire reader_frame_bad = reader_data_valid && stream_active &&
        ((reader_data_tag != task_tag_reg) ||
         !valid_keep8(reader_data_keep) ||
         (reader_data_offset[2:0] != 3'b000) ||
         (reader_end_offset > {1'b0, phase_bytes}) ||
         (reader_data_last !=
          (reader_end_offset == {1'b0, phase_bytes})));

    wire reader_upper_present = |reader_data_keep[7:4];
    wire [31:0] logical_data = half_upper ? reader_data[63:32] :
                                                   reader_data[31:0];
    wire [3:0] logical_keep = half_upper ? reader_data_keep[7:4] :
                                                  reader_data_keep[3:0];
    wire [13:0] logical_offset = reader_data_offset +
                                 (half_upper ? 14'd4 : 14'd0);
    wire logical_last = reader_data_last &&
                        (half_upper || !reader_upper_present);
    wire logical_ready = stream_is_scale ? validator_scale_ready :
                                                    validator_data_ready;
    wire child_fault_gate = reader_error_valid || validator_error_valid;
    wire logical_valid = reader_data_valid && stream_active && !abort &&
                         !reader_frame_bad && !child_fault_gate;
    wire logical_fire = logical_valid && logical_ready;

    // Do not consume the 64-bit reader beat after its lower word when an
    // upper word exists.  On the final logical half, reader and validator
    // handshakes are atomic.
    assign reader_data_ready = stream_active && !abort && !reader_frame_bad &&
                               !child_fault_gate && logical_ready &&
                               (half_upper || !reader_upper_present);

    wire validator_data_valid = logical_valid && (state == ST_DATA_STREAM);
    wire validator_scale_valid = logical_valid &&
                                  (state == ST_SCALE_STREAM);

    assign reader_abort = abort || reader_frame_bad || validator_error_valid;
    wire validator_abort = abort || reader_frame_bad || reader_error_valid;

    kv_v03_hp64_range_reader #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .TAG_WIDTH(TAG_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .MAX_BYTES(MAX_PAGE_BYTES)
    ) u_range_reader (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(reader_cmd_valid),
        .cmd_ready(reader_cmd_ready),
        .cmd_addr(reader_cmd_addr),
        .cmd_bytes(reader_cmd_bytes),
        .cmd_tag(task_tag_reg),
        .abort(reader_abort),
        .data_valid(reader_data_valid),
        .data_ready(reader_data_ready),
        .data(reader_data),
        .data_keep(reader_data_keep),
        .data_last(reader_data_last),
        .data_byte_offset(reader_data_offset),
        .data_tag(reader_data_tag),
        .busy(reader_busy),
        .draining(reader_draining),
        .done(reader_done),
        .done_tag(reader_done_tag),
        .aborted(reader_aborted),
        .aborted_tag(reader_aborted_tag),
        .error_valid(reader_error_valid),
        .error_code(reader_error_code),
        .error_tag(reader_error_tag),
        .clear_counters(clear_counters),
        .read_beats(read_beats),
        .burst_count(burst_count),
        .ar_stall_cycles(ar_stall_cycles),
        .r_wait_cycles(r_wait_cycles),
        .output_stall_cycles(output_stall_cycles),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    kv_v03_page128_record_validator #(
        .TAG_WIDTH(TAG_WIDTH),
        .SCALE_BITS(SCALE_BITS),
        .COMPILED_CODEBOOK_ID(COMPILED_CODEBOOK_ID),
        .MAX_PAGE_BYTES(MAX_PAGE_BYTES)
    ) u_validator (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(validator_cmd_valid),
        .cmd_ready(validator_cmd_ready),
        .cmd_page_index(cmd_page_index),
        .cmd_page_count(cmd_page_count),
        .cmd_token_base(cmd_token_base),
        .cmd_token_count(cmd_token_count),
        .cmd_expected_symbols(cmd_expected_symbols),
        .cmd_page_window_bytes(cmd_page_window_bytes),
        .cmd_scale_slice_bytes(cmd_scale_slice_bytes),
        .cmd_stream_is_v(cmd_stream_is_v),
        .cmd_task_tag(cmd_task_tag),
        .abort(validator_abort),
        .data_valid(validator_data_valid),
        .data_ready(validator_data_ready),
        .data_data(logical_data),
        .data_byte_valid(logical_keep),
        .data_last(logical_last),
        .data_byte_offset(logical_offset),
        .data_task_tag(task_tag_reg),
        .data_page_index(page_index_reg),
        .data_stream_is_v(stream_is_v_reg),
        .scale_valid(validator_scale_valid),
        .scale_ready(validator_scale_ready),
        .scale_data(logical_data),
        .scale_byte_valid(logical_keep),
        .scale_last(logical_last),
        .scale_byte_offset(logical_offset),
        .scale_task_tag(task_tag_reg),
        .scale_page_index(page_index_reg),
        .scale_stream_is_v(stream_is_v_reg),
        .verified_valid(validator_verified_valid),
        .verified_ready(validator_verified_ready),
        .verified_task_tag(validator_verified_tag),
        .verified_page_index(validator_verified_page),
        .verified_page_count(validator_verified_page_count),
        .verified_token_base(validator_verified_token_base),
        .verified_token_count(validator_verified_token_count),
        .verified_expected_symbols(validator_verified_symbols),
        .verified_raw_mode(validator_verified_raw),
        .verified_stream_is_v(validator_verified_stream),
        .verified_payload_bytes(validator_verified_payload),
        .verified_scale_format_id(validator_verified_scale_format),
        .verified_record_bytes(validator_verified_record),
        .verified_page_window_bytes(validator_verified_window),
        .verified_scale_slice_bytes(validator_verified_scale_bytes),
        .verified_padding_bytes(validator_verified_padding),
        .busy(validator_busy),
        .aborted(validator_aborted),
        .aborted_task_tag(validator_aborted_tag),
        .aborted_page_index(validator_aborted_page),
        .aborted_stream_is_v(validator_aborted_stream),
        .error_valid(validator_error_valid),
        .error_code(validator_error_code),
        .error_task_tag(validator_error_tag),
        .error_page_index(validator_error_page),
        .error_stream_is_v(validator_error_stream)
    );

    wire verified_identity_bad = validator_verified_valid &&
        ((validator_verified_tag != task_tag_reg) ||
         (validator_verified_page != page_index_reg) ||
         (validator_verified_stream != stream_is_v_reg));

    assign publish_valid = (state == ST_VERIFY) &&
                           validator_verified_valid &&
                           !verified_identity_bad && !abort;
    assign validator_verified_ready = publish_valid && publish_ready;
    wire publish_fire = publish_valid && publish_ready;

    assign page_task_tag = slot_active ? committed_tag_reg :
                                          validator_verified_tag;
    assign page_index = slot_active ? committed_page_index_reg :
                                      validator_verified_page;
    assign page_count = slot_active ? committed_page_count_reg :
                                      validator_verified_page_count;
    assign page_token_base = slot_active ? committed_token_base_reg :
                                           validator_verified_token_base;
    assign page_token_count = slot_active ? committed_token_count_reg :
                                            validator_verified_token_count;
    assign page_expected_symbols = slot_active ?
        committed_expected_symbols_reg : validator_verified_symbols;
    assign page_raw_mode = slot_active ? committed_raw_mode_reg :
                                         validator_verified_raw;
    assign page_stream_is_v = slot_active ? committed_stream_is_v_reg :
                                            validator_verified_stream;
    assign page_payload_bytes = slot_active ? committed_payload_bytes_reg :
                                              validator_verified_payload;
    assign page_scale_format_id = slot_active ? committed_scale_format_reg :
                                                validator_verified_scale_format;
    assign page_record_bytes = slot_active ? committed_record_bytes_reg :
                                             validator_verified_record;
    assign page_window_bytes = slot_active ? committed_window_bytes_reg :
                                             validator_verified_window;
    assign page_scale_slice_bytes = slot_active ? committed_scale_bytes_reg :
                                                  validator_verified_scale_bytes;
    assign page_padding_bytes = slot_active ? committed_padding_bytes_reg :
                                              validator_verified_padding;

    wire [12:0] active_data_words =
        ({1'b0, committed_window_bytes_reg} + 14'd3) >> 2;
    wire [7:0] active_scale_words =
        ({1'b0, committed_scale_bytes_reg} + 10'd3) >> 2;
    reg data_rd_valid_reg;
    reg scale_rd_valid_reg;
    assign data_rd_valid = data_rd_valid_reg && slot_active && !abort;
    assign scale_rd_valid = scale_rd_valid_reg && slot_active && !abort;

    always @(posedge clk) begin
        if (!rst_n) begin
            data_rd_valid_reg <= 1'b0;
            data_rd_data <= 32'b0;
            data_rd_byte_valid <= 4'b0;
            data_rd_last <= 1'b0;
            data_rd_byte_offset <= 14'b0;
            scale_rd_valid_reg <= 1'b0;
            scale_rd_data <= 32'b0;
            scale_rd_byte_valid <= 4'b0;
            scale_rd_last <= 1'b0;
            scale_rd_byte_offset <= 9'b0;
        end else begin
            data_rd_valid_reg <= 1'b0;
            scale_rd_valid_reg <= 1'b0;
            if (!abort && !slot_release && state == ST_ACTIVE && data_rd_en &&
                ({1'b0, data_rd_word_addr} < active_data_words)) begin
                data_rd_valid_reg <= 1'b1;
                data_rd_data <= data_scratch[data_rd_word_addr];
                data_rd_byte_valid <= data_scratch_mask[data_rd_word_addr];
                data_rd_last <= ({1'b0, data_rd_word_addr} + 13'd1 ==
                                 active_data_words);
                data_rd_byte_offset <= {data_rd_word_addr, 2'b00};
            end
            if (!abort && !slot_release && state == ST_ACTIVE && scale_rd_en &&
                ({1'b0, scale_rd_word_addr} < active_scale_words)) begin
                scale_rd_valid_reg <= 1'b1;
                scale_rd_data <= scale_scratch[scale_rd_word_addr];
                scale_rd_byte_valid <= scale_scratch_mask[scale_rd_word_addr];
                scale_rd_last <= ({1'b0, scale_rd_word_addr} + 8'd1 ==
                                  active_scale_words);
                scale_rd_byte_offset <= {scale_rd_word_addr, 2'b00};
            end
        end
    end

    // Writes are tentative.  Visibility is controlled solely by ST_ACTIVE;
    // old words need not be cleared because committed lengths and masks bound
    // every legal read.
    always @(posedge clk) begin
        if (logical_fire && state == ST_DATA_STREAM) begin
            data_scratch[logical_offset[13:2]] <= logical_data;
            data_scratch_mask[logical_offset[13:2]] <= logical_keep;
        end
        if (logical_fire && state == ST_SCALE_STREAM) begin
            scale_scratch[logical_offset[8:2]] <= logical_data;
            scale_scratch_mask[logical_offset[8:2]] <= logical_keep;
        end
    end

    always @(posedge clk) begin
        if (!rst_n || clear_counters) begin
            data_scratch_bytes <= 32'b0;
            scale_scratch_bytes <= 32'b0;
            committed_pages <= 32'b0;
            failed_pages <= 32'b0;
            aborted_pages <= 32'b0;
        end else begin
            if (logical_fire && state == ST_DATA_STREAM)
                data_scratch_bytes <= data_scratch_bytes +
                                      keep4_count(logical_keep);
            if (logical_fire && state == ST_SCALE_STREAM)
                scale_scratch_bytes <= scale_scratch_bytes +
                                       keep4_count(logical_keep);
            if (publish_fire)
                committed_pages <= committed_pages + 1'b1;
            if (error_valid)
                failed_pages <= failed_pages + 1'b1;
            if (aborted)
                aborted_pages <= aborted_pages + 1'b1;
        end
    end

    task fail_slot;
        input [1:0] source;
        input [7:0] code;
        input phase_is_scale;
        begin
            state <= ST_FAIL_WAIT;
            half_upper <= 1'b0;
            error_valid <= 1'b1;
            error_source <= source;
            error_code <= code;
            error_phase_is_scale <= phase_is_scale;
            error_task_tag <= task_tag_reg;
            error_page_index <= page_index_reg;
            error_stream_is_v <= stream_is_v_reg;
        end
    endtask

    wire validator_status_tag_bad = validator_error_valid &&
        ((validator_error_tag != task_tag_reg) ||
         (validator_error_page != page_index_reg) ||
         (validator_error_stream != stream_is_v_reg));
    wire reader_error_tag_bad = reader_error_valid &&
                                (reader_error_tag != task_tag_reg);
    wire active_run = (state >= ST_VALIDATE) && (state <= ST_VERIFY);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            half_upper <= 1'b0;
            page_index_reg <= 5'b0;
            page_count_reg <= 6'b0;
            token_base_reg <= 13'b0;
            token_count_reg <= 8'b0;
            expected_symbols_reg <= 15'b0;
            data_addr_reg <= {ADDR_WIDTH{1'b0}};
            page_window_reg <= 14'b0;
            scale_addr_reg <= {ADDR_WIDTH{1'b0}};
            scale_slice_reg <= 9'b0;
            stream_is_v_reg <= 1'b0;
            task_tag_reg <= {TAG_WIDTH{1'b0}};
            committed_tag_reg <= {TAG_WIDTH{1'b0}};
            committed_page_index_reg <= 5'b0;
            committed_page_count_reg <= 6'b0;
            committed_token_base_reg <= 13'b0;
            committed_token_count_reg <= 8'b0;
            committed_expected_symbols_reg <= 15'b0;
            committed_raw_mode_reg <= 1'b0;
            committed_stream_is_v_reg <= 1'b0;
            committed_payload_bytes_reg <= 16'b0;
            committed_scale_format_reg <= 8'b0;
            committed_record_bytes_reg <= 14'b0;
            committed_window_bytes_reg <= 14'b0;
            committed_scale_bytes_reg <= 9'b0;
            committed_padding_bytes_reg <= 14'b0;
            committed <= 1'b0;
            committed_task_tag <= {TAG_WIDTH{1'b0}};
            aborted <= 1'b0;
            aborted_task_tag <= {TAG_WIDTH{1'b0}};
            aborted_page_index <= 5'b0;
            aborted_stream_is_v <= 1'b0;
            error_valid <= 1'b0;
            error_source <= 2'b0;
            error_code <= 8'b0;
            error_phase_is_scale <= 1'b0;
            error_task_tag <= {TAG_WIDTH{1'b0}};
            error_page_index <= 5'b0;
            error_stream_is_v <= 1'b0;
        end else begin
            committed <= 1'b0;
            aborted <= 1'b0;
            error_valid <= 1'b0;

            if (abort && state != ST_IDLE && state != ST_FAIL_WAIT) begin
                state <= ST_ABORT_WAIT;
                half_upper <= 1'b0;
            end else if (active_run && reader_frame_bad) begin
                fail_slot(ERROR_SOURCE_SLOT, ERR_ADAPTER, stream_is_scale);
            end else if (active_run && reader_error_valid) begin
                if (reader_error_tag_bad)
                    fail_slot(ERROR_SOURCE_SLOT, ERR_CHILD_TAG,
                              stream_is_scale || state == ST_SCALE_CMD);
                else
                    fail_slot(ERROR_SOURCE_READER, reader_error_code,
                              stream_is_scale || state == ST_SCALE_CMD);
            end else if (active_run && validator_error_valid) begin
                if (validator_status_tag_bad)
                    fail_slot(ERROR_SOURCE_SLOT, ERR_CHILD_TAG,
                              state >= ST_SCALE_CMD);
                else
                    fail_slot(ERROR_SOURCE_VALIDATOR, validator_error_code,
                              state >= ST_SCALE_CMD);
            end else if (active_run && (reader_aborted || validator_aborted)) begin
                fail_slot(ERROR_SOURCE_SLOT, ERR_CHILD_PROTOCOL,
                          state >= ST_SCALE_CMD);
            end else begin
                case (state)
                    ST_IDLE: begin
                        half_upper <= 1'b0;
                        if (cmd_fire) begin
                            if (local_cmd_bad) begin
                                error_valid <= 1'b1;
                                error_source <= ERROR_SOURCE_SLOT;
                                error_code <= ERR_DATA_LIMIT;
                                error_phase_is_scale <= 1'b0;
                                error_task_tag <= cmd_task_tag;
                                error_page_index <= cmd_page_index;
                                error_stream_is_v <= cmd_stream_is_v;
                            end else begin
                                page_index_reg <= cmd_page_index;
                                page_count_reg <= cmd_page_count;
                                token_base_reg <= cmd_token_base;
                                token_count_reg <= cmd_token_count;
                                expected_symbols_reg <= cmd_expected_symbols;
                                data_addr_reg <= cmd_data_addr;
                                page_window_reg <= cmd_page_window_bytes[13:0];
                                scale_addr_reg <= cmd_scale_addr;
                                scale_slice_reg <= cmd_scale_slice_bytes;
                                stream_is_v_reg <= cmd_stream_is_v;
                                task_tag_reg <= cmd_task_tag;
                                state <= ST_VALIDATE;
                            end
                        end
                    end

                    ST_VALIDATE: begin
                        if (validator_busy)
                            state <= ST_DATA_CMD;
                    end

                    ST_DATA_CMD: begin
                        if (reader_cmd_valid && reader_cmd_ready) begin
                            half_upper <= 1'b0;
                            state <= ST_DATA_STREAM;
                        end
                    end

                    ST_DATA_STREAM: begin
                        if (logical_fire) begin
                            if (!half_upper && reader_upper_present)
                                half_upper <= 1'b1;
                            else
                                half_upper <= 1'b0;
                        end
                        if (reader_done) begin
                            if (reader_done_tag != task_tag_reg)
                                fail_slot(ERROR_SOURCE_SLOT, ERR_CHILD_TAG,
                                          1'b0);
                            else begin
                                half_upper <= 1'b0;
                                state <= ST_SCALE_CMD;
                            end
                        end
                    end

                    ST_SCALE_CMD: begin
                        if (reader_cmd_valid && reader_cmd_ready) begin
                            half_upper <= 1'b0;
                            state <= ST_SCALE_STREAM;
                        end
                    end

                    ST_SCALE_STREAM: begin
                        if (logical_fire) begin
                            if (!half_upper && reader_upper_present)
                                half_upper <= 1'b1;
                            else
                                half_upper <= 1'b0;
                        end
                        if (reader_done) begin
                            if (reader_done_tag != task_tag_reg)
                                fail_slot(ERROR_SOURCE_SLOT, ERR_CHILD_TAG,
                                          1'b1);
                            else begin
                                half_upper <= 1'b0;
                                state <= ST_VERIFY;
                            end
                        end
                    end

                    ST_VERIFY: begin
                        if (verified_identity_bad) begin
                            fail_slot(ERROR_SOURCE_SLOT, ERR_CHILD_TAG, 1'b1);
                        end else if (publish_fire) begin
                            committed_tag_reg <= validator_verified_tag;
                            committed_page_index_reg <=
                                validator_verified_page;
                            committed_page_count_reg <=
                                validator_verified_page_count;
                            committed_token_base_reg <=
                                validator_verified_token_base;
                            committed_token_count_reg <=
                                validator_verified_token_count;
                            committed_expected_symbols_reg <=
                                validator_verified_symbols;
                            committed_raw_mode_reg <= validator_verified_raw;
                            committed_stream_is_v_reg <=
                                validator_verified_stream;
                            committed_payload_bytes_reg <=
                                validator_verified_payload;
                            committed_scale_format_reg <=
                                validator_verified_scale_format;
                            committed_record_bytes_reg <=
                                validator_verified_record;
                            committed_window_bytes_reg <=
                                validator_verified_window;
                            committed_scale_bytes_reg <=
                                validator_verified_scale_bytes;
                            committed_padding_bytes_reg <=
                                validator_verified_padding;
                            committed <= 1'b1;
                            committed_task_tag <= validator_verified_tag;
                            state <= ST_ACTIVE;
                        end else if (!validator_busy) begin
                            fail_slot(ERROR_SOURCE_SLOT, ERR_CHILD_PROTOCOL,
                                      1'b1);
                        end
                    end

                    ST_ACTIVE: begin
                        if (slot_release)
                            state <= ST_IDLE;
                    end

                    ST_FAIL_WAIT: begin
                        half_upper <= 1'b0;
                        if (!reader_busy && !validator_busy)
                            state <= ST_IDLE;
                    end

                    ST_ABORT_WAIT: begin
                        half_upper <= 1'b0;
                        if (!abort && !reader_busy && !validator_busy) begin
                            aborted <= 1'b1;
                            aborted_task_tag <= task_tag_reg;
                            aborted_page_index <= page_index_reg;
                            aborted_stream_is_v <= stream_is_v_reg;
                            state <= ST_IDLE;
                        end
                    end

                    default: begin
                        fail_slot(ERROR_SOURCE_SLOT, ERR_CHILD_PROTOCOL,
                                  state >= ST_SCALE_CMD);
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ADDR_WIDTH != 32)
            $error("kv_v03_page_prefetch_slot: ADDR_WIDTH must be 32");
        if (ID_WIDTH != 1)
            $error("kv_v03_page_prefetch_slot: ID_WIDTH must be 1");
        if (TAG_WIDTH < 1)
            $error("kv_v03_page_prefetch_slot: TAG_WIDTH must be positive");
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("kv_v03_page_prefetch_slot: SCALE_BITS must be 12 or 16");
        if (MAX_PAGE_BYTES < 12 || MAX_PAGE_BYTES > 16383)
            $error("kv_v03_page_prefetch_slot: MAX_PAGE_BYTES must be 12..16383");
        if (MAX_SCALE_BYTES < ((128*SCALE_BITS + 7)/8) ||
            MAX_SCALE_BYTES > 511)
            $error("kv_v03_page_prefetch_slot: MAX_SCALE_BYTES is insufficient or too large");
    end
`endif
endmodule

`default_nettype wire
