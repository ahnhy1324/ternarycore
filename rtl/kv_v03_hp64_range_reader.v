// kv_v03_hp64_range_reader.v -- tagged variable-length AXI4 HP reader.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// One command reads an aligned byte range and publishes it as tentative
// 64- or 128-bit beats.  DATA_WIDTH defaults to 64 so existing HP64 users
// retain their interface and behavior.  The caller must retain those beats
// in private scratch state
// until the tagged done pulse arrives and any higher-level page integrity
// checks pass.  A later transport fault can therefore invalidate all beats
// already accepted for the command without exposing a partial page.
module kv_v03_hp64_range_reader #(
    parameter integer ADDR_WIDTH     = 32,
    parameter integer DATA_WIDTH     = 64,
    parameter integer ID_WIDTH       = 1,
    parameter integer TAG_WIDTH      = 64,
    parameter integer TIMEOUT_CYCLES = 65536,
    parameter integer MAX_BYTES      = 10256
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire                      cmd_valid,
    output wire                      cmd_ready,
    input  wire [ADDR_WIDTH-1:0]     cmd_addr,
    input  wire [13:0]               cmd_bytes,
    input  wire [TAG_WIDTH-1:0]      cmd_tag,
    input  wire                      abort,

    output reg                       data_valid,
    input  wire                      data_ready,
    output reg  [DATA_WIDTH-1:0]     data,
    output reg  [(DATA_WIDTH/8)-1:0] data_keep,
    output reg                       data_last,
    output reg  [13:0]               data_byte_offset,
    output wire [TAG_WIDTH-1:0]      data_tag,

    output wire                      busy,
    output wire                      draining,
    output reg                       done,
    output reg  [TAG_WIDTH-1:0]      done_tag,
    output reg                       aborted,
    output reg  [TAG_WIDTH-1:0]      aborted_tag,
    output reg                       error_valid,
    output reg  [7:0]                error_code,
    output reg  [TAG_WIDTH-1:0]      error_tag,

    input  wire                      clear_counters,
    output reg  [31:0]               read_beats,
    output reg  [31:0]               burst_count,
    output reg  [31:0]               ar_stall_cycles,
    output reg  [31:0]               r_wait_cycles,
    output reg  [31:0]               output_stall_cycles,

    output wire [ID_WIDTH-1:0]       m_axi_arid,
    output reg  [ADDR_WIDTH-1:0]     m_axi_araddr,
    output reg  [7:0]                m_axi_arlen,
    output wire [2:0]                m_axi_arsize,
    output wire [1:0]                m_axi_arburst,
    output wire                      m_axi_arlock,
    output wire [3:0]                m_axi_arcache,
    output wire [2:0]                m_axi_arprot,
    output wire [3:0]                m_axi_arqos,
    output reg                       m_axi_arvalid,
    input  wire                      m_axi_arready,

    input  wire [ID_WIDTH-1:0]       m_axi_rid,
    input  wire [DATA_WIDTH-1:0]     m_axi_rdata,
    input  wire [1:0]                m_axi_rresp,
    input  wire                      m_axi_rlast,
    input  wire                      m_axi_rvalid,
    output wire                      m_axi_rready
);
    localparam integer BYTES_PER_BEAT = DATA_WIDTH / 8;
    localparam integer BYTE_SHIFT = $clog2(BYTES_PER_BEAT);
    localparam integer MAX_BURST_BEATS = 256;
    localparam [14:0] BEAT_ROUND_MASK = BYTES_PER_BEAT - 1;

    localparam [2:0] ST_IDLE      = 3'd0,
                     ST_PREP      = 3'd1,
                     ST_AR        = 3'd2,
                     ST_R         = 3'd3,
                     ST_LAST      = 3'd4,
                     ST_DRAIN     = 3'd5,
                     ST_POISON_AR = 3'd6;

    // Reader-local typed failures.  The transport codes deliberately match
    // kv_v03_raw_v5_axi_reader so a containing page controller can preserve
    // one error namespace.
    localparam [7:0] ERR_ALIGN         = 8'h01;
    localparam [7:0] ERR_ADDRESS_RANGE = 8'h02;
    localparam [7:0] ERR_LENGTH        = 8'h03;
    localparam [7:0] ERR_AR_TIMEOUT    = 8'h10;
    localparam [7:0] ERR_R_TIMEOUT     = 8'h11;
    localparam [7:0] ERR_RID           = 8'h12;
    localparam [7:0] ERR_RRESP         = 8'h13;
    localparam [7:0] ERR_RLAST         = 8'h14;
    localparam [7:0] ERR_DRAIN_TIMEOUT = 8'h15;

    localparam [13:0] MAX_BYTES_VALUE = MAX_BYTES;

    reg [2:0] state;
    reg [ADDR_WIDTH-1:0] next_addr;
    reg [13:0] bytes_reg;
    reg [TAG_WIDTH-1:0] tag_reg;
    reg [10:0] total_beats;
    reg [10:0] global_beat;
    reg [8:0] chunk_beats;
    reg [8:0] chunk_beat;
    reg [31:0] timeout_count;
    reg drain_is_abort;
    reg drain_timeout_reported;
    reg poison_is_abort;

    wire ar_handshake = m_axi_arvalid && m_axi_arready;
    wire r_handshake = m_axi_rvalid && m_axi_rready;
    wire data_handshake = data_valid && data_ready;
    wire chunk_expected_last = (chunk_beat == chunk_beats - 1'b1);
    wire range_expected_last = (global_beat == total_beats - 1'b1);
    wire [14:0] current_byte_offset_ext =
        {4'b0000, global_beat} << BYTE_SHIFT;
    wire [13:0] current_byte_offset = current_byte_offset_ext[13:0];
    wire [14:0] current_bytes_left =
        {1'b0, bytes_reg} - {1'b0, current_byte_offset};

    wire [14:0] cmd_rounded_bytes =
        (({1'b0, cmd_bytes} + BEAT_ROUND_MASK) >> BYTE_SHIFT) <<
        BYTE_SHIFT;
    wire [ADDR_WIDTH:0] cmd_last_addr_ext =
        {1'b0, cmd_addr} + cmd_rounded_bytes - 1'b1;

    function [BYTES_PER_BEAT-1:0] final_keep;
        input [5:0] valid_bytes;
        integer keep_index;
        begin
            final_keep = {BYTES_PER_BEAT{1'b0}};
            for (keep_index = 0; keep_index < BYTES_PER_BEAT;
                 keep_index = keep_index + 1)
                if (keep_index < valid_bytes)
                    final_keep[keep_index] = 1'b1;
        end
    endfunction

    wire [BYTES_PER_BEAT-1:0] current_keep =
        (current_bytes_left >= BYTES_PER_BEAT) ?
        {BYTES_PER_BEAT{1'b1}} : final_keep(current_bytes_left[5:0]);

    // Every address presented here is beat aligned, so beats_to_4k is at
    // least one.  ARLEN remains AXI4's beats-minus-one encoding.
    function [8:0] choose_chunk_beats;
        input [10:0] beat_index;
        input [10:0] beat_total;
        input [ADDR_WIDTH-1:0] address;
        integer beats_left;
        integer beats_to_4k;
        integer selected;
        begin
            beats_left = beat_total - beat_index;
            beats_to_4k = (4096 - address[11:0]) / BYTES_PER_BEAT;
            selected = beats_left;
            if (selected > beats_to_4k)
                selected = beats_to_4k;
            if (selected > MAX_BURST_BEATS)
                selected = MAX_BURST_BEATS;
            choose_chunk_beats = selected[8:0];
        end
    endfunction

    wire [8:0] selected_chunk =
        choose_chunk_beats(global_beat, total_beats, next_addr);

    assign cmd_ready = (state == ST_IDLE) && !abort;
    assign busy = (state != ST_IDLE);
    assign draining = (state == ST_DRAIN);
    assign data_tag = tag_reg;

    assign m_axi_arid    = {ID_WIDTH{1'b0}};
    assign m_axi_arsize  = BYTE_SHIFT;
    assign m_axi_arburst = 2'b01; // INCR
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0010; // normal, non-cacheable, bufferable
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;

    // A one-beat output skid buffer lets the caller apply backpressure.  Such
    // intentional backpressure neither advances nor times out the R channel.
    assign m_axi_rready = (state == ST_DRAIN) ||
                          ((state == ST_R) &&
                           (!data_valid || data_ready));

    // Lifetime transport counters.  Drained beats are physical bus traffic
    // and therefore remain part of read_beats/r_wait_cycles.
    always @(posedge clk) begin
        if (!rst_n || clear_counters) begin
            read_beats         <= 32'd0;
            burst_count        <= 32'd0;
            ar_stall_cycles    <= 32'd0;
            r_wait_cycles      <= 32'd0;
            output_stall_cycles <= 32'd0;
        end else begin
            if (r_handshake)
                read_beats <= read_beats + 1'b1;
            if (ar_handshake)
                burst_count <= burst_count + 1'b1;
            if (m_axi_arvalid && !m_axi_arready)
                ar_stall_cycles <= ar_stall_cycles + 1'b1;
            if (m_axi_rready && !m_axi_rvalid)
                r_wait_cycles <= r_wait_cycles + 1'b1;
            if (data_valid && !data_ready)
                output_stall_cycles <= output_stall_cycles + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state                  <= ST_IDLE;
            next_addr              <= {ADDR_WIDTH{1'b0}};
            bytes_reg              <= 14'd0;
            tag_reg                <= {TAG_WIDTH{1'b0}};
            total_beats            <= 11'd0;
            global_beat            <= 11'd0;
            chunk_beats            <= 9'd0;
            chunk_beat             <= 9'd0;
            timeout_count          <= 32'd0;
            drain_is_abort         <= 1'b0;
            drain_timeout_reported <= 1'b0;
            poison_is_abort        <= 1'b0;

            data_valid             <= 1'b0;
            data                   <= {DATA_WIDTH{1'b0}};
            data_keep              <= {BYTES_PER_BEAT{1'b0}};
            data_last              <= 1'b0;
            data_byte_offset       <= 14'd0;

            done                   <= 1'b0;
            done_tag               <= {TAG_WIDTH{1'b0}};
            aborted                <= 1'b0;
            aborted_tag            <= {TAG_WIDTH{1'b0}};
            error_valid            <= 1'b0;
            error_code             <= 8'd0;
            error_tag              <= {TAG_WIDTH{1'b0}};

            m_axi_araddr           <= {ADDR_WIDTH{1'b0}};
            m_axi_arlen            <= 8'd0;
            m_axi_arvalid          <= 1'b0;
        end else begin
            done        <= 1'b0;
            aborted     <= 1'b0;
            error_valid <= 1'b0;

            if (data_handshake)
                data_valid <= 1'b0;

            // Once AR is accepted, cancellation is impossible.  Abort drops
            // all tentative output and drains the owned transaction through
            // its observed RLAST before acknowledging the abort.
            if (abort && state != ST_IDLE && state != ST_DRAIN &&
                state != ST_POISON_AR) begin
                data_valid    <= 1'b0;
                timeout_count <= 32'd0;
                if (state == ST_AR) begin
                    if (ar_handshake) begin
                        m_axi_arvalid          <= 1'b0;
                        state                  <= ST_DRAIN;
                        drain_is_abort         <= 1'b1;
                        drain_timeout_reported <= 1'b0;
                    end else begin
                        // AXI requires VALID and its payload to remain stable
                        // until READY.  Poison the command, but do not retract
                        // its already-presented address request.
                        state           <= ST_POISON_AR;
                        poison_is_abort <= 1'b1;
                    end
                end else if (state == ST_R) begin
                    if (r_handshake && m_axi_rlast) begin
                        state       <= ST_IDLE;
                        aborted     <= 1'b1;
                        aborted_tag <= tag_reg;
                    end else begin
                        state                  <= ST_DRAIN;
                        drain_is_abort         <= 1'b1;
                        drain_timeout_reported <= 1'b0;
                    end
                end else begin
                    m_axi_arvalid <= 1'b0;
                    state       <= ST_IDLE;
                    aborted     <= 1'b1;
                    aborted_tag <= tag_reg;
                end
            end else begin
                case (state)
                    ST_IDLE: begin
                        data_valid             <= 1'b0;
                        m_axi_arvalid          <= 1'b0;
                        timeout_count          <= 32'd0;
                        drain_is_abort         <= 1'b0;
                        drain_timeout_reported <= 1'b0;
                        poison_is_abort        <= 1'b0;
                        if (cmd_valid && cmd_ready) begin
                            tag_reg       <= cmd_tag;
                            bytes_reg     <= cmd_bytes;
                            next_addr     <= cmd_addr;
                            total_beats   <=
                                ({1'b0, cmd_bytes} + BEAT_ROUND_MASK) >>
                                BYTE_SHIFT;
                            global_beat   <= 11'd0;
                            chunk_beats   <= 9'd0;
                            chunk_beat    <= 9'd0;
                            error_code    <= 8'd0;
                            if (cmd_addr[BYTE_SHIFT-1:0] !=
                                {BYTE_SHIFT{1'b0}}) begin
                                error_valid <= 1'b1;
                                error_code  <= ERR_ALIGN;
                                error_tag   <= cmd_tag;
                            end else if (cmd_bytes == 0 ||
                                         cmd_bytes > MAX_BYTES_VALUE) begin
                                error_valid <= 1'b1;
                                error_code  <= ERR_LENGTH;
                                error_tag   <= cmd_tag;
                            end else if (cmd_last_addr_ext[ADDR_WIDTH]) begin
                                error_valid <= 1'b1;
                                error_code  <= ERR_ADDRESS_RANGE;
                                error_tag   <= cmd_tag;
                            end else begin
                                state <= ST_PREP;
                            end
                        end
                    end

                    ST_PREP: begin
                        chunk_beats   <= selected_chunk;
                        chunk_beat    <= 9'd0;
                        m_axi_araddr  <= next_addr;
                        m_axi_arlen   <= selected_chunk - 1'b1;
                        m_axi_arvalid <= 1'b1;
                        timeout_count <= 32'd0;
                        state         <= ST_AR;
                    end

                    ST_AR: begin
                        if (ar_handshake) begin
                            m_axi_arvalid <= 1'b0;
                            timeout_count <= 32'd0;
                            state         <= ST_R;
                        end else if (timeout_count >= TIMEOUT_CYCLES-1) begin
                            data_valid    <= 1'b0;
                            timeout_count <= 32'd0;
                            error_valid   <= 1'b1;
                            error_code    <= ERR_AR_TIMEOUT;
                            error_tag     <= tag_reg;
                            // ARVALID cannot be withdrawn before a handshake.
                            // Report the timeout once and wait indefinitely;
                            // reset is the only escape if READY never returns.
                            poison_is_abort <= 1'b0;
                            state           <= ST_POISON_AR;
                        end else begin
                            timeout_count <= timeout_count + 1'b1;
                        end
                    end

                    ST_POISON_AR: begin
                        data_valid <= 1'b0;
                        if (ar_handshake) begin
                            m_axi_arvalid          <= 1'b0;
                            timeout_count          <= 32'd0;
                            state                  <= ST_DRAIN;
                            drain_is_abort         <= poison_is_abort;
                            drain_timeout_reported <= 1'b0;
                            poison_is_abort        <= 1'b0;
                        end
                    end

                    ST_R: begin
                        if (r_handshake) begin
                            timeout_count <= 32'd0;
                            if (m_axi_rid != {ID_WIDTH{1'b0}}) begin
                                data_valid  <= 1'b0;
                                error_valid <= 1'b1;
                                error_code  <= ERR_RID;
                                error_tag   <= tag_reg;
                                if (m_axi_rlast) begin
                                    state <= ST_IDLE;
                                end else begin
                                    state                  <= ST_DRAIN;
                                    drain_is_abort         <= 1'b0;
                                    drain_timeout_reported <= 1'b0;
                                end
                            end else if (m_axi_rresp != 2'b00) begin
                                data_valid  <= 1'b0;
                                error_valid <= 1'b1;
                                error_code  <= ERR_RRESP;
                                error_tag   <= tag_reg;
                                if (m_axi_rlast) begin
                                    state <= ST_IDLE;
                                end else begin
                                    state                  <= ST_DRAIN;
                                    drain_is_abort         <= 1'b0;
                                    drain_timeout_reported <= 1'b0;
                                end
                            end else if (m_axi_rlast !=
                                         chunk_expected_last) begin
                                data_valid  <= 1'b0;
                                error_valid <= 1'b1;
                                error_code  <= ERR_RLAST;
                                error_tag   <= tag_reg;
                                if (m_axi_rlast) begin
                                    // Early RLAST closes the transaction.
                                    state <= ST_IDLE;
                                end else begin
                                    // Missing expected RLAST leaves an
                                    // unknown transaction tail to discard.
                                    state                  <= ST_DRAIN;
                                    drain_is_abort         <= 1'b0;
                                    drain_timeout_reported <= 1'b0;
                                end
                            end else begin
                                data             <= m_axi_rdata;
                                data_keep        <= current_keep;
                                data_last        <= range_expected_last;
                                data_byte_offset <= current_byte_offset;
                                data_valid       <= 1'b1;
                                if (chunk_expected_last) begin
                                    if (range_expected_last) begin
                                        state <= ST_LAST;
                                    end else begin
                                        global_beat <= global_beat + 1'b1;
                                        next_addr <= next_addr +
                                            (chunk_beats * BYTES_PER_BEAT);
                                        state <= ST_PREP;
                                    end
                                end else begin
                                    global_beat <= global_beat + 1'b1;
                                    chunk_beat  <= chunk_beat + 1'b1;
                                end
                            end
                        end else if (m_axi_rready) begin
                            if (timeout_count >= TIMEOUT_CYCLES-1) begin
                                data_valid             <= 1'b0;
                                timeout_count          <= 32'd0;
                                error_valid            <= 1'b1;
                                error_code             <= ERR_R_TIMEOUT;
                                error_tag              <= tag_reg;
                                drain_is_abort         <= 1'b0;
                                drain_timeout_reported <= 1'b1;
                                state                  <= ST_DRAIN;
                            end else begin
                                timeout_count <= timeout_count + 1'b1;
                            end
                        end
                    end

                    ST_LAST: begin
                        if (data_handshake) begin
                            data_valid <= 1'b0;
                            done       <= 1'b1;
                            done_tag   <= tag_reg;
                            state      <= ST_IDLE;
                        end
                    end

                    ST_DRAIN: begin
                        data_valid    <= 1'b0;
                        m_axi_arvalid <= 1'b0;
                        if (r_handshake) begin
                            timeout_count <= 32'd0;
                            if (m_axi_rlast) begin
                                state <= ST_IDLE;
                                if (drain_is_abort) begin
                                    aborted     <= 1'b1;
                                    aborted_tag <= tag_reg;
                                end
                                drain_is_abort         <= 1'b0;
                                drain_timeout_reported <= 1'b0;
                            end
                        end else if (!drain_timeout_reported) begin
                            if (timeout_count >= TIMEOUT_CYCLES-1) begin
                                timeout_count          <= 32'd0;
                                drain_is_abort         <= 1'b0;
                                drain_timeout_reported <= 1'b1;
                                error_valid            <= 1'b1;
                                error_code             <= ERR_DRAIN_TIMEOUT;
                                error_tag              <= tag_reg;
                            end else begin
                                timeout_count <= timeout_count + 1'b1;
                            end
                        end
                    end

                    default: begin
                        state         <= ST_IDLE;
                        data_valid    <= 1'b0;
                        m_axi_arvalid <= 1'b0;
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ADDR_WIDTH != 32)
            $error("kv_v03_hp64_range_reader: ADDR_WIDTH must be 32");
        if (ID_WIDTH != 1)
            $error("kv_v03_hp64_range_reader: ID_WIDTH must be 1");
        if (DATA_WIDTH != 64 && DATA_WIDTH != 128)
            $error("kv_v03_hp64_range_reader: DATA_WIDTH must be 64 or 128");
        if (TAG_WIDTH < 1)
            $error("kv_v03_hp64_range_reader: TAG_WIDTH must be positive");
        if (TIMEOUT_CYCLES < 1)
            $error("kv_v03_hp64_range_reader: TIMEOUT_CYCLES must be positive");
        if (MAX_BYTES < 1 || MAX_BYTES > 16383)
            $error("kv_v03_hp64_range_reader: MAX_BYTES must be 1..16383");
    end
`endif
endmodule

`default_nettype wire
