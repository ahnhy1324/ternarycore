`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_BITS_VAL
`define SCALE_BITS_VAL 12
`endif

module tb_kv_v03_canned_page_arithmetic;
    localparam integer SCALE_BITS = `SCALE_BITS_VAL;
    localparam integer LONG_CONTEXT = 128;
    localparam integer SHORT_CONTEXT = 2;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg start_valid;
    wire start_ready;
    reg [12:0] context_len;
    reg abort;
    reg clear_fault;
    reg clear_counters;
    reg q_wr_en;
    reg [1:0] q_wr_row;
    reg [6:0] q_wr_addr;
    reg signed [7:0] q_wr_data;
    wire queries_ready;

    reg k_page_active;
    reg [63:0] k_task_tag;
    reg [15:0] k_epoch;
    reg [4:0] k_page_index;
    reg k_stream_is_v, k_raw_mode;
    reg [14:0] k_expected_symbols;
    reg [7:0] k_token_count;
    reg [8:0] k_scale_slice_bytes;
    wire k_p16_rd_en;
    wire [9:0] k_p16_rd_addr;
    reg k_p16_rd_valid;
    reg [79:0] k_p16_rd_codes;
    wire k_scale_rd_en;
    wire [6:0] k_scale_rd_addr;
    reg k_scale_rd_valid;
    reg [SCALE_BITS-1:0] k_scale_rd_data;
    wire k_page_release;

    reg v_page_active;
    reg [63:0] v_task_tag;
    reg [15:0] v_epoch;
    reg [4:0] v_page_index;
    reg v_stream_is_v, v_raw_mode;
    reg [14:0] v_expected_symbols;
    reg [7:0] v_token_count;
    reg [8:0] v_scale_slice_bytes;
    wire v_p16_rd_en;
    wire [9:0] v_p16_rd_addr;
    reg v_p16_rd_valid;
    reg [79:0] v_p16_rd_codes;
    wire v_scale_rd_en;
    wire [6:0] v_scale_rd_addr;
    reg v_scale_rd_valid;
    reg [SCALE_BITS-1:0] v_scale_rd_data;
    wire v_page_release;

    wire score_valid;
    wire score_ready;
    wire [1:0] score_row;
    wire [11:0] score_index;
    wire signed [15:0] score_data;
    wire score_saturated;
    wire result_valid;
    wire result_ready;
    wire [1:0] result_head;
    wire [6:0] result_dimension;
    wire signed [47:0] result_numerator;
    wire signed [17:0] result_normalized;
    wire result_saturated, result_last;
    wire [63:0] result_k_task_tag, result_v_task_tag;
    wire [15:0] result_epoch;
    wire [4:0] result_page_index;
    wire result_k_raw_mode, result_v_raw_mode;
    wire [111:0] denominators;
    wire [51:0] reciprocal_codes;
    wire [19:0] reciprocal_exponents;

    wire busy, draining, done, aborted, sticky_error, clear_ready, row_abort;
    wire [7:0] sticky_error_code, sticky_error_subcode;
    wire [63:0] sticky_k_task_tag, sticky_v_task_tag;
    wire [15:0] sticky_epoch;
    wire [4:0] sticky_page_index;
    wire [4:0] progress_state;
    wire [6:0] progress_token;
    wire [1:0] progress_head;
    wire [2:0] progress_group;
    wire [31:0] perf_cycles;
    wire [31:0] k_p16_read_requests, k_scale_read_requests;
    wire [31:0] v_p16_read_requests, v_scale_read_requests;
    wire [31:0] k_read_starvation_cycles, v_read_starvation_cycles;
    wire [31:0] k_starvation_high_water, v_starvation_high_water;
    wire [1:0] read_outstanding_high_water;
    wire [31:0] arithmetic_active_cycles, score_stall_cycles;
    wire [31:0] result_stall_cycles, score_count, result_count;

    reg force_score_hold, force_result_hold, enable_backpressure;
    integer cycle_count;
    assign score_ready = !force_score_hold &&
                         (!enable_backpressure || (cycle_count % 7 != 2));
    assign result_ready = !force_result_hold &&
                          (!enable_backpressure || (cycle_count % 5 != 1));

    kv_v03_canned_page_arithmetic #(
        .SCALE_BITS(SCALE_BITS), .MAX_CONTEXT(128), .MULT_STYLE(2)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start_valid(start_valid),
        .start_ready(start_ready), .context_len(context_len),
        .abort(abort), .clear_fault(clear_fault),
        .clear_ready(clear_ready), .clear_counters(clear_counters),
        .q_wr_en(q_wr_en), .q_wr_row(q_wr_row), .q_wr_addr(q_wr_addr),
        .q_wr_data(q_wr_data), .queries_ready(queries_ready),
        .k_page_active(k_page_active), .k_task_tag(k_task_tag),
        .k_epoch(k_epoch), .k_page_index(k_page_index),
        .k_stream_is_v(k_stream_is_v), .k_raw_mode(k_raw_mode),
        .k_expected_symbols(k_expected_symbols),
        .k_token_count(k_token_count),
        .k_scale_slice_bytes(k_scale_slice_bytes),
        .k_p16_rd_en(k_p16_rd_en), .k_p16_rd_addr(k_p16_rd_addr),
        .k_p16_rd_valid(k_p16_rd_valid),
        .k_p16_rd_codes(k_p16_rd_codes),
        .k_scale_rd_en(k_scale_rd_en),
        .k_scale_rd_addr(k_scale_rd_addr),
        .k_scale_rd_valid(k_scale_rd_valid),
        .k_scale_rd_data(k_scale_rd_data),
        .k_page_release(k_page_release),
        .v_page_active(v_page_active), .v_task_tag(v_task_tag),
        .v_epoch(v_epoch), .v_page_index(v_page_index),
        .v_stream_is_v(v_stream_is_v), .v_raw_mode(v_raw_mode),
        .v_expected_symbols(v_expected_symbols),
        .v_token_count(v_token_count),
        .v_scale_slice_bytes(v_scale_slice_bytes),
        .v_p16_rd_en(v_p16_rd_en), .v_p16_rd_addr(v_p16_rd_addr),
        .v_p16_rd_valid(v_p16_rd_valid),
        .v_p16_rd_codes(v_p16_rd_codes),
        .v_scale_rd_en(v_scale_rd_en),
        .v_scale_rd_addr(v_scale_rd_addr),
        .v_scale_rd_valid(v_scale_rd_valid),
        .v_scale_rd_data(v_scale_rd_data),
        .v_page_release(v_page_release),
        .score_valid(score_valid), .score_ready(score_ready),
        .score_row(score_row), .score_index(score_index),
        .score_data(score_data), .score_saturated(score_saturated),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_head(result_head), .result_dimension(result_dimension),
        .result_numerator(result_numerator),
        .result_normalized(result_normalized),
        .result_saturated(result_saturated), .result_last(result_last),
        .result_k_task_tag(result_k_task_tag),
        .result_v_task_tag(result_v_task_tag),
        .result_epoch(result_epoch), .result_page_index(result_page_index),
        .result_k_raw_mode(result_k_raw_mode),
        .result_v_raw_mode(result_v_raw_mode),
        .denominators(denominators), .reciprocal_codes(reciprocal_codes),
        .reciprocal_exponents(reciprocal_exponents),
        .busy(busy), .draining(draining), .done(done), .aborted(aborted),
        .sticky_error(sticky_error),
        .sticky_error_code(sticky_error_code),
        .sticky_error_subcode(sticky_error_subcode),
        .sticky_k_task_tag(sticky_k_task_tag),
        .sticky_v_task_tag(sticky_v_task_tag),
        .sticky_epoch(sticky_epoch),
        .sticky_page_index(sticky_page_index), .row_abort(row_abort),
        .progress_state(progress_state), .progress_token(progress_token),
        .progress_head(progress_head), .progress_group(progress_group),
        .perf_cycles(perf_cycles),
        .k_p16_read_requests(k_p16_read_requests),
        .k_scale_read_requests(k_scale_read_requests),
        .v_p16_read_requests(v_p16_read_requests),
        .v_scale_read_requests(v_scale_read_requests),
        .k_read_starvation_cycles(k_read_starvation_cycles),
        .v_read_starvation_cycles(v_read_starvation_cycles),
        .k_starvation_high_water(k_starvation_high_water),
        .v_starvation_high_water(v_starvation_high_water),
        .read_outstanding_high_water(read_outstanding_high_water),
        .arithmetic_active_cycles(arithmetic_active_cycles),
        .score_stall_cycles(score_stall_cycles),
        .result_stall_cycles(result_stall_cycles),
        .score_count(score_count), .result_count(result_count)
    );

    reg [79:0] k_words [0:1023];
    reg [79:0] v_words [0:1023];
    reg [SCALE_BITS-1:0] k_scales [0:127];
    reg [SCALE_BITS-1:0] v_scales [0:127];
    reg k_scale_pending, k_p16_pending, v_scale_pending, v_p16_pending;
    reg [6:0] k_scale_pending_addr, v_scale_pending_addr;
    reg [9:0] k_p16_pending_addr, v_p16_pending_addr;
    integer k_scale_delay, k_p16_delay, v_scale_delay, v_p16_delay;
    integer model_k_delay, model_v_delay;
    integer inject_zero_k_token, inject_zero_v_token;

    // Independent synchronous read models.  Deliberately different response
    // delays prove that neither arithmetic stream borrows the other's port.
    always @(posedge clk) begin
        if (!rst_n) begin
            k_scale_rd_valid <= 1'b0;
            k_p16_rd_valid <= 1'b0;
            v_scale_rd_valid <= 1'b0;
            v_p16_rd_valid <= 1'b0;
            k_scale_pending <= 1'b0;
            k_p16_pending <= 1'b0;
            v_scale_pending <= 1'b0;
            v_p16_pending <= 1'b0;
        end else begin
            k_scale_rd_valid <= 1'b0;
            k_p16_rd_valid <= 1'b0;
            v_scale_rd_valid <= 1'b0;
            v_p16_rd_valid <= 1'b0;

            if (k_scale_pending) begin
                if (k_scale_delay == 0) begin
                    k_scale_rd_valid <= 1'b1;
                    if (k_scale_pending_addr == inject_zero_k_token)
                        k_scale_rd_data <= {SCALE_BITS{1'b0}};
                    else
                        k_scale_rd_data <= k_scales[k_scale_pending_addr];
                    k_scale_pending <= 1'b0;
                end else k_scale_delay <= k_scale_delay - 1;
            end
            if (k_p16_pending) begin
                if (k_p16_delay == 0) begin
                    k_p16_rd_valid <= 1'b1;
                    k_p16_rd_codes <= k_words[k_p16_pending_addr];
                    k_p16_pending <= 1'b0;
                end else k_p16_delay <= k_p16_delay - 1;
            end
            if (v_scale_pending) begin
                if (v_scale_delay == 0) begin
                    v_scale_rd_valid <= 1'b1;
                    if (v_scale_pending_addr == inject_zero_v_token)
                        v_scale_rd_data <= {SCALE_BITS{1'b0}};
                    else
                        v_scale_rd_data <= v_scales[v_scale_pending_addr];
                    v_scale_pending <= 1'b0;
                end else v_scale_delay <= v_scale_delay - 1;
            end
            if (v_p16_pending) begin
                if (v_p16_delay == 0) begin
                    v_p16_rd_valid <= 1'b1;
                    v_p16_rd_codes <= v_words[v_p16_pending_addr];
                    v_p16_pending <= 1'b0;
                end else v_p16_delay <= v_p16_delay - 1;
            end

            if (k_scale_rd_en) begin
                if (k_scale_pending)
                    $fatal(1, "overlapping K scale request");
                k_scale_pending <= 1'b1;
                k_scale_pending_addr <= k_scale_rd_addr;
                k_scale_delay <= model_k_delay;
            end
            if (k_p16_rd_en) begin
                if (k_p16_pending)
                    $fatal(1, "overlapping K P16 request");
                k_p16_pending <= 1'b1;
                k_p16_pending_addr <= k_p16_rd_addr;
                k_p16_delay <= model_k_delay;
            end
            if (v_scale_rd_en) begin
                if (v_scale_pending)
                    $fatal(1, "overlapping V scale request");
                v_scale_pending <= 1'b1;
                v_scale_pending_addr <= v_scale_rd_addr;
                v_scale_delay <= model_v_delay;
            end
            if (v_p16_rd_en) begin
                if (v_p16_pending)
                    $fatal(1, "overlapping V P16 request");
                v_p16_pending <= 1'b1;
                v_p16_pending_addr <= v_p16_rd_addr;
                v_p16_delay <= model_v_delay;
            end

            if (k_page_release)
                k_page_active <= 1'b0;
            if (v_page_release)
                v_page_active <= 1'b0;
        end
    end

    reg signed [15:0] score_reference [0:511];
    reg score_sat_reference [0:511];
    reg signed [47:0] numerator_reference [0:511];
    reg signed [17:0] normalized_reference [0:511];
    reg result_sat_reference [0:511];
    reg signed [15:0] short_score_reference [0:511];
    reg signed [47:0] short_numerator_reference [0:511];
    reg signed [17:0] short_normalized_reference [0:511];
    reg [111:0] denominator_reference, short_denominator_reference;
    reg [51:0] reciprocal_reference, short_reciprocal_reference;
    reg [19:0] exponent_reference, short_exponent_reference;
    integer collected_scores, collected_results;
    integer collect_mode;
    reg collect_enable;
    reg expected_k_raw, expected_v_raw;
    reg saw_row_abort, saw_aborted;
    integer release_k_count, release_v_count;

    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 0;
            saw_row_abort <= 1'b0;
            saw_aborted <= 1'b0;
            release_k_count <= 0;
            release_v_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (row_abort)
                saw_row_abort <= 1'b1;
            if (aborted)
                saw_aborted <= 1'b1;
            if (k_page_release)
                release_k_count <= release_k_count + 1;
            if (v_page_release)
                release_v_count <= release_v_count + 1;

            if (collect_enable && score_valid && score_ready) begin
                if (score_index !== collected_scores/4 ||
                    score_row !== collected_scores%4)
                    $fatal(1, "score order mismatch n=%0d row=%0d index=%0d",
                           collected_scores, score_row, score_index);
                case (collect_mode)
                    0: begin
                        score_reference[collected_scores] <= score_data;
                        score_sat_reference[collected_scores] <= score_saturated;
                    end
                    1: begin
                        if (score_data !== score_reference[collected_scores] ||
                            score_saturated !==
                                score_sat_reference[collected_scores])
                            $fatal(1, "RAW/COMPRESSED score mismatch n=%0d",
                                   collected_scores);
                    end
                    2: short_score_reference[collected_scores] <= score_data;
                    3: if (score_data !== short_score_reference[collected_scores])
                        $fatal(1, "short RAW/COMPRESSED score mismatch n=%0d",
                               collected_scores);
                endcase
                collected_scores <= collected_scores + 1;
            end

            if (collect_enable && result_valid && result_ready) begin
                if (result_head !== collected_results/128 ||
                    result_dimension !== collected_results%128)
                    $fatal(1, "result order mismatch n=%0d head=%0d dim=%0d",
                           collected_results, result_head, result_dimension);
                if (result_k_task_tag !== k_task_tag ||
                    result_v_task_tag !== v_task_tag ||
                    result_epoch !== k_epoch ||
                    result_page_index !== k_page_index ||
                    result_k_raw_mode !== expected_k_raw ||
                    result_v_raw_mode !== expected_v_raw)
                    $fatal(1, "result typed metadata mismatch n=%0d",
                           collected_results);
                if (result_last !== (collected_results == 511))
                    $fatal(1, "result last mismatch n=%0d", collected_results);
                case (collect_mode)
                    0: begin
                        numerator_reference[collected_results] <=
                            result_numerator;
                        normalized_reference[collected_results] <=
                            result_normalized;
                        result_sat_reference[collected_results] <=
                            result_saturated;
                    end
                    1: begin
                        if (result_numerator !==
                                numerator_reference[collected_results] ||
                            result_normalized !==
                                normalized_reference[collected_results] ||
                            result_saturated !==
                                result_sat_reference[collected_results])
                            $fatal(1,
                                "RAW/COMPRESSED AV mismatch n=%0d", collected_results);
                    end
                    2: begin
                        short_numerator_reference[collected_results] <=
                            result_numerator;
                        short_normalized_reference[collected_results] <=
                            result_normalized;
                    end
                    3: begin
                        if (result_numerator !==
                                short_numerator_reference[collected_results] ||
                            result_normalized !==
                                short_normalized_reference[collected_results])
                            $fatal(1, "short AV mismatch n=%0d", collected_results);
                    end
                endcase
                collected_results <= collected_results + 1;
            end
        end
    end

    task configure_pages;
        input integer count;
        input integer raw_label;
        begin
            k_page_active = 1'b1;
            v_page_active = 1'b1;
            k_task_tag = {16'h0003,16'h0007,16'h0000,8'h11,8'h5a};
            v_task_tag = {16'h0003,16'h0007,16'h0000,8'h22,8'h5a};
            k_epoch = 16'h1234;
            v_epoch = 16'h1234;
            k_page_index = 5'd6;
            v_page_index = 5'd6;
            k_stream_is_v = 1'b0;
            v_stream_is_v = 1'b1;
            k_raw_mode = raw_label != 0;
            v_raw_mode = raw_label != 0;
            k_expected_symbols = count * 128;
            v_expected_symbols = count * 128;
            k_token_count = count;
            v_token_count = count;
            k_scale_slice_bytes = ((count*SCALE_BITS)+7)/8;
            v_scale_slice_bytes = ((count*SCALE_BITS)+7)/8;
            context_len = count;
            expected_k_raw = raw_label != 0;
            expected_v_raw = raw_label != 0;
        end
    endtask

    task pulse_counter_clear;
        begin
            @(negedge clk);
            clear_counters = 1'b1;
            @(negedge clk);
            clear_counters = 1'b0;
        end
    endtask

    task launch_current_pages;
        begin
            @(negedge clk);
            while (!start_ready)
                @(negedge clk);
            start_valid = 1'b1;
            @(negedge clk);
            start_valid = 1'b0;
        end
    endtask

    task run_good;
        input integer count;
        input integer raw_label;
        input integer mode;
        input integer use_backpressure;
        integer watchdog;
        begin
            inject_zero_k_token = -1;
            inject_zero_v_token = -1;
            force_score_hold = 1'b0;
            force_result_hold = 1'b0;
            enable_backpressure = use_backpressure != 0;
            collect_enable = 1'b0;
            collected_scores = 0;
            collected_results = 0;
            collect_mode = mode;
            @(negedge clk);
            configure_pages(count, raw_label);
            pulse_counter_clear();
            collect_enable = 1'b1;
            launch_current_pages();
            watchdog = 0;
            while (!done && watchdog < 300000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
                if (sticky_error)
                    $fatal(1, "good run fault code=%02x sub=%02x state=%0d av=%0d/%0d expected=%0d/%0d beat=%0d",
                           sticky_error_code, sticky_error_subcode,
                           progress_state, dut.av_out_head, dut.av_out_group,
                           dut.norm_head_reg, dut.expected_av_group,
                           dut.beat_active);
            end
            if (!done)
                $fatal(1, "good run timeout scale=%0d", SCALE_BITS);
            @(negedge clk);
            collect_enable = 1'b0;
            enable_backpressure = 1'b0;
            if (collected_scores != count*4)
                $fatal(1, "score count %0d expected %0d",
                       collected_scores, count*4);
            if (collected_results != 512)
                $fatal(1, "result count %0d expected 512", collected_results);
            if (score_count != count*4 || result_count != 512)
                $fatal(1, "performance commit counts wrong score=%0d result=%0d",
                       score_count, result_count);
            if (k_scale_read_requests != count ||
                v_scale_read_requests != count ||
                k_p16_read_requests != count*32 ||
                v_p16_read_requests != count*32)
                $fatal(1,
                    "read request counts wrong K=%0d/%0d V=%0d/%0d",
                    k_scale_read_requests, k_p16_read_requests,
                    v_scale_read_requests, v_p16_read_requests);
            if (k_read_starvation_cycles == 0 ||
                v_read_starvation_cycles == 0 ||
                k_starvation_high_water == 0 ||
                v_starvation_high_water == 0 ||
                read_outstanding_high_water != 1)
                $fatal(1, "starvation/high-water counters not exercised");
            if (k_page_active || v_page_active)
                $fatal(1, "successful run did not release both pages");
        end
    endtask

    task wait_for_fault;
        input [7:0] expected_code;
        integer watchdog;
        begin
            watchdog = 0;
            while (!(sticky_error && clear_ready) && watchdog < 100000) begin
                @(posedge clk);
                watchdog = watchdog + 1;
                if (sticky_error && (score_valid || result_valid))
                    $fatal(1, "fault exposed stale output");
            end
            if (!(sticky_error && clear_ready))
                $fatal(1, "fault drain timeout expected=%02x state=%0d",
                       expected_code, progress_state);
            if (sticky_error_code !== expected_code)
                $fatal(1, "fault code %02x expected %02x sub=%02x",
                       sticky_error_code, expected_code,
                       sticky_error_subcode);
            if (!saw_row_abort)
                $fatal(1, "fault omitted row_abort");
            @(posedge clk);
            if (k_page_active || v_page_active)
                $fatal(1, "fault did not release both pages");
        end
    endtask

    task clear_current_fault;
        begin
            @(negedge clk);
            clear_fault = 1'b1;
            @(negedge clk);
            clear_fault = 1'b0;
            while (sticky_error)
                @(negedge clk);
            saw_row_abort = 1'b0;
            saw_aborted = 1'b0;
        end
    endtask

    task short_restart;
        begin
            clear_current_fault();
            run_good(1, 0, 4, 0);
        end
    endtask

    task start_fault_transaction;
        input integer count;
        begin
            collect_enable = 1'b0;
            enable_backpressure = 1'b0;
            force_score_hold = 1'b0;
            force_result_hold = 1'b0;
            inject_zero_k_token = -1;
            inject_zero_v_token = -1;
            saw_row_abort = 1'b0;
            saw_aborted = 1'b0;
            @(negedge clk);
            configure_pages(count, 0);
            pulse_counter_clear();
            launch_current_pages();
        end
    endtask

    task pulse_abort_now;
        begin
            @(negedge clk);
            abort = 1'b1;
            @(negedge clk);
            abort = 1'b0;
        end
    endtask

    integer t, g, l, r, d;
    integer late_av_abort_watchdog;
    integer kval, vval, qval;
    reg signed [47:0] held_numerator;
    reg signed [17:0] held_normalized;
    reg [6:0] held_dimension;
    initial begin
        start_valid = 1'b0;
        context_len = 13'd0;
        abort = 1'b0;
        clear_fault = 1'b0;
        clear_counters = 1'b0;
        q_wr_en = 1'b0;
        q_wr_row = 2'd0;
        q_wr_addr = 7'd0;
        q_wr_data = 8'sd0;
        k_page_active = 1'b0;
        v_page_active = 1'b0;
        k_task_tag = 64'd0;
        v_task_tag = 64'd0;
        k_epoch = 16'd0;
        v_epoch = 16'd0;
        k_page_index = 5'd0;
        v_page_index = 5'd0;
        k_stream_is_v = 1'b0;
        v_stream_is_v = 1'b1;
        k_raw_mode = 1'b0;
        v_raw_mode = 1'b0;
        k_expected_symbols = 15'd0;
        v_expected_symbols = 15'd0;
        k_token_count = 8'd0;
        v_token_count = 8'd0;
        k_scale_slice_bytes = 9'd0;
        v_scale_slice_bytes = 9'd0;
        k_p16_rd_valid = 1'b0;
        v_p16_rd_valid = 1'b0;
        k_scale_rd_valid = 1'b0;
        v_scale_rd_valid = 1'b0;
        k_p16_rd_codes = 80'd0;
        v_p16_rd_codes = 80'd0;
        k_scale_rd_data = {SCALE_BITS{1'b0}};
        v_scale_rd_data = {SCALE_BITS{1'b0}};
        force_score_hold = 1'b0;
        force_result_hold = 1'b0;
        enable_backpressure = 1'b0;
        collect_enable = 1'b0;
        collect_mode = 0;
        collected_scores = 0;
        collected_results = 0;
        expected_k_raw = 1'b0;
        expected_v_raw = 1'b0;
        model_k_delay = 2;
        model_v_delay = 4;
        inject_zero_k_token = -1;
        inject_zero_v_token = -1;

        for (t = 0; t < 128; t = t + 1) begin
            k_scales[t] = ((SCALE_BITS == 16) ? 8 : 1) + (t % 3);
            v_scales[t] = ((SCALE_BITS == 16) ? 9 : 2) + (t % 2);
            for (g = 0; g < 8; g = g + 1) begin
                k_words[t*8+g] = 80'd0;
                v_words[t*8+g] = 80'd0;
                for (l = 0; l < 16; l = l + 1) begin
                    kval = ((t*5 + g*3 + l*7) % 15) - 7;
                    vval = ((t*11 + g*5 + l*3) % 31) - 15;
                    k_words[t*8+g][(l*5) +: 5] = kval;
                    v_words[t*8+g][(l*5) +: 5] = vval;
                end
            end
        end

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        // Load every query address exactly once; duplicate-address counting
        // would not satisfy queries_ready.
        for (r = 0; r < 4; r = r + 1) begin
            for (d = 0; d < 128; d = d + 1) begin
                @(negedge clk);
                qval = ((r*13 + d*5) % 23) - 11;
                q_wr_en = 1'b1;
                q_wr_row = r;
                q_wr_addr = d;
                q_wr_data = qval;
            end
        end
        @(negedge clk);
        q_wr_en = 1'b0;
        if (!queries_ready)
            $fatal(1, "query preload did not publish");

        // Byte-identical values with only the whole-page RAW label changed.
        run_good(LONG_CONTEXT, 1, 0, 1);
        denominator_reference = denominators;
        reciprocal_reference = reciprocal_codes;
        exponent_reference = reciprocal_exponents;
        run_good(LONG_CONTEXT, 0, 1, 1);
        if (denominators !== denominator_reference ||
            reciprocal_codes !== reciprocal_reference ||
            reciprocal_exponents !== exponent_reference)
            $fatal(1, "RAW/COMPRESSED softmax summary mismatch");

        // Short-after-long uses no reset and must not expose any prior score,
        // exponent, numerator, or normalized dimension.
        run_good(SHORT_CONTEXT, 1, 2, 0);
        short_denominator_reference = denominators;
        short_reciprocal_reference = reciprocal_codes;
        short_exponent_reference = reciprocal_exponents;
        run_good(SHORT_CONTEXT, 0, 3, 0);
        if (denominators !== short_denominator_reference ||
            reciprocal_codes !== short_reciprocal_reference ||
            reciprocal_exponents !== short_exponent_reference)
            $fatal(1, "short RAW/COMPRESSED softmax summary mismatch");

        // Typed tag mismatch at acceptance.
        @(negedge clk);
        configure_pages(2, 0);
        v_task_tag[7:0] = 8'h5b;
        saw_row_abort = 1'b0;
        launch_current_pages();
        wait_for_fault(8'h02);
        short_restart();

        // Typed stream mismatch and epoch mismatch are independent gates.
        @(negedge clk);
        configure_pages(2, 0);
        k_stream_is_v = 1'b1;
        saw_row_abort = 1'b0;
        launch_current_pages();
        wait_for_fault(8'h01);
        clear_current_fault();
        @(negedge clk);
        configure_pages(2, 0);
        v_epoch = 16'h1235;
        saw_row_abort = 1'b0;
        launch_current_pages();
        wait_for_fault(8'h03);
        short_restart();

        // A zero K token scale after token zero proves partial scores abort
        // rather than commit or leak into the following restart.
        inject_zero_k_token = 1;
        start_fault_transaction(3);
        inject_zero_k_token = 1;
        wait_for_fault(8'h04);
        if (score_count != 4)
            $fatal(1, "scale fault did not occur after one complete token");
        inject_zero_k_token = -1;
        short_restart();

        // Explicit abort in QK, after a partial score row, softmax, and AV.
        start_fault_transaction(3);
        while (progress_state != 7)
            @(posedge clk);
        pulse_abort_now();
        wait_for_fault(8'h0a);
        if (!saw_aborted)
            $fatal(1, "QK abort did not report aborted");
        short_restart();

        start_fault_transaction(3);
        while (score_count < 2)
            @(posedge clk);
        pulse_abort_now();
        wait_for_fault(8'h0a);
        short_restart();

        start_fault_transaction(2);
        while (progress_state != 13)
            @(posedge clk);
        pulse_abort_now();
        wait_for_fault(8'h0a);
        short_restart();

        start_fault_transaction(2);
        while (progress_state != 19)
            @(posedge clk);
        pulse_abort_now();
        wait_for_fault(8'h0a);
        short_restart();

        // Physical XSDB writes can reach the arithmetic core much later than
        // the first AV beat.  Reproduce the exact late-AV window observed on
        // Zybo: token 48, head 3, group 7.  Drain and the immediate no-reset
        // restart must remain bounded at a full 128-token context.
        start_fault_transaction(128);
        late_av_abort_watchdog = 0;
        while ((progress_state != 19 || progress_token != 48 ||
                progress_head != 3 || progress_group != 7) &&
               late_av_abort_watchdog < 2000000) begin
            @(posedge clk);
            late_av_abort_watchdog = late_av_abort_watchdog + 1;
        end
        if (late_av_abort_watchdog == 2000000)
            $fatal(1, "late AV abort window timeout state=%0d token=%0d head=%0d group=%0d",
                   progress_state, progress_token, progress_head,
                   progress_group);
        pulse_abort_now();
        wait_for_fault(8'h0a);
        short_restart();

        // Abort a held normalized result and verify the public tuple remains
        // stable before abort, then disappears immediately without a handshake.
        start_fault_transaction(2);
        force_result_hold = 1'b1;
        while (!result_valid)
            @(posedge clk);
        held_numerator = result_numerator;
        held_normalized = result_normalized;
        held_dimension = result_dimension;
        repeat (3) begin
            @(posedge clk);
            if (!result_valid || result_numerator !== held_numerator ||
                result_normalized !== held_normalized ||
                result_dimension !== held_dimension)
                $fatal(1, "held result was not stable");
        end
        pulse_abort_now();
        if (result_valid)
            $fatal(1, "held result remained visible on abort");
        force_result_hold = 1'b0;
        wait_for_fault(8'h0a);
        short_restart();

        // Fault-after-valid: mutate the published V tag after a score has
        // crossed the public/guard atomic handshake.
        start_fault_transaction(3);
        while (score_count == 0)
            @(posedge clk);
        @(negedge clk);
        v_task_tag[31:16] = 16'h0001;
        wait_for_fault(8'h0b);
        if (score_count == 0)
            $fatal(1, "fault-after-valid setup failed");
        short_restart();

        if (SCALE_BITS == 12)
            $display("KV_V03_CANNED_PAGE_ARITHMETIC_SCALE12_PASS");
        else
            $display("KV_V03_CANNED_PAGE_ARITHMETIC_SCALE16_PASS");
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "canned page arithmetic global timeout scale=%0d",
               SCALE_BITS);
    end
endmodule

`default_nettype wire
