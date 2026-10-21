// ============================================================================
// Shared framebuffer, tile, artwork, and DDRAM layout constants.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// ============================================================================

`default_nettype none

package vfb_layout_pkg;
	import vfb_control_pkg::*;

	// Each stored energy unit represents two source units: 0..2047 maps to 0..4094.
	// Raw pixels use [15:12] for draw phase; composed pixels use bit 15 for freshness
	// and clear [14:12].
	typedef struct packed {
		logic [3:0]  phase;
		logic        dwell_excess;
		logic [10:0] energy;
	} vfb_frame_pixel_t;

	// Composite light retains four fractional bits through presentation.
	typedef logic [16:0] vfb_energy_q4_t;

	// Validated VART plane fields used for resolution selection and readout.
	typedef struct packed {
		logic [11:0] width;
		logic [11:0] height;
		logic [7:0]  index_bits;
		logic [31:0] palette_offset;
		logic [31:0] payload_offset;
		logic [31:0] payload_size;
	} vfb_artwork_plane_t;

	typedef enum logic [1:0] {
		INDEX_MODE_4,
		INDEX_MODE_6,
		INDEX_MODE_8
	} vfb_artwork_index_t;

	localparam integer VFB_ARTWORK_PLANES = 4;
	localparam integer VFB_BUFFER_COUNT = 5;
	localparam logic [15:0] VFB_TILEMAP_ENTRIES_480 = 16'd11520;

	// DDRAM addresses count 64-bit words: 16 per tile, with a 256-tile row stride.
	// Tilemaps use a separate 192-entry row stride.
	localparam logic [28:0] VFB_FRAMEBUFFER_BASE = 29'h06000000;
	localparam logic [28:0] VFB_FRAMEBUFFER_LAST = 29'h0654ffff;
	localparam logic [28:0] VFB_ARTWORK_BASE = 29'h06550000;
	localparam logic [28:0] VFB_ARTWORK_LAST = 29'h065cffff;
	// PiTrex command ring shared with the HPS (byte 0x34000000): header + 64K entries.
	localparam logic [28:0] VFB_PITREX_BASE = 29'h06800000;
	localparam logic [28:0] VFB_PITREX_LAST = 29'h068101ff;

	function automatic logic [28:0] vfb_buffer_base(
		input logic [2:0] index
	);
		begin
			case (index)
				3'd0:    vfb_buffer_base = 29'h06000000;
				3'd1:    vfb_buffer_base = 29'h06110000;
				3'd2:    vfb_buffer_base = 29'h06220000;
				3'd3:    vfb_buffer_base = 29'h06330000;
				3'd4:    vfb_buffer_base = 29'h06440000;
				default: vfb_buffer_base = VFB_FRAMEBUFFER_BASE;
			endcase
		end
	endfunction

	function automatic logic [8:0] vfb_tile_columns(
		input logic [11:0] width
	);
		vfb_tile_columns = 9'((width + 12'd7) >> 3);
	endfunction

	function automatic logic [8:0] vfb_tile_rows(
		input logic [11:0] height
	);
		vfb_tile_rows = 9'((height + 12'd7) >> 3);
	endfunction

	function automatic logic [14:0] vfb_tile_row_addr(
		input logic [7:0] tile_y
	);
		logic [15:0] row_base;
		begin
			row_base          = ({8'd0, tile_y} << 7) + ({8'd0, tile_y} << 6);
			vfb_tile_row_addr = row_base[14:0];
		end
	endfunction

	function automatic logic [14:0] vfb_linear_tile_addr(
		input logic [15:0] tile_id
	);
		vfb_linear_tile_addr = vfb_tile_row_addr(tile_id[15:8]) + {7'd0, tile_id[7:0]};
	endfunction

	function automatic logic [15:0] vfb_tilemap_entries(
		input logic [8:0] rows
	);
		vfb_tilemap_entries = ({7'd0, rows} << 7) + ({7'd0, rows} << 6);
	endfunction

	function automatic logic [7:0] vfb_energy_to_level(
		input logic [11:0] energy
	);
		logic [18:0] line_scaled;
		logic [7:0]  shoulder_delta;
		logic [17:0] shoulder_scaled;
		begin
			if (energy <= 12'd768) begin
				line_scaled         = ({7'd0, energy} << 9) +
				                      ({7'd0, energy} << 6) + ({7'd0, energy} << 5) +
				                      ({7'd0, energy} << 3) + ({7'd0, energy} << 2) +
				                      {7'd0, energy} + 19'd128;
				vfb_energy_to_level = line_scaled[18:11];
			end else if (energy < 12'd1024) begin
				shoulder_delta      = energy[7:0];
				shoulder_scaled     = ({10'd0, shoulder_delta} << 9) +
				                      ({10'd0, shoulder_delta} << 7) +
				                      ({10'd0, shoulder_delta} << 6) +
				                      ({10'd0, shoulder_delta} << 5) +
				                      ({10'd0, shoulder_delta} << 1) +
				                      {10'd0, shoulder_delta} + 18'd7680;
				vfb_energy_to_level = 8'd232 + {3'd0, shoulder_scaled[17:13]};
			end else
				vfb_energy_to_level = 8'hff;
		end
	endfunction

	// Intra-frame decay: A is weakest (~0.99), C moderate (~0.98), B strongest (~0.96).
	// The compositor and readout share these 8-bit factors.
	function automatic [7:0] vfb_decay_factor(
		input  logic [1:0] mode,
		input  logic [3:0] age
	);
		begin
			case ({mode, age})
				// LUT A: round(255 * 0.99^age).
				{INTRA_LUT_A, 4'd0}:  vfb_decay_factor = 8'd255;
				{INTRA_LUT_A, 4'd1}:  vfb_decay_factor = 8'd252;
				{INTRA_LUT_A, 4'd2}:  vfb_decay_factor = 8'd250;
				{INTRA_LUT_A, 4'd3}:  vfb_decay_factor = 8'd247;
				{INTRA_LUT_A, 4'd4}:  vfb_decay_factor = 8'd245;
				{INTRA_LUT_A, 4'd5}:  vfb_decay_factor = 8'd243;
				{INTRA_LUT_A, 4'd6}:  vfb_decay_factor = 8'd240;
				{INTRA_LUT_A, 4'd7}:  vfb_decay_factor = 8'd238;
				{INTRA_LUT_A, 4'd8}:  vfb_decay_factor = 8'd235;
				{INTRA_LUT_A, 4'd9}:  vfb_decay_factor = 8'd233;
				{INTRA_LUT_A, 4'd10}: vfb_decay_factor = 8'd231;
				{INTRA_LUT_A, 4'd11}: vfb_decay_factor = 8'd228;
				{INTRA_LUT_A, 4'd12}: vfb_decay_factor = 8'd226;
				{INTRA_LUT_A, 4'd13}: vfb_decay_factor = 8'd224;
				{INTRA_LUT_A, 4'd14}: vfb_decay_factor = 8'd222;
				{INTRA_LUT_A, 4'd15}: vfb_decay_factor = 8'd219;
				{INTRA_LUT_B, 4'd0}:  vfb_decay_factor = 8'd255;
				{INTRA_LUT_B, 4'd1}:  vfb_decay_factor = 8'd245;
				{INTRA_LUT_B, 4'd2}:  vfb_decay_factor = 8'd235;
				{INTRA_LUT_B, 4'd3}:  vfb_decay_factor = 8'd226;
				{INTRA_LUT_B, 4'd4}:  vfb_decay_factor = 8'd217;
				{INTRA_LUT_B, 4'd5}:  vfb_decay_factor = 8'd208;
				{INTRA_LUT_B, 4'd6}:  vfb_decay_factor = 8'd200;
				{INTRA_LUT_B, 4'd7}:  vfb_decay_factor = 8'd192;
				{INTRA_LUT_B, 4'd8}:  vfb_decay_factor = 8'd184;
				{INTRA_LUT_B, 4'd9}:  vfb_decay_factor = 8'd177;
				{INTRA_LUT_B, 4'd10}: vfb_decay_factor = 8'd170;
				{INTRA_LUT_B, 4'd11}: vfb_decay_factor = 8'd163;
				{INTRA_LUT_B, 4'd12}: vfb_decay_factor = 8'd156;
				{INTRA_LUT_B, 4'd13}: vfb_decay_factor = 8'd150;
				{INTRA_LUT_B, 4'd14}: vfb_decay_factor = 8'd144;
				{INTRA_LUT_B, 4'd15}: vfb_decay_factor = 8'd138;
				{INTRA_LUT_C, 4'd0}:  vfb_decay_factor = 8'd255;
				{INTRA_LUT_C, 4'd1}:  vfb_decay_factor = 8'd250;
				{INTRA_LUT_C, 4'd2}:  vfb_decay_factor = 8'd245;
				{INTRA_LUT_C, 4'd3}:  vfb_decay_factor = 8'd240;
				{INTRA_LUT_C, 4'd4}:  vfb_decay_factor = 8'd235;
				{INTRA_LUT_C, 4'd5}:  vfb_decay_factor = 8'd230;
				{INTRA_LUT_C, 4'd6}:  vfb_decay_factor = 8'd225;
				{INTRA_LUT_C, 4'd7}:  vfb_decay_factor = 8'd221;
				{INTRA_LUT_C, 4'd8}:  vfb_decay_factor = 8'd216;
				{INTRA_LUT_C, 4'd9}:  vfb_decay_factor = 8'd212;
				{INTRA_LUT_C, 4'd10}: vfb_decay_factor = 8'd208;
				{INTRA_LUT_C, 4'd11}: vfb_decay_factor = 8'd204;
				{INTRA_LUT_C, 4'd12}: vfb_decay_factor = 8'd200;
				{INTRA_LUT_C, 4'd13}: vfb_decay_factor = 8'd196;
				{INTRA_LUT_C, 4'd14}: vfb_decay_factor = 8'd192;
				{INTRA_LUT_C, 4'd15}: vfb_decay_factor = 8'd188;
				default:              vfb_decay_factor = 8'd255;
			endcase
		end
	endfunction

endpackage

`default_nettype wire
