// tb_kv_v03_hp64_range_reader.v -- tagged HP64 range reader regression.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_kv_v03_hp64_range_reader;
    localparam integer ADDR_WIDTH = 32;
    localparam integer ID_WIDTH = 1;
    localparam integer TAG_WIDTH = 64;
    localparam integer TIMEOUT_CYCLES = 8;
    localparam integer MAX_BYTES = 10256;
    localparam integer WATCHDOG_CYCLES = 60000;

    localparam [7:0] ERR_ALIGN         = 8'h01;
    localparam [7:0] ERR_ADDRESS_RANGE = 8'h02;
    localparam [7:0] ERR_LENGTH        = 8'h03;
    localparam [7:0] ERR_AR_TIMEOUT    = 8'h10;
    localparam [7:0] ERR_R_TIMEOUT     = 8'h11;
    localparam [7:0] ERR_RID           = 8'h12;
    localparam [7:0] ERR_RRESP         = 8'h13;
    localparam [7:0] ERR_RLAST         = 8'h14;
    localparam [7:0] ERR_DRAIN_TIMEOUT = 8'h15;

    localparam integer INJECT_NONE          = 0;
    localparam integer INJECT_RID           = 1;
    localparam integer INJECT_RRESP         = 2;
    localparam integer INJECT_EARLY_RLAST   = 3;
    localparam integer INJECT_MISSING_RLAST = 4;

    localparam integer READY_ALWAYS = 0;
    localparam integer READY_PATTERN = 1;
    localparam integer READY_NEVER = 2;

    localparam [63:0] TAG_BASE       = 64'h4850_3634_0000_0000;
    localparam [63:0] TAG_LONG       = 64'h4850_3634_aaaa_1025;
    localparam [63:0] TAG_SHORT      = 64'h4850_3634_5555_0001;
    localparam [63:0] TAG_FAULT      = 64'h4850_3634_dead_beef;
    localparam [63:0] TAG_RESTART    = 64'h4850_3634_cafe_0001;

    reg clk = 0;
    reg rst_n = 0;

    reg cmd_valid = 0;
    wire cmd_ready;
    reg [ADDR_WIDTH-1:0] cmd_addr = 0;
    reg [13:0] cmd_bytes = 0;
    reg [TAG_WIDTH-1:0] cmd_tag = 0;
    reg abort = 0;

    wire data_valid;
    reg data_ready = 0;
    wire [63:0] data;
    wire [7:0] data_keep;
    wire data_last;
    wire [13:0] data_byte_offset;
    wire [TAG_WIDTH-1:0] data_tag;

    wire busy;
    wire draining;
    wire done;
    wire [TAG_WIDTH-1:0] done_tag;
    wire aborted;
    wire [TAG_WIDTH-1:0] aborted_tag;
    wire error_valid;
    wire [7:0] error_code;
    wire [TAG_WIDTH-1:0] error_tag;

    reg clear_counters = 0;
    wire [31:0] read_beats;
    wire [31:0] burst_count;
    wire [31:0] ar_stall_cycles;
    wire [31:0] r_wait_cycles;
    wire [31:0] output_stall_cycles;

    wire [ID_WIDTH-1:0] m_axi_arid;
    wire [ADDR_WIDTH-1:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [2:0] m_axi_arprot;
    wire [3:0] m_axi_arqos;
    wire m_axi_arvalid;
    reg m_axi_arready = 0;

    reg [ID_WIDTH-1:0] m_axi_rid = 0;
    reg [63:0] m_axi_rdata = 0;
    reg [1:0] m_axi_rresp = 0;
    reg m_axi_rlast = 0;
    reg m_axi_rvalid = 0;
    wire m_axi_rready;

    integer errors = 0;
    integer cycle_count = 0;

    // Per-command oracle state.
    reg case_active = 0;
    reg case_expect_stream = 0;
    reg case_poisoned = 0;
    reg [ADDR_WIDTH-1:0] case_addr = 0;
    integer case_bytes = 0;
    reg [TAG_WIDTH-1:0] case_tag = 0;
    integer case_total_beats = 0;
    integer case_scheduled_beats = 0;
    integer case_ar_count = 0;
    integer case_r_count = 0;
    integer case_output_beats = 0;
    integer case_output_bytes = 0;

    // Sticky observations of one-cycle status outputs.
    integer done_pulses = 0;
    integer abort_pulses = 0;
    integer error_pulses = 0;
    integer abort_data_handshakes = 0;
    reg [TAG_WIDTH-1:0] seen_done_tag = 0;
    reg [TAG_WIDTH-1:0] seen_abort_tag = 0;
    reg [TAG_WIDTH-1:0] seen_error_tag = 0;
    reg [7:0] seen_error_code = 0;
    reg prior_done = 0;
    reg prior_aborted = 0;
    reg prior_error = 0;

    // Output stability oracle.
    reg output_hold_active = 0;
    reg [63:0] held_data = 0;
    reg [7:0] held_keep = 0;
    reg held_last = 0;
    reg [13:0] held_offset = 0;
    reg [TAG_WIDTH-1:0] held_tag = 0;

    // AR stability oracle.  This also covers poisoned AR requests, whose
    // VALID and payload must remain asserted until READY eventually rises.
    reg ar_hold_active = 0;
    reg [ADDR_WIDTH-1:0] held_araddr = 0;
    reg [7:0] held_arlen = 0;

    // AXI slave controls/state.  The model permits one outstanding burst,
    // matching the reader contract.
    reg slave_r_enable = 1;
    reg slave_r_gaps = 0;
    integer ready_mode = READY_ALWAYS;
    reg [15:0] ready_lfsr = 16'h1d3f;
    integer inject_kind = INJECT_NONE;
    integer inject_beat = 0;
    reg [1:0] inject_resp = 2'b10;

    reg model_active = 0;
    reg [ADDR_WIDTH-1:0] model_addr = 0;
    integer model_declared_beats = 0;
    integer model_total_beats = 0;
    integer model_beat_index = 0;

    integer expected_chunk;
    integer expected_remaining;
    integer expected_to_4k;
    integer expected_valid_bytes;
    integer byte_index;
    reg [7:0] expected_keep;
    reg [7:0] expected_byte;

    always #5 clk = ~clk;

    kv_v03_hp64_range_reader #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .ID_WIDTH(ID_WIDTH),
        .TAG_WIDTH(TAG_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .MAX_BYTES(MAX_BYTES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_bytes(cmd_bytes), .cmd_tag(cmd_tag),
        .abort(abort),
        .data_valid(data_valid), .data_ready(data_ready), .data(data),
        .data_keep(data_keep), .data_last(data_last),
        .data_byte_offset(data_byte_offset), .data_tag(data_tag),
        .busy(busy), .draining(draining), .done(done), .done_tag(done_tag),
        .aborted(aborted), .aborted_tag(aborted_tag),
        .error_valid(error_valid), .error_code(error_code),
        .error_tag(error_tag),
        .clear_counters(clear_counters), .read_beats(read_beats),
        .burst_count(burst_count), .ar_stall_cycles(ar_stall_cycles),
        .r_wait_cycles(r_wait_cycles),
        .output_stall_cycles(output_stall_cycles),
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

    function [7:0] pattern_byte;
        input [ADDR_WIDTH-1:0] address;
        begin
            pattern_byte = address[7:0] ^ address[15:8] ^
                           address[23:16] ^ 8'ha5;
        end
    endfunction

    function [63:0] pattern_word;
        input [ADDR_WIDTH-1:0] address;
        integer i;
        begin
            pattern_word = 64'd0;
            for (i = 0; i < 8; i = i + 1)
                pattern_word[(i*8) +: 8] = pattern_byte(address + i);
        end
    endfunction

    function [7:0] keep_mask;
        input integer count;
        begin
            case (count)
                1: keep_mask = 8'h01;
                2: keep_mask = 8'h03;
                3: keep_mask = 8'h07;
                4: keep_mask = 8'h0f;
                5: keep_mask = 8'h1f;
                6: keep_mask = 8'h3f;
                7: keep_mask = 8'h7f;
                default: keep_mask = 8'hff;
            endcase
        end
    endfunction

    // Deterministic output backpressure.  READY_PATTERN never stalls for more
    // than one cycle, keeping ordinary cases well below the timeout bound.
    always @(negedge clk) begin
        if (!rst_n) begin
            data_ready <= 1'b0;
            ready_lfsr <= 16'h1d3f;
        end else begin
            case (ready_mode)
                READY_NEVER: data_ready <= 1'b0;
                READY_PATTERN: begin
                    data_ready <= ready_lfsr[1:0] != 2'b00;
                    ready_lfsr <= {ready_lfsr[14:0],
                                   ready_lfsr[15] ^ ready_lfsr[13] ^
                                   ready_lfsr[12] ^ ready_lfsr[10]};
                end
                default: data_ready <= 1'b1;
            endcase
        end
    end

    // AXI slave plus protocol/burst oracle.
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= 0;
            model_active <= 1'b0;
            model_addr <= 0;
            model_declared_beats <= 0;
            model_total_beats <= 0;
            model_beat_index <= 0;
            m_axi_rvalid <= 1'b0;
            m_axi_rid <= 0;
            m_axi_rdata <= 0;
            m_axi_rresp <= 0;
            m_axi_rlast <= 0;
            ar_hold_active <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (m_axi_arvalid && !m_axi_arready) begin
                if (!ar_hold_active) begin
                    ar_hold_active <= 1'b1;
                    held_araddr <= m_axi_araddr;
                    held_arlen <= m_axi_arlen;
                end else if (m_axi_araddr !== held_araddr ||
                             m_axi_arlen !== held_arlen) begin
                    $display("FAIL AR payload changed while stalled addr=%08x/%08x len=%0d/%0d",
                             m_axi_araddr, held_araddr,
                             m_axi_arlen, held_arlen);
                    errors = errors + 1;
                end
            end else if (!m_axi_arvalid || m_axi_arready) begin
                ar_hold_active <= 1'b0;
            end

            if (m_axi_arvalid && m_axi_arready) begin
                if (!case_active) begin
                    $display("FAIL stale AR handshake addr=%08x", m_axi_araddr);
                    errors = errors + 1;
                end
                if (model_active) begin
                    $display("FAIL reader issued a second outstanding burst");
                    errors = errors + 1;
                end
                if (m_axi_arid !== {ID_WIDTH{1'b0}} ||
                    m_axi_arsize !== 3'd3 || m_axi_arburst !== 2'b01 ||
                    m_axi_arlock !== 1'b0 || m_axi_arcache !== 4'b0010 ||
                    m_axi_arprot !== 3'b000 || m_axi_arqos !== 4'b0000) begin
                    $display("FAIL AXI AR attributes id=%0d size=%0d burst=%0d lock=%0d cache=%x prot=%x qos=%x",
                             m_axi_arid, m_axi_arsize, m_axi_arburst,
                             m_axi_arlock, m_axi_arcache,
                             m_axi_arprot, m_axi_arqos);
                    errors = errors + 1;
                end
                if (m_axi_araddr[2:0] != 0) begin
                    $display("FAIL unaligned AXI AR address=%08x", m_axi_araddr);
                    errors = errors + 1;
                end
                if (m_axi_araddr[11:0] + ((m_axi_arlen + 1) * 8) > 4096) begin
                    $display("FAIL AXI burst crossed 4KiB addr=%08x beats=%0d",
                             m_axi_araddr, m_axi_arlen + 1);
                    errors = errors + 1;
                end

                expected_remaining = case_total_beats - case_scheduled_beats;
                expected_to_4k = (4096 - m_axi_araddr[11:0]) / 8;
                expected_chunk = expected_remaining;
                if (expected_chunk > expected_to_4k)
                    expected_chunk = expected_to_4k;
                if (expected_chunk > 256)
                    expected_chunk = 256;
                if (m_axi_araddr !== case_addr + case_scheduled_beats*8 ||
                    m_axi_arlen + 1 != expected_chunk) begin
                    $display("FAIL burst plan addr=%08x want=%08x beats=%0d want=%0d",
                             m_axi_araddr,
                             case_addr + case_scheduled_beats*8,
                             m_axi_arlen + 1, expected_chunk);
                    errors = errors + 1;
                end
                case_scheduled_beats = case_scheduled_beats +
                                       (m_axi_arlen + 1);
                case_ar_count = case_ar_count + 1;

                model_active <= 1'b1;
                model_addr <= m_axi_araddr;
                model_declared_beats <= m_axi_arlen + 1;
                model_total_beats <= (inject_kind == INJECT_MISSING_RLAST) ?
                                     (m_axi_arlen + 2) : (m_axi_arlen + 1);
                model_beat_index <= 0;
            end

            if (m_axi_rvalid && m_axi_rready) begin
                case_r_count = case_r_count + 1;
                m_axi_rvalid <= 1'b0;
                if (m_axi_rlast) begin
                    model_active <= 1'b0;
                end else begin
                    model_beat_index <= model_beat_index + 1;
                end
            end

            if (model_active && !m_axi_rvalid && slave_r_enable &&
                (!slave_r_gaps || cycle_count[1:0] != 2'b00)) begin
                m_axi_rvalid <= 1'b1;
                m_axi_rdata <= pattern_word(model_addr + model_beat_index*8);
                m_axi_rid <= ((inject_kind == INJECT_RID) &&
                              (model_beat_index == inject_beat)) ? 1'b1 : 1'b0;
                m_axi_rresp <= ((inject_kind == INJECT_RRESP) &&
                                (model_beat_index == inject_beat)) ?
                               inject_resp : 2'b00;
                if ((inject_kind == INJECT_EARLY_RLAST) &&
                    (model_beat_index == inject_beat))
                    m_axi_rlast <= 1'b1;
                else if (inject_kind == INJECT_MISSING_RLAST)
                    m_axi_rlast <= (model_beat_index == model_declared_beats);
                else
                    m_axi_rlast <=
                        (model_beat_index == model_declared_beats - 1);
            end
        end
    end

    // Stream and one-cycle status oracle.
    always @(posedge clk) begin
        if (!rst_n) begin
            done_pulses = 0;
            abort_pulses = 0;
            error_pulses = 0;
            abort_data_handshakes = 0;
            prior_done <= 1'b0;
            prior_aborted <= 1'b0;
            prior_error <= 1'b0;
            output_hold_active <= 1'b0;
        end else begin
            if (draining && cmd_ready) begin
                $display("FAIL cmd_ready rose while an AXI transaction was draining");
                errors = errors + 1;
            end
            if ((done && aborted) || (done && error_valid) ||
                (aborted && error_valid)) begin
                $display("FAIL terminal status pulses overlapped done=%0d abort=%0d error=%0d",
                         done, aborted, error_valid);
                errors = errors + 1;
            end
            if (done) begin
                done_pulses = done_pulses + 1;
                seen_done_tag = done_tag;
                if (prior_done) begin
                    $display("FAIL done was not a one-cycle pulse");
                    errors = errors + 1;
                end
                if (case_expect_stream && case_output_bytes != case_bytes) begin
                    $display("FAIL done before final output acceptance bytes=%0d want=%0d",
                             case_output_bytes, case_bytes);
                    errors = errors + 1;
                end
            end
            if (aborted) begin
                abort_pulses = abort_pulses + 1;
                seen_abort_tag = aborted_tag;
                // Any beats accepted before abort are tentative only.  Once
                // abort is acknowledged, no later beat may escape.
                case_poisoned = 1'b1;
                if (prior_aborted) begin
                    $display("FAIL aborted was not a one-cycle pulse");
                    errors = errors + 1;
                end
            end
            if (error_valid) begin
                error_pulses = error_pulses + 1;
                seen_error_code = error_code;
                seen_error_tag = error_tag;
                case_poisoned = 1'b1;
                if (prior_error) begin
                    $display("FAIL error_valid was not a one-cycle pulse");
                    errors = errors + 1;
                end
            end
            prior_done <= done;
            prior_aborted <= aborted;
            prior_error <= error_valid;

            if (abort && data_valid && data_ready)
                abort_data_handshakes = abort_data_handshakes + 1;

            if (data_valid && !data_ready) begin
                if (!output_hold_active) begin
                    output_hold_active <= 1'b1;
                    held_data <= data;
                    held_keep <= data_keep;
                    held_last <= data_last;
                    held_offset <= data_byte_offset;
                    held_tag <= data_tag;
                end else if (data !== held_data || data_keep !== held_keep ||
                             data_last !== held_last ||
                             data_byte_offset !== held_offset ||
                             data_tag !== held_tag) begin
                    $display("FAIL stream payload changed under backpressure");
                    errors = errors + 1;
                end
            end else begin
                output_hold_active <= 1'b0;
            end

            if (data_valid && data_ready) begin
                // Transport faults and post-AR aborts may follow a legal
                // prefix of tentative output beats.  Validate that prefix
                // exactly, but never mistake it for committed output: only
                // an eventual done pulse commits the complete byte range.
                if (!case_active || case_poisoned) begin
                    $display("FAIL stale/poisoned stream beat tag=%016x offset=%0d",
                             data_tag, data_byte_offset);
                    errors = errors + 1;
                end else begin
                    expected_remaining = case_bytes - case_output_bytes;
                    expected_valid_bytes = (expected_remaining > 8) ?
                                           8 : expected_remaining;
                    expected_keep = keep_mask(expected_valid_bytes);
                    if (data_byte_offset !== case_output_bytes[13:0] ||
                        data_keep !== expected_keep ||
                        data_last !==
                            (case_output_bytes + expected_valid_bytes ==
                             case_bytes) ||
                        data_tag !== case_tag) begin
                        $display("FAIL stream metadata off=%0d/%0d keep=%02x/%02x last=%0d tag=%016x/%016x",
                                 data_byte_offset, case_output_bytes,
                                 data_keep, expected_keep, data_last,
                                 data_tag, case_tag);
                        errors = errors + 1;
                    end
                    for (byte_index = 0; byte_index < 8;
                         byte_index = byte_index + 1) begin
                        if (expected_keep[byte_index]) begin
                            expected_byte = pattern_byte(
                                case_addr + case_output_bytes + byte_index);
                            if (data[(byte_index*8) +: 8] !== expected_byte) begin
                                $display("FAIL stream byte off=%0d got=%02x want=%02x",
                                         case_output_bytes + byte_index,
                                         data[(byte_index*8) +: 8],
                                         expected_byte);
                                errors = errors + 1;
                            end
                        end
                    end
                    case_output_bytes = case_output_bytes +
                                        expected_valid_bytes;
                    case_output_beats = case_output_beats + 1;
                end
            end
        end
    end

    task reset_seen_status;
        begin
            done_pulses = 0;
            abort_pulses = 0;
            error_pulses = 0;
            abort_data_handshakes = 0;
            seen_done_tag = 0;
            seen_abort_tag = 0;
            seen_error_tag = 0;
            seen_error_code = 0;
            case_poisoned = 0;
        end
    endtask

    task configure_case;
        input [ADDR_WIDTH-1:0] address;
        input integer length;
        input [TAG_WIDTH-1:0] tag;
        input expect_stream;
        begin
            if (model_active || m_axi_rvalid || busy || draining) begin
                $fatal(1, "configure_case while prior transaction is live");
            end
            reset_seen_status();
            case_active = 1'b1;
            case_expect_stream = expect_stream;
            case_addr = address;
            case_bytes = length;
            case_tag = tag;
            case_total_beats = (length + 7) / 8;
            case_scheduled_beats = 0;
            case_ar_count = 0;
            case_r_count = 0;
            case_output_beats = 0;
            case_output_bytes = 0;
            inject_kind = INJECT_NONE;
            inject_beat = 0;
            inject_resp = 2'b10;
            slave_r_enable = 1'b1;
            slave_r_gaps = 1'b0;
            ready_mode = READY_ALWAYS;
        end
    endtask

    task issue_command;
        integer timeout;
        begin
            timeout = 0;
            while (!cmd_ready && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!cmd_ready)
                $fatal(1, "command-ready timeout");
            @(negedge clk);
            cmd_addr = case_addr;
            cmd_bytes = case_bytes;
            cmd_tag = case_tag;
            cmd_valid = 1'b1;
            @(negedge clk);
            cmd_valid = 1'b0;
        end
    endtask

    task wait_arvalid;
        integer timeout;
        begin
            timeout = 0;
            while (!m_axi_arvalid && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!m_axi_arvalid)
                $fatal(1, "ARVALID timeout");
        end
    endtask

    task wait_ar_count;
        input integer wanted;
        integer timeout;
        begin
            timeout = 0;
            while (case_ar_count < wanted && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (case_ar_count < wanted)
                $fatal(1, "AR handshake timeout got=%0d want=%0d",
                       case_ar_count, wanted);
        end
    endtask

    task wait_r_count;
        input integer wanted;
        integer timeout;
        begin
            timeout = 0;
            while (case_r_count < wanted && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (case_r_count < wanted)
                $fatal(1, "R handshake timeout got=%0d want=%0d",
                       case_r_count, wanted);
        end
    endtask

    task wait_data;
        integer timeout;
        begin
            timeout = 0;
            while (!data_valid && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!data_valid)
                $fatal(1, "data-valid timeout");
        end
    endtask

    task wait_drain;
        integer timeout;
        begin
            timeout = 0;
            while (!draining && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!draining)
                $fatal(1, "draining-state timeout");
        end
    endtask

    task wait_idle;
        integer timeout;
        begin
            timeout = 0;
            while ((!cmd_ready || busy || draining || model_active ||
                    m_axi_rvalid) && timeout < WATCHDOG_CYCLES) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!cmd_ready || busy || draining || model_active || m_axi_rvalid)
                $fatal(1, "idle timeout ready=%0d busy=%0d drain=%0d model=%0d rv=%0d",
                       cmd_ready, busy, draining, model_active, m_axi_rvalid);
        end
    endtask

    task wait_done;
        integer timeout;
        begin
            timeout = 0;
            while (done_pulses == 0 && error_pulses == 0 &&
                   abort_pulses == 0 && timeout < WATCHDOG_CYCLES) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (done_pulses == 0 && error_pulses == 0 && abort_pulses == 0)
                $fatal(1, "completion timeout length=%0d", case_bytes);
        end
    endtask

    task wait_error;
        input [7:0] wanted;
        integer timeout;
        begin
            timeout = 0;
            while (error_pulses == 0 && timeout < 1000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (error_pulses == 0)
                $fatal(1, "error timeout want=%02x", wanted);
            if (error_pulses != 1 || seen_error_code != wanted ||
                seen_error_tag != case_tag) begin
                $display("FAIL error got pulses=%0d code=%02x tag=%016x want=%02x/%016x",
                         error_pulses, seen_error_code, seen_error_tag,
                         wanted, case_tag);
                errors = errors + 1;
            end
        end
    endtask

    task wait_aborted;
        integer timeout;
        begin
            timeout = 0;
            while (abort_pulses == 0 && timeout < WATCHDOG_CYCLES) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (abort_pulses == 0)
                $fatal(1, "aborted timeout tag=%016x", case_tag);
            if (abort_pulses != 1 || seen_abort_tag != case_tag) begin
                $display("FAIL abort got pulses=%0d tag=%016x want=%016x",
                         abort_pulses, seen_abort_tag, case_tag);
                errors = errors + 1;
            end
        end
    endtask

    task finish_success_case;
        input integer expected_bursts;
        begin
            wait_done();
            if (done_pulses != 1 || error_pulses != 0 || abort_pulses != 0 ||
                seen_done_tag != case_tag ||
                case_output_bytes != case_bytes ||
                case_output_beats != case_total_beats ||
                case_scheduled_beats != case_total_beats ||
                case_ar_count != expected_bursts) begin
                $display("FAIL success len=%0d done=%0d err=%0d abort=%0d tag=%016x/%016x out=%0d/%0d beats=%0d/%0d scheduled=%0d bursts=%0d/%0d",
                         case_bytes, done_pulses, error_pulses, abort_pulses,
                         seen_done_tag, case_tag,
                         case_output_bytes, case_bytes,
                         case_output_beats, case_total_beats,
                         case_scheduled_beats, case_ar_count,
                         expected_bursts);
                errors = errors + 1;
            end
            wait_idle();
            case_active = 1'b0;
            case_expect_stream = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task run_success;
        input [ADDR_WIDTH-1:0] address;
        input integer length;
        input [TAG_WIDTH-1:0] tag;
        input integer use_gaps;
        input integer use_backpressure;
        input integer expected_bursts;
        begin
            configure_case(address, length, tag, 1'b1);
            m_axi_arready = 1'b1;
            slave_r_gaps = use_gaps;
            ready_mode = use_backpressure ? READY_PATTERN : READY_ALWAYS;
            issue_command();
            finish_success_case(expected_bursts);
            $display("PASS hp64 length=%0d bursts=%0d", length,
                     expected_bursts);
        end
    endtask

    task run_preflight_error;
        input [ADDR_WIDTH-1:0] address;
        input integer length;
        input [7:0] wanted;
        input [TAG_WIDTH-1:0] tag;
        begin
            configure_case(address, length, tag, 1'b0);
            m_axi_arready = 1'b1;
            issue_command();
            wait_error(wanted);
            repeat (2) @(negedge clk);
            if (case_ar_count != 0 || case_r_count != 0 || data_valid ||
                done_pulses != 0 || abort_pulses != 0 || !cmd_ready) begin
                $display("FAIL preflight fault leaked activity code=%02x ar=%0d r=%0d data=%0d done=%0d abort=%0d ready=%0d",
                         wanted, case_ar_count, case_r_count, data_valid,
                         done_pulses, abort_pulses, cmd_ready);
                errors = errors + 1;
            end
            case_active = 1'b0;
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

    task assert_no_stale_then_restart;
        input [TAG_WIDTH-1:0] restart_tag;
        begin
            case_active = 1'b0;
            case_expect_stream = 1'b0;
            repeat (3) begin
                @(negedge clk);
                if (data_valid || m_axi_arvalid || busy || draining) begin
                    $display("FAIL stale activity survived abort/fault");
                    errors = errors + 1;
                end
            end
            run_success(32'h0018_0000, 1, restart_tag, 0, 0, 1);
        end
    endtask

    initial begin
        integer timeout;
        integer stalls_before;
        integer read_beats_before;
        integer burst_count_before;
        reg [ADDR_WIDTH-1:0] poison_addr;
        reg [7:0] poison_len;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        m_axi_arready = 1'b1;
        ready_mode = READY_ALWAYS;

        // Required byte-count boundaries, including both partial and exact
        // page windows.  The 12-byte case begins eight bytes before a 4KiB
        // boundary and must split into two single-beat bursts.
        run_success(32'h0000_1000, 1, TAG_BASE + 1, 1, 1, 1);
        run_success(32'h0000_1100, 7, TAG_BASE + 7, 1, 1, 1);
        run_success(32'h0000_1200, 8, TAG_BASE + 8, 1, 1, 1);
        run_success(32'h0000_1300, 9, TAG_BASE + 9, 1, 1, 1);
        run_success(32'h0000_0ff8, 12, TAG_BASE + 12, 1, 1, 2);
        run_success(32'h0000_2000, 192, TAG_BASE + 192, 1, 1, 1);
        run_success(32'h0000_2200, 256, TAG_BASE + 256, 1, 1, 1);
        run_success(32'h0000_4000, 8204, TAG_BASE + 8204, 1, 1, 5);
        run_success(32'h0000_8000, 8208, TAG_BASE + 8208, 1, 1, 5);
        run_success(32'h0001_0000, 10252, TAG_BASE + 10252, 1, 1, 6);

        // Explicit long-to-short/tag replacement.  The long case also proves
        // the five full 256-beat bursts plus a two-beat tail.
        run_success(32'h0001_4000, 10256, TAG_LONG, 1, 1, 6);
        run_success(32'h0001_8000, 1, TAG_SHORT, 0, 0, 1);

        // The final physical address 0xffffffff is legal for eight bytes.
        run_success(32'hffff_fff8, 8, TAG_BASE + 64'hff, 0, 0, 1);

        // Alignment, zero/oversize length, and rounded physical wrap.
        run_preflight_error(32'h0000_1004, 8, ERR_ALIGN, TAG_FAULT + 1);
        run_preflight_error(32'h0000_1000, 0, ERR_LENGTH, TAG_FAULT + 2);
        run_preflight_error(32'h0000_1000, 10257,
                            ERR_LENGTH, TAG_FAULT + 3);
        run_preflight_error(32'hffff_fff8, 9,
                            ERR_ADDRESS_RANGE, TAG_FAULT + 4);

        // Abort in PREP, before ARVALID has ever been presented, is immediate
        // and owns no AXI transaction to drain.
        configure_case(32'h0001_9000, 192, TAG_FAULT + 8'h05, 1'b0);
        m_axi_arready = 1'b1;
        issue_command();
        if (m_axi_arvalid)
            $fatal(1, "PREP-abort setup missed the pre-AR phase");
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        wait_aborted();
        wait_idle();
        if (case_ar_count != 0 || case_r_count != 0 || done_pulses != 0 ||
            error_pulses != 0 || data_valid) begin
            $display("FAIL pre-AR abort leaked activity ar=%0d r=%0d done=%0d err=%0d data=%0d",
                     case_ar_count, case_r_count, done_pulses,
                     error_pulses, data_valid);
            errors = errors + 1;
        end
        assert_no_stale_then_restart(TAG_RESTART + 8'h05);

        // Counter ownership: clear, then force AR, R-wait, and output stalls.
        @(negedge clk);
        clear_counters = 1'b1;
        @(negedge clk);
        clear_counters = 1'b0;
        if (read_beats != 0 || burst_count != 0 || ar_stall_cycles != 0 ||
            r_wait_cycles != 0 || output_stall_cycles != 0) begin
            $display("FAIL counter clear did not zero every counter");
            errors = errors + 1;
        end
        configure_case(32'h0001_a000, 192, TAG_BASE + 64'hc0, 1'b1);
        m_axi_arready = 1'b0;
        slave_r_gaps = 1'b1;
        ready_mode = READY_NEVER;
        issue_command();
        wait_arvalid();
        repeat (3) @(negedge clk);
        m_axi_arready = 1'b1;
        wait_ar_count(1);
        wait_data();
        repeat (3) begin
            @(negedge clk);
            if (error_pulses != 0)
                $fatal(1, "output backpressure incorrectly caused timeout");
        end
        ready_mode = READY_PATTERN;
        finish_success_case(1);
        if (read_beats != 24 || burst_count != 1 ||
            ar_stall_cycles < 3 || r_wait_cycles == 0 ||
            output_stall_cycles < 3) begin
            $display("FAIL counters beats=%0d bursts=%0d arstall=%0d rwait=%0d outstall=%0d",
                     read_beats, burst_count, ar_stall_cycles,
                     r_wait_cycles, output_stall_cycles);
            errors = errors + 1;
        end

        // AR timeout before ARVALID is accepted: VALID and its payload remain
        // poisoned/stable.  READY later causes exactly one handshake and the
        // whole accepted burst is drained with no stream output or done.
        read_beats_before = read_beats;
        burst_count_before = burst_count;
        configure_case(32'h0001_c000, 192, TAG_FAULT + 8'h10, 1'b0);
        m_axi_arready = 1'b0;
        issue_command();
        wait_arvalid();
        poison_addr = m_axi_araddr;
        poison_len = m_axi_arlen;
        timeout = 0;
        while (error_pulses == 0 && timeout < 100) begin
            @(negedge clk);
            if (!m_axi_arvalid || m_axi_araddr != poison_addr ||
                m_axi_arlen != poison_len || cmd_ready) begin
                $display("FAIL timed-out AR was withdrawn/changed or ready rose");
                errors = errors + 1;
            end
            timeout = timeout + 1;
        end
        wait_error(ERR_AR_TIMEOUT);
        repeat (3) begin
            @(negedge clk);
            if (!m_axi_arvalid || m_axi_araddr != poison_addr ||
                m_axi_arlen != poison_len || cmd_ready)
                $fatal(1, "poisoned AR unstable after timeout");
        end
        m_axi_arready = 1'b1;
        wait_ar_count(1);
        wait_drain();
        wait_idle();
        if (case_ar_count != 1 || case_r_count != poison_len + 1 ||
            done_pulses != 0 || abort_pulses != 0 || data_valid ||
            error_pulses != 1 ||
            read_beats - read_beats_before != poison_len + 1 ||
            burst_count - burst_count_before != 1) begin
            $display("FAIL AR-timeout drain ar=%0d r=%0d/%0d done=%0d abort=%0d err=%0d data=%0d",
                     case_ar_count, case_r_count, poison_len + 1,
                     done_pulses, abort_pulses, error_pulses, data_valid);
            errors = errors + 1;
        end
        assert_no_stale_then_restart(TAG_RESTART + 8'h10);

        // Abort after a stalled ARVALID is visible.  AXI forbids withdrawal;
        // the abort is acknowledged only after eventual AR acceptance and
        // full RLAST drain.
        configure_case(32'h0001_e000, 192, TAG_FAULT + 8'h20, 1'b0);
        m_axi_arready = 1'b0;
        issue_command();
        wait_arvalid();
        poison_addr = m_axi_araddr;
        poison_len = m_axi_arlen;
        @(negedge clk);
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        repeat (3) begin
            @(negedge clk);
            if (!m_axi_arvalid || m_axi_araddr != poison_addr ||
                m_axi_arlen != poison_len || cmd_ready || abort_pulses != 0)
                $fatal(1, "aborted poisoned AR was withdrawn or acknowledged early");
        end
        m_axi_arready = 1'b1;
        wait_ar_count(1);
        wait_drain();
        // A second abort while already draining must not end ownership early.
        pulse_abort();
        wait_aborted();
        wait_idle();
        if (case_ar_count != 1 || case_r_count != poison_len + 1 ||
            done_pulses != 0 || error_pulses != 0 || data_valid) begin
            $display("FAIL poisoned-AR abort drain ar=%0d r=%0d/%0d done=%0d err=%0d data=%0d",
                     case_ar_count, case_r_count, poison_len + 1,
                     done_pulses, error_pulses, data_valid);
            errors = errors + 1;
        end
        assert_no_stale_then_restart(TAG_RESTART + 8'h20);

        // Same-cycle AR handshake and abort is accepted and drained.
        configure_case(32'h0002_0000, 192, TAG_FAULT + 8'h21, 1'b0);
        m_axi_arready = 1'b0;
        issue_command();
        wait_arvalid();
        @(negedge clk);
        m_axi_arready = 1'b1;
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        wait_ar_count(1);
        wait_drain();
        wait_aborted();
        wait_idle();
        if (done_pulses != 0 || error_pulses != 0 || data_valid) begin
            $display("FAIL same-cycle AR/abort exposed output/status");
            errors = errors + 1;
        end
        assert_no_stale_then_restart(TAG_RESTART + 8'h21);

        // R timeout after an accepted burst reports once, then remains in
        // drain until the slave eventually supplies RLAST.
        configure_case(32'h0002_2000, 192, TAG_FAULT + 8'h11, 1'b0);
        m_axi_arready = 1'b1;
        slave_r_enable = 1'b0;
        issue_command();
        wait_ar_count(1);
        wait_error(ERR_R_TIMEOUT);
        wait_drain();
        repeat (2) @(negedge clk);
        slave_r_enable = 1'b1;
        wait_idle();
        if (done_pulses != 0 || abort_pulses != 0 ||
            error_pulses != 1 || data_valid) begin
            $display("FAIL R-timeout drain done=%0d abort=%0d err=%0d data=%0d",
                     done_pulses, abort_pulses, error_pulses, data_valid);
            errors = errors + 1;
        end
        assert_no_stale_then_restart(TAG_RESTART + 8'h11);

        // Drain timeout is distinct.  Use a post-AR abort, hold R absent long
        // enough for 0x15, then close the physical transaction with RLAST.
        configure_case(32'h0002_4000, 192, TAG_FAULT + 8'h15, 1'b0);
        m_axi_arready = 1'b1;
        slave_r_enable = 1'b0;
        issue_command();
        wait_ar_count(1);
        pulse_abort();
        wait_drain();
        wait_error(ERR_DRAIN_TIMEOUT);
        slave_r_enable = 1'b1;
        wait_idle();
        if (done_pulses != 0 || abort_pulses != 0 || data_valid ||
            error_pulses != 1) begin
            $display("FAIL drain-timeout leaked completion/data");
            errors = errors + 1;
        end
        assert_no_stale_then_restart(TAG_RESTART + 8'h15);

        // RID mismatch and every non-OKAY RRESP encoding are tagged and
        // drained.  Fault injection occurs before RLAST.
        configure_case(32'h0002_6000, 192, TAG_FAULT + 8'h12, 1'b0);
        inject_kind = INJECT_RID;
        inject_beat = 1;
        m_axi_arready = 1'b1;
        issue_command();
        wait_error(ERR_RID);
        wait_idle();
        if (done_pulses != 0 || abort_pulses != 0 || data_valid)
            $fatal(1, "RID fault leaked completion/data");
        assert_no_stale_then_restart(TAG_RESTART + 8'h12);

        for (stalls_before = 1; stalls_before <= 3;
             stalls_before = stalls_before + 1) begin
            configure_case(32'h0002_8000 + stalls_before*32'h1000,
                           192, TAG_FAULT + 8'h30 + stalls_before, 1'b0);
            inject_kind = INJECT_RRESP;
            inject_beat = 1;
            inject_resp = stalls_before[1:0];
            m_axi_arready = 1'b1;
            issue_command();
            wait_error(ERR_RRESP);
            wait_idle();
            if (done_pulses != 0 || abort_pulses != 0 || data_valid)
                $fatal(1, "RRESP fault leaked completion/data resp=%0d",
                       stalls_before);
            assert_no_stale_then_restart(
                TAG_RESTART + 8'h30 + stalls_before);
        end

        // Early RLAST closes immediately; missing expected RLAST requires an
        // extra tail beat and drain before restart.
        configure_case(32'h0003_0000, 192, TAG_FAULT + 8'h14, 1'b0);
        inject_kind = INJECT_EARLY_RLAST;
        inject_beat = 1;
        m_axi_arready = 1'b1;
        issue_command();
        wait_error(ERR_RLAST);
        wait_idle();
        if (case_r_count != 2 || done_pulses != 0 || data_valid) begin
            $display("FAIL early RLAST termination r=%0d", case_r_count);
            errors = errors + 1;
        end
        assert_no_stale_then_restart(TAG_RESTART + 8'h40);

        configure_case(32'h0003_2000, 192, TAG_FAULT + 8'h15, 1'b0);
        inject_kind = INJECT_MISSING_RLAST;
        m_axi_arready = 1'b1;
        issue_command();
        wait_error(ERR_RLAST);
        wait_idle();
        if (case_r_count != 25 || done_pulses != 0 || data_valid) begin
            $display("FAIL missing RLAST drain r=%0d want=25", case_r_count);
            errors = errors + 1;
        end
        assert_no_stale_then_restart(TAG_RESTART + 8'h41);

        // Abort while waiting for R, in the middle of R, and while an output
        // beat is backpressured.  Each accepted burst drains through RLAST.
        configure_case(32'h0003_4000, 192, TAG_FAULT + 8'h50, 1'b0);
        m_axi_arready = 1'b1;
        slave_r_enable = 1'b0;
        issue_command();
        wait_ar_count(1);
        pulse_abort();
        wait_drain();
        slave_r_enable = 1'b1;
        wait_aborted();
        wait_idle();
        assert_no_stale_then_restart(TAG_RESTART + 8'h50);

        configure_case(32'h0003_6000, 192, TAG_FAULT + 8'h51, 1'b0);
        m_axi_arready = 1'b1;
        issue_command();
        wait_r_count(3);
        pulse_abort();
        wait_drain();
        wait_aborted();
        wait_idle();
        assert_no_stale_then_restart(TAG_RESTART + 8'h51);

        configure_case(32'h0003_8000, 192, TAG_FAULT + 8'h52, 1'b0);
        m_axi_arready = 1'b1;
        ready_mode = READY_NEVER;
        issue_command();
        wait_data();
        repeat (2) @(negedge clk);
        pulse_abort();
        wait_drain();
        wait_aborted();
        wait_idle();
        if (data_valid || done_pulses != 0)
            $fatal(1, "backpressured abort exposed stale data/done");
        assert_no_stale_then_restart(TAG_RESTART + 8'h52);

        // A registered tentative beat may be accepted on the same edge as
        // abort.  It remains uncommitted: validate the beat, drain the owned
        // burst, require abort (never done), then prove a clean restart.
        configure_case(32'h0003_9000, 192, TAG_FAULT + 8'h54, 1'b0);
        m_axi_arready = 1'b1;
        ready_mode = READY_NEVER;
        issue_command();
        wait_data();
        // Release the held beat and assert abort together after the negedge
        // READY driver has settled, guaranteeing coincidence at the next
        // rising edge rather than merely adjacent cycles.
        #1;
        data_ready = 1'b1;
        abort = 1'b1;
        @(negedge clk);
        abort = 1'b0;
        wait_drain();
        wait_aborted();
        wait_idle();
        if (abort_data_handshakes != 1 || case_output_beats != 1 ||
            done_pulses != 0 ||
            error_pulses != 0 || data_valid) begin
            $display("FAIL coincident output/abort handshakes=%0d tentative=%0d done=%0d err=%0d data=%0d",
                     abort_data_handshakes, case_output_beats, done_pulses,
                     error_pulses, data_valid);
            errors = errors + 1;
        end
        assert_no_stale_then_restart(TAG_RESTART + 8'h54);

        // Once final RLAST has been accepted, aborting the blocked final
        // output needs no drain and must not produce done.
        configure_case(32'h0003_a000, 1, TAG_FAULT + 8'h53, 1'b0);
        m_axi_arready = 1'b1;
        ready_mode = READY_NEVER;
        issue_command();
        wait_data();
        timeout = 0;
        while (model_active && timeout < 100) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (model_active)
            $fatal(1, "final RLAST was not accepted before output abort");
        pulse_abort();
        wait_aborted();
        wait_idle();
        if (draining || data_valid || done_pulses != 0)
            $fatal(1, "post-RLAST output abort drained or completed");
        assert_no_stale_then_restart(TAG_RESTART + 8'h53);

        // Reset is the defined escape if a poisoned AR can never handshake.
        configure_case(32'h0003_c000, 192, TAG_FAULT + 8'h60, 1'b0);
        m_axi_arready = 1'b0;
        issue_command();
        wait_arvalid();
        pulse_abort();
        repeat (2) @(negedge clk);
        if (!m_axi_arvalid || cmd_ready || abort_pulses != 0)
            $fatal(1, "poisoned AR did not remain owned before reset");
        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        m_axi_arready = 1'b1;
        @(negedge clk);
        if (!cmd_ready || busy || draining || m_axi_arvalid || data_valid)
            $fatal(1, "reset did not clear poisoned AR ownership");
        case_active = 1'b0;
        run_success(32'h0003_e000, 1, TAG_RESTART + 8'h60, 0, 0, 1);

        if (errors == 0) begin
            $display("TB PASS: HP64 range reader boundaries/splits/faults/abort");
            $finish;
        end
        $fatal(1, "TB FAIL: HP64 range reader errors=%0d", errors);
    end
endmodule

`default_nettype wire
