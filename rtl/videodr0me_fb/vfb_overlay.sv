// ============================================================================
// Palette artwork loader, decoder, and color-coefficient stream.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Loads boot2.rom, manual ART uploads, or companion art files into DDRAM.
// Selects the plane matching the active resolution and decodes it one row
// ahead. The video path emits aligned beam energy and precomputed color
// coefficients for final presentation.
// ============================================================================

`default_nettype none

module vfb_overlay (
	input  wire  clk_sys,
	input  wire  clk_io,
	input  wire  reset,
	input  wire  upload_reset,
	input  wire  arbiter_ready,
	input  wire  video_timing_reset,

	input  wire         processed_path_active,
	input  wire         artwork_enable,
	input  wire  [2:0]  artwork_tint,
	input  wire  [2:0]  presentation_color,
	input  wire         presentation_boost,
	input  wire  [2:0]  artwork_blend,
	input  wire  [2:0]  artwork_opaque_brightness,
	input  wire  [11:0] render_width,
	input  wire  [11:0] render_height,
	input  wire         matte_open,
	input  wire  [11:0] matte_left,
	input  wire  [11:0] matte_right,
	input  wire  [11:0] matte_top,
	input  wire  [11:0] matte_bottom,

	input  wire         ioctl_download,
	input  wire         ioctl_wr,
	input  wire  [15:0] ioctl_index,
	input  wire  [24:0] ioctl_addr,
	input  wire  [7:0]  ioctl_data,
	output logic        ioctl_wait,
	output wire         artwork_valid,
	output wire         overlay_active,

	input  wire             ce_pix,
	input  wire  [16:0]     video_energy_in,
	input  wire             video_hs_in,
	input  wire             video_vs_in,
	input  wire             video_hblank_in,
	input  wire             video_vblank_in,
	output logic [16:0]     video_energy_out,
	output vfb_color_pkg::color_coeff_t color_coeff_out,
	output logic            video_hs_out,
	output logic            video_vs_out,
	output logic            video_hblank_out,
	output logic            video_vblank_out,

	output logic        upload_write_ready,
	input  wire         upload_write_done,
	output logic [28:0] upload_write_addr,
	output logic [7:0]  upload_write_burstcnt,
	output logic [63:0] upload_write_data,
	output logic [7:0]  upload_write_be,
	input  wire         upload_write_advance,

	output logic        artwork_read_ready,
	input  wire         artwork_read_grant,
	output logic [28:0] artwork_read_addr,
	output logic [7:0]  artwork_read_burstcnt,
	input  wire  [63:0] artwork_read_data,
	input  wire         artwork_read_data_valid
);

import vfb_layout_pkg::*;
import vfb_color_pkg::*;

localparam integer MAX_PLANES     = VFB_ARTWORK_PLANES;
localparam integer PLANE_INDEX_W  = $clog2(MAX_PLANES);
localparam integer PALETTE_ADDR_W = 11;

wire                      package_valid;
wire                      upload_reset_sys;
wire [MAX_PLANES-1:0]     plane_valid;
vfb_artwork_plane_t       plane [0:MAX_PLANES-1];
wire                      palette_write_enable;
wire [PALETTE_ADDR_W-1:0] palette_write_address;
wire [31:0]               palette_write_data;
wire [7:0]                palette_read_index;
wire                      palette_index_valid;
color_coeff_t             palette_read_coeff;
wire                      palette_ready;
wire [11:0]               display_x, input_line_number;

vfb_vart_loader loader (
	.clk_sys              (clk_sys),
	.clk_io               (clk_io),
	.upload_reset         (upload_reset),
	.arbiter_ready        (arbiter_ready),
	.ioctl_download       (ioctl_download),
	.ioctl_wr             (ioctl_wr),
	.ioctl_index          (ioctl_index),
	.ioctl_addr           (ioctl_addr),
	.ioctl_data           (ioctl_data),
	.ioctl_wait           (ioctl_wait),
	.artwork_valid        (package_valid),
	.upload_reset_sys     (upload_reset_sys),
	.plane_valid          (plane_valid),
	.plane_info           (plane),
	.palette_write_enable (palette_write_enable),
	.palette_write_address(palette_write_address),
	.palette_write_data   (palette_write_data),
	.upload_write_ready   (upload_write_ready),
	.upload_write_done    (upload_write_done),
	.upload_write_addr    (upload_write_addr),
	.upload_write_burstcnt (upload_write_burstcnt),
	.upload_write_data    (upload_write_data),
	.upload_write_be      (upload_write_be),
	.upload_write_advance (upload_write_advance)
);

assign artwork_valid = package_valid;

// Both selectors control ambient artwork brightness. A weight of
// 64/64 applies the palette color at its stored alpha.
function automatic [6:0] brightness_weight(input logic [2:0] selection);
	begin
		case (selection)
			3'b000:  brightness_weight = 7'd32;  // 50%
			3'b001:  brightness_weight = 7'd38;  // 60%
			3'b010:  brightness_weight = 7'd45;  // 70%
			3'b011:  brightness_weight = 7'd51;  // 80%
			3'b100:  brightness_weight =  7'd6;  // 10%
			3'b101:  brightness_weight = 7'd13;  // 20%
			3'b110:  brightness_weight = 7'd19;  // 30%
			default: brightness_weight = 7'd26;  // 40%
		endcase
	end
endfunction

// ------------------------------------------------------------------------
// Plane selection and user controls
// ------------------------------------------------------------------------

logic       processed_path_active_q =  1'b0;
logic       artwork_enable_q        =  1'b0;
logic       boost_q                 =  1'b0;
logic [6:0] blend_weight_q          = 7'd32;
logic [6:0] opaque_weight_q         = 7'd32;

always_ff @(posedge clk_sys) begin
	processed_path_active_q <= processed_path_active;
	artwork_enable_q        <= artwork_enable;
	boost_q                 <= presentation_boost;

	blend_weight_q  <= brightness_weight(artwork_blend);
	opaque_weight_q <= brightness_weight(artwork_opaque_brightness);
end

logic   [MAX_PLANES-1:0]    plane_match_q = '0;
logic                       selected_plane_valid_d;
logic   [PLANE_INDEX_W-1:0] selected_plane_index_d;
logic                       selected_plane_valid_q = 1'b0;
logic   [PLANE_INDEX_W-1:0] selected_plane_index_q =   '0;
integer                     match_index;
integer                     priority_index;
logic                       priority_found;

// Register each descriptor match before selecting the first one.
always_ff @(posedge clk_sys) begin
	if (reset || video_timing_reset || !package_valid) begin
		plane_match_q <= '0;
	end else begin
		for (match_index = 0; match_index < MAX_PLANES; match_index = match_index + 1) begin
			plane_match_q[match_index] <= plane_valid[match_index] &&
			                              (plane[match_index].width == render_width) &&
			                              (plane[match_index].height == render_height);
		end
	end
end

always_comb begin
	selected_plane_valid_d = 1'b0;
	selected_plane_index_d =   '0;
	priority_found         = 1'b0;

	for (priority_index = 0; priority_index < MAX_PLANES; priority_index = priority_index + 1) begin
		if (!priority_found && plane_match_q[priority_index]) begin
			selected_plane_valid_d = 1'b1;
			selected_plane_index_d = priority_index[PLANE_INDEX_W-1:0];
			priority_found         = 1'b1;
		end
	end
end

always_ff @(posedge clk_sys) begin
	if (reset || video_timing_reset || !package_valid) begin
		selected_plane_valid_q <= 1'b0;
		selected_plane_index_q <=   '0;
	end else begin
		selected_plane_valid_q <= selected_plane_valid_d;
		selected_plane_index_q <= selected_plane_index_d;
	end
end

logic [7:0]  selected_index_bits;
logic [31:0] selected_palette_offset;
logic [31:0] selected_payload_offset;
logic [31:0] selected_payload_size;
always_comb begin
	selected_index_bits     =  8'd4;
	selected_palette_offset = 32'd0;
	selected_payload_offset = 32'd0;
	selected_payload_size   = 32'd0;

	if (selected_plane_valid_q) begin
		selected_index_bits     = plane[selected_plane_index_q].index_bits;
		selected_palette_offset = plane[selected_plane_index_q].palette_offset;
		selected_payload_offset = plane[selected_plane_index_q].payload_offset;
		selected_payload_size   = plane[selected_plane_index_q].payload_size;
	end
end


logic               active_plane_valid    = 1'b0;
vfb_artwork_index_t active_index_mode     = INDEX_MODE_4;
logic [31:0]        active_palette_offset = 32'd0;
logic [31:0]        active_payload_offset = 32'd0;
logic [31:0]        active_payload_size   = 32'd0;

always_ff @(posedge clk_sys) begin
	if (reset || video_timing_reset) begin
		active_plane_valid    <= 1'b0;
		active_index_mode     <= INDEX_MODE_4;
		active_palette_offset <= 32'd0;
		active_payload_offset <= 32'd0;
		active_payload_size   <= 32'd0;
	end else begin
		active_plane_valid <= selected_plane_valid_q;
		if (selected_plane_valid_q) begin
			active_palette_offset <= selected_palette_offset;
			active_payload_offset <= selected_payload_offset;
			active_payload_size   <= selected_payload_size;
			case (selected_index_bits)
				8'd4:    begin
					active_index_mode <= INDEX_MODE_4;
				end
				8'd6:    begin
					active_index_mode <= INDEX_MODE_6;
				end
				default: begin
					active_index_mode <= INDEX_MODE_8;
				end
			endcase
		end
	end
end

wire active_plane_ready = active_plane_valid && package_valid;
vfb_palette palette (
	.clk_sys(clk_sys), .reset(reset || upload_reset_sys || video_timing_reset),
	.write_enable(palette_write_enable),
	.write_address(palette_write_address),
	.write_data(palette_write_data),
	.plane_valid(active_plane_ready),
	.palette_offset(active_palette_offset[PALETTE_ADDR_W+1:2]),
	.palette_count(active_index_mode == INDEX_MODE_4 ? 9'd16 :
		(active_index_mode == INDEX_MODE_6 ? 9'd64 : 9'd256)),
	.color(presentation_color), .tint(artwork_tint),
	.boost(boost_q),
	.translucent_weight(blend_weight_q), .opaque_weight(opaque_weight_q),
	.read_enable(ce_pix), .read_index(palette_read_index),
	.read_coeff(palette_read_coeff), .ready(palette_ready)
);
assign overlay_active = active_plane_ready && artwork_enable_q && processed_path_active_q;
wire   run_requested  = overlay_active && palette_ready;

vfb_overlay_readout readout (
	.clk_sys                (clk_sys),
	.reset                  (reset),
	.video_timing_reset     (video_timing_reset),
	.run_requested          (run_requested),
	.active_index_mode      (active_index_mode),
	.active_payload_offset  (active_payload_offset),
	.active_payload_size    (active_payload_size),
	.render_width           (render_width),
	.render_height          (render_height),
	.ce_pix                 (ce_pix),
	.video_hblank_in        (video_hblank_in),
	.video_vblank_in        (video_vblank_in),
	.palette_read_index     (palette_read_index),
	.palette_index_valid    (palette_index_valid),
	.pixel_x                (display_x),
	.pixel_y                (input_line_number),
	.artwork_read_ready     (artwork_read_ready),
	.artwork_read_grant     (artwork_read_grant),
	.artwork_read_addr      (artwork_read_addr),
	.artwork_read_burstcnt  (artwork_read_burstcnt),
	.artwork_read_data      (artwork_read_data),
	.artwork_read_data_valid(artwork_read_data_valid)
);

// ------------------------------------------------------------------------
// Palette coefficient lookup and video alignment.
// ------------------------------------------------------------------------

typedef struct packed {
	logic [16:0] energy;
	logic        hs;
	logic        vs;
	logic        hblank;
	logic        vblank;
	logic        overlay_active;
	logic [2:0]  color;
} video_packet_t;

video_packet_t pixel_s0;
video_packet_t pixel_s1;
video_packet_t pixel_s2;
// Stage 2 uses artwork metadata for the palette lookup.
typedef struct packed {
	logic [16:0] energy;
	logic        hs;
	logic        vs;
	logic        hblank;
	logic        vblank;
} present_sample_t;
present_sample_t pixel_s3, pixel_s4, pixel_s5, pixel_s6;
color_coeff_t    coeff_s3, coeff_s4, coeff_s5, coeff_s6;
logic            palette_valid_s2;
wire             beam_in_matte    = matte_open ||
                                    ((display_x >= matte_left) &&
                                     (display_x <= matte_right) &&
                                     (input_line_number >= matte_top) &&
                                     (input_line_number <= matte_bottom));
logic            beam_in_matte_s0 = 1'b0;
(* preserve, dont_merge *) logic present_reset_q = 1'b1;

always_ff @(posedge clk_sys) begin
	if (reset || video_timing_reset) begin
		pixel_s0         <= '0;
		pixel_s1         <= '0;
		pixel_s2         <= '0;
		pixel_s3         <= '0;
		pixel_s4         <= '0;
		pixel_s5         <= '0;
		pixel_s6         <= '0;
		coeff_s3         <= bare_color(1'b0, 3'd0, 1'b0);
		coeff_s4         <= bare_color(1'b0, 3'd0, 1'b0);
		coeff_s5         <= bare_color(1'b0, 3'd0, 1'b0);
		coeff_s6         <= bare_color(1'b0, 3'd0, 1'b0);
		beam_in_matte_s0 <= 1'b0;
		palette_valid_s2 <= 1'b0;
	end else if (ce_pix) begin
		pixel_s0.energy         <= video_energy_in;
		pixel_s0.hs             <= video_hs_in;
		pixel_s0.vs             <= video_vs_in;
		pixel_s0.hblank         <= video_hblank_in;
		pixel_s0.vblank         <= video_vblank_in;
		pixel_s0.overlay_active <= overlay_active;
		pixel_s0.color          <= presentation_color;
		beam_in_matte_s0        <= beam_in_matte;

		pixel_s1 <= pixel_s0;
		if (!beam_in_matte_s0) pixel_s1.energy <= 17'd0;

		pixel_s2         <= pixel_s1;
		palette_valid_s2 <= palette_index_valid;
		pixel_s3 <= '{energy: pixel_s2.energy, hs: pixel_s2.hs,
			vs: pixel_s2.vs, hblank: pixel_s2.hblank, vblank: pixel_s2.vblank};
		coeff_s3 <= palette_valid_s2 ? palette_read_coeff
		                             : bare_color(pixel_s2.overlay_active, pixel_s2.color, boost_q);
		pixel_s4 <= pixel_s3;
		coeff_s4 <= coeff_s3;
		pixel_s5 <= pixel_s4;
		coeff_s5 <= coeff_s4;
		pixel_s6 <= pixel_s5;
		coeff_s6 <= coeff_s5;
	end
end

// Reset aligned energy, color coefficients and video timing together.
always_ff @(posedge clk_sys) begin
	present_reset_q <= reset || video_timing_reset;
	if (present_reset_q) begin
		video_energy_out <= 17'd0;
		color_coeff_out  <=    '0;
		video_hs_out     <=  1'b1;
		video_vs_out     <=  1'b1;
		video_hblank_out <=  1'b1;
		video_vblank_out <=  1'b1;
	end else if (ce_pix) begin
		video_energy_out <= pixel_s6.hblank || pixel_s6.vblank ? 17'd0 : pixel_s6.energy;
		color_coeff_out  <= coeff_s6;
		video_hs_out     <= pixel_s6.hs;
		video_vs_out     <= pixel_s6.vs;
		video_hblank_out <= pixel_s6.hblank;
		video_vblank_out <= pixel_s6.vblank;
	end
end

endmodule

`default_nettype wire
