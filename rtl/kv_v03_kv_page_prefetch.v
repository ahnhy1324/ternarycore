// kv_v03_kv_page_prefetch.v -- atomic K/V two-page prefetch coordinator.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// A row descriptor is accepted only when both typed streams can accept it.
// K and V retain private two-slot queues and four independent HP64 readers.
// Neither page is exposed until both queue heads are committed and their
// common row/page identity agrees.  Fault handling is fail-closed: a first
// fault aborts both children, hides both scratches, and requires PS software
// to wait for clear_ready before pulsing clear_fault.
module kv_v03_kv_page_prefetch #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer ID_WIDTH = 1,
    parameter integer SCALE_BITS = 12,
    parameter integer COMPILED_PROFILE_ID = 0,
    parameter integer COMPILED_K_CODEBOOK_ID = 1,
    parameter integer COMPILED_V_CODEBOOK_ID = 1,
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
    input  wire [7:0]              cmd_k_codebook_id,
    input  wire [7:0]              cmd_v_codebook_id,
    input  wire [4:0]              cmd_page_index,
    input  wire [5:0]              cmd_page_count,
    input  wire [12:0]             cmd_token_base,
    input  wire [7:0]              cmd_token_count,
    input  wire [14:0]             cmd_expected_symbols,
    input  wire [ADDR_WIDTH-1:0]   cmd_k_data_addr,
    input  wire [ADDR_WIDTH-1:0]   cmd_k_data_limit,
    input  wire [31:0]             cmd_k_page_window_bytes,
    input  wire [ADDR_WIDTH-1:0]   cmd_k_scale_addr,
    input  wire [8:0]              cmd_k_scale_slice_bytes,
    input  wire [ADDR_WIDTH-1:0]   cmd_v_data_addr,
    input  wire [ADDR_WIDTH-1:0]   cmd_v_data_limit,
    input  wire [31:0]             cmd_v_page_window_bytes,
    input  wire [ADDR_WIDTH-1:0]   cmd_v_scale_addr,
    input  wire [8:0]              cmd_v_scale_slice_bytes,

    input  wire                    abort,
    input  wire                    clear_fault,
    output wire                    clear_ready,
    input  wire                    clear_counters,

    output wire                    page_valid,
    input  wire                    page_ready,
    output wire                    page_active,
    input  wire                    page_release,
    output wire [7:0]              page_request_id,
    output wire [15:0]             page_layer,
    output wire [15:0]             page_kv_head,
    output wire [15:0]             page_profile_id,
    output wire [7:0]              page_k_codebook_id,
    output wire [7:0]              page_v_codebook_id,
    output wire [4:0]              page_index,
    output wire [5:0]              page_count,
    output wire [12:0]             page_token_base,
    output wire [7:0]              page_token_count,
    output wire [14:0]             page_expected_symbols,
    output wire                    page_k_raw_mode,
    output wire                    page_v_raw_mode,
    output wire [15:0]             page_k_payload_bytes,
    output wire [15:0]             page_v_payload_bytes,
    output wire [7:0]              page_k_scale_format_id,
    output wire [7:0]              page_v_scale_format_id,
    output wire [13:0]             page_k_record_bytes,
    output wire [13:0]             page_v_record_bytes,
    output wire [13:0]             page_k_window_bytes,
    output wire [13:0]             page_v_window_bytes,
    output wire [8:0]              page_k_scale_slice_bytes,
    output wire [8:0]              page_v_scale_slice_bytes,
    output wire [13:0]             page_k_padding_bytes,
    output wire [13:0]             page_v_padding_bytes,

    input  wire                    k_data_rd_en,
    input  wire [11:0]             k_data_rd_word_addr,
    output wire                    k_data_rd_valid,
    output wire [31:0]             k_data_rd_data,
    output wire [3:0]              k_data_rd_byte_valid,
    output wire                    k_data_rd_last,
    output wire [13:0]             k_data_rd_byte_offset,
    input  wire                    k_scale_rd_en,
    input  wire [6:0]              k_scale_rd_word_addr,
    output wire                    k_scale_rd_valid,
    output wire [31:0]             k_scale_rd_data,
    output wire [3:0]              k_scale_rd_byte_valid,
    output wire                    k_scale_rd_last,
    output wire [8:0]              k_scale_rd_byte_offset,

    input  wire                    v_data_rd_en,
    input  wire [11:0]             v_data_rd_word_addr,
    output wire                    v_data_rd_valid,
    output wire [31:0]             v_data_rd_data,
    output wire [3:0]              v_data_rd_byte_valid,
    output wire                    v_data_rd_last,
    output wire [13:0]             v_data_rd_byte_offset,
    input  wire                    v_scale_rd_en,
    input  wire [6:0]              v_scale_rd_word_addr,
    output wire                    v_scale_rd_valid,
    output wire [31:0]             v_scale_rd_data,
    output wire [3:0]              v_scale_rd_byte_valid,
    output wire                    v_scale_rd_last,
    output wire [8:0]              v_scale_rd_byte_offset,

    input  wire                    consumer_need,
    output wire                    busy,
    output reg                     flushing,
    output reg                     sticky_error,
    output reg  [1:0]              sticky_error_source,
    output reg  [7:0]              sticky_error_code,
    output reg                     sticky_error_phase_is_scale,
    output reg                     sticky_fault_stream_is_v,
    output reg  [7:0]              sticky_request_id,
    output reg  [15:0]             sticky_layer,
    output reg  [15:0]             sticky_kv_head,
    output reg  [15:0]             sticky_profile_id,
    output reg  [7:0]              sticky_codebook_id,
    output reg  [4:0]              sticky_page_index,
    output reg                     row_abort,
    output reg                     reload_required,

    output reg  [31:0]             pair_commands,
    output reg  [31:0]             pairs_published,
    output reg  [31:0]             pairs_released,
    output reg  [31:0]             pair_aborted_rows,
    output reg  [31:0]             pair_starvation_cycles,
    output reg  [1:0]              pair_fifo_high_water,

    output wire [31:0]             k_prefetch_commands,
    output wire [31:0]             k_pages_published,
    output wire [31:0]             k_pages_released,
    output wire [31:0]             k_raw_fallback_pages,
    output wire [31:0]             k_integrity_faults,
    output wire [31:0]             k_transport_faults,
    output wire [31:0]             k_aborted_rows,
    output wire [31:0]             k_starvation_cycles,
    output wire [1:0]              k_fifo_high_water,
    output wire [31:0]             k_read_beats,
    output wire [31:0]             k_burst_count,
    output wire [31:0]             k_ar_stall_cycles,
    output wire [31:0]             k_r_wait_cycles,
    output wire [31:0]             k_output_stall_cycles,
    output wire [31:0]             v_prefetch_commands,
    output wire [31:0]             v_pages_published,
    output wire [31:0]             v_pages_released,
    output wire [31:0]             v_raw_fallback_pages,
    output wire [31:0]             v_integrity_faults,
    output wire [31:0]             v_transport_faults,
    output wire [31:0]             v_aborted_rows,
    output wire [31:0]             v_starvation_cycles,
    output wire [1:0]              v_fifo_high_water,
    output wire [31:0]             v_read_beats,
    output wire [31:0]             v_burst_count,
    output wire [31:0]             v_ar_stall_cycles,
    output wire [31:0]             v_r_wait_cycles,
    output wire [31:0]             v_output_stall_cycles,

    output wire [ID_WIDTH-1:0]     k0_axi_arid,
    output wire [ADDR_WIDTH-1:0]   k0_axi_araddr,
    output wire [7:0]              k0_axi_arlen,
    output wire [2:0]              k0_axi_arsize,
    output wire [1:0]              k0_axi_arburst,
    output wire                    k0_axi_arlock,
    output wire [3:0]              k0_axi_arcache,
    output wire [2:0]              k0_axi_arprot,
    output wire [3:0]              k0_axi_arqos,
    output wire                    k0_axi_arvalid,
    input  wire                    k0_axi_arready,
    input  wire [ID_WIDTH-1:0]     k0_axi_rid,
    input  wire [63:0]             k0_axi_rdata,
    input  wire [1:0]              k0_axi_rresp,
    input  wire                    k0_axi_rlast,
    input  wire                    k0_axi_rvalid,
    output wire                    k0_axi_rready,

    output wire [ID_WIDTH-1:0]     k1_axi_arid,
    output wire [ADDR_WIDTH-1:0]   k1_axi_araddr,
    output wire [7:0]              k1_axi_arlen,
    output wire [2:0]              k1_axi_arsize,
    output wire [1:0]              k1_axi_arburst,
    output wire                    k1_axi_arlock,
    output wire [3:0]              k1_axi_arcache,
    output wire [2:0]              k1_axi_arprot,
    output wire [3:0]              k1_axi_arqos,
    output wire                    k1_axi_arvalid,
    input  wire                    k1_axi_arready,
    input  wire [ID_WIDTH-1:0]     k1_axi_rid,
    input  wire [63:0]             k1_axi_rdata,
    input  wire [1:0]              k1_axi_rresp,
    input  wire                    k1_axi_rlast,
    input  wire                    k1_axi_rvalid,
    output wire                    k1_axi_rready,

    output wire [ID_WIDTH-1:0]     v0_axi_arid,
    output wire [ADDR_WIDTH-1:0]   v0_axi_araddr,
    output wire [7:0]              v0_axi_arlen,
    output wire [2:0]              v0_axi_arsize,
    output wire [1:0]              v0_axi_arburst,
    output wire                    v0_axi_arlock,
    output wire [3:0]              v0_axi_arcache,
    output wire [2:0]              v0_axi_arprot,
    output wire [3:0]              v0_axi_arqos,
    output wire                    v0_axi_arvalid,
    input  wire                    v0_axi_arready,
    input  wire [ID_WIDTH-1:0]     v0_axi_rid,
    input  wire [63:0]             v0_axi_rdata,
    input  wire [1:0]              v0_axi_rresp,
    input  wire                    v0_axi_rlast,
    input  wire                    v0_axi_rvalid,
    output wire                    v0_axi_rready,

    output wire [ID_WIDTH-1:0]     v1_axi_arid,
    output wire [ADDR_WIDTH-1:0]   v1_axi_araddr,
    output wire [7:0]              v1_axi_arlen,
    output wire [2:0]              v1_axi_arsize,
    output wire [1:0]              v1_axi_arburst,
    output wire                    v1_axi_arlock,
    output wire [3:0]              v1_axi_arcache,
    output wire [2:0]              v1_axi_arprot,
    output wire [3:0]              v1_axi_arqos,
    output wire                    v1_axi_arvalid,
    input  wire                    v1_axi_arready,
    input  wire [ID_WIDTH-1:0]     v1_axi_rid,
    input  wire [63:0]             v1_axi_rdata,
    input  wire [1:0]              v1_axi_rresp,
    input  wire                    v1_axi_rlast,
    input  wire                    v1_axi_rvalid,
    output wire                    v1_axi_rready
);
    localparam [1:0] ERROR_SOURCE_PAIR = 2'd0;
    localparam [7:0] ERR_IDENTITY       = 8'he0;
    localparam [7:0] ERR_CHILD_ABORT    = 8'he1;
    localparam [7:0] ERR_EXTERNAL_ABORT = 8'he2;
    localparam [7:0] ERR_PROFILE        = 8'he3;
    localparam [7:0] ERR_K_CODEBOOK     = 8'he4;
    localparam [7:0] ERR_V_CODEBOOK     = 8'he5;

    wire k_cmd_ready_i, v_cmd_ready_i;
    wire k_page_valid_i, v_page_valid_i;
    wire k_page_active_i, v_page_active_i;
    wire k_busy_i, v_busy_i;
    wire k_flushing_i, v_flushing_i;
    wire k_sticky_i, v_sticky_i;
    wire [1:0] k_error_source_i, v_error_source_i;
    wire [7:0] k_error_code_i, v_error_code_i;
    wire k_error_phase_i, v_error_phase_i;
    wire [7:0] k_sticky_request_i, v_sticky_request_i;
    wire [15:0] k_sticky_layer_i, v_sticky_layer_i;
    wire [15:0] k_sticky_head_i, v_sticky_head_i;
    wire [15:0] k_sticky_profile_i, v_sticky_profile_i;
    wire [7:0] k_sticky_codebook_i, v_sticky_codebook_i;
    wire [4:0] k_sticky_page_i, v_sticky_page_i;
    wire k_row_abort_i, v_row_abort_i;
    wire k_reload_i, v_reload_i;

    wire [7:0] k_page_request_i, v_page_request_i;
    wire [15:0] k_page_layer_i, v_page_layer_i;
    wire [15:0] k_page_head_i, v_page_head_i;
    wire [15:0] k_page_profile_i, v_page_profile_i;
    wire [7:0] k_page_codebook_i, v_page_codebook_i;
    wire [4:0] k_page_index_i, v_page_index_i;
    wire [5:0] k_page_count_i, v_page_count_i;
    wire [12:0] k_page_token_base_i, v_page_token_base_i;
    wire [7:0] k_page_token_count_i, v_page_token_count_i;
    wire [14:0] k_page_symbols_i, v_page_symbols_i;
    wire k_page_raw_i, v_page_raw_i;
    wire k_page_stream_i, v_page_stream_i;
    wire [15:0] k_page_payload_i, v_page_payload_i;
    wire [7:0] k_page_scale_format_i, v_page_scale_format_i;
    wire [13:0] k_page_record_i, v_page_record_i;
    wire [13:0] k_page_window_i, v_page_window_i;
    wire [8:0] k_page_scale_bytes_i, v_page_scale_bytes_i;
    wire [13:0] k_page_padding_i, v_page_padding_i;
    wire k_data_rd_valid_i, k_scale_rd_valid_i;
    wire v_data_rd_valid_i, v_scale_rd_valid_i;

    wire command_identity_ok =
        (cmd_profile_id == COMPILED_PROFILE_ID[15:0]) &&
        (cmd_k_codebook_id == COMPILED_K_CODEBOOK_ID[7:0]) &&
        (cmd_v_codebook_id == COMPILED_V_CODEBOOK_ID[7:0]);

    wire children_drained = !k_busy_i && !v_busy_i &&
                            !k_flushing_i && !v_flushing_i &&
                            !k_page_valid_i && !v_page_valid_i &&
                            !k_page_active_i && !v_page_active_i;
    assign clear_ready = sticky_error && !flushing && !abort &&
                         children_drained;
    wire clear_fire = clear_fault && clear_ready;

    wire page_identity_match =
        (k_page_request_i == v_page_request_i) &&
        (k_page_layer_i == v_page_layer_i) &&
        (k_page_head_i == v_page_head_i) &&
        (k_page_profile_i == v_page_profile_i) &&
        (k_page_index_i == v_page_index_i) &&
        (k_page_count_i == v_page_count_i) &&
        (k_page_token_base_i == v_page_token_base_i) &&
        (k_page_token_count_i == v_page_token_count_i) &&
        (k_page_symbols_i == v_page_symbols_i) &&
        !k_page_stream_i && v_page_stream_i;
    wire comparable_heads = (k_page_valid_i && v_page_valid_i) ||
                            (k_page_active_i && v_page_active_i);
    wire identity_mismatch = comparable_heads && !page_identity_match;
    wire active_shape_mismatch = k_page_active_i ^ v_page_active_i;

    wire healthy = !abort && !flushing && !sticky_error &&
                   !k_sticky_i && !v_sticky_i && !identity_mismatch &&
                   !active_shape_mismatch;
    assign cmd_ready = healthy && k_cmd_ready_i && v_cmd_ready_i;
    wire cmd_fire = cmd_valid && cmd_ready;
    wire enqueue_fire = cmd_fire && command_identity_ok;

    assign page_valid = healthy && k_page_valid_i && v_page_valid_i &&
                        page_identity_match;
    wire page_fire = page_valid && page_ready;
    assign page_active = healthy && k_page_active_i && v_page_active_i &&
                         page_identity_match;
    wire release_fire = page_active && page_release;

    assign page_request_id = k_page_request_i;
    assign page_layer = k_page_layer_i;
    assign page_kv_head = k_page_head_i;
    assign page_profile_id = k_page_profile_i;
    assign page_k_codebook_id = k_page_codebook_i;
    assign page_v_codebook_id = v_page_codebook_i;
    assign page_index = k_page_index_i;
    assign page_count = k_page_count_i;
    assign page_token_base = k_page_token_base_i;
    assign page_token_count = k_page_token_count_i;
    assign page_expected_symbols = k_page_symbols_i;
    assign page_k_raw_mode = k_page_raw_i;
    assign page_v_raw_mode = v_page_raw_i;
    assign page_k_payload_bytes = k_page_payload_i;
    assign page_v_payload_bytes = v_page_payload_i;
    assign page_k_scale_format_id = k_page_scale_format_i;
    assign page_v_scale_format_id = v_page_scale_format_i;
    assign page_k_record_bytes = k_page_record_i;
    assign page_v_record_bytes = v_page_record_i;
    assign page_k_window_bytes = k_page_window_i;
    assign page_v_window_bytes = v_page_window_i;
    assign page_k_scale_slice_bytes = k_page_scale_bytes_i;
    assign page_v_scale_slice_bytes = v_page_scale_bytes_i;
    assign page_k_padding_bytes = k_page_padding_i;
    assign page_v_padding_bytes = v_page_padding_i;
    assign k_data_rd_valid = healthy && page_active && k_data_rd_valid_i;
    assign k_scale_rd_valid = healthy && page_active && k_scale_rd_valid_i;
    assign v_data_rd_valid = healthy && page_active && v_data_rd_valid_i;
    assign v_scale_rd_valid = healthy && page_active && v_scale_rd_valid_i;

    wire bad_command = cmd_fire && !command_identity_ok;
    wire child_sticky_fault = k_sticky_i || v_sticky_i;
    wire child_abort_fault = k_row_abort_i || v_row_abort_i;
    wire fault_event = !sticky_error && !flushing &&
        (bad_command || child_sticky_fault || identity_mismatch ||
         active_shape_mismatch || child_abort_fault || abort);

    // Abort is an initiating pulse/level, not the flush completion state.
    // Register internal fault kicks: combinationally feeding identity/error
    // visibility back into child abort would create a ready/valid loop.
    reg fault_abort_kick;
    wire pair_abort_i = abort || fault_abort_kick;

    assign busy = flushing || (pair_queue_count != 0) || k_busy_i || v_busy_i;
    reg [1:0] pair_queue_count;

    integer next_pair_count;
    always @(posedge clk) begin
        if (!rst_n) begin
            flushing <= 1'b0;
            sticky_error <= 1'b0;
            sticky_error_source <= 2'd0;
            sticky_error_code <= 8'd0;
            sticky_error_phase_is_scale <= 1'b0;
            sticky_fault_stream_is_v <= 1'b0;
            sticky_request_id <= 8'd0;
            sticky_layer <= 16'd0;
            sticky_kv_head <= 16'd0;
            sticky_profile_id <= 16'd0;
            sticky_codebook_id <= 8'd0;
            sticky_page_index <= 5'd0;
            row_abort <= 1'b0;
            reload_required <= 1'b0;
            fault_abort_kick <= 1'b0;
            pair_queue_count <= 2'd0;
            pair_commands <= 32'd0;
            pairs_published <= 32'd0;
            pairs_released <= 32'd0;
            pair_aborted_rows <= 32'd0;
            pair_starvation_cycles <= 32'd0;
            pair_fifo_high_water <= 2'd0;
        end else begin
            row_abort <= 1'b0;
            fault_abort_kick <= 1'b0;

            if (clear_counters) begin
                pair_commands <= 32'd0;
                pairs_published <= 32'd0;
                pairs_released <= 32'd0;
                pair_aborted_rows <= 32'd0;
                pair_starvation_cycles <= 32'd0;
                pair_fifo_high_water <= 2'd0;
            end else begin
                if (enqueue_fire)
                    pair_commands <= pair_commands + 1'b1;
                if (page_fire)
                    pairs_published <= pairs_published + 1'b1;
                if (release_fire)
                    pairs_released <= pairs_released + 1'b1;
                if (fault_event)
                    pair_aborted_rows <= pair_aborted_rows + 1'b1;
                if (consumer_need && !page_valid && !page_active && healthy)
                    pair_starvation_cycles <= pair_starvation_cycles + 1'b1;
                next_pair_count = pair_queue_count +
                                  (enqueue_fire ? 1 : 0) -
                                  (release_fire ? 1 : 0);
                if (next_pair_count > pair_fifo_high_water)
                    pair_fifo_high_water <= next_pair_count[1:0];
            end

            if (enqueue_fire)
                pair_queue_count <= pair_queue_count + 1'b1;
            if (release_fire)
                pair_queue_count <= pair_queue_count - 1'b1;

            if (fault_event) begin
                flushing <= 1'b1;
                sticky_error <= 1'b1;
                reload_required <= 1'b1;
                row_abort <= 1'b1;
                if (!bad_command)
                    fault_abort_kick <= 1'b1;
                sticky_error_source <= ERROR_SOURCE_PAIR;
                sticky_error_code <= ERR_CHILD_ABORT;
                sticky_error_phase_is_scale <= 1'b0;
                sticky_fault_stream_is_v <= 1'b0;
                sticky_request_id <= k_page_request_i;
                sticky_layer <= k_page_layer_i;
                sticky_kv_head <= k_page_head_i;
                sticky_profile_id <= k_page_profile_i;
                sticky_codebook_id <= k_page_codebook_i;
                sticky_page_index <= k_page_index_i;

                if (bad_command) begin
                    sticky_request_id <= cmd_request_id;
                    sticky_layer <= cmd_layer;
                    sticky_kv_head <= cmd_kv_head;
                    sticky_profile_id <= cmd_profile_id;
                    sticky_page_index <= cmd_page_index;
                    if (cmd_profile_id != COMPILED_PROFILE_ID[15:0]) begin
                        sticky_error_code <= ERR_PROFILE;
                        sticky_codebook_id <= cmd_k_codebook_id;
                    end else if (cmd_k_codebook_id !=
                                 COMPILED_K_CODEBOOK_ID[7:0]) begin
                        sticky_error_code <= ERR_K_CODEBOOK;
                        sticky_codebook_id <= cmd_k_codebook_id;
                    end else begin
                        sticky_error_code <= ERR_V_CODEBOOK;
                        sticky_codebook_id <= cmd_v_codebook_id;
                        sticky_fault_stream_is_v <= 1'b1;
                    end
                end else if (k_sticky_i) begin
                    sticky_error_source <= k_error_source_i;
                    sticky_error_code <= k_error_code_i;
                    sticky_error_phase_is_scale <= k_error_phase_i;
                    sticky_fault_stream_is_v <= 1'b0;
                    sticky_request_id <= k_sticky_request_i;
                    sticky_layer <= k_sticky_layer_i;
                    sticky_kv_head <= k_sticky_head_i;
                    sticky_profile_id <= k_sticky_profile_i;
                    sticky_codebook_id <= k_sticky_codebook_i;
                    sticky_page_index <= k_sticky_page_i;
                end else if (v_sticky_i) begin
                    sticky_error_source <= v_error_source_i;
                    sticky_error_code <= v_error_code_i;
                    sticky_error_phase_is_scale <= v_error_phase_i;
                    sticky_fault_stream_is_v <= 1'b1;
                    sticky_request_id <= v_sticky_request_i;
                    sticky_layer <= v_sticky_layer_i;
                    sticky_kv_head <= v_sticky_head_i;
                    sticky_profile_id <= v_sticky_profile_i;
                    sticky_codebook_id <= v_sticky_codebook_i;
                    sticky_page_index <= v_sticky_page_i;
                end else if (identity_mismatch || active_shape_mismatch) begin
                    sticky_error_code <= ERR_IDENTITY;
                end else if (abort) begin
                    sticky_error_code <= ERR_EXTERNAL_ABORT;
                end
            end

            if (flushing && !abort && children_drained) begin
                flushing <= 1'b0;
                pair_queue_count <= 2'd0;
            end

            if (clear_fire) begin
                sticky_error <= 1'b0;
                sticky_error_source <= 2'd0;
                sticky_error_code <= 8'd0;
                sticky_error_phase_is_scale <= 1'b0;
                sticky_fault_stream_is_v <= 1'b0;
                reload_required <= 1'b0;
            end
        end
    end

    kv_v03_page_pingpong #(
        .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH),
        .SCALE_BITS(SCALE_BITS), .STREAM_IS_V(0),
        .COMPILED_PROFILE_ID(COMPILED_PROFILE_ID),
        .COMPILED_CODEBOOK_ID(COMPILED_K_CODEBOOK_ID),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .MAX_PAGE_BYTES(MAX_PAGE_BYTES),
        .MAX_SCALE_BYTES(MAX_SCALE_BYTES)
    ) u_k (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(enqueue_fire), .cmd_ready(k_cmd_ready_i),
        .cmd_request_id(cmd_request_id), .cmd_layer(cmd_layer),
        .cmd_kv_head(cmd_kv_head), .cmd_profile_id(cmd_profile_id),
        .cmd_codebook_id(cmd_k_codebook_id),
        .cmd_page_index(cmd_page_index), .cmd_page_count(cmd_page_count),
        .cmd_token_base(cmd_token_base), .cmd_token_count(cmd_token_count),
        .cmd_expected_symbols(cmd_expected_symbols),
        .cmd_data_addr(cmd_k_data_addr), .cmd_data_limit(cmd_k_data_limit),
        .cmd_page_window_bytes(cmd_k_page_window_bytes),
        .cmd_scale_addr(cmd_k_scale_addr),
        .cmd_scale_slice_bytes(cmd_k_scale_slice_bytes),
        .abort(pair_abort_i), .clear_fault(clear_fire),
        .clear_counters(clear_counters),
        .page_valid(k_page_valid_i),
        .page_ready(page_fire), .page_active(k_page_active_i),
        .page_release(release_fire),
        .page_request_id(k_page_request_i), .page_layer(k_page_layer_i),
        .page_kv_head(k_page_head_i), .page_profile_id(k_page_profile_i),
        .page_codebook_id(k_page_codebook_i),
        .page_index(k_page_index_i), .page_count(k_page_count_i),
        .page_token_base(k_page_token_base_i),
        .page_token_count(k_page_token_count_i),
        .page_expected_symbols(k_page_symbols_i),
        .page_raw_mode(k_page_raw_i), .page_stream_is_v(k_page_stream_i),
        .page_payload_bytes(k_page_payload_i),
        .page_scale_format_id(k_page_scale_format_i),
        .page_record_bytes(k_page_record_i),
        .page_window_bytes(k_page_window_i),
        .page_scale_slice_bytes(k_page_scale_bytes_i),
        .page_padding_bytes(k_page_padding_i),
        .data_rd_en(k_data_rd_en && page_active),
        .data_rd_word_addr(k_data_rd_word_addr),
        .data_rd_valid(k_data_rd_valid_i), .data_rd_data(k_data_rd_data),
        .data_rd_byte_valid(k_data_rd_byte_valid),
        .data_rd_last(k_data_rd_last),
        .data_rd_byte_offset(k_data_rd_byte_offset),
        .scale_rd_en(k_scale_rd_en && page_active),
        .scale_rd_word_addr(k_scale_rd_word_addr),
        .scale_rd_valid(k_scale_rd_valid_i), .scale_rd_data(k_scale_rd_data),
        .scale_rd_byte_valid(k_scale_rd_byte_valid),
        .scale_rd_last(k_scale_rd_last),
        .scale_rd_byte_offset(k_scale_rd_byte_offset),
        .consumer_need(consumer_need), .busy(k_busy_i),
        .flushing(k_flushing_i), .sticky_error(k_sticky_i),
        .sticky_error_source(k_error_source_i),
        .sticky_error_code(k_error_code_i),
        .sticky_error_phase_is_scale(k_error_phase_i),
        .sticky_request_id(k_sticky_request_i),
        .sticky_layer(k_sticky_layer_i),
        .sticky_kv_head(k_sticky_head_i),
        .sticky_profile_id(k_sticky_profile_i),
        .sticky_codebook_id(k_sticky_codebook_i),
        .sticky_page_index(k_sticky_page_i),
        .row_abort(k_row_abort_i), .reload_required(k_reload_i),
        .prefetch_commands(k_prefetch_commands),
        .pages_published(k_pages_published),
        .pages_released(k_pages_released),
        .raw_fallback_pages(k_raw_fallback_pages),
        .integrity_faults(k_integrity_faults),
        .transport_faults(k_transport_faults),
        .aborted_rows(k_aborted_rows),
        .starvation_cycles(k_starvation_cycles),
        .fifo_high_water(k_fifo_high_water),
        .read_beats(k_read_beats), .burst_count(k_burst_count),
        .ar_stall_cycles(k_ar_stall_cycles),
        .r_wait_cycles(k_r_wait_cycles),
        .output_stall_cycles(k_output_stall_cycles),
        .m0_axi_arid(k0_axi_arid), .m0_axi_araddr(k0_axi_araddr),
        .m0_axi_arlen(k0_axi_arlen), .m0_axi_arsize(k0_axi_arsize),
        .m0_axi_arburst(k0_axi_arburst), .m0_axi_arlock(k0_axi_arlock),
        .m0_axi_arcache(k0_axi_arcache), .m0_axi_arprot(k0_axi_arprot),
        .m0_axi_arqos(k0_axi_arqos), .m0_axi_arvalid(k0_axi_arvalid),
        .m0_axi_arready(k0_axi_arready), .m0_axi_rid(k0_axi_rid),
        .m0_axi_rdata(k0_axi_rdata), .m0_axi_rresp(k0_axi_rresp),
        .m0_axi_rlast(k0_axi_rlast), .m0_axi_rvalid(k0_axi_rvalid),
        .m0_axi_rready(k0_axi_rready),
        .m1_axi_arid(k1_axi_arid), .m1_axi_araddr(k1_axi_araddr),
        .m1_axi_arlen(k1_axi_arlen), .m1_axi_arsize(k1_axi_arsize),
        .m1_axi_arburst(k1_axi_arburst), .m1_axi_arlock(k1_axi_arlock),
        .m1_axi_arcache(k1_axi_arcache), .m1_axi_arprot(k1_axi_arprot),
        .m1_axi_arqos(k1_axi_arqos), .m1_axi_arvalid(k1_axi_arvalid),
        .m1_axi_arready(k1_axi_arready), .m1_axi_rid(k1_axi_rid),
        .m1_axi_rdata(k1_axi_rdata), .m1_axi_rresp(k1_axi_rresp),
        .m1_axi_rlast(k1_axi_rlast), .m1_axi_rvalid(k1_axi_rvalid),
        .m1_axi_rready(k1_axi_rready)
    );

    kv_v03_page_pingpong #(
        .ADDR_WIDTH(ADDR_WIDTH), .ID_WIDTH(ID_WIDTH),
        .SCALE_BITS(SCALE_BITS), .STREAM_IS_V(1),
        .COMPILED_PROFILE_ID(COMPILED_PROFILE_ID),
        .COMPILED_CODEBOOK_ID(COMPILED_V_CODEBOOK_ID),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .MAX_PAGE_BYTES(MAX_PAGE_BYTES),
        .MAX_SCALE_BYTES(MAX_SCALE_BYTES)
    ) u_v (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(enqueue_fire), .cmd_ready(v_cmd_ready_i),
        .cmd_request_id(cmd_request_id), .cmd_layer(cmd_layer),
        .cmd_kv_head(cmd_kv_head), .cmd_profile_id(cmd_profile_id),
        .cmd_codebook_id(cmd_v_codebook_id),
        .cmd_page_index(cmd_page_index), .cmd_page_count(cmd_page_count),
        .cmd_token_base(cmd_token_base), .cmd_token_count(cmd_token_count),
        .cmd_expected_symbols(cmd_expected_symbols),
        .cmd_data_addr(cmd_v_data_addr), .cmd_data_limit(cmd_v_data_limit),
        .cmd_page_window_bytes(cmd_v_page_window_bytes),
        .cmd_scale_addr(cmd_v_scale_addr),
        .cmd_scale_slice_bytes(cmd_v_scale_slice_bytes),
        .abort(pair_abort_i), .clear_fault(clear_fire),
        .clear_counters(clear_counters),
        .page_valid(v_page_valid_i),
        .page_ready(page_fire), .page_active(v_page_active_i),
        .page_release(release_fire),
        .page_request_id(v_page_request_i), .page_layer(v_page_layer_i),
        .page_kv_head(v_page_head_i), .page_profile_id(v_page_profile_i),
        .page_codebook_id(v_page_codebook_i),
        .page_index(v_page_index_i), .page_count(v_page_count_i),
        .page_token_base(v_page_token_base_i),
        .page_token_count(v_page_token_count_i),
        .page_expected_symbols(v_page_symbols_i),
        .page_raw_mode(v_page_raw_i), .page_stream_is_v(v_page_stream_i),
        .page_payload_bytes(v_page_payload_i),
        .page_scale_format_id(v_page_scale_format_i),
        .page_record_bytes(v_page_record_i),
        .page_window_bytes(v_page_window_i),
        .page_scale_slice_bytes(v_page_scale_bytes_i),
        .page_padding_bytes(v_page_padding_i),
        .data_rd_en(v_data_rd_en && page_active),
        .data_rd_word_addr(v_data_rd_word_addr),
        .data_rd_valid(v_data_rd_valid_i), .data_rd_data(v_data_rd_data),
        .data_rd_byte_valid(v_data_rd_byte_valid),
        .data_rd_last(v_data_rd_last),
        .data_rd_byte_offset(v_data_rd_byte_offset),
        .scale_rd_en(v_scale_rd_en && page_active),
        .scale_rd_word_addr(v_scale_rd_word_addr),
        .scale_rd_valid(v_scale_rd_valid_i), .scale_rd_data(v_scale_rd_data),
        .scale_rd_byte_valid(v_scale_rd_byte_valid),
        .scale_rd_last(v_scale_rd_last),
        .scale_rd_byte_offset(v_scale_rd_byte_offset),
        .consumer_need(consumer_need), .busy(v_busy_i),
        .flushing(v_flushing_i), .sticky_error(v_sticky_i),
        .sticky_error_source(v_error_source_i),
        .sticky_error_code(v_error_code_i),
        .sticky_error_phase_is_scale(v_error_phase_i),
        .sticky_request_id(v_sticky_request_i),
        .sticky_layer(v_sticky_layer_i),
        .sticky_kv_head(v_sticky_head_i),
        .sticky_profile_id(v_sticky_profile_i),
        .sticky_codebook_id(v_sticky_codebook_i),
        .sticky_page_index(v_sticky_page_i),
        .row_abort(v_row_abort_i), .reload_required(v_reload_i),
        .prefetch_commands(v_prefetch_commands),
        .pages_published(v_pages_published),
        .pages_released(v_pages_released),
        .raw_fallback_pages(v_raw_fallback_pages),
        .integrity_faults(v_integrity_faults),
        .transport_faults(v_transport_faults),
        .aborted_rows(v_aborted_rows),
        .starvation_cycles(v_starvation_cycles),
        .fifo_high_water(v_fifo_high_water),
        .read_beats(v_read_beats), .burst_count(v_burst_count),
        .ar_stall_cycles(v_ar_stall_cycles),
        .r_wait_cycles(v_r_wait_cycles),
        .output_stall_cycles(v_output_stall_cycles),
        .m0_axi_arid(v0_axi_arid), .m0_axi_araddr(v0_axi_araddr),
        .m0_axi_arlen(v0_axi_arlen), .m0_axi_arsize(v0_axi_arsize),
        .m0_axi_arburst(v0_axi_arburst), .m0_axi_arlock(v0_axi_arlock),
        .m0_axi_arcache(v0_axi_arcache), .m0_axi_arprot(v0_axi_arprot),
        .m0_axi_arqos(v0_axi_arqos), .m0_axi_arvalid(v0_axi_arvalid),
        .m0_axi_arready(v0_axi_arready), .m0_axi_rid(v0_axi_rid),
        .m0_axi_rdata(v0_axi_rdata), .m0_axi_rresp(v0_axi_rresp),
        .m0_axi_rlast(v0_axi_rlast), .m0_axi_rvalid(v0_axi_rvalid),
        .m0_axi_rready(v0_axi_rready),
        .m1_axi_arid(v1_axi_arid), .m1_axi_araddr(v1_axi_araddr),
        .m1_axi_arlen(v1_axi_arlen), .m1_axi_arsize(v1_axi_arsize),
        .m1_axi_arburst(v1_axi_arburst), .m1_axi_arlock(v1_axi_arlock),
        .m1_axi_arcache(v1_axi_arcache), .m1_axi_arprot(v1_axi_arprot),
        .m1_axi_arqos(v1_axi_arqos), .m1_axi_arvalid(v1_axi_arvalid),
        .m1_axi_arready(v1_axi_arready), .m1_axi_rid(v1_axi_rid),
        .m1_axi_rdata(v1_axi_rdata), .m1_axi_rresp(v1_axi_rresp),
        .m1_axi_rlast(v1_axi_rlast), .m1_axi_rvalid(v1_axi_rvalid),
        .m1_axi_rready(v1_axi_rready)
    );

    wire unused = k_reload_i ^ v_reload_i;

`ifndef SYNTHESIS
    initial begin
        if (ADDR_WIDTH != 32)
            $error("kv_v03_kv_page_prefetch requires 32-bit Zybo addresses");
        if (SCALE_BITS != 12 && SCALE_BITS != 16)
            $error("kv_v03_kv_page_prefetch SCALE_BITS must be 12 or 16");
        if (COMPILED_PROFILE_ID < 0 || COMPILED_PROFILE_ID > 65535)
            $error("kv_v03_kv_page_prefetch profile ID must fit in 16 bits");
        if (COMPILED_K_CODEBOOK_ID < 0 ||
            COMPILED_K_CODEBOOK_ID > 255 ||
            COMPILED_V_CODEBOOK_ID < 0 ||
            COMPILED_V_CODEBOOK_ID > 255)
            $error("kv_v03_kv_page_prefetch codebook IDs must fit in 8 bits");
    end
`endif
endmodule

`default_nettype wire
