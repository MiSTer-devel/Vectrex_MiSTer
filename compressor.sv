//============================================================================
//  Audio compressor (signed samples)
// 
//  Copyright (C) 2018 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module compressor
(
	input        clk,
	input  [9:0] din,
	output [8:0] dout
);

always @(posedge clk) dout <= {din[9], din[9] ? ~tbl[~din[8:0]] : tbl[din[8:0]]};

wire [7:0] tbl[0:511] = 
'{
 8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h06, 8'h07, 8'h08, 8'h09, 8'h0B, 8'h0C, 8'h0D, 8'h0E, 8'h0F, 8'h11, 8'h12,
 8'h13, 8'h14, 8'h16, 8'h17, 8'h18, 8'h19, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25,
 8'h27, 8'h28, 8'h29, 8'h2A, 8'h2C, 8'h2D, 8'h2E, 8'h2F, 8'h30, 8'h32, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37, 8'h39,
 8'h3A, 8'h3B, 8'h3C, 8'h3D, 8'h3F, 8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h46, 8'h47, 8'h48, 8'h49, 8'h4A, 8'h4B,
 8'h4D, 8'h4E, 8'h4F, 8'h50, 8'h51, 8'h52, 8'h53, 8'h55, 8'h56, 8'h57, 8'h58, 8'h59, 8'h5A, 8'h5B, 8'h5C, 8'h5E,
 8'h5F, 8'h60, 8'h61, 8'h62, 8'h63, 8'h64, 8'h65, 8'h66, 8'h67, 8'h69, 8'h6A, 8'h6B, 8'h6C, 8'h6D, 8'h6E, 8'h6F,
 8'h70, 8'h71, 8'h72, 8'h73, 8'h74, 8'h75, 8'h76, 8'h77, 8'h78, 8'h79, 8'h7A, 8'h7B, 8'h7C, 8'h7D, 8'h7E, 8'h7F,
 8'h80, 8'h81, 8'h82, 8'h83, 8'h84, 8'h85, 8'h86, 8'h87, 8'h88, 8'h89, 8'h8A, 8'h8B, 8'h8C, 8'h8D, 8'h8E, 8'h8F,
 8'h90, 8'h91, 8'h92, 8'h93, 8'h94, 8'h95, 8'h96, 8'h96, 8'h97, 8'h98, 8'h99, 8'h9A, 8'h9B, 8'h9C, 8'h9D, 8'h9E,
 8'h9E, 8'h9F, 8'hA0, 8'hA1, 8'hA2, 8'hA3, 8'hA4, 8'hA4, 8'hA5, 8'hA6, 8'hA7, 8'hA8, 8'hA9, 8'hA9, 8'hAA, 8'hAB,
 8'hAC, 8'hAD, 8'hAD, 8'hAE, 8'hAF, 8'hB0, 8'hB1, 8'hB1, 8'hB2, 8'hB3, 8'hB4, 8'hB4, 8'hB5, 8'hB6, 8'hB7, 8'hB7,
 8'hB8, 8'hB9, 8'hB9, 8'hBA, 8'hBB, 8'hBC, 8'hBC, 8'hBD, 8'hBE, 8'hBE, 8'hBF, 8'hC0, 8'hC0, 8'hC1, 8'hC2, 8'hC2,
 8'hC3, 8'hC4, 8'hC4, 8'hC5, 8'hC6, 8'hC6, 8'hC7, 8'hC8, 8'hC8, 8'hC9, 8'hC9, 8'hCA, 8'hCB, 8'hCB, 8'hCC, 8'hCC,
 8'hCD, 8'hCE, 8'hCE, 8'hCF, 8'hCF, 8'hD0, 8'hD0, 8'hD1, 8'hD2, 8'hD2, 8'hD3, 8'hD3, 8'hD4, 8'hD4, 8'hD5, 8'hD5,
 8'hD6, 8'hD6, 8'hD7, 8'hD7, 8'hD8, 8'hD8, 8'hD9, 8'hD9, 8'hDA, 8'hDA, 8'hDB, 8'hDB, 8'hDC, 8'hDC, 8'hDD, 8'hDD,
 8'hDE, 8'hDE, 8'hDE, 8'hDF, 8'hDF, 8'hE0, 8'hE0, 8'hE1, 8'hE1, 8'hE1, 8'hE2, 8'hE2, 8'hE3, 8'hE3, 8'hE3, 8'hE4,
 8'hE4, 8'hE5, 8'hE5, 8'hE5, 8'hE6, 8'hE6, 8'hE6, 8'hE7, 8'hE7, 8'hE7, 8'hE8, 8'hE8, 8'hE9, 8'hE9, 8'hE9, 8'hEA,
 8'hEA, 8'hEA, 8'hEA, 8'hEB, 8'hEB, 8'hEB, 8'hEC, 8'hEC, 8'hEC, 8'hED, 8'hED, 8'hED, 8'hEE, 8'hEE, 8'hEE, 8'hEE,
 8'hEF, 8'hEF, 8'hEF, 8'hEF, 8'hF0, 8'hF0, 8'hF0, 8'hF0, 8'hF1, 8'hF1, 8'hF1, 8'hF1, 8'hF2, 8'hF2, 8'hF2, 8'hF2,
 8'hF3, 8'hF3, 8'hF3, 8'hF3, 8'hF3, 8'hF4, 8'hF4, 8'hF4, 8'hF4, 8'hF4, 8'hF5, 8'hF5, 8'hF5, 8'hF5, 8'hF5, 8'hF6,
 8'hF6, 8'hF6, 8'hF6, 8'hF6, 8'hF6, 8'hF7, 8'hF7, 8'hF7, 8'hF7, 8'hF7, 8'hF7, 8'hF8, 8'hF8, 8'hF8, 8'hF8, 8'hF8,
 8'hF8, 8'hF8, 8'hF9, 8'hF9, 8'hF9, 8'hF9, 8'hF9, 8'hF9, 8'hF9, 8'hF9, 8'hFA, 8'hFA, 8'hFA, 8'hFA, 8'hFA, 8'hFA,
 8'hFA, 8'hFA, 8'hFA, 8'hFB, 8'hFB, 8'hFB, 8'hFB, 8'hFB, 8'hFB, 8'hFB, 8'hFB, 8'hFB, 8'hFB, 8'hFB, 8'hFC, 8'hFC,
 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFC, 8'hFD, 8'hFD, 8'hFD,
 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD, 8'hFD,
 8'hFD, 8'hFD, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE,
 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE,
 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE,
 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE,
 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE,
 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE,
 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFE, 8'hFF
};

endmodule
