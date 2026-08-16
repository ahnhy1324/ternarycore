// axi_kv_cache.v -- AXI4-Lite controlled INT4 KV-cache Q.K accelerator.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module axi_kv_cache #(
    parameter integer HEAD_DIM          = 64,
    parameter integer KV_BITS           = 4,
    parameter integer P                 = 16,
    parameter integer MAX_CONTEXT       = 4096,
    parameter integer Q_WIDTH           = 8,
    parameter integer SCALE_WIDTH       = 16,
    parameter integer SCALE_GROUP_SIZE  = HEAD_DIM,
    parameter integer MULT_STYLE        = 2,
    parameter integer ACC_WIDTH         = 32,
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 16,
    parameter integer M_AXI_ADDR_WIDTH   = 32,
    parameter integer M_AXI_DATA_WIDTH   = 128,
    parameter integer M_AXI_ID_WIDTH     = 1,
    parameter integer TIMEOUT_CYCLES     = 65536
) (
    input  wire clk,
    input  wire rst_n,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [2:0]                    s_axi_awprot,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                          s_axi_wvalid,
    output wire                          s_axi_wready,
    output wire [1:0]                    s_axi_bresp,
    output reg                           s_axi_bvalid,
    input  wire                          s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [2:0]                    s_axi_arprot,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output reg                           s_axi_rvalid,
    input  wire                          s_axi_rready,

    output wire [M_AXI_ID_WIDTH-1:0]     m_axi_arid,
    output wire [M_AXI_ADDR_WIDTH-1:0]   m_axi_araddr,
    output wire [7:0]                    m_axi_arlen,
    output wire [2:0]                    m_axi_arsize,
    output wire [1:0]                    m_axi_arburst,
    output wire                          m_axi_arlock,
    output wire [3:0]                    m_axi_arcache,
    output wire [2:0]                    m_axi_arprot,
    output wire [3:0]                    m_axi_arqos,
    output wire                          m_axi_arvalid,
    input  wire                          m_axi_arready,
    input  wire [M_AXI_ID_WIDTH-1:0]     m_axi_rid,
    input  wire [M_AXI_DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire [1:0]                    m_axi_rresp,
    input  wire                          m_axi_rlast,
    input  wire                          m_axi_rvalid,
    output wire                          m_axi_rready
);
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_CTRL       = 16'h0000;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_STATUS     = 16'h0004;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_K_BASE_LO  = 16'h0008;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_K_BASE_HI  = 16'h000c;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_CONTEXT    = 16'h001c;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_TOKEN_POS  = 16'h0020;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_CFG        = 16'h0024;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_PERF       = 16'h0028;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_ERROR      = 16'h002c;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_ID         = 16'h0030;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_GEOMETRY   = 16'h0034;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] Q_BASE         = 16'h0100;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] LOGIT_BASE     = 16'h1000;
    localparam [31:0] CORE_ID = 32'h4b56_0001; // "KV", ABI v1
    localparam [31:0] GEOMETRY =
        ((M_AXI_DATA_WIDTH & 8'hff) << 24) |
        ((HEAD_DIM         & 8'hff) << 16) |
        ((P                & 8'hff) << 8)  |
        ( KV_BITS          & 8'hff);
    localparam integer TOKEN_WIDTH =
        (MAX_CONTEXT <= 1) ? 1 : $clog2(MAX_CONTEXT);

    reg aw_hold, w_hold;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
    reg [C_S_AXI_DATA_WIDTH-1:0] wdata_hold;
    reg [(C_S_AXI_DATA_WIDTH/8)-1:0] wstrb_hold;
    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready  = !w_hold  && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;

    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    reg [63:0] k_base_reg;
    reg [31:0] context_len_reg;
    reg [31:0] token_pos_reg;
    reg signed [SCALE_WIDTH-1:0] k_scale_reg;
    reg done_sticky, error_sticky;
    reg [7:0] error_code_reg;
    reg engine_start;

    reg [Q_WIDTH-1:0] q_mem [0:HEAD_DIM-1];
    reg signed [ACC_WIDTH-1:0] logit_mem [0:MAX_CONTEXT-1];
    wire [(HEAD_DIM*Q_WIDTH)-1:0] q_vector;
    genvar qg;
    generate
        for (qg = 0; qg < HEAD_DIM; qg = qg + 1) begin : g_q_pack
            assign q_vector[(qg*Q_WIDTH) +: Q_WIDTH] = q_mem[qg];
        end
    endgenerate
    wire [((HEAD_DIM/SCALE_GROUP_SIZE)*SCALE_WIDTH)-1:0] k_scales;
    genvar sg;
    generate
        for (sg = 0; sg < HEAD_DIM/SCALE_GROUP_SIZE; sg = sg + 1) begin : g_scale_compat
            assign k_scales[(sg*SCALE_WIDTH) +: SCALE_WIDTH] = k_scale_reg;
        end
    endgenerate

    wire engine_busy, engine_done, engine_error;
    wire [7:0] engine_error_code;
    wire [31:0] engine_perf_cycles;
    wire engine_logit_valid;
    wire [TOKEN_WIDTH-1:0] engine_logit_index;
    wire signed [ACC_WIDTH-1:0] engine_logit_data;

    kv_cache_engine #(
        .HEAD_DIM(HEAD_DIM), .KV_BITS(KV_BITS),
        .AXI_DATA_WIDTH(M_AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(M_AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(M_AXI_ID_WIDTH), .P(P),
        .MAX_CONTEXT(MAX_CONTEXT), .Q_WIDTH(Q_WIDTH),
        .SCALE_WIDTH(SCALE_WIDTH), .SCALE_GROUP_SIZE(SCALE_GROUP_SIZE),
        .MULT_STYLE(MULT_STYLE),
        .ACC_WIDTH(ACC_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_engine (
        .clk(clk), .rst_n(rst_n), .start(engine_start),
        .k_base_addr(k_base_reg[M_AXI_ADDR_WIDTH-1:0]),
        .context_len(context_len_reg), .q_vector(q_vector),
        .k_scales(k_scales), .busy(engine_busy), .done(engine_done),
        .error(engine_error), .error_code(engine_error_code),
        .perf_cycles(engine_perf_cycles),
        .logit_valid(engine_logit_valid),
        .logit_index(engine_logit_index), .logit_data(engine_logit_data),
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

    function [31:0] merge_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0] strobe;
        integer byte_index;
        begin
            merge_wstrb = old_value;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (strobe[byte_index])
                    merge_wstrb[(byte_index*8) +: 8] =
                        new_value[(byte_index*8) +: 8];
        end
    endfunction

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_hold         <= 1'b0;
            w_hold          <= 1'b0;
            awaddr_hold     <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_hold      <= {C_S_AXI_DATA_WIDTH{1'b0}};
            wstrb_hold      <= {(C_S_AXI_DATA_WIDTH/8){1'b0}};
            s_axi_bvalid    <= 1'b0;
            s_axi_rvalid    <= 1'b0;
            s_axi_rdata     <= {C_S_AXI_DATA_WIDTH{1'b0}};
            k_base_reg      <= 64'd0;
            context_len_reg <= 32'd0;
            token_pos_reg   <= 32'd0;
            k_scale_reg     <= 16'sh0100; // Q8.8 value 1.0
            done_sticky     <= 1'b0;
            error_sticky    <= 1'b0;
            error_code_reg  <= 8'd0;
            engine_start    <= 1'b0;
            for (i = 0; i < HEAD_DIM; i = i + 1)
                q_mem[i] <= {Q_WIDTH{1'b0}};
        end else begin
            engine_start <= 1'b0;

            if (engine_done)
                done_sticky <= 1'b1;
            if (engine_error) begin
                error_sticky   <= 1'b1;
                error_code_reg <= engine_error_code;
            end
            if (engine_logit_valid)
                logit_mem[engine_logit_index] <= engine_logit_data;

            if (s_axi_awready && s_axi_awvalid) begin
                aw_hold     <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                w_hold     <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end

            // AW and W may arrive independently. Commit only after both have
            // been captured, then hold BVALID until the master accepts it.
            if (aw_hold && w_hold && !s_axi_bvalid) begin
                aw_hold      <= 1'b0;
                w_hold       <= 1'b0;
                s_axi_bvalid <= 1'b1;
                case (awaddr_hold)
                    REG_CTRL: begin
                        if (wstrb_hold[0] && wdata_hold[1]) begin
                            done_sticky     <= 1'b0;
                            error_sticky    <= 1'b0;
                            error_code_reg  <= 8'd0;
                        end
                        if (wstrb_hold[0] && wdata_hold[0]) begin
                            if (engine_busy) begin
                                error_sticky   <= 1'b1;
                                error_code_reg <= 8'h80; // start while busy
                            end else begin
                                done_sticky     <= 1'b0;
                                error_sticky    <= 1'b0;
                                error_code_reg  <= 8'd0;
                                engine_start    <= 1'b1;
                            end
                        end
                    end
                    REG_K_BASE_LO:
                        k_base_reg[31:0] <= merge_wstrb(
                            k_base_reg[31:0], wdata_hold, wstrb_hold);
                    REG_K_BASE_HI:
                        k_base_reg[63:32] <= merge_wstrb(
                            k_base_reg[63:32], wdata_hold, wstrb_hold);
                    REG_CONTEXT:
                        context_len_reg <= merge_wstrb(
                            context_len_reg, wdata_hold, wstrb_hold);
                    REG_TOKEN_POS:
                        token_pos_reg <= merge_wstrb(
                            token_pos_reg, wdata_hold, wstrb_hold);
                    REG_CFG: begin
                        if (wstrb_hold[0]) k_scale_reg[7:0]  <= wdata_hold[7:0];
                        if (wstrb_hold[1]) k_scale_reg[15:8] <= wdata_hold[15:8];
                    end
                    default: begin
                        if (awaddr_hold >= Q_BASE &&
                            awaddr_hold < Q_BASE + HEAD_DIM) begin
                            for (i = 0; i < 4; i = i + 1)
                                if (wstrb_hold[i] &&
                                    ((awaddr_hold - Q_BASE + i) < HEAD_DIM))
                                    q_mem[awaddr_hold - Q_BASE + i] <=
                                        wdata_hold[(i*8) +: 8];
                        end
                    end
                endcase
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr)
                    REG_CTRL:
                        s_axi_rdata <= {done_sticky, 28'd0,
                                           error_sticky, engine_busy, 1'b0};
                    REG_STATUS:
                        s_axi_rdata <= {29'd0, error_sticky,
                                           done_sticky, engine_busy};
                    REG_K_BASE_LO: s_axi_rdata <= k_base_reg[31:0];
                    REG_K_BASE_HI: s_axi_rdata <= k_base_reg[63:32];
                    REG_CONTEXT:   s_axi_rdata <= context_len_reg;
                    REG_TOKEN_POS: s_axi_rdata <= token_pos_reg;
                    REG_CFG:       s_axi_rdata <= {{(32-SCALE_WIDTH){k_scale_reg[SCALE_WIDTH-1]}}, k_scale_reg};
                    REG_PERF:      s_axi_rdata <= engine_perf_cycles;
                    REG_ERROR:     s_axi_rdata <= {24'd0, error_code_reg};
                    REG_ID:        s_axi_rdata <= CORE_ID;
                    REG_GEOMETRY:  s_axi_rdata <= GEOMETRY;
                    default: begin
                        if (s_axi_araddr >= Q_BASE &&
                            s_axi_araddr <= Q_BASE + HEAD_DIM - 4 &&
                            s_axi_araddr[1:0] == 2'b00) begin
                            s_axi_rdata <= {
                                q_mem[s_axi_araddr - Q_BASE + 3],
                                q_mem[s_axi_araddr - Q_BASE + 2],
                                q_mem[s_axi_araddr - Q_BASE + 1],
                                q_mem[s_axi_araddr - Q_BASE]
                            };
                        end else if (s_axi_araddr >= LOGIT_BASE &&
                                     s_axi_araddr < LOGIT_BASE + MAX_CONTEXT*4) begin
                            s_axi_rdata <= logit_mem[
                                (s_axi_araddr - LOGIT_BASE) >> 2];
                        end else begin
                            s_axi_rdata <= 32'd0;
                        end
                    end
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    wire unused_prot = ^s_axi_awprot ^ ^s_axi_arprot;

`ifndef SYNTHESIS
    initial begin
        if (C_S_AXI_DATA_WIDTH != 32)
            $error("axi_kv_cache v0.1 requires a 32-bit AXI-Lite data port");
        if (Q_WIDTH != 8)
            $error("axi_kv_cache v0.1 query window is defined for INT8 Q");
        if (SCALE_WIDTH != 16)
            $error("axi_kv_cache v0.1 CFG register is defined for Q8.8 scale");
        if (ACC_WIDTH != 32)
            $error("axi_kv_cache v0.1 logit window is defined for 32-bit results");
    end
`endif
endmodule

`default_nettype wire
