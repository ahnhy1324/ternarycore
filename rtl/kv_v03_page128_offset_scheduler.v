// kv_v03_page128_offset_scheduler.v -- CRC-gated page128 address planner.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_page128_offset_scheduler #(
    parameter integer ADDR_WIDTH  = 64,
    parameter integer TAG_WIDTH   = 64,
    parameter integer SCALE_BITS  = 12,
    parameter integer MAX_CONTEXT = 4096
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire                      cmd_valid,
    output wire                      cmd_ready,
    input  wire [12:0]               cmd_context_len,
    input  wire [ADDR_WIDTH-1:0]     cmd_data_base,
    input  wire [31:0]               cmd_data_stream_bytes,
    input  wire [ADDR_WIDTH-1:0]     cmd_scale_base,
    input  wire [31:0]               cmd_scale_plane_bytes,
    input  wire [31:0]               cmd_offset_crc32,
    input  wire                      cmd_stream_is_v,
    input  wire [TAG_WIDTH-1:0]      cmd_task_tag,
    input  wire                      abort,

    // The complete task-local offset table is presented as little-endian
    // u32 words.  An AXI reader is deliberately outside this module.
    input  wire                      offset_valid,
    output wire                      offset_ready,
    input  wire [31:0]               offset_data,
    input  wire                      offset_last,

    // Descriptors are not visible until the complete table has passed both
    // CRC and structural validation.
    output wire                      page_valid,
    input  wire                      page_ready,
    output wire [4:0]                page_index,
    output wire [5:0]                page_count,
    output wire [12:0]               token_base,
    output wire [7:0]                token_count,
    output wire [14:0]               expected_symbols,
    output wire [ADDR_WIDTH-1:0]     data_addr,
    output wire [ADDR_WIDTH-1:0]     data_limit,
    output wire [31:0]               page_window_bytes,
    output wire [ADDR_WIDTH-1:0]     scale_addr,
    output wire [8:0]                scale_slice_bytes,
    output wire                      stream_is_v,
    output wire [TAG_WIDTH-1:0]      task_tag,

    output reg                       busy,
    output reg                       table_valid,
    output reg                       done,
    output reg                       aborted,
    output reg                       error_valid,
    output reg  [7:0]                error_code
);
    localparam integer PAGE_TOKENS = 128;
    localparam integer MAX_PAGES = (MAX_CONTEXT + PAGE_TOKENS - 1) /
                                   PAGE_TOKENS;
    localparam integer SCALE_STRIDE_BYTES = PAGE_TOKENS * SCALE_BITS / 8;
    // These values are local block identities, not the final integrated ABI.
    localparam [7:0] ERR_CONTEXT        = 8'h01;
    localparam [7:0] ERR_CONFIG         = 8'h02;
    localparam [7:0] ERR_TABLE_PROTOCOL = 8'h03;
    localparam [7:0] ERR_TABLE_CRC      = 8'h04;
    localparam [7:0] ERR_OFFSET         = 8'h05;

    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_LOAD     = 3'd1;
    localparam [2:0] ST_WAIT_CRC = 3'd2;
    localparam [2:0] ST_VALIDATE = 3'd3;
    localparam [2:0] ST_EMIT     = 3'd4;

    reg [2:0] state;
    reg [31:0] offsets [0:MAX_PAGES-1];
    reg [5:0] load_index;
    reg [5:0] validate_index;
    reg [4:0] emit_index;

    reg [12:0] context_len_reg;
    reg [5:0] page_count_reg;
    reg [ADDR_WIDTH-1:0] data_base_reg;
    reg [31:0] data_stream_bytes_reg;
    reg [ADDR_WIDTH-1:0] scale_base_reg;
    reg [31:0] offset_crc32_reg;
    reg stream_is_v_reg;
    reg [TAG_WIDTH-1:0] task_tag_reg;

    reg crc_start;
    wire crc_in_ready;
    wire crc_valid;
    wire [31:0] crc_value;
    wire crc_protocol_error;

    assign cmd_ready = (state == ST_IDLE) && !abort;
    assign offset_ready = (state == ST_LOAD) && crc_in_ready && !abort;

    kv_v03_crc32 offset_crc (
        .clk(clk),
        .rst_n(rst_n),
        .start(crc_start),
        .in_valid(offset_valid && offset_ready),
        .in_ready(crc_in_ready),
        .in_data(offset_data),
        .in_byte_valid(4'b1111),
        .in_last(offset_last),
        .crc_valid(crc_valid),
        .crc(crc_value),
        .protocol_error(crc_protocol_error)
    );

    reg [5:0] cmd_page_count_calc;
    reg [31:0] cmd_scale_bytes_calc;
    reg [31:0] cmd_scale_bits_calc;
    reg [ADDR_WIDTH:0] cmd_data_end_ext;
    reg [ADDR_WIDTH:0] cmd_scale_end_ext;
    reg [7:0] cmd_error;
    always @* begin
        cmd_page_count_calc = ({1'b0, cmd_context_len} + 14'd127) >> 7;
        cmd_scale_bits_calc = cmd_context_len * SCALE_BITS;
        cmd_scale_bytes_calc = (cmd_scale_bits_calc + 7) >> 3;
        cmd_data_end_ext = {1'b0, cmd_data_base} +
                           cmd_data_stream_bytes;
        cmd_scale_end_ext = {1'b0, cmd_scale_base} +
                            cmd_scale_plane_bytes;
        cmd_error = 8'h00;
        if (cmd_context_len == 0 || cmd_context_len > MAX_CONTEXT ||
            cmd_page_count_calc == 0 || cmd_page_count_calc > MAX_PAGES)
            cmd_error = ERR_CONTEXT;
        else if (cmd_data_stream_bytes == 0 || cmd_data_base[3:0] != 0 ||
                 cmd_data_end_ext[ADDR_WIDTH] ||
                 cmd_scale_plane_bytes != cmd_scale_bytes_calc ||
                 cmd_scale_plane_bytes == 0 ||
                 cmd_scale_end_ext[ADDR_WIDTH])
            cmd_error = ERR_CONFIG;
    end

    wire [31:0] validate_offset = offsets[validate_index[4:0]];
    wire [31:0] validate_end =
        (validate_index + 1 < page_count_reg) ?
        offsets[validate_index[4:0] + 1'b1] : data_stream_bytes_reg;
    wire validate_offset_bad =
        (validate_offset[3:0] != 0) ||
        (validate_offset >= data_stream_bytes_reg) ||
        (validate_index != 0 &&
         validate_offset <= offsets[validate_index[4:0] - 1'b1]) ||
        (validate_end <= validate_offset) ||
        ((validate_end - validate_offset) < 12);

    wire [31:0] emit_offset = offsets[emit_index];
    wire [31:0] emit_end =
        ({1'b0, emit_index} + 1 < page_count_reg) ?
        offsets[emit_index + 1'b1] : data_stream_bytes_reg;
    wire [12:0] emit_token_base = {emit_index, 7'b0};
    wire [12:0] emit_remaining = context_len_reg - emit_token_base;
    wire [7:0] emit_token_count =
        (emit_remaining > PAGE_TOKENS) ? 8'd128 : emit_remaining[7:0];
    wire [31:0] emit_scale_offset = emit_index * SCALE_STRIDE_BYTES;
    wire [16:0] emit_scale_bits = emit_token_count * SCALE_BITS;

    // Abort is combinationally fail-closed: no table word or descriptor may
    // handshake on the edge that accepts the abort.
    assign page_valid = (state == ST_EMIT) && table_valid && !abort;
    assign page_index = emit_index;
    assign page_count = page_count_reg;
    assign token_base = emit_token_base;
    assign token_count = emit_token_count;
    assign expected_symbols = {emit_token_count, 7'b0};
    assign data_addr = data_base_reg + emit_offset;
    assign data_limit = data_base_reg + emit_end;
    assign page_window_bytes = emit_end - emit_offset;
    assign scale_addr = scale_base_reg + emit_scale_offset;
    assign scale_slice_bytes = (emit_scale_bits + 7) >> 3;
    assign stream_is_v = stream_is_v_reg;
    assign task_tag = task_tag_reg;

    task fail_transaction;
        input [7:0] code;
        begin
            state       <= ST_IDLE;
            busy        <= 1'b0;
            table_valid <= 1'b0;
            error_valid <= 1'b1;
            error_code  <= code;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            state                   <= ST_IDLE;
            load_index              <= 0;
            validate_index          <= 0;
            emit_index              <= 0;
            context_len_reg         <= 0;
            page_count_reg          <= 0;
            data_base_reg           <= 0;
            data_stream_bytes_reg   <= 0;
            scale_base_reg          <= 0;
            offset_crc32_reg        <= 0;
            stream_is_v_reg         <= 0;
            task_tag_reg            <= 0;
            crc_start               <= 0;
            busy                    <= 0;
            table_valid             <= 0;
            done                    <= 0;
            aborted                 <= 0;
            error_valid             <= 0;
            error_code              <= 0;
        end else begin
            crc_start <= 1'b0;
            done      <= 1'b0;
            aborted   <= 1'b0;

            if (abort && busy) begin
                state       <= ST_IDLE;
                busy        <= 1'b0;
                table_valid <= 1'b0;
                aborted     <= 1'b1;
            end else if (cmd_valid && cmd_ready) begin
                error_valid <= 1'b0;
                error_code  <= 8'h00;
                table_valid <= 1'b0;
                // Fault identity belongs to the newly accepted command even
                // when its context or address preflight fails.
                stream_is_v_reg <= cmd_stream_is_v;
                task_tag_reg    <= cmd_task_tag;
                if (cmd_error != 0) begin
                    fail_transaction(cmd_error);
                end else begin
                    context_len_reg       <= cmd_context_len;
                    page_count_reg        <= cmd_page_count_calc;
                    data_base_reg         <= cmd_data_base;
                    data_stream_bytes_reg <= cmd_data_stream_bytes;
                    scale_base_reg        <= cmd_scale_base;
                    offset_crc32_reg      <= cmd_offset_crc32;
                    load_index            <= 0;
                    validate_index        <= 0;
                    emit_index            <= 0;
                    crc_start             <= 1'b1;
                    busy                  <= 1'b1;
                    state                 <= ST_LOAD;
                end
            end else begin
                case (state)
                    ST_LOAD: begin
                        if (offset_valid && offset_ready) begin
                            if (offset_last !=
                                (load_index + 1 == page_count_reg)) begin
                                fail_transaction(ERR_TABLE_PROTOCOL);
                            end else begin
                                offsets[load_index[4:0]] <= offset_data;
                                if (load_index + 1 == page_count_reg) begin
                                    state <= ST_WAIT_CRC;
                                end else begin
                                    load_index <= load_index + 1'b1;
                                end
                            end
                        end
                    end

                    ST_WAIT_CRC: begin
                        if (crc_protocol_error) begin
                            fail_transaction(ERR_TABLE_PROTOCOL);
                        end else if (crc_valid) begin
                            if (crc_value != offset_crc32_reg) begin
                                fail_transaction(ERR_TABLE_CRC);
                            end else begin
                                validate_index <= 0;
                                state <= ST_VALIDATE;
                            end
                        end
                    end

                    ST_VALIDATE: begin
                        if (validate_offset_bad) begin
                            fail_transaction(ERR_OFFSET);
                        end else if (validate_index + 1 == page_count_reg) begin
                            emit_index  <= 0;
                            table_valid <= 1'b1;
                            state       <= ST_EMIT;
                        end else begin
                            validate_index <= validate_index + 1'b1;
                        end
                    end

                    ST_EMIT: begin
                        if (page_valid && page_ready) begin
                            if ({1'b0, emit_index} + 1 == page_count_reg) begin
                                state       <= ST_IDLE;
                                busy        <= 1'b0;
                                table_valid <= 1'b0;
                                done        <= 1'b1;
                            end else begin
                                emit_index <= emit_index + 1'b1;
                            end
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                        busy  <= 1'b0;
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ADDR_WIDTH < 32)
            $error("kv_v03_page128_offset_scheduler: ADDR_WIDTH must be >= 32");
        if (TAG_WIDTH < 1)
            $error("kv_v03_page128_offset_scheduler: TAG_WIDTH must be positive");
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("kv_v03_page128_offset_scheduler: SCALE_BITS must be 12 or 16");
        if (MAX_CONTEXT < 1 || MAX_CONTEXT > 4096 || MAX_PAGES > 32)
            $error("kv_v03_page128_offset_scheduler: MAX_CONTEXT must be 1..4096");
    end
`endif
endmodule

`default_nettype wire
