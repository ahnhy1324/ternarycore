// kv_v03_page_pingpong.v -- ordered two-slot PACKED5 prefetch queue.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// One instance owns one typed stream (K or V).  Each physical slot contains
// its own HP64 range reader, integrity validator and private scratch RAM.  At
// most one page is presented to the consumer while the other slot may fetch
// and verify the following page.  A page becomes visible only after the slot's
// CRC-gated publish handshake, and remains owned until page_release.
module kv_v03_page_pingpong #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer ID_WIDTH = 1,
    parameter integer SCALE_BITS = 12,
    parameter integer STREAM_IS_V = 0,
    parameter integer COMPILED_PROFILE_ID = 0,
    parameter integer COMPILED_CODEBOOK_ID = 1,
    parameter integer TIMEOUT_CYCLES = 65536,
    parameter integer MAX_PAGE_BYTES = 10256,
    parameter integer MAX_SCALE_BYTES = 256
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    cmd_valid,
    output wire                    cmd_ready,
    input  wire [7:0]              cmd_request_id,
    input  wire [15:0]             cmd_layer,
    input  wire [15:0]             cmd_kv_head,
    input  wire [15:0]             cmd_profile_id,
    input  wire [7:0]              cmd_codebook_id,
    input  wire [4:0]              cmd_page_index,
    input  wire [5:0]              cmd_page_count,
    input  wire [12:0]             cmd_token_base,
    input  wire [7:0]              cmd_token_count,
    input  wire [14:0]             cmd_expected_symbols,
    input  wire [ADDR_WIDTH-1:0]   cmd_data_addr,
    input  wire [ADDR_WIDTH-1:0]   cmd_data_limit,
    input  wire [31:0]             cmd_page_window_bytes,
    input  wire [ADDR_WIDTH-1:0]   cmd_scale_addr,
    input  wire [8:0]              cmd_scale_slice_bytes,

    input  wire                    abort,
    input  wire                    clear_fault,
    input  wire                    clear_counters,

    output wire                    page_valid,
    input  wire                    page_ready,
    output wire                    page_active,
    input  wire                    page_release,
    output wire [7:0]              page_request_id,
    output wire [15:0]             page_layer,
    output wire [15:0]             page_kv_head,
    output wire [15:0]             page_profile_id,
    output wire [7:0]              page_codebook_id,
    output wire [4:0]              page_index,
    output wire [5:0]              page_count,
    output wire [12:0]             page_token_base,
    output wire [7:0]              page_token_count,
    output wire [14:0]             page_expected_symbols,
    output wire                    page_raw_mode,
    output wire                    page_stream_is_v,
    output wire [15:0]             page_payload_bytes,
    output wire [7:0]              page_scale_format_id,
    output wire [13:0]             page_record_bytes,
    output wire [13:0]             page_window_bytes,
    output wire [8:0]              page_scale_slice_bytes,
    output wire [13:0]             page_padding_bytes,

    input  wire                    data_rd_en,
    input  wire [11:0]             data_rd_word_addr,
    output wire                    data_rd_valid,
    output wire [31:0]             data_rd_data,
    output wire [3:0]              data_rd_byte_valid,
    output wire                    data_rd_last,
    output wire [13:0]             data_rd_byte_offset,
    input  wire                    scale_rd_en,
    input  wire [6:0]              scale_rd_word_addr,
    output wire                    scale_rd_valid,
    output wire [31:0]             scale_rd_data,
    output wire [3:0]              scale_rd_byte_valid,
    output wire                    scale_rd_last,
    output wire [8:0]              scale_rd_byte_offset,

    input  wire                    consumer_need,
    output wire                    busy,
    output reg                     flushing,
    output reg                     sticky_error,
    output reg  [1:0]              sticky_error_source,
    output reg  [7:0]              sticky_error_code,
    output reg                     sticky_error_phase_is_scale,
    output reg  [7:0]              sticky_request_id,
    output reg  [15:0]             sticky_layer,
    output reg  [15:0]             sticky_kv_head,
    output reg  [15:0]             sticky_profile_id,
    output reg  [7:0]              sticky_codebook_id,
    output reg  [4:0]              sticky_page_index,
    output reg                     row_abort,
    output reg                     reload_required,

    output reg  [31:0]             prefetch_commands,
    output reg  [31:0]             pages_published,
    output reg  [31:0]             pages_released,
    output reg  [31:0]             raw_fallback_pages,
    output reg  [31:0]             integrity_faults,
    output reg  [31:0]             transport_faults,
    output reg  [31:0]             aborted_rows,
    output reg  [31:0]             starvation_cycles,
    output reg  [1:0]              fifo_high_water,
    output wire [31:0]             read_beats,
    output wire [31:0]             burst_count,
    output wire [31:0]             ar_stall_cycles,
    output wire [31:0]             r_wait_cycles,
    output wire [31:0]             output_stall_cycles,

    output wire [ID_WIDTH-1:0]     m0_axi_arid,
    output wire [ADDR_WIDTH-1:0]   m0_axi_araddr,
    output wire [7:0]              m0_axi_arlen,
    output wire [2:0]              m0_axi_arsize,
    output wire [1:0]              m0_axi_arburst,
    output wire                    m0_axi_arlock,
    output wire [3:0]              m0_axi_arcache,
    output wire [2:0]              m0_axi_arprot,
    output wire [3:0]              m0_axi_arqos,
    output wire                    m0_axi_arvalid,
    input  wire                    m0_axi_arready,
    input  wire [ID_WIDTH-1:0]     m0_axi_rid,
    input  wire [63:0]             m0_axi_rdata,
    input  wire [1:0]              m0_axi_rresp,
    input  wire                    m0_axi_rlast,
    input  wire                    m0_axi_rvalid,
    output wire                    m0_axi_rready,

    output wire [ID_WIDTH-1:0]     m1_axi_arid,
    output wire [ADDR_WIDTH-1:0]   m1_axi_araddr,
    output wire [7:0]              m1_axi_arlen,
    output wire [2:0]              m1_axi_arsize,
    output wire [1:0]              m1_axi_arburst,
    output wire                    m1_axi_arlock,
    output wire [3:0]              m1_axi_arcache,
    output wire [2:0]              m1_axi_arprot,
    output wire [3:0]              m1_axi_arqos,
    output wire                    m1_axi_arvalid,
    input  wire                    m1_axi_arready,
    input  wire [ID_WIDTH-1:0]     m1_axi_rid,
    input  wire [63:0]             m1_axi_rdata,
    input  wire [1:0]              m1_axi_rresp,
    input  wire                    m1_axi_rlast,
    input  wire                    m1_axi_rvalid,
    output wire                    m1_axi_rready
);
    localparam [1:0] ERROR_SOURCE_PAIR = 2'd0;
    localparam [7:0] ERR_PROFILE = 8'h01;
    localparam [7:0] ERR_CODEBOOK = 8'h02;

    wire [63:0] cmd_task_tag = {cmd_layer, cmd_kv_head, cmd_profile_id,
                                cmd_codebook_id, cmd_request_id};
    wire identity_ok = (cmd_profile_id == COMPILED_PROFILE_ID[15:0]) &&
                       (cmd_codebook_id == COMPILED_CODEBOOK_ID[7:0]);

    reg occupied0, occupied1;
    reg [1:0] queue_count;
    reg queue_slot0, queue_slot1;
    reg head_presented;

    wire select_slot = occupied0 && !occupied1;
    wire slot0_cmd_ready, slot1_cmd_ready;
    wire selected_cmd_ready = select_slot ? slot1_cmd_ready :
                                             slot0_cmd_ready;
    assign cmd_ready = !abort && !flushing && !sticky_error &&
                       !page_release && (queue_count < 2) &&
                       selected_cmd_ready;
    wire cmd_fire = cmd_valid && cmd_ready;
    wire enqueue_fire = cmd_fire && identity_ok;
    wire slot0_cmd_valid = enqueue_fire && !select_slot;
    wire slot1_cmd_valid = enqueue_fire && select_slot;

    wire slot0_publish_valid, slot1_publish_valid;
    wire slot0_active, slot1_active;
    wire slot0_busy, slot1_busy;
    wire slot0_committed, slot1_committed;
    wire [63:0] slot0_committed_tag, slot1_committed_tag;
    wire slot0_aborted, slot1_aborted;
    wire [63:0] slot0_aborted_tag, slot1_aborted_tag;
    wire [4:0] slot0_aborted_page, slot1_aborted_page;
    wire slot0_aborted_stream, slot1_aborted_stream;
    wire slot0_error_valid, slot1_error_valid;
    wire [1:0] slot0_error_source, slot1_error_source;
    wire [7:0] slot0_error_code, slot1_error_code;
    wire slot0_error_phase, slot1_error_phase;
    wire [63:0] slot0_error_tag, slot1_error_tag;
    wire [4:0] slot0_error_page, slot1_error_page;
    wire slot0_error_stream, slot1_error_stream;
    // `flushing` is a completion status, not an abort level.  Holding abort
    // throughout the flush would strand each slot in ST_ABORT_WAIT while this
    // pair waits for those same slots to become idle.  Kick both slots on the
    // initiating event, then let them drain and retire with flushing asserted.
    reg flush_abort_kick;
    wire internal_abort = abort || slot0_error_valid || slot1_error_valid ||
                          flush_abort_kick;

    assign page_valid = (queue_count != 0) && !head_presented &&
                        (queue_slot0 ? slot1_active : slot0_active) &&
                        !abort && !flushing && !sticky_error;
    wire page_fire = page_valid && page_ready;
    assign page_active = (queue_count != 0) && head_presented &&
                         (queue_slot0 ? slot1_active : slot0_active) &&
                         !abort && !flushing && !sticky_error;
    wire release_fire = page_active && page_release;
    wire slot0_release = release_fire && !queue_slot0;
    wire slot1_release = release_fire && queue_slot0;

    wire [63:0] selected_page_tag = queue_slot0 ? slot1_page_tag :
                                                   slot0_page_tag;
    assign page_layer       = selected_page_tag[63:48];
    assign page_kv_head     = selected_page_tag[47:32];
    assign page_profile_id  = selected_page_tag[31:16];
    assign page_codebook_id = selected_page_tag[15:8];
    assign page_request_id  = selected_page_tag[7:0];

    wire [63:0] slot0_page_tag, slot1_page_tag;
    wire [4:0] slot0_page_index, slot1_page_index;
    wire [5:0] slot0_page_count, slot1_page_count;
    wire [12:0] slot0_token_base, slot1_token_base;
    wire [7:0] slot0_token_count, slot1_token_count;
    wire [14:0] slot0_symbols, slot1_symbols;
    wire slot0_raw, slot1_raw, slot0_stream, slot1_stream;
    wire [15:0] slot0_payload, slot1_payload;
    wire [7:0] slot0_scale_format, slot1_scale_format;
    wire [13:0] slot0_record, slot1_record;
    wire [13:0] slot0_window, slot1_window;
    wire [8:0] slot0_scale_bytes, slot1_scale_bytes;
    wire [13:0] slot0_padding, slot1_padding;

    assign page_index              = queue_slot0 ? slot1_page_index : slot0_page_index;
    assign page_count              = queue_slot0 ? slot1_page_count : slot0_page_count;
    assign page_token_base         = queue_slot0 ? slot1_token_base : slot0_token_base;
    assign page_token_count        = queue_slot0 ? slot1_token_count : slot0_token_count;
    assign page_expected_symbols   = queue_slot0 ? slot1_symbols : slot0_symbols;
    assign page_raw_mode           = queue_slot0 ? slot1_raw : slot0_raw;
    assign page_stream_is_v        = queue_slot0 ? slot1_stream : slot0_stream;
    assign page_payload_bytes      = queue_slot0 ? slot1_payload : slot0_payload;
    assign page_scale_format_id    = queue_slot0 ? slot1_scale_format : slot0_scale_format;
    assign page_record_bytes       = queue_slot0 ? slot1_record : slot0_record;
    assign page_window_bytes       = queue_slot0 ? slot1_window : slot0_window;
    assign page_scale_slice_bytes  = queue_slot0 ? slot1_scale_bytes : slot0_scale_bytes;
    assign page_padding_bytes      = queue_slot0 ? slot1_padding : slot0_padding;

    wire slot0_data_valid, slot1_data_valid;
    wire [31:0] slot0_data, slot1_data;
    wire [3:0] slot0_data_keep, slot1_data_keep;
    wire slot0_data_last, slot1_data_last;
    wire [13:0] slot0_data_offset, slot1_data_offset;
    wire slot0_scale_valid, slot1_scale_valid;
    wire [31:0] slot0_scale_data, slot1_scale_data;
    wire [3:0] slot0_scale_keep, slot1_scale_keep;
    wire slot0_scale_last, slot1_scale_last;
    wire [8:0] slot0_scale_offset, slot1_scale_offset;

    wire scratch_enable = page_active && !page_release;
    assign data_rd_valid = page_active && !page_release &&
                           (queue_slot0 ? slot1_data_valid : slot0_data_valid);
    assign data_rd_data = queue_slot0 ? slot1_data : slot0_data;
    assign data_rd_byte_valid = queue_slot0 ? slot1_data_keep : slot0_data_keep;
    assign data_rd_last = queue_slot0 ? slot1_data_last : slot0_data_last;
    assign data_rd_byte_offset = queue_slot0 ? slot1_data_offset : slot0_data_offset;
    assign scale_rd_valid = page_active && !page_release &&
                            (queue_slot0 ? slot1_scale_valid : slot0_scale_valid);
    assign scale_rd_data = queue_slot0 ? slot1_scale_data : slot0_scale_data;
    assign scale_rd_byte_valid = queue_slot0 ? slot1_scale_keep : slot0_scale_keep;
    assign scale_rd_last = queue_slot0 ? slot1_scale_last : slot0_scale_last;
    assign scale_rd_byte_offset = queue_slot0 ? slot1_scale_offset : slot0_scale_offset;

    wire [31:0] slot0_read_beats, slot1_read_beats;
    wire [31:0] slot0_bursts, slot1_bursts;
    wire [31:0] slot0_ar_stalls, slot1_ar_stalls;
    wire [31:0] slot0_r_wait, slot1_r_wait;
    wire [31:0] slot0_out_stalls, slot1_out_stalls;
    assign read_beats = slot0_read_beats + slot1_read_beats;
    assign burst_count = slot0_bursts + slot1_bursts;
    assign ar_stall_cycles = slot0_ar_stalls + slot1_ar_stalls;
    assign r_wait_cycles = slot0_r_wait + slot1_r_wait;
    assign output_stall_cycles = slot0_out_stalls + slot1_out_stalls;

    wire slot_fault = slot0_error_valid || slot1_error_valid;
    wire slot_abort_status = slot0_aborted || slot1_aborted;
    assign busy = (queue_count != 0) || slot0_busy || slot1_busy || flushing;

    integer next_count;
    always @(posedge clk) begin
        if (!rst_n) begin
            occupied0 <= 1'b0;
            occupied1 <= 1'b0;
            queue_count <= 2'd0;
            queue_slot0 <= 1'b0;
            queue_slot1 <= 1'b0;
            head_presented <= 1'b0;
            flush_abort_kick <= 1'b0;
            flushing <= 1'b0;
            sticky_error <= 1'b0;
            sticky_error_source <= 2'd0;
            sticky_error_code <= 8'd0;
            sticky_error_phase_is_scale <= 1'b0;
            sticky_request_id <= 8'd0;
            sticky_layer <= 16'd0;
            sticky_kv_head <= 16'd0;
            sticky_profile_id <= 16'd0;
            sticky_codebook_id <= 8'd0;
            sticky_page_index <= 5'd0;
            row_abort <= 1'b0;
            reload_required <= 1'b0;
            prefetch_commands <= 32'd0;
            pages_published <= 32'd0;
            pages_released <= 32'd0;
            raw_fallback_pages <= 32'd0;
            integrity_faults <= 32'd0;
            transport_faults <= 32'd0;
            aborted_rows <= 32'd0;
            starvation_cycles <= 32'd0;
            fifo_high_water <= 2'd0;
        end else begin
            row_abort <= 1'b0;
            flush_abort_kick <= 1'b0;

            if (clear_counters) begin
                prefetch_commands <= 32'd0;
                pages_published <= 32'd0;
                pages_released <= 32'd0;
                raw_fallback_pages <= 32'd0;
                integrity_faults <= 32'd0;
                transport_faults <= 32'd0;
                aborted_rows <= 32'd0;
                starvation_cycles <= 32'd0;
                fifo_high_water <= 2'd0;
            end else begin
                if (enqueue_fire)
                    prefetch_commands <= prefetch_commands + 1'b1;
                if (slot0_committed || slot1_committed)
                    pages_published <= pages_published +
                        {31'b0, slot0_committed} +
                        {31'b0, slot1_committed};
                if ((slot0_committed && slot0_raw) ||
                    (slot1_committed && slot1_raw))
                    raw_fallback_pages <= raw_fallback_pages +
                        {31'b0, (slot0_committed && slot0_raw)} +
                        {31'b0, (slot1_committed && slot1_raw)};
                if (release_fire)
                    pages_released <= pages_released + 1'b1;
                if (consumer_need && !page_valid && !page_active)
                    starvation_cycles <= starvation_cycles + 1'b1;
                next_count = queue_count + (enqueue_fire ? 1 : 0) -
                             (release_fire ? 1 : 0);
                if (next_count > fifo_high_water)
                    fifo_high_water <= next_count[1:0];
            end

            if (clear_fault && !flushing) begin
                sticky_error <= 1'b0;
                sticky_error_source <= 2'd0;
                sticky_error_code <= 8'd0;
                reload_required <= 1'b0;
            end

            if (page_fire)
                head_presented <= 1'b1;

            if (release_fire) begin
                if (queue_slot0)
                    occupied1 <= 1'b0;
                else
                    occupied0 <= 1'b0;
                if (queue_count == 2) begin
                    queue_slot0 <= queue_slot1;
                    queue_count <= 1;
                end else begin
                    queue_count <= 0;
                end
                head_presented <= 1'b0;
            end

            if (enqueue_fire) begin
                if (select_slot)
                    occupied1 <= 1'b1;
                else
                    occupied0 <= 1'b1;
                if (queue_count == 0)
                    queue_slot0 <= select_slot;
                else
                    queue_slot1 <= select_slot;
                queue_count <= queue_count + 1'b1;
            end

            if (cmd_fire && !identity_ok) begin
                sticky_error <= 1'b1;
                sticky_error_source <= ERROR_SOURCE_PAIR;
                sticky_error_code <= (cmd_profile_id !=
                    COMPILED_PROFILE_ID[15:0]) ? ERR_PROFILE : ERR_CODEBOOK;
                sticky_error_phase_is_scale <= 1'b0;
                sticky_request_id <= cmd_request_id;
                sticky_layer <= cmd_layer;
                sticky_kv_head <= cmd_kv_head;
                sticky_profile_id <= cmd_profile_id;
                sticky_codebook_id <= cmd_codebook_id;
                sticky_page_index <= cmd_page_index;
                reload_required <= 1'b1;
                row_abort <= 1'b1;
                flush_abort_kick <= 1'b1;
                integrity_faults <= integrity_faults + 1'b1;
                flushing <= 1'b1;
            end else if (slot_fault && !flushing) begin
                sticky_error <= 1'b1;
                if (slot0_error_valid) begin
                    sticky_error_source <= slot0_error_source;
                    sticky_error_code <= slot0_error_code;
                    sticky_error_phase_is_scale <= slot0_error_phase;
                    sticky_layer <= slot0_error_tag[63:48];
                    sticky_kv_head <= slot0_error_tag[47:32];
                    sticky_profile_id <= slot0_error_tag[31:16];
                    sticky_codebook_id <= slot0_error_tag[15:8];
                    sticky_request_id <= slot0_error_tag[7:0];
                    sticky_page_index <= slot0_error_page;
                    if (slot0_error_source == 2'd3)
                        integrity_faults <= integrity_faults + 1'b1;
                    else
                        transport_faults <= transport_faults + 1'b1;
                end else begin
                    sticky_error_source <= slot1_error_source;
                    sticky_error_code <= slot1_error_code;
                    sticky_error_phase_is_scale <= slot1_error_phase;
                    sticky_layer <= slot1_error_tag[63:48];
                    sticky_kv_head <= slot1_error_tag[47:32];
                    sticky_profile_id <= slot1_error_tag[31:16];
                    sticky_codebook_id <= slot1_error_tag[15:8];
                    sticky_request_id <= slot1_error_tag[7:0];
                    sticky_page_index <= slot1_error_page;
                    if (slot1_error_source == 2'd3)
                        integrity_faults <= integrity_faults + 1'b1;
                    else
                        transport_faults <= transport_faults + 1'b1;
                end
                reload_required <= 1'b1;
                row_abort <= 1'b1;
                flushing <= 1'b1;
            end else if (abort && !flushing) begin
                row_abort <= 1'b1;
                aborted_rows <= aborted_rows + 1'b1;
                flushing <= 1'b1;
            end

            if (slot_abort_status && !abort && !flushing)
                aborted_rows <= aborted_rows + 1'b1;

            if (flushing && !abort && !slot0_busy && !slot1_busy &&
                !slot0_active && !slot1_active) begin
                occupied0 <= 1'b0;
                occupied1 <= 1'b0;
                queue_count <= 2'd0;
                queue_slot0 <= 1'b0;
                queue_slot1 <= 1'b0;
                head_presented <= 1'b0;
                flushing <= 1'b0;
            end
        end
    end

    wire [31:0] unused_slot0_data_bytes, unused_slot1_data_bytes;
    wire [31:0] unused_slot0_scale_bytes_count,
                unused_slot1_scale_bytes_count;
    wire [31:0] unused_slot0_committed_pages, unused_slot1_committed_pages;
    wire [31:0] unused_slot0_failed_pages, unused_slot1_failed_pages;
    wire [31:0] unused_slot0_aborted_pages, unused_slot1_aborted_pages;
    wire slot0_transport_busy, slot1_transport_busy;
    wire slot0_transport_draining, slot1_transport_draining;

    kv_v03_page_prefetch_slot #(
        .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH), .TAG_WIDTH(64),
        .SCALE_BITS(SCALE_BITS),
        .COMPILED_CODEBOOK_ID(COMPILED_CODEBOOK_ID),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .MAX_PAGE_BYTES(MAX_PAGE_BYTES),
        .MAX_SCALE_BYTES(MAX_SCALE_BYTES)
    ) u_slot0 (
        .clk(clk), .rst_n(rst_n), .cmd_valid(slot0_cmd_valid),
        .cmd_ready(slot0_cmd_ready), .cmd_page_index(cmd_page_index),
        .cmd_page_count(cmd_page_count), .cmd_token_base(cmd_token_base),
        .cmd_token_count(cmd_token_count),
        .cmd_expected_symbols(cmd_expected_symbols),
        .cmd_data_addr(cmd_data_addr), .cmd_data_limit(cmd_data_limit),
        .cmd_page_window_bytes(cmd_page_window_bytes),
        .cmd_scale_addr(cmd_scale_addr),
        .cmd_scale_slice_bytes(cmd_scale_slice_bytes),
        .cmd_stream_is_v(STREAM_IS_V != 0), .cmd_task_tag(cmd_task_tag),
        .abort(internal_abort), .publish_valid(slot0_publish_valid),
        .publish_ready(1'b1), .slot_release(slot0_release),
        .slot_active(slot0_active), .busy(slot0_busy),
        .page_task_tag(slot0_page_tag), .page_index(slot0_page_index),
        .page_count(slot0_page_count), .page_token_base(slot0_token_base),
        .page_token_count(slot0_token_count),
        .page_expected_symbols(slot0_symbols), .page_raw_mode(slot0_raw),
        .page_stream_is_v(slot0_stream), .page_payload_bytes(slot0_payload),
        .page_scale_format_id(slot0_scale_format),
        .page_record_bytes(slot0_record), .page_window_bytes(slot0_window),
        .page_scale_slice_bytes(slot0_scale_bytes),
        .page_padding_bytes(slot0_padding),
        .data_rd_en(data_rd_en && scratch_enable && !queue_slot0),
        .data_rd_word_addr(data_rd_word_addr),
        .data_rd_valid(slot0_data_valid), .data_rd_data(slot0_data),
        .data_rd_byte_valid(slot0_data_keep), .data_rd_last(slot0_data_last),
        .data_rd_byte_offset(slot0_data_offset),
        .scale_rd_en(scale_rd_en && scratch_enable && !queue_slot0),
        .scale_rd_word_addr(scale_rd_word_addr),
        .scale_rd_valid(slot0_scale_valid), .scale_rd_data(slot0_scale_data),
        .scale_rd_byte_valid(slot0_scale_keep),
        .scale_rd_last(slot0_scale_last),
        .scale_rd_byte_offset(slot0_scale_offset),
        .committed(slot0_committed),
        .committed_task_tag(slot0_committed_tag),
        .aborted(slot0_aborted), .aborted_task_tag(slot0_aborted_tag),
        .aborted_page_index(slot0_aborted_page),
        .aborted_stream_is_v(slot0_aborted_stream),
        .error_valid(slot0_error_valid), .error_source(slot0_error_source),
        .error_code(slot0_error_code),
        .error_phase_is_scale(slot0_error_phase),
        .error_task_tag(slot0_error_tag), .error_page_index(slot0_error_page),
        .error_stream_is_v(slot0_error_stream),
        .clear_counters(clear_counters), .read_beats(slot0_read_beats),
        .burst_count(slot0_bursts), .ar_stall_cycles(slot0_ar_stalls),
        .r_wait_cycles(slot0_r_wait),
        .output_stall_cycles(slot0_out_stalls),
        .data_scratch_bytes(unused_slot0_data_bytes),
        .scale_scratch_bytes(unused_slot0_scale_bytes_count),
        .committed_pages(unused_slot0_committed_pages),
        .failed_pages(unused_slot0_failed_pages),
        .aborted_pages(unused_slot0_aborted_pages),
        .transport_busy(slot0_transport_busy),
        .transport_draining(slot0_transport_draining),
        .m_axi_arid(m0_axi_arid), .m_axi_araddr(m0_axi_araddr),
        .m_axi_arlen(m0_axi_arlen), .m_axi_arsize(m0_axi_arsize),
        .m_axi_arburst(m0_axi_arburst), .m_axi_arlock(m0_axi_arlock),
        .m_axi_arcache(m0_axi_arcache), .m_axi_arprot(m0_axi_arprot),
        .m_axi_arqos(m0_axi_arqos), .m_axi_arvalid(m0_axi_arvalid),
        .m_axi_arready(m0_axi_arready), .m_axi_rid(m0_axi_rid),
        .m_axi_rdata(m0_axi_rdata), .m_axi_rresp(m0_axi_rresp),
        .m_axi_rlast(m0_axi_rlast), .m_axi_rvalid(m0_axi_rvalid),
        .m_axi_rready(m0_axi_rready)
    );

    kv_v03_page_prefetch_slot #(
        .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH), .TAG_WIDTH(64),
        .SCALE_BITS(SCALE_BITS),
        .COMPILED_CODEBOOK_ID(COMPILED_CODEBOOK_ID),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .MAX_PAGE_BYTES(MAX_PAGE_BYTES),
        .MAX_SCALE_BYTES(MAX_SCALE_BYTES)
    ) u_slot1 (
        .clk(clk), .rst_n(rst_n), .cmd_valid(slot1_cmd_valid),
        .cmd_ready(slot1_cmd_ready), .cmd_page_index(cmd_page_index),
        .cmd_page_count(cmd_page_count), .cmd_token_base(cmd_token_base),
        .cmd_token_count(cmd_token_count),
        .cmd_expected_symbols(cmd_expected_symbols),
        .cmd_data_addr(cmd_data_addr), .cmd_data_limit(cmd_data_limit),
        .cmd_page_window_bytes(cmd_page_window_bytes),
        .cmd_scale_addr(cmd_scale_addr),
        .cmd_scale_slice_bytes(cmd_scale_slice_bytes),
        .cmd_stream_is_v(STREAM_IS_V != 0), .cmd_task_tag(cmd_task_tag),
        .abort(internal_abort), .publish_valid(slot1_publish_valid),
        .publish_ready(1'b1), .slot_release(slot1_release),
        .slot_active(slot1_active), .busy(slot1_busy),
        .page_task_tag(slot1_page_tag), .page_index(slot1_page_index),
        .page_count(slot1_page_count), .page_token_base(slot1_token_base),
        .page_token_count(slot1_token_count),
        .page_expected_symbols(slot1_symbols), .page_raw_mode(slot1_raw),
        .page_stream_is_v(slot1_stream), .page_payload_bytes(slot1_payload),
        .page_scale_format_id(slot1_scale_format),
        .page_record_bytes(slot1_record), .page_window_bytes(slot1_window),
        .page_scale_slice_bytes(slot1_scale_bytes),
        .page_padding_bytes(slot1_padding),
        .data_rd_en(data_rd_en && scratch_enable && queue_slot0),
        .data_rd_word_addr(data_rd_word_addr),
        .data_rd_valid(slot1_data_valid), .data_rd_data(slot1_data),
        .data_rd_byte_valid(slot1_data_keep), .data_rd_last(slot1_data_last),
        .data_rd_byte_offset(slot1_data_offset),
        .scale_rd_en(scale_rd_en && scratch_enable && queue_slot0),
        .scale_rd_word_addr(scale_rd_word_addr),
        .scale_rd_valid(slot1_scale_valid), .scale_rd_data(slot1_scale_data),
        .scale_rd_byte_valid(slot1_scale_keep),
        .scale_rd_last(slot1_scale_last),
        .scale_rd_byte_offset(slot1_scale_offset),
        .committed(slot1_committed),
        .committed_task_tag(slot1_committed_tag),
        .aborted(slot1_aborted), .aborted_task_tag(slot1_aborted_tag),
        .aborted_page_index(slot1_aborted_page),
        .aborted_stream_is_v(slot1_aborted_stream),
        .error_valid(slot1_error_valid), .error_source(slot1_error_source),
        .error_code(slot1_error_code),
        .error_phase_is_scale(slot1_error_phase),
        .error_task_tag(slot1_error_tag), .error_page_index(slot1_error_page),
        .error_stream_is_v(slot1_error_stream),
        .clear_counters(clear_counters), .read_beats(slot1_read_beats),
        .burst_count(slot1_bursts), .ar_stall_cycles(slot1_ar_stalls),
        .r_wait_cycles(slot1_r_wait),
        .output_stall_cycles(slot1_out_stalls),
        .data_scratch_bytes(unused_slot1_data_bytes),
        .scale_scratch_bytes(unused_slot1_scale_bytes_count),
        .committed_pages(unused_slot1_committed_pages),
        .failed_pages(unused_slot1_failed_pages),
        .aborted_pages(unused_slot1_aborted_pages),
        .transport_busy(slot1_transport_busy),
        .transport_draining(slot1_transport_draining),
        .m_axi_arid(m1_axi_arid), .m_axi_araddr(m1_axi_araddr),
        .m_axi_arlen(m1_axi_arlen), .m_axi_arsize(m1_axi_arsize),
        .m_axi_arburst(m1_axi_arburst), .m_axi_arlock(m1_axi_arlock),
        .m_axi_arcache(m1_axi_arcache), .m_axi_arprot(m1_axi_arprot),
        .m_axi_arqos(m1_axi_arqos), .m_axi_arvalid(m1_axi_arvalid),
        .m_axi_arready(m1_axi_arready), .m_axi_rid(m1_axi_rid),
        .m_axi_rdata(m1_axi_rdata), .m_axi_rresp(m1_axi_rresp),
        .m_axi_rlast(m1_axi_rlast), .m_axi_rvalid(m1_axi_rvalid),
        .m_axi_rready(m1_axi_rready)
    );

    wire unused = slot0_publish_valid ^ slot1_publish_valid ^
                  ^slot0_committed_tag ^ ^slot1_committed_tag ^
                  slot0_aborted ^ slot1_aborted ^ ^slot0_aborted_tag ^
                  ^slot1_aborted_tag ^ ^slot0_aborted_page ^
                  ^slot1_aborted_page ^ slot0_aborted_stream ^
                  slot1_aborted_stream ^ slot0_error_stream ^
                  slot1_error_stream ^ slot0_transport_busy ^
                  slot1_transport_busy ^ slot0_transport_draining ^
                  slot1_transport_draining;

`ifndef SYNTHESIS
    initial begin
        if (ADDR_WIDTH != 32)
            $error("kv_v03_page_pingpong requires 32-bit Zybo addresses");
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("kv_v03_page_pingpong SCALE_BITS must be 12 or 16");
        if (STREAM_IS_V != 0 && STREAM_IS_V != 1)
            $error("kv_v03_page_pingpong STREAM_IS_V must be 0 or 1");
        if (COMPILED_PROFILE_ID < 0 || COMPILED_PROFILE_ID > 65535)
            $error("kv_v03_page_pingpong profile ID must fit in 16 bits");
        if (COMPILED_CODEBOOK_ID < 0 || COMPILED_CODEBOOK_ID > 255)
            $error("kv_v03_page_pingpong codebook ID must fit in 8 bits");
    end
`endif
endmodule

`default_nettype wire
