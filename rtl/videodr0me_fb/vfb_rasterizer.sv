// ============================================================================
// Vector pixel FIFO and rasterizer.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// Receives framebuffer pixels and end-of-frame markers from the beam adapter.
//
// Pixel path: clock-crossing FIFO -> input register -> pixel generation
//             -> tile cache.
//
// Emit the input pixel first; this is the primary pixel. Then emit its
// dwell-footprint neighbours, or a fill pixel for a one-pixel diagonal.
// End-of-frame markers follow the preceding pixels through the same FIFO.
// ============================================================================

`default_nettype none

module vfb_rasterizer #(
	parameter FIFO_ADDR_W = 10
) (
	input  wire  clk_sys,
	input  wire  clk_source,
	input  wire  reset,

	// Source pixels and ordered EOF markers
	input  wire  [10:0] X_VECTOR,
	input  wire  [10:0] Y_VECTOR,
	input  wire  [11:0] Z_VECTOR,
	input  wire  [13:0] DWELL_DOSE, // Calibrated dot dose in units of four; zero for lines.
	input  wire         BEAM_ON,
	input  wire         RMW_REPLACE,
	input  wire         FRAME_DONE,

	// Dwell controls synchronized to clk_sys by vfb_top.
	input  wire  [2:0]  DWELL_LOW_SIZE,
	input  wire  [2:0]  DWELL_MID_GROWTH,
	input  wire  [2:0]  DWELL_HIGH_GROWTH,

	input  wire  [11:0] FB_WIDTH,
	input  wire  [11:0] FB_HEIGHT,

	// Tile cache output
	output logic        pixel_valid,
	input  wire         pixel_ready,
	output logic [15:0] pixel_tile_id,
	output logic [5:0]  pixel_offset,
	output logic [15:0] pixel_data,
	output logic        pixel_replace,
	output logic        pixel_dwell_high_dose,
	input  wire  [3:0]  draw_idx,         // Pixel draw-time phase
	input  wire  [15:0] frame_tick_clks,  // Source clocks per draw-index phase
	input  wire  [15:0] completed_frame_tick_clks,

	output logic        eof_token,
	output logic [15:0] eof_completed_frame_tick_clks,
	output logic        fifo_full_led
);

import vfb_dwell_pkg::*;
import vfb_control_pkg::*;

// Clock-crossing FIFO ------------------------------------------------------

localparam FIFO_DEPTH = 1 << FIFO_ADDR_W;
localparam FIFO_PTR_W = FIFO_ADDR_W + 1;

function automatic logic [FIFO_PTR_W-1:0] b2g(input logic [FIFO_PTR_W-1:0] b);
	b2g = b ^ (b >> 1);
endfunction

function automatic logic [FIFO_PTR_W-1:0] g2b(input logic [FIFO_PTR_W-1:0] g);
	logic [FIFO_PTR_W-1:0] b;
	begin
		b[FIFO_PTR_W-1] = g[FIFO_PTR_W-1];
		for (int i=FIFO_PTR_W-2; i>=0; i=i-1)
			b[i] = b[i+1] ^ g[i];
		g2b = b;
	end
endfunction

(* ramstyle = "M10K" *) logic [49:0] fifo_mem [0:FIFO_DEPTH-1];

logic [FIFO_PTR_W-1:0] wr_ptr   = 0;
logic [FIFO_PTR_W-1:0] wr_ptr_g = 0;
logic [FIFO_PTR_W-1:0] rd_ptr   = 0;
logic [FIFO_PTR_W-1:0] rd_ptr_g = 0;

(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [FIFO_PTR_W-1:0] wr_ptr_g_sync1    = 0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [FIFO_PTR_W-1:0] wr_ptr_g_sync2    = 0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [FIFO_PTR_W-1:0] rd_ptr_g_sync1_12 = 0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [FIFO_PTR_W-1:0] rd_ptr_g_sync2_12 = 0;

// FIFO writes (clk_source) -------------------------------------------------

logic last_frame_done = 0;

wire push_eof = (FRAME_DONE && !last_frame_done);
wire push_pix = BEAM_ON;

wire [49:0] eof_data = { 14'd0, 1'b0, 1'b1, 2'd0, completed_frame_tick_clks, frame_tick_clks };
wire [49:0] pixel_data_in = {
	DWELL_DOSE,   // 49:36: dwell-size dose in units of four; zero for line pixels.
	RMW_REPLACE,  // 35: RMW policy for the primary and generated pixels.
	1'b0,         // 34: EOF
	Y_VECTOR,     // 33:23
	X_VECTOR,     // 22:12
	Z_VECTOR      // 11:0
};

logic        eof_pending      = 1'b0;
logic [49:0] eof_pending_data = 50'd0;
logic        source_overflow  = 1'b0;

wire [FIFO_PTR_W-1:0] wr_ptr_next   = wr_ptr + 1'b1;
wire [FIFO_PTR_W-1:0] wr_ptr_g_next = b2g(wr_ptr_next);
wire [FIFO_PTR_W-1:0] rd_ptr_bin_12 = g2b(rd_ptr_g_sync2_12);
wire [FIFO_PTR_W-1:0] fifo_used_12  = wr_ptr - rd_ptr_bin_12;

// Stop pixel writes one entry before full, leaving room for an EOF marker.
wire        fifo_full_12       = (fifo_used_12 >= FIFO_PTR_W'(FIFO_DEPTH));
wire        fifo_pixel_full_12 = (fifo_used_12 >= FIFO_PTR_W'(FIFO_DEPTH - 1));
wire        service_eof        = eof_pending || push_eof;
wire        fifo_write         = service_eof ? !fifo_full_12 : (push_pix && !fifo_pixel_full_12);
wire [49:0] fifo_din           = service_eof ? (eof_pending ? eof_pending_data : eof_data)
                                             : pixel_data_in;

logic [1:0] rst_12_sync = 2'b11;
always_ff @(posedge clk_source) rst_12_sync <= {rst_12_sync[0], reset};
wire rst_12 = rst_12_sync[1];

// Synchronize the read pointer into clk_source for the FIFO capacity checks.
always_ff @(posedge clk_source) begin
	if (rst_12) begin
		rd_ptr_g_sync1_12 <= 0;
		rd_ptr_g_sync2_12 <= 0;
	end else begin
		rd_ptr_g_sync1_12 <= rd_ptr_g;
		rd_ptr_g_sync2_12 <= rd_ptr_g_sync1_12;
	end
end

always_ff @(posedge clk_source) begin
	if (rst_12) begin
		last_frame_done  <= 1'b0;
		wr_ptr           <= 0;
		wr_ptr_g         <= 0;
		eof_pending      <= 1'b0;
		eof_pending_data <= 50'd0;
		source_overflow  <= 1'b0;
	end else begin
		last_frame_done <= FRAME_DONE;

		if (fifo_write) begin
			fifo_mem[wr_ptr[FIFO_ADDR_W-1:0]] <= fifo_din;
			wr_ptr                            <= wr_ptr_next;
			wr_ptr_g                          <= wr_ptr_g_next;

			if (eof_pending && push_eof) begin
				eof_pending      <= 1'b1;
				eof_pending_data <= eof_data;
			end
			else if (service_eof) begin
				eof_pending <= 1'b0;
			end
		end
		else if (push_eof && !eof_pending) begin
			eof_pending      <= 1'b1;
			eof_pending_data <= eof_data;
		end

		if ((push_pix && (service_eof || fifo_pixel_full_12)) ||
			(push_eof && eof_pending && !fifo_write)) begin
			source_overflow <= 1'b1;
		end
	end
end

// FIFO reads (clk_sys) -----------------------------------------------------

logic [1:0] rst_sys_sync = 2'b11;
always_ff @(posedge clk_sys) rst_sys_sync <= {rst_sys_sync[0], reset};
wire rst_sys = rst_sys_sync[1];

always_ff @(posedge clk_sys) begin
	wr_ptr_g_sync1 <= wr_ptr_g;
	wr_ptr_g_sync2 <= wr_ptr_g_sync1;
end
wire fifo_empty = (rd_ptr_g == wr_ptr_g_sync2);

// Input register
logic [49:0] a_data;
logic        a_valid = 0;
wire         a_ready;

wire a_fifo_read = !fifo_empty && (!a_valid || a_ready);

always_ff @(posedge clk_sys) begin
	if (rst_sys) begin
		a_valid  <= 0;
		rd_ptr   <= 0;
		rd_ptr_g <= 0;
	end else begin
		if (a_ready && a_valid) a_valid <= 0;
		if (a_fifo_read) begin
			a_data   <= fifo_mem[rd_ptr[FIFO_ADDR_W-1:0]];
			rd_ptr   <= rd_ptr + 1'b1;
			rd_ptr_g <= b2g(rd_ptr + 1'b1);
			a_valid  <= 1;
		end
	end
end

wire [10:0] a_x        = a_data[22:12];
wire [10:0] a_y        = a_data[33:23];
wire [11:0] a_z        = a_data[11:0];
wire [13:0] a_dose     = a_data[49:36];
wire [15:0] a_dose_raw = {a_dose, 2'b00};
wire        a_eof      = a_data[34];

// FIFO diagnostics --------------------------------------------------------

// Hold the high-water indication for about 75 ms.
// A source overflow keeps the LED on until reset.
wire [FIFO_PTR_W-1:0] wr_ptr_bin      = g2b(wr_ptr_g_sync2);
wire [FIFO_PTR_W-1:0] fifo_used       = wr_ptr_bin - rd_ptr;
wire                  fifo_high_water = (fifo_used > FIFO_PTR_W'(128));

logic [1:0]  source_overflow_sync = 2'b00;
logic        fifo_high_water_q    = 1'b0;
logic [23:0] led_timer            = 0;

always_ff @(posedge clk_sys) begin
	source_overflow_sync <= {source_overflow_sync[0], source_overflow};
	fifo_high_water_q    <= fifo_high_water;
	if (fifo_high_water_q) led_timer <= 24'd9349794;
	else if (led_timer != 0) led_timer <= led_timer - 1'b1;
end
assign fifo_full_led = (led_timer != 0) || source_overflow_sync[1];

// Pixel generation state and output ---------------------------------------

// B_IDLE      - accept and emit a source pixel or EOF marker
// B_CHECK_SUB - choose and emit a diagonal-fill pixel
// B_DOT_*     - calculate and emit a centered dwell footprint
typedef enum logic [3:0] {
	B_IDLE, B_CHECK_SUB, B_DOT_NORMALIZE, B_DOT_T,
	B_DOT_MUL, B_DOT_ADD, B_DOT_BOUNDS, B_DOT_SIZE, B_DOT_SQUARE,
	B_DOT_AREA, B_DOT_WEIGHTS, B_DOT_DISPATCH, B_DOT_SUB
} b_state_t;

b_state_t b_state = B_IDLE;

logic [10:0] s2_out_x;
logic [10:0] s2_out_y;
logic [10:0] s2_out_energy;
logic [3:0]  s2_out_phase;
logic        s2_dwell_excess;
logic        s2_out_valid                     = 0;
logic [15:0] s2_eof_frame_tick_clks           = 0;
logic [15:0] s2_eof_completed_frame_tick_clks = 0;

// Load another output when the register is empty or its current pixel is accepted.
wire b_output_free = pixel_ready || !s2_out_valid;
assign pixel_valid = s2_out_valid;
assign a_ready     = a_valid && b_output_free && (b_state == B_IDLE);

// Diagonal-fill geometry ---------------------------------------------------

logic [10:0] fill_z;
logic        fill_prev_horizontal;
logic        fill_prev_vertical;

// Retain the two source positions that form the diagonal's endpoints.
logic [10:0] hist_x [2];
logic [10:0] hist_y [2];
logic [1:0]  hist_count = 0;

logic [10:0] read_last_x = 0;
logic [10:0] read_last_y = 0;

function automatic logic unit_step(input logic [10:0] a, b);
	// The extended additions exclude wraparound between 2047 and zero.
	unit_step = ({1'b0, a} + 12'd1 == {1'b0, b}) ||
	            ({1'b0, b} + 12'd1 == {1'b0, a});
endfunction

// Compare the input pixel with the last accepted source pixel.
// A one-pixel change on both axes identifies a diagonal.
wire step_x_equal = (a_x == read_last_x);
wire step_y_equal = (a_y == read_last_y);
wire step_x_unit  = unit_step(a_x, read_last_x);
wire step_y_unit  = unit_step(a_y, read_last_y);
wire step_is_diag = step_x_unit && step_y_unit;
wire is_neighbor  = (step_x_equal || step_x_unit) &&
                    (step_y_equal || step_y_unit);

wire hist_is_horizontal = (hist_count >= 2'd2) &&
                          unit_step(hist_x[0], hist_x[1]) && (hist_y[0] == hist_y[1]);
wire hist_is_vertical   = (hist_count >= 2'd2) &&
                          (hist_x[0] == hist_x[1]) && unit_step(hist_y[0], hist_y[1]);

// During B_CHECK_SUB, the input register holds the following FIFO entry.
// Its position provides the outgoing line direction; EOF provides none.
wire next_is_horizontal = !a_eof && step_x_unit && step_y_equal;
wire next_is_vertical   = !a_eof && step_x_equal && step_y_unit;

wire [1:0] x_first_cost   = {1'b0, fill_prev_horizontal} + {1'b0, next_is_vertical};
wire [1:0] y_first_cost   = {1'b0, fill_prev_vertical} + {1'b0, next_is_horizontal};
wire       choose_x_first = (x_first_cost < y_first_cost) ||
                            ((x_first_cost == y_first_cost) && (hist_x[0] > hist_x[1]));

// Dwell footprint ---------------------------------------------------------

logic [11:0] fb_width_q  = 12'd720;
logic [11:0] fb_height_q = 12'd480;

always_ff @(posedge clk_sys) begin
	fb_width_q  <= FB_WIDTH;
	fb_height_q <= FB_HEIGHT;
end

// Select the dose interval for this pixel. dwell_config supplies its
// cubic size curve for the current resolution and dwell controls.
wire [1:0]    dwell_resolution = (fb_height_q > 12'd720) ? GEOMETRY_1080 :
                                 (fb_height_q > 12'd480) ? GEOMETRY_720 :
                                     (fb_height_q > 12'd240) ? GEOMETRY_480 : GEOMETRY_240;
wire [1:0]    dwell_segment    = (a_dose_raw < 16'd7705) ? 2'd0 :
                                 (a_dose_raw < 16'd19296) ? 2'd1 :
                                     (a_dose_raw < 16'd28512) ? 2'd2 : 2'd3;
dwell_curve_t dwell_curve, dot_curve_q;
wire [15:0]   dwell_onset;
wire          dwell_expansion_enabled;

vfb_dwell_config dwell_config (
	.clk_sys(clk_sys), .reset(rst_sys),
	.settings({dwell_resolution, DWELL_LOW_SIZE, DWELL_MID_GROWTH, DWELL_HIGH_GROWTH}),
	.segment(dwell_segment), .curve(dwell_curve),
	.expansion_enabled(dwell_expansion_enabled), .onset(dwell_onset)
);

wire primary_needs_footprint = (a_dose_raw > dwell_onset) && dwell_expansion_enabled;

logic [15:0] dot_dose_q;
logic [10:0] dot_x, dot_y;
logic [11:0] dot_base_z;
logic        dot_diag_q;

logic        [36:0] dot_normalized_q;
logic        [18:0] dot_t_q, dot_size_q;
logic signed [23:0] dot_acc_q;
logic signed [43:0] dot_product_q;
logic        [1:0]  dot_term_q;

// Keep the bound decisions separate from the size selection.
(* dont_retime *) logic dot_below_q, dot_above_q;

wire        [15:0] dot_delta           = (dot_dose_q > dot_curve_q.origin) ?
                                         dot_dose_q - dot_curve_q.origin :
                                         16'd0;
wire        [22:0] dot_t_rounded       = 23'((dot_normalized_q + 37'd8192) >> 14);
wire signed [43:0] dot_product_rounded = dot_product_q + 44'sd131072;
wire signed [23:0] dot_term            = (dot_term_q == 2'd0) ? dot_curve_q.b :
                                         (dot_term_q == 2'd1) ? dot_curve_q.c :
                                             dot_curve_q.d + 24'sd2;
wire signed [23:0] dot_sum             = 24'(dot_product_rounded >>> 18) + dot_term;

logic [37:0] dot_square_q;
logic [16:0] dot_area_q;

logic [3:0]          dot_weight_step_q;
dwell_weight_input_t dot_weight_input_q, dot_weight_bypass_q;
(* multstyle = "dsp" *)
logic [39:0]         dot_weight_product_q;
logic [16:0]         dot_weight_q;
logic [28:0]         dot_weighted_q;

wire [19:0] dot_weight_value   = dot_weight_bypass_q.divide_three ?
                                 {1'b0, dot_weight_product_q[39:21]} :
                                 dot_weight_bypass_q.numerator;
wire [29:0] dot_energy_rounded = {1'b0, dot_weighted_q} + 30'd65536;
wire [10:0] dot_energy_packed  = dot_energy_rounded[28] ? 11'h7ff : dot_energy_rounded[27:17];

// One 11-bit pixel energy for each of the five symmetric neighbour groups.
(* ramstyle = "logic" *) logic [10:0] dot_energy [5];

logic [2:0] dot_group_q, dot_member_q;
logic [5:0] dot_offset_q;

wire [11:0] dot_candidate_x     = {1'b0, dot_x} + {{9{dot_offset_q[5]}}, dot_offset_q[5:3]};
wire [11:0] dot_candidate_y     = {1'b0, dot_y} + {{9{dot_offset_q[2]}}, dot_offset_q[2:0]};
wire        dot_candidate_valid = (dot_candidate_x < fb_width_q) &&
                                  (dot_candidate_y < fb_height_q);
wire        dot_member_last     = (dot_member_q == ((dot_group_q == 3'd3) ? 3'd7 : 3'd3));

// Pixel generation sequence -----------------------------------------------

always_ff @(posedge clk_sys) begin
	if (rst_sys) begin
		s2_out_valid                     <= 0;
		pixel_replace                    <= 0;
		pixel_dwell_high_dose            <= 0;
		s2_dwell_excess                  <= 0;
		s2_out_phase                     <= 0;
		eof_token                        <= 0;
		s2_eof_frame_tick_clks           <= 16'd0;
		s2_eof_completed_frame_tick_clks <= 16'd0;
		b_state                          <= B_IDLE;
		hist_count                       <= 0;
	end else begin
		if (pixel_ready) begin
			s2_out_valid <= 0;
			eof_token    <= 0;
		end

		case (b_state)
		B_IDLE: begin
			if (a_valid && b_output_free) begin
				if (a_eof) begin
					pixel_replace                    <= 0;
					pixel_dwell_high_dose            <= 0;
					s2_dwell_excess                  <= 0;
					eof_token                        <= 1;
					s2_out_valid                     <= 1;
					s2_eof_frame_tick_clks           <= a_data[15:0];
					s2_eof_completed_frame_tick_clks <= a_data[31:16];
				end else begin
					s2_out_x              <= a_x;
					s2_out_y              <= a_y;
					s2_out_energy         <= dwell_pack(a_z);
					s2_out_phase          <= draw_idx;
					s2_dwell_excess       <= 1'b0;
					pixel_dwell_high_dose <= (a_dose >= DWELL_HIGH_DOSE);
					s2_out_valid          <= 1;
					pixel_replace         <= a_data[35];

					// Save the fill energy and preceding line direction before advancing
					// the position history.
					fill_z               <= dwell_pack(a_z);
					fill_prev_horizontal <= hist_is_horizontal;
					fill_prev_vertical   <= hist_is_vertical;

					hist_x[1]   <= hist_x[0]; hist_y[1] <= hist_y[0];
					hist_x[0]   <= a_x;       hist_y[0] <= a_y;
					hist_count  <= is_neighbor ? ((hist_count < 2'd2) ? hist_count + 2'd1 : 2'd2) : 2'd1;
					read_last_x <= a_x;
					read_last_y <= a_y;

					// Save this pixel's position, intensity, dose, size curve and diagonal
					// flag before the input register loads the next FIFO entry.
					dot_curve_q <= dwell_curve;
					dot_dose_q  <= a_dose_raw;
					dot_base_z  <= a_z;
					dot_x       <= a_x;
					dot_y       <= a_y;
					dot_diag_q  <= step_is_diag;

					if (primary_needs_footprint) begin
						b_state <= B_DOT_NORMALIZE;
					end else if (step_is_diag) begin
						b_state <= B_CHECK_SUB;
					end
				end
			end
		end

		// Emit one of the two corners between the diagonal's endpoints.
		// The preceding and following line directions select the corner;
		// equal scores select the corner with the larger X coordinate.
		B_CHECK_SUB: begin
			if (a_valid && b_output_free) begin
				if (choose_x_first) begin
					s2_out_x <= hist_x[0];
					s2_out_y <= hist_y[1];
				end else begin
					s2_out_x <= hist_x[1];
					s2_out_y <= hist_y[0];
				end
				s2_out_energy         <= fill_z;
				s2_out_phase          <= draw_idx;
				s2_dwell_excess       <= 1'b0;
				pixel_dwell_high_dose <= 1'b0;
				s2_out_valid          <= 1;
				b_state               <= B_IDLE;
			end
		end

		// Footprint calculations continue even when the cache cannot accept a pixel.
		// They do not change the pending output pixel.

		// Normalize the dose to t = 0..1 within the selected interval.
		B_DOT_NORMALIZE: begin
			dot_normalized_q <= dot_delta * dot_curve_q.reciprocal;
			b_state          <= B_DOT_T;
		end
		B_DOT_T: begin
			dot_t_q    <= (dot_t_rounded >= 23'd262144) ? 19'd262144 : dot_t_rounded[18:0];
			dot_acc_q  <= dot_curve_q.a;
			dot_term_q <= 2'd0;
			b_state    <= B_DOT_MUL;
		end

		// Evaluate size = ((a*t + b)*t + c)*t + d, then clamp to the interval bounds.
		// d has two zero low bits, so folding in the rounding bias adds no carry chain.
		B_DOT_MUL: begin
			dot_product_q <= dot_acc_q * $signed({1'b0, dot_t_q});
			b_state       <= B_DOT_ADD;
		end
		B_DOT_ADD: begin
			dot_acc_q  <= dot_sum;
			dot_term_q <= dot_term_q + 2'd1;
			b_state    <= (dot_term_q == 2'd2) ? B_DOT_BOUNDS : B_DOT_MUL;
		end
		B_DOT_BOUNDS: begin
			dot_below_q <= $signed(dot_acc_q[23:2]) < $signed({1'b0, dot_curve_q.lower});
			dot_above_q <= $signed(dot_acc_q[23:2]) > $signed({1'b0, dot_curve_q.upper});
			b_state     <= B_DOT_SIZE;
		end
		B_DOT_SIZE: begin
			dot_size_q <= dot_below_q ? dot_curve_q.lower :
			              dot_above_q ? dot_curve_q.upper : dot_acc_q[20:2];
			b_state    <= B_DOT_SQUARE;
		end

		// Convert the interpolated size to footprint area.
		B_DOT_SQUARE: begin
			dot_square_q <= dot_size_q * dot_size_q;
			b_state      <= B_DOT_AREA;
		end
		B_DOT_AREA: begin
			dot_area_q        <= 17'((dot_square_q + 38'd524288) >> 20);
			dot_weight_step_q <= 4'd0;
			b_state           <= B_DOT_WEIGHTS;
		end

		// Convert area to five neighbour weights, then to packed pixel energies.
		B_DOT_WEIGHTS: begin
			if (dot_weight_step_q < 4'd5)
				dot_weight_input_q <= dwell_weight_input(dot_area_q, dot_weight_step_q[2:0]);

			// floor(n/3) = (n*699051)>>21 exactly for every unsigned 20-bit n.
			if (dot_weight_step_q >= 4'd1 && dot_weight_step_q <= 4'd5) begin
				dot_weight_product_q <= dot_weight_input_q.numerator * 20'd699051;
				dot_weight_bypass_q  <= dot_weight_input_q;
			end

			if (dot_weight_step_q >= 4'd2 && dot_weight_step_q <= 4'd6)
				dot_weight_q <= (dot_weight_value >= 20'd65536) ? 17'd65536
				                                                : dot_weight_value[16:0];

			if (dot_weight_step_q >= 4'd3 && dot_weight_step_q <= 4'd7)
				dot_weighted_q <= dot_base_z * dot_weight_q;

			if (dot_weight_step_q >= 4'd4)
				dot_energy[dot_weight_step_q - 4'd4] <= dot_energy_packed;

			dot_weight_step_q <= dot_weight_step_q + 4'd1;
			if (dot_weight_step_q == 4'd8)
				b_state <= B_DOT_DISPATCH;
		end

		B_DOT_DISPATCH: begin
			dot_group_q  <= 3'd0;
			dot_member_q <= 3'd0;
			dot_offset_q <= dwell_offset(3'd0, 3'd0);

			// The four immediate horizontal/vertical neighbours have the highest energy.
			// If their energy rounds to zero, use diagonal fill instead of expansion.
			b_state <= (dot_energy[0] != 11'd0) ? B_DOT_SUB :
			           dot_diag_q ? B_CHECK_SUB : B_IDLE;
		end

		B_DOT_SUB: begin
			if (b_output_free) begin
				if (dot_energy[dot_group_q] == 11'd0) begin
					// Later groups have no greater energy, so stop at the first zero group.
					b_state <= B_IDLE;
				end else begin
					// Suppress out-of-bounds neighbours through s2_out_valid only.
					// Keep bounds checks off the coordinate and energy register enables.
					s2_out_x        <= dot_candidate_x[10:0];
					s2_out_y        <= dot_candidate_y[10:0];
					s2_out_energy   <= dot_energy[dot_group_q];
					s2_out_phase    <= draw_idx;
					s2_dwell_excess <= !pixel_dwell_high_dose;
					s2_out_valid    <= dot_candidate_valid;

					if (dot_member_last) begin
						dot_member_q <= 3'd0;
						dot_group_q  <= dot_group_q + 3'd1;
						dot_offset_q <= dwell_offset(dot_group_q + 3'd1, 3'd0);
						if (dot_group_q == 3'd4) b_state <= B_IDLE;
					end else begin
						dot_member_q <= dot_member_q + 3'd1;
						dot_offset_q <= dwell_offset(dot_group_q, dot_member_q + 3'd1);
					end
				end
			end
		end
		endcase
	end
end

// Tile-cache output encoding ----------------------------------------------

// Pixels carry draw phase, dwell-excess flag and 11-bit energy.
// EOF entries carry frame timing instead of pixel data.
assign pixel_tile_id                 = {s2_out_y[10:3], s2_out_x[10:3]};
assign pixel_offset                  = {s2_out_y[2:0],  s2_out_x[2:0]};
assign pixel_data                    = eof_token ?
                                       s2_eof_frame_tick_clks :
                                       {s2_out_phase, s2_dwell_excess && (|s2_out_energy),
                                       s2_out_energy};
assign eof_completed_frame_tick_clks = s2_eof_completed_frame_tick_clks;

endmodule

`default_nettype wire
