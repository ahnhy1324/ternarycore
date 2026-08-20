// axi_kvq_raw_attention_diag.v -- canned raw score/softmax/V5/AV diagnostic.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module axi_kvq_raw_attention_diag #(
    parameter integer MAX_CONTEXT = 128,
    parameter integer SCALE_WIDTH = 12,
    parameter integer MULT_STYLE = 2,
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 16,
    parameter integer M_AXI_ADDR_WIDTH = 32,
    parameter integer M_AXI_DATA_WIDTH = 64,
    parameter integer M_AXI_ID_WIDTH = 1,
    parameter integer TIMEOUT_CYCLES = 65536
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
    localparam [15:0] REG_CTRL        = 16'h0000;
    localparam [15:0] REG_STATUS      = 16'h0004;
    localparam [15:0] REG_V_BASE_LO   = 16'h0008;
    localparam [15:0] REG_V_BASE_HI   = 16'h000c;
    localparam [15:0] REG_CONTEXT     = 16'h0010;
    localparam [15:0] REG_SCORE_COUNT = 16'h0014;
    localparam [15:0] REG_SCALE_COUNT = 16'h0018;
    localparam [15:0] REG_ERROR       = 16'h001c;
    localparam [15:0] REG_PERF        = 16'h0020;
    localparam [15:0] REG_READ_BEATS  = 16'h0024;
    localparam [15:0] REG_AR_STALLS   = 16'h0028;
    localparam [15:0] REG_R_STALLS    = 16'h002c;
    localparam [15:0] REG_ID          = 16'h0030;
    localparam [15:0] REG_GEOMETRY    = 16'h0034;
    localparam [15:0] REG_SCALE_FMT   = 16'h0038;
    localparam [15:0] REG_SAT_COUNT   = 16'h003c;
    localparam [15:0] REG_DENOM0      = 16'h0040;
    localparam [15:0] REG_DENOM1      = 16'h0044;
    localparam [15:0] REG_DENOM2      = 16'h0048;
    localparam [15:0] REG_DENOM3      = 16'h004c;
    localparam [15:0] REG_RECIP0      = 16'h0050;
    localparam [15:0] REG_RECIP1      = 16'h0054;
    localparam [15:0] REG_RECIP2      = 16'h0058;
    localparam [15:0] REG_RECIP3      = 16'h005c;
    localparam [15:0] SCORE_BASE      = 16'h1000;
    localparam [15:0] SCALE_BASE      = 16'h2000;
    localparam [15:0] RESULT_BASE     = 16'h4000;
    localparam [31:0] CORE_ID         = 32'h4b56_0302;
    localparam [7:0] ERR_CONTEXT      = 8'h01;
    localparam [7:0] ERR_ADDRESS      = 8'h04;
    localparam [7:0] ERR_COUNTS       = 8'h21;
    localparam [7:0] ERR_SCALE_FORMAT = 8'h22;
    localparam [7:0] ERR_CTRL         = 8'h82;
    localparam [7:0] ERR_BUSY_WRITE   = 8'h83;

    reg aw_hold, w_hold;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
    reg [31:0] wdata_hold;
    reg [3:0] wstrb_hold;
    wire [2:0] ctrl_effective = wdata_hold[2:0] &
                                {3{wstrb_hold[0]}};
    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready = !w_hold && !s_axi_bvalid;
    assign s_axi_bresp = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp = 2'b00;

    reg [63:0] v_base_reg;
    reg [31:0] context_reg, score_count_reg, scale_count_reg;
    reg done_sticky, error_sticky, aborted_sticky, result_valid_sticky;
    reg [7:0] error_code_reg;
    reg pipeline_start, pipeline_abort;
    reg score_wr_en_reg, scale_wr_en_reg;
    reg [1:0] score_wr_row_reg;
    reg [11:0] score_wr_addr_reg;
    reg signed [15:0] score_wr_data_reg;
    reg [6:0] scale_wr_addr_reg;
    reg [SCALE_WIDTH-1:0] scale_wr_data_reg;

    wire pipeline_score_ready, pipeline_scale_ready;
    wire pipeline_result_valid;
    wire [1:0] pipeline_result_head;
    wire [6:0] pipeline_result_dimension;
    wire signed [47:0] pipeline_result_numerator;
    wire signed [17:0] pipeline_result_code;
    wire pipeline_result_saturated, pipeline_result_last;
    wire pipeline_busy, pipeline_done, pipeline_aborted;
    wire pipeline_error_valid;
    wire [7:0] pipeline_error_code;
    wire [31:0] pipeline_perf, pipeline_read_beats;
    wire [31:0] pipeline_ar_stalls, pipeline_r_stalls;
    wire [15:0] pipeline_saturation_count;
    wire [111:0] pipeline_denominators;
    wire [51:0] pipeline_reciprocals;
    wire [19:0] pipeline_reciprocal_exponents;

    (* ram_style = "block" *) reg [66:0] result_mem [0:511];
    wire [8:0] pipeline_result_index =
        {pipeline_result_head, pipeline_result_dimension};

    kv_v03_softmax_av_pipeline #(
        .MAX_CONTEXT(MAX_CONTEXT), .SCALE_WIDTH(SCALE_WIDTH),
        .MULT_STYLE(MULT_STYLE), .AXI_ADDR_WIDTH(M_AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(M_AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(M_AXI_ID_WIDTH), .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_pipeline (
        .clk(clk), .rst_n(rst_n), .start(pipeline_start),
        .abort(pipeline_abort), .context_len(context_reg[12:0]),
        .v_base_addr(v_base_reg[M_AXI_ADDR_WIDTH-1:0]),
        .score_wr_en(score_wr_en_reg), .score_wr_row(score_wr_row_reg),
        .score_wr_addr(score_wr_addr_reg),
        .score_wr_data(score_wr_data_reg),
        .score_wr_ready(pipeline_score_ready),
        .scale_wr_en(scale_wr_en_reg), .scale_wr_addr(scale_wr_addr_reg),
        .scale_wr_data(scale_wr_data_reg),
        .scale_wr_ready(pipeline_scale_ready),
        .result_valid(pipeline_result_valid), .result_ready(1'b1),
        .result_head(pipeline_result_head),
        .result_dimension(pipeline_result_dimension),
        .result_numerator(pipeline_result_numerator),
        .result_code(pipeline_result_code),
        .result_saturated(pipeline_result_saturated),
        .result_last(pipeline_result_last), .busy(pipeline_busy),
        .done(pipeline_done), .aborted(pipeline_aborted),
        .error_valid(pipeline_error_valid),
        .error_code(pipeline_error_code), .perf_cycles(pipeline_perf),
        .read_beats(pipeline_read_beats),
        .ar_stall_cycles(pipeline_ar_stalls),
        .r_stall_cycles(pipeline_r_stalls),
        .saturation_count(pipeline_saturation_count),
        .denominators(pipeline_denominators),
        .reciprocal_codes(pipeline_reciprocals),
        .reciprocal_exponents(pipeline_reciprocal_exponents),
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
                    merge_wstrb[byte_index*8 +: 8] =
                        new_value[byte_index*8 +: 8];
        end
    endfunction

    integer write_index;
    integer read_index;
    reg [15:0] scale_slot;
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_hold              <= 1'b0;
            w_hold               <= 1'b0;
            awaddr_hold          <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_hold           <= 32'd0;
            wstrb_hold           <= 4'd0;
            s_axi_bvalid         <= 1'b0;
            s_axi_rvalid         <= 1'b0;
            s_axi_rdata          <= 32'd0;
            v_base_reg           <= 64'd0;
            context_reg          <= 32'd0;
            score_count_reg      <= 32'd0;
            scale_count_reg      <= 32'd0;
            done_sticky          <= 1'b0;
            error_sticky         <= 1'b0;
            aborted_sticky       <= 1'b0;
            result_valid_sticky  <= 1'b0;
            error_code_reg       <= 8'd0;
            pipeline_start       <= 1'b0;
            pipeline_abort       <= 1'b0;
            score_wr_en_reg      <= 1'b0;
            scale_wr_en_reg      <= 1'b0;
            score_wr_row_reg     <= 2'd0;
            score_wr_addr_reg    <= 12'd0;
            score_wr_data_reg    <= 16'sd0;
            scale_wr_addr_reg    <= 7'd0;
            scale_wr_data_reg    <= {SCALE_WIDTH{1'b0}};
        end else begin
            pipeline_start  <= 1'b0;
            pipeline_abort  <= 1'b0;
            score_wr_en_reg <= 1'b0;
            scale_wr_en_reg <= 1'b0;

            if (pipeline_result_valid) begin
                result_mem[pipeline_result_index] <= {
                    pipeline_result_saturated, pipeline_result_code,
                    pipeline_result_numerator};
            end
            if (pipeline_done) begin
                done_sticky         <= 1'b1;
                result_valid_sticky <= 1'b1;
            end
            if (pipeline_aborted) begin
                aborted_sticky      <= 1'b1;
                result_valid_sticky <= 1'b0;
            end
            if (pipeline_error_valid) begin
                error_sticky        <= 1'b1;
                error_code_reg      <= pipeline_error_code;
                result_valid_sticky <= 1'b0;
            end

            if (s_axi_awvalid && s_axi_awready) begin
                aw_hold     <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_hold     <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end
            if (aw_hold && w_hold && !s_axi_bvalid) begin
                aw_hold      <= 1'b0;
                w_hold       <= 1'b0;
                s_axi_bvalid <= 1'b1;
                if (pipeline_busy && awaddr_hold != REG_CTRL) begin
                    error_sticky        <= 1'b1;
                    error_code_reg      <= ERR_BUSY_WRITE;
                    result_valid_sticky <= 1'b0;
                    pipeline_abort      <= 1'b1;
                end else begin
                    case (awaddr_hold)
                        REG_CTRL: begin
                            if ((ctrl_effective[0] && ctrl_effective[1]) ||
                                (ctrl_effective[0] && ctrl_effective[2]) ||
                                (ctrl_effective[1] && ctrl_effective[2])) begin
                                error_sticky        <= 1'b1;
                                error_code_reg      <= ERR_CTRL;
                                result_valid_sticky <= 1'b0;
                                if (pipeline_busy)
                                    pipeline_abort <= 1'b1;
                            end else if (ctrl_effective[1]) begin
                                done_sticky         <= 1'b0;
                                error_sticky        <= 1'b0;
                                aborted_sticky      <= 1'b0;
                                result_valid_sticky <= 1'b0;
                                error_code_reg      <= 8'd0;
                            end else if (ctrl_effective[2]) begin
                                pipeline_abort      <= 1'b1;
                                result_valid_sticky <= 1'b0;
                            end else if (ctrl_effective[0]) begin
                                done_sticky         <= 1'b0;
                                error_sticky        <= 1'b0;
                                aborted_sticky      <= 1'b0;
                                result_valid_sticky <= 1'b0;
                                error_code_reg      <= 8'd0;
                                if (context_reg == 0 ||
                                    context_reg > MAX_CONTEXT) begin
                                    error_sticky   <= 1'b1;
                                    error_code_reg <= ERR_CONTEXT;
                                end else if (score_count_reg !=
                                             context_reg*4 ||
                                             scale_count_reg != context_reg) begin
                                    error_sticky   <= 1'b1;
                                    error_code_reg <= ERR_COUNTS;
                                end else if (|(v_base_reg >> M_AXI_ADDR_WIDTH)) begin
                                    error_sticky   <= 1'b1;
                                    error_code_reg <= ERR_ADDRESS;
                                end else begin
                                    pipeline_start <= 1'b1;
                                end
                            end
                        end
                        REG_V_BASE_LO: begin
                            v_base_reg[31:0] <= merge_wstrb(
                                v_base_reg[31:0], wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_V_BASE_HI: begin
                            v_base_reg[63:32] <= merge_wstrb(
                                v_base_reg[63:32], wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_CONTEXT: begin
                            context_reg <= merge_wstrb(
                                context_reg, wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_SCORE_COUNT: begin
                            score_count_reg <= merge_wstrb(
                                score_count_reg, wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        REG_SCALE_COUNT: begin
                            scale_count_reg <= merge_wstrb(
                                scale_count_reg, wdata_hold, wstrb_hold);
                            result_valid_sticky <= 1'b0;
                        end
                        default: begin
                            if (awaddr_hold >= SCORE_BASE &&
                                awaddr_hold < SCORE_BASE + (MAX_CONTEXT*16) &&
                                awaddr_hold[1:0] == 0) begin
                                result_valid_sticky <= 1'b0;
                                if (wstrb_hold != 4'hf) begin
                                    error_sticky   <= 1'b1;
                                    error_code_reg <= ERR_CTRL;
                                end else begin
                                    write_index = (awaddr_hold-SCORE_BASE) >> 2;
                                    score_wr_en_reg   <= 1'b1;
                                    score_wr_row_reg  <= write_index / MAX_CONTEXT;
                                    score_wr_addr_reg <= write_index % MAX_CONTEXT;
                                    score_wr_data_reg <= wdata_hold[15:0];
                                end
                            end else if (awaddr_hold >= SCALE_BASE &&
                                awaddr_hold < SCALE_BASE + (MAX_CONTEXT*4) &&
                                awaddr_hold[1:0] == 0) begin
                                result_valid_sticky <= 1'b0;
                                if (wstrb_hold != 4'hf) begin
                                    error_sticky   <= 1'b1;
                                    error_code_reg <= ERR_CTRL;
                                end else begin
                                    write_index = (awaddr_hold-SCALE_BASE) >> 2;
                                    scale_slot = wdata_hold[15:0];
                                    if (SCALE_WIDTH == 12 &&
                                        scale_slot[15:12] != 0) begin
                                        error_sticky   <= 1'b1;
                                        error_code_reg <= ERR_SCALE_FORMAT;
                                    end else begin
                                        scale_wr_en_reg   <= 1'b1;
                                        scale_wr_addr_reg <= write_index;
                                        scale_wr_data_reg <=
                                            scale_slot[SCALE_WIDTH-1:0];
                                    end
                                end
                            end
                        end
                    endcase
                end
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr)
                    REG_CTRL:        s_axi_rdata <= 32'd0;
                    REG_STATUS:      s_axi_rdata <= {27'd0,
                        result_valid_sticky, aborted_sticky, error_sticky,
                        done_sticky, pipeline_busy};
                    REG_V_BASE_LO:   s_axi_rdata <= v_base_reg[31:0];
                    REG_V_BASE_HI:   s_axi_rdata <= v_base_reg[63:32];
                    REG_CONTEXT:     s_axi_rdata <= context_reg;
                    REG_SCORE_COUNT: s_axi_rdata <= score_count_reg;
                    REG_SCALE_COUNT: s_axi_rdata <= scale_count_reg;
                    REG_ERROR:       s_axi_rdata <= {24'd0, error_code_reg};
                    REG_PERF:        s_axi_rdata <= pipeline_perf;
                    REG_READ_BEATS:  s_axi_rdata <= pipeline_read_beats;
                    REG_AR_STALLS:   s_axi_rdata <= pipeline_ar_stalls;
                    REG_R_STALLS:    s_axi_rdata <= pipeline_r_stalls;
                    REG_ID:          s_axi_rdata <= CORE_ID;
                    REG_GEOMETRY:    s_axi_rdata <=
                        ((M_AXI_DATA_WIDTH & 8'hff) << 24) |
                        (8'd128 << 16) | (8'd18 << 8) | 8'd5;
                    REG_SCALE_FMT:   s_axi_rdata <=
                        (SCALE_WIDTH == 12) ? 32'h0000_0c08 : 32'h0000_100b;
                    REG_SAT_COUNT:   s_axi_rdata <=
                        {16'd0, pipeline_saturation_count};
                    REG_DENOM0:      s_axi_rdata <= {4'd0,
                        pipeline_denominators[27:0]};
                    REG_DENOM1:      s_axi_rdata <= {4'd0,
                        pipeline_denominators[55:28]};
                    REG_DENOM2:      s_axi_rdata <= {4'd0,
                        pipeline_denominators[83:56]};
                    REG_DENOM3:      s_axi_rdata <= {4'd0,
                        pipeline_denominators[111:84]};
                    REG_RECIP0:      s_axi_rdata <= {14'd0,
                        pipeline_reciprocal_exponents[4:0],
                        pipeline_reciprocals[12:0]};
                    REG_RECIP1:      s_axi_rdata <= {14'd0,
                        pipeline_reciprocal_exponents[9:5],
                        pipeline_reciprocals[25:13]};
                    REG_RECIP2:      s_axi_rdata <= {14'd0,
                        pipeline_reciprocal_exponents[14:10],
                        pipeline_reciprocals[38:26]};
                    REG_RECIP3:      s_axi_rdata <= {14'd0,
                        pipeline_reciprocal_exponents[19:15],
                        pipeline_reciprocals[51:39]};
                    default: begin
                        if (s_axi_araddr >= RESULT_BASE &&
                            s_axi_araddr < RESULT_BASE + 16'h2000) begin
                            read_index = (s_axi_araddr-RESULT_BASE) >> 4;
                            if (!result_valid_sticky)
                                s_axi_rdata <= 32'd0;
                            else case (s_axi_araddr[3:2])
                                2'd0: s_axi_rdata <=
                                    result_mem[read_index][31:0];
                                2'd1: s_axi_rdata <=
                                    {{16{result_mem[read_index][47]}},
                                      result_mem[read_index][47:32]};
                                2'd2: s_axi_rdata <= {
                                    result_mem[read_index][66], 13'd0,
                                    result_mem[read_index][65:48]};
                                default: s_axi_rdata <= 32'd0;
                            endcase
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

    wire unused = ^s_axi_awprot ^ ^s_axi_arprot ^ pipeline_score_ready ^
                  pipeline_scale_ready ^ pipeline_result_last;

`ifndef SYNTHESIS
    initial begin
        if (C_S_AXI_DATA_WIDTH != 32 || C_S_AXI_ADDR_WIDTH != 16)
            $error("axi_kvq_raw_attention_diag requires AXI-Lite 32/16");
        if (M_AXI_ADDR_WIDTH != 32)
            $error("axi_kvq_raw_attention_diag requires 32-bit DDR addresses");
        if (M_AXI_DATA_WIDTH != 64 && M_AXI_DATA_WIDTH != 128)
            $error("axi_kvq_raw_attention_diag AXI width must be 64 or 128");
        if (MAX_CONTEXT < 1 || MAX_CONTEXT > 128)
            $error("axi_kvq_raw_attention_diag MAX_CONTEXT must be 1..128");
        if (SCALE_WIDTH != 12 && SCALE_WIDTH != 16)
            $error("axi_kvq_raw_attention_diag SCALE_WIDTH must be 12 or 16");
    end
`endif
endmodule

`default_nettype wire
