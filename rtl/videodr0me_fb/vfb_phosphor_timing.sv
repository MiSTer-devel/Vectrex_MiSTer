// ============================================================================
// Phosphor timing.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// Measures source frame rate and converts draw phases to physical age.
// ============================================================================

`default_nettype none

module vfb_phosphor_timing #(
	parameter [15:0]  AGE_QUANTUM_CLKS     =  16'd18519,
	parameter [17:0]  SYS_AGE_QUANTUM_CLKS = 18'd191364,
	parameter integer BUFFER_COUNT         =          5,
	parameter integer BUF_IDX_W            =          3
) (
	input wire clk_source,
	input wire clk_sys,
	input wire reset_source,
	input wire reset_sys,
	input wire frame_done,

	input wire                 eof_token_popped,
	input wire [15:0]          eof_frame_tick_clks_popped,
	input wire [15:0]          eof_elapsed_frame_tick_clks_popped,
	input wire [BUF_IDX_W-1:0] buf_draw,
	input wire [BUF_IDX_W-1:0] buf_display,
	input wire                 vbl_swap_req,
	input wire                 presentation_120hz,
	input wire [1:0]           BUFFER_MODE,

	input  wire                  compose_req,
	input  wire  [BUF_IDX_W-1:0] compose_buf,
	input  wire                  raw_frame_dropped,
	input  wire  [BUF_IDX_W-1:0] raw_frame_dropped_buf,
	output logic [3:0]           compose_draw_idx,
	output logic [63:0]          compose_age_map,
	output logic [3:0]           compose_frame_age,
	output logic                 compose_metadata_ready,

	output logic [3:0]  draw_idx,
	output logic [15:0] active_frame_tick_clks,
	output logic [15:0] completed_frame_tick_clks,
	output logic [3:0]  readout_draw_idx,
	output logic [63:0] readout_age_map
);
import vfb_control_pkg::*;

localparam [15:0] DEFAULT_TICK_CLKS     = (AGE_QUANTUM_CLKS == 16'd0) ? 16'd1 : AGE_QUANTUM_CLKS;
localparam [16:0] AGE_QUANTUM_EXT       = {1'b0, DEFAULT_TICK_CLKS};
localparam [16:0] AGE_HALF_QUANTUM      = {1'b0, (DEFAULT_TICK_CLKS >> 1)};
localparam [17:0] SYS_DEFAULT_TICK_CLKS = (SYS_AGE_QUANTUM_CLKS == 18'd0) ? 18'd1
                                                                          : SYS_AGE_QUANTUM_CLKS;
localparam [17:0] SYS_HALF_QUANTUM      = SYS_DEFAULT_TICK_CLKS >> 1;
localparam [63:0] IDENTITY_AGE_MAP      = 64'hFEDCBA9876543210;

function automatic [15:0] frame_tick_from_period(input logic [19:0] period);
	logic [16:0] rounded_tick;
	begin
		if (period[19:4] == 16'hffff) begin
			frame_tick_from_period = 16'hffff;
		end else begin
			rounded_tick           = {1'b0, period[19:4]} + {16'd0, period[3]};
			frame_tick_from_period = (rounded_tick == 17'd0) ? 16'd1 : rounded_tick[15:0];
		end
	end
endfunction

logic        frame_done_q;
logic        have_eof_reference;
logic [19:0] eof_period_count;
logic [15:0] draw_tick_count;
// Hold the phase across source resets so its Gray code never jumps to zero
// while the renderer continues running.
logic [3:0] draw_idx_source  = 4'd0;
logic [3:0] draw_gray_source = 4'd0;
wire  [3:0] draw_idx_next    = draw_idx_source + 4'd1;

wire          frame_done_rise           = frame_done && !frame_done_q;
wire   [15:0] measured_frame_tick_clks  = frame_tick_from_period(eof_period_count);
assign        completed_frame_tick_clks = have_eof_reference ? measured_frame_tick_clks
                                                             : active_frame_tick_clks;

always_ff @(posedge clk_source) begin
	if (reset_source) begin
		frame_done_q           <=  1'b0;
		have_eof_reference     <=  1'b0;
		eof_period_count       <= 20'd0;
		draw_tick_count        <= 16'd0;
		active_frame_tick_clks <= DEFAULT_TICK_CLKS;
	end else begin
		frame_done_q <= frame_done;

		if (draw_tick_count >= active_frame_tick_clks - 16'd1) begin
			draw_tick_count  <= 16'd0;
			draw_idx_source  <= draw_idx_next;
			draw_gray_source <= draw_idx_next ^ (draw_idx_next >> 1);
		end else begin
			draw_tick_count <= draw_tick_count + 16'd1;
		end

		if (frame_done_rise) begin
			eof_period_count <= 20'd1;
			if (have_eof_reference)
				active_frame_tick_clks <= measured_frame_tick_clks;
			else
				have_eof_reference <= 1'b1;
		end else if (eof_period_count != 20'hfffff) begin
			eof_period_count <= eof_period_count + 20'd1;
		end
	end
end

// Register Gray code at the source; decode only after both synchronizer stages.
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
logic [3:0] draw_gray_meta;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
logic [3:0] draw_gray_sync;
always_ff @(posedge clk_sys) begin
	if (reset_sys) begin
		draw_gray_meta <= 4'd0;
		draw_gray_sync <= 4'd0;
	end else begin
		draw_gray_meta <= draw_gray_source;
		draw_gray_sync <= draw_gray_meta;
	end
end
assign draw_idx = {draw_gray_sync[3], ^draw_gray_sync[3:2], ^draw_gray_sync[3:1], ^draw_gray_sync};

logic [63:0]             buf_age_map [0:BUFFER_COUNT-1];
logic [3:0]              buf_frame_age [0:BUFFER_COUNT-1];
logic [BUFFER_COUNT-1:0] buf_metadata_ready;
// Frame age covers every drawn frame, including frames dropped before
// composition. Drops during composition carry into the next composition.
logic       compose_req_q;
logic [3:0] skipped_frame_age;
logic [3:0] compose_age_carry;
logic       compose_age_carry_valid;

typedef struct packed {
	logic                 valid;
	logic                 store_buffer;
	logic [BUF_IDX_W-1:0] buffer_idx;
	logic [15:0]          tick;
	logic [15:0]          elapsed_tick;
} age_map_request_t;

typedef struct packed {
	logic                 active;
	logic                 finishing_frame;
	logic                 store_buffer;
	logic [BUF_IDX_W-1:0] buffer_idx;
	logic [3:0]           index;
	logic [3:0]           age;
	logic [15:0]          tick;
	logic [15:0]          elapsed_tick;
	logic [20:0]          remainder;
	logic [63:0]          data;
} age_map_build_t;

typedef struct packed {
	logic                 valid;
	logic                 store_buffer;
	logic [BUF_IDX_W-1:0] buffer_idx;
	logic [63:0]          data;
	logic [3:0]           frame_age;
} age_map_result_t;

age_map_request_t     map_request_q;
age_map_build_t       map_build_q;
age_map_result_t      map_result_q;
logic [63:0]          latest_age_map;
logic [BUF_IDX_W-1:0] prev_buf_display;
logic                 have_vbl_reference;
logic [17:0]          vbl_age_tick_count;
logic [3:0]           vbl_elapsed_age;
logic                 presentation_120hz_control_q = 1'b0;
logic [1:0]           buffer_mode_q                = BUFFER_EOF_VBL;
logic                 presentation_120hz_q;
logic                 presentation_vbl_half;

always_ff @(posedge clk_sys) begin
	presentation_120hz_control_q <= presentation_120hz;
	buffer_mode_q                <= BUFFER_MODE;
end

wire [15:0] popped_frame_tick_clks         = (eof_frame_tick_clks_popped == 16'd0) ?
                                             DEFAULT_TICK_CLKS :
                                             eof_frame_tick_clks_popped;
wire [15:0] popped_elapsed_frame_tick_clks = (eof_elapsed_frame_tick_clks_popped == 16'd0) ?
                                             popped_frame_tick_clks :
                                             eof_elapsed_frame_tick_clks_popped;

function automatic [3:0] saturating_age_sum(
	input  logic [3:0] lhs,
	input  logic [3:0] rhs
);
	logic [4:0] sum;
	begin
		sum                = {1'b0, lhs} + {1'b0, rhs};
		saturating_age_sum = (sum > 5'd15) ? 4'd15 : sum[3:0];
	end
endfunction

// Independent pseudorandom phases are held for each composition/presentation.
// At 120 Hz, the presentation reference advances every other VBL.
function automatic [15:0] phase_prng_next(input logic [15:0] state);
	begin
		phase_prng_next = {state[14:0], state[15] ^ state[13] ^ state[12] ^ state[10]};
	end
endfunction

logic [15:0] readout_phase_prng;
logic [15:0] compose_phase_prng;
wire  [15:0] readout_phase_prng_next = phase_prng_next(readout_phase_prng);
wire  [15:0] compose_phase_prng_next = phase_prng_next(compose_phase_prng);

// If a dropped frame has no metadata, use maximum age instead.
wire [3:0] dropped_frame_age = buf_metadata_ready[raw_frame_dropped_buf] ?
                               buf_frame_age[raw_frame_dropped_buf] :
                               4'd15;

always_comb begin
	compose_age_map        = buf_age_map[compose_buf];
	compose_frame_age      = saturating_age_sum(buf_frame_age[compose_buf],
	                                            compose_age_carry_valid ? compose_age_carry : 4'd0);
	compose_metadata_ready = buf_metadata_ready[compose_buf] &&
	                         (!compose_req || compose_age_carry_valid);
end

always_ff @(posedge clk_sys) begin
	if (reset_sys) begin
		compose_req_q           <= 1'b0;
		skipped_frame_age       <= 4'd0;
		compose_age_carry       <= 4'd0;
		compose_age_carry_valid <= 1'b0;
		map_request_q           <=   '0;
		map_build_q             <=   '0;
		map_result_q            <=   '0;
		latest_age_map          <= IDENTITY_AGE_MAP;
		prev_buf_display        <=   '0;
		have_vbl_reference      <= 1'b0;
		vbl_age_tick_count      <= SYS_HALF_QUANTUM;
		vbl_elapsed_age         <=     4'd0;
		presentation_120hz_q    <=     1'b0;
		presentation_vbl_half   <=     1'b0;
		readout_draw_idx        <=     4'd0;
		compose_draw_idx        <=     4'd0;
		readout_phase_prng      <= 16'h1ace;
		compose_phase_prng      <= 16'hbeef;
		readout_age_map         <= IDENTITY_AGE_MAP;
		buf_metadata_ready      <= '0;
		for (int i = 0; i < BUFFER_COUNT; i++) begin
			buf_age_map[i]   <= IDENTITY_AGE_MAP;
			buf_frame_age[i] <= 4'd0;
		end
	end else begin
		compose_req_q        <= compose_req;
		presentation_120hz_q <= presentation_120hz_control_q;

		// In VBL-only mode, derive age from display swaps instead of EOF.
		if (buffer_mode_q != BUFFER_VBL) begin
			have_vbl_reference <= 1'b0;
			vbl_age_tick_count <= SYS_HALF_QUANTUM;
			vbl_elapsed_age    <= 4'd0;
		end else if (vbl_swap_req) begin
			have_vbl_reference <= 1'b1;
			vbl_age_tick_count <= SYS_HALF_QUANTUM;
			vbl_elapsed_age    <= 4'd0;
		end else if (have_vbl_reference && (vbl_age_tick_count >= SYS_DEFAULT_TICK_CLKS - 18'd1)) begin
			vbl_age_tick_count <= 18'd0;
			if (vbl_elapsed_age != 4'd15) vbl_elapsed_age <= vbl_elapsed_age + 4'd1;
		end else if (have_vbl_reference) begin
			vbl_age_tick_count <= vbl_age_tick_count + 18'd1;
		end

		if (!compose_req) compose_age_carry_valid <= 1'b0;

		if (compose_req && !compose_req_q) begin
			compose_phase_prng      <= compose_phase_prng_next;
			compose_draw_idx        <= compose_phase_prng_next[3:0];
			compose_age_carry       <= skipped_frame_age;
			compose_age_carry_valid <= 1'b1;
			skipped_frame_age       <= raw_frame_dropped ? dropped_frame_age : 4'd0;
		end else if (raw_frame_dropped) begin
			skipped_frame_age <= saturating_age_sum(skipped_frame_age, dropped_frame_age);
		end

		if (presentation_120hz_control_q != presentation_120hz_q) begin
			presentation_vbl_half <= 1'b0;
		end else if (vbl_swap_req) begin
			if (presentation_120hz_control_q) begin
				presentation_vbl_half <= ~presentation_vbl_half;
				if (!presentation_vbl_half) begin
					readout_phase_prng <= readout_phase_prng_next;
					readout_draw_idx   <= readout_phase_prng_next[3:0];
				end
			end else begin
				presentation_vbl_half <= 1'b0;
				readout_phase_prng    <= readout_phase_prng_next;
				readout_draw_idx      <= readout_phase_prng_next[3:0];
			end
		end

		prev_buf_display <= buf_display;
		if (vbl_swap_req || (buf_display != prev_buf_display)) begin
			readout_age_map <= buf_age_map[buf_display];
		end

		if (map_result_q.valid) begin
			latest_age_map <= map_result_q.data;
			if (map_result_q.store_buffer) begin
				buf_age_map[map_result_q.buffer_idx]        <= map_result_q.data;
				buf_frame_age[map_result_q.buffer_idx]      <= map_result_q.frame_age;
				buf_metadata_ready[map_result_q.buffer_idx] <= 1'b1;
			end
			map_result_q.valid <= 1'b0;
			map_build_q.active <= 1'b0;
		end else if (!map_build_q.active && map_request_q.valid) begin
			map_request_q.valid         <= 1'b0;
			map_build_q.active          <= 1'b1;
			map_build_q.finishing_frame <= 1'b0;
			map_build_q.store_buffer    <= map_request_q.store_buffer;
			map_build_q.buffer_idx      <= map_request_q.buffer_idx;
			map_build_q.index           <= 4'd1;
			map_build_q.age             <= 4'd0;
			map_build_q.tick            <= map_request_q.tick;
			map_build_q.elapsed_tick    <= map_request_q.elapsed_tick;
			map_build_q.remainder       <= AGE_HALF_QUANTUM + {5'd0, map_request_q.tick};
			map_build_q.data            <= 64'd0;
		end else if (map_build_q.active) begin
			if ((map_build_q.age == 4'd15) || (map_build_q.remainder < AGE_QUANTUM_EXT)) begin
				if (map_build_q.finishing_frame) begin
					map_result_q.valid        <= 1'b1;
					map_result_q.store_buffer <= map_build_q.store_buffer &&
					                             (buffer_mode_q != BUFFER_VBL);
					map_result_q.buffer_idx   <= map_build_q.buffer_idx;
					map_result_q.data         <= map_build_q.data;
					map_result_q.frame_age    <= map_build_q.age;
				end else if (map_build_q.index == 4'd15) begin
					map_build_q.data            <= {map_build_q.age, map_build_q.data[59:0]};
					map_build_q.age             <= 4'd0;
					map_build_q.remainder       <= AGE_HALF_QUANTUM +
					                               {1'b0, map_build_q.elapsed_tick, 4'b0000};
					map_build_q.finishing_frame <= 1'b1;
				end else begin
					map_build_q.data[{map_build_q.index, 2'b00} +: 4] <= map_build_q.age;
					map_build_q.index                                 <= map_build_q.index + 4'd1;
					if (map_build_q.age != 4'd15)
						map_build_q.remainder <= map_build_q.remainder + {5'd0, map_build_q.tick};
				end
			end else begin
				map_build_q.remainder <= map_build_q.remainder - AGE_QUANTUM_EXT;
				map_build_q.age       <= map_build_q.age + 4'd1;
			end
		end

		if (eof_token_popped) begin
			map_request_q.buffer_idx   <= buf_draw;
			map_request_q.tick         <= popped_frame_tick_clks;
			map_request_q.elapsed_tick <= popped_elapsed_frame_tick_clks;
			map_request_q.store_buffer <= (buffer_mode_q != BUFFER_VBL);
			map_request_q.valid        <= 1'b1;
			if (buffer_mode_q != BUFFER_VBL) begin
				buf_metadata_ready[buf_draw] <= 1'b0;
			end
		end

		if ((buffer_mode_q == BUFFER_VBL) && vbl_swap_req) begin
			buf_age_map[buf_draw]        <= latest_age_map;
			buf_frame_age[buf_draw]      <= have_vbl_reference ? vbl_elapsed_age : 4'd0;
			buf_metadata_ready[buf_draw] <= 1'b1;
		end
	end
end

endmodule

`default_nettype wire
