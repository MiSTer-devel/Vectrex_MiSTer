// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// Fourteen ce_pix stages keep light and sync aligned.
// Three lookup stages precede C1 F(I) with Q4 interpolation.
// C2 compensation product; C3 target; C4 segment; C5 channel products;
// C6 rounded products; C7 linear RGB; C8 ambient; C9 address; C10 sRGB; C11 output.
`default_nettype none

module vfb_final_present (
	input  wire         clk_sys, reset, ce_pix,
	input  wire  [1:0]  tone_mapping,
	input  wire  [16:0] ENERGY_IN, // Q4 energy
	input  vfb_color_pkg::color_coeff_t COEFF_IN,
	input  wire         VGA_HS_IN, VGA_VS_IN, VGA_HBLANK_IN, VGA_VBLANK_IN,
	output logic [7:0]  VGA_R_OUT, VGA_G_OUT, VGA_B_OUT,
	output logic        VGA_HS_OUT, VGA_VS_OUT, VGA_HBLANK_OUT, VGA_VBLANK_OUT
);
import vfb_color_pkg::*;
import vfb_control_pkg::*;

localparam integer SYNC_STAGES = 13;

// Five hex digits store 17 data bits and three zero padding bits.
// Standard: F(I); Bright: F(4I/3); Boost: F(3I*1450/(2*1024)); Reduced: F(3I/4).
// Boost coefficients use the shared 820/1024 mapping knee.
(* ramstyle = "M10K" *) logic [19:0] luminance_rom [0:8191];
initial $readmemh("rtl/videodr0me_fb/vfb_color_luminance.hex", luminance_rom);
wire  [10:0]      intensity      = |ENERGY_IN[16:15] ? 11'h7ff : ENERGY_IN[14:4];
wire  [10:0]      intensity_next = &intensity ? intensity : intensity + 11'd1;
wire  [1:0]       luminance_bank = (tone_mapping == TONE_BOOST) ? 2'd2 :
                                   (tone_mapping == TONE_BRIGHT) ? 2'd1 :
                                       (tone_mapping == TONE_REDUCED) ? 2'd3 : 2'd0;
logic [16:0]      luminance_c1, target_c3, argument_c4;
logic [16:0]      luminance_low_q, luminance_high_q, luminance_base_q, luminance_base_d, luminance_slope_q;
logic [3:0]       luminance_frac_q, luminance_frac_d;
logic [20:0]      luminance_product_q;
color_coeff_t     coeff_lookup [0:2];
logic [33:0]      compensated_c2;
color_coeff_t     coeff_c1, coeff_c2, coeff_c3;
logic [2:0][20:0] slope_c4;
logic             high_c4, high_c5, high_c6;
logic [2:0][37:0] product_c5;
logic [2:0][21:0] rounded_c6;
logic [2:0][16:0] linear_c7;
logic [2:0][17:0] sum_c8;
logic [2:0][12:0] address_c9;
logic [2:0][7:0]  srgb_c10;
logic [3:0]       sync_pipe [0:SYNC_STAGES-1];
// Keep the ambient delay in registers to avoid RAM address hold paths.
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
logic [2:0][16:0] ambient_pipe [0:6];

// Each channel has a synchronous read port; low light keeps every Q16 step.
genvar g;
generate
	for (g = 0; g < 3; g = g + 1) begin : encode_channel
		vfb_color_encode encoder (
			.clk_sys(clk_sys), .ce_pix(ce_pix), .address(address_c9[g]), .data(srgb_c10[g])
		);
	end
endgenerate

always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		luminance_low_q     <= 17'(luminance_rom[{luminance_bank, intensity}]);
		luminance_high_q    <= 17'(luminance_rom[{luminance_bank, intensity_next}]);
		luminance_frac_q    <= &intensity ? 4'd0 : ENERGY_IN[3:0];

		luminance_base_q    <= luminance_low_q;
		luminance_slope_q   <= luminance_high_q - luminance_low_q;
		luminance_frac_d    <= luminance_frac_q;

		luminance_base_d    <= luminance_base_q;
		luminance_product_q <= luminance_slope_q * luminance_frac_d;

		luminance_c1    <= luminance_base_d +
		                   17'(luminance_product_q[20:4]) + 17'(luminance_product_q[3]);

		coeff_lookup[0] <= COEFF_IN;
		coeff_lookup[1] <= coeff_lookup[0];
		coeff_lookup[2] <= coeff_lookup[1];
		coeff_c1        <= coeff_lookup[2];

		compensated_c2  <= luminance_c1 * coeff_c1.gain;
		coeff_c2        <= coeff_c1;

		target_c3   <= compensated_c2[32:16] + 17'(compensated_c2[15]);
		coeff_c3    <= coeff_c2;

		high_c4     <= target_c3 >= coeff_c3.knee;
		slope_c4    <= target_c3 >= coeff_c3.knee ? coeff_c3.high : coeff_c3.low;
		argument_c4 <= target_c3 >= coeff_c3.knee ? COLOR_ONE - target_c3 : target_c3;
		high_c5     <= high_c4;
		high_c6     <= high_c5;
		for (int c = 0; c < 3; c++) begin
			product_c5[c] <= slope_c4[c] * argument_c4;
			rounded_c6[c] <= product_c5[c][37:16] + 22'(product_c5[c][15]);
			// Saturation and complement share the original rounded value.
			linear_c7[c] <= |rounded_c6[c][21:16] ? (high_c6 ? 17'd0 : COLOR_ONE) :
				(high_c6 ? COLOR_ONE - {1'b0, rounded_c6[c][15:0]} :
				           {1'b0, rounded_c6[c][15:0]});
			// Add emitted and ambient light before the single display encoding.
			sum_c8[c] <= {1'b0, linear_c7[c]} + {1'b0, ambient_pipe[6][c]};
			address_c9[c] <= sum_c8[c] >= 18'd65536 ? 13'd8191 :
				(sum_c8[c] < 18'd4096 ? {1'b0, sum_c8[c][11:0]} : {1'b1, sum_c8[c][15:4]});
		end
		ambient_pipe[0] <= coeff_lookup[2].ambient;
		for (int i = 1; i < 7; i++) ambient_pipe[i] <= ambient_pipe[i - 1];
	end

	if (reset) begin
		for (int i = 0; i < SYNC_STAGES; i++) sync_pipe[i] <= 4'b1111;
		{VGA_R_OUT, VGA_G_OUT, VGA_B_OUT}                        <=   24'd0;
		{VGA_HS_OUT, VGA_VS_OUT, VGA_HBLANK_OUT, VGA_VBLANK_OUT} <= 4'b1111;
	end else if (ce_pix) begin
		sync_pipe[0] <= {VGA_HS_IN, VGA_VS_IN, VGA_HBLANK_IN, VGA_VBLANK_IN};
		for (int i = 1; i < SYNC_STAGES; i++) sync_pipe[i] <= sync_pipe[i - 1];
		VGA_R_OUT <= |sync_pipe[SYNC_STAGES-1][1:0] ? 8'd0 : srgb_c10[2];
		VGA_G_OUT <= |sync_pipe[SYNC_STAGES-1][1:0] ? 8'd0 : srgb_c10[1];
		VGA_B_OUT <= |sync_pipe[SYNC_STAGES-1][1:0] ? 8'd0 : srgb_c10[0];

		{VGA_HS_OUT, VGA_VS_OUT, VGA_HBLANK_OUT, VGA_VBLANK_OUT} <= sync_pipe[SYNC_STAGES-1];
	end
end
endmodule

module vfb_color_encode (
	input  wire         clk_sys, ce_pix,
	input  wire  [12:0] address,
	output logic [7:0]  data
);
(* ramstyle = "M10K" *) logic [7:0] encode_rom [0:8191];
initial $readmemh("rtl/videodr0me_fb/vfb_color_encode.hex", encode_rom);
always_ff @(posedge clk_sys) if (ce_pix) data <= encode_rom[address];
endmodule

`default_nettype wire
