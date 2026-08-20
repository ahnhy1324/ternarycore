// kv_v03_raw_v5_axi_reader.v -- dense 128-lane signed-V5 AXI reader.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

// One command fetches exactly 80 bytes.  Byte address order maps directly to
// increasing vector_codes bit positions, so signed lane d occupies
// vector_codes[(5*d)+:5].  A vector is never published until every beat has
// passed the AXI ID/response/length checks.
module kv_v03_raw_v5_axi_reader #(
    parameter integer ADDR_WIDTH     = 32,
    parameter integer DATA_WIDTH     = 64,
    parameter integer ID_WIDTH       = 1,
    parameter integer TIMEOUT_CYCLES = 65536
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire                      cmd_valid,
    output wire                      cmd_ready,
    input  wire [ADDR_WIDTH-1:0]     cmd_addr,
    input  wire                      abort,

    output reg                       vector_valid,
    input  wire                      vector_ready,
    output reg  [639:0]              vector_codes,

    output wire                      busy,
    output wire                      draining,
    output reg                       aborted,
    output reg                       error,
    output reg  [7:0]                error_code,

    input  wire                      clear_counters,
    output reg  [31:0]               read_beats,
    output reg  [31:0]               ar_stall_cycles,
    output reg  [31:0]               r_stall_cycles,

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
    localparam integer VECTOR_BYTES   = 80;
    localparam integer BYTES_PER_BEAT = DATA_WIDTH / 8;
    localparam integer TOTAL_BEATS    = (VECTOR_BYTES * 8) / DATA_WIDTH;
    localparam integer BYTE_SHIFT     = $clog2(BYTES_PER_BEAT);

    localparam [2:0] ST_IDLE   = 3'd0,
                     ST_PREP   = 3'd1,
                     ST_AR     = 3'd2,
                     ST_R      = 3'd3,
                     ST_VECTOR = 3'd4,
                     ST_DRAIN  = 3'd5;

    // Reader-local typed failures.  Codes 0x10..0x1f are AXI transport
    // failures so a containing engine can preserve the low six bits.
    localparam [7:0] ERR_ALIGN         = 8'h01;
    localparam [7:0] ERR_ADDRESS_RANGE = 8'h02;
    localparam [7:0] ERR_AR_TIMEOUT    = 8'h10;
    localparam [7:0] ERR_R_TIMEOUT     = 8'h11;
    localparam [7:0] ERR_RID           = 8'h12;
    localparam [7:0] ERR_RRESP         = 8'h13;
    localparam [7:0] ERR_RLAST         = 8'h14;
    localparam [7:0] ERR_DRAIN_TIMEOUT = 8'h15;

    reg [2:0] state;
    reg [ADDR_WIDTH-1:0] next_addr;
    reg [3:0] global_beat;
    reg [8:0] chunk_beats;
    reg [8:0] chunk_beat;
    reg [31:0] timeout_count;
    reg drain_is_abort;
    reg drain_timeout_reported;

    wire ar_handshake = m_axi_arvalid && m_axi_arready;
    wire r_handshake = m_axi_rvalid && m_axi_rready;
    wire chunk_expected_last = (chunk_beat == chunk_beats - 1'b1);
    wire vector_expected_last = (global_beat == TOTAL_BEATS - 1);
    wire [ADDR_WIDTH:0] cmd_last_addr_ext =
        {1'b0, cmd_addr} + (VECTOR_BYTES - 1);

    // Addresses are beat aligned, so the floor division is always nonzero.
    // The 256-beat AXI limit is retained even though an 80-byte vector needs
    // only five or ten beats.
    function [8:0] choose_chunk_beats;
        input [3:0] beat_index;
        input [ADDR_WIDTH-1:0] address;
        integer beats_left;
        integer beats_to_4k;
        integer selected;
        begin
            beats_left = TOTAL_BEATS - beat_index;
            beats_to_4k = (4096 - address[11:0]) / BYTES_PER_BEAT;
            selected = beats_left;
            if (selected > beats_to_4k)
                selected = beats_to_4k;
            if (selected > 256)
                selected = 256;
            choose_chunk_beats = selected[8:0];
        end
    endfunction

    assign cmd_ready = (state == ST_IDLE) && !abort;
    assign busy = (state != ST_IDLE);
    assign draining = (state == ST_DRAIN);

    assign m_axi_arid    = {ID_WIDTH{1'b0}};
    assign m_axi_arsize  = BYTE_SHIFT;
    assign m_axi_arburst = 2'b01; // INCR
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0010; // normal, non-cacheable, bufferable
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;
    assign m_axi_rready  = (state == ST_R) || (state == ST_DRAIN);

    // Bus-use counters are lifetime counters unless explicitly cleared by the
    // containing diagnostic engine.  R stalls count cycles in which this
    // reader is ready and an accepted burst owes another beat.
    always @(posedge clk) begin
        if (!rst_n || clear_counters) begin
            read_beats      <= 32'd0;
            ar_stall_cycles <= 32'd0;
            r_stall_cycles  <= 32'd0;
        end else begin
            if (r_handshake)
                read_beats <= read_beats + 1'b1;
            if (m_axi_arvalid && !m_axi_arready)
                ar_stall_cycles <= ar_stall_cycles + 1'b1;
            if (m_axi_rready && !m_axi_rvalid)
                r_stall_cycles <= r_stall_cycles + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state                  <= ST_IDLE;
            vector_valid           <= 1'b0;
            vector_codes           <= 640'b0;
            aborted                <= 1'b0;
            error                  <= 1'b0;
            error_code             <= 8'b0;
            m_axi_araddr           <= {ADDR_WIDTH{1'b0}};
            m_axi_arlen            <= 8'b0;
            m_axi_arvalid          <= 1'b0;
            next_addr              <= {ADDR_WIDTH{1'b0}};
            global_beat            <= 4'b0;
            chunk_beats            <= 9'b0;
            chunk_beat             <= 9'b0;
            timeout_count          <= 32'b0;
            drain_is_abort         <= 1'b0;
            drain_timeout_reported <= 1'b0;
        end else begin
            aborted <= 1'b0;
            error   <= 1'b0;

            // AR cannot be cancelled after a same-cycle handshake.  Likewise,
            // an accepted R burst is drained through its observed RLAST before
            // an abort is acknowledged.
            if (abort && state != ST_IDLE && state != ST_DRAIN) begin
                vector_valid  <= 1'b0;
                m_axi_arvalid <= 1'b0;
                timeout_count <= 32'b0;
                if ((state == ST_AR && ar_handshake) || state == ST_R) begin
                    if (state == ST_R && r_handshake && m_axi_rlast) begin
                        state   <= ST_IDLE;
                        aborted <= 1'b1;
                    end else begin
                        state                  <= ST_DRAIN;
                        drain_is_abort         <= 1'b1;
                        drain_timeout_reported <= 1'b0;
                    end
                end else begin
                    state   <= ST_IDLE;
                    aborted <= 1'b1;
                end
            end else begin
                case (state)
                    ST_IDLE: begin
                        vector_valid  <= 1'b0;
                        m_axi_arvalid <= 1'b0;
                        timeout_count <= 32'b0;
                        if (cmd_valid && cmd_ready) begin
                            error_code  <= 8'b0;
                            vector_codes <= 640'b0;
                            global_beat <= 4'b0;
                            next_addr   <= cmd_addr;
                            if (cmd_addr[BYTE_SHIFT-1:0] != 0) begin
                                error      <= 1'b1;
                                error_code <= ERR_ALIGN;
                            end else if (cmd_last_addr_ext[ADDR_WIDTH]) begin
                                error      <= 1'b1;
                                error_code <= ERR_ADDRESS_RANGE;
                            end else begin
                                state <= ST_PREP;
                            end
                        end
                    end

                    ST_PREP: begin
                        chunk_beats   <= choose_chunk_beats(global_beat,
                                                            next_addr);
                        chunk_beat    <= 9'b0;
                        m_axi_araddr  <= next_addr;
                        m_axi_arlen   <= choose_chunk_beats(global_beat,
                                                            next_addr) - 1'b1;
                        m_axi_arvalid <= 1'b1;
                        timeout_count <= 32'b0;
                        state         <= ST_AR;
                    end

                    ST_AR: begin
                        if (ar_handshake) begin
                            m_axi_arvalid <= 1'b0;
                            timeout_count <= 32'b0;
                            state         <= ST_R;
                        end else if (timeout_count >= TIMEOUT_CYCLES-1) begin
                            m_axi_arvalid <= 1'b0;
                            timeout_count <= 32'b0;
                            error         <= 1'b1;
                            error_code    <= ERR_AR_TIMEOUT;
                            state         <= ST_IDLE;
                        end else begin
                            timeout_count <= timeout_count + 1'b1;
                        end
                    end

                    ST_R: begin
                        if (r_handshake) begin
                            timeout_count <= 32'b0;
                            if (m_axi_rid != {ID_WIDTH{1'b0}}) begin
                                vector_valid <= 1'b0;
                                error        <= 1'b1;
                                error_code   <= ERR_RID;
                                if (m_axi_rlast) begin
                                    state <= ST_IDLE;
                                end else begin
                                    state                  <= ST_DRAIN;
                                    drain_is_abort         <= 1'b0;
                                    drain_timeout_reported <= 1'b0;
                                end
                            end else if (m_axi_rresp != 2'b00) begin
                                vector_valid <= 1'b0;
                                error        <= 1'b1;
                                error_code   <= ERR_RRESP;
                                if (m_axi_rlast) begin
                                    state <= ST_IDLE;
                                end else begin
                                    state                  <= ST_DRAIN;
                                    drain_is_abort         <= 1'b0;
                                    drain_timeout_reported <= 1'b0;
                                end
                            end else if (m_axi_rlast !=
                                         chunk_expected_last) begin
                                vector_valid <= 1'b0;
                                error        <= 1'b1;
                                error_code   <= ERR_RLAST;
                                if (m_axi_rlast) begin
                                    // Early RLAST terminates the accepted
                                    // transaction; no drain remains.
                                    state <= ST_IDLE;
                                end else begin
                                    // A missing expected RLAST means the
                                    // slave still owns an unknown tail.
                                    state                  <= ST_DRAIN;
                                    drain_is_abort         <= 1'b0;
                                    drain_timeout_reported <= 1'b0;
                                end
                            end else begin
                                vector_codes[(global_beat*DATA_WIDTH)
                                             +: DATA_WIDTH] <= m_axi_rdata;
                                if (chunk_expected_last) begin
                                    if (vector_expected_last) begin
                                        vector_valid <= 1'b1;
                                        state        <= ST_VECTOR;
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
                        end else if (timeout_count >= TIMEOUT_CYCLES-1) begin
                            // The burst was accepted, so timeout reports the
                            // fault but keeps the reader poisoned/draining
                            // until an actual RLAST is observed.
                            vector_valid           <= 1'b0;
                            timeout_count          <= 32'b0;
                            error                  <= 1'b1;
                            error_code             <= ERR_R_TIMEOUT;
                            drain_is_abort         <= 1'b0;
                            drain_timeout_reported <= 1'b1;
                            state                  <= ST_DRAIN;
                        end else begin
                            timeout_count <= timeout_count + 1'b1;
                        end
                    end

                    ST_VECTOR: begin
                        if (vector_valid && vector_ready) begin
                            vector_valid <= 1'b0;
                            state        <= ST_IDLE;
                        end
                    end

                    ST_DRAIN: begin
                        // Discard every payload until the slave closes the
                        // one accepted transaction.  A timeout is reported
                        // once, but the interface stays fail-closed.
                        if (r_handshake) begin
                            timeout_count <= 32'b0;
                            if (m_axi_rlast) begin
                                state <= ST_IDLE;
                                if (drain_is_abort)
                                    aborted <= 1'b1;
                            end
                        end else if (!drain_timeout_reported &&
                                     timeout_count >= TIMEOUT_CYCLES-1) begin
                            timeout_count          <= 32'b0;
                            drain_is_abort         <= 1'b0;
                            drain_timeout_reported <= 1'b1;
                            error                  <= 1'b1;
                            error_code             <= ERR_DRAIN_TIMEOUT;
                        end else if (!drain_timeout_reported) begin
                            timeout_count <= timeout_count + 1'b1;
                        end
                    end

                    default: begin
                        state         <= ST_IDLE;
                        vector_valid  <= 1'b0;
                        m_axi_arvalid <= 1'b0;
                    end
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ADDR_WIDTH != 32)
            $error("kv_v03_raw_v5_axi_reader: ADDR_WIDTH must be 32");
        if (DATA_WIDTH != 64 && DATA_WIDTH != 128)
            $error("kv_v03_raw_v5_axi_reader: DATA_WIDTH must be 64 or 128");
        if (ID_WIDTH != 1)
            $error("kv_v03_raw_v5_axi_reader: ID_WIDTH must be 1");
        if ((VECTOR_BYTES * 8) % DATA_WIDTH != 0)
            $error("kv_v03_raw_v5_axi_reader: DATA_WIDTH must divide 640");
        if (TIMEOUT_CYCLES < 1)
            $error("kv_v03_raw_v5_axi_reader: TIMEOUT_CYCLES must be positive");
    end
`endif
endmodule

`default_nettype wire
