// kv_v03_page128_record_validator.v -- AXI-free PACKED5 page integrity gate.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_page128_record_validator #(
    parameter integer TAG_WIDTH = 64,
    parameter integer SCALE_BITS = 12,
    parameter integer COMPILED_CODEBOOK_ID = 1,
    // Local scratch/transport capacity, not an on-wire canonical-padding rule.
    parameter integer MAX_PAGE_BYTES = 10256
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     cmd_valid,
    output wire                     cmd_ready,
    input  wire [4:0]               cmd_page_index,
    input  wire [5:0]               cmd_page_count,
    input  wire [12:0]              cmd_token_base,
    input  wire [7:0]               cmd_token_count,
    input  wire [14:0]              cmd_expected_symbols,
    input  wire [31:0]              cmd_page_window_bytes,
    input  wire [8:0]               cmd_scale_slice_bytes,
    input  wire                     cmd_stream_is_v,
    input  wire [TAG_WIDTH-1:0]     cmd_task_tag,
    input  wire                     abort,

    input  wire                     data_valid,
    output wire                     data_ready,
    input  wire [31:0]              data_data,
    input  wire [3:0]               data_byte_valid,
    input  wire                     data_last,
    input  wire [13:0]              data_byte_offset,
    input  wire [TAG_WIDTH-1:0]     data_task_tag,
    input  wire [4:0]               data_page_index,
    input  wire                     data_stream_is_v,

    input  wire                     scale_valid,
    output wire                     scale_ready,
    input  wire [31:0]              scale_data,
    input  wire [3:0]               scale_byte_valid,
    input  wire                     scale_last,
    input  wire [13:0]              scale_byte_offset,
    input  wire [TAG_WIDTH-1:0]     scale_task_tag,
    input  wire [4:0]               scale_page_index,
    input  wire                     scale_stream_is_v,

    output wire                     verified_valid,
    input  wire                     verified_ready,
    output wire [TAG_WIDTH-1:0]     verified_task_tag,
    output wire [4:0]               verified_page_index,
    output wire [5:0]               verified_page_count,
    output wire [12:0]              verified_token_base,
    output wire [7:0]               verified_token_count,
    output wire [14:0]              verified_expected_symbols,
    output wire                     verified_raw_mode,
    output wire                     verified_stream_is_v,
    output wire [15:0]              verified_payload_bytes,
    output wire [7:0]               verified_scale_format_id,
    output wire [13:0]              verified_record_bytes,
    output wire [13:0]              verified_page_window_bytes,
    output wire [8:0]               verified_scale_slice_bytes,
    output wire [13:0]              verified_padding_bytes,

    output wire                     busy,
    output reg                      aborted,
    output reg  [TAG_WIDTH-1:0]     aborted_task_tag,
    output reg  [4:0]               aborted_page_index,
    output reg                      aborted_stream_is_v,
    output reg                      error_valid,
    output reg  [7:0]               error_code,
    output reg  [TAG_WIDTH-1:0]     error_task_tag,
    output reg  [4:0]               error_page_index,
    output reg                      error_stream_is_v
);
    localparam [7:0] ERR_PAGE_DESCRIPTOR  = 8'h01;
    localparam [7:0] ERR_TOKEN_DESCRIPTOR = 8'h02;
    localparam [7:0] ERR_WINDOW_DESCRIPTOR = 8'h03;
    localparam [7:0] ERR_SCALE_DESCRIPTOR = 8'h04;
    localparam [7:0] ERR_DATA_TAG         = 8'h05;
    localparam [7:0] ERR_DATA_FRAMING     = 8'h06;
    localparam [7:0] ERR_RECORD_WINDOW    = 8'h07;
    localparam [7:0] ERR_NONZERO_PADDING  = 8'h08;
    localparam [7:0] ERR_SCALE_TAG        = 8'h09;
    localparam [7:0] ERR_SCALE_FRAMING    = 8'h0a;
    localparam [7:0] ERR_STREAM_MISMATCH  = 8'h0b;
    localparam [7:0] ERR_TOKEN_MISMATCH   = 8'h0c;
    localparam [7:0] ERR_SCALE_MISMATCH   = 8'h0d;
    localparam [7:0] ERR_CRC_PROTOCOL     = 8'h0e;
    localparam [7:0] ERR_INTERNAL         = 8'h0f;

    localparam [3:0] ST_IDLE        = 4'd0;
    localparam [3:0] ST_HEADER      = 4'd1;
    localparam [3:0] ST_HEADER_WAIT = 4'd2;
    localparam [3:0] ST_DATA        = 4'd3;
    localparam [3:0] ST_EARLY       = 4'd4;
    localparam [3:0] ST_SCALE       = 4'd5;
    localparam [3:0] ST_WAIT        = 4'd6;
    localparam [3:0] ST_HOLD        = 4'd7;
    localparam [3:0] ST_PREFLIGHT   = 4'd8;
    localparam [3:0] ST_START       = 4'd9;
    localparam [3:0] ST_HEADER_SUBMIT = 4'd10;

    localparam [7:0] EXPECTED_SCALE_ID = (SCALE_BITS == 12) ? 8'd1 : 8'd2;

    reg [3:0] state;
    reg [TAG_WIDTH-1:0] task_tag_reg;
    reg [4:0] page_index_reg;
    reg [5:0] page_count_reg;
    reg [12:0] token_base_reg;
    reg [7:0] token_count_reg;
    reg [14:0] expected_symbols_reg;
    reg [31:0] page_window_cmd_reg;
    reg [13:0] page_window_reg;
    reg [8:0] scale_slice_reg;
    reg stream_is_v_reg;

    reg [95:0] header_buffer;
    reg [31:0] early_payload_data;
    reg [2:0] early_payload_count;
    reg [2:0] early_crc_count;
    reg [13:0] data_offset_reg;
    reg [13:0] scale_offset_reg;

    reg raw_mode_reg;
    reg [15:0] payload_bytes_reg;
    reg [7:0] scale_format_reg;
    reg [13:0] record_bytes_reg;
    reg [13:0] padding_bytes_reg;
    reg header_crc_ok;
    reg scale_ok;

    reg [7:0] cmd_error;
    reg [9:0] expected_scale_bytes;
    reg [15:0] expected_symbol_count;
    reg [13:0] token_end;

    function valid_mask;
        input [3:0] mask;
        begin
            valid_mask = (mask == 4'b0001) || (mask == 4'b0011) ||
                         (mask == 4'b0111) || (mask == 4'b1111);
        end
    endfunction

    function [2:0] byte_count;
        input [3:0] mask;
        begin
            case (mask)
                4'b0001: byte_count = 3'd1;
                4'b0011: byte_count = 3'd2;
                4'b0111: byte_count = 3'd3;
                4'b1111: byte_count = 3'd4;
                default: byte_count = 3'd0;
            endcase
        end
    endfunction

    function [3:0] prefix_mask;
        input [2:0] count;
        begin
            case (count)
                3'd1: prefix_mask = 4'b0001;
                3'd2: prefix_mask = 4'b0011;
                3'd3: prefix_mask = 4'b0111;
                3'd4: prefix_mask = 4'b1111;
                default: prefix_mask = 4'b0000;
            endcase
        end
    endfunction

    always @* begin
        expected_symbol_count = {8'b0, token_count_reg} << 7;
        if (SCALE_BITS == 12)
            expected_scale_bytes = ((token_count_reg * 12) + 7) >> 3;
        else
            expected_scale_bytes = {2'b0, token_count_reg} << 1;
        token_end = {1'b0, token_base_reg} + {6'b0, token_count_reg};

        cmd_error = 8'h00;
        if (page_count_reg == 0 || page_count_reg > 32 ||
            page_index_reg >= page_count_reg)
            cmd_error = ERR_PAGE_DESCRIPTOR;
        else if (token_count_reg == 0 || token_count_reg > 128 ||
                 token_base_reg != {1'b0, page_index_reg, 7'b0} ||
                 expected_symbols_reg != expected_symbol_count[14:0] ||
                 token_end > 14'd4096 ||
                 (({1'b0, page_index_reg} + 6'd1) < page_count_reg &&
                  token_count_reg != 8'd128))
            cmd_error = ERR_TOKEN_DESCRIPTOR;
        else if (page_window_cmd_reg < 12 ||
                 page_window_cmd_reg > MAX_PAGE_BYTES)
            cmd_error = ERR_WINDOW_DESCRIPTOR;
        else if (scale_slice_reg != expected_scale_bytes[8:0])
            cmd_error = ERR_SCALE_DESCRIPTOR;
    end

    assign cmd_ready = (state == ST_IDLE) && !abort;
    wire cmd_fire = cmd_valid && cmd_ready;
    assign busy = (state != ST_IDLE);

    assign verified_valid = (state == ST_HOLD) && !abort;
    assign verified_task_tag = task_tag_reg;
    assign verified_page_index = page_index_reg;
    assign verified_page_count = page_count_reg;
    assign verified_token_base = token_base_reg;
    assign verified_token_count = token_count_reg;
    assign verified_expected_symbols = expected_symbols_reg;
    assign verified_raw_mode = raw_mode_reg;
    assign verified_stream_is_v = stream_is_v_reg;
    assign verified_payload_bytes = payload_bytes_reg;
    assign verified_scale_format_id = scale_format_reg;
    assign verified_record_bytes = record_bytes_reg;
    assign verified_page_window_bytes = page_window_reg;
    assign verified_scale_slice_bytes = scale_slice_reg;
    assign verified_padding_bytes = padding_bytes_reg;

    // Latch the complete descriptor before preflight.  This isolates parent
    // control registers from the descriptor arithmetic and starts the CRC and
    // header blocks only from a registered state after preflight succeeds.
    wire crc_start = (state == ST_START);
    wire header_start = crc_start;
    wire scale12_start;

    wire crc_in_ready;
    reg crc_in_valid;
    reg [31:0] crc_in_data;
    reg [3:0] crc_in_byte_valid;
    reg crc_in_last;
    wire crc_valid;
    wire [31:0] computed_crc;
    wire crc_protocol_error;

    kv_v03_crc32 u_crc32 (
        .clk(clk),
        .rst_n(rst_n),
        .start(crc_start),
        .in_valid(crc_in_valid),
        .in_ready(crc_in_ready),
        .in_data(crc_in_data),
        .in_byte_valid(crc_in_byte_valid),
        .in_last(crc_in_last),
        .crc_valid(crc_valid),
        .crc(computed_crc),
        .protocol_error(crc_protocol_error)
    );

    wire header_busy;
    wire header_descriptor_valid;
    wire header_raw_mode;
    wire header_stream_is_v;
    wire [7:0] header_token_count;
    wire [15:0] header_payload_bytes;
    wire [7:0] header_scale_format_id;
    wire [31:0] header_expected_crc;
    wire header_error_valid;
    wire [7:0] header_error_code;
    wire header_input_valid;
    wire [95:0] header_input_data;
    wire header_crc_valid = (state == ST_WAIT) && crc_valid;

    kv_v03_page_header #(
        .COMPILED_CODEBOOK_ID(COMPILED_CODEBOOK_ID)
    ) u_page_header (
        .clk(clk),
        .rst_n(rst_n),
        .start(header_start),
        .header_valid(header_input_valid),
        .header_data(header_input_data),
        .crc_valid(header_crc_valid),
        .computed_crc(computed_crc),
        .busy(header_busy),
        .descriptor_valid(header_descriptor_valid),
        .raw_mode(header_raw_mode),
        .stream_is_v(header_stream_is_v),
        .token_count(header_token_count),
        .payload_bytes(header_payload_bytes),
        .scale_format_id(header_scale_format_id),
        .expected_crc(header_expected_crc),
        .error_valid(header_error_valid),
        .error_code(header_error_code)
    );

    wire scale12_in_ready;
    wire scale12_out_valid;
    wire [11:0] scale12_out_scale;
    wire scale12_busy;
    wire scale12_done;
    wire scale12_error_valid;
    wire [7:0] scale12_error_code;
    wire scale12_in_valid;

    kv_v03_scale12_reader #(.MAX_SCALES(128)) u_scale12 (
        .clk(clk),
        .rst_n(rst_n),
        .start(scale12_start),
        .expected_scales({1'b0, token_count_reg}),
        .in_valid(scale12_in_valid),
        .in_ready(scale12_in_ready),
        .in_data(scale_data),
        .in_byte_valid(scale_byte_valid),
        .in_last(scale_last),
        .out_valid(scale12_out_valid),
        .out_ready(1'b1),
        .out_scale(scale12_out_scale),
        .busy(scale12_busy),
        .done(scale12_done),
        .error_valid(scale12_error_valid),
        .error_code(scale12_error_code)
    );

    wire [2:0] data_bytes = byte_count(data_byte_valid);
    wire [14:0] data_next_offset = {1'b0, data_offset_reg} + data_bytes;
    wire data_metadata_ok = (data_task_tag == task_tag_reg) &&
                            (data_page_index == page_index_reg) &&
                            (data_stream_is_v == stream_is_v_reg);
    wire header_framing_ok = valid_mask(data_byte_valid) &&
                             (data_byte_offset == data_offset_reg) &&
                             (data_next_offset <= {1'b0, page_window_reg}) &&
                             (data_last ==
                              (data_next_offset == {1'b0, page_window_reg}));
    wire body_framing_ok = valid_mask(data_byte_valid) &&
                           (data_byte_offset == data_offset_reg) &&
                           (data_next_offset <= {1'b0, page_window_reg}) &&
                           (data_last ==
                            (data_next_offset == {1'b0, page_window_reg}));

    reg data_padding_nonzero;
    reg [2:0] payload_bytes_this_beat;
    integer data_lane;
    always @* begin
        data_padding_nonzero = 1'b0;
        payload_bytes_this_beat = 3'd0;
        for (data_lane = 0; data_lane < 4; data_lane = data_lane + 1) begin
            if (data_lane < data_bytes) begin
                if ((data_offset_reg + data_lane) < record_bytes_reg)
                    payload_bytes_this_beat = payload_bytes_this_beat + 1'b1;
                else if (data_data[(data_lane*8) +: 8] != 8'h00)
                    data_padding_nonzero = 1'b1;
            end
        end
    end

    wire data_needs_crc = ((state == ST_HEADER) && (data_offset_reg < 8)) ||
                          ((state == ST_DATA) &&
                           (data_offset_reg < record_bytes_reg));
    assign data_ready = !abort &&
                        (((state == ST_HEADER) &&
                          (!data_needs_crc || crc_in_ready)) ||
                         ((state == ST_DATA) &&
                          (!data_needs_crc || crc_in_ready)));
    wire data_fire = data_valid && data_ready;
    wire header_beat_good = data_metadata_ok && header_framing_ok;
    wire body_beat_good = data_metadata_ok && body_framing_ok &&
                          !data_padding_nonzero;
    reg [95:0] header_candidate;
    reg [31:0] early_payload_candidate;
    reg [2:0] header_crc_bytes_this_beat;
    integer header_lane;
    always @* begin
        header_candidate = header_buffer;
        early_payload_candidate = 32'b0;
        header_crc_bytes_this_beat = 3'b0;
        if (data_offset_reg < 8) begin
            if (data_next_offset <= 15'd8)
                header_crc_bytes_this_beat = data_bytes;
            else
                header_crc_bytes_this_beat = 8 - data_offset_reg[2:0];
        end
        for (header_lane = 0; header_lane < 4; header_lane = header_lane + 1) begin
            if (header_lane < data_bytes) begin
                if ((data_offset_reg + header_lane) < 12)
                    header_candidate[((data_offset_reg + header_lane)*8) +: 8] =
                        data_data[(header_lane*8) +: 8];
                else if ((data_offset_reg + header_lane) < 16)
                    early_payload_candidate[
                        (((data_offset_reg + header_lane) - 12)*8) +: 8] =
                        data_data[(header_lane*8) +: 8];
            end
        end
    end
    // Submit the completed header from a registered state.  This prevents the
    // byte-offset/framing arithmetic from directly driving every enable in
    // the page-header parser on the same cycle as the final header beat.
    assign header_input_valid = state == ST_HEADER_SUBMIT;
    assign header_input_data = header_buffer;

    wire [2:0] scale_bytes = byte_count(scale_byte_valid);
    wire [14:0] scale_next_offset = {1'b0, scale_offset_reg} + scale_bytes;
    wire scale_metadata_ok = (scale_task_tag == task_tag_reg) &&
                             (scale_page_index == page_index_reg) &&
                             (scale_stream_is_v == stream_is_v_reg);
    wire scale_framing_ok = valid_mask(scale_byte_valid) &&
                            (scale_byte_offset == scale_offset_reg) &&
                            (scale_next_offset <= {6'b0, scale_slice_reg}) &&
                            (scale_last ==
                             (scale_next_offset == {6'b0, scale_slice_reg}));
    assign scale_ready = !abort && (state == ST_SCALE) && crc_in_ready &&
                         ((SCALE_BITS == 12) ? scale12_in_ready : 1'b1);
    wire scale_fire = scale_valid && scale_ready;
    wire scale_beat_good = scale_metadata_ok && scale_framing_ok;

    wire data_complete_good = data_fire && (state == ST_DATA) &&
                              body_beat_good && data_last;
    wire early_crc_fire = (state == ST_EARLY) && crc_in_ready && !abort;
    wire early_completes_data = early_crc_fire &&
                                (data_offset_reg == page_window_reg);
    assign scale12_start = (data_complete_good || early_completes_data) &&
                           (SCALE_BITS == 12);
    assign scale12_in_valid = scale_fire && scale_beat_good &&
                              (SCALE_BITS == 12);

    always @* begin
        crc_in_valid = 1'b0;
        crc_in_data = 32'b0;
        crc_in_byte_valid = 4'b0;
        crc_in_last = 1'b0;

        if (data_fire && (state == ST_HEADER) && header_beat_good &&
            header_crc_bytes_this_beat != 0) begin
            crc_in_valid = 1'b1;
            crc_in_data = data_data;
            crc_in_byte_valid = prefix_mask(header_crc_bytes_this_beat);
        end else if (early_crc_fire) begin
            crc_in_valid = 1'b1;
            crc_in_data = early_payload_data;
            crc_in_byte_valid = prefix_mask(early_crc_count);
        end else if (data_fire && (state == ST_DATA) && body_beat_good &&
                     payload_bytes_this_beat != 0) begin
            crc_in_valid = 1'b1;
            crc_in_data = data_data;
            crc_in_byte_valid = prefix_mask(payload_bytes_this_beat);
        end else if (scale_fire && scale_beat_good) begin
            crc_in_valid = 1'b1;
            crc_in_data = scale_data;
            crc_in_byte_valid = scale_byte_valid;
            crc_in_last = scale_last;
        end
    end

    wire [16:0] header_record_bytes =
        {1'b0, header_payload_bytes} + 17'd12;

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            task_tag_reg <= {TAG_WIDTH{1'b0}};
            page_index_reg <= 5'b0;
            page_count_reg <= 6'b0;
            token_base_reg <= 13'b0;
            token_count_reg <= 8'b0;
            expected_symbols_reg <= 15'b0;
            page_window_cmd_reg <= 32'b0;
            page_window_reg <= 14'b0;
            scale_slice_reg <= 9'b0;
            stream_is_v_reg <= 1'b0;
            header_buffer <= 96'b0;
            early_payload_data <= 32'b0;
            early_payload_count <= 3'b0;
            early_crc_count <= 3'b0;
            data_offset_reg <= 14'b0;
            scale_offset_reg <= 14'b0;
            raw_mode_reg <= 1'b0;
            payload_bytes_reg <= 16'b0;
            scale_format_reg <= 8'b0;
            record_bytes_reg <= 14'b0;
            padding_bytes_reg <= 14'b0;
            header_crc_ok <= 1'b0;
            scale_ok <= 1'b0;
            aborted <= 1'b0;
            aborted_task_tag <= {TAG_WIDTH{1'b0}};
            aborted_page_index <= 5'b0;
            aborted_stream_is_v <= 1'b0;
            error_valid <= 1'b0;
            error_code <= 8'b0;
            error_task_tag <= {TAG_WIDTH{1'b0}};
            error_page_index <= 5'b0;
            error_stream_is_v <= 1'b0;
        end else begin
            aborted <= 1'b0;
            error_valid <= 1'b0;

            if (abort && state != ST_IDLE) begin
                state <= ST_IDLE;
                header_crc_ok <= 1'b0;
                scale_ok <= 1'b0;
                aborted <= 1'b1;
                aborted_task_tag <= task_tag_reg;
                aborted_page_index <= page_index_reg;
                aborted_stream_is_v <= stream_is_v_reg;
            end else if (state != ST_IDLE && crc_protocol_error) begin
                state <= ST_IDLE;
                header_crc_ok <= 1'b0;
                scale_ok <= 1'b0;
                error_valid <= 1'b1;
                error_code <= ERR_CRC_PROTOCOL;
                error_task_tag <= task_tag_reg;
                error_page_index <= page_index_reg;
                error_stream_is_v <= stream_is_v_reg;
            end else begin
                case (state)
                    ST_IDLE: begin
                        if (cmd_fire) begin
                            task_tag_reg <= cmd_task_tag;
                            page_index_reg <= cmd_page_index;
                            page_count_reg <= cmd_page_count;
                            token_base_reg <= cmd_token_base;
                            token_count_reg <= cmd_token_count;
                            expected_symbols_reg <= cmd_expected_symbols;
                            page_window_cmd_reg <= cmd_page_window_bytes;
                            scale_slice_reg <= cmd_scale_slice_bytes;
                            stream_is_v_reg <= cmd_stream_is_v;
                            state <= ST_PREFLIGHT;
                        end
                    end

                    ST_PREFLIGHT: begin
                        if (cmd_error != 0) begin
                            state <= ST_IDLE;
                            error_valid <= 1'b1;
                            error_code <= cmd_error;
                            error_task_tag <= task_tag_reg;
                            error_page_index <= page_index_reg;
                            error_stream_is_v <= stream_is_v_reg;
                        end else begin
                            page_window_reg <= page_window_cmd_reg[13:0];
                            header_buffer <= 96'b0;
                            early_payload_data <= 32'b0;
                            early_payload_count <= 3'b0;
                            early_crc_count <= 3'b0;
                            data_offset_reg <= 14'b0;
                            scale_offset_reg <= 14'b0;
                            raw_mode_reg <= 1'b0;
                            payload_bytes_reg <= 16'b0;
                            scale_format_reg <= 8'b0;
                            record_bytes_reg <= 14'b0;
                            padding_bytes_reg <= 14'b0;
                            header_crc_ok <= 1'b0;
                            scale_ok <= 1'b0;
                            state <= ST_START;
                        end
                    end

                    ST_START: begin
                        state <= ST_HEADER;
                    end

                    ST_HEADER: begin
                        if (data_fire) begin
                            if (!data_metadata_ok) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_DATA_TAG;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (!header_framing_ok) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_DATA_FRAMING;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else begin
                                header_buffer <= header_candidate;
                                data_offset_reg <= data_next_offset[13:0];
                                if (data_next_offset >= 15'd12) begin
                                    early_payload_data <= early_payload_candidate;
                                    early_payload_count <=
                                        data_next_offset[2:0] - 3'd4;
                                    state <= ST_HEADER_SUBMIT;
                                end
                            end
                        end
                    end

                    ST_HEADER_SUBMIT: begin
                        state <= ST_HEADER_WAIT;
                    end

                    ST_HEADER_WAIT: begin
                        if (header_error_valid) begin
                            state <= ST_IDLE;
                            error_valid <= 1'b1;
                            error_code <= 8'h20 | header_error_code;
                            error_task_tag <= task_tag_reg;
                            error_page_index <= page_index_reg;
                            error_stream_is_v <= stream_is_v_reg;
                        end else if (header_busy) begin
                            if (header_stream_is_v != stream_is_v_reg) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_STREAM_MISMATCH;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (header_token_count != token_count_reg) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_TOKEN_MISMATCH;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (header_scale_format_id != EXPECTED_SCALE_ID) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_SCALE_MISMATCH;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (header_record_bytes > page_window_reg) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_RECORD_WINDOW;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else begin
                                raw_mode_reg <= header_raw_mode;
                                payload_bytes_reg <= header_payload_bytes;
                                scale_format_reg <= header_scale_format_id;
                                record_bytes_reg <= header_record_bytes[13:0];
                                padding_bytes_reg <=
                                    page_window_reg - header_record_bytes[13:0];
                                if (early_payload_count != 0) begin
                                    if (header_payload_bytes < early_payload_count)
                                        early_crc_count <= header_payload_bytes[2:0];
                                    else
                                        early_crc_count <= early_payload_count;
                                    if (((early_payload_count > header_payload_bytes) &&
                                         (header_payload_bytes == 0)) ||
                                        ((early_payload_count > header_payload_bytes) &&
                                         ((header_payload_bytes == 1 &&
                                           |early_payload_data[23:8]) ||
                                          (header_payload_bytes == 2 &&
                                           |early_payload_data[23:16])))) begin
                                        state <= ST_IDLE;
                                        error_valid <= 1'b1;
                                        error_code <= ERR_NONZERO_PADDING;
                                        error_task_tag <= task_tag_reg;
                                        error_page_index <= page_index_reg;
                                        error_stream_is_v <= stream_is_v_reg;
                                    end else begin
                                        state <= ST_EARLY;
                                    end
                                end else begin
                                    state <= ST_DATA;
                                end
                            end
                        end
                    end

                    ST_EARLY: begin
                        if (early_crc_fire) begin
                            if (early_crc_count == 0) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_INTERNAL;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (data_offset_reg == page_window_reg) begin
                                scale_offset_reg <= 14'b0;
                                state <= ST_SCALE;
                            end else begin
                                state <= ST_DATA;
                            end
                        end
                    end

                    ST_DATA: begin
                        if (data_fire) begin
                            if (!data_metadata_ok) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_DATA_TAG;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (!body_framing_ok) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_DATA_FRAMING;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (data_padding_nonzero) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_NONZERO_PADDING;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (data_last) begin
                                scale_offset_reg <= 14'b0;
                                state <= ST_SCALE;
                            end else begin
                                data_offset_reg <= data_next_offset[13:0];
                            end
                        end
                    end

                    ST_SCALE: begin
                        if (scale_fire) begin
                            if (!scale_metadata_ok) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_SCALE_TAG;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (!scale_framing_ok) begin
                                state <= ST_IDLE;
                                error_valid <= 1'b1;
                                error_code <= ERR_SCALE_FRAMING;
                                error_task_tag <= task_tag_reg;
                                error_page_index <= page_index_reg;
                                error_stream_is_v <= stream_is_v_reg;
                            end else if (scale_last) begin
                                if (SCALE_BITS == 16)
                                    scale_ok <= 1'b1;
                                state <= ST_WAIT;
                            end else begin
                                scale_offset_reg <= scale_next_offset[13:0];
                            end
                        end
                    end

                    ST_WAIT: begin
                        if (header_error_valid) begin
                            state <= ST_IDLE;
                            header_crc_ok <= 1'b0;
                            scale_ok <= 1'b0;
                            error_valid <= 1'b1;
                            error_code <= 8'h20 | header_error_code;
                            error_task_tag <= task_tag_reg;
                            error_page_index <= page_index_reg;
                            error_stream_is_v <= stream_is_v_reg;
                        end else if ((SCALE_BITS == 12) && scale12_error_valid) begin
                            state <= ST_IDLE;
                            header_crc_ok <= 1'b0;
                            scale_ok <= 1'b0;
                            error_valid <= 1'b1;
                            error_code <= 8'h30 | scale12_error_code;
                            error_task_tag <= task_tag_reg;
                            error_page_index <= page_index_reg;
                            error_stream_is_v <= stream_is_v_reg;
                        end else begin
                            if (header_descriptor_valid)
                                header_crc_ok <= 1'b1;
                            if ((SCALE_BITS == 12) && scale12_done)
                                scale_ok <= 1'b1;
                            if ((header_crc_ok || header_descriptor_valid) &&
                                (scale_ok ||
                                 ((SCALE_BITS == 12) && scale12_done))) begin
                                state <= ST_HOLD;
                            end
                        end
                    end

                    ST_HOLD: begin
                        if (verified_ready)
                            state <= ST_IDLE;
                    end

                    default: begin
                        state <= ST_IDLE;
                        error_valid <= 1'b1;
                        error_code <= ERR_INTERNAL;
                        error_task_tag <= task_tag_reg;
                        error_page_index <= page_index_reg;
                        error_stream_is_v <= stream_is_v_reg;
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (TAG_WIDTH < 1)
            $error("kv_v03_page128_record_validator: TAG_WIDTH must be positive");
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("kv_v03_page128_record_validator: SCALE_BITS must be 12 or 16");
        if (MAX_PAGE_BYTES < 12 || MAX_PAGE_BYTES > 16383)
            $error("kv_v03_page128_record_validator: MAX_PAGE_BYTES must be 12..16383");
    end
`endif
endmodule

`default_nettype wire
