// ============================================================================
// Local bloom stage for the delayed primary stream.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Applies the bloom source curve, runs the local blur passes, and combines
// the result with the primary image.
// ============================================================================

`default_nettype none

module vfb_filter (
	input  wire  clk_sys,
	input  wire  ce_pix,
	input  wire  reset,

	// Bloom controls
	input  wire  [2:0] osd_bloom_width,
	input  wire  [2:0] bloom_curve_mode,

	// Delayed primary image
	input  wire  [11:0] ENERGY_IN,
	input  wire         VGA_HS_IN,
	input  wire         VGA_VS_IN,
	input  wire         VGA_HBLANK_IN,
	input  wire         VGA_VBLANK_IN,

	// Filtered output
	output logic [16:0] ENERGY_OUT, // Q4 energy
	output logic        VGA_HS_OUT,
	output logic        VGA_VS_OUT,
	output logic        VGA_HBLANK_OUT,
	output logic        VGA_VBLANK_OUT
);
import vfb_control_pkg::*;

logic [2:0] osd_bloom_width_q  = BLOOM_OFF;
logic [2:0] bloom_curve_mode_q = CURVE_MINIMAL;

always_ff @(posedge clk_sys) begin
	osd_bloom_width_q  <= osd_bloom_width;
	bloom_curve_mode_q <= bloom_curve_mode;
end

logic [11:0] energy_in_r;
logic        vga_hs_in_r;
logic        vga_vs_in_r;
logic        vga_hblank_in_r;
logic        vga_vblank_in_r;

always_ff @(posedge clk_sys) begin
	if (reset) begin
		energy_in_r     <= 12'd0;
		vga_hs_in_r     <= 1'b1;
		vga_vs_in_r     <= 1'b1;
		vga_hblank_in_r <= 1'b1;
		vga_vblank_in_r <= 1'b1;
	end else if (ce_pix) begin
		energy_in_r     <= ENERGY_IN;
		vga_hs_in_r     <= VGA_HS_IN;
		vga_vs_in_r     <= VGA_VS_IN;
		vga_hblank_in_r <= VGA_HBLANK_IN;
		vga_vblank_in_r <= VGA_VBLANK_IN;
	end
end

logic [7:0] bloom_comp_scale;
always_comb begin
	case (osd_bloom_width_q)
		BLOOM_OFF:    bloom_comp_scale = 8'd0;
		BLOOM_THIN:   bloom_comp_scale = 8'd16;
		BLOOM_TIGHT:  bloom_comp_scale = 8'd29;
		BLOOM_SOFT:   bloom_comp_scale = 8'd54;
		BLOOM_NORMAL: bloom_comp_scale = 8'd76;
		BLOOM_BROAD:  bloom_comp_scale = 8'd121;
		BLOOM_WIDE_M: bloom_comp_scale = 8'd161;
		default:      bloom_comp_scale = 8'd214; // Wide
	endcase
end

// Bloom excitation table: x^1.75 with eight gain settings.
// x runs from 0 to 1 across 256 input samples per setting.
// Each 16-bit entry contains:
// [15]    zero padding;
// [14:7]  8-bit curve value after gain and saturation;
// [6:0]   interpolation slope after expansion to 12-bit energy.
(* ramstyle = "M10K" *) logic [15:0] bloom_source_rom [0:2047];
initial $readmemh("rtl/videodr0me_fb/vfb_bloom_curve.hex", bloom_source_rom);

logic en_p1, en_p2, en_p3;
always_comb begin
	en_p1 = (osd_bloom_width_q >= BLOOM_THIN);
	en_p2 = (osd_bloom_width_q >= BLOOM_SOFT);
	en_p3 = (osd_bloom_width_q >= BLOOM_BROAD);
end

// Sync pipeline matched to the energy path.
(* ramstyle = "M10K, no_rw_check" *) logic [3:0] sync_lb_0 [0:2047];
(* ramstyle = "M10K, no_rw_check" *) logic [3:0] sync_lb_1 [0:2047];
(* ramstyle = "M10K, no_rw_check" *) logic [3:0] sync_lb_2 [0:2047];
(* ramstyle = "M10K, no_rw_check" *) logic [3:0] sync_lb_3 [0:2047];
(* ramstyle = "M10K, no_rw_check" *) logic [3:0] sync_lb_4 [0:2047];
(* ramstyle = "M10K, no_rw_check" *) logic [3:0] sync_lb_5 [0:2047];
(* ramstyle = "M10K, no_rw_check" *) logic [3:0] sync_lb_6 [0:2047];
(* ramstyle = "M10K, no_rw_check" *) logic [3:0] sync_lb_7 [0:2047];
(* ramstyle = "M10K, no_rw_check" *) logic [3:0] sync_lb_8 [0:2047];

logic [3:0] s_lb_out [0:8];

logic [10:0] h_count;
logic [10:0] h_count_d1;
logic        hs_d;

logic [33:0] hs_pipe, vs_pipe, hb_pipe, vb_pipe;
logic [3:0]  sync_in_d1;

always_ff @(posedge clk_sys) begin
	if (reset) begin
		hs_pipe    <= '0;
		vs_pipe    <= '0;
		hb_pipe    <= '1;
		vb_pipe    <= '1;
		h_count    <= '0;
		hs_d       <= '0;
		sync_in_d1 <= 4'b0011;
	end else if (ce_pix) begin
		hs_d       <= vga_hs_in_r;
		sync_in_d1 <= {
			vga_hs_in_r,
			vga_vs_in_r,
			vga_hblank_in_r,
			vga_vblank_in_r
		};

		if (vga_hs_in_r && !hs_d) h_count <= 0;
		else if (h_count < 11'd2047) h_count <= h_count + 11'd1;

		h_count_d1 <= h_count;

		s_lb_out[0] <= sync_lb_0[h_count];
		s_lb_out[1] <= sync_lb_1[h_count];
		s_lb_out[2] <= sync_lb_2[h_count];
		s_lb_out[3] <= sync_lb_3[h_count];
		s_lb_out[4] <= sync_lb_4[h_count];
		s_lb_out[5] <= sync_lb_5[h_count];
		s_lb_out[6] <= sync_lb_6[h_count];
		s_lb_out[7] <= sync_lb_7[h_count];
		s_lb_out[8] <= sync_lb_8[h_count];

		sync_lb_0[h_count_d1] <= sync_in_d1;
		sync_lb_1[h_count_d1] <= s_lb_out[0];
		sync_lb_2[h_count_d1] <= s_lb_out[1];
		sync_lb_3[h_count_d1] <= s_lb_out[2];
		sync_lb_4[h_count_d1] <= s_lb_out[3];
		sync_lb_5[h_count_d1] <= s_lb_out[4];
		sync_lb_6[h_count_d1] <= s_lb_out[5];
		sync_lb_7[h_count_d1] <= s_lb_out[6];
		sync_lb_8[h_count_d1] <= s_lb_out[7];

		hs_pipe <= {hs_pipe[32:0], s_lb_out[8][3]};
		vs_pipe <= {vs_pipe[32:0], s_lb_out[8][2]};
		hb_pipe <= {hb_pipe[32:0], s_lb_out[8][1]};
		vb_pipe <= {vb_pipe[32:0], s_lb_out[8][0]};
	end
end

localparam integer COMP_SERVICE_STAGE = 30;
localparam integer COMP_WRITE_STAGE = 31;
localparam integer COMP_PRESENT_READ_STAGE = 32;
localparam integer COMP_OUTPUT_SYNC_STAGE = 30;
logic [10:0] active_x;
logic [10:0] ax_pipe [1:33];
logic        ax_valid_pipe [1:33];

always_ff @(posedge clk_sys) begin
	if (reset) begin
		active_x <= 11'd0;
		for (int i=1; i<=33; i++) ax_pipe[i] <= 11'd0;
		for (int i=1; i<=33; i++) ax_valid_pipe[i] <= 1'b0;
	end else if (ce_pix) begin
		if (vga_hblank_in_r) begin
			active_x <= 11'd0;
		end else begin
			if (active_x < 11'd1471)
				active_x <= active_x + 11'd1;
		end

		ax_pipe[1] <= vga_hblank_in_r ? 11'd0 : active_x;
		for (int i=2; i<=33; i++) ax_pipe[i] <= ax_pipe[i-1];

		ax_valid_pipe[1] <= !vga_hblank_in_r;
		for (int i=2; i<=33; i++)
			ax_valid_pipe[i] <= ax_valid_pipe[i-1];
	end
end

// Register primary energy while starting the single-port curve lookup.
// Bloom uses display-normalized excitation; halo retains the full dwell range.
wire  [11:0] bloom_input = |energy_in_r[11:10] ? 12'hfff : {energy_in_r[9:0], 2'b00};
logic [11:0] source_energy;
logic [14:0] bloom_curve_q;
logic [3:0]  bloom_curve_frac_q;
always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		source_energy <= energy_in_r;

		bloom_curve_q      <= 15'(bloom_source_rom[{bloom_curve_mode_q, bloom_input[11:4]}]);
		bloom_curve_frac_q <= bloom_input[3:0];
	end
end

// Expand the curve sample and multiply its slope by the fractional bits.
logic [11:0] base_energy;
logic [11:0] bloom_curve_base_q;
logic [9:0]  bloom_curve_product_q;
always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		base_energy <= source_energy;

		bloom_curve_base_q    <= {bloom_curve_q[14:7], bloom_curve_q[14:11]};
		bloom_curve_product_q <= bloom_curve_q[6:0] * bloom_curve_frac_q;
	end
end

// Delay primary energy by six lines.
(* ramstyle = "M10K, no_rw_check" *) logic [11:0] base_lb_0 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [11:0] base_lb_1 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [11:0] base_lb_2 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [11:0] base_lb_3 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [11:0] base_lb_4 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [11:0] base_lb_5 [0:1471];

logic [11:0] base_lb_0_ram, base_lb_1_ram, base_lb_2_ram;
logic [11:0] base_lb_3_ram, base_lb_4_ram, base_lb_5_ram;
logic [10:0] base_cascade_addr;
logic        base_cascade_valid;

always_ff @(posedge clk_sys) begin
	if (reset) begin
		base_cascade_addr  <= 11'd0;
		base_cascade_valid <= 1'b0;
	end else if (ce_pix) begin
		base_cascade_addr  <= ax_pipe[1];
		base_cascade_valid <= ax_valid_pipe[1];

		base_lb_0_ram <= base_lb_0[ax_pipe[1]];
		base_lb_1_ram <= base_lb_1[ax_pipe[1]];
		base_lb_2_ram <= base_lb_2[ax_pipe[1]];
		base_lb_3_ram <= base_lb_3[ax_pipe[1]];
		base_lb_4_ram <= base_lb_4[ax_pipe[1]];
		base_lb_5_ram <= base_lb_5[ax_pipe[1]];

		if (ax_valid_pipe[2])
			base_lb_0[ax_pipe[2]] <= base_energy;

		if (base_cascade_valid) begin
			base_lb_1[base_cascade_addr] <= base_lb_0_ram;
			base_lb_2[base_cascade_addr] <= base_lb_1_ram;
			base_lb_3[base_cascade_addr] <= base_lb_2_ram;
			base_lb_4[base_cascade_addr] <= base_lb_3_ram;
			base_lb_5[base_cascade_addr] <= base_lb_4_ram;
		end
	end
end

logic [11:0] base_align_pipe [1:28];
always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		base_align_pipe[1] <= base_lb_5_ram;
		for (int i = 2; i <= 28; i++) base_align_pipe[i] <= base_align_pipe[i-1];
	end
end

// Interpolate the bloom excitation before the blur passes.
wire [15:0] bloom_curve_sum = {bloom_curve_base_q, 4'd1} + {6'd0, bloom_curve_product_q};
// Keep three fractional bits through the blur passes.
logic [17:0] bloom_src;
always_ff @(posedge clk_sys) begin
	if (ce_pix)
		bloom_src <= {3'd0, bloom_curve_sum[15:1]};
end

logic [10:0] hc_p1, hc_p2;
logic        hb_p1, hb_p2;
logic [17:0] b_p1, b_p2, b_p3;

vfb_blur bloom_pass1 (.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset), .active_x_in(ax_pipe[3]), .hblank_in(hb_pipe[3]), .enable(en_p1), .energy_in(bloom_src), .active_x_out(hc_p1), .hblank_out(hb_p1), .energy_out(b_p1));
vfb_blur bloom_pass2 (.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset), .active_x_in(hc_p1), .hblank_in(hb_p1), .enable(en_p2), .energy_in(b_p1), .active_x_out(hc_p2), .hblank_out(hb_p2), .energy_out(b_p2));
vfb_blur bloom_pass3 (.clk_sys(clk_sys), .ce_pix(ce_pix), .reset(reset), .active_x_in(hc_p2), .hblank_in(hb_p2), .enable(en_p3), .energy_in(b_p2), .active_x_out(), .hblank_out(), .energy_out(b_p3));

// Per-width bloom gains include the 0.67 normalization.
logic [25:0] bloom_scaled_q;
always_ff @(posedge clk_sys) begin
	if (ce_pix)
		bloom_scaled_q <= b_p3 * bloom_comp_scale;
end

logic [16:0] bloom_comp_q, bloom_comp_d;
always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		logic [17:0] rounded;
		// Q3 input / 64 becomes Q4 output after a five-bit shift.
		rounded = {1'b0, bloom_scaled_q[21:5]} + 18'(bloom_scaled_q[4]);
		bloom_comp_q <= |bloom_scaled_q[25:22] || rounded > 18'd131056 ? 17'h1fff0 : rounded[16:0];
		bloom_comp_d <= bloom_comp_q;
	end
end

// Preserve the full framebuffer intensity in the primary.
wire [16:0] primary_core = {1'b0, base_align_pipe[28], 4'd0};
logic [16:0] comp_energy;
always_ff @(posedge clk_sys) begin
	if (ce_pix)
		comp_energy <= (bloom_comp_d > primary_core) ? bloom_comp_d : primary_core;
end

(* ramstyle = "M10K, no_rw_check" *) logic [16:0] comp_lb_0 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [16:0] comp_lb_1 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [16:0] comp_lb_2 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [16:0] comp_lb_3 [0:1471];

logic [16:0] clb_0, clb_1, clb_2, clb_3;
logic [10:0] comp_cascade_addr;
logic        comp_cascade_valid;

always_ff @(posedge clk_sys) begin
	if (reset) begin
		comp_cascade_addr  <= 11'd0;
		comp_cascade_valid <= 1'b0;
	end else if (ce_pix) begin
		comp_cascade_addr  <= ax_pipe[COMP_SERVICE_STAGE];
		comp_cascade_valid <= ax_valid_pipe[COMP_SERVICE_STAGE];

		clb_0 <= comp_lb_0[ax_pipe[COMP_SERVICE_STAGE]];
		clb_1 <= comp_lb_1[ax_pipe[COMP_SERVICE_STAGE]];
		clb_2 <= comp_lb_2[ax_pipe[COMP_SERVICE_STAGE]];
		// Read the final delayed row at the output position. Advance the
		// line buffers only for active pixels.
		clb_3 <= comp_lb_3[ax_pipe[COMP_PRESENT_READ_STAGE]];

		if (ax_valid_pipe[COMP_WRITE_STAGE])
			comp_lb_0[ax_pipe[COMP_WRITE_STAGE]] <= comp_energy;

		if (comp_cascade_valid) begin
			comp_lb_1[comp_cascade_addr] <= clb_0;
			comp_lb_2[comp_cascade_addr] <= clb_1;
			comp_lb_3[comp_cascade_addr] <= clb_2;
		end
	end
end

logic [16:0] mix_energy;
logic        mix_hs, mix_vs, mix_hblank, mix_vblank;
logic        out_hs, out_vs, out_hblank, out_vblank;
always_ff @(posedge clk_sys) begin
	if (reset) begin
		mix_energy     <= 17'd0;
		mix_hs         <= 1'b1;
		mix_vs         <= 1'b1;
		mix_hblank     <= 1'b1;
		mix_vblank     <= 1'b1;
		out_hs         <= 1'b1;
		out_vs         <= 1'b1;
		out_hblank     <= 1'b1;
		out_vblank     <= 1'b1;
		ENERGY_OUT     <= 17'd0;
		VGA_HS_OUT     <= 1'b1;
		VGA_VS_OUT     <= 1'b1;
		VGA_HBLANK_OUT <= 1'b1;
		VGA_VBLANK_OUT <= 1'b1;
	end else if (ce_pix) begin
		mix_energy <= clb_3;
		mix_hs     <= hs_pipe[COMP_OUTPUT_SYNC_STAGE];
		mix_vs     <= vs_pipe[COMP_OUTPUT_SYNC_STAGE];
		mix_hblank <= hb_pipe[COMP_OUTPUT_SYNC_STAGE];
		mix_vblank <= vb_pipe[COMP_OUTPUT_SYNC_STAGE];

		out_hs     <= mix_hs;
		out_vs     <= mix_vs;
		out_hblank <= mix_hblank;
		out_vblank <= mix_vblank;

		ENERGY_OUT     <= mix_energy;
		VGA_HS_OUT     <= out_hs;
		VGA_VS_OUT     <= out_vs;
		VGA_HBLANK_OUT <= out_hblank;
		VGA_VBLANK_OUT <= out_vblank;
	end
end

endmodule

`default_nettype wire
