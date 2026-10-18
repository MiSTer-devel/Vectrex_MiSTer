`timescale 1ns / 1ps

// ============================================================================
// Sparse inter-frame phosphor compositor.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Store the greater of the current frame's intensity, after any
// intra-frame decay, and the decayed accumulator. A current-frame winner
// is marked fresh for one stronger decay pass; its first trail is capped
// at full line energy. An accumulator winner continues with tail decay
// and is not marked fresh.
// The buffer controller waits for composition to finish before displaying the frame.
// ============================================================================

`default_nettype none

module vfb_phosphor_compositor #(
	parameter integer BUFFER_COUNT   =  5,
	parameter integer BUF_IDX_W      =  3,
	parameter integer TILEMAP_ADDR_W = 15
) (
	input wire clk_sys,
	input wire reset,

	input wire [11:0] render_width,
	input wire [11:0] render_height,
	input wire [1:0]  intra_frame_mode,
	input wire [1:0]  inter_frame_mode,

	input  wire                  compose_req,
	input  wire  [BUF_IDX_W-1:0] compose_source_buf,
	input  wire  [BUF_IDX_W-1:0] compose_target_buf,
	input  wire                  compose_has_source,
	input  wire                  compose_source_is_composed,
	output logic                 compose_done,

	input wire [3:0]  raw_reference_draw_idx,
	input wire [63:0] raw_age_map,
	input wire [3:0]  raw_frame_age,
	input wire        raw_metadata_ready,

	output logic [TILEMAP_ADDR_W-1:0] tilemap_addr,
	output logic [BUFFER_COUNT-1:0]   tilemap_write_hot,
	output logic                      tilemap_write_din,
	input  wire  [BUFFER_COUNT-1:0]   tilemap_dout,

	output logic        read_ready,
	input  wire         read_grant,
	output logic [28:0] read_addr,
	output logic [7:0]  read_burstcnt,
	input  wire  [63:0] read_data,
	input  wire         read_data_valid,

	output logic        write_ready,
	input  wire         write_grant,
	input  wire         write_done,
	output logic [28:0] write_addr,
	output logic [7:0]  write_burstcnt,
	output logic [63:0] write_data,
	output logic [7:0]  write_be,
	input  wire         write_advance
);

import vfb_layout_pkg::*;
import vfb_control_pkg::*;
localparam logic [10:0] INTER_FRAME_FLOOR = 11'd3;

logic [1:0]              intra_frame_mode_control_q = INTRA_OFF;
logic [1:0]              inter_frame_mode_control_q = INTER_OFF;
logic [BUFFER_COUNT-1:0] target_buf_hot_q           = '0;

always_ff @(posedge clk_sys) begin
	intra_frame_mode_control_q <= intra_frame_mode;
	inter_frame_mode_control_q <= inter_frame_mode;
end

// Short, Medium and Long use tail factors 240/256, 245/256 and 248/256
// per age step. For age n >= 1, a fresh pixel uses one 214/256 pass
// followed by n-1 tail passes; an existing tail uses n tail passes.
// Combined factors round down.
function automatic [15:0] inter_decay_factors(
	input  logic [1:0] mode,
	input  logic [3:0] age
);
	begin
		case ({mode, age})
			{INTER_SHORT, 4'd0}:   inter_decay_factors = {8'd255, 8'd255};
			{INTER_SHORT, 4'd1}:   inter_decay_factors = {8'd214, 8'd240};
			{INTER_SHORT, 4'd2}:   inter_decay_factors = {8'd200, 8'd225};
			{INTER_SHORT, 4'd3}:   inter_decay_factors = {8'd188, 8'd210};
			{INTER_SHORT, 4'd4}:   inter_decay_factors = {8'd176, 8'd197};
			{INTER_SHORT, 4'd5}:   inter_decay_factors = {8'd165, 8'd185};
			{INTER_SHORT, 4'd6}:   inter_decay_factors = {8'd154, 8'd173};
			{INTER_SHORT, 4'd7}:   inter_decay_factors = {8'd145, 8'd162};
			{INTER_SHORT, 4'd8}:   inter_decay_factors = {8'd136, 8'd152};
			{INTER_SHORT, 4'd9}:   inter_decay_factors = {8'd127, 8'd143};
			{INTER_SHORT, 4'd10}:  inter_decay_factors = {8'd119, 8'd134};
			{INTER_SHORT, 4'd11}:  inter_decay_factors = {8'd112, 8'd125};
			{INTER_SHORT, 4'd12}:  inter_decay_factors = {8'd105, 8'd118};
			{INTER_SHORT, 4'd13}:  inter_decay_factors = {8'd98,  8'd110};
			{INTER_SHORT, 4'd14}:  inter_decay_factors = {8'd92,  8'd103};
			{INTER_SHORT, 4'd15}:  inter_decay_factors = {8'd86,  8'd97};
			{INTER_MEDIUM, 4'd0}:  inter_decay_factors = {8'd255, 8'd255};
			{INTER_MEDIUM, 4'd1}:  inter_decay_factors = {8'd214, 8'd245};
			{INTER_MEDIUM, 4'd2}:  inter_decay_factors = {8'd204, 8'd234};
			{INTER_MEDIUM, 4'd3}:  inter_decay_factors = {8'd196, 8'd224};
			{INTER_MEDIUM, 4'd4}:  inter_decay_factors = {8'd187, 8'd214};
			{INTER_MEDIUM, 4'd5}:  inter_decay_factors = {8'd179, 8'd205};
			{INTER_MEDIUM, 4'd6}:  inter_decay_factors = {8'd171, 8'd196};
			{INTER_MEDIUM, 4'd7}:  inter_decay_factors = {8'd164, 8'd188};
			{INTER_MEDIUM, 4'd8}:  inter_decay_factors = {8'd157, 8'd180};
			{INTER_MEDIUM, 4'd9}:  inter_decay_factors = {8'd150, 8'd172};
			{INTER_MEDIUM, 4'd10}: inter_decay_factors = {8'd144, 8'd165};
			{INTER_MEDIUM, 4'd11}: inter_decay_factors = {8'd137, 8'd157};
			{INTER_MEDIUM, 4'd12}: inter_decay_factors = {8'd132, 8'd151};
			{INTER_MEDIUM, 4'd13}: inter_decay_factors = {8'd126, 8'd144};
			{INTER_MEDIUM, 4'd14}: inter_decay_factors = {8'd120, 8'd138};
			{INTER_MEDIUM, 4'd15}: inter_decay_factors = {8'd115, 8'd132};
			{INTER_LONG, 4'd0}:    inter_decay_factors = {8'd255, 8'd255};
			{INTER_LONG, 4'd1}:    inter_decay_factors = {8'd214, 8'd248};
			{INTER_LONG, 4'd2}:    inter_decay_factors = {8'd207, 8'd240};
			{INTER_LONG, 4'd3}:    inter_decay_factors = {8'd200, 8'd232};
			{INTER_LONG, 4'd4}:    inter_decay_factors = {8'd194, 8'd225};
			{INTER_LONG, 4'd5}:    inter_decay_factors = {8'd188, 8'd218};
			{INTER_LONG, 4'd6}:    inter_decay_factors = {8'd182, 8'd211};
			{INTER_LONG, 4'd7}:    inter_decay_factors = {8'd176, 8'd204};
			{INTER_LONG, 4'd8}:    inter_decay_factors = {8'd171, 8'd198};
			{INTER_LONG, 4'd9}:    inter_decay_factors = {8'd165, 8'd192};
			{INTER_LONG, 4'd10}:   inter_decay_factors = {8'd160, 8'd186};
			{INTER_LONG, 4'd11}:   inter_decay_factors = {8'd155, 8'd180};
			{INTER_LONG, 4'd12}:   inter_decay_factors = {8'd150, 8'd174};
			{INTER_LONG, 4'd13}:   inter_decay_factors = {8'd146, 8'd169};
			{INTER_LONG, 4'd14}:   inter_decay_factors = {8'd141, 8'd164};
			{INTER_LONG, 4'd15}:   inter_decay_factors = {8'd137, 8'd159};
			default:               inter_decay_factors = {8'd255, 8'd255};
		endcase
	end
endfunction

typedef enum logic [4:0] {
	COMP_IDLE,
	COMP_WAIT_METADATA,
	COMP_MAP_ISSUE,
	COMP_MAP_WAIT,
	COMP_MAP_DECIDE,
	COMP_OLD_REQUEST,
	COMP_OLD_RECEIVE,
	COMP_RAW_REQUEST,
	COMP_RAW_RECEIVE,
	COMP_PIXEL_PRIME,
	COMP_PIXEL_LOAD,
	COMP_PIXEL_RAW,
	COMP_PIXEL_OLD,
	COMP_PIXEL_BLEND,
	COMP_PIXEL_STORE,
	COMP_PIXEL_DRAIN,
	COMP_WRITE_REQUEST,
	COMP_WRITE_WAIT,
	COMP_MAP_COMMIT,
	COMP_NEXT_TILE,
	COMP_WAIT_REQUEST_LOW
} comp_state_t;

comp_state_t state;

logic [BUF_IDX_W-1:0] source_buf_q;
logic [BUF_IDX_W-1:0] target_buf_q;
logic                 has_source_q;
logic                 source_is_composed_q;
logic [1:0]           intra_mode_q;
logic [1:0]           inter_mode_q;
logic [3:0]           reference_draw_idx_q;
logic [63:0]          age_map_q;
logic [7:0]           fresh_decay_factor_q;
logic [7:0]           tail_decay_factor_q;

logic [7:0] tile_x;
logic       tile_row_end_q;
logic       tile_last_row_q;
logic [7:0] tile_y;
logic [7:0] tile_columns;
logic [7:0] tile_rows;
logic       source_tile_dirty;
logic       raw_tile_dirty;
logic       tile_nonzero;

logic [63:0] source_tile   [0:15];
logic [63:0] raw_tile      [0:15];
logic [63:0] composed_tile [0:15];

logic [3:0] read_beat;
logic [3:0] write_beat;
logic [5:0] pixel_index;
logic [5:0] lookahead_pixel_index;

logic [10:0] raw_intensity_q;
logic        raw_dwell_excess_q;
logic [7:0]  raw_factor_q;
logic        raw_bypass_q;
logic [18:0] raw_product_q;

logic [10:0] old_intensity_q;
logic        old_dwell_excess_q;
logic [7:0]  old_factor_q;
logic [18:0] old_product_q;

logic [11:0] next_raw_pixel_q;
logic [12:0] next_old_pixel_q;
// Keep age lookup and decay-factor lookup in separate pipeline stages.
(* dont_retime *)
logic [3:0]  next_raw_age_q;
logic [7:0]  next_raw_factor_q;
logic [7:0]  next_old_factor_q;

logic [10:0] blend_energy_q;
logic        blend_dwell_excess_q;
logic        blend_fresh_q;

logic [15:0] pending_pixel_q;
logic [3:0]  pending_word_q;
logic [1:0]  pending_lane_q;
logic        pending_nonzero_q;
logic        pending_write_q;

wire [15:0] current_tile_id  = {tile_y, tile_x};
wire [28:0] source_tile_addr = vfb_buffer_base(source_buf_q) + ({13'd0, current_tile_id} << 4);
wire [28:0] target_tile_addr = vfb_buffer_base(target_buf_q) + ({13'd0, current_tile_id} << 4);

wire [63:0] raw_word         = raw_tile[pixel_index[5:2]];
wire [63:0] old_word         = source_tile[pixel_index[5:2]];
wire [5:0]  pixel_bit_offset = {pixel_index[1:0], 4'b0000};
wire [15:0] raw_pixel        = raw_word[pixel_bit_offset +: 16];
wire [15:0] old_pixel        = old_word[pixel_bit_offset +: 16];

wire [15:0] selected_inter_factors = inter_decay_factors(inter_mode_q, raw_frame_age);

wire [63:0] next_raw_word         = raw_tile[lookahead_pixel_index[5:2]];
wire [63:0] next_old_word         = source_tile[lookahead_pixel_index[5:2]];
wire [5:0]  next_pixel_bit_offset = {lookahead_pixel_index[1:0], 4'b0000};
wire [15:0] next_raw_pixel        = next_raw_word[next_pixel_bit_offset +: 16];
wire [15:0] next_old_pixel        = next_old_word[next_pixel_bit_offset +: 16];

wire        next_old_uses_fresh   = !source_is_composed_q || next_old_pixel_q[12];
wire [10:0] next_old_decay_energy = (next_old_uses_fresh &&
                                     (fresh_decay_factor_q != 8'd255) &&
                                     (next_old_pixel_q[10:9] != 2'b00)) ?
                                    11'd512 :
                                    next_old_pixel_q[10:0];

wire [3:0] raw_age_draw_idx  = raw_tile_dirty ?
                               ((state == COMP_PIXEL_PRIME) ? raw_pixel[15:12]
                                                            : next_raw_pixel[15:12]) :
                               4'd0;
wire [3:0] raw_age_delta     = reference_draw_idx_q - raw_age_draw_idx;
wire [3:0] raw_pixel_age     = raw_tile_dirty ? age_map_q[{raw_age_delta, 2'b00} +: 4] : 4'd0;
wire [7:0] staged_raw_factor = vfb_decay_factor(intra_mode_q, next_raw_age_q);

wire [10:0] raw_energy         = raw_bypass_q ? raw_intensity_q : raw_product_q[18:8];
// Truncation with factors <= 255 strictly reduces every positive old energy.
wire [10:0] old_decayed_energy = old_product_q[18:8];
// Clamp accumulated tails below three stored energy units to black.
wire [10:0] old_energy = (old_decayed_energy < INTER_FRAME_FLOOR) ? 11'd0 : old_decayed_energy;

wire raw_present = (raw_energy != 11'd0);
wire old_present = (old_energy != 11'd0);
wire raw_wins    = raw_present && (!old_present || (raw_energy >= old_energy));

wire [10:0] selected_blend_energy = raw_wins ? raw_energy : old_energy;
wire [15:0] stored_pixel          = {blend_fresh_q, 3'd0,
                                     blend_dwell_excess_q && (|blend_energy_q), blend_energy_q};
wire        tile_nonzero_final    = tile_nonzero | (pending_write_q && pending_nonzero_q);

assign read_burstcnt  = 8'd16;
assign write_burstcnt = 8'd16;
assign write_be       = 8'hff;

// Each published tile is fully overwritten; only its control state needs reset.
always_ff @(posedge clk_sys) begin
	if (pending_write_q)
		composed_tile[pending_word_q][{pending_lane_q, 4'b0000} +: 16] <= pending_pixel_q;
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		state                 <= COMP_IDLE;
		compose_done          <=  1'b0;
		read_ready            <=  1'b0;
		read_addr             <= 29'd0;
		write_ready           <=  1'b0;
		write_addr            <= 29'd0;
		tilemap_addr          <=    '0;
		tilemap_write_hot     <=    '0;
		tilemap_write_din     <=  1'b0;
		source_buf_q          <=    '0;
		target_buf_q          <=    '0;
		target_buf_hot_q      <=    '0;
		has_source_q          <=  1'b0;
		source_is_composed_q  <=  1'b0;
		intra_mode_q          <= INTRA_OFF;
		inter_mode_q          <= INTER_OFF;
		reference_draw_idx_q  <=   4'd0;
		age_map_q             <=  64'd0;
		fresh_decay_factor_q  <= 8'd255;
		tail_decay_factor_q   <= 8'd255;
		tile_x                <=   8'd0;
		tile_row_end_q        <=   1'b0;
		tile_last_row_q       <=   1'b0;
		tile_y                <=   8'd0;
		tile_columns          <=   8'd0;
		tile_rows             <=   8'd0;
		source_tile_dirty     <=   1'b0;
		raw_tile_dirty        <=   1'b0;
		tile_nonzero          <=   1'b0;
		read_beat             <=   4'd0;
		write_beat            <=   4'd0;
		write_data            <=  64'd0;
		pixel_index           <=   6'd0;
		lookahead_pixel_index <=   6'd0;
		raw_intensity_q       <=  11'd0;
		raw_dwell_excess_q    <=   1'b0;
		raw_factor_q          <=   8'd0;
		raw_bypass_q          <=   1'b0;
		raw_product_q         <=  19'd0;
		old_intensity_q       <=  11'd0;
		old_dwell_excess_q    <=   1'b0;
		old_factor_q          <=   8'd0;
		old_product_q         <=  19'd0;
		next_raw_pixel_q      <=  12'd0;
		next_old_pixel_q      <=  13'd0;
		next_raw_age_q        <=   4'd0;
		next_raw_factor_q     <=   8'd0;
		next_old_factor_q     <=   8'd0;
		blend_energy_q        <=  11'd0;
		blend_dwell_excess_q  <=   1'b0;
		blend_fresh_q         <=   1'b0;
		pending_write_q       <=   1'b0;
	end else begin
		compose_done      <= 1'b0;
		pending_write_q   <= 1'b0;
		tilemap_write_hot <=   '0;

		if (pending_write_q) tile_nonzero <= tile_nonzero | pending_nonzero_q;
		if (write_advance && write_beat != 4'd15) begin
			write_beat <= write_beat + 4'd1;
			write_data <= composed_tile[write_beat + 4'd1];
		end

		case (state)
			COMP_IDLE: begin
				if (compose_req) begin
					source_buf_q         <= compose_source_buf;
					target_buf_q         <= compose_target_buf;
					target_buf_hot_q     <= {{(BUFFER_COUNT-1){1'b0}}, 1'b1} << compose_target_buf;
					has_source_q         <= compose_has_source;
					source_is_composed_q <= compose_source_is_composed;
					intra_mode_q         <= intra_frame_mode_control_q;
					inter_mode_q         <= inter_frame_mode_control_q;
					tile_columns         <= 8'(vfb_tile_columns(render_width));
					tile_rows            <= 8'(vfb_tile_rows(render_height));
					tile_x               <= 8'd0;
					tile_y               <= 8'd0;
					tilemap_addr         <=   '0;
					state                <= COMP_WAIT_METADATA;
				end
			end

			COMP_WAIT_METADATA: begin
				if (raw_metadata_ready) begin
					reference_draw_idx_q <= raw_reference_draw_idx;
					age_map_q            <= raw_age_map;
					fresh_decay_factor_q <= selected_inter_factors[15:8];
					tail_decay_factor_q  <= selected_inter_factors[7:0];
					state                <= COMP_MAP_ISSUE;
				end
			end

			COMP_MAP_ISSUE: begin
				tile_row_end_q  <= (tile_x + 8'd1 >= tile_columns);
				tile_last_row_q <= (tile_y + 8'd1 >= tile_rows);
				state           <= COMP_MAP_WAIT;
			end

			COMP_MAP_WAIT: begin
				source_tile_dirty <= has_source_q && tilemap_dout[source_buf_q];
				raw_tile_dirty    <= tilemap_dout[target_buf_q];
				state             <= COMP_MAP_DECIDE;
			end

			COMP_MAP_DECIDE: begin
				if (source_tile_dirty) begin
					read_addr  <= source_tile_addr;
					read_ready <= 1'b1;
					state      <= COMP_OLD_REQUEST;
				end else if (raw_tile_dirty) begin
					read_addr  <= target_tile_addr;
					read_ready <= 1'b1;
					state      <= COMP_RAW_REQUEST;
				end else begin
					state <= COMP_NEXT_TILE;
				end
			end

			COMP_OLD_REQUEST: begin
				if (read_grant) begin
					read_ready <= 1'b0;
					read_beat  <= 4'd0;
					state      <= COMP_OLD_RECEIVE;
				end
			end

			COMP_OLD_RECEIVE: begin
				if (read_data_valid) begin
					source_tile[read_beat] <= read_data;
					if (read_beat == 4'd15) begin
						if (raw_tile_dirty) begin
							read_addr  <= target_tile_addr;
							read_ready <= 1'b1;
							state      <= COMP_RAW_REQUEST;
						end else begin
							pixel_index  <= 6'd0;
							tile_nonzero <= 1'b0;
							state        <= COMP_PIXEL_PRIME;
						end
					end else begin
						read_beat <= read_beat + 4'd1;
					end
				end
			end

			COMP_RAW_REQUEST: begin
				if (read_grant) begin
					read_ready <= 1'b0;
					read_beat  <= 4'd0;
					state      <= COMP_RAW_RECEIVE;
				end
			end

			COMP_RAW_RECEIVE: begin
				if (read_data_valid) begin
					raw_tile[read_beat] <= read_data;
					if (read_beat == 4'd15) begin
						pixel_index  <= 6'd0;
						tile_nonzero <= 1'b0;
						state        <= COMP_PIXEL_PRIME;
					end else begin
						read_beat <= read_beat + 4'd1;
					end
				end
			end

			COMP_PIXEL_PRIME: begin
				next_raw_pixel_q      <= raw_tile_dirty ? raw_pixel[11:0] : 12'd0;
				next_old_pixel_q      <= source_tile_dirty ? {old_pixel[15], old_pixel[11:0]}
				                                           : 13'd0;
				next_raw_age_q        <= raw_pixel_age;
				lookahead_pixel_index <= 6'd1;
				state                 <= COMP_PIXEL_LOAD;
			end

			COMP_PIXEL_LOAD: begin
				raw_intensity_q    <= next_raw_pixel_q[10:0];
				raw_dwell_excess_q <= next_raw_pixel_q[11];
				old_dwell_excess_q <= next_old_pixel_q[11];
				raw_factor_q       <= staged_raw_factor;
				raw_bypass_q       <= (intra_mode_q == INTRA_OFF);
				old_intensity_q    <= next_old_decay_energy;
				old_factor_q       <= next_old_uses_fresh ? fresh_decay_factor_q
				                                          : tail_decay_factor_q;
				state              <= COMP_PIXEL_RAW;
			end

			COMP_PIXEL_RAW: begin
				raw_product_q <= raw_intensity_q * raw_factor_q;
				if (pixel_index != 6'd63) begin
					next_raw_pixel_q <= raw_tile_dirty ? next_raw_pixel[11:0] : 12'd0;
					next_old_pixel_q <= source_tile_dirty ?
					                    {next_old_pixel[15], next_old_pixel[11:0]} :
					                    13'd0;
					next_raw_age_q   <= raw_pixel_age;
				end
				state <= COMP_PIXEL_OLD;
			end

			COMP_PIXEL_OLD: begin
				old_product_q <= old_intensity_q * old_factor_q;
				if (pixel_index != 6'd63) begin
					next_raw_factor_q <= staged_raw_factor;
					next_old_factor_q <= next_old_uses_fresh ? fresh_decay_factor_q
					                                         : tail_decay_factor_q;
				end
				state <= COMP_PIXEL_BLEND;
			end

			COMP_PIXEL_BLEND: begin
				blend_energy_q       <= selected_blend_energy;
				blend_fresh_q        <= raw_wins;
				blend_dwell_excess_q <= raw_wins ? raw_dwell_excess_q : old_dwell_excess_q;
				state                <= COMP_PIXEL_STORE;
			end

			COMP_PIXEL_STORE: begin
				pending_pixel_q   <= stored_pixel;
				pending_word_q    <= pixel_index[5:2];
				pending_lane_q    <= pixel_index[1:0];
				pending_nonzero_q <= (blend_energy_q != 11'd0);
				pending_write_q   <= 1'b1;
				if (pixel_index == 6'd63) begin
					state <= COMP_PIXEL_DRAIN;
				end else begin
					pixel_index           <= pixel_index + 6'd1;
					lookahead_pixel_index <= lookahead_pixel_index + 6'd1;
					raw_intensity_q       <= next_raw_pixel_q[10:0];
					raw_dwell_excess_q    <= next_raw_pixel_q[11];
					old_dwell_excess_q    <= next_old_pixel_q[11];
					raw_factor_q          <= next_raw_factor_q;
					raw_bypass_q          <= (intra_mode_q == INTRA_OFF);
					old_intensity_q       <= next_old_decay_energy;
					old_factor_q          <= next_old_factor_q;
					state                 <= COMP_PIXEL_RAW;
				end
			end

			COMP_PIXEL_DRAIN: begin
				if (tile_nonzero_final) begin
					write_addr  <= target_tile_addr;
					write_ready <= 1'b1;
					write_beat  <= 4'd0;
					write_data  <= composed_tile[0];
					state       <= COMP_WRITE_REQUEST;
				end else begin
					tilemap_write_hot <= target_buf_hot_q;
					tilemap_write_din <= 1'b0;
					state             <= COMP_MAP_COMMIT;
				end
			end

			COMP_WRITE_REQUEST: begin
				if (write_grant) begin
					write_ready <= 1'b0;
					state       <= COMP_WRITE_WAIT;
				end
			end

			COMP_WRITE_WAIT: begin
				if (write_done) begin
					tilemap_write_hot <= target_buf_hot_q;
					tilemap_write_din <= tile_nonzero;
					state             <= COMP_MAP_COMMIT;
				end
			end

			COMP_MAP_COMMIT: begin
				state <= COMP_NEXT_TILE;
			end

			COMP_NEXT_TILE: begin
				if (tile_row_end_q && tile_last_row_q) begin
					compose_done <= 1'b1;
					state        <= COMP_WAIT_REQUEST_LOW;
				end else if (tile_row_end_q) begin
					tile_x       <= 8'd0;
					tile_y       <= tile_y + 8'd1;
					tilemap_addr <= vfb_tile_row_addr(tile_y + 8'd1);
					state        <= COMP_MAP_ISSUE;
				end else begin
					tile_x       <= tile_x + 8'd1;
					tilemap_addr <= tilemap_addr + 15'd1;
					state        <= COMP_MAP_ISSUE;
				end
			end

			COMP_WAIT_REQUEST_LOW: begin
				if (!compose_req) state <= COMP_IDLE;
			end

			default: state <= COMP_IDLE;
		endcase
	end
end

endmodule

`default_nettype wire
