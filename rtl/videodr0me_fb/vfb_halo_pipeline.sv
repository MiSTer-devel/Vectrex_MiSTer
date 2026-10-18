// ============================================================================
// Delayed-primary, bloom, and broad-halo video pipeline.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The delayed primary uses 12-bit energy. The max(primary, bloom) and
// broad-halo outputs use 17 bits with four fractional bits.
// Halo scaling uses a 25-bit product; final composition uses an
// 18-bit sum. The output uses 17 bits with four fractional bits
// and is limited to an energy of 8191.
// ============================================================================

`default_nettype none

module vfb_halo_pipeline #(
	parameter integer MAX_WIDTH = 1472,
	parameter integer SDR_FIFO_DEPTH = 256,
	parameter integer PRIMARY_H_DELAY = 42,
	parameter integer PRIMARY_DATA_ADVANCE = 0,
	parameter integer HALO_OUTPUT_OFF_Q8 = 128, // Halo output multiplier (overlay off): 0.5 in Q8.
	parameter integer HALO_OUTPUT_ON_Q8  = 128  // Halo output multiplier (overlay on): 0.5 in Q8.
) (
	input  wire  clk_sys,
	input  wire  reset,
	input  wire  ce_pix,

	input  wire  [2:0]  osd_bloom_width,
	input  wire  [2:0]  bloom_curve_mode,
	input  wire  [2:0]  halo_curve_mode,
	input  wire  [1:0]  halo_dot_reduction,
	input  wire  [2:0]  halo_filter_mode,
	input  wire         overlay_active,
	input  wire  [1:0]  halo_spread_mode,
	input  wire  [2:0]  halo_knee_mode,
	input  wire         halo_grid_8,
	input  wire  [11:0] active_height,

	input  wire  [11:0] CANONICAL_IN,
	input  wire  [11:0] HALO_SOURCE_IN,
	input  wire         DWELL_EXCESS_IN,
	input  wire         VGA_HS_IN,
	input  wire         VGA_VS_IN,
	input  wire         VGA_HBLANK_IN,
	input  wire         VGA_VBLANK_IN,

	output logic [16:0] ENERGY_OUT, // Q4 energy
	output logic        VGA_HS_OUT,
	output logic        VGA_VS_OUT,
	output logic        VGA_HBLANK_OUT,
	output logic        VGA_VBLANK_OUT,

	input  wire  [15:0] sdram_data_in,
	output logic [15:0] sdram_data_out,
	output logic        sdram_data_oe,
	output logic        sdram_cke,
	output logic        sdram_cs,
	output logic        sdram_ras,
	output logic        sdram_cas,
	output logic        sdram_we,
	output logic [1:0]  sdram_dqm,
	output logic [12:0] sdram_addr,
	output logic [1:0]  sdram_ba,
	output logic        memory_overflow,
	output logic        memory_underflow,
	output logic        memory_ready
);

logic [7:0] halo_gain_q = 8'd0;

// Precompute the eight menu gains multiplied by the output calibration, in Q8.
function automatic [63:0] halo_gain_table(input integer g);
	return {8'((3*g+1)/2), 8'((5*g+2)/4), 8'(g), 8'((3*g+2)/4),
		8'((g+1)/2), 8'((11*g+16)/32), 8'((g+2)/4), 8'd0};
endfunction
localparam [63:0] HALO_GAIN_OFF = halo_gain_table(HALO_OUTPUT_OFF_Q8);
localparam [63:0] HALO_GAIN_ON  = halo_gain_table(HALO_OUTPUT_ON_Q8);

always_ff @(posedge clk_sys) begin
	halo_gain_q <= overlay_active ? HALO_GAIN_ON[halo_filter_mode*8 +: 8]
	                              : HALO_GAIN_OFF[halo_filter_mode*8 +: 8];
end

localparam integer PRIMARY_SYNC_TAP = PRIMARY_H_DELAY - 1;
localparam integer PRIMARY_DATA_TAP = PRIMARY_SYNC_TAP - PRIMARY_DATA_ADVANCE;

initial begin
	if (HALO_OUTPUT_OFF_Q8 < 0 || HALO_OUTPUT_OFF_Q8 > 170 ||
		HALO_OUTPUT_ON_Q8 < 0 || HALO_OUTPUT_ON_Q8 > 170)
		$error("Halo output calibration must fit the 8-bit combined Q8 gain (0..170)");
	if (PRIMARY_H_DELAY < 1)
		$error("PRIMARY_H_DELAY must be positive");
	if ((PRIMARY_DATA_ADVANCE < 0) || (PRIMARY_DATA_ADVANCE >= PRIMARY_H_DELAY))
		$error("PRIMARY_DATA_ADVANCE must select a valid delay tap");
end

logic [11:0] delayed_canonical;
logic        delayed_hs, delayed_vs, delayed_hblank, delayed_vblank;
// Align primary with halo reconstruction: 31 scanlines for grid 8, 71 for grid 16.
// PRIMARY_H_DELAY counts pixel enables.
wire [11:0]  line_delay = halo_grid_8 ? 12'd31 : 12'd71;
(* preserve, dont_merge *) logic primary_line_delay_reset_q = 1'b1;
always_ff @(posedge clk_sys)
	primary_line_delay_reset_q <= reset;

vfb_sdram_delay #(
	.SDRAM_MHZ (125),
	.FIFO_DEPTH(SDR_FIFO_DEPTH)
) primary_line_delay (
	.clk_sys       (clk_sys),
	.reset         (primary_line_delay_reset_q),
	.ce_pix        (ce_pix),
	.line_delay    (line_delay),
	.CANONICAL_IN  (CANONICAL_IN),
	.VGA_HS_IN     (VGA_HS_IN),
	.VGA_VS_IN     (VGA_VS_IN),
	.VGA_HBLANK_IN (VGA_HBLANK_IN),
	.VGA_VBLANK_IN (VGA_VBLANK_IN),
	.CANONICAL_OUT (delayed_canonical),
	.VGA_HS_OUT    (delayed_hs),
	.VGA_VS_OUT    (delayed_vs),
	.VGA_HBLANK_OUT(delayed_hblank),
	.VGA_VBLANK_OUT(delayed_vblank),
	.sdram_data_in (sdram_data_in),
	.sdram_data_out(sdram_data_out),
	.sdram_data_oe (sdram_data_oe),
	.sdram_cke     (sdram_cke),
	.sdram_cs      (sdram_cs),
	.sdram_ras     (sdram_ras),
	.sdram_cas     (sdram_cas),
	.sdram_we      (sdram_we),
	.sdram_dqm     (sdram_dqm),
	.sdram_addr    (sdram_addr),
	.sdram_ba      (sdram_ba),
	.overflow      (memory_overflow),
	.underflow     (memory_underflow),
	.init_done     (memory_ready)
);

(* ramstyle = "MLAB" *) logic [15:0] horizontal_delay
	[0:PRIMARY_H_DELAY-1];
integer delay_i;
always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		horizontal_delay[0] <= {
			delayed_hs, delayed_vs, delayed_hblank, delayed_vblank,
			delayed_canonical
		};
		for (delay_i = 1; delay_i < PRIMARY_H_DELAY;
			delay_i = delay_i + 1)
			horizontal_delay[delay_i] <= horizontal_delay[delay_i-1];
	end
end

wire [15:0] filter_input = {
	horizontal_delay[PRIMARY_SYNC_TAP][15:12],
	horizontal_delay[PRIMARY_DATA_TAP][11:0]
};

logic [16:0] composite_energy;
logic        composite_hs, composite_vs, composite_hblank, composite_vblank;
vfb_filter bloom_filter (
	.clk_sys         (clk_sys),
	.ce_pix          (ce_pix),
	.reset           (reset),
	.osd_bloom_width (osd_bloom_width),
	.bloom_curve_mode(bloom_curve_mode),
	.ENERGY_IN       (filter_input[11:0]),
	.VGA_HS_IN       (filter_input[15]),
	.VGA_VS_IN       (filter_input[14]),
	.VGA_HBLANK_IN   (filter_input[13]),
	.VGA_VBLANK_IN   (filter_input[12]),
	.ENERGY_OUT      (composite_energy),
	.VGA_HS_OUT      (composite_hs),
	.VGA_VS_OUT      (composite_vs),
	.VGA_HBLANK_OUT  (composite_hblank),
	.VGA_VBLANK_OUT  (composite_vblank)
);

logic [16:0] wide_halo_energy;
logic        wide_halo_valid;
vfb_halo_wide #(
	.MAX_WIDTH(MAX_WIDTH)
) wide_halo (
	.clk_sys         (clk_sys),
	.reset           (reset),
	.ce_pix          (ce_pix),
	.halo_curve_mode (halo_curve_mode),
	.halo_spread_mode(halo_spread_mode),
	.halo_knee_mode  (halo_knee_mode),
	.halo_grid_8     (halo_grid_8),
	.line_delay      (line_delay),
	.active_height   (active_height),
	.ENERGY_IN       (HALO_SOURCE_IN),
	.DWELL_EXCESS_IN (DWELL_EXCESS_IN),
	.halo_dot_reduction (halo_dot_reduction),
	.VGA_HBLANK_IN   (VGA_HBLANK_IN),
	.VGA_VBLANK_IN   (VGA_VBLANK_IN),
	.HALO_ENERGY_OUT (wide_halo_energy),
	.HALO_VALID_OUT  (wide_halo_valid)
);

logic [16:0] mix_composite;
logic [24:0] mix_halo_product;
logic        mix_halo_valid;
wire [16:0]  mix_halo_rounded = mix_halo_product[24:8] + 17'(mix_halo_product[7]);
wire [15:0]  mix_halo         = !mix_halo_valid ? 16'd0 :
                                (mix_halo_rounded > 17'd65520) ? 16'hfff0 : mix_halo_rounded[15:0];
logic        mix_hs, mix_vs, mix_hblank, mix_vblank;

// Register halo rounding and saturation before composition. Composite energy
// and sync cross the same pixel-enable boundary as the halo contribution.
logic [16:0] sum_composite_q;
logic [15:0] sum_halo_q;
logic        sum_hs_q, sum_vs_q, sum_hblank_q, sum_vblank_q;
wire [17:0]  mix_energy = {1'b0, sum_composite_q} + {2'd0, sum_halo_q};

// Keep multiplication separate from rounding and composition for DSP packing.
always_ff @(posedge clk_sys) begin
	if (ce_pix)
		mix_halo_product <= wide_halo_energy * halo_gain_q;
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		mix_composite   <= 17'd0;
		mix_halo_valid  <= 1'b0;
		mix_hs          <= 1'b1;
		mix_vs          <= 1'b1;
		mix_hblank      <= 1'b1;
		mix_vblank      <= 1'b1;
		sum_composite_q <= 17'd0;
		sum_halo_q      <= 16'd0;
		sum_hs_q        <= 1'b1;
		sum_vs_q        <= 1'b1;
		sum_hblank_q    <= 1'b1;
		sum_vblank_q    <= 1'b1;
		ENERGY_OUT      <= 17'd0;
		VGA_HS_OUT      <= 1'b1;
		VGA_VS_OUT      <= 1'b1;
		VGA_HBLANK_OUT  <= 1'b1;
		VGA_VBLANK_OUT  <= 1'b1;
	end else if (ce_pix) begin
		ENERGY_OUT      <= (sum_hblank_q || sum_vblank_q) ? 17'd0 :
		                   (mix_energy > 18'd131056) ? 17'h1fff0 : mix_energy[16:0];
		VGA_HS_OUT      <= sum_hs_q;
		VGA_VS_OUT      <= sum_vs_q;
		VGA_HBLANK_OUT  <= sum_hblank_q;
		VGA_VBLANK_OUT  <= sum_vblank_q;

		sum_composite_q <= mix_composite;
		sum_halo_q      <= mix_halo;
		sum_hs_q        <= mix_hs;
		sum_vs_q        <= mix_vs;
		sum_hblank_q    <= mix_hblank;
		sum_vblank_q    <= mix_vblank;

		mix_composite   <= composite_energy;
		mix_halo_valid  <= wide_halo_valid;
		mix_hs          <= composite_hs;
		mix_vs          <= composite_vs;
		mix_hblank      <= composite_hblank;
		mix_vblank      <= composite_vblank;
	end
end

endmodule

`default_nettype wire
