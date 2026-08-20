`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_softmax_av_pipeline;
    localparam [31:0] V_BASE = 32'h0200_0000;
`ifdef SCALE_WIDTH_VAL
    localparam integer SCALE_WIDTH = `SCALE_WIDTH_VAL;
`else
    localparam integer SCALE_WIDTH = 12;
`endif
    localparam [SCALE_WIDTH-1:0] UNIT_SCALE =
        (SCALE_WIDTH == 12) ? 12'd256 : 16'd2048;
    localparam signed [47:0] EXPECTED_NUMERATOR =
        (SCALE_WIDTH == 12) ? 48'sd33554432 : 48'sd268435456;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg abort = 1'b0;
    reg [12:0] context_len = 13'd0;
    reg [31:0] v_base_addr = V_BASE;
    reg score_wr_en = 1'b0;
    reg [1:0] score_wr_row = 2'd0;
    reg [11:0] score_wr_addr = 12'd0;
    reg signed [15:0] score_wr_data = 16'sd0;
    wire score_wr_ready;
    reg scale_wr_en = 1'b0;
    reg [6:0] scale_wr_addr = 7'd0;
    reg [SCALE_WIDTH-1:0] scale_wr_data = {SCALE_WIDTH{1'b0}};
    wire scale_wr_ready;
    wire result_valid;
    reg result_ready = 1'b1;
    wire [1:0] result_head;
    wire [6:0] result_dimension;
    wire signed [47:0] result_numerator;
    wire signed [17:0] result_code;
    wire result_saturated, result_last, busy, done, aborted, error_valid;
    wire [7:0] error_code;
    wire [31:0] perf_cycles, read_beats, ar_stall_cycles, r_stall_cycles;
    wire [15:0] saturation_count;
    wire [111:0] denominators;
    wire [51:0] reciprocal_codes;
    wire [19:0] reciprocal_exponents;

    wire [0:0] m_axi_arid;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_arqos;
    wire m_axi_arvalid;
    reg m_axi_arready = 1'b1;
    reg [0:0] m_axi_rid = 1'b0;
    reg [63:0] m_axi_rdata = 64'd0;
    reg [1:0] m_axi_rresp = 2'b00;
    reg m_axi_rlast = 1'b0;
    reg m_axi_rvalid = 1'b0;
    wire m_axi_rready;

    reg [7:0] vmem [0:159];
    reg response_active = 1'b0;
    reg [31:0] response_addr = 32'd0;
    reg [8:0] response_beats_left = 9'd0;
    integer errors = 0;
    integer result_count = 0;
    integer ar_count = 0;
    integer beat_count = 0;
    integer index;

    kv_v03_softmax_av_pipeline #(
        .MAX_CONTEXT(128), .SCALE_WIDTH(SCALE_WIDTH), .MULT_STYLE(2),
        .AXI_ADDR_WIDTH(32), .AXI_DATA_WIDTH(64), .AXI_ID_WIDTH(1),
        .TIMEOUT_CYCLES(256)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .abort(abort),
        .context_len(context_len), .v_base_addr(v_base_addr),
        .score_wr_en(score_wr_en), .score_wr_row(score_wr_row),
        .score_wr_addr(score_wr_addr), .score_wr_data(score_wr_data),
        .score_wr_ready(score_wr_ready), .scale_wr_en(scale_wr_en),
        .scale_wr_addr(scale_wr_addr), .scale_wr_data(scale_wr_data),
        .scale_wr_ready(scale_wr_ready), .result_valid(result_valid),
        .result_ready(result_ready), .result_head(result_head),
        .result_dimension(result_dimension),
        .result_numerator(result_numerator), .result_code(result_code),
        .result_saturated(result_saturated), .result_last(result_last),
        .busy(busy), .done(done), .aborted(aborted),
        .error_valid(error_valid), .error_code(error_code),
        .perf_cycles(perf_cycles), .read_beats(read_beats),
        .ar_stall_cycles(ar_stall_cycles),
        .r_stall_cycles(r_stall_cycles),
        .saturation_count(saturation_count), .denominators(denominators),
        .reciprocal_codes(reciprocal_codes),
        .reciprocal_exponents(reciprocal_exponents),
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

    task set_token_code;
        input integer token;
        input [4:0] code;
        integer dimension;
        integer bit_index;
        integer absolute_bit;
        integer byte_index;
        integer bit_in_byte;
        begin
            for (dimension = 0; dimension < 128; dimension = dimension + 1)
                for (bit_index = 0; bit_index < 5; bit_index = bit_index + 1) begin
                    absolute_bit = dimension*5 + bit_index;
                    byte_index = token*80 + absolute_bit/8;
                    bit_in_byte = absolute_bit % 8;
                    if (code[bit_index])
                        vmem[byte_index] = vmem[byte_index] |
                                           (8'b1 << bit_in_byte);
                end
        end
    endtask

    task write_score;
        input [1:0] row;
        input [11:0] address;
        input signed [15:0] value;
        begin
            @(negedge clk);
            score_wr_row = row;
            score_wr_addr = address;
            score_wr_data = value;
            score_wr_en = 1'b1;
            @(negedge clk);
            score_wr_en = 1'b0;
        end
    endtask

    task write_scale;
        input [6:0] address;
        input [SCALE_WIDTH-1:0] value;
        begin
            @(negedge clk);
            scale_wr_addr = address;
            scale_wr_data = value;
            scale_wr_en = 1'b1;
            @(negedge clk);
            scale_wr_en = 1'b0;
        end
    endtask

    always @* begin
        m_axi_rdata = 64'd0;
        if (response_active)
            for (index = 0; index < 8; index = index + 1)
                m_axi_rdata[index*8 +: 8] =
                    vmem[(response_addr - V_BASE) + index];
        m_axi_rvalid = response_active;
        m_axi_rlast = response_active && response_beats_left == 1;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            response_active <= 1'b0;
            response_addr <= 32'd0;
            response_beats_left <= 9'd0;
            ar_count <= 0;
            beat_count <= 0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                if (response_active) begin
                    $display("FAIL overlapping AXI read command");
                    errors = errors + 1;
                end
                if (m_axi_arsize != 3 || m_axi_arburst != 2'b01 ||
                    m_axi_araddr < V_BASE || m_axi_araddr >= V_BASE+160) begin
                    $display("FAIL AXI command addr=%08x len=%0d size=%0d",
                             m_axi_araddr, m_axi_arlen, m_axi_arsize);
                    errors = errors + 1;
                end
                response_active <= 1'b1;
                response_addr <= m_axi_araddr;
                response_beats_left <= m_axi_arlen + 1'b1;
                ar_count <= ar_count + 1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                beat_count <= beat_count + 1;
                if (response_beats_left == 1) begin
                    response_active <= 1'b0;
                    response_beats_left <= 9'd0;
                end else begin
                    response_addr <= response_addr + 8;
                    response_beats_left <= response_beats_left - 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (result_valid && result_ready) begin
            if (result_head !== (result_count / 128) ||
                result_dimension !== (result_count % 128)) begin
                $display("FAIL result order count=%0d head=%0d dim=%0d",
                         result_count, result_head, result_dimension);
                errors = errors + 1;
            end
            if (result_numerator !== EXPECTED_NUMERATOR) begin
                $display("FAIL numerator count=%0d got=%0d",
                         result_count, result_numerator);
                errors = errors + 1;
            end
            if (result_code !== 18'sd512 || result_saturated) begin
                $display("FAIL normalized count=%0d code=%0d sat=%0d",
                         result_count, result_code, result_saturated);
                errors = errors + 1;
            end
            if (result_last !== (result_count == 511)) begin
                $display("FAIL result_last count=%0d", result_count);
                errors = errors + 1;
            end
            result_count = result_count + 1;
        end
        if (abort && result_valid && result_ready) begin
            $display("FAIL abort leaked result handshake");
            errors = errors + 1;
        end
    end

    integer row;
    integer token;
    integer watchdog;
    initial begin
        for (index = 0; index < 160; index = index + 1)
            vmem[index] = 8'd0;
        set_token_code(0, 5'd1);
        set_token_code(1, 5'd3);

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        for (row = 0; row < 4; row = row + 1)
            for (token = 0; token < 2; token = token + 1)
                write_score(row[1:0], token[11:0], 16'sd0);
        write_scale(0, UNIT_SCALE);
        write_scale(1, UNIT_SCALE);

        @(negedge clk);
        context_len = 13'd2;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        watchdog = 0;
        while (!done && watchdog < 30000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
            // Deterministic result backpressure exercises the scalar hold path.
            result_ready = (watchdog % 7) != 3;
            if (error_valid) begin
                $display("FAIL pipeline error code=%02x", error_code);
                errors = errors + 1;
            end
        end
        result_ready = 1'b1;
        if (!done) begin
            $display("FAIL pipeline timeout state=%0d results=%0d", dut.state,
                     result_count);
            errors = errors + 1;
        end
        if (result_count != 512 || ar_count != 2 || beat_count != 20 ||
            read_beats != 20 || saturation_count != 0) begin
            $display("FAIL summary results=%0d ar=%0d beats=%0d/%0d sat=%0d",
                     result_count, ar_count, beat_count, read_beats,
                     saturation_count);
            errors = errors + 1;
        end
        for (row = 0; row < 4; row = row + 1) begin
            if (denominators[row*28 +: 28] != 28'd65536 ||
                reciprocal_codes[row*13 +: 13] != 13'd4096 ||
                reciprocal_exponents[row*5 +: 5] != 5'd16) begin
                $display("FAIL softmax summary row=%0d d=%0d r=%0d e=%0d",
                         row, denominators[row*28 +: 28],
                         reciprocal_codes[row*13 +: 13],
                         reciprocal_exponents[row*5 +: 5]);
                errors = errors + 1;
            end
        end

        // Abort while the non-cancellable reciprocal is active.  The top-level
        // drain must not report idle until that orphaned iteration is quiet,
        // and the very next request must complete without a reset.
        result_count = 0;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        watchdog = 0;
        while (!dut.u_softmax.u_softmax.u_reciprocal.busy &&
               watchdog < 2000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
        end
        if (!dut.u_softmax.u_softmax.u_reciprocal.busy) begin
            $display("FAIL reciprocal abort window timeout");
            errors = errors + 1;
        end
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        watchdog = 0;
        while (busy && watchdog < 2000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
            if (error_valid) begin
                $display("FAIL reciprocal abort error code=%02x", error_code);
                errors = errors + 1;
            end
        end
        if (busy || result_valid || result_count != 0 ||
            dut.u_softmax.u_softmax.u_reciprocal.busy || !aborted) begin
            $display("FAIL reciprocal abort drain busy=%0d valid=%0d results=%0d recip_busy=%0d aborted=%0d",
                     busy, result_valid, result_count,
                     dut.u_softmax.u_softmax.u_reciprocal.busy, aborted);
            errors = errors + 1;
        end

        // Immediate no-reset restart after reciprocal drain.
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        watchdog = 0;
        while (!done && watchdog < 30000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
            result_ready = (watchdog % 5) != 2;
            if (error_valid) begin
                $display("FAIL reciprocal restart error code=%02x", error_code);
                errors = errors + 1;
            end
        end
        result_ready = 1'b1;
        if (!done || result_count != 512 || saturation_count != 0) begin
            $display("FAIL reciprocal restart done=%0d results=%0d sat=%0d",
                     done, result_count, saturation_count);
            errors = errors + 1;
        end

        // Abort in the one-cycle window after a metadata request was accepted
        // but before its registered response handshakes.  The response must be
        // retained through drain, consumed, and followed by a no-reset restart.
        result_count = 0;
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        watchdog = 0;
        while (!(dut.state == 4'd4 && dut.meta_rsp_valid) &&
               watchdog < 30000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
            if (error_valid) begin
                $display("FAIL metadata-window setup error code=%02x",
                         error_code);
                errors = errors + 1;
            end
        end
        if (!dut.meta_rsp_valid) begin
            $display("FAIL metadata abort window timeout state=%0d", dut.state);
            errors = errors + 1;
        end
        abort = 1'b1;
        #1;
        if (dut.meta_rsp_ready) begin
            $display("FAIL metadata response was not blocked by abort");
            errors = errors + 1;
        end
        @(negedge clk);
        abort = 1'b0;
        watchdog = 0;
        while (busy && watchdog < 3000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
            if (error_valid) begin
                $display("FAIL metadata abort drain error code=%02x",
                         error_code);
                errors = errors + 1;
            end
        end
        if (busy || result_valid || result_count != 0 ||
            dut.meta_rsp_valid || !aborted) begin
            $display("FAIL metadata abort drain busy=%0d valid=%0d results=%0d meta_valid=%0d aborted=%0d",
                     busy, result_valid, result_count, dut.meta_rsp_valid,
                     aborted);
            errors = errors + 1;
        end

        // Immediate no-reset restart after metadata/AXI drain.
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        watchdog = 0;
        while (!done && watchdog < 30000) begin
            @(negedge clk);
            watchdog = watchdog + 1;
            result_ready = (watchdog % 11) != 6;
            if (error_valid) begin
                $display("FAIL metadata restart error code=%02x", error_code);
                errors = errors + 1;
            end
        end
        result_ready = 1'b1;
        if (!done || result_count != 512 || saturation_count != 0) begin
            $display("FAIL metadata restart done=%0d results=%0d sat=%0d",
                     done, result_count, saturation_count);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("TB PASS: KV v0.3 score-softmax-rawV-AV-normalized pipeline scale_width=%0d",
                     SCALE_WIDTH);
        else begin
            $display("TB FAIL: KV v0.3 pipeline errors=%0d", errors);
            $fatal(1);
        end
        $finish;
    end

    wire unused_axi = ^m_axi_arid ^ m_axi_arlock ^ ^m_axi_arcache ^
                       ^m_axi_arprot ^ ^m_axi_arqos ^ perf_cycles ^ aborted;
endmodule

`default_nettype wire
