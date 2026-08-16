// tb_kv_cache_engine.v -- boundary lengths, stalls, stale state and errors.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_cache_engine;
`ifdef HEAD_DIM_VAL
    localparam HEAD_DIM = `HEAD_DIM_VAL;
`else
    localparam HEAD_DIM = 64;
`endif
    localparam P = 16, MAX_CONTEXT = 4096;
`ifdef AXI_DATA_WIDTH_VAL
    localparam AXI_WIDTH = `AXI_DATA_WIDTH_VAL;
`else
    localparam AXI_WIDTH = 128;
`endif
    localparam VECTOR_BITS = HEAD_DIM * 4;
    localparam VECTOR_BYTES = VECTOR_BITS / 8;
    localparam VECTOR_SHIFT = $clog2(VECTOR_BYTES);
    localparam BEATS_PER_VECTOR = VECTOR_BITS / AXI_WIDTH;
    localparam BASE = 32'h8000_1000;
    localparam SCALE = 16'sh0100;
    localparam SCALE_GROUP_SIZE = 32;
    localparam SCALE_GROUPS = HEAD_DIM / SCALE_GROUP_SIZE;
    localparam TOKEN_WIDTH = $clog2(MAX_CONTEXT);

    reg clk = 0, rst_n = 0, start = 0;
    reg [31:0] k_base_addr = BASE;
    reg [31:0] context_len = 0;
    reg [(HEAD_DIM*8)-1:0] q_vector;
    wire busy, done, error;
    wire [7:0] error_code;
    wire [31:0] perf_cycles;
    wire logit_valid;
    wire [TOKEN_WIDTH-1:0] logit_index;
    wire signed [31:0] logit_data;

    wire [0:0] arid;
    wire [31:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arlock;
    wire [3:0] arcache, arqos;
    wire [2:0] arprot;
    wire arvalid;
    reg arready = 0;
    reg [0:0] rid = 0;
    reg [AXI_WIDTH-1:0] rdata = 0;
    reg [1:0] rresp = 0;
    reg rlast = 0, rvalid = 0;
    wire rready;
    always #5 clk = ~clk;

    kv_cache_engine #(
        .HEAD_DIM(HEAD_DIM), .KV_BITS(4), .AXI_DATA_WIDTH(AXI_WIDTH),
        .AXI_ADDR_WIDTH(32), .AXI_ID_WIDTH(1), .P(P),
        .MAX_CONTEXT(MAX_CONTEXT), .Q_WIDTH(8), .SCALE_WIDTH(16),
        .SCALE_GROUP_SIZE(SCALE_GROUP_SIZE),
        .ACC_WIDTH(32), .TIMEOUT_CYCLES(1000)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .k_base_addr(k_base_addr), .context_len(context_len),
        .q_vector(q_vector), .k_scales({SCALE_GROUPS{SCALE}}),
        .busy(busy), .done(done), .error(error), .error_code(error_code),
        .perf_cycles(perf_cycles), .logit_valid(logit_valid),
        .logit_index(logit_index), .logit_data(logit_data),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arlock(arlock), .m_axi_arcache(arcache),
        .m_axi_arprot(arprot), .m_axi_arqos(arqos),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    function signed [3:0] k_at;
        input integer token;
        input integer dim;
        integer signed_value;
        begin
            signed_value = ((token * 3 + dim * 5) % 15) - 7;
            k_at = signed_value[3:0];
        end
    endfunction

    function integer q_at;
        input integer dim;
        begin q_at = (dim % 9) - 4; end
    endfunction

    function signed [31:0] expected_dot;
        input integer token;
        integer dim;
        integer k_code;
        integer k_signed;
        reg signed [31:0] sum;
        begin
            sum = 0;
            // Keep the reference arithmetic at integer width. XSIM 2026.1
            // context-sizes the multiplication through the signed 4-bit
            // function return differently from Icarus, which made the old
            // checker disagree even though the DUT result was correct.
            for (dim = 0; dim < HEAD_DIM; dim = dim + 1) begin
                k_code = (token * 3 + dim * 5) % 15;
                k_signed = k_code - 7;
                sum = sum + q_at(dim) * k_signed * 256;
            end
            expected_dot = sum;
        end
    endfunction

    function [AXI_WIDTH-1:0] make_beat;
        input integer token;
        input integer beat;
        integer lane;
        reg [AXI_WIDTH-1:0] value;
        begin
            value = 0;
            for (lane = 0; lane < AXI_WIDTH/4; lane = lane + 1)
                value[(lane*4) +: 4] =
                    k_at(token, beat*(AXI_WIDTH/4) + lane);
            make_beat = value;
        end
    endfunction

    reg pending = 0;
    integer pending_token = 0, beat_no = 0;
    reg [15:0] lfsr = 16'h1ace;
    reg inject_rresp_error = 0;
    reg force_ar_stall = 0, force_r_stall = 0;
    integer protocol_errors = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            pending <= 0; arready <= 0; rvalid <= 0; rresp <= 0;
            lfsr <= 16'h1ace; beat_no <= 0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            arready <= !force_ar_stall && !pending && lfsr[0];
            if (arvalid && arready) begin
                pending       <= 1;
                pending_token <= (araddr - BASE) >> VECTOR_SHIFT;
                beat_no       <= 0;
                if (arlen != BEATS_PER_VECTOR-1 ||
                    arsize != $clog2(AXI_WIDTH/8) || arburst != 2'b01) begin
                    $display("FAIL AXI AR: len=%0d size=%0d burst=%0d", arlen, arsize, arburst);
                    protocol_errors = protocol_errors + 1;
                end
            end
            if (!rvalid && pending && !force_r_stall && lfsr[1]) begin
                rdata  <= make_beat(pending_token, beat_no);
                rlast  <= (beat_no == BEATS_PER_VECTOR-1);
                rresp  <= inject_rresp_error ? 2'b10 : 2'b00;
                rvalid <= 1;
            end
            if (rvalid && rready) begin
                rvalid <= 0;
                rresp  <= 0;
                if (rlast) pending <= 0;
                else beat_no <= beat_no + 1;
            end
        end
    end

    integer seen = 0, active_length = 0, errors = 0;
    integer account_issue = 0, account_reader_launch = 0;
    integer account_axi_ar = 0, account_axi_r_empty = 0;
    integer account_axi_r_transfer = 0, account_beat_handoff = 0;
    integer account_mac = 0, account_result = 0, account_other = 0;
    reg checking = 0;
    always @(posedge clk) begin
        if (checking && busy) begin
            case (dut.state)
                3'd1: account_issue = account_issue + 1;
                3'd2: begin
                    case (dut.u_reader.state)
                        2'd0: account_reader_launch = account_reader_launch + 1;
                        2'd1: account_axi_ar = account_axi_ar + 1;
                        2'd2: begin
                            if (dut.u_reader.beat_valid)
                                account_beat_handoff = account_beat_handoff + 1;
                            else if (rvalid && rready)
                                account_axi_r_transfer = account_axi_r_transfer + 1;
                            else
                                account_axi_r_empty = account_axi_r_empty + 1;
                        end
                        default: account_other = account_other + 1;
                    endcase
                end
                3'd3: account_mac = account_mac + 1;
                3'd4: account_result = account_result + 1;
                default: account_other = account_other + 1;
            endcase
        end
        if (checking && logit_valid) begin
            if (logit_index !== seen[TOKEN_WIDTH-1:0]) begin
                $display("FAIL length %0d: index got %0d want %0d",
                         active_length, logit_index, seen);
                errors = errors + 1;
            end
            if ($signed(logit_data) !== expected_dot(seen)) begin
                $display("FAIL length %0d token %0d: got %0d want %0d",
                         active_length, seen, $signed(logit_data), expected_dot(seen));
                errors = errors + 1;
            end
            seen = seen + 1;
        end
    end

    task run_case;
        input integer length;
        integer cycles;
        reg saw_done, saw_error;
        reg [7:0] saw_error_code;
        begin
            active_length = length; seen = 0; checking = 1;
            // Each performance case starts from the same deterministic AXI
            // back-pressure phase so cycle accounting does not depend on the
            // set or order of preceding regression lengths.
            account_issue = 0; account_reader_launch = 0;
            account_axi_ar = 0; account_axi_r_empty = 0;
            account_axi_r_transfer = 0; account_beat_handoff = 0;
            account_mac = 0; account_result = 0; account_other = 0;
            context_len = length; k_base_addr = BASE;
            @(negedge clk); lfsr = 16'h1ace; start = 1;
            @(negedge clk); start = 0;
            cycles = 0;
            while (!done && !error && cycles < length*40 + 2000) begin
                @(negedge clk); cycles = cycles + 1;
            end
            saw_done = done;
            saw_error = error;
            saw_error_code = error_code;
            // DONE and the final logit are produced together. The monitor
            // samples registered outputs on the following rising edge.
            @(posedge clk); #1; checking = 0;
            if (saw_error) begin
                $display("FAIL length %0d: engine error %02x", length, saw_error_code);
                errors = errors + 1;
            end else if (!saw_done) begin
                $display("FAIL length %0d: timeout after %0d cycles", length, cycles);
                errors = errors + 1;
            end else if (seen != length) begin
                $display("FAIL length %0d: saw %0d logits", length, seen);
                errors = errors + 1;
            end else begin
                $display("PASS length %0d: %0d cycles", length, perf_cycles);
            end
            if (length == 512 || length == 4096) begin
                $display("CYCLE_ACCOUNT width=%0d length=%0d total=%0d issue=%0d reader_launch=%0d axi_ar=%0d axi_r_empty=%0d axi_r_transfer=%0d beat_handoff=%0d mac=%0d result=%0d other=%0d",
                         AXI_WIDTH, length, perf_cycles, account_issue,
                         account_reader_launch, account_axi_ar,
                         account_axi_r_empty, account_axi_r_transfer,
                         account_beat_handoff, account_mac, account_result,
                         account_other);
            end
            repeat (3) @(posedge clk);
        end
    endtask

    task wait_for_error;
        input integer max_cycles;
        output reg saw_error;
        integer guard;
        begin
            guard = 0;
            while (!error && guard < max_cycles) begin
                @(negedge clk);
                guard = guard + 1;
            end
            saw_error = error;
        end
    endtask

    integer d;
    initial begin
        q_vector = 0;
        for (d = 0; d < HEAD_DIM; d = d + 1)
            q_vector[(d*8) +: 8] = q_at(d);
        repeat (5) @(negedge clk); rst_n = 1;
        repeat (3) @(posedge clk);

`ifdef CYCLE_ACCOUNT_ONLY
        run_case(512);
        run_case(4096);
        if (errors == 0) begin
            $display("TB PASS: KV cycle accounting");
            $finish;
        end else begin
            $fatal(1, "TB FAIL: %0d KV cycle-accounting errors", errors);
        end
`else
        run_case(1); run_case(7); run_case(63); run_case(64); run_case(65);
        run_case(127); run_case(128); run_case(129);
        run_case(511); run_case(512); run_case(513);
        run_case(1023); run_case(1024); run_case(1025);
        run_case(4095); run_case(4096);
        run_case(7); // stale-state check: short run after the maximum

        // Invalid runtime length must fail without issuing a read.
        context_len = 0;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        if (!error || error_code != 8'h01) begin
            $display("FAIL invalid context: error=%0d code=%02x", error, error_code);
            errors = errors + 1;
        end else $display("PASS invalid context rejected");
        repeat (3) @(posedge clk);

        // An unaligned vector base is rejected before AXI activity.
        context_len = 1; k_base_addr = BASE + 4;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        if (!error || error_code != 8'h02) begin
            $display("FAIL unaligned base: error=%0d code=%02x", error, error_code);
            errors = errors + 1;
        end else $display("PASS unaligned base rejected");
        repeat (3) @(posedge clk);

        // Both AXI channel timeout classes propagate through the engine.
        k_base_addr = BASE; context_len = 1; force_ar_stall = 1;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        begin : ar_timeout_check
        reg saw_timeout;
        wait_for_error(1500, saw_timeout);
        if (!saw_timeout || error_code != 8'h11) begin
            $display("FAIL AR timeout propagation error=%0d code=%02x",
                     saw_timeout, error_code);
            errors = errors + 1;
        end else $display("PASS AR timeout propagated");
        end
        force_ar_stall = 0;
        repeat (3) @(posedge clk);

        force_r_stall = 1;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        begin : r_timeout_check
        reg saw_timeout;
        wait_for_error(1500, saw_timeout);
        if (!saw_timeout || error_code != 8'h12) begin
            $display("FAIL R timeout propagation error=%0d code=%02x",
                     saw_timeout, error_code);
            errors = errors + 1;
        end else $display("PASS R timeout propagated");
        end
        force_r_stall = 0;

        // Reset clears the deliberately abandoned timed-out read before the
        // independent RRESP test, and covers a reset boundary in the process.
        @(negedge clk); rst_n = 0;
        repeat (3) @(negedge clk); rst_n = 1;
        repeat (3) @(posedge clk);

        // Propagate memory response errors. This is last because the memory
        // model deliberately leaves the rest of the failed burst pending.
        k_base_addr = BASE; context_len = 1; inject_rresp_error = 1;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        begin : rresp_check
        reg saw_response_error;
        wait_for_error(1500, saw_response_error);
        if (!saw_response_error || error_code != 8'h13) begin
            $display("FAIL RRESP propagation error=%0d code=%02x",
                     saw_response_error, error_code);
            errors = errors + 1;
        end else $display("PASS RRESP error propagated");
        end

        errors = errors + protocol_errors;
        if (errors == 0) begin
            $display("TB PASS: KV engine regression");
            $finish;
        end else begin
            $fatal(1, "TB FAIL: %0d KV engine errors", errors);
        end
`endif
    end
endmodule

`default_nettype wire
