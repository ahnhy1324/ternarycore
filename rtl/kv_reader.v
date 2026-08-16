// kv_reader.v -- one-vector, read-only AXI4 burst reader with a skid buffer.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_reader #(
    parameter integer ADDR_WIDTH     = 32,
    parameter integer DATA_WIDTH     = 128,
    parameter integer ID_WIDTH       = 1,
    parameter integer VECTOR_BITS    = 256,
    parameter integer TIMEOUT_CYCLES = 65536
) (
    input  wire clk,
    input  wire rst_n,

    input  wire start,
    input  wire [ADDR_WIDTH-1:0] vector_addr,
    output reg  busy,
    output reg  done,
    output reg  error,
    output reg  [3:0] error_code,

    output reg  [DATA_WIDTH-1:0] beat_data,
    output reg  beat_valid,
    output reg  beat_last,
    input  wire beat_ready,

    output wire [ID_WIDTH-1:0]   m_axi_arid,
    output reg  [ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0]            m_axi_arlen,
    output wire [2:0]            m_axi_arsize,
    output wire [1:0]            m_axi_arburst,
    output wire                  m_axi_arlock,
    output wire [3:0]            m_axi_arcache,
    output wire [2:0]            m_axi_arprot,
    output wire [3:0]            m_axi_arqos,
    output reg                   m_axi_arvalid,
    input  wire                  m_axi_arready,

    input  wire [ID_WIDTH-1:0]   m_axi_rid,
    input  wire [DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [1:0]            m_axi_rresp,
    input  wire                  m_axi_rlast,
    input  wire                  m_axi_rvalid,
    output wire                  m_axi_rready
);
    localparam integer BEATS_PER_VECTOR = VECTOR_BITS / DATA_WIDTH;
    localparam integer BEAT_COUNT_WIDTH =
        (BEATS_PER_VECTOR <= 1) ? 1 : $clog2(BEATS_PER_VECTOR);
    localparam integer BYTES_PER_BEAT = DATA_WIDTH / 8;
    localparam [1:0] S_IDLE = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2;

    reg [1:0] state;
    reg [BEAT_COUNT_WIDTH-1:0] beat_count;
    reg [31:0] timeout_count;
    wire expected_last = (beat_count == BEATS_PER_VECTOR-1);
    wire r_handshake = m_axi_rvalid && m_axi_rready;

    assign m_axi_arid    = {ID_WIDTH{1'b0}};
    assign m_axi_arlen   = BEATS_PER_VECTOR - 1;
    assign m_axi_arsize  = $clog2(BYTES_PER_BEAT);
    assign m_axi_arburst = 2'b01; // INCR
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0010; // normal, non-cacheable bufferable read
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;

    // Consume and replace the one-beat buffer in the same cycle when possible.
    assign m_axi_rready = (state == S_DATA) && (!beat_valid || beat_ready);

    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            error         <= 1'b0;
            error_code    <= 4'd0;
            beat_data     <= {DATA_WIDTH{1'b0}};
            beat_valid    <= 1'b0;
            beat_last     <= 1'b0;
            beat_count    <= {BEAT_COUNT_WIDTH{1'b0}};
            timeout_count <= 32'd0;
            m_axi_araddr  <= {ADDR_WIDTH{1'b0}};
            m_axi_arvalid <= 1'b0;
        end else begin
            done  <= 1'b0;
            error <= 1'b0;

            if (beat_valid && beat_ready)
                beat_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    timeout_count <= 32'd0;
                    if (start) begin
                        busy          <= 1'b1;
                        beat_valid    <= 1'b0;
                        beat_count    <= {BEAT_COUNT_WIDTH{1'b0}};
                        m_axi_araddr  <= vector_addr;
                        m_axi_arvalid <= 1'b1;
                        state         <= S_ADDR;
                    end
                end

                S_ADDR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        timeout_count <= 32'd0;
                        state         <= S_DATA;
                    end else if (timeout_count >= TIMEOUT_CYCLES-1) begin
                        m_axi_arvalid <= 1'b0;
                        busy          <= 1'b0;
                        error         <= 1'b1;
                        error_code    <= 4'h1; // address-channel timeout
                        state         <= S_IDLE;
                    end else begin
                        timeout_count <= timeout_count + 1'b1;
                    end
                end

                S_DATA: begin
                    // Consumer stalls are not memory timeouts. Count only when
                    // the skid buffer is empty and the memory owes us a beat.
                    if (r_handshake) begin
                        timeout_count <= 32'd0;
                        if (m_axi_rresp != 2'b00) begin
                            beat_valid <= 1'b0;
                            busy       <= 1'b0;
                            error      <= 1'b1;
                            error_code <= 4'h3; // SLVERR/DECERR
                            state      <= S_IDLE;
                        end else if (m_axi_rlast != expected_last) begin
                            beat_valid <= 1'b0;
                            busy       <= 1'b0;
                            error      <= 1'b1;
                            error_code <= 4'h4; // malformed burst length
                            state      <= S_IDLE;
                        end else begin
                            beat_data  <= m_axi_rdata;
                            beat_valid <= 1'b1;
                            beat_last  <= expected_last;
                            if (expected_last) begin
                                busy       <= 1'b0;
                                done       <= 1'b1;
                                beat_count <= {BEAT_COUNT_WIDTH{1'b0}};
                                state      <= S_IDLE;
                            end else begin
                                beat_count <= beat_count + 1'b1;
                            end
                        end
                    end else if (!beat_valid) begin
                        if (timeout_count >= TIMEOUT_CYCLES-1) begin
                            busy       <= 1'b0;
                            error      <= 1'b1;
                            error_code <= 4'h2; // read-data timeout
                            state      <= S_IDLE;
                        end else begin
                            timeout_count <= timeout_count + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // RID is intentionally ignored: this reader issues one transaction at a
    // time with a constant ID, so ordering is implicit.
    wire unused_rid = ^m_axi_rid;

`ifndef SYNTHESIS
    initial begin
        if (VECTOR_BITS % DATA_WIDTH != 0)
            $error("kv_reader: DATA_WIDTH must divide VECTOR_BITS");
        if (DATA_WIDTH % 8 != 0)
            $error("kv_reader: DATA_WIDTH must be byte aligned");
        if (BEATS_PER_VECTOR < 1 || BEATS_PER_VECTOR > 256)
            $error("kv_reader: unsupported beats per vector");
    end
`endif
endmodule

`default_nettype wire
