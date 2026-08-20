// tb_axi_v5_av_diag.v -- raw-V5 DDR to AV-numerator AXI integration.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module tb_axi_v5_av_diag;
`ifdef AXI_DATA_WIDTH_VAL
    localparam integer AXI_WIDTH = `AXI_DATA_WIDTH_VAL;
`else
    localparam integer AXI_WIDTH = 64;
`endif
    localparam integer AXI_BYTES = AXI_WIDTH / 8;
    localparam integer AXI_SIZE = $clog2(AXI_BYTES);
    localparam integer MAX_CONTEXT = 128;
    localparam integer TIMEOUT_CYCLES = 32;
    localparam [31:0] DEFAULT_V_BASE = 32'h0200_0000;
    localparam [31:0] SPLIT_V_BASE   = 32'h0200_0fc0;

    localparam [15:0] REG_CTRL        = 16'h0000;
    localparam [15:0] REG_STATUS      = 16'h0004;
    localparam [15:0] REG_V_BASE_LO   = 16'h0008;
    localparam [15:0] REG_V_BASE_HI   = 16'h000c;
    localparam [15:0] REG_EXP_COUNT   = 16'h0014;
    localparam [15:0] REG_SCALE_COUNT = 16'h0018;
    localparam [15:0] REG_CONTEXT     = 16'h001c;
    localparam [15:0] REG_PROGRESS    = 16'h0020;
    localparam [15:0] REG_PERF        = 16'h0028;
    localparam [15:0] REG_ERROR       = 16'h002c;
    localparam [15:0] REG_ID          = 16'h0030;
    localparam [15:0] REG_GEOMETRY    = 16'h0034;
    localparam [15:0] REG_V_STRIDE    = 16'h0038;
    localparam [15:0] REG_CAPS        = 16'h003c;
    localparam [15:0] REG_READ_BEATS  = 16'h0040;
    localparam [15:0] REG_AR_STALLS   = 16'h0044;
    localparam [15:0] REG_R_STALLS    = 16'h0048;
    localparam [15:0] REG_SCALE_FMT   = 16'h004c;
    localparam [15:0] RESULT_BASE     = 16'h1000;
    localparam [15:0] EXP_BASE        = 16'h3000;
    localparam [15:0] SCALE_BASE      = 16'h4000;

    localparam integer FAULT_NONE       = 0;
    localparam integer FAULT_RRESP      = 1;
    localparam integer FAULT_RLAST_EARLY= 2;
    localparam integer FAULT_RLAST_LATE = 3;
    localparam integer FAULT_AR_TIMEOUT = 4;
    localparam integer FAULT_R_TIMEOUT  = 5;

    // Engine transport error codes.  These are deliberately checked at the
    // software-visible wrapper rather than through hierarchical references.
    localparam [7:0] ERR_AR_TIMEOUT = 8'h10;
    localparam [7:0] ERR_R_TIMEOUT  = 8'h11;
    localparam [7:0] ERR_RRESP      = 8'h13;
    localparam [7:0] ERR_RLAST      = 8'h14;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [15:0] s_axi_awaddr = 16'd0;
    reg  [2:0]  s_axi_awprot = 3'd0;
    reg         s_axi_awvalid = 1'b0;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata = 32'd0;
    reg  [3:0]  s_axi_wstrb = 4'd0;
    reg         s_axi_wvalid = 1'b0;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready = 1'b0;
    reg  [15:0] s_axi_araddr = 16'd0;
    reg  [2:0]  s_axi_arprot = 3'd0;
    reg         s_axi_arvalid = 1'b0;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready = 1'b0;

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
    reg  m_axi_arready = 1'b0;
    reg  [0:0] m_axi_rid = 1'b0;
    reg  [AXI_WIDTH-1:0] m_axi_rdata = {AXI_WIDTH{1'b0}};
    reg  [1:0] m_axi_rresp = 2'b00;
    reg  m_axi_rlast = 1'b0;
    reg  m_axi_rvalid = 1'b0;
    wire m_axi_rready;

    axi_v5_av_diag #(
        .MAX_CONTEXT(MAX_CONTEXT),
        .MULT_STYLE(2),
        .M_AXI_DATA_WIDTH(AXI_WIDTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
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

    reg [4:0]  v_codes [0:(MAX_CONTEXT*128)-1];
    reg [11:0] v_scales [0:MAX_CONTEXT-1];
    reg [15:0] exp_codes [0:(MAX_CONTEXT*4)-1];
    reg [47:0] expected [0:511];
    reg [7:0]  packed_v [0:(MAX_CONTEXT*80)-1];
    string golden_root;

    integer errors = 0;
    integer write_sequence = 0;
    integer current_context = 0;
    integer current_v_bytes = 0;
    reg [31:0] current_v_base = DEFAULT_V_BASE;

    // Byte-addressed DDR read model.  It intentionally supports only the
    // currently programmed dense V5 span, so any accidental scale/exp DDR
    // fetch or over-read is an immediate test failure.
    reg burst_active = 1'b0;
    reg [31:0] burst_addr = 32'd0;
    integer burst_beats = 0;
    integer burst_beat = 0;
    integer fault_mode = FAULT_NONE;
    reg fault_sent = 1'b0;
    reg [15:0] ddr_lfsr = 16'hd37a;
    integer ar_holdoff = 0;
    integer model_ar_count = 0;
    integer model_read_beats = 0;
    integer model_ar_stalls = 0;
    integer model_r_waits = 0;
    integer model_bad_addresses = 0;
    reg saw_base_page = 1'b0;
    reg saw_next_page = 1'b0;
    integer byte_lane;
    integer byte_offset;
    integer burst_byte_count;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0;
            m_axi_rvalid <= 1'b0;
            m_axi_rdata <= {AXI_WIDTH{1'b0}};
            m_axi_rresp <= 2'b00;
            m_axi_rlast <= 1'b0;
            burst_active <= 1'b0;
            burst_addr <= 32'd0;
            burst_beats <= 0;
            burst_beat <= 0;
            fault_sent <= 1'b0;
            ddr_lfsr <= 16'hd37a;
            ar_holdoff <= 0;
        end else begin
            ddr_lfsr <= {ddr_lfsr[14:0],
                         ddr_lfsr[15] ^ ddr_lfsr[13] ^
                         ddr_lfsr[12] ^ ddr_lfsr[10]};

            if (m_axi_arvalid && !m_axi_arready)
                model_ar_stalls = model_ar_stalls + 1;
            if (burst_active && !m_axi_rvalid)
                model_r_waits = model_r_waits + 1;

            if (fault_mode == FAULT_AR_TIMEOUT) begin
                m_axi_arready <= 1'b0;
            end else if (burst_active || m_axi_rvalid) begin
                m_axi_arready <= 1'b0;
            end else if (m_axi_arvalid && ar_holdoff < 2) begin
                // Every address request is held for two cycles, then gets a
                // randomized additional delay.  This makes the stall counter
                // non-zero and deterministic enough to audit exactly.
                m_axi_arready <= 1'b0;
                ar_holdoff <= ar_holdoff + 1;
            end else begin
                m_axi_arready <= ddr_lfsr[0] | ddr_lfsr[3];
            end

            if (m_axi_arvalid && m_axi_arready) begin
                model_ar_count = model_ar_count + 1;
                ar_holdoff <= 0;
                burst_active <= 1'b1;
                burst_addr <= m_axi_araddr;
                burst_beats <= m_axi_arlen + 1;
                burst_beat <= 0;
                burst_byte_count = (m_axi_arlen + 1) * AXI_BYTES;

                if (m_axi_arid !== 0 || m_axi_arsize !== AXI_SIZE[2:0] ||
                    m_axi_arburst !== 2'b01 || m_axi_arlock !== 1'b0) begin
                    $display("FAIL illegal AXI AR attributes id=%0d size=%0d burst=%0d lock=%0d",
                             m_axi_arid, m_axi_arsize, m_axi_arburst,
                             m_axi_arlock);
                    errors = errors + 1;
                end
                if ((m_axi_araddr % AXI_BYTES) != 0) begin
                    $display("FAIL unaligned V ARADDR %08x width=%0d",
                             m_axi_araddr, AXI_WIDTH);
                    errors = errors + 1;
                end
                if (m_axi_araddr[11:0] + burst_byte_count > 4096) begin
                    $display("FAIL AXI burst crosses 4KiB addr=%08x len=%0d",
                             m_axi_araddr, m_axi_arlen);
                    errors = errors + 1;
                end
                if (m_axi_araddr < current_v_base ||
                    m_axi_araddr + burst_byte_count >
                        current_v_base + current_v_bytes) begin
                    $display("FAIL AXI read outside dense V span addr=%08x bytes=%0d span=%08x..%08x",
                             m_axi_araddr, burst_byte_count, current_v_base,
                             current_v_base + current_v_bytes);
                    errors = errors + 1;
                    model_bad_addresses = model_bad_addresses + 1;
                end
                if (m_axi_araddr[31:12] == current_v_base[31:12])
                    saw_base_page <= 1'b1;
                if (m_axi_araddr[31:12] == current_v_base[31:12] + 1'b1)
                    saw_next_page <= 1'b1;
            end

            if (!m_axi_rvalid && burst_active &&
                fault_mode != FAULT_R_TIMEOUT &&
                (ddr_lfsr[2:1] != 2'b00)) begin
                for (byte_lane = 0; byte_lane < AXI_BYTES;
                     byte_lane = byte_lane + 1) begin
                    byte_offset = burst_addr + burst_beat*AXI_BYTES +
                                  byte_lane - current_v_base;
                    if (byte_offset >= 0 && byte_offset < current_v_bytes)
                        m_axi_rdata[(byte_lane*8) +: 8] <= packed_v[byte_offset];
                    else
                        m_axi_rdata[(byte_lane*8) +: 8] <= 8'h00;
                end
                m_axi_rresp <= 2'b00;
                m_axi_rlast <= (burst_beat == burst_beats-1);
                if (!fault_sent && fault_mode == FAULT_RRESP) begin
                    m_axi_rresp <= 2'b10;
                    fault_sent <= 1'b1;
                end else if (!fault_sent &&
                             fault_mode == FAULT_RLAST_EARLY &&
                             burst_beats > 1) begin
                    m_axi_rlast <= 1'b1;
                    fault_sent <= 1'b1;
                end else if (!fault_sent &&
                             fault_mode == FAULT_RLAST_LATE &&
                             burst_beat == burst_beats-1) begin
                    m_axi_rlast <= 1'b0;
                    fault_sent <= 1'b1;
                end
                m_axi_rvalid <= 1'b1;
            end

            if (m_axi_rvalid && m_axi_rready) begin
                model_read_beats = model_read_beats + 1;
                m_axi_rvalid <= 1'b0;
                m_axi_rresp <= 2'b00;
                if (burst_beat == burst_beats-1 &&
                    fault_mode == FAULT_RLAST_LATE &&
                    fault_sent && !m_axi_rlast) begin
                    // The malformed expected-last beat is followed by one
                    // explicit RLAST so the reader can drain the poisoned AXI
                    // transaction and return to a restartable idle state.
                    burst_beats <= burst_beats + 1;
                    burst_beat <= burst_beat + 1;
                end else if (burst_beat == burst_beats-1 || m_axi_rlast) begin
                    burst_active <= 1'b0;
                    m_axi_rlast <= 1'b0;
                end else begin
                    burst_beat <= burst_beat + 1;
                end
            end
        end
    end

    task send_aw;
        input [15:0] addr;
        integer guard;
        begin
            @(negedge clk);
            s_axi_awaddr = addr;
            s_axi_awvalid = 1'b1;
            guard = 0;
            while (!s_axi_awready && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_awready)
                $fatal(1, "AXI-Lite AW timeout addr=%04x", addr);
            @(posedge clk);
            @(negedge clk);
            s_axi_awvalid = 1'b0;
        end
    endtask

    task send_w;
        input [31:0] data;
        input [3:0] strobe;
        integer guard;
        begin
            @(negedge clk);
            s_axi_wdata = data;
            s_axi_wstrb = strobe;
            s_axi_wvalid = 1'b1;
            guard = 0;
            while (!s_axi_wready && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_wready)
                $fatal(1, "AXI-Lite W timeout data=%08x", data);
            @(posedge clk);
            @(negedge clk);
            s_axi_wvalid = 1'b0;
            s_axi_wstrb = 4'd0;
        end
    endtask

    task axi_write;
        input [15:0] addr;
        input [31:0] data;
        integer gap;
        integer guard;
        begin
            // Alternate AW-first and W-first to prove independent channels.
            if ((write_sequence & 1) == 0) begin
                send_aw(addr);
                gap = write_sequence % 3;
                repeat (gap) @(negedge clk);
                send_w(data, 4'hf);
            end else begin
                send_w(data, 4'hf);
                gap = write_sequence % 3;
                repeat (gap) @(negedge clk);
                send_aw(addr);
            end
            write_sequence = write_sequence + 1;
            @(negedge clk);
            s_axi_bready = 1'b1;
            guard = 0;
            while (!s_axi_bvalid && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_bvalid)
                $fatal(1, "AXI-Lite B timeout addr=%04x", addr);
            if (s_axi_bresp !== 2'b00) begin
                $display("FAIL AXI-Lite BRESP addr=%04x resp=%0d",
                         addr, s_axi_bresp);
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task axi_read;
        input [15:0] addr;
        output [31:0] data;
        integer guard;
        integer ready_gap;
        begin
            @(negedge clk);
            s_axi_araddr = addr;
            s_axi_arvalid = 1'b1;
            guard = 0;
            while (!s_axi_arready && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_arready)
                $fatal(1, "AXI-Lite AR timeout addr=%04x", addr);
            @(posedge clk);
            @(negedge clk);
            s_axi_arvalid = 1'b0;

            ready_gap = ddr_lfsr[1:0];
            repeat (ready_gap) @(negedge clk);
            s_axi_rready = 1'b1;
            guard = 0;
            while (!s_axi_rvalid && guard < 100) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!s_axi_rvalid)
                $fatal(1, "AXI-Lite R timeout addr=%04x", addr);
            #1 data = s_axi_rdata;
            if (s_axi_rresp !== 2'b00) begin
                $display("FAIL AXI-Lite RRESP addr=%04x resp=%0d",
                         addr, s_axi_rresp);
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    task expect_reg;
        input [15:0] addr;
        input [31:0] wanted;
        input string label_text;
        reg [31:0] got;
        begin
            axi_read(addr, got);
            if (got !== wanted) begin
                $display("FAIL %s got=%08x want=%08x",
                         label_text, got, wanted);
                errors = errors + 1;
            end
        end
    endtask

    task load_case;
        input string case_name;
        input integer length;
        input [31:0] v_base;
        integer code_index;
        integer packed_index;
        integer bit_index;
        begin
            $readmemh({golden_root, "/", case_name, "/v_codes_s5.hex"},
                      v_codes, 0, length*128-1);
            $readmemh({golden_root, "/", case_name, "/v_scales_u12.hex"},
                      v_scales, 0, length-1);
            $readmemh({golden_root, "/", case_name, "/exp_h4_u16.hex"},
                      exp_codes, 0, length*4-1);
            $readmemh({golden_root, "/", case_name,
                       "/expected_numerators_s48.hex"},
                      expected, 0, 511);

            current_context = length;
            current_v_bytes = length * 80;
            current_v_base = v_base;
            for (packed_index = 0; packed_index < length*80;
                 packed_index = packed_index + 1)
                packed_v[packed_index] = 8'd0;
            // Signed values are stored as raw two's-complement 5-bit codes,
            // contiguous and LSB-first.  One 128-lane row is exactly 80 B.
            for (code_index = 0; code_index < length*128;
                 code_index = code_index + 1)
                for (bit_index = 0; bit_index < 5;
                     bit_index = bit_index + 1)
                    packed_v[(code_index*5 + bit_index)/8]
                            [(code_index*5 + bit_index)%8] =
                        v_codes[code_index][bit_index];
        end
    endtask

    task program_metadata;
        input integer length;
        input [31:0] v_base;
        integer pair_index;
        reg [31:0] word;
        begin
            axi_write(REG_CTRL, 32'h0000_0002);
            axi_write(REG_V_BASE_LO, v_base);
            axi_write(REG_V_BASE_HI, 32'd0);
            axi_write(REG_CONTEXT, length);

            for (pair_index = 0; pair_index < length*2;
                 pair_index = pair_index + 1) begin
                word = {exp_codes[pair_index*2+1],
                        exp_codes[pair_index*2]};
                axi_write(EXP_BASE + pair_index*4, word);
            end
            for (pair_index = 0; pair_index < (length+1)/2;
                 pair_index = pair_index + 1) begin
                word = {4'd0,
                        ((pair_index*2+1) < length) ?
                            v_scales[pair_index*2+1] : 12'd0,
                        4'd0, v_scales[pair_index*2]};
                axi_write(SCALE_BASE + pair_index*4, word);
            end
            axi_write(REG_EXP_COUNT, length);
            axi_write(REG_SCALE_COUNT, length);

            expect_reg(REG_V_BASE_LO, v_base, "V base low");
            expect_reg(REG_V_BASE_HI, 32'd0, "V base high");
            expect_reg(REG_CONTEXT, length, "context");
            expect_reg(REG_EXP_COUNT, length, "exp count");
            expect_reg(REG_SCALE_COUNT, length, "scale count");
            expect_reg(EXP_BASE,
                       {exp_codes[1], exp_codes[0]}, "exp window first");
            expect_reg(SCALE_BASE,
                       {4'd0, v_scales[1], 4'd0, v_scales[0]},
                       "scale window first");
        end
    endtask

    task reset_run_monitors;
        begin
            @(negedge clk);
            model_ar_count = 0;
            model_read_beats = 0;
            model_ar_stalls = 0;
            model_r_waits = 0;
            model_bad_addresses = 0;
            saw_base_page = 1'b0;
            saw_next_page = 1'b0;
            fault_sent = 1'b0;
            ddr_lfsr = 16'hd37a;
            ar_holdoff = 0;
        end
    endtask

    task flush_ddr_model;
        begin
            @(negedge clk);
            burst_active = 1'b0;
            burst_addr = 32'd0;
            burst_beats = 0;
            burst_beat = 0;
            m_axi_arready = 1'b0;
            m_axi_rvalid = 1'b0;
            m_axi_rresp = 2'b00;
            m_axi_rlast = 1'b0;
            fault_sent = 1'b0;
            fault_mode = FAULT_NONE;
        end
    endtask

    task wait_terminal;
        output [31:0] status;
        integer polls;
        begin
            status = 32'd0;
            polls = 0;
            while (polls < 200000) begin
                axi_read(REG_STATUS, status);
                if (!status[0] && !status[3] &&
                    (status[1] || status[2] || status[4]))
                    polls = 200000;
                else
                    polls = polls + 1;
            end
            if (status[0] || status[3] ||
                !(status[1] || status[2] || status[4]))
                $fatal(1, "diagnostic completion timeout status=%08x",
                       status);
        end
    endtask

    task wait_idle;
        output [31:0] status;
        integer polls;
        begin
            status = 32'd0;
            polls = 0;
            while (polls < 200000) begin
                axi_read(REG_STATUS, status);
                if (!status[0] && !status[3])
                    polls = 200000;
                else
                    polls = polls + 1;
            end
            if (status[0] || status[3])
                $fatal(1, "diagnostic idle timeout status=%08x", status);
        end
    endtask

    task check_results;
        input string case_name;
        integer result_index;
        reg [31:0] low_word;
        reg [31:0] high_word;
        reg [47:0] reconstructed;
        begin
            for (result_index = 0; result_index < 512;
                 result_index = result_index + 1) begin
                axi_read(RESULT_BASE + result_index*8, low_word);
                axi_read(RESULT_BASE + result_index*8 + 4, high_word);
                reconstructed = {high_word[15:0], low_word};
                if (high_word[31:16] !==
                    {16{expected[result_index][47]}}) begin
                    if (errors < 20)
                        $display("FAIL %s result[%0d] high sign got=%08x expected_sign=%0d",
                                 case_name, result_index, high_word,
                                 expected[result_index][47]);
                    errors = errors + 1;
                end
                if ($signed(reconstructed) !==
                    $signed(expected[result_index])) begin
                    if (errors < 20)
                        $display("FAIL %s result[%0d] got=%0d want=%0d",
                                 case_name, result_index,
                                 $signed(reconstructed),
                                 $signed(expected[result_index]));
                    errors = errors + 1;
                end
            end
        end
    endtask

    task expect_results_hidden;
        input string label_text;
        reg [31:0] first_word;
        reg [31:0] middle_word;
        reg [31:0] last_word;
        begin
            axi_read(RESULT_BASE, first_word);
            axi_read(RESULT_BASE + 16'h0800, middle_word);
            axi_read(RESULT_BASE + 16'h0ffc, last_word);
            if (first_word !== 32'd0 || middle_word !== 32'd0 ||
                last_word !== 32'd0) begin
                $display("FAIL %s exposed result window first=%08x middle=%08x last=%08x",
                         label_text, first_word, middle_word, last_word);
                errors = errors + 1;
            end
        end
    endtask

    task run_success_case;
        input string case_name;
        input integer length;
        input [31:0] v_base;
        input integer require_split;
        reg [31:0] status;
        reg [31:0] read_beats;
        reg [31:0] perf_cycles;
        reg [31:0] ar_stalls;
        reg [31:0] r_stalls;
        integer expected_beats;
        begin
            load_case(case_name, length, v_base);
            program_metadata(length, v_base);
            reset_run_monitors();
            fault_mode = FAULT_NONE;
            axi_write(REG_CTRL, 32'h0000_0001);
            wait_terminal(status);
            if (status !== 32'h0000_0012) begin
                $display("FAIL %s final status=%08x want=00000012",
                         case_name, status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, 32'd0, "success error register");

            expected_beats = (length * 80) / AXI_BYTES;
            axi_read(REG_READ_BEATS, read_beats);
            if (read_beats !== expected_beats ||
                model_read_beats != expected_beats) begin
                $display("FAIL %s read beats reg=%0d model=%0d want=%0d",
                         case_name, read_beats, model_read_beats,
                         expected_beats);
                errors = errors + 1;
            end
            axi_read(REG_PERF, perf_cycles);
            if (perf_cycles == 0 || perf_cycles < read_beats) begin
                $display("FAIL %s perf counter=%0d beats=%0d",
                         case_name, perf_cycles, read_beats);
                errors = errors + 1;
            end
            axi_read(REG_AR_STALLS, ar_stalls);
            if (ar_stalls == 0) begin
                $display("FAIL %s AR stalls did not count randomized backpressure",
                         case_name);
                errors = errors + 1;
            end
            axi_read(REG_R_STALLS, r_stalls);
            if (r_stalls == 0) begin
                $display("FAIL %s R stalls did not count randomized bubbles",
                         case_name);
                errors = errors + 1;
            end
            if (model_bad_addresses != 0) begin
                $display("FAIL %s made %0d non-V DDR requests",
                         case_name, model_bad_addresses);
                errors = errors + 1;
            end
            if (require_split && (!saw_base_page || !saw_next_page)) begin
                $display("FAIL %s did not split read at 4KiB boundary base_page=%0d next_page=%0d",
                         case_name, saw_base_page, saw_next_page);
                errors = errors + 1;
            end
            check_results(case_name);
            $display("PASS AXI raw-V5 AV %s width=%0d context=%0d beats=%0d perf=%0d",
                     case_name, AXI_WIDTH, length, read_beats, perf_cycles);
        end
    endtask

    task run_abort_restart;
        reg [31:0] status;
        reg [31:0] word;
        integer guard;
        begin
            load_case("real_c128_l00_kvh0", 128, DEFAULT_V_BASE);
            program_metadata(128, DEFAULT_V_BASE);
            reset_run_monitors();
            fault_mode = FAULT_NONE;
            axi_write(REG_CTRL, 32'h0000_0001);
            guard = 0;
            while (model_read_beats < 12 && guard < 10000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (model_read_beats < 12)
                $fatal(1, "abort setup did not reach live DDR read");
            axi_write(REG_CTRL, 32'h0000_0004);

            axi_read(RESULT_BASE, word);
            if (word !== 32'd0) begin
                $display("FAIL abort exposed stale result word=%08x", word);
                errors = errors + 1;
            end
            wait_idle(status);
            if (status !== 32'd0) begin
                $display("FAIL abort final status=%08x want=00000000", status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, 32'h0000_0100,
                       "explicit abort marker");
            axi_read(RESULT_BASE + 16'h0ffc, word);
            if (word !== 32'd0) begin
                $display("FAIL abort exposed stale tail result=%08x", word);
                errors = errors + 1;
            end
            flush_ddr_model();

            // No reset: a short job after the partial long job must commit a
            // complete new bank and cannot expose a partial/stale result.
            run_success_case("adversarial_c7", 7, SPLIT_V_BASE, 1);
        end
    endtask

    task expect_transport_fault;
        input integer requested_fault;
        input [7:0] wanted_code;
        input string label_text;
        reg [31:0] status;
        reg [31:0] error_word;
        reg [31:0] result_word;
        integer fault_polls;
        begin
            load_case("adversarial_c7", 7, DEFAULT_V_BASE);
            program_metadata(7, DEFAULT_V_BASE);
            reset_run_monitors();
            fault_mode = requested_fault;
            axi_write(REG_CTRL, 32'h0000_0001);
            if (requested_fault == FAULT_R_TIMEOUT) begin
                // A read timeout is fail-closed: the accepted transaction
                // remains in DRAIN until its real RLAST arrives.  First prove
                // the typed timeout became visible, then release the model to
                // finish that already-owned burst.
                status = 32'd0;
                fault_polls = 0;
                while (!status[2] && fault_polls < 1000) begin
                    axi_read(REG_STATUS, status);
                    fault_polls = fault_polls + 1;
                end
                if (!status[2])
                    $fatal(1, "R timeout fault never became visible");
                fault_mode = FAULT_NONE;
            end
            wait_terminal(status);
            if (status !== 32'h0000_0004) begin
                $display("FAIL %s status=%08x want=00000004",
                         label_text, status);
                errors = errors + 1;
            end
            axi_read(REG_ERROR, error_word);
            if (error_word[7:0] !== wanted_code || error_word[8]) begin
                $display("FAIL %s code=%08x want low=%02x aborted=0",
                         label_text, error_word, wanted_code);
                errors = errors + 1;
            end
            axi_read(RESULT_BASE, result_word);
            if (result_word !== 32'd0) begin
                $display("FAIL %s exposed result=%08x",
                         label_text, result_word);
                errors = errors + 1;
            end
            flush_ddr_model();
            axi_write(REG_CTRL, 32'h0000_0002);
            expect_reg(REG_STATUS, 32'd0, "fault clear status");
            expect_reg(REG_ERROR, 32'd0, "fault clear error");
            $display("PASS AXI raw-V5 AV typed fault %s code=%02x",
                     label_text, wanted_code);
        end
    endtask

    task expect_metadata_count_fault;
        reg [31:0] status;
        begin
            load_case("adversarial_c7", 7, DEFAULT_V_BASE);
            program_metadata(7, DEFAULT_V_BASE);
            axi_write(REG_SCALE_COUNT, 32'd6);
            axi_write(REG_CTRL, 32'h0000_0001);
            expect_reg(REG_STATUS, 32'h0000_0004,
                       "metadata-count status");
            expect_reg(REG_ERROR, 32'h0000_0021,
                       "metadata-count code");
            expect_results_hidden("metadata-count fault");
            axi_write(REG_CTRL, 32'h0000_0002);
            axi_read(REG_STATUS, status);
            if (status !== 32'd0) begin
                $display("FAIL metadata-count clear status=%08x", status);
                errors = errors + 1;
            end
            $display("PASS AXI raw-V5 AV typed fault metadata count code=21");
        end
    endtask

    task expect_payload_fault;
        input integer make_reserved_v5;
        input [7:0] wanted_code;
        input string label_text;
        reg [31:0] status;
        reg [31:0] scale_word;
        begin
            load_case("adversarial_c7", 7, DEFAULT_V_BASE);
            program_metadata(7, DEFAULT_V_BASE);
            if (make_reserved_v5) begin
                // Lane zero of token zero becomes the reserved signed-V5 -16.
                packed_v[0][4:0] = 5'b10000;
            end else begin
                // Retain the valid high slot while forcing token-zero scale 0.
                scale_word = {4'd0, v_scales[1], 16'd0};
                axi_write(SCALE_BASE, scale_word);
            end
            reset_run_monitors();
            fault_mode = FAULT_NONE;
            axi_write(REG_CTRL, 32'h0000_0001);
            wait_terminal(status);
            if (status !== 32'h0000_0004) begin
                $display("FAIL %s status=%08x want=00000004",
                         label_text, status);
                errors = errors + 1;
            end
            expect_reg(REG_ERROR, {24'd0, wanted_code}, label_text);
            expect_results_hidden(label_text);
            flush_ddr_model();
            axi_write(REG_CTRL, 32'h0000_0002);
            $display("PASS AXI raw-V5 AV typed fault %s code=%02x",
                     label_text, wanted_code);
        end
    endtask

    task expect_start_while_busy;
        reg [31:0] status;
        reg [31:0] error_word;
        integer guard;
        begin
            load_case("real_c128_l00_kvh0", 128, DEFAULT_V_BASE);
            program_metadata(128, DEFAULT_V_BASE);
            reset_run_monitors();
            fault_mode = FAULT_NONE;
            axi_write(REG_CTRL, 32'h0000_0001);
            guard = 0;
            while (model_read_beats < 4 && guard < 10000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (model_read_beats < 4)
                $fatal(1, "busy-start setup did not reach live DDR read");
            axi_write(REG_CTRL, 32'h0000_0001);
            wait_terminal(status);
            if (status !== 32'h0000_0004) begin
                $display("FAIL start-while-busy status=%08x want=00000004",
                         status);
                errors = errors + 1;
            end
            axi_read(REG_ERROR, error_word);
            if (error_word[7:0] !== 8'h80 || !error_word[8]) begin
                $display("FAIL start-while-busy error=%08x want aborted/code80",
                         error_word);
                errors = errors + 1;
            end
            expect_results_hidden("start-while-busy");
            flush_ddr_model();
            axi_write(REG_CTRL, 32'h0000_0002);
            $display("PASS AXI raw-V5 AV typed fault start-while-busy code=80");
        end
    endtask

    reg [31:0] initial_status;
    initial begin
        if (AXI_WIDTH != 64 && AXI_WIDTH != 128)
            $fatal(1, "TB requires AXI_DATA_WIDTH_VAL=64 or 128");
        if (!$value$plusargs("GOLDEN_ROOT=%s", golden_root))
            golden_root = "../analysis/kv_validation/v0_3/rtl_goldens/av";

        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        expect_reg(REG_ID, 32'h4b56_0301, "core ID");
        expect_reg(REG_GEOMETRY,
                   ((AXI_WIDTH & 8'hff) << 24) |
                   (32'd128 << 16) | (32'd16 << 8) | 32'd5,
                   "geometry");
        expect_reg(REG_V_STRIDE, 32'd80, "V stride");
        expect_reg(REG_CAPS, 32'h0000_001f, "capabilities");
        expect_reg(REG_SCALE_FMT, 32'h0000_0c08, "scale format");
        axi_read(REG_STATUS, initial_status);
        if (initial_status !== 32'd0) begin
            $display("FAIL reset status=%08x", initial_status);
            errors = errors + 1;
        end

        // Full long case followed immediately by full short case proves that
        // the same RTL image safely replaces all 512 committed numerators.
        run_success_case("real_c128_l00_kvh0", 128,
                         DEFAULT_V_BASE, 0);
        run_success_case("adversarial_c7", 7, SPLIT_V_BASE, 1);

        run_abort_restart();

        expect_metadata_count_fault();
        expect_payload_fault(0, 8'h22, "zero scale");
        expect_payload_fault(1, 8'h23, "reserved V5");
        expect_start_while_busy();

        expect_transport_fault(FAULT_RRESP, ERR_RRESP, "RRESP");
        expect_transport_fault(FAULT_RLAST_EARLY, ERR_RLAST,
                               "early RLAST");
        expect_transport_fault(FAULT_RLAST_LATE, ERR_RLAST,
                               "late RLAST");
        expect_transport_fault(FAULT_AR_TIMEOUT, ERR_AR_TIMEOUT,
                               "AR timeout");
        expect_transport_fault(FAULT_R_TIMEOUT, ERR_R_TIMEOUT,
                               "R timeout");

        // One final clean restart makes every injected failure prove recovery,
        // not merely typed fail-closed behavior.
        run_success_case("adversarial_c7", 7, DEFAULT_V_BASE, 0);

        if (errors == 0) begin
            $display("TB PASS: AXI raw-V5 AV diagnostic");
            $finish;
        end
        $fatal(1, "TB FAIL: AXI raw-V5 AV diagnostic errors=%0d", errors);
    end
endmodule

`default_nettype wire
