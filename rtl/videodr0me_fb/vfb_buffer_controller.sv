`timescale 1ns / 1ps

// ============================================================================
// Sparse framebuffer ownership controller.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Five buffers circulate through CLEAN -> DRAWING -> DRAWN. With inter-frame
// decay off, DRAWN can become DISPLAY at EOF, EOF + VBL or VBL. With
// inter-frame decay enabled, a DRAWN target becomes COMPOSING and is blended
// with the latest accumulated frame, if available. Only the target is
// modified; the source frame stays unchanged. The result becomes COMPOSED
// before display.
// Retired buffers pass through DIRTY -> CLEARING -> CLEAN.
// ============================================================================

`default_nettype none

module vfb_buffer_controller #(
	parameter integer BUFFER_COUNT = 5,
	parameter integer BUF_IDX_W = 3
) (
	input  wire  clk_sys,
	input  wire  reset,

	// 0 = EOF + VBL, 1 = VBL only, 2 = EOF only
	input  wire  [1:0] BUFFER_MODE,
	input  wire  [1:0] inter_frame_mode,

	input  wire  eof_token_popped,
	input  wire  vbl_swap_req,

	output logic flush_req,
	input  wire  flush_done,

	output logic                 clear_req,
	output logic [BUF_IDX_W-1:0] clear_buf_idx,
	input  wire                  clear_done,

	output logic                 compose_req,
	output logic [BUF_IDX_W-1:0] compose_source_buf,
	output logic [BUF_IDX_W-1:0] compose_target_buf,
	output logic                 compose_has_source,
	output logic                 compose_source_is_composed,
	input  wire                  compose_done,

	output logic [BUF_IDX_W-1:0]    buf_draw,
	output logic [BUF_IDX_W-1:0]    buf_display_out,
	output logic                    display_valid,
	output logic                    display_is_composed,
	output logic                    has_draw_buf,
	output logic [BUFFER_COUNT-1:0] buf_draw_hot,
	output logic                    raw_frame_dropped,
	output logic [BUF_IDX_W-1:0]    raw_frame_dropped_buf,
	output logic                    readout_frame_start
);
import vfb_control_pkg::*;

initial begin
	if (BUFFER_COUNT < 2 || BUFFER_COUNT > vfb_layout_pkg::VFB_BUFFER_COUNT)
		$error("vfb_buffer_controller BUFFER_COUNT must fit the framebuffer layout (2..5)");
	if (BUF_IDX_W < $clog2(BUFFER_COUNT + 1))
		$error("vfb_buffer_controller BUF_IDX_W must represent BUFFER_COUNT");
end

typedef enum logic [3:0] {
	ST_DISPLAY,
	ST_DRAWING,
	ST_DRAWN,
	ST_COMPOSING,
	ST_COMPOSED,
	ST_DIRTY,
	ST_CLEARING,
	ST_CLEAN
} buf_state_t;

typedef struct packed {
	logic                    raw;
	logic [BUFFER_COUNT-1:0] raw_hot;
	logic                    composed;
	logic [BUF_IDX_W-1:0]    composed_idx;
} vbl_promotion_t;

typedef struct packed {
	logic flush_complete;
	logic compose_start;
	logic compose_complete;
	logic assign_draw;
	logic clear_start;
	logic clear_complete;
	logic drop_raw;
} controller_event_t;

buf_state_t              buf_state [0:BUFFER_COUNT-1];
// One-hot completion order, oldest first; completed drawings move last.
logic [BUFFER_COUNT-1:0] completion_order [0:BUFFER_COUNT-1];
logic                    buffer_is_composed [0:BUFFER_COUNT-1];

logic                 accumulator_valid;
logic [BUF_IDX_W-1:0] accumulator_buf;
logic                 compose_active;
logic                 inter_enabled_q;
vbl_promotion_t       vbl_promotion_d;
vbl_promotion_t       vbl_promotion_q;
controller_event_t    evt;
logic [1:0]           buffer_mode_q      = BUFFER_EOF_VBL;
logic [1:0]           inter_frame_mode_q = INTER_OFF;

always_ff @(posedge clk_sys) begin
	buffer_mode_q      <= BUFFER_MODE;
	inter_frame_mode_q <= inter_frame_mode;
end

logic                    has_display;
logic                    has_drawing;
logic                    has_drawn;
logic                    has_dirty;
logic                    has_clean;
logic [BUFFER_COUNT-1:0] drawing_mask;
logic [BUFFER_COUNT-1:0] drawn_mask;
logic [BUFFER_COUNT-1:0] drawn_by_age;
logic [BUFFER_COUNT-1:0] drawn_at_age [0:BUFFER_COUNT-1];
logic [BUFFER_COUNT-1:0] oldest_drawn_onehot;
logic [BUFFER_COUNT-1:0] newest_drawn_onehot;
logic [BUFFER_COUNT-1:0] oldest_drawn_onehot_q;
logic [BUF_IDX_W-1:0]    display_idx;
logic [BUF_IDX_W-1:0]    oldest_drawn_idx;
logic [BUF_IDX_W-1:0]    oldest_drawn_idx_q;
logic                    oldest_drawn_valid_q;
logic [BUF_IDX_W-1:0]    dirty_idx;
logic [BUF_IDX_W-1:0]    clean_idx;
logic                    oldest_found;
logic                    newest_found;

function automatic logic [BUFFER_COUNT-1:0] index_to_onehot(
	input logic [BUF_IDX_W-1:0] index
);
	begin
		index_to_onehot        =   '0;
		index_to_onehot[index] = 1'b1;
	end
endfunction

function automatic logic [BUF_IDX_W-1:0] onehot_to_index(
	input logic [BUFFER_COUNT-1:0] onehot
);
	begin
		onehot_to_index = '0;
		for (int i = 0; i < BUFFER_COUNT; i++) begin
			if (onehot[i]) onehot_to_index = BUF_IDX_W'(i);
		end
	end
endfunction

function automatic logic onehot_valid(
	input logic [BUFFER_COUNT-1:0] onehot
);
	begin
		onehot_valid = (onehot != '0) && ((onehot & (onehot - 1'b1)) == '0);
	end
endfunction

always_comb begin
	has_display  = 1'b0;
	has_drawing  = 1'b0;
	has_drawn    = 1'b0;
	has_dirty    = 1'b0;
	has_clean    = 1'b0;
	drawing_mask =   '0;
	drawn_mask   =   '0;
	display_idx  =   '0;
	dirty_idx    =   '0;
	clean_idx    =   '0;

	for (int i = 0; i < BUFFER_COUNT; i++) begin
		if (buf_state[i] == ST_DISPLAY) begin
			has_display = 1'b1;
			display_idx = BUF_IDX_W'(i);
		end

		if (buf_state[i] == ST_DRAWING) begin
			has_drawing     = 1'b1;
			drawing_mask[i] = 1'b1;
		end

		if (buf_state[i] == ST_DRAWN) begin
			has_drawn     = 1'b1;
			drawn_mask[i] = 1'b1;
		end

		if (buf_state[i] == ST_DIRTY && !has_dirty) begin
			has_dirty = 1'b1;
			dirty_idx = BUF_IDX_W'(i);
		end

		if (buf_state[i] == ST_CLEAN && !has_clean) begin
			has_clean = 1'b1;
			clean_idx = BUF_IDX_W'(i);
		end
	end
end

always_comb begin
	oldest_drawn_onehot =   '0;
	newest_drawn_onehot =   '0;
	oldest_found        = 1'b0;
	newest_found        = 1'b0;
	for (int age = 0; age < BUFFER_COUNT; age++) begin
		drawn_at_age[age] = completion_order[age] & drawn_mask;
		drawn_by_age[age] = |drawn_at_age[age];
	end

	for (int age = 0; age < BUFFER_COUNT; age++) begin
		if (!oldest_found && drawn_by_age[age]) begin
			oldest_drawn_onehot = drawn_at_age[age];
			oldest_found        = 1'b1;
		end
		if (!newest_found && drawn_by_age[BUFFER_COUNT-1-age]) begin
			newest_drawn_onehot = drawn_at_age[BUFFER_COUNT-1-age];
			newest_found        = 1'b1;
		end
	end

	oldest_drawn_idx = onehot_to_index(oldest_drawn_onehot);
end

// Register the oldest queued buffer before composition and recycling
// select their next buffer.
always_ff @(posedge clk_sys) begin
	if (reset) begin
		oldest_drawn_onehot_q <=   '0;
		oldest_drawn_idx_q    <=   '0;
		oldest_drawn_valid_q  <= 1'b0;
	end else begin
		oldest_drawn_onehot_q <= oldest_drawn_onehot;
		oldest_drawn_idx_q    <= oldest_drawn_idx;
		oldest_drawn_valid_q  <= onehot_valid(oldest_drawn_onehot);
	end
end

logic [BUF_IDX_W-1:0] internal_buf_draw;
(* preserve, dont_merge *) logic [BUFFER_COUNT-1:0] buf_draw_hot_reg;

assign buf_draw     = internal_buf_draw;
assign buf_draw_hot = buf_draw_hot_reg;
assign compose_req  = compose_active;
always_ff @(posedge clk_sys) begin
	if (reset) begin
		buf_display_out     <=   '0;
		has_draw_buf        <= 1'b0;
		buf_draw_hot_reg    <=   '0;
		display_valid       <= 1'b0;
		display_is_composed <= 1'b0;
	end else begin
		buf_display_out     <= display_idx;
		has_draw_buf        <= has_drawing;
		buf_draw_hot_reg    <= drawing_mask;
		display_valid       <= has_display;
		display_is_composed <= buffer_is_composed[display_idx];
	end
end

localparam logic [1:0] DISPLAY_SETTLE_CYCLES = 2'd3;

logic       flush_pending;
logic       display_wait_flush;
logic [1:0] display_settle_count;

// Inter-frame mode transitions.
wire inter_enabled         = (inter_frame_mode_q != INTER_OFF);
wire inter_enable_rise     = inter_enabled && !inter_enabled_q;
wire inter_enable_fall     = !inter_enabled && inter_enabled_q;
wire accumulator_idx_valid = (accumulator_buf < BUF_IDX_W'(BUFFER_COUNT));
// The registered selection can outlive the buffer's DRAWN state by one clock.
wire oldest_drawn_ready = oldest_drawn_valid_q &&
                          |(oldest_drawn_onehot_q & drawn_mask);

// Select the buffer to display at VBLANK.
always_comb begin
	vbl_promotion_d.raw          = vbl_swap_req &&
	                               (buffer_mode_q == BUFFER_EOF_VBL) &&
	                               !inter_enabled && has_drawn;
	vbl_promotion_d.raw_hot      = newest_drawn_onehot;
	vbl_promotion_d.composed     = vbl_swap_req && (buffer_mode_q != BUFFER_EOF) && inter_enabled &&
	                               accumulator_valid && accumulator_idx_valid &&
	                               (buf_state[accumulator_buf] == ST_COMPOSED);
	vbl_promotion_d.composed_idx = accumulator_buf;
end

always_comb begin
	evt                  = '0;
	evt.flush_complete   = flush_req && flush_done;
	evt.compose_start    = inter_enabled && !inter_enable_rise &&
	                       !compose_active && oldest_drawn_ready;
	evt.compose_complete = compose_active && compose_done;
	evt.assign_draw      = !has_drawing && has_clean && !flush_req;
	evt.clear_start      = !clear_req && has_dirty &&
	                       !vbl_promotion_q.raw &&
	                       !vbl_promotion_q.composed;
	evt.clear_complete   = clear_req && clear_done;
	// Retire queued raw frames only while composition is busy. A completing
	// composition may release a buffer without discarding another frame.
	evt.drop_raw = inter_enabled && compose_active &&
	               !evt.compose_complete && oldest_drawn_ready &&
	               !has_drawing && !has_clean && !has_dirty && !clear_req;
end

logic [BUFFER_COUNT-1:0] completed_buffer_onehot;
logic [BUFFER_COUNT-1:0] completed_order_position;
logic [BUFFER_COUNT-1:0] completed_order_shift;
always_comb begin
	completed_buffer_onehot = index_to_onehot(internal_buf_draw);
	completed_order_shift   = '0;
	for (int age = 0; age < BUFFER_COUNT; age++) begin
		completed_order_position[age] = |(completion_order[age] & completed_buffer_onehot);
		if (age == 0)
			completed_order_shift[age] = completed_order_position[age];
		else
			completed_order_shift[age] = completed_order_shift[age-1] |
			                             completed_order_position[age];
	end
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		vbl_promotion_q <= '0;
	end else begin
		vbl_promotion_q <= vbl_promotion_d;
	end
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		buf_state[0] <= ST_DISPLAY;
		buf_state[1] <= ST_DRAWING;
		for (int i = 2; i < BUFFER_COUNT; i++)
			buf_state[i] <= ST_DIRTY;

		for (int i = 0; i < BUFFER_COUNT; i++) begin
			completion_order[i]   <= index_to_onehot(BUF_IDX_W'(i));
			buffer_is_composed[i] <= 1'b0;
		end

		internal_buf_draw          <= BUF_IDX_W'(1);
		flush_req                  <= 1'b0;
		flush_pending              <= 1'b0;
		display_wait_flush         <= 1'b0;
		display_settle_count       <= 2'd0;
		readout_frame_start        <= 1'b0;
		clear_req                  <= 1'b0;
		clear_buf_idx              <=   '0;
		compose_active             <= 1'b0;
		compose_source_buf         <=   '0;
		compose_target_buf         <=   '0;
		compose_has_source         <= 1'b0;
		compose_source_is_composed <= 1'b0;
		accumulator_valid          <= 1'b0;
		accumulator_buf            <=   '0;
		inter_enabled_q            <= inter_enabled;
		raw_frame_dropped          <= 1'b0;
		raw_frame_dropped_buf      <=   '0;
	end else begin
		inter_enabled_q     <= inter_enabled;
		raw_frame_dropped   <= evt.drop_raw;
		readout_frame_start <= 1'b0;

		// Let the selected display and its tilemap address settle before prefetch.
		if (vbl_swap_req) begin
			if ((buffer_mode_q == BUFFER_VBL) && !inter_enabled &&
				has_drawing && !evt.flush_complete) begin
				display_wait_flush   <= 1'b1;
				display_settle_count <= 2'd0;
			end else begin
				display_wait_flush   <= 1'b0;
				display_settle_count <= DISPLAY_SETTLE_CYCLES;
			end
		end else if (display_wait_flush && evt.flush_complete) begin
			display_wait_flush   <= 1'b0;
			display_settle_count <= DISPLAY_SETTLE_CYCLES;
		end else if (display_settle_count != 2'd0) begin
			display_settle_count <= display_settle_count - 1'b1;
			if (display_settle_count == 2'd1) readout_frame_start <= 1'b1;
		end

		if (evt.drop_raw) raw_frame_dropped_buf <= oldest_drawn_idx_q;

		if (buffer_mode_q == BUFFER_VBL) begin
			if (vbl_swap_req && has_drawing) flush_pending <= 1'b1;
		end else if (eof_token_popped && has_drawing) begin
			flush_pending <= 1'b1;
		end

		if (evt.flush_complete) begin
			flush_req <= 1'b0;
		end else if (!flush_req && flush_pending) begin
			flush_req     <= 1'b1;
			flush_pending <= 1'b0;
		end

		for (int i = 0; i < BUFFER_COUNT; i++) begin
			if (vbl_promotion_q.raw && vbl_promotion_q.raw_hot[i]) begin
				buf_state[i] <= ST_DISPLAY;
			end else if (vbl_promotion_q.raw && (buf_state[i] == ST_DISPLAY)) begin
				buf_state[i] <= ST_DIRTY;
			end else if (evt.compose_complete && (BUF_IDX_W'(i) == compose_target_buf)) begin
				if (!inter_enabled)
					buf_state[i] <= ST_DRAWN;
				else
					buf_state[i] <= (buffer_mode_q == BUFFER_EOF) ? ST_DISPLAY : ST_COMPOSED;
			end else if (evt.compose_complete &&
				inter_enabled &&
				(buffer_mode_q == BUFFER_EOF) &&
				(buf_state[i] == ST_DISPLAY)) begin
				buf_state[i] <= ST_DIRTY;
			end else if (evt.compose_complete && compose_has_source &&
				(BUF_IDX_W'(i) == compose_source_buf) &&
				(buf_state[i] == ST_COMPOSED) &&
				!vbl_promotion_q.composed) begin
				buf_state[i] <= ST_DIRTY;
			end else if (inter_enable_fall &&
				(buf_state[i] == ST_COMPOSED)) begin
				buf_state[i] <= ST_DRAWN;
			end else if (vbl_promotion_q.composed &&
				(BUF_IDX_W'(i) == vbl_promotion_q.composed_idx)) begin
				buf_state[i] <= ST_DISPLAY;
			end else if (vbl_promotion_q.composed &&
				(buf_state[i] == ST_DISPLAY)) begin
				buf_state[i] <= ST_DIRTY;
			end else if (evt.flush_complete &&
				(BUF_IDX_W'(i) == internal_buf_draw)) begin
				buf_state[i] <= inter_enabled ? ST_DRAWN :
					((buffer_mode_q == BUFFER_EOF_VBL) ? ST_DRAWN : ST_DISPLAY);
			end else if (evt.flush_complete && !inter_enabled &&
				(buffer_mode_q != BUFFER_EOF_VBL) &&
				(buf_state[i] == ST_DISPLAY)) begin
				buf_state[i] <= ST_DIRTY;
			end else if (evt.compose_start &&
				oldest_drawn_onehot_q[i]) begin
				buf_state[i] <= ST_COMPOSING;
			end else if (!inter_enabled && (buf_state[i] == ST_DRAWN) &&
				((buffer_mode_q != BUFFER_EOF_VBL) || evt.flush_complete ||
					vbl_promotion_q.raw)) begin
				buf_state[i] <= ST_DIRTY;
			end else if (evt.drop_raw && oldest_drawn_onehot_q[i]) begin
				buf_state[i] <= ST_DIRTY;
			end else if (evt.assign_draw && (BUF_IDX_W'(i) == clean_idx)) begin
				buf_state[i] <= ST_DRAWING;
			end else if (evt.clear_complete && (BUF_IDX_W'(i) == clear_buf_idx)) begin
				buf_state[i] <= ST_CLEAN;
			end else if (evt.clear_start && (BUF_IDX_W'(i) == dirty_idx)) begin
				buf_state[i] <= ST_CLEARING;
			end
		end

		if (evt.flush_complete) begin
			for (int age = 0; age < BUFFER_COUNT-1; age++)
				if (completed_order_shift[age]) completion_order[age] <= completion_order[age+1];
			if (completed_order_shift[BUFFER_COUNT-2])
				completion_order[BUFFER_COUNT-1] <= completed_buffer_onehot;
		end

		if (evt.compose_start) begin
			compose_active             <= 1'b1;
			compose_target_buf         <= oldest_drawn_idx_q;
			compose_source_buf         <= accumulator_buf;
			compose_has_source         <= accumulator_valid;
			compose_source_is_composed <= accumulator_valid &&
			                              accumulator_idx_valid &&
			                              buffer_is_composed[accumulator_buf];
		end else if (evt.compose_complete) begin
			compose_active <= 1'b0;
		end

		if (evt.compose_complete) begin
			accumulator_valid <= inter_enabled;
			if (inter_enabled) accumulator_buf <= compose_target_buf;
		end else if (inter_enable_rise) begin
			accumulator_valid <= has_display;
			accumulator_buf   <= display_idx;
		end else if (inter_enable_fall) begin
			accumulator_valid <= 1'b0;
		end

		if (evt.compose_complete) buffer_is_composed[compose_target_buf] <= 1'b1;
		if (evt.assign_draw)      buffer_is_composed[clean_idx]          <= 1'b0;
		if (evt.clear_complete)   buffer_is_composed[clear_buf_idx]      <= 1'b0;

		if (evt.assign_draw) internal_buf_draw <= clean_idx;

		if (evt.clear_complete) begin
			clear_req <= 1'b0;
		end else if (evt.clear_start) begin
			clear_req     <= 1'b1;
			clear_buf_idx <= dirty_idx;
		end
	end
end

endmodule

`default_nettype wire
