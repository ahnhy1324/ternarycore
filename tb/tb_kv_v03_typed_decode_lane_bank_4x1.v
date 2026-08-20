// tb_kv_v03_typed_decode_lane_bank_4x1.v
// Focused acceptance for capture overlap, ordered retirement, canonical P16
// reads, typed fail-closed abort, and no-reset short restart.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

`ifndef SCALE_BITS_VAL
`define SCALE_BITS_VAL 12
`endif

module tb_kv_v03_typed_decode_lane_bank_4x1;
    localparam integer SCALE_BITS = `SCALE_BITS_VAL;
    localparam [15:0] PROFILE_ID = 16'h1234;
    localparam [7:0] K_CODEBOOK_ID = 8'h4b;
    localparam [7:0] V_CODEBOOK_ID = 8'h56;

    localparam [7:0] ERR_DESCRIPTOR = 8'h01;
    localparam [7:0] ERR_PROFILE    = 8'h02;
    localparam [7:0] ERR_CODEBOOK   = 8'h03;
    localparam [7:0] ERR_STREAM     = 8'h04;
    localparam [7:0] ERR_DECODER    = 8'h07;
    localparam [7:0] ERR_ABORT      = 8'h09;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg page_valid = 1'b0;
    wire page_ready;
    reg [63:0] page_task_tag = 64'd0;
    reg [15:0] page_epoch = 16'd0;
    reg [4:0] page_index = 5'd0;
    reg page_stream_is_v = 1'b0;
    reg page_expected_stream_is_v = 1'b0;
    reg page_raw_mode = 1'b0;
    reg [15:0] page_payload_bytes = 16'd0;
    reg [14:0] page_expected_symbols = 15'd0;
    reg [7:0] page_token_count = 8'd0;
    reg [8:0] page_scale_slice_bytes = 9'd0;
    wire source_release;

    wire data_rd_en;
    wire [11:0] data_rd_word_addr;
    reg data_rd_valid = 1'b0;
    reg [31:0] data_rd_data = 32'd0;
    reg [3:0] data_rd_byte_valid = 4'd0;
    reg data_rd_last = 1'b0;
    reg [13:0] data_rd_byte_offset = 14'd0;
    wire scale_rd_en;
    wire [6:0] scale_rd_word_addr;
    reg scale_rd_valid = 1'b0;
    reg [31:0] scale_rd_data = 32'd0;
    reg [3:0] scale_rd_byte_valid = 4'd0;
    reg scale_rd_last = 1'b0;
    reg [8:0] scale_rd_byte_offset = 9'd0;

    reg abort_valid = 1'b0;
    reg [63:0] abort_task_tag = 64'd0;
    reg [15:0] abort_epoch = 16'd0;
    reg [4:0] abort_page_index = 5'd0;
    reg abort_stream_is_v = 1'b0;
    reg clear_fault = 1'b0;
    wire clear_ready;

    wire publish_valid;
    reg publish_ready = 1'b0;
    wire page_active;
    reg page_release = 1'b0;
    wire [63:0] published_task_tag;
    wire [15:0] published_epoch;
    wire [4:0] published_page_index;
    wire published_stream_is_v;
    wire published_raw_mode;
    wire [15:0] published_payload_bytes;
    wire [14:0] published_expected_symbols;
    wire [7:0] published_token_count;
    wire [8:0] published_scale_slice_bytes;

    reg p16_rd_en = 1'b0;
    reg [9:0] p16_rd_addr = 10'd0;
    wire p16_rd_valid;
    wire [79:0] p16_rd_codes;
    reg token_scale_rd_en = 1'b0;
    reg [6:0] token_scale_rd_addr = 7'd0;
    wire token_scale_rd_valid;
    wire [SCALE_BITS-1:0] token_scale_rd_data;

    wire busy, draining;
    wire [3:0] lane_occupied, lane_decode_busy, lane_complete;
    wire sticky_error;
    wire [7:0] sticky_error_code, sticky_error_subcode;
    wire [63:0] sticky_task_tag;
    wire [15:0] sticky_epoch;
    wire [4:0] sticky_page_index;
    wire sticky_stream_is_v;
    wire row_abort;

    kv_v03_typed_decode_lane_bank_4x1 #(
        .SCALE_BITS(SCALE_BITS),
        .COMPILED_PROFILE_ID(PROFILE_ID),
        .COMPILED_K_CODEBOOK_ID(K_CODEBOOK_ID),
        .COMPILED_V_CODEBOOK_ID(V_CODEBOOK_ID)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .page_valid(page_valid), .page_ready(page_ready),
        .page_task_tag(page_task_tag), .page_epoch(page_epoch),
        .page_index(page_index), .page_stream_is_v(page_stream_is_v),
        .page_expected_stream_is_v(page_expected_stream_is_v),
        .page_raw_mode(page_raw_mode),
        .page_payload_bytes(page_payload_bytes),
        .page_expected_symbols(page_expected_symbols),
        .page_token_count(page_token_count),
        .page_scale_slice_bytes(page_scale_slice_bytes),
        .source_release(source_release),
        .data_rd_en(data_rd_en),
        .data_rd_word_addr(data_rd_word_addr),
        .data_rd_valid(data_rd_valid), .data_rd_data(data_rd_data),
        .data_rd_byte_valid(data_rd_byte_valid),
        .data_rd_last(data_rd_last),
        .data_rd_byte_offset(data_rd_byte_offset),
        .scale_rd_en(scale_rd_en),
        .scale_rd_word_addr(scale_rd_word_addr),
        .scale_rd_valid(scale_rd_valid), .scale_rd_data(scale_rd_data),
        .scale_rd_byte_valid(scale_rd_byte_valid),
        .scale_rd_last(scale_rd_last),
        .scale_rd_byte_offset(scale_rd_byte_offset),
        .abort_valid(abort_valid), .abort_task_tag(abort_task_tag),
        .abort_epoch(abort_epoch),
        .abort_page_index(abort_page_index),
        .abort_stream_is_v(abort_stream_is_v),
        .clear_fault(clear_fault), .clear_ready(clear_ready),
        .publish_valid(publish_valid), .publish_ready(publish_ready),
        .page_active(page_active), .page_release(page_release),
        .published_task_tag(published_task_tag),
        .published_epoch(published_epoch),
        .published_page_index(published_page_index),
        .published_stream_is_v(published_stream_is_v),
        .published_raw_mode(published_raw_mode),
        .published_payload_bytes(published_payload_bytes),
        .published_expected_symbols(published_expected_symbols),
        .published_token_count(published_token_count),
        .published_scale_slice_bytes(published_scale_slice_bytes),
        .p16_rd_en(p16_rd_en), .p16_rd_addr(p16_rd_addr),
        .p16_rd_valid(p16_rd_valid), .p16_rd_codes(p16_rd_codes),
        .token_scale_rd_en(token_scale_rd_en),
        .token_scale_rd_addr(token_scale_rd_addr),
        .token_scale_rd_valid(token_scale_rd_valid),
        .token_scale_rd_data(token_scale_rd_data),
        .busy(busy), .draining(draining),
        .lane_occupied(lane_occupied),
        .lane_decode_busy(lane_decode_busy),
        .lane_complete(lane_complete),
        .sticky_error(sticky_error),
        .sticky_error_code(sticky_error_code),
        .sticky_error_subcode(sticky_error_subcode),
        .sticky_task_tag(sticky_task_tag),
        .sticky_epoch(sticky_epoch),
        .sticky_page_index(sticky_page_index),
        .sticky_stream_is_v(sticky_stream_is_v),
        .row_abort(row_abort)
    );

    reg [7:0] source_payload [0:10239];
    reg [7:0] source_scale [0:255];
    integer source_payload_len = 0;
    integer source_scale_len = 0;
    reg data_pending = 1'b0;
    reg [11:0] data_pending_addr = 12'd0;
    reg scale_pending = 1'b0;
    reg [6:0] scale_pending_addr = 7'd0;
    reg hold_data_response = 1'b0;
    reg hold_scale_response = 1'b0;
    integer source_errors = 0;

    integer payload_base;
    integer payload_left;
    integer scale_base;
    integer scale_left;
    always @(posedge clk) begin
        if (!rst_n) begin
            data_rd_valid <= 1'b0;
            data_pending <= 1'b0;
            scale_rd_valid <= 1'b0;
            scale_pending <= 1'b0;
        end else begin
            data_rd_valid <= 1'b0;
            scale_rd_valid <= 1'b0;

            if (data_rd_en) begin
                if (data_pending) begin
                    $display("FAIL source overlapping data request");
                    source_errors = source_errors + 1;
                end else begin
                    data_pending <= 1'b1;
                    data_pending_addr <= data_rd_word_addr;
                end
            end
            if (scale_rd_en) begin
                if (scale_pending) begin
                    $display("FAIL source overlapping scale request");
                    source_errors = source_errors + 1;
                end else begin
                    scale_pending <= 1'b1;
                    scale_pending_addr <= scale_rd_word_addr;
                end
            end

            if (data_pending && !hold_data_response) begin
                payload_base = (data_pending_addr - 3) * 4;
                payload_left = source_payload_len - payload_base;
                data_rd_valid <= 1'b1;
                data_rd_data <= {
                    (payload_left > 3) ? source_payload[payload_base+3] : 8'd0,
                    (payload_left > 2) ? source_payload[payload_base+2] : 8'd0,
                    (payload_left > 1) ? source_payload[payload_base+1] : 8'd0,
                    (payload_left > 0) ? source_payload[payload_base] : 8'd0};
                data_rd_byte_valid <=
                    (payload_left >= 4) ? 4'hf :
                    (payload_left == 3) ? 4'h7 :
                    (payload_left == 2) ? 4'h3 : 4'h1;
                data_rd_last <= payload_left <= 4;
                data_rd_byte_offset <= {data_pending_addr, 2'b00};
                data_pending <= 1'b0;
            end

            if (scale_pending && !hold_scale_response) begin
                scale_base = scale_pending_addr * 4;
                scale_left = source_scale_len - scale_base;
                scale_rd_valid <= 1'b1;
                scale_rd_data <= {
                    (scale_left > 3) ? source_scale[scale_base+3] : 8'd0,
                    (scale_left > 2) ? source_scale[scale_base+2] : 8'd0,
                    (scale_left > 1) ? source_scale[scale_base+1] : 8'd0,
                    (scale_left > 0) ? source_scale[scale_base] : 8'd0};
                scale_rd_byte_valid <=
                    (scale_left >= 4) ? 4'hf :
                    (scale_left == 3) ? 4'h7 :
                    (scale_left == 2) ? 4'h3 : 4'h1;
                scale_rd_last <= scale_left <= 4;
                scale_rd_byte_offset <= {scale_pending_addr, 2'b00};
                scale_pending <= 1'b0;
            end
        end
    end

    integer errors = 0;
    integer abort_pulses = 0;
    integer complete_count = 0;
    integer complete_order [0:15];
    reg record_completions = 1'b0;
    integer monitor_lane;
    always @(posedge clk) begin
        if (row_abort)
            abort_pulses = abort_pulses + 1;
        if (record_completions) begin
            for (monitor_lane = 0; monitor_lane < 4;
                 monitor_lane = monitor_lane + 1) begin
                if (lane_complete[monitor_lane]) begin
                    complete_order[complete_count] = monitor_lane;
                    complete_count = complete_count + 1;
                end
            end
        end
        if ((sticky_error || abort_valid) &&
            (publish_valid || page_active || p16_rd_valid ||
             token_scale_rd_valid)) begin
            $display("FAIL fail-closed visibility");
            errors = errors + 1;
        end
    end

    function [63:0] make_tag;
        input [15:0] layer;
        input [15:0] head;
        input [15:0] profile;
        input [7:0] codebook;
        input [7:0] request_id;
        begin
            make_tag = {layer, head, profile, codebook, request_id};
        end
    endfunction

    function [SCALE_BITS-1:0] expected_scale;
        input integer token;
        integer mask;
        begin
            mask = (1 << SCALE_BITS) - 1;
            expected_scale = (16'h0123 + token * 16'h0011) & mask;
        end
    endfunction

    integer k;
    integer bit_position;
    integer bit_index;
    integer symbol_index;
    integer scale_value;
    task clear_source_images;
        begin
            for (k = 0; k < 10240; k = k + 1)
                source_payload[k] = 8'd0;
            for (k = 0; k < 256; k = k + 1)
                source_scale[k] = 8'd0;
            source_payload_len = 0;
            source_scale_len = 0;
        end
    endtask

    task build_scales;
        input integer tokens;
        begin
            source_scale_len = (tokens * SCALE_BITS + 7) / 8;
            for (k = 0; k < source_scale_len; k = k + 1)
                source_scale[k] = 8'd0;
            for (symbol_index = 0; symbol_index < tokens;
                 symbol_index = symbol_index + 1) begin
                scale_value = 16'h0123 + symbol_index * 16'h0011;
                for (bit_index = 0; bit_index < SCALE_BITS;
                     bit_index = bit_index + 1) begin
                    bit_position = symbol_index * SCALE_BITS + bit_index;
                    if ((scale_value >> bit_index) & 1)
                        source_scale[bit_position >> 3] =
                            source_scale[bit_position >> 3] |
                            (1 << (bit_position & 7));
                end
            end
        end
    endtask

    task build_k_zero;
        input integer tokens;
        input integer raw_page;
        begin
            clear_source_images();
            source_payload_len = tokens * (raw_page ? 64 : 32);
            build_scales(tokens);
        end
    endtask

    task build_v_five;
        input integer tokens;
        input integer raw_page;
        integer value;
        begin
            clear_source_images();
            source_payload_len = tokens * (raw_page ? 80 : 64);
            if (raw_page) begin
                value = 5;
                for (symbol_index = 0; symbol_index < tokens * 128;
                     symbol_index = symbol_index + 1) begin
                    for (bit_index = 0; bit_index < 5;
                         bit_index = bit_index + 1) begin
                        bit_position = symbol_index * 5 + bit_index;
                        if ((value >> bit_index) & 1)
                            source_payload[bit_position >> 3] =
                                source_payload[bit_position >> 3] |
                                (1 << (bit_position & 7));
                    end
                end
            end
            build_scales(tokens);
        end
    endtask

    task drive_descriptor;
        input [63:0] tag;
        input [15:0] epoch;
        input [4:0] index;
        input actual_stream;
        input expected_stream;
        input raw_page;
        input integer tokens;
        input integer payload_bytes;
        integer timeout;
        begin
            timeout = 0;
            while (!page_ready && timeout < 200000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!page_ready) begin
                $fatal(1, "descriptor ready timeout tag=%016x", tag);
            end
            @(negedge clk);
            page_task_tag = tag;
            page_epoch = epoch;
            page_index = index;
            page_stream_is_v = actual_stream;
            page_expected_stream_is_v = expected_stream;
            page_raw_mode = raw_page;
            page_payload_bytes = payload_bytes;
            page_expected_symbols = tokens * 128;
            page_token_count = tokens;
            page_scale_slice_bytes = (tokens * SCALE_BITS + 7) / 8;
            page_valid = 1'b1;
            @(posedge clk);
            if (!page_ready)
                $fatal(1, "descriptor lost ready tag=%016x", tag);
            @(negedge clk);
            page_valid = 1'b0;
        end
    endtask

    task issue_page_and_wait_copy;
        input [63:0] tag;
        input [15:0] epoch;
        input [4:0] index;
        input actual_stream;
        input expected_stream;
        input raw_page;
        input integer tokens;
        input integer payload_bytes;
        integer timeout;
        begin
            drive_descriptor(tag, epoch, index, actual_stream,
                             expected_stream, raw_page, tokens,
                             payload_bytes);
            timeout = 0;
            while (!source_release && timeout < 200000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!source_release)
                $fatal(1, "source release timeout tag=%016x", tag);
            @(posedge clk);
        end
    endtask

    task wait_publish;
        input [63:0] tag;
        input [15:0] epoch;
        input [4:0] index;
        input stream_is_v;
        input raw_page;
        input integer tokens;
        integer timeout;
        begin
            timeout = 0;
            while (!publish_valid && !sticky_error && timeout < 300000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!publish_valid) begin
                $fatal(1, "publish timeout tag=%016x code=%02x/%02x",
                       tag, sticky_error_code, sticky_error_subcode);
            end
            if (published_task_tag != tag ||
                published_epoch != epoch ||
                published_page_index != index ||
                published_stream_is_v != stream_is_v ||
                published_raw_mode != raw_page ||
                published_payload_bytes != source_payload_len ||
                published_expected_symbols != tokens * 128 ||
                published_token_count != tokens ||
                published_scale_slice_bytes != source_scale_len) begin
                $display("FAIL published metadata tag=%016x got=%016x",
                         tag, published_task_tag);
                errors = errors + 1;
            end
        end
    endtask

    task accept_publish;
        begin
            @(negedge clk);
            publish_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            publish_ready = 1'b0;
            if (!page_active) begin
                $display("FAIL accepted page not active");
                errors = errors + 1;
            end
        end
    endtask

    task read_p16;
        input integer address;
        output [79:0] value;
        begin
            @(negedge clk);
            p16_rd_addr = address;
            p16_rd_en = 1'b1;
            @(posedge clk);
            #1;
            value = p16_rd_codes;
            if (!p16_rd_valid) begin
                $display("FAIL P16 read addr=%0d not valid", address);
                errors = errors + 1;
            end
            @(negedge clk);
            p16_rd_en = 1'b0;
        end
    endtask

    task read_scale;
        input integer address;
        output [SCALE_BITS-1:0] value;
        begin
            @(negedge clk);
            token_scale_rd_addr = address;
            token_scale_rd_en = 1'b1;
            @(posedge clk);
            #1;
            value = token_scale_rd_data;
            if (!token_scale_rd_valid) begin
                $display("FAIL scale read addr=%0d not valid", address);
                errors = errors + 1;
            end
            @(negedge clk);
            token_scale_rd_en = 1'b0;
        end
    endtask

    task verify_invalid_reads;
        input integer p16_address;
        input integer scale_address;
        begin
            @(negedge clk);
            p16_rd_addr = p16_address;
            token_scale_rd_addr = scale_address;
            p16_rd_en = 1'b1;
            token_scale_rd_en = 1'b1;
            @(posedge clk);
            #1;
            if (p16_rd_valid || token_scale_rd_valid) begin
                $display("FAIL stale/out-of-range read p16=%0d scale=%0d",
                         p16_address, scale_address);
                errors = errors + 1;
            end
            @(negedge clk);
            p16_rd_en = 1'b0;
            token_scale_rd_en = 1'b0;
        end
    endtask

    task release_published_page;
        begin
            @(negedge clk);
            page_release = 1'b1;
            @(posedge clk);
            @(negedge clk);
            page_release = 1'b0;
            // A later completed lane may immediately become publish_valid;
            // only the released owner's active/read visibility must vanish.
            if (page_active || p16_rd_valid || token_scale_rd_valid) begin
                $display("FAIL release did not hide page");
                errors = errors + 1;
            end
        end
    endtask

    task wait_fault;
        input [7:0] code;
        input [63:0] tag;
        input [15:0] epoch;
        input [4:0] index;
        input stream_is_v;
        input integer abort_before;
        integer timeout;
        begin
            timeout = 0;
            while (!sticky_error && timeout < 300000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!sticky_error)
                $fatal(1, "fault timeout code=%02x tag=%016x", code, tag);
            // row_abort is registered with the sticky fields; allow the
            // monitor one edge to count that one-cycle notification.
            @(posedge clk);
            #1;
            if (sticky_error_code != code ||
                sticky_task_tag != tag || sticky_epoch != epoch ||
                sticky_page_index != index ||
                sticky_stream_is_v != stream_is_v ||
                abort_pulses != abort_before + 1) begin
                $display("FAIL typed fault got code/tag/epoch/page/stream/aborts=%02x/%016x/%04x/%0d/%0d/%0d want=%02x/%016x/%04x/%0d/%0d/%0d",
                         sticky_error_code, sticky_task_tag, sticky_epoch,
                         sticky_page_index, sticky_stream_is_v,
                         abort_pulses, code, tag, epoch, index,
                         stream_is_v, abort_before+1);
                errors = errors + 1;
            end
            if (publish_valid || page_active)
                errors = errors + 1;
        end
    endtask

    task clear_sticky_fault;
        integer timeout;
        begin
            timeout = 0;
            while (!clear_ready && timeout < 200000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!clear_ready)
                $fatal(1, "clear boundary timeout drain=%0d busy=%0d",
                       draining, busy);
            @(negedge clk);
            clear_fault = 1'b1;
            @(posedge clk);
            @(negedge clk);
            clear_fault = 1'b0;
            @(posedge clk);
            if (sticky_error || !page_ready) begin
                $display("FAIL clear/restart boundary sticky=%0d ready=%0d",
                         sticky_error, page_ready);
                errors = errors + 1;
            end
        end
    endtask

    reg [79:0] read_value;
    reg [79:0] reference_codes [0:7];
    reg [SCALE_BITS-1:0] read_scale_value;
    reg [SCALE_BITS-1:0] reference_scale;
    integer beat;
    task verify_constant_page;
        input integer wanted_symbol;
        input integer tokens;
        reg [4:0] got_symbol;
        integer s;
        begin
            for (beat = 0; beat < tokens * 8; beat = beat + 1) begin
                read_p16(beat, read_value);
                for (s = 0; s < 16; s = s + 1) begin
                    got_symbol = read_value[(s*5) +: 5];
                    if ($signed(got_symbol) != wanted_symbol) begin
                        $display("FAIL code beat=%0d lane=%0d got=%0d want=%0d",
                                 beat, s, $signed(got_symbol),
                                 wanted_symbol);
                        errors = errors + 1;
                    end
                end
            end
            for (beat = 0; beat < tokens; beat = beat + 1) begin
                read_scale(beat, read_scale_value);
                if (read_scale_value != expected_scale(beat)) begin
                    $display("FAIL scale token=%0d got=%x want=%x",
                             beat, read_scale_value,
                             expected_scale(beat));
                    errors = errors + 1;
                end
            end
        end
    endtask

    task run_short_good;
        input [63:0] tag;
        input [15:0] epoch;
        input [4:0] index;
        begin
            build_k_zero(1, 0);
            issue_page_and_wait_copy(tag, epoch, index, 0, 0, 0, 1,
                                     source_payload_len);
            wait_publish(tag, epoch, index, 0, 0, 1);
            accept_publish();
            verify_constant_page(0, 1);
            verify_invalid_reads(8, 1);
            release_published_page();
            verify_invalid_reads(0, 0);
        end
    endtask

    reg [63:0] order_tags [0:3];
    integer abort_before;
    integer timeout;
    integer prior_complete_count;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // 1. Four pages are captured in issue order while their independent
        // decoders deliberately finish in reverse lane order.
        $display("PHASE ordered_four_lane scale=%0d", SCALE_BITS);
        order_tags[0] = make_tag(16'h0010, 16'h0020, PROFILE_ID,
                                 K_CODEBOOK_ID, 8'h10);
        order_tags[1] = make_tag(16'h0010, 16'h0020, PROFILE_ID,
                                 K_CODEBOOK_ID, 8'h11);
        order_tags[2] = make_tag(16'h0010, 16'h0020, PROFILE_ID,
                                 K_CODEBOOK_ID, 8'h12);
        order_tags[3] = make_tag(16'h0010, 16'h0020, PROFILE_ID,
                                 K_CODEBOOK_ID, 8'h13);
        complete_count = 0;
        record_completions = 1'b1;

        build_k_zero(8, 0);
        issue_page_and_wait_copy(order_tags[0], 16'h0100, 5'd0,
                                 0, 0, 0, 8, source_payload_len);
        build_k_zero(4, 0);
        issue_page_and_wait_copy(order_tags[1], 16'h0100, 5'd1,
                                 0, 0, 0, 4, source_payload_len);
        build_k_zero(2, 0);
        issue_page_and_wait_copy(order_tags[2], 16'h0100, 5'd2,
                                 0, 0, 0, 2, source_payload_len);
        build_k_zero(1, 0);
        issue_page_and_wait_copy(order_tags[3], 16'h0100, 5'd3,
                                 0, 0, 0, 1, source_payload_len);

        timeout = 0;
        while (complete_count < 4 && timeout < 300000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        record_completions = 1'b0;
        if (complete_count != 4 ||
            complete_order[0] != 3 || complete_order[1] != 2 ||
            complete_order[2] != 1 || complete_order[3] != 0) begin
            $display("FAIL lane completion order count=%0d order=%0d,%0d,%0d,%0d",
                     complete_count, complete_order[0], complete_order[1],
                     complete_order[2], complete_order[3]);
            errors = errors + 1;
        end
        if (lane_occupied != 4'hf) begin
            $display("FAIL four-lane occupancy=%b", lane_occupied);
            errors = errors + 1;
        end

        build_k_zero(8, 0);
        wait_publish(order_tags[0], 16'h0100, 5'd0, 0, 0, 8);
        accept_publish();
        verify_constant_page(0, 8);
        release_published_page();
        build_k_zero(4, 0);
        wait_publish(order_tags[1], 16'h0100, 5'd1, 0, 0, 4);
        accept_publish();
        verify_constant_page(0, 4);
        release_published_page();
        build_k_zero(2, 0);
        wait_publish(order_tags[2], 16'h0100, 5'd2, 0, 0, 2);
        accept_publish();
        verify_constant_page(0, 2);
        release_published_page();
        build_k_zero(1, 0);
        wait_publish(order_tags[3], 16'h0100, 5'd3, 0, 0, 1);
        accept_publish();
        verify_constant_page(0, 1);
        release_published_page();

        // 3. Raw and compressed K pages expose exactly the same P16 beats and
        // scales.  Repeat independently for V.
        $display("PHASE raw_compressed_equivalence scale=%0d", SCALE_BITS);
        build_k_zero(1, 0);
        issue_page_and_wait_copy(
            make_tag(1, 2, PROFILE_ID, K_CODEBOOK_ID, 8'h20),
            16'h0200, 5'd4, 0, 0, 0, 1, source_payload_len);
        wait_publish(make_tag(1, 2, PROFILE_ID, K_CODEBOOK_ID, 8'h20),
                     16'h0200, 5'd4, 0, 0, 1);
        accept_publish();
        for (beat = 0; beat < 8; beat = beat + 1)
            read_p16(beat, reference_codes[beat]);
        read_scale(0, reference_scale);
        release_published_page();

        build_k_zero(1, 1);
        issue_page_and_wait_copy(
            make_tag(1, 2, PROFILE_ID, K_CODEBOOK_ID, 8'h21),
            16'h0201, 5'd5, 0, 0, 1, 1, source_payload_len);
        wait_publish(make_tag(1, 2, PROFILE_ID, K_CODEBOOK_ID, 8'h21),
                     16'h0201, 5'd5, 0, 1, 1);
        accept_publish();
        for (beat = 0; beat < 8; beat = beat + 1) begin
            read_p16(beat, read_value);
            if (read_value !== reference_codes[beat]) begin
                $display("FAIL compressed/raw K beat=%0d", beat);
                errors = errors + 1;
            end
        end
        read_scale(0, read_scale_value);
        if (read_scale_value !== reference_scale)
            errors = errors + 1;
        release_published_page();

        build_v_five(1, 0);
        issue_page_and_wait_copy(
            make_tag(1, 3, PROFILE_ID, V_CODEBOOK_ID, 8'h22),
            16'h0202, 5'd6, 1, 1, 0, 1, source_payload_len);
        wait_publish(make_tag(1, 3, PROFILE_ID, V_CODEBOOK_ID, 8'h22),
                     16'h0202, 5'd6, 1, 0, 1);
        accept_publish();
        verify_constant_page(5, 1);
        for (beat = 0; beat < 8; beat = beat + 1)
            read_p16(beat, reference_codes[beat]);
        read_scale(0, reference_scale);
        release_published_page();

        build_v_five(1, 1);
        issue_page_and_wait_copy(
            make_tag(1, 3, PROFILE_ID, V_CODEBOOK_ID, 8'h23),
            16'h0203, 5'd7, 1, 1, 1, 1, source_payload_len);
        wait_publish(make_tag(1, 3, PROFILE_ID, V_CODEBOOK_ID, 8'h23),
                     16'h0203, 5'd7, 1, 1, 1);
        accept_publish();
        for (beat = 0; beat < 8; beat = beat + 1) begin
            read_p16(beat, read_value);
            if (read_value !== reference_codes[beat]) begin
                $display("FAIL compressed/raw V beat=%0d", beat);
                errors = errors + 1;
            end
        end
        read_scale(0, read_scale_value);
        if (read_scale_value !== reference_scale)
            errors = errors + 1;
        release_published_page();

        // Exercise the physical page128 bounds as well as the compact
        // one-token equivalence cases above.  SCALE12 uses maximum raw K4;
        // SCALE16 uses maximum raw V5 (the largest legal payload).
        $display("PHASE page128_bounds scale=%0d", SCALE_BITS);
        if (SCALE_BITS == 12) begin
            build_k_zero(128, 1);
            issue_page_and_wait_copy(
                make_tag(1, 4, PROFILE_ID, K_CODEBOOK_ID, 8'h24),
                16'h0204, 5'd20, 0, 0, 1, 128, source_payload_len);
            wait_publish(
                make_tag(1, 4, PROFILE_ID, K_CODEBOOK_ID, 8'h24),
                16'h0204, 5'd20, 0, 1, 128);
            accept_publish();
            verify_constant_page(0, 128);
            release_published_page();
        end else begin
            build_v_five(128, 1);
            issue_page_and_wait_copy(
                make_tag(1, 4, PROFILE_ID, V_CODEBOOK_ID, 8'h24),
                16'h0204, 5'd20, 1, 1, 1, 128, source_payload_len);
            wait_publish(
                make_tag(1, 4, PROFILE_ID, V_CODEBOOK_ID, 8'h24),
                16'h0204, 5'd20, 1, 1, 128);
            accept_publish();
            verify_constant_page(5, 128);
            release_published_page();
        end

        // 5/6. Abort after tentative P16 writes, clear without reset, then
        // prove a short page cannot expose the preceding long page.
        $display("PHASE partial_decode_abort_restart scale=%0d", SCALE_BITS);
        build_k_zero(8, 0);
        issue_page_and_wait_copy(
            make_tag(4, 5, PROFILE_ID, K_CODEBOOK_ID, 8'h30),
            16'h0300, 5'd8, 0, 0, 0, 8, source_payload_len);
        repeat (80) @(posedge clk);
        abort_before = abort_pulses;
        @(negedge clk);
        abort_task_tag =
            make_tag(4, 5, PROFILE_ID, K_CODEBOOK_ID, 8'h30);
        abort_epoch = 16'h0300;
        abort_page_index = 5'd8;
        abort_stream_is_v = 1'b0;
        abort_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        abort_valid = 1'b0;
        wait_fault(ERR_ABORT,
                   make_tag(4, 5, PROFILE_ID, K_CODEBOOK_ID, 8'h30),
                   16'h0300, 5'd8, 0, abort_before);
        verify_invalid_reads(0, 0);
        clear_sticky_fault();
        run_short_good(
            make_tag(4, 5, PROFILE_ID, K_CODEBOOK_ID, 8'h31),
            16'h0301, 5'd9);

        // Abort with an accepted scratch response deliberately held.  The
        // bank must not release ownership or become clearable until it drains.
        $display("PHASE late_drain scale=%0d", SCALE_BITS);
        build_v_five(2, 1);
        hold_data_response = 1'b1;
        drive_descriptor(
            make_tag(6, 7, PROFILE_ID, V_CODEBOOK_ID, 8'h40),
            16'h0400, 5'd10, 1, 1, 1, 2, source_payload_len);
        timeout = 0;
        while (!data_pending && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!data_pending)
            $fatal(1, "late-drain request was not accepted");
        abort_before = abort_pulses;
        @(negedge clk);
        abort_task_tag =
            make_tag(6, 7, PROFILE_ID, V_CODEBOOK_ID, 8'h40);
        abort_epoch = 16'h0400;
        abort_page_index = 5'd10;
        abort_stream_is_v = 1'b1;
        abort_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        abort_valid = 1'b0;
        if (!draining || clear_ready || source_release) begin
            $display("FAIL abort did not hold drain boundary");
            errors = errors + 1;
        end
        hold_data_response = 1'b0;
        timeout = 0;
        while (!source_release && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!source_release || draining)
            $fatal(1, "late response did not drain/release");
        wait_fault(ERR_ABORT,
                   make_tag(6, 7, PROFILE_ID, V_CODEBOOK_ID, 8'h40),
                   16'h0400, 5'd10, 1, abort_before);
        clear_sticky_fault();
        run_short_good(
            make_tag(6, 7, PROFILE_ID, K_CODEBOOK_ID, 8'h41),
            16'h0401, 5'd11);

        // 7. Wrong profile, codebook, and stream identities each produce one
        // exactly tagged row abort.  A real decoder truncation does likewise.
        $display("PHASE typed_faults scale=%0d", SCALE_BITS);
        build_k_zero(1, 0);
        abort_before = abort_pulses;
        issue_page_and_wait_copy(
            make_tag(8, 9, 16'hdead, K_CODEBOOK_ID, 8'h50),
            16'h0500, 5'd12, 0, 0, 0, 1, source_payload_len);
        wait_fault(ERR_PROFILE,
                   make_tag(8, 9, 16'hdead, K_CODEBOOK_ID, 8'h50),
                   16'h0500, 5'd12, 0, abort_before);
        clear_sticky_fault();
        run_short_good(
            make_tag(8, 9, PROFILE_ID, K_CODEBOOK_ID, 8'h51),
            16'h0501, 5'd13);

        build_k_zero(1, 0);
        abort_before = abort_pulses;
        issue_page_and_wait_copy(
            make_tag(8, 9, PROFILE_ID, 8'hee, 8'h52),
            16'h0502, 5'd14, 0, 0, 0, 1, source_payload_len);
        wait_fault(ERR_CODEBOOK,
                   make_tag(8, 9, PROFILE_ID, 8'hee, 8'h52),
                   16'h0502, 5'd14, 0, abort_before);
        clear_sticky_fault();
        run_short_good(
            make_tag(8, 9, PROFILE_ID, K_CODEBOOK_ID, 8'h53),
            16'h0503, 5'd15);

        build_v_five(1, 0);
        abort_before = abort_pulses;
        issue_page_and_wait_copy(
            make_tag(8, 9, PROFILE_ID, K_CODEBOOK_ID, 8'h54),
            16'h0504, 5'd16, 1, 0, 0, 1, source_payload_len);
        wait_fault(ERR_STREAM,
                   make_tag(8, 9, PROFILE_ID, K_CODEBOOK_ID, 8'h54),
                   16'h0504, 5'd16, 1, abort_before);
        clear_sticky_fault();
        run_short_good(
            make_tag(8, 9, PROFILE_ID, K_CODEBOOK_ID, 8'h55),
            16'h0505, 5'd17);

        clear_source_images();
        source_payload_len = 1;
        source_payload[0] = 8'h00;
        build_scales(1);
        abort_before = abort_pulses;
        issue_page_and_wait_copy(
            make_tag(8, 9, PROFILE_ID, K_CODEBOOK_ID, 8'h56),
            16'h0506, 5'd18, 0, 0, 0, 1, source_payload_len);
        wait_fault(ERR_DECODER,
                   make_tag(8, 9, PROFILE_ID, K_CODEBOOK_ID, 8'h56),
                   16'h0506, 5'd18, 0, abort_before);
        if (sticky_error_subcode == 0) begin
            $display("FAIL decoder fault lost lane subcode");
            errors = errors + 1;
        end
        clear_sticky_fault();
        run_short_good(
            make_tag(8, 9, PROFILE_ID, K_CODEBOOK_ID, 8'h57),
            16'h0507, 5'd19);

        if (source_errors != 0) begin
            $display("FAIL scratch model errors=%0d", source_errors);
            errors = errors + source_errors;
        end
        if (busy || lane_occupied != 0 || publish_valid || page_active) begin
            $display("FAIL final idle state busy=%0d occupied=%b",
                     busy, lane_occupied);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("KV_V03_TYPED_DECODE_LANE_BANK_4X1_SCALE%0d_PASS",
                     SCALE_BITS);
        else
            $fatal(1,
                "KV_V03_TYPED_DECODE_LANE_BANK_4X1_SCALE%0d_FAIL errors=%0d",
                SCALE_BITS, errors);
        $finish;
    end

    initial begin
        #30000000;
        $fatal(1, "typed decode lane bank global timeout scale=%0d",
               SCALE_BITS);
    end
endmodule

`default_nettype wire
