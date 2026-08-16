// kv_cache_engine.v -- INT4 K read, unpack, dequantize and Q.K logits.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_cache_engine #(
    parameter integer HEAD_DIM        = 64,
    parameter integer KV_BITS         = 4,
    parameter integer AXI_DATA_WIDTH  = 128,
    parameter integer AXI_ADDR_WIDTH  = 32,
    parameter integer AXI_ID_WIDTH    = 1,
    parameter integer P               = 16,
    parameter integer MAX_CONTEXT     = 4096,
    parameter integer Q_WIDTH         = 8,
    parameter integer SCALE_WIDTH     = 16,
    parameter integer DEQUANT_WIDTH   = KV_BITS + SCALE_WIDTH,
    parameter integer ACC_WIDTH       = 32,
    parameter integer TIMEOUT_CYCLES  = 65536
) (
    input  wire clk,
    input  wire rst_n,

    input  wire start,
    input  wire [AXI_ADDR_WIDTH-1:0] k_base_addr,
    input  wire [31:0] context_len,
    input  wire [(HEAD_DIM*Q_WIDTH)-1:0] q_vector,
    input  wire signed [SCALE_WIDTH-1:0] k_scale,

    output reg  busy,
    output reg  done,
    output reg  error,
    output reg  [7:0] error_code,
    output reg  [31:0] perf_cycles,

    output reg  logit_valid,
    output reg  [((MAX_CONTEXT <= 1) ? 1 : $clog2(MAX_CONTEXT))-1:0] logit_index,
    output reg signed [ACC_WIDTH-1:0] logit_data,

    output wire [AXI_ID_WIDTH-1:0]    m_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_araddr,
    output wire [7:0]                 m_axi_arlen,
    output wire [2:0]                 m_axi_arsize,
    output wire [1:0]                 m_axi_arburst,
    output wire                       m_axi_arlock,
    output wire [3:0]                 m_axi_arcache,
    output wire [2:0]                 m_axi_arprot,
    output wire [3:0]                 m_axi_arqos,
    output wire                       m_axi_arvalid,
    input  wire                       m_axi_arready,
    input  wire [AXI_ID_WIDTH-1:0]    m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_rdata,
    input  wire [1:0]                 m_axi_rresp,
    input  wire                       m_axi_rlast,
    input  wire                       m_axi_rvalid,
    output wire                       m_axi_rready
);
    localparam integer VECTOR_BITS       = HEAD_DIM * KV_BITS;
    localparam integer VECTOR_BYTES      = VECTOR_BITS / 8;
    localparam integer VECTOR_SHIFT      = $clog2(VECTOR_BYTES);
    localparam integer TOTAL_SLICES      = HEAD_DIM / P;
    localparam integer SLICES_PER_BEAT   = AXI_DATA_WIDTH / (P * KV_BITS);
    localparam integer TOKEN_WIDTH       =
        (MAX_CONTEXT <= 1) ? 1 : $clog2(MAX_CONTEXT);
    localparam integer SLICE_WIDTH       =
        (TOTAL_SLICES <= 1) ? 1 : $clog2(TOTAL_SLICES);
    localparam integer BEAT_SLICE_WIDTH  =
        (SLICES_PER_BEAT <= 1) ? 1 : $clog2(SLICES_PER_BEAT);

    localparam [2:0] ST_IDLE        = 3'd0,
                     ST_ISSUE       = 3'd1,
                     ST_WAIT_BEAT   = 3'd2,
                     ST_PROCESS     = 3'd3,
                     ST_WAIT_RESULT = 3'd4;

    reg [2:0] state;
    reg [TOKEN_WIDTH-1:0] token_counter;
    reg [SLICE_WIDTH-1:0] global_slice;
    reg [BEAT_SLICE_WIDTH-1:0] beat_slice;
    reg [AXI_DATA_WIDTH-1:0] beat_buffer;
    reg buffered_beat_last;

    wire [AXI_ADDR_WIDTH-1:0] vector_addr;
    kv_addr_gen #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .TOKEN_WIDTH(TOKEN_WIDTH),
        .VECTOR_BYTES(VECTOR_BYTES)
    ) u_addr (
        .base_addr(k_base_addr),
        .token_index(token_counter),
        .vector_addr(vector_addr)
    );

    reg reader_start;
    wire reader_busy, reader_done, reader_error;
    wire [3:0] reader_error_code;
    wire [AXI_DATA_WIDTH-1:0] reader_beat_data;
    wire reader_beat_valid, reader_beat_last;
    wire reader_beat_ready = (state == ST_WAIT_BEAT);

    kv_reader #(
        .ADDR_WIDTH(AXI_ADDR_WIDTH),
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ID_WIDTH(AXI_ID_WIDTH),
        .VECTOR_BITS(VECTOR_BITS),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_reader (
        .clk(clk), .rst_n(rst_n),
        .start(reader_start), .vector_addr(vector_addr),
        .busy(reader_busy), .done(reader_done),
        .error(reader_error), .error_code(reader_error_code),
        .beat_data(reader_beat_data), .beat_valid(reader_beat_valid),
        .beat_last(reader_beat_last), .beat_ready(reader_beat_ready),
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

    wire [(P*KV_BITS)-1:0] packed_slice =
        beat_buffer[(beat_slice*(P*KV_BITS)) +: (P*KV_BITS)];
    wire [(P*KV_BITS)-1:0] unpacked_slice;
    int4_unpack #(.LANES(P), .OUT_WIDTH(KV_BITS)) u_unpack (
        .packed_in(packed_slice), .unpacked_out(unpacked_slice)
    );

    wire [(P*DEQUANT_WIDTH)-1:0] dequant_slice;
    kv_dequant #(
        .LANES(P), .IN_WIDTH(KV_BITS), .SCALE_WIDTH(SCALE_WIDTH),
        .OUT_WIDTH(DEQUANT_WIDTH)
    ) u_dequant (
        .quant_in(unpacked_slice), .scale(k_scale),
        .dequant_out(dequant_slice)
    );

    wire [(P*Q_WIDTH)-1:0] q_slice =
        q_vector[(global_slice*(P*Q_WIDTH)) +: (P*Q_WIDTH)];
    wire dot_in_valid = (state == ST_PROCESS);
    wire dot_vector_start = (global_slice == 0);
    wire dot_vector_last  = (global_slice == TOTAL_SLICES-1);
    wire dot_out_valid;
    wire signed [ACC_WIDTH-1:0] dot_result;
    qk_dot #(
        .LANES(P), .Q_WIDTH(Q_WIDTH), .K_WIDTH(DEQUANT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_dot (
        .clk(clk), .rst_n(rst_n), .in_valid(dot_in_valid),
        .vector_start(dot_vector_start), .vector_last(dot_vector_last),
        .q_lanes(q_slice), .k_lanes(dequant_slice),
        .out_valid(dot_out_valid), .result(dot_result)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            busy               <= 1'b0;
            done               <= 1'b0;
            error              <= 1'b0;
            error_code         <= 8'd0;
            perf_cycles        <= 32'd0;
            logit_valid        <= 1'b0;
            logit_index        <= {TOKEN_WIDTH{1'b0}};
            logit_data         <= {ACC_WIDTH{1'b0}};
            token_counter      <= {TOKEN_WIDTH{1'b0}};
            global_slice       <= {SLICE_WIDTH{1'b0}};
            beat_slice         <= {BEAT_SLICE_WIDTH{1'b0}};
            beat_buffer        <= {AXI_DATA_WIDTH{1'b0}};
            buffered_beat_last <= 1'b0;
            reader_start       <= 1'b0;
        end else begin
            done         <= 1'b0;
            error        <= 1'b0;
            logit_valid  <= 1'b0;
            reader_start <= 1'b0;

            if (busy)
                perf_cycles <= perf_cycles + 1'b1;

            // A read error may arrive while the previous buffered beat is
            // being processed, so handle it above the state-specific logic.
            if (busy && reader_error) begin
                busy       <= 1'b0;
                error      <= 1'b1;
                error_code <= {4'h1, reader_error_code};
                state      <= ST_IDLE;
            end else begin
                case (state)
                    ST_IDLE: begin
                        busy <= 1'b0;
                        if (start) begin
                            perf_cycles   <= 32'd0;
                            token_counter <= {TOKEN_WIDTH{1'b0}};
                            global_slice  <= {SLICE_WIDTH{1'b0}};
                            beat_slice    <= {BEAT_SLICE_WIDTH{1'b0}};
                            error_code    <= 8'd0;
                            if (context_len == 0 || context_len > MAX_CONTEXT) begin
                                error      <= 1'b1;
                                error_code <= 8'h01;
                            end else if (k_base_addr[VECTOR_SHIFT-1:0] != 0) begin
                                error      <= 1'b1;
                                error_code <= 8'h02;
                            end else begin
                                busy  <= 1'b1;
                                state <= ST_ISSUE;
                            end
                        end
                    end

                    ST_ISSUE: begin
                        reader_start <= 1'b1;
                        state        <= ST_WAIT_BEAT;
                    end

                    ST_WAIT_BEAT: begin
                        if (reader_beat_valid) begin
                            beat_buffer        <= reader_beat_data;
                            buffered_beat_last <= reader_beat_last;
                            beat_slice         <= {BEAT_SLICE_WIDTH{1'b0}};
                            state              <= ST_PROCESS;
                        end
                    end

                    ST_PROCESS: begin
                        global_slice <= global_slice + 1'b1;
                        if (beat_slice == SLICES_PER_BEAT-1) begin
                            beat_slice <= {BEAT_SLICE_WIDTH{1'b0}};
                            if (buffered_beat_last)
                                state <= ST_WAIT_RESULT;
                            else
                                state <= ST_WAIT_BEAT;
                        end else begin
                            beat_slice <= beat_slice + 1'b1;
                        end
                    end

                    ST_WAIT_RESULT: begin
                        if (dot_out_valid) begin
                            logit_valid <= 1'b1;
                            logit_index <= token_counter;
                            logit_data  <= dot_result;
                            if (token_counter == context_len - 1'b1) begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                token_counter <= token_counter + 1'b1;
                                global_slice  <= {SLICE_WIDTH{1'b0}};
                                state         <= ST_ISSUE;
                            end
                        end
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

    wire unused_reader_status = reader_busy ^ reader_done;

`ifndef SYNTHESIS
    initial begin
        if (KV_BITS != 4)
            $error("kv_cache_engine v0.1 supports signed INT4 K only");
        if (HEAD_DIM % P != 0)
            $error("kv_cache_engine: P must divide HEAD_DIM");
        if (VECTOR_BITS % AXI_DATA_WIDTH != 0)
            $error("kv_cache_engine: AXI_DATA_WIDTH must divide one vector");
        if (AXI_DATA_WIDTH % (P*KV_BITS) != 0)
            $error("kv_cache_engine: AXI beat must contain whole P-lane slices");
        if ((1 << VECTOR_SHIFT) != VECTOR_BYTES)
            $error("kv_cache_engine: vector size must be a power of two bytes");
    end
`endif
endmodule

`default_nettype wire
