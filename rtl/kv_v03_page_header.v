// kv_v03_page_header.v -- CRC-gated PACKED5 v0.3 page descriptor parser.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_page_header #(
    parameter integer MAX_PAGE_TOKENS = 128,
    parameter integer VALUES_PER_TOKEN = 128,
    // The generated profile supplies the static codebook identifier.  Keep
    // the historical value as the default so existing v0.3 vectors retain
    // their byte-for-byte ABI.
    parameter integer COMPILED_CODEBOOK_ID = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        header_valid,
    input  wire [95:0] header_data,
    input  wire        crc_valid,
    input  wire [31:0] computed_crc,
    output wire        busy,
    output reg         descriptor_valid,
    output reg         raw_mode,
    output reg         stream_is_v,
    output reg  [7:0]  token_count,
    output reg  [15:0] payload_bytes,
    output reg  [7:0]  scale_format_id,
    output reg  [31:0] expected_crc,
    output reg         error_valid,
    output reg  [7:0]  error_code
);
    localparam [15:0] MAGIC_VERSION = 16'hc303;
    localparam [7:0] ERR_MAGIC    = 8'h01;
    localparam [7:0] ERR_FLAGS    = 8'h02;
    localparam [7:0] ERR_TOKENS   = 8'h03;
    localparam [7:0] ERR_PAYLOAD  = 8'h04;
    localparam [7:0] ERR_CODEBOOK = 8'h05;
    localparam [7:0] ERR_SCALE    = 8'h06;
    localparam [7:0] ERR_CRC      = 8'h07;
    localparam [7:0] ERR_PROTOCOL = 8'h08;

    reg pending;
    assign busy = pending;

    reg [8:0] parsed_tokens;
    reg [16:0] raw_payload_bytes;
    reg [7:0] flags;
    reg [15:0] parsed_payload_bytes;
    reg [7:0] parsed_codebook;
    reg [7:0] parsed_scale;
    reg parsed_is_v;
    reg parsed_raw;
    reg [7:0] validation_error;

    always @* begin
        flags                = header_data[23:16];
        parsed_tokens        = {1'b0, header_data[31:24]} + 9'd1;
        parsed_payload_bytes = header_data[47:32];
        parsed_codebook      = header_data[55:48];
        parsed_scale         = header_data[63:56];
        parsed_raw           = flags[0];
        parsed_is_v          = flags[1];
        raw_payload_bytes    = parsed_tokens * VALUES_PER_TOKEN *
                               (parsed_is_v ? 5 : 4) / 8;
        validation_error = 8'h00;
        if (header_data[15:0] != MAGIC_VERSION)
            validation_error = ERR_MAGIC;
        else if (flags[7:2] != 0)
            validation_error = ERR_FLAGS;
        else if (parsed_tokens == 0 || parsed_tokens > MAX_PAGE_TOKENS)
            validation_error = ERR_TOKENS;
        else if (parsed_payload_bytes == 0 || raw_payload_bytes > 16'hffff ||
                 (parsed_raw && parsed_payload_bytes != raw_payload_bytes) ||
                 (!parsed_raw && parsed_payload_bytes >= raw_payload_bytes))
            validation_error = ERR_PAYLOAD;
        else if (parsed_codebook != COMPILED_CODEBOOK_ID[7:0])
            validation_error = ERR_CODEBOOK;
        else if (parsed_scale != 8'd1 && parsed_scale != 8'd2)
            validation_error = ERR_SCALE;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            pending          <= 1'b0;
            descriptor_valid <= 1'b0;
            raw_mode         <= 1'b0;
            stream_is_v      <= 1'b0;
            token_count      <= 8'b0;
            payload_bytes    <= 16'b0;
            scale_format_id  <= 8'b0;
            expected_crc     <= 32'b0;
            error_valid      <= 1'b0;
            error_code       <= 8'b0;
        end else begin
            descriptor_valid <= 1'b0;
            error_valid      <= 1'b0;

            if (start)
                pending <= 1'b0;

            if (header_valid) begin
                if (pending && !start) begin
                    pending     <= 1'b0;
                    error_valid <= 1'b1;
                    error_code  <= ERR_PROTOCOL;
                end else if (validation_error != 0) begin
                    pending     <= 1'b0;
                    error_valid <= 1'b1;
                    error_code  <= validation_error;
                end else begin
                    raw_mode        <= parsed_raw;
                    stream_is_v     <= parsed_is_v;
                    token_count     <= parsed_tokens[7:0];
                    payload_bytes   <= parsed_payload_bytes;
                    scale_format_id <= parsed_scale;
                    expected_crc    <= header_data[95:64];
                    pending         <= 1'b1;
                end
            end

            if (crc_valid) begin
                if (!pending || header_valid || start) begin
                    pending     <= 1'b0;
                    error_valid <= 1'b1;
                    error_code  <= ERR_PROTOCOL;
                end else if (computed_crc != expected_crc) begin
                    pending     <= 1'b0;
                    error_valid <= 1'b1;
                    error_code  <= ERR_CRC;
                end else begin
                    pending          <= 1'b0;
                    descriptor_valid <= 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_PAGE_TOKENS < 1 || MAX_PAGE_TOKENS > 255)
            $error("kv_v03_page_header: MAX_PAGE_TOKENS must be 1..255");
        if (VALUES_PER_TOKEN != 128)
            $error("kv_v03_page_header: v0.3 requires 128 values/token");
        if (COMPILED_CODEBOOK_ID < 0 || COMPILED_CODEBOOK_ID > 255)
            $error("kv_v03_page_header: codebook ID must fit in 8 bits");
    end
`endif
endmodule

`default_nettype wire
