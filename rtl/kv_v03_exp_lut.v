// kv_v03_exp_lut.v -- frozen 128-entry UQ1.15 exp(-distance) table.
// SPDX-License-Identifier: CERN-OHL-S-2.0
`timescale 1ns / 1ps
`default_nettype none

module kv_v03_exp_lut (
    input  wire [6:0]  address,
    output reg  [15:0] value
);
    always @* begin
        case (address)
            7'd0: value = 16'h8000;
            7'd1: value = 16'h748c;
            7'd2: value = 16'h6a1e;
            7'd3: value = 16'h609f;
            7'd4: value = 16'h57f9;
            7'd5: value = 16'h501a;
            7'd6: value = 16'h48ef;
            7'd7: value = 16'h4268;
            7'd8: value = 16'h3c77;
            7'd9: value = 16'h370d;
            7'd10: value = 16'h3220;
            7'd11: value = 16'h2da4;
            7'd12: value = 16'h298e;
            7'd13: value = 16'h25d6;
            7'd14: value = 16'h2273;
            7'd15: value = 16'h1f5e;
            7'd16: value = 16'h1c90;
            7'd17: value = 16'h1a01;
            7'd18: value = 16'h17ad;
            7'd19: value = 16'h158f;
            7'd20: value = 16'h13a1;
            7'd21: value = 16'h11df;
            7'd22: value = 16'h1046;
            7'd23: value = 16'h0ed1;
            7'd24: value = 16'h0d7e;
            7'd25: value = 16'h0c49;
            7'd26: value = 16'h0b2f;
            7'd27: value = 16'h0a2f;
            7'd28: value = 16'h0946;
            7'd29: value = 16'h0871;
            7'd30: value = 16'h07b0;
            7'd31: value = 16'h0700;
            7'd32: value = 16'h065f;
            7'd33: value = 16'h05cd;
            7'd34: value = 16'h0548;
            7'd35: value = 16'h04cf;
            7'd36: value = 16'h0461;
            7'd37: value = 16'h03fd;
            7'd38: value = 16'h03a2;
            7'd39: value = 16'h034e;
            7'd40: value = 16'h0303;
            7'd41: value = 16'h02be;
            7'd42: value = 16'h027f;
            7'd43: value = 16'h0246;
            7'd44: value = 16'h0212;
            7'd45: value = 16'h01e2;
            7'd46: value = 16'h01b7;
            7'd47: value = 16'h0190;
            7'd48: value = 16'h016c;
            7'd49: value = 16'h014b;
            7'd50: value = 16'h012e;
            7'd51: value = 16'h0113;
            7'd52: value = 16'h00fa;
            7'd53: value = 16'h00e4;
            7'd54: value = 16'h00cf;
            7'd55: value = 16'h00bd;
            7'd56: value = 16'h00ac;
            7'd57: value = 16'h009d;
            7'd58: value = 16'h008f;
            7'd59: value = 16'h0082;
            7'd60: value = 16'h0076;
            7'd61: value = 16'h006c;
            7'd62: value = 16'h0062;
            7'd63: value = 16'h0059;
            7'd64: value = 16'h0051;
            7'd65: value = 16'h004a;
            7'd66: value = 16'h0043;
            7'd67: value = 16'h003d;
            7'd68: value = 16'h0038;
            7'd69: value = 16'h0033;
            7'd70: value = 16'h002e;
            7'd71: value = 16'h002a;
            7'd72: value = 16'h0026;
            7'd73: value = 16'h0023;
            7'd74: value = 16'h0020;
            7'd75: value = 16'h001d;
            7'd76: value = 16'h001a;
            7'd77: value = 16'h0018;
            7'd78: value = 16'h0016;
            7'd79: value = 16'h0014;
            7'd80: value = 16'h0012;
            7'd81: value = 16'h0011;
            7'd82: value = 16'h000f;
            7'd83: value = 16'h000e;
            7'd84: value = 16'h000c;
            7'd85: value = 16'h000b;
            7'd86: value = 16'h000a;
            7'd87: value = 16'h0009;
            7'd88: value = 16'h0009;
            7'd89: value = 16'h0008;
            7'd90: value = 16'h0007;
            7'd91: value = 16'h0006;
            7'd92: value = 16'h0006;
            7'd93: value = 16'h0005;
            7'd94: value = 16'h0005;
            7'd95: value = 16'h0004;
            7'd96: value = 16'h0004;
            7'd97: value = 16'h0004;
            7'd98: value = 16'h0003;
            7'd99: value = 16'h0003;
            7'd100: value = 16'h0003;
            7'd101: value = 16'h0003;
            7'd102: value = 16'h0002;
            7'd103: value = 16'h0002;
            7'd104: value = 16'h0002;
            7'd105: value = 16'h0002;
            7'd106: value = 16'h0002;
            7'd107: value = 16'h0001;
            7'd108: value = 16'h0001;
            7'd109: value = 16'h0001;
            7'd110: value = 16'h0001;
            7'd111: value = 16'h0001;
            7'd112: value = 16'h0001;
            7'd113: value = 16'h0001;
            7'd114: value = 16'h0001;
            7'd115: value = 16'h0001;
            7'd116: value = 16'h0001;
            7'd117: value = 16'h0001;
            7'd118: value = 16'h0001;
            default: value = 16'h0000;
        endcase
    end
endmodule

`default_nettype wire
