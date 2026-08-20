// tb_kv_v03_raw_k4_qk_engine.v -- raw K4/Q8.8 engine regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_WIDTH_VAL
`define SCALE_WIDTH_VAL 12
`endif

module tb_kv_v03_raw_k4_qk_engine;
    localparam integer SCALE_WIDTH = `SCALE_WIDTH_VAL;
    localparam integer TIMEOUT_CYCLES = 12;
    localparam [31:0] TEST_BASE = 32'h0000_0fe0;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg abort = 1'b0;
    reg [12:0] context_len = 13'd0;
    reg [31:0] k_base_addr = TEST_BASE;
    reg [4095:0] q_vectors = 4096'd0;

    wire meta_req_valid;
    reg meta_req_ready;
    wire [6:0] meta_req_token;
    reg meta_rsp_valid = 1'b0;
    wire meta_rsp_ready;
    reg [SCALE_WIDTH-1:0] meta_scale = {SCALE_WIDTH{1'b0}};

    wire busy, draining, done, aborted, error_valid;
    wire [7:0] error_code;
    wire [15:0] error_tag;
    wire [31:0] perf_cycles, read_beats, burst_count;
    wire [31:0] ar_stall_cycles, r_wait_cycles;
    wire [31:0] metadata_wait_cycles, dot_active_cycles;
    wire [31:0] score_stall_cycles, score_count;
    wire [6:0] progress_token;
    wire [1:0] progress_head;
    wire [2:0] progress_slice;
    wire [3:0] progress_state;
    wire score_valid;
    reg score_ready = 1'b1;
    wire [1:0] score_row;
    wire [11:0] score_index;
    wire signed [15:0] score;
    wire score_saturated;

    wire m_axi_arid;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_arqos;
    wire m_axi_arvalid;
    reg m_axi_arready;
    reg m_axi_rid = 1'b0;
    reg [63:0] m_axi_rdata = 64'd0;
    reg [1:0] m_axi_rresp = 2'b00;
    reg m_axi_rlast = 1'b0;
    reg m_axi_rvalid = 1'b0;
    wire m_axi_rready;

    kv_v03_raw_k4_qk_engine #(
        .MAX_CONTEXT(128), .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .MULT_STYLE(2), .SCALE_WIDTH(SCALE_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .abort(abort),
        .context_len(context_len), .k_base_addr(k_base_addr),
        .q_vectors(q_vectors),
        .meta_req_valid(meta_req_valid), .meta_req_ready(meta_req_ready),
        .meta_req_token(meta_req_token), .meta_rsp_valid(meta_rsp_valid),
        .meta_rsp_ready(meta_rsp_ready), .meta_scale(meta_scale),
        .busy(busy), .draining(draining), .done(done), .aborted(aborted),
        .error_valid(error_valid), .error_code(error_code),
        .error_tag(error_tag), .perf_cycles(perf_cycles),
        .read_beats(read_beats), .burst_count(burst_count),
        .ar_stall_cycles(ar_stall_cycles), .r_wait_cycles(r_wait_cycles),
        .metadata_wait_cycles(metadata_wait_cycles),
        .dot_active_cycles(dot_active_cycles),
        .score_stall_cycles(score_stall_cycles), .score_count(score_count),
        .progress_token(progress_token), .progress_head(progress_head),
        .progress_slice(progress_slice), .progress_state(progress_state),
        .score_valid(score_valid), .score_ready(score_ready),
        .score_row(score_row), .score_index(score_index), .score(score),
        .score_saturated(score_saturated),
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

    integer errors = 0;
    integer observed_scores = 0;
    integer expected_scores = 0;
    reg signed [15:0] expected_value [0:7];
    reg [1:0] expected_row [0:7];
    reg [11:0] expected_index [0:7];
    reg check_scores = 1'b0;
    reg seen_error = 1'b0;
    reg [7:0] seen_error_code = 8'd0;
    reg [15:0] seen_error_tag = 16'd0;
    reg seen_done = 1'b0;
    reg seen_aborted = 1'b0;

    always @(posedge clk) begin
        if (error_valid) begin
            seen_error <= 1'b1;
            seen_error_code <= error_code;
            seen_error_tag <= error_tag;
        end
        if (done)
            seen_done <= 1'b1;
        if (aborted)
            seen_aborted <= 1'b1;
        if (score_valid && score_ready) begin
            if (!check_scores) begin
                $display("ERROR unexpected score row=%0d index=%0d value=%0d",
                         score_row, score_index, score);
                errors <= errors + 1;
            end else if (observed_scores >= expected_scores) begin
                $display("ERROR excess score row=%0d index=%0d",
                         score_row, score_index);
                errors <= errors + 1;
            end else begin
                if (score_row !== expected_row[observed_scores] ||
                    score_index !== expected_index[observed_scores] ||
                    score !== expected_value[observed_scores] ||
                    score_saturated !== 1'b0) begin
                    $display("ERROR score[%0d] got r%0d i%0d v%0d sat%0d expected r%0d i%0d v%0d",
                        observed_scores, score_row, score_index, score,
                        score_saturated, expected_row[observed_scores],
                        expected_index[observed_scores],
                        expected_value[observed_scores]);
                    errors <= errors + 1;
                end
            end
            observed_scores <= observed_scores + 1;
        end
    end

    // ------------------------------------------------------------------
    // Metadata responder.  Requests and responses may stall independently.
    // ------------------------------------------------------------------
    reg allow_meta_request = 1'b1;
    reg auto_meta_response = 1'b1;
    integer meta_request_delay = 0;
    integer meta_response_delay = 0;
    integer meta_request_wait = 0;
    integer meta_response_wait = 0;
    reg meta_pending = 1'b0;
    reg [6:0] pending_meta_token = 7'd0;

    always @* begin
        meta_req_ready = allow_meta_request && !meta_pending &&
                         (meta_request_wait == 0);
    end

    function [SCALE_WIDTH-1:0] scale_for_token;
        input [6:0] token;
        begin
            if (SCALE_WIDTH == 16)
                scale_for_token = token == 0 ? 16'd513 : 16'd771;
            else
                scale_for_token = token == 0 ? 12'd64 : 12'd96;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            meta_rsp_valid <= 1'b0;
            meta_scale <= {SCALE_WIDTH{1'b0}};
            meta_pending <= 1'b0;
            pending_meta_token <= 7'd0;
            meta_request_wait <= 0;
            meta_response_wait <= 0;
        end else begin
            if (!meta_pending && meta_request_wait > 0)
                meta_request_wait <= meta_request_wait - 1;
            if (meta_req_valid && meta_req_ready) begin
                meta_pending <= 1'b1;
                pending_meta_token <= meta_req_token;
                meta_response_wait <= meta_response_delay;
            end
            if (meta_pending && auto_meta_response && !meta_rsp_valid) begin
                if (meta_response_wait > 0)
                    meta_response_wait <= meta_response_wait - 1;
                else begin
                    meta_rsp_valid <= 1'b1;
                    meta_scale <= scale_for_token(pending_meta_token);
                end
            end
            if (meta_rsp_valid && meta_rsp_ready) begin
                meta_rsp_valid <= 1'b0;
                meta_pending <= 1'b0;
                meta_request_wait <= meta_request_delay;
            end
        end
    end

    // ------------------------------------------------------------------
    // One-outstanding AXI memory model with selectable protocol faults.
    // ------------------------------------------------------------------
    localparam integer AXI_OK            = 0;
    localparam integer AXI_RRESP         = 1;
    localparam integer AXI_EARLY_RLAST   = 2;
    localparam integer AXI_MISSING_RLAST = 3;
    localparam integer AXI_R_TIMEOUT     = 4;
    integer axi_fault_mode = AXI_OK;
    reg axi_fault_consumed = 1'b0;
    reg allow_ar = 1'b1;
    integer ar_ready_delay = 0;
    integer ar_wait = 0;
    integer r_gap = 0;
    integer r_wait = 0;
    integer timeout_hold = 0;
    reg axi_active = 1'b0;
    reg [31:0] active_addr = 32'd0;
    integer active_beats = 0;
    integer active_beat = 0;
    integer emitted_beats = 0;
    reg reserved_k_mode = 1'b0;

    always @* begin
        m_axi_arready = allow_ar && !axi_active && (ar_wait == 0);
    end

    function [63:0] k_data_for_address;
        input [31:0] address;
        integer token;
        reg [63:0] word;
        begin
            token = (address - TEST_BASE) / 64;
            word = token == 0 ? 64'h1111_1111_1111_1111 :
                                64'hffff_ffff_ffff_ffff;
            if (reserved_k_mode && address == TEST_BASE)
                word[3:0] = 4'h8;
            k_data_for_address = word;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            m_axi_rvalid <= 1'b0;
            m_axi_rdata <= 64'd0;
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            axi_active <= 1'b0;
            active_addr <= 32'd0;
            active_beats <= 0;
            active_beat <= 0;
            emitted_beats <= 0;
            ar_wait <= 0;
            r_wait <= 0;
            timeout_hold <= 0;
            axi_fault_consumed <= 1'b0;
        end else begin
            if (!axi_active && ar_wait > 0)
                ar_wait <= ar_wait - 1;
            if (m_axi_arvalid && m_axi_arready) begin
                axi_active <= 1'b1;
                active_addr <= m_axi_araddr;
                active_beats <= m_axi_arlen + 1;
                active_beat <= 0;
                emitted_beats <= 0;
                r_wait <= r_gap;
                if (axi_fault_mode == AXI_R_TIMEOUT && !axi_fault_consumed)
                    timeout_hold <= TIMEOUT_CYCLES + 3;
                else
                    timeout_hold <= 0;
            end

            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                if (m_axi_rlast) begin
                    axi_active <= 1'b0;
                    ar_wait <= ar_ready_delay;
                    if (axi_fault_mode != AXI_OK)
                        axi_fault_consumed <= 1'b1;
                end else begin
                    active_beat <= active_beat + 1;
                    r_wait <= r_gap;
                end
            end

            if (axi_active && !m_axi_rvalid) begin
                if (timeout_hold > 0)
                    timeout_hold <= timeout_hold - 1;
                else if (r_wait > 0)
                    r_wait <= r_wait - 1;
                else begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rid <= 1'b0;
                    m_axi_rdata <= k_data_for_address(
                        active_addr + active_beat*8);
                    m_axi_rresp <= (axi_fault_mode == AXI_RRESP &&
                                    !axi_fault_consumed && active_beat == 1) ?
                                   2'b10 : 2'b00;
                    if (axi_fault_mode == AXI_EARLY_RLAST &&
                        !axi_fault_consumed)
                        m_axi_rlast <= (active_beat == 1);
                    else if (axi_fault_mode == AXI_MISSING_RLAST &&
                             !axi_fault_consumed)
                        m_axi_rlast <= (active_beat == active_beats);
                    else
                        m_axi_rlast <= (active_beat == active_beats-1);
                    emitted_beats <= emitted_beats + 1;
                end
            end
        end
    end

    task clear_observers;
        begin
            @(negedge clk);
            seen_error = 1'b0;
            seen_error_code = 8'd0;
            seen_error_tag = 16'd0;
            seen_done = 1'b0;
            seen_aborted = 1'b0;
            observed_scores = 0;
            expected_scores = 0;
            check_scores = 1'b0;
        end
    endtask

    task configure_clean;
        begin
            @(negedge clk);
            allow_ar = 1'b1;
            ar_ready_delay = 0;
            ar_wait = 0;
            r_gap = 0;
            axi_fault_mode = AXI_OK;
            axi_fault_consumed = 1'b0;
            reserved_k_mode = 1'b0;
            allow_meta_request = 1'b1;
            auto_meta_response = 1'b1;
            meta_request_delay = 0;
            meta_response_delay = 0;
            meta_request_wait = 0;
            score_ready = 1'b1;
        end
    endtask

    task pulse_start;
        input [12:0] count;
        begin
            @(negedge clk);
            context_len = count;
            k_base_addr = TEST_BASE;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task pulse_abort;
        begin
            @(negedge clk);
            abort = 1'b1;
            @(negedge clk);
            abort = 1'b0;
        end
    endtask

    task wait_idle;
        integer watchdog;
        begin
            watchdog = 0;
            while (busy && watchdog < 2000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
            end
            if (busy) begin
                $display("ERROR timeout waiting idle state=%0d token=%0d",
                         progress_state, progress_token);
                errors = errors + 1;
            end
            repeat (2) @(posedge clk);
        end
    endtask

    task expect_no_score_cycles;
        input integer cycles;
        integer i;
        begin
            for (i = 0; i < cycles; i = i + 1) begin
                @(posedge clk);
                if (score_valid) begin
                    $display("ERROR stale score after cancellation");
                    errors = errors + 1;
                end
            end
        end
    endtask

    task prepare_expected;
        input integer tokens;
        integer t;
        integer h;
        integer raw_sum;
        integer signed_product;
        integer magnitude;
        integer quotient;
        integer remainder;
        integer rounded;
        begin
            expected_scores = tokens * 4;
            for (t = 0; t < tokens; t = t + 1) begin
                for (h = 0; h < 4; h = h + 1) begin
                    case (h)
                        0: raw_sum = 4;
                        1: raw_sum = 12;
                        2: raw_sum = -4;
                        default: raw_sum = 20;
                    endcase
                    if (t == 1)
                        raw_sum = -raw_sum;
                    signed_product = raw_sum * scale_for_token(t);
                    if (SCALE_WIDTH == 16) begin
                        magnitude = signed_product < 0 ?
                                    -signed_product : signed_product;
                        quotient = magnitude / 8;
                        remainder = magnitude % 8;
                        rounded = quotient;
                        if (remainder > 4 ||
                            (remainder == 4 && (quotient % 2) == 1))
                            rounded = rounded + 1;
                        if (signed_product < 0)
                            rounded = -rounded;
                    end else begin
                        rounded = signed_product;
                    end
                    expected_row[t*4+h] = h;
                    expected_index[t*4+h] = t;
                    expected_value[t*4+h] = rounded;
                end
            end
            observed_scores = 0;
            check_scores = 1'b1;
        end
    endtask

    task check_error;
        input [7:0] wanted;
        begin
            if (!seen_error || seen_error_code !== wanted) begin
                $display("ERROR expected error %02x got seen=%0d code=%02x tag=%04x",
                         wanted, seen_error, seen_error_code, seen_error_tag);
                errors = errors + 1;
            end
        end
    endtask

    integer d;
    integer watchdog;
    initial begin
        // Query row sums are +4, +12, -4, and +20.
        for (d = 0; d < 128; d = d + 1) begin
            q_vectors[(0*1024 + d*8) +: 8] = d < 4 ? 8'sd1 : 8'sd0;
            q_vectors[(1*1024 + d*8) +: 8] = d < 12 ? 8'sd1 : 8'sd0;
            q_vectors[(2*1024 + d*8) +: 8] = d < 4 ? -8'sd1 : 8'sd0;
            q_vectors[(3*1024 + d*8) +: 8] = d < 20 ? 8'sd1 : 8'sd0;
        end

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // Two-token exact run: first vector straddles 4 KiB, and both AXI
        // channels plus metadata and the held score output see stalls.
        clear_observers();
        configure_clean();
        @(negedge clk);
        ar_ready_delay = 2;
        ar_wait = 2;
        r_gap = 1;
        meta_request_delay = 2;
        meta_request_wait = 2;
        meta_response_delay = 3;
        score_ready = 1'b0;
        prepare_expected(2);
        pulse_start(2);
        wait (score_valid);
        repeat (4) @(posedge clk);
        @(negedge clk);
        score_ready = 1'b1;
        wait_idle();
        if (!seen_done || seen_error || seen_aborted || observed_scores != 8) begin
            $display("ERROR normal completion done=%0d err=%0d aborted=%0d scores=%0d",
                     seen_done, seen_error, seen_aborted, observed_scores);
            errors = errors + 1;
        end
        if (burst_count != 3 || read_beats != 16 ||
            ar_stall_cycles == 0 || metadata_wait_cycles == 0 ||
            score_stall_cycles == 0 || score_count != 8) begin
            $display("ERROR counters bursts=%0d beats=%0d arstall=%0d metastall=%0d scorestall=%0d scores=%0d",
                burst_count, read_beats, ar_stall_cycles,
                metadata_wait_cycles, score_stall_cycles, score_count);
            errors = errors + 1;
        end

        // Reserved signed-K4 -8 must fail before score commit.
        clear_observers(); configure_clean();
        @(negedge clk); reserved_k_mode = 1'b1;
        pulse_start(1); wait_idle(); check_error(8'h21);
        if (observed_scores != 0) errors = errors + 1;
        expect_no_score_cycles(3);

        // RRESP and early/missing RLAST preserve the reader's typed errors.
        clear_observers(); configure_clean();
        @(negedge clk); axi_fault_mode = AXI_RRESP;
        pulse_start(1); wait_idle(); check_error(8'h13);
        expect_no_score_cycles(2);

        clear_observers(); configure_clean();
        @(negedge clk); axi_fault_mode = AXI_EARLY_RLAST;
        pulse_start(1); wait_idle(); check_error(8'h14);

        clear_observers(); configure_clean();
        @(negedge clk); axi_fault_mode = AXI_MISSING_RLAST;
        pulse_start(1); wait_idle(); check_error(8'h14);

        // Reader R timeout is reported, then its accepted burst is drained.
        clear_observers(); configure_clean();
        @(negedge clk); axi_fault_mode = AXI_R_TIMEOUT;
        pulse_start(1); wait_idle(); check_error(8'h11);

        // A second start is a typed fail-closed cancellation of the active
        // job, including its already-accepted transport obligations.
        clear_observers(); configure_clean();
        @(negedge clk); r_gap = 3; meta_response_delay = 3;
        pulse_start(1); wait (axi_active);
        pulse_start(1); wait_idle(); check_error(8'h80);
        expect_no_score_cycles(2);

        // Accepted metadata request times out, but its late response is still
        // consumed before the error-drain state releases busy.
        clear_observers(); configure_clean();
        @(negedge clk); auto_meta_response = 1'b0;
        pulse_start(1);
        watchdog = 0;
        while (!seen_error && watchdog < 200) begin
            @(posedge clk); watchdog = watchdog + 1;
        end
        check_error(8'h20);
        if (!busy || !draining || !meta_pending) begin
            $display("ERROR metadata timeout did not retain drain ownership");
            errors = errors + 1;
        end
        @(negedge clk); auto_meta_response = 1'b1;
        wait_idle();

        // Abort while ARVALID is held: VALID remains owned until READY, then
        // the accepted burst drains and the engine acknowledges cancellation.
        clear_observers(); configure_clean();
        @(negedge clk); allow_ar = 1'b0;
        pulse_start(1);
        wait (m_axi_arvalid);
        pulse_abort();
        @(negedge clk); allow_ar = 1'b1;
        wait_idle();
        if (!seen_aborted || seen_error) begin
            $display("ERROR AR abort aborted=%0d error=%0d", seen_aborted, seen_error);
            errors = errors + 1;
        end
        expect_no_score_cycles(2);

        // Abort during R, during an accepted metadata wait, in dot drain, and
        // with a score held by downstream backpressure.
        clear_observers(); configure_clean();
        @(negedge clk); r_gap = 2;
        pulse_start(1);
        wait (axi_active && m_axi_rvalid && !m_axi_rlast);
        pulse_abort(); wait_idle();
        if (!seen_aborted || seen_error) errors = errors + 1;

        clear_observers(); configure_clean();
        @(negedge clk); auto_meta_response = 1'b0;
        pulse_start(1); wait (meta_pending);
        pulse_abort();
        repeat (2) @(posedge clk);
        if (!busy || !draining) errors = errors + 1;
        @(negedge clk); auto_meta_response = 1'b1;
        wait_idle();
        if (!seen_aborted || seen_error) errors = errors + 1;

        clear_observers(); configure_clean();
        pulse_start(1); wait (progress_state == 4'd3);
        pulse_abort(); wait_idle();
        if (!seen_aborted || seen_error) errors = errors + 1;
        expect_no_score_cycles(2);

        clear_observers(); configure_clean();
        @(negedge clk); score_ready = 1'b0;
        pulse_start(1); wait (score_valid);
        pulse_abort();
        @(negedge clk); score_ready = 1'b1;
        wait_idle();
        if (!seen_aborted || seen_error) errors = errors + 1;
        expect_no_score_cycles(3);

        // Immediate no-reset restart and long-to-short ownership proof.
        clear_observers(); configure_clean(); prepare_expected(2);
        pulse_start(2); wait_idle();
        if (!seen_done || observed_scores != 8) errors = errors + 1;
        clear_observers(); configure_clean(); prepare_expected(1);
        pulse_start(1); wait_idle();
        if (!seen_done || observed_scores != 4 || score_count != 4)
            errors = errors + 1;
        expect_no_score_cycles(4);

        if (errors == 0)
            $display("KV_V03_RAW_K4_QK_ENGINE_SCALE%0d_PASS", SCALE_WIDTH);
        else
            $fatal(1, "KV v0.3 raw K4 QK engine errors=%0d", errors);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "TB timeout");
    end
endmodule

`default_nettype wire
