// axi_v5_av_diag.v -- raw-V5 AXI reader and AV-numerator diagnostic wrapper.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// This checkpoint-independent diagnostic ABI is intentionally separate from
// axi_kv_cache ABI v2.  Only the dense V5 rows live in DDR in this phase.
// Exponents and UQ4.8 scales are loaded into small AXI-Lite memories; the
// physical scale-plane prefetcher belongs to the later page/integrity phase.
module axi_v5_av_diag #(
    parameter integer MAX_CONTEXT         = 128,
    parameter integer MULT_STYLE          = 2,
    parameter integer C_S_AXI_DATA_WIDTH  = 32,
    parameter integer C_S_AXI_ADDR_WIDTH  = 16,
    parameter integer M_AXI_ADDR_WIDTH    = 32,
    parameter integer M_AXI_DATA_WIDTH    = 64,
    parameter integer M_AXI_ID_WIDTH      = 1,
    parameter integer TIMEOUT_CYCLES      = 65536,
    parameter integer SCALE_WIDTH         = 12
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
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_V_BASE_LO  = 16'h0008;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_V_BASE_HI  = 16'h000c;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_EXP_COUNT  = 16'h0014;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_SCALE_COUNT= 16'h0018;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_CONTEXT    = 16'h001c;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_PROGRESS   = 16'h0020;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_ERROR      = 16'h002c;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_PERF       = 16'h0028;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_ID         = 16'h0030;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_GEOMETRY   = 16'h0034;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_V_STRIDE   = 16'h0038;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_CAPS       = 16'h003c;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_READ_BEATS = 16'h0040;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_AR_STALLS  = 16'h0044;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_R_STALLS   = 16'h0048;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] REG_SCALE_FMT  = 16'h004c;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] RESULT_BASE    = 16'h1000;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] EXP_BASE       = 16'h3000;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] SCALE_BASE     = 16'h4000;

    localparam [31:0] CORE_ID = 32'h4b56_0301;
    localparam [31:0] GEOMETRY =
        ((M_AXI_DATA_WIDTH & 8'hff) << 24) |
        (8'd128 << 16) | (8'd16 << 8) | 8'd5;
    localparam [31:0] CAPS = 32'h0000_001f; // raw/numerator/local-exp/local-scale/abort
    localparam [7:0] ERR_ADDRESS_RANGE    = 8'h04;
    localparam [7:0] ERR_METADATA_COUNTS  = 8'h21;
    localparam [7:0] ERR_METADATA_FORMAT  = 8'h22;
    localparam [7:0] ERR_START_WHILE_BUSY = 8'h80;
    localparam [7:0] ERR_CTRL_CONFLICT    = 8'h82;
    localparam [7:0] ERR_WRITE_WHILE_BUSY = 8'h83;

    reg aw_hold, w_hold;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
    reg [C_S_AXI_DATA_WIDTH-1:0] wdata_hold;
    reg [(C_S_AXI_DATA_WIDTH/8)-1:0] wstrb_hold;
    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready  = !w_hold  && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    reg [63:0] v_base_reg;
    reg [31:0] context_len_reg, exp_count_reg, scale_count_reg;
    reg done_sticky, error_sticky, aborted_sticky, result_valid_sticky;
    reg metadata_format_error;
    reg [7:0] error_code_reg;
    reg engine_start, engine_abort;

    // Four head banks provide the four exponent reads needed per token.
    reg [15:0] exp_mem [0:3][0:MAX_CONTEXT-1];
    reg [SCALE_WIDTH-1:0] scale_mem [0:MAX_CONTEXT-1];
    // Serialize each 16-lane result beat into one true dual-port block RAM.
    // A second asynchronous 512x48 bank dissolves into flip-flops and exceeds
    // the XC7Z020 slice budget once the existing ABI-v2 block is present.
    (* ram_style = "block" *)
    reg signed [47:0] result_mem [0:511];
    reg capture_active, capture_last;
    reg [3:0] capture_lane;
    reg [8:0] capture_base;
    reg [767:0] capture_numerators;

    wire engine_busy, engine_draining, engine_done, engine_aborted;
    wire engine_error_valid;
    wire [7:0] engine_error_code;
    wire [31:0] engine_perf_cycles, engine_read_beats;
    wire [31:0] engine_ar_stall_cycles, engine_r_stall_cycles;
    wire [31:0] engine_progress;
    wire [6:0] engine_progress_token;
    wire [1:0] engine_progress_head;
    wire [2:0] engine_progress_group;
    wire [3:0] engine_progress_state;
    wire engine_result_valid, engine_result_ready, engine_result_last;
    wire [1:0] engine_result_head;
    wire [2:0] engine_result_group;
    wire [767:0] engine_result_numerators;

    wire meta_req_valid, meta_req_ready;
    wire [6:0] meta_req_token;
    reg meta_rsp_valid;
    wire meta_rsp_ready;
    reg [SCALE_WIDTH-1:0] meta_rsp_scale;
    reg [63:0] meta_rsp_exp_codes;
    assign meta_req_ready = !meta_rsp_valid;

    wire address_out_of_range = |(v_base_reg >> M_AXI_ADDR_WIDTH);
    assign engine_progress = {engine_progress_state, 5'd0,
        engine_progress_group, 2'd0, engine_progress_head, 3'd0,
        6'd0, engine_progress_token};
    wire diag_busy = engine_busy || capture_active;
    assign engine_result_ready = !capture_active;

    kv_v03_raw_v5_av_engine #(
        .MAX_CONTEXT(MAX_CONTEXT), .MULT_STYLE(MULT_STYLE),
        .AXI_ADDR_WIDTH(M_AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH(M_AXI_DATA_WIDTH),
        .AXI_ID_WIDTH(M_AXI_ID_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .SCALE_WIDTH(SCALE_WIDTH)
    ) u_engine (
        .clk(clk), .rst_n(rst_n), .start(engine_start),
        .abort(engine_abort),
        .v_base_addr(v_base_reg[M_AXI_ADDR_WIDTH-1:0]),
        .context_len(context_len_reg[12:0]),
        .meta_req_valid(meta_req_valid), .meta_req_ready(meta_req_ready),
        .meta_req_token(meta_req_token),
        .meta_rsp_valid(meta_rsp_valid), .meta_rsp_ready(meta_rsp_ready),
        .meta_scale(meta_rsp_scale),
        .meta_exp_codes(meta_rsp_exp_codes),
        .busy(engine_busy), .draining(engine_draining),
        .done(engine_done), .aborted(engine_aborted),
        .error(engine_error_valid), .error_code(engine_error_code),
        .perf_cycles(engine_perf_cycles), .read_beats(engine_read_beats),
        .ar_stall_cycles(engine_ar_stall_cycles),
        .r_stall_cycles(engine_r_stall_cycles),
        .progress_token(engine_progress_token),
        .progress_head(engine_progress_head),
        .progress_group(engine_progress_group),
        .progress_state(engine_progress_state),
        .result_valid(engine_result_valid),
        .result_ready(engine_result_ready),
        .result_head(engine_result_head),
        .result_group(engine_result_group),
        .result_numerators(engine_result_numerators),
        .result_last(engine_result_last),
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

    integer write_index;
    integer read_index;
    reg [15:0] low_slot, high_slot;
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_hold             <= 1'b0;
            w_hold              <= 1'b0;
            awaddr_hold         <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_hold          <= {C_S_AXI_DATA_WIDTH{1'b0}};
            wstrb_hold          <= {(C_S_AXI_DATA_WIDTH/8){1'b0}};
            s_axi_bvalid        <= 1'b0;
            s_axi_rvalid        <= 1'b0;
            s_axi_rdata         <= {C_S_AXI_DATA_WIDTH{1'b0}};
            v_base_reg          <= 64'd0;
            context_len_reg     <= 32'd0;
            exp_count_reg       <= 32'd0;
            scale_count_reg     <= 32'd0;
            done_sticky         <= 1'b0;
            error_sticky        <= 1'b0;
            aborted_sticky      <= 1'b0;
            result_valid_sticky <= 1'b0;
            metadata_format_error <= 1'b0;
            error_code_reg      <= 8'd0;
            engine_start        <= 1'b0;
            engine_abort        <= 1'b0;
            meta_rsp_valid      <= 1'b0;
            meta_rsp_scale      <= {SCALE_WIDTH{1'b0}};
            meta_rsp_exp_codes  <= 64'd0;
            capture_active      <= 1'b0;
            capture_last        <= 1'b0;
            capture_lane        <= 4'd0;
            capture_base        <= 9'd0;
            capture_numerators  <= 768'd0;
        end else begin
            engine_start <= 1'b0;
            engine_abort <= 1'b0;

            if (meta_rsp_valid && meta_rsp_ready)
                meta_rsp_valid <= 1'b0;
            if (meta_req_valid && meta_req_ready) begin
                meta_rsp_valid <= 1'b1;
                meta_rsp_scale <= scale_mem[meta_req_token];
                meta_rsp_exp_codes <= {
                    exp_mem[3][meta_req_token],
                    exp_mem[2][meta_req_token],
                    exp_mem[1][meta_req_token],
                    exp_mem[0][meta_req_token]};
            end

            if (engine_result_valid && engine_result_ready) begin
                capture_active     <= 1'b1;
                capture_last       <= engine_result_last;
                capture_lane       <= 4'd0;
                capture_base       <= {engine_result_head,
                                       engine_result_group, 4'b0000};
                capture_numerators <= engine_result_numerators;
            end
            if (capture_active) begin
                result_mem[capture_base + capture_lane] <=
                    capture_numerators[(capture_lane*48) +: 48];
                if (capture_lane == 4'd15) begin
                    capture_active <= 1'b0;
                    if (capture_last && !error_sticky && !aborted_sticky) begin
                        done_sticky         <= 1'b1;
                        result_valid_sticky <= 1'b1;
                    end
                end else begin
                    capture_lane <= capture_lane + 1'b1;
                end
            end
            if (engine_aborted) begin
                capture_active      <= 1'b0;
                aborted_sticky      <= 1'b1;
                done_sticky         <= 1'b0;
                result_valid_sticky <= 1'b0;
            end
            // Preserve the first fault until software explicitly clears it.
            if (engine_error_valid && !error_sticky) begin
                capture_active      <= 1'b0;
                error_sticky        <= 1'b1;
                error_code_reg      <= engine_error_code;
                done_sticky         <= 1'b0;
                result_valid_sticky <= 1'b0;
            end

            if (s_axi_awready && s_axi_awvalid) begin
                aw_hold     <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                w_hold     <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end
            if (aw_hold && w_hold && !s_axi_bvalid) begin
                aw_hold      <= 1'b0;
                w_hold       <= 1'b0;
                s_axi_bvalid <= 1'b1;

                if (diag_busy && awaddr_hold != REG_CTRL) begin
                    engine_abort        <= engine_busy;
                    capture_active      <= 1'b0;
                    done_sticky         <= 1'b0;
                    error_sticky        <= 1'b1;
                    aborted_sticky      <= 1'b1;
                    result_valid_sticky <= 1'b0;
                    error_code_reg      <= ERR_WRITE_WHILE_BUSY;
                    meta_rsp_valid      <= 1'b0;
                end else begin
                    case (awaddr_hold)
                        REG_CTRL: begin
                            if (wstrb_hold[0]) begin
                                case (wdata_hold[2:0])
                                    3'b001: begin
                                        if (diag_busy) begin
                                            engine_abort        <= engine_busy;
                                            capture_active      <= 1'b0;
                                            done_sticky         <= 1'b0;
                                            error_sticky        <= 1'b1;
                                            aborted_sticky      <= 1'b1;
                                            result_valid_sticky <= 1'b0;
                                            error_code_reg      <= ERR_START_WHILE_BUSY;
                                        end else if (address_out_of_range) begin
                                            done_sticky         <= 1'b0;
                                            error_sticky        <= 1'b1;
                                            aborted_sticky      <= 1'b0;
                                            result_valid_sticky <= 1'b0;
                                            error_code_reg      <= ERR_ADDRESS_RANGE;
                                        end else if (exp_count_reg != context_len_reg ||
                                                     scale_count_reg != context_len_reg) begin
                                            done_sticky         <= 1'b0;
                                            error_sticky        <= 1'b1;
                                            aborted_sticky      <= 1'b0;
                                            result_valid_sticky <= 1'b0;
                                            error_code_reg      <= ERR_METADATA_COUNTS;
                                        end else if (metadata_format_error) begin
                                            done_sticky         <= 1'b0;
                                            error_sticky        <= 1'b1;
                                            aborted_sticky      <= 1'b0;
                                            result_valid_sticky <= 1'b0;
                                            error_code_reg      <= ERR_METADATA_FORMAT;
                                        end else begin
                                            done_sticky         <= 1'b0;
                                            error_sticky        <= 1'b0;
                                            aborted_sticky      <= 1'b0;
                                            result_valid_sticky <= 1'b0;
                                            error_code_reg      <= 8'd0;
                                            meta_rsp_valid      <= 1'b0;
                                            engine_start        <= 1'b1;
                                        end
                                    end
                                    3'b010: begin
                                        if (diag_busy) begin
                                            engine_abort        <= engine_busy;
                                            capture_active      <= 1'b0;
                                            done_sticky         <= 1'b0;
                                            error_sticky        <= 1'b1;
                                            aborted_sticky      <= 1'b1;
                                            result_valid_sticky <= 1'b0;
                                            error_code_reg      <= ERR_WRITE_WHILE_BUSY;
                                        end else begin
                                            done_sticky         <= 1'b0;
                                            error_sticky        <= 1'b0;
                                            aborted_sticky      <= 1'b0;
                                            result_valid_sticky <= 1'b0;
                                            metadata_format_error <= 1'b0;
                                            error_code_reg      <= 8'd0;
                                            meta_rsp_valid      <= 1'b0;
                                        end
                                    end
                                    3'b100: begin
                                        engine_abort        <= engine_busy;
                                        capture_active      <= 1'b0;
                                        done_sticky         <= 1'b0;
                                        error_sticky        <= 1'b0;
                                        aborted_sticky      <= diag_busy;
                                        result_valid_sticky <= 1'b0;
                                        error_code_reg      <= 8'd0;
                                        meta_rsp_valid      <= 1'b0;
                                    end
                                    3'b000: begin end
                                    default: begin
                                        engine_abort        <= engine_busy;
                                        capture_active      <= 1'b0;
                                        done_sticky         <= 1'b0;
                                        error_sticky        <= 1'b1;
                                        aborted_sticky      <= diag_busy;
                                        result_valid_sticky <= 1'b0;
                                        error_code_reg      <= ERR_CTRL_CONFLICT;
                                        meta_rsp_valid      <= 1'b0;
                                    end
                                endcase
                            end
                        end
                        REG_V_BASE_LO:
                            v_base_reg[31:0] <= merge_wstrb(
                                v_base_reg[31:0], wdata_hold, wstrb_hold);
                        REG_V_BASE_HI:
                            v_base_reg[63:32] <= merge_wstrb(
                                v_base_reg[63:32], wdata_hold, wstrb_hold);
                        REG_EXP_COUNT:
                            exp_count_reg <= merge_wstrb(
                                exp_count_reg, wdata_hold, wstrb_hold);
                        REG_SCALE_COUNT:
                            scale_count_reg <= merge_wstrb(
                                scale_count_reg, wdata_hold, wstrb_hold);
                        REG_CONTEXT:
                            context_len_reg <= merge_wstrb(
                                context_len_reg, wdata_hold, wstrb_hold);
                        default: begin
                            if (awaddr_hold >= EXP_BASE &&
                                awaddr_hold < EXP_BASE + (MAX_CONTEXT*8) &&
                                awaddr_hold[1:0] == 2'b00) begin
                                write_index = (awaddr_hold - EXP_BASE) >> 1;
                                if (wstrb_hold[0])
                                    exp_mem[write_index % 4]
                                           [write_index / 4][7:0] <= wdata_hold[7:0];
                                if (wstrb_hold[1])
                                    exp_mem[write_index % 4]
                                           [write_index / 4][15:8] <= wdata_hold[15:8];
                                if (wstrb_hold[2])
                                    exp_mem[(write_index+1) % 4]
                                           [(write_index+1) / 4][7:0] <= wdata_hold[23:16];
                                if (wstrb_hold[3])
                                    exp_mem[(write_index+1) % 4]
                                           [(write_index+1) / 4][15:8] <= wdata_hold[31:24];
                            end else if (awaddr_hold >= SCALE_BASE &&
                                awaddr_hold < SCALE_BASE + (MAX_CONTEXT*2) &&
                                awaddr_hold[1:0] == 2'b00) begin
                                write_index = (awaddr_hold - SCALE_BASE) >> 1;
                                low_slot = {{(16-SCALE_WIDTH){1'b0}},
                                            scale_mem[write_index]};
                                high_slot = {{(16-SCALE_WIDTH){1'b0}},
                                             scale_mem[write_index+1]};
                                if (wstrb_hold[0]) low_slot[7:0] = wdata_hold[7:0];
                                if (wstrb_hold[1]) low_slot[15:8] = wdata_hold[15:8];
                                if (wstrb_hold[2]) high_slot[7:0] = wdata_hold[23:16];
                                if (wstrb_hold[3]) high_slot[15:8] = wdata_hold[31:24];
                                scale_mem[write_index] <=
                                    low_slot[SCALE_WIDTH-1:0];
                                scale_mem[write_index+1] <=
                                    high_slot[SCALE_WIDTH-1:0];
                                if (SCALE_WIDTH == 12 &&
                                    (low_slot[15:12] != 0 ||
                                     high_slot[15:12] != 0))
                                    metadata_format_error <= 1'b1;
                            end
                        end
                    endcase
                end
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr)
                    REG_CTRL:        s_axi_rdata <= 32'd0;
                    REG_STATUS:      s_axi_rdata <= {27'd0, result_valid_sticky,
                        engine_draining, error_sticky, done_sticky, diag_busy};
                    REG_V_BASE_LO:   s_axi_rdata <= v_base_reg[31:0];
                    REG_V_BASE_HI:   s_axi_rdata <= v_base_reg[63:32];
                    REG_EXP_COUNT:   s_axi_rdata <= exp_count_reg;
                    REG_SCALE_COUNT: s_axi_rdata <= scale_count_reg;
                    REG_CONTEXT:     s_axi_rdata <= context_len_reg;
                    REG_PROGRESS:    s_axi_rdata <= engine_progress;
                    REG_ERROR:       s_axi_rdata <= {23'd0, aborted_sticky,
                                                     error_code_reg};
                    REG_PERF:        s_axi_rdata <= engine_perf_cycles;
                    REG_ID:          s_axi_rdata <= CORE_ID;
                    REG_GEOMETRY:    s_axi_rdata <= GEOMETRY;
                    REG_V_STRIDE:    s_axi_rdata <= 32'd80;
                    REG_CAPS:        s_axi_rdata <= CAPS;
                    REG_READ_BEATS:  s_axi_rdata <= engine_read_beats;
                    REG_AR_STALLS:   s_axi_rdata <= engine_ar_stall_cycles;
                    REG_R_STALLS:    s_axi_rdata <= engine_r_stall_cycles;
                    REG_SCALE_FMT:   s_axi_rdata <=
                        (SCALE_WIDTH == 12) ? 32'h0000_0c08 : 32'h0000_100b;
                    default: begin
                        if (s_axi_araddr >= RESULT_BASE &&
                            s_axi_araddr < RESULT_BASE + 16'h1000 &&
                            s_axi_araddr[1:0] == 2'b00) begin
                            read_index = (s_axi_araddr - RESULT_BASE) >> 3;
                            if (!result_valid_sticky)
                                s_axi_rdata <= 32'd0;
                            else if (!s_axi_araddr[2])
                                s_axi_rdata <= result_mem[read_index][31:0];
                            else
                                s_axi_rdata <= {{16{result_mem[read_index][47]}},
                                                result_mem[read_index][47:32]};
                        end else if (s_axi_araddr >= EXP_BASE &&
                            s_axi_araddr < EXP_BASE + (MAX_CONTEXT*8) &&
                            s_axi_araddr[1:0] == 2'b00) begin
                            read_index = (s_axi_araddr - EXP_BASE) >> 1;
                            s_axi_rdata <= {
                                exp_mem[(read_index+1) % 4]
                                       [(read_index+1) / 4],
                                exp_mem[read_index % 4][read_index / 4]};
                        end else if (s_axi_araddr >= SCALE_BASE &&
                            s_axi_araddr < SCALE_BASE + (MAX_CONTEXT*2) &&
                            s_axi_araddr[1:0] == 2'b00) begin
                            read_index = (s_axi_araddr - SCALE_BASE) >> 1;
                            s_axi_rdata <= {
                                {{(16-SCALE_WIDTH){1'b0}},
                                 scale_mem[read_index+1]},
                                {{(16-SCALE_WIDTH){1'b0}},
                                 scale_mem[read_index]}};
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

    wire unused_prot = ^s_axi_awprot ^ ^s_axi_arprot ^ engine_result_last;

`ifndef SYNTHESIS
    initial begin
        if (C_S_AXI_DATA_WIDTH != 32)
            $error("axi_v5_av_diag requires a 32-bit AXI-Lite port");
        if (C_S_AXI_ADDR_WIDTH != 16)
            $error("axi_v5_av_diag v1 requires a 16-bit AXI-Lite address port");
        if (M_AXI_DATA_WIDTH != 64 && M_AXI_DATA_WIDTH != 128)
            $error("axi_v5_av_diag supports 64- or 128-bit V readers");
        if (M_AXI_ADDR_WIDTH != 32)
            $error("axi_v5_av_diag v1 requires a 32-bit DDR address port");
        if (MAX_CONTEXT < 1 || MAX_CONTEXT > 128)
            $error("axi_v5_av_diag MAX_CONTEXT must be 1..128");
        if ((MAX_CONTEXT % 2) != 0)
            $error("axi_v5_av_diag MAX_CONTEXT must be even for paired metadata words");
        if (SCALE_WIDTH != 12 && SCALE_WIDTH != 16)
            $error("axi_v5_av_diag SCALE_WIDTH must be 12 or 16");
    end
`endif
endmodule

`default_nettype wire
