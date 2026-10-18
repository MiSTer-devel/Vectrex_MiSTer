// ============================================================================
// Broad, low-resolution halo generator.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Reduces each 16x16 or 8x8 cell, applies a symmetric eight-tap blur,
// and reconstructs beam energy. The kernels have equal coefficient sums
// and the same center. Wide 1 and Wide 2 feed the blur with the greater
// of the scaled cell sum and half the brightest pixel's energy in that cell.
// ============================================================================

`default_nettype none

module vfb_halo_wide #(
	parameter integer MAX_WIDTH = 1472,
	parameter integer H_DELAY = 80
) (
	input  wire          clk_sys,
	input  wire          reset,
	input  wire          ce_pix,

	input  wire  [2:0]   halo_curve_mode,
	input  wire  [1:0]   halo_dot_reduction,
	input  wire  [1:0]   halo_spread_mode,
	input  wire  [2:0]   halo_knee_mode,
	input  wire          halo_grid_8,
	input  wire  [11:0]  line_delay,
	input  wire  [11:0]  active_height,
	input  wire  [11:0]  ENERGY_IN,
	input  wire          DWELL_EXCESS_IN,
	input  wire          VGA_HBLANK_IN,
	input  wire          VGA_VBLANK_IN,

	output logic [16:0]  HALO_ENERGY_OUT, // Q4 energy
	output logic         HALO_VALID_OUT
);
import vfb_control_pkg::*;

localparam integer COARSE_WIDTH                 = MAX_WIDTH / 8;
localparam integer COARSE_W                     = $clog2(COARSE_WIDTH + 5);
localparam integer EPOCH_RAM_DEPTH              = 1 << (COARSE_W + 1);
localparam integer HALO_W                       =   15;  // 13 integer bits and two fractional bits.
localparam integer RECON_W                      =   17;  // Q4 reconstruction.
localparam [3:0]   RECON_SAMPLE_X_ADVANCE       = 4'd5;
localparam [7:0]   VERTICAL_CENTER_DELAY_ROWS   = 8'd3;
localparam [7:0]   VERTICAL_PREVIOUS_DELAY_ROWS = 8'd2;
localparam [7:0]   RECON_FIRST_ROW              = 8'd2;
localparam [1:0]   RECON_FIRST_BANK             = 2'd2;
logic [2:0]        halo_curve_mode_q            = CURVE_MINIMAL;
logic [1:0]        halo_dot_reduction_q         = HALO_CORRECTION_NONE;
logic [1:0]        halo_spread_mode_q           = SPREAD_ORIGINAL;
logic              halo_knee_enable_q           =    1'b0;
logic [11:0]       halo_knee_threshold_q        =   12'd0;
logic [7:0]        halo_knee_offset_q           =    8'd0;
logic [11:0]       active_height_q              = 12'd480;

always_ff @(posedge clk_sys) begin
	halo_curve_mode_q    <= halo_curve_mode;
	halo_dot_reduction_q <= halo_dot_reduction;
	halo_spread_mode_q   <= halo_spread_mode;
	halo_knee_enable_q   <= (halo_knee_mode != KNEE_OFF);
	active_height_q      <= active_height;
	// T is 16 times the displayed compression knee; the compressed segment
	// uses offset 5*T/8.
	case (halo_knee_mode)
		KNEE_2:  {halo_knee_threshold_q, halo_knee_offset_q} <= {12'd32,  8'd20};
		KNEE_4:  {halo_knee_threshold_q, halo_knee_offset_q} <= {12'd64,  8'd40};
		KNEE_6:  {halo_knee_threshold_q, halo_knee_offset_q} <= {12'd96,  8'd60};
		KNEE_8:  {halo_knee_threshold_q, halo_knee_offset_q} <= {12'd128, 8'd80};
		KNEE_10: {halo_knee_threshold_q, halo_knee_offset_q} <= {12'd160, 8'd100};
		KNEE_16: {halo_knee_threshold_q, halo_knee_offset_q} <= {12'd256, 8'd160};
		KNEE_24: {halo_knee_threshold_q, halo_knee_offset_q} <= {12'd384, 8'd240};
		default: {halo_knee_threshold_q, halo_knee_offset_q} <= '0;
	endcase
end

initial begin
	if ((MAX_WIDTH % 8) != 0)
		$error("vfb_halo_wide MAX_WIDTH must be divisible by 8");
	if (MAX_WIDTH < 8 || MAX_WIDTH > 2040)
		$error("vfb_halo_wide MAX_WIDTH must be between 8 and 2040");
	if (H_DELAY < 1 || MAX_WIDTH + H_DELAY > 4096)
		$error("vfb_halo_wide H_DELAY must fit the 12-bit output coordinate");
end

// Halo excitation table: x^1.5 with eight gain settings.
// x runs from 0 to 1 across 256 input samples per setting.
// Each 16-bit entry contains:
// [15]    zero padding;
// [14:7]  8-bit curve value after gain and saturation;
// [6:0]   interpolation slope after expansion to 12-bit energy.
(* ramstyle = "M10K" *) logic [15:0] halo_curve_rom [0:2047];
initial $readmemh("rtl/videodr0me_fb/vfb_halo_curve.hex", halo_curve_rom);

logic source_in_hblank_q;
logic source_in_vblank_q;

logic [14:0] source_curve_q;
logic [3:0]  source_curve_frac_q;
logic [11:0] source_curve_base_q;
logic [9:0]  source_curve_product_q;
// Round in the base-add stage, keeping the multiplier stage isolated.
wire  [15:0] source_curve_sum = {source_curve_base_q, 4'd8} + {6'd0, source_curve_product_q};
logic        source_hblank_q;
logic        source_vblank_q;
logic        source_vblank_d;
logic        reduce_hblank_q;
logic        reduce_vblank_q;
logic        reduce_hblank_d;

logic [13:0] source_energy_q; // Q2, after excitation and footprint reduction.
logic [1:0]  source_reduction_q, source_reduction_d;

// Read the excitation curve, then interpolate over two processing stages.
// Use ce_pix on the multiplier registers to support DSP register packing.
// Reset blanks the pipeline instead of clearing these arithmetic registers.
always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		source_curve_q         <= 15'(halo_curve_rom[{halo_curve_mode_q, ENERGY_IN[11:4]}]);
		source_curve_frac_q    <= ENERGY_IN[3:0];
		source_reduction_q     <= DWELL_EXCESS_IN ? halo_dot_reduction_q : HALO_CORRECTION_NONE;
		source_reduction_d     <= source_reduction_q;
		source_curve_base_q    <= {source_curve_q[14:7], source_curve_q[14:11]};
		source_curve_product_q <= source_curve_q[6:0] * source_curve_frac_q;
		case (source_reduction_d)
			HALO_CORRECTION_NONE: source_energy_q <= {source_curve_sum[15:4], 2'b00};
			HALO_CORRECTION_50:   source_energy_q <= {1'b0, source_curve_sum[15:4], 1'b0};
			HALO_CORRECTION_75:   source_energy_q <= {2'b00, source_curve_sum[15:4]};
			HALO_CORRECTION_100:  source_energy_q <= 14'd0;
		endcase
	end
end

// Selectable 16x16/8x8 coarse source reducer.
logic                hblank_d;
logic [3:0]          h_phase;
logic [3:0]          v_phase;
logic [7:0]          reduce_y;
logic [7:0]          reduced_height;
logic                source_epoch;
wire                 next_source_epoch = ~source_epoch;
logic [COARSE_W-1:0] coarse_x;
logic [COARSE_W-1:0] coarse_width;
logic [17:0]         h_sum;
logic [13:0]         h_max;

wire       line_start                = ce_pix && hblank_d && !source_in_hblank_q;
wire       source_line_end           = ce_pix && !reduce_hblank_d && reduce_hblank_q;
wire       source_frame_active_start = ce_pix && source_vblank_d && !source_vblank_q;
wire [3:0] grid_phase_last           = halo_grid_8 ? 4'd7 : 4'd15;
wire [3:0] grid_prefetch_phase       = halo_grid_8 ? 4'd2 : 4'd10;
wire [3:0] grid_read_phase           = halo_grid_8 ? 4'd3 : 4'd11;
wire [3:0] grid_recon_lead           = halo_grid_8 ? 4'd5 : 4'd0;
wire [3:0] grid_recon_lag            = halo_grid_8 ? 4'd9 : 4'd4;
wire       source_active             = ce_pix && !reduce_hblank_q && !reduce_vblank_q;
wire       normal_group              = source_active && (h_phase == grid_phase_last);

logic                zero_fill_active;
logic [COARSE_W-1:0] zero_fill_x;
logic [3:0]          zero_fill_phase;
logic [7:0]          zero_fill_y;
logic                zero_fill_epoch;

logic                tail_fill_active;
logic [COARSE_W-1:0] tail_fill_x;
logic [3:0]          tail_fill_phase;
logic [7:0]          tail_fill_y;
logic                tail_fill_epoch;
logic [18:0]         tail_fill_energy;
logic [13:0]         tail_fill_max;

wire                next_sample_valid  = normal_group || tail_fill_active ||
                                         (ce_pix && zero_fill_active);
wire [COARSE_W-1:0] next_sample_x      = tail_fill_active ? tail_fill_x :
                                         zero_fill_active ? zero_fill_x : coarse_x;
wire [3:0]          next_sample_phase  = tail_fill_active ? tail_fill_phase :
                                         zero_fill_active ? zero_fill_phase : v_phase;
wire [7:0]          next_sample_y      = tail_fill_active ? tail_fill_y :
                                         zero_fill_active ? zero_fill_y : reduce_y;
wire                next_sample_epoch  = tail_fill_active ? tail_fill_epoch :
                                         zero_fill_active ? zero_fill_epoch : source_epoch;
wire [18:0]         next_sample_energy = tail_fill_active ? tail_fill_energy :
                                         zero_fill_active ? 19'd0 :
                                             {1'b0, h_sum} + {5'd0, source_energy_q};
wire [13:0]         next_sample_max    = tail_fill_active ? tail_fill_max :
                                         zero_fill_active ? 14'd0 :
                                             (source_energy_q > h_max) ? source_energy_q : h_max;

typedef struct packed {
	logic                valid;
	logic [COARSE_W-1:0] x;
	logic [3:0]          phase;
	logic [7:0]          y;
	logic                epoch;
	logic [18:0]         energy;
	logic [13:0]         peak;
} reducer_sample_t;

typedef struct packed {
	logic                valid;
	logic [COARSE_W-1:0] x;
	logic [3:0]          phase;
	logic [7:0]          y;
	logic                epoch;
	logic [18:0]         energy;
	logic [13:0]         peak;
	logic [21:0]         sum;
	logic [13:0]         prev_peak;
} reducer_accum_t;

typedef struct packed {
	logic                valid;
	logic [COARSE_W-1:0] x;
	logic [7:0]          y;
	logic                epoch;
	logic [1:0]          mode;
	logic [22:0]         energy;
	logic [13:0]         peak;
} coarse_total_t;

typedef struct packed {
	logic                valid;
	logic [COARSE_W-1:0] x;
	logic [7:0]          y;
	logic                epoch;
	logic [1:0]          mode;
	logic [HALO_W-1:0]   sum;
	logic [HALO_W-1:0]   peak_lift;
} coarse_reduce_t;

typedef struct packed {
	logic                valid;
	logic [COARSE_W-1:0] x;
	logic [7:0]          y;
	logic                epoch;
	logic [HALO_W-1:0]   energy;
} coarse_sample_t;

reducer_sample_t reduce_sample_q;
reducer_accum_t  reduce_accum_q;
coarse_total_t   coarse_total_q;
logic            reduce_write_valid_q;
coarse_reduce_t  coarse_reduce_q;
coarse_reduce_t  coarse_select_q;
coarse_sample_t  coarse_sample_q;

// Keep the Q2 sum and peak together in one synchronous cell record.
(* ramstyle = "M10K, no_rw_check" *)
logic [35:0] v_reduce_mem [0:COARSE_WIDTH-1];

logic [1:0]  write_bank [0:1];
logic [7:0]  completed_rows [0:1];
logic [11:0] source_line_y;
logic [11:0] prev_frame_lines;

wire [11:0] source_full_line_for_line = source_frame_active_start ? 12'd0 : source_line_y;
wire        source_epoch_for_line     = source_frame_active_start ? next_source_epoch : source_epoch;
wire        recon_prev_frame          = (source_full_line_for_line < line_delay);
wire        recon_epoch               = recon_prev_frame ? ~source_epoch_for_line : source_epoch_for_line;
wire [11:0] recon_line                = recon_prev_frame ?
                                        prev_frame_lines + source_full_line_for_line - line_delay :
                                        source_full_line_for_line - line_delay;

logic                v_pad_active;
logic [COARSE_W-1:0] v_pad_x;
logic [7:0]          v_pad_y;
logic [7:0]          v_pad_end_y;
logic [7:0]          v_pad_height;
logic                v_pad_epoch;
logic [2:0]          v_pad_gap;

// First coarse row whose contents reconstruction still needs.
logic [7:0] v_pad_keep_y_q;

wire [11:0] v_pad_recon_start = prev_frame_lines - line_delay;
wire [11:0] v_pad_recon_line  = (source_line_y < line_delay) ?
                                prev_frame_lines + source_line_y - line_delay :
                                source_line_y - line_delay;

function automatic [7:0] full_line_to_coarse_y(
	input logic [11:0] line_y,
	input logic        grid_8
);
	begin
		full_line_to_coarse_y = grid_8 ? line_y[10:3] : line_y[11:4];
	end
endfunction

wire  [7:0] v_pad_keep_start_y = full_line_to_coarse_y(v_pad_recon_start, halo_grid_8) +
                                 VERTICAL_PREVIOUS_DELAY_ROWS;
wire  [7:0] v_pad_keep_line_y  = full_line_to_coarse_y(v_pad_recon_line, halo_grid_8) +
                                 VERTICAL_PREVIOUS_DELAY_ROWS;
logic [7:0] v_pad_keep_start_y_q;
logic [7:0] v_pad_keep_line_y_q;

always_ff @(posedge clk_sys) begin
	v_pad_keep_start_y_q <= v_pad_keep_start_y;
	v_pad_keep_line_y_q  <= v_pad_keep_line_y;
end

wire v_pad_row_safe = (v_pad_y < VERTICAL_CENTER_DELAY_ROWS) ||
                      ((v_pad_y - VERTICAL_CENTER_DELAY_ROWS) < v_pad_keep_y_q);
wire v_pad_valid    = v_pad_active && (v_pad_gap == 3'd0) && v_pad_row_safe;

wire                blur_in_valid  = v_pad_valid || coarse_sample_q.valid;
wire [COARSE_W-1:0] blur_in_x      = v_pad_valid ? v_pad_x : coarse_sample_q.x;
wire [7:0]          blur_in_y      = v_pad_valid ? v_pad_y : coarse_sample_q.y;
wire                blur_in_epoch  = v_pad_valid ? v_pad_epoch : coarse_sample_q.epoch;
wire [7:0]          blur_in_height = v_pad_valid ? v_pad_height : reduced_height;
wire [HALO_W-1:0]   blur_in_energy = v_pad_valid ? '0 : coarse_sample_q.energy;

function automatic [HALO_W-1:0] coarse_source_boost(
	input  logic [22:0] total,
	input  logic        grid_8
);
	logic [22:0] boosted;
	begin
		// Use 1/4 of the 8x8 cell sum or 1/8 of the 16x16 cell sum.
		// Full-cell averaging can lose faint isolated contributions in the blur.
		boosted             = grid_8 ? ((total + 23'd2) >> 2) : ((total + 23'd4) >> 3);
		coarse_source_boost = (boosted > 23'd32764) ? 15'd32764 : boosted[HALO_W-1:0];
	end
endfunction

function automatic [HALO_W-1:0] coarse_source_select(
	input  logic [HALO_W-1:0] sum_boost,
	input  logic [HALO_W-1:0] max_lift,
	input  logic [1:0]        spread_mode
);
	begin
		coarse_source_select = (spread_mode == SPREAD_ORIGINAL || spread_mode == SPREAD_FOCUS) ?
		                       sum_boost :
		                       (max_lift > sum_boost) ? max_lift : sum_boost;
	end
endfunction

// Reset clears the pipeline valid flags and blocks writes to
// v_reduce_mem.
always_ff @(posedge clk_sys) begin
	logic [22:0] total_energy;
	logic [13:0] total_max;
	total_energy = reduce_accum_q.sum + reduce_accum_q.energy;
	total_max    = (reduce_accum_q.peak > reduce_accum_q.prev_peak) ? reduce_accum_q.peak
	                                                                : reduce_accum_q.prev_peak;

	reduce_sample_q.x      <= next_sample_x;
	reduce_sample_q.phase  <= next_sample_phase;
	reduce_sample_q.y      <= next_sample_y;
	reduce_sample_q.epoch  <= next_sample_epoch;
	reduce_sample_q.energy <= next_sample_energy;
	reduce_sample_q.peak   <= next_sample_max;
	if (coarse_total_q.valid) begin
		coarse_reduce_q.x         <= coarse_total_q.x;
		coarse_reduce_q.y         <= coarse_total_q.y;
		coarse_reduce_q.epoch     <= coarse_total_q.epoch;
		coarse_reduce_q.mode      <= coarse_total_q.mode;
		coarse_reduce_q.sum       <= coarse_source_boost(coarse_total_q.energy, halo_grid_8);
		coarse_reduce_q.peak_lift <= {2'b00, coarse_total_q.peak[13:1]};
	end
	if (coarse_reduce_q.valid) begin
		coarse_select_q.x     <= coarse_reduce_q.x;
		coarse_select_q.y     <= coarse_reduce_q.y;
		coarse_select_q.epoch <= coarse_reduce_q.epoch;
		coarse_select_q.mode  <= coarse_reduce_q.mode;
		coarse_select_q.sum   <= coarse_reduce_q.sum;

		coarse_select_q.peak_lift <= coarse_reduce_q.peak_lift;
	end
	if (coarse_select_q.valid) begin
		coarse_sample_q.x      <= coarse_select_q.x;
		coarse_sample_q.y      <= coarse_select_q.y;
		coarse_sample_q.epoch  <= coarse_select_q.epoch;
		coarse_sample_q.energy <= coarse_source_select(coarse_select_q.sum,
		                                               coarse_select_q.peak_lift,
		                                               coarse_select_q.mode);
	end
	if (reduce_sample_q.valid) begin
		reduce_accum_q.x         <= reduce_sample_q.x;
		reduce_accum_q.phase     <= reduce_sample_q.phase;
		reduce_accum_q.y         <= reduce_sample_q.y;
		reduce_accum_q.epoch     <= reduce_sample_q.epoch;
		reduce_accum_q.energy    <= reduce_sample_q.energy;
		reduce_accum_q.peak      <= reduce_sample_q.peak;
		reduce_accum_q.sum       <= v_reduce_mem[reduce_sample_q.x][35:14];
		reduce_accum_q.prev_peak <= v_reduce_mem[reduce_sample_q.x][13:0];
	end

	// Register each cell update for RAM writeback.
	// coarse_total_q.valid marks a completed cell for the halo blur.
	if (reduce_accum_q.valid) begin
		coarse_total_q.x      <= reduce_accum_q.x;
		coarse_total_q.y      <= reduce_accum_q.y;
		coarse_total_q.epoch  <= reduce_accum_q.epoch;
		coarse_total_q.mode   <= halo_spread_mode_q;
		coarse_total_q.energy <= (reduce_accum_q.phase == 4'd0) ? {4'd0, reduce_accum_q.energy}
		                                                        : total_energy;
		coarse_total_q.peak   <= (reduce_accum_q.phase == 4'd0) ? reduce_accum_q.peak : total_max;
	end

	if (reset) begin
		hblank_d              <= 1'b1;
		source_in_hblank_q    <= 1'b1;
		source_in_vblank_q    <= 1'b1;
		source_hblank_q       <= 1'b1;
		source_vblank_q       <= 1'b1;
		source_vblank_d       <= 1'b1;
		reduce_hblank_q       <= 1'b1;
		reduce_vblank_q       <= 1'b1;
		reduce_hblank_d       <= 1'b1;
		h_phase               <= 4'd0;
		v_phase               <= 4'd0;
		reduce_y              <= 8'd0;
		reduced_height        <= 8'd0;
		source_epoch          <= 1'b0;
		coarse_x              <=   '0;
		coarse_width          <= COARSE_W'(COARSE_WIDTH);
		h_sum                 <= 18'd0;
		h_max                 <= 14'd0;
		zero_fill_active      <=  1'b0;
		zero_fill_x           <=    '0;
		zero_fill_phase       <=  4'd0;
		zero_fill_y           <=  8'd0;
		zero_fill_epoch       <=  1'b0;
		tail_fill_active      <=  1'b0;
		tail_fill_x           <=    '0;
		tail_fill_phase       <=  4'd0;
		tail_fill_y           <=  8'd0;
		tail_fill_epoch       <=  1'b0;
		tail_fill_energy      <= 19'd0;
		tail_fill_max         <= 14'd0;
		reduce_sample_q.valid <=  1'b0;
		reduce_accum_q.valid  <=  1'b0;
		coarse_total_q.valid  <=  1'b0;
		reduce_write_valid_q  <=  1'b0;
		coarse_reduce_q.valid <=  1'b0;
		coarse_select_q.valid <=  1'b0;
		coarse_sample_q.valid <=  1'b0;
		v_pad_active          <=  1'b0;
		v_pad_x               <=    '0;
		v_pad_y               <=  8'd0;
		v_pad_end_y           <=  8'd0;
		v_pad_height          <=  8'd0;
		v_pad_epoch           <=  1'b0;
		v_pad_gap             <=  3'd0;
		v_pad_keep_y_q        <=  8'd0;
	end else begin
		coarse_total_q.valid  <= reduce_accum_q.valid && (reduce_accum_q.phase == grid_phase_last);
		reduce_write_valid_q  <= reduce_accum_q.valid;
		coarse_reduce_q.valid <= coarse_total_q.valid;
		coarse_select_q.valid <= coarse_reduce_q.valid;
		coarse_sample_q.valid <= coarse_select_q.valid;
		reduce_sample_q.valid <= next_sample_valid;
		reduce_accum_q.valid  <= reduce_sample_q.valid;

		if (ce_pix) begin
			hblank_d           <= source_in_hblank_q;
			source_in_hblank_q <= VGA_HBLANK_IN;
			source_in_vblank_q <= VGA_VBLANK_IN;
			source_hblank_q    <= source_in_hblank_q;
			source_vblank_q    <= source_in_vblank_q;
			source_vblank_d    <= source_vblank_q;
			reduce_hblank_q    <= source_hblank_q;
			reduce_vblank_q    <= source_vblank_q;
			reduce_hblank_d    <= reduce_hblank_q;
		end

		if (tail_fill_active) tail_fill_active <= 1'b0;

		if (v_pad_valid) begin
			if (v_pad_x + 1'b1 >= coarse_width) begin
				v_pad_x <= '0;
				if (v_pad_y + 1'b1 >= v_pad_end_y) begin
					v_pad_active <= 1'b0;
					v_pad_gap    <= 3'd0;
				end else begin
					v_pad_y   <= v_pad_y + 1'b1;
					v_pad_gap <= 3'd4;
				end
			end else begin
				v_pad_x <= v_pad_x + 1'b1;
			end
		end else if (v_pad_gap != 3'd0) begin
			v_pad_gap <= v_pad_gap - 1'b1;
		end

		if (source_frame_active_start) begin
			logic [7:0] tail_limit_y;

			tail_limit_y = reduced_height + VERTICAL_CENTER_DELAY_ROWS + 8'd1;
			v_pad_keep_y_q   <= v_pad_keep_start_y_q;
			source_epoch     <= next_source_epoch;
			reduce_y         <= 8'd0;
			zero_fill_active <= 1'b0;
			tail_fill_active <= 1'b0;
			v_pad_x          <=   '0;
			v_pad_y          <= completed_rows[source_epoch];
			v_pad_end_y      <= tail_limit_y;
			v_pad_height     <= reduced_height;
			v_pad_epoch      <= source_epoch;
			v_pad_gap        <= 3'd0;
			v_pad_active     <= (coarse_width != 0) && (reduced_height != 8'd0) &&
			                    (completed_rows[source_epoch] < tail_limit_y);
		end else if (line_start) begin
			v_pad_keep_y_q <= v_pad_keep_line_y_q;
		end

		if (source_frame_active_start) v_phase <= 4'd0;

		if (source_active) begin
			if (h_phase == grid_phase_last) begin
				h_phase  <= 4'd0;
				coarse_x <= coarse_x + 1'b1;
				h_sum    <= 18'd0;
				h_max    <= 14'd0;
			end else begin
				h_phase <= h_phase + 1'b1;
				h_sum   <= h_sum + source_energy_q;
				if (source_energy_q > h_max) h_max <= source_energy_q;
			end
		end

		if (source_line_end) begin
			if (!reduce_vblank_q && (coarse_x != 0 || h_phase != 0)) begin
				coarse_width   <= coarse_x + ((h_phase != 0) ? 1'b1 : 1'b0);
				reduced_height <= reduce_y + 8'd1;
			end
			if (!reduce_vblank_q && h_phase != 0) begin
				tail_fill_active <= 1'b1;
				tail_fill_x      <= coarse_x;
				tail_fill_phase  <= v_phase;
				tail_fill_y      <= reduce_y;
				tail_fill_epoch  <= source_epoch;
				tail_fill_energy <= {1'b0, h_sum};
				tail_fill_max    <= h_max;
			end
			h_phase  <=  4'd0;
			coarse_x <=    '0;
			h_sum    <= 18'd0;
			h_max    <= 14'd0;
			if (v_phase == grid_phase_last) begin
				v_phase  <= 4'd0;
				reduce_y <= reduce_y + 1'b1;
			end else begin
				v_phase <= v_phase + 1'b1;
			end

			// Add black rows during VBLANK so the halo fades below the final
			// visible line.
			if (reduce_vblank_q && coarse_width != 0) begin
				zero_fill_active <= 1'b1;
				zero_fill_x      <=   '0;
				zero_fill_phase  <= v_phase;
				zero_fill_y      <= reduce_y;
				zero_fill_epoch  <= source_epoch;
			end
		end

		if (ce_pix && zero_fill_active) begin
			if (zero_fill_x + 1'b1 >= coarse_width) begin
				zero_fill_active <= 1'b0;
				zero_fill_x      <=   '0;
			end else begin
				zero_fill_x <= zero_fill_x + 1'b1;
			end
		end

		if (reduce_write_valid_q)
			v_reduce_mem[coarse_total_q.x] <= coarse_total_q.valid ?
			                                  36'd0 :
			                                  {coarse_total_q.energy[21:0], coarse_total_q.peak};
	end
end

// Reduced-rate separable eight-tap spread blur
function automatic [HALO_W+6:0] spread8_edge(
	input  logic [HALO_W-1:0] left,
	input  logic [HALO_W-1:0] right,
	input  logic [1:0]        spread_mode
);
	logic [HALO_W:0]   pair;
	logic [HALO_W+6:0] pair_ext;
	begin
		pair     = {1'b0, left} + {1'b0, right};
		pair_ext = {6'd0, pair};
		case (spread_mode)
			SPREAD_ORIGINAL: spread8_edge = pair_ext;
			SPREAD_WIDE1:    spread8_edge = pair_ext << 2;
			SPREAD_WIDE2:    spread8_edge = pair_ext << 3;
			default:         spread8_edge = '0;
		endcase
	end
endfunction

function automatic [HALO_W+6:0] spread8_near(
	input  logic [HALO_W-1:0] left,
	input  logic [HALO_W-1:0] right,
	input  logic [1:0]        spread_mode
);
	logic [HALO_W:0]   pair;
	logic [HALO_W+6:0] pair_ext;
	begin
		pair     = {1'b0, left} + {1'b0, right};
		pair_ext = {6'd0, pair};
		case (spread_mode)
			SPREAD_ORIGINAL:
				spread8_near = (pair_ext << 3) - pair_ext;
			SPREAD_WIDE1, SPREAD_WIDE2:
				spread8_near = (pair_ext << 3) + (pair_ext << 2);
			default: spread8_near = pair_ext << 2;
		endcase
	end
endfunction

function automatic [HALO_W+6:0] spread8_mid(
	input  logic [HALO_W-1:0] left,
	input  logic [HALO_W-1:0] right,
	input  logic [1:0]        spread_mode
);
	logic [HALO_W:0]   pair;
	logic [HALO_W+6:0] pair_ext;
	begin
		pair     = {1'b0, left} + {1'b0, right};
		pair_ext = {6'd0, pair};
		case (spread_mode)
			SPREAD_ORIGINAL:
				spread8_mid = (pair_ext << 4) + (pair_ext << 2) + pair_ext;
			SPREAD_WIDE1, SPREAD_FOCUS:
				spread8_mid = (pair_ext << 4) + (pair_ext << 2);
			default:
				spread8_mid = pair_ext << 4;
		endcase
	end
endfunction

function automatic [HALO_W+6:0] spread8_center(
	input  logic [HALO_W-1:0] left,
	input  logic [HALO_W-1:0] right,
	input  logic [1:0]        spread_mode
);
	logic [HALO_W:0]   pair;
	logic [HALO_W+6:0] pair_ext;
	begin
		pair     = {1'b0, left} + {1'b0, right};
		pair_ext = {6'd0, pair};
		case (spread_mode)
			SPREAD_ORIGINAL:
				spread8_center = (pair_ext << 5) + (pair_ext << 1) + pair_ext;
			SPREAD_WIDE1, SPREAD_WIDE2:
				spread8_center = (pair_ext << 5) - (pair_ext << 2);
			default:
				spread8_center = (pair_ext << 5) + (pair_ext << 3);
		endcase
	end
endfunction

function automatic logic reduced_y_tap_valid(
	input  logic [7:0] y,
	input  logic [2:0] tap,
	input  logic [7:0] height
);
	logic [7:0] tap_ext;
	logic [7:0] tap_y;
	begin
		tap_ext = {5'd0, tap};
		if (y < tap_ext) begin
			reduced_y_tap_valid = 1'b0;
		end else begin
			tap_y               = y - tap_ext;
			reduced_y_tap_valid = (tap_y < height);
		end
	end
endfunction

function automatic [HALO_W-1:0] mask_energy(
	input  logic [HALO_W-1:0] energy,
	input  logic              valid
);
	begin
		mask_energy = valid ? energy : '0;
	end
endfunction

// Each epoch occupies one address half; every coarse x stores seven rows.
(* ramstyle = "M10K, no_rw_check" *)
logic [7*HALO_W-1:0] blur_history [0:EPOCH_RAM_DEPTH-1];
typedef struct packed {
	logic                valid;
	logic [COARSE_W-1:0] x;
	logic [7:0]          y;
	logic [7:0]          height;
	logic                epoch;
	logic [HALO_W-1:0]   energy;
} blur_feed_t;

typedef struct packed {
	logic                valid;
	logic                safe;
	logic [COARSE_W-1:0] x;
	logic [7:0]          y;
	logic                epoch;
	logic [HALO_W-1:0]   energy;
	logic [7*HALO_W-1:0] history;
	logic [7:0]          tap_valid;
} blur_history_t;

typedef struct packed {
	logic                valid;
	logic                safe;
	logic [COARSE_W-1:0] x;
	logic [7:0]          y;
	logic                epoch;
	logic [1:0]          mode;
	logic [HALO_W-1:0]   tap_0;
	logic [HALO_W-1:0]   tap_1;
	logic [HALO_W-1:0]   tap_2;
	logic [HALO_W-1:0]   tap_3;
	logic [HALO_W-1:0]   tap_4;
	logic [HALO_W-1:0]   tap_5;
	logic [HALO_W-1:0]   tap_6;
	logic [HALO_W-1:0]   tap_7;
} blur_mask_t;

typedef struct packed {
	logic                valid;
	logic                safe;
	logic [COARSE_W-1:0] x;
	logic [7:0]          y;
	logic                epoch;
	logic [HALO_W+6:0]   edge_pair;
	logic [HALO_W+6:0]   near;
	logic [HALO_W+6:0]   mid;
	logic [HALO_W+6:0]   center;
} blur_partial_t;

typedef struct packed {
	logic                valid;
	logic                safe;
	logic [COARSE_W-1:0] x;
	logic [7:0]          y;
	logic                epoch;
	logic [HALO_W+6:0]   energy;
} blur_sum_t;

typedef struct packed {
	logic                valid;
	logic                safe;
	logic                row_end;
	logic                row_start;
	logic [COARSE_W-1:0] x;
	logic [7:0]          y;
	logic                epoch;
	logic [HALO_W-1:0]   energy;
} blur_output_t;

blur_feed_t       blur_feed_q;
blur_history_t    blur_history_q;
blur_mask_t       v_mask_q;
blur_partial_t    v_partial_q;
blur_sum_t        v_sum_q;
blur_output_t     v_blur_q;
wire [HALO_W-1:0] blur_row_0 = blur_history_q.history[0*HALO_W +: HALO_W];
wire [HALO_W-1:0] blur_row_1 = blur_history_q.history[1*HALO_W +: HALO_W];
wire [HALO_W-1:0] blur_row_2 = blur_history_q.history[2*HALO_W +: HALO_W];
wire [HALO_W-1:0] blur_row_3 = blur_history_q.history[3*HALO_W +: HALO_W];
wire [HALO_W-1:0] blur_row_4 = blur_history_q.history[4*HALO_W +: HALO_W];
wire [HALO_W-1:0] blur_row_5 = blur_history_q.history[5*HALO_W +: HALO_W];
wire [HALO_W-1:0] blur_row_6 = blur_history_q.history[6*HALO_W +: HALO_W];

always_ff @(posedge clk_sys) begin
	blur_feed_q.valid <= !reset && blur_in_valid;
	if (blur_in_valid) begin
		blur_feed_q.x      <= blur_in_x;
		blur_feed_q.y      <= blur_in_y;
		blur_feed_q.height <= blur_in_height;
		blur_feed_q.epoch  <= blur_in_epoch;
		blur_feed_q.energy <= blur_in_energy;
	end
	blur_history_q.valid <= !reset && blur_feed_q.valid;
	v_mask_q.valid       <= !reset && blur_history_q.valid;
	v_partial_q.valid    <= !reset && v_mask_q.valid;
	v_sum_q.valid        <= !reset && v_partial_q.valid;
	v_blur_q.valid       <= !reset && v_sum_q.valid;
	if (blur_feed_q.valid) begin
		blur_history_q.safe      <= 1'b1;
		blur_history_q.x         <= blur_feed_q.x;
		blur_history_q.y         <= blur_feed_q.y;
		blur_history_q.epoch     <= blur_feed_q.epoch;
		blur_history_q.energy    <= blur_feed_q.energy;
		blur_history_q.tap_valid <= {reduced_y_tap_valid(blur_feed_q.y, 3'd7, blur_feed_q.height),
		                             reduced_y_tap_valid(blur_feed_q.y, 3'd6, blur_feed_q.height),
		                             reduced_y_tap_valid(blur_feed_q.y, 3'd5, blur_feed_q.height),
		                             reduced_y_tap_valid(blur_feed_q.y, 3'd4, blur_feed_q.height),
		                             reduced_y_tap_valid(blur_feed_q.y, 3'd3, blur_feed_q.height),
		                             reduced_y_tap_valid(blur_feed_q.y, 3'd2, blur_feed_q.height),
		                             reduced_y_tap_valid(blur_feed_q.y, 3'd1, blur_feed_q.height),
		                             reduced_y_tap_valid(blur_feed_q.y, 3'd0, blur_feed_q.height)};
		blur_history_q.history   <= blur_history[{blur_feed_q.epoch, blur_feed_q.x}];
	end

	v_mask_q.safe  <= blur_history_q.safe && (|blur_history_q.tap_valid);
	v_mask_q.x     <= blur_history_q.x;
	v_mask_q.y     <= blur_history_q.y;
	v_mask_q.epoch <= blur_history_q.epoch;
	v_mask_q.mode  <= halo_spread_mode_q;
	v_mask_q.tap_0 <= mask_energy( blur_history_q.energy, blur_history_q.tap_valid[0]);
	v_mask_q.tap_1 <= mask_energy( blur_row_0, blur_history_q.tap_valid[1]);
	v_mask_q.tap_2 <= mask_energy( blur_row_1, blur_history_q.tap_valid[2]);
	v_mask_q.tap_3 <= mask_energy( blur_row_2, blur_history_q.tap_valid[3]);
	v_mask_q.tap_4 <= mask_energy( blur_row_3, blur_history_q.tap_valid[4]);
	v_mask_q.tap_5 <= mask_energy( blur_row_4, blur_history_q.tap_valid[5]);
	v_mask_q.tap_6 <= mask_energy( blur_row_5, blur_history_q.tap_valid[6]);
	v_mask_q.tap_7 <= mask_energy( blur_row_6, blur_history_q.tap_valid[7]);

	if (!reset && blur_history_q.valid) begin
		blur_history[{blur_history_q.epoch, blur_history_q.x}] <= {blur_history_q.history[6*HALO_W-1:0],
		                                                           blur_history_q.energy};
	end

	v_partial_q.safe      <= v_mask_q.safe;
	v_partial_q.x         <= v_mask_q.x;
	v_partial_q.y         <= v_mask_q.y;
	v_partial_q.epoch     <= v_mask_q.epoch;
	v_partial_q.edge_pair <= spread8_edge(v_mask_q.tap_0, v_mask_q.tap_7, v_mask_q.mode);
	v_partial_q.near      <= spread8_near(v_mask_q.tap_1, v_mask_q.tap_6, v_mask_q.mode);
	v_partial_q.mid       <= spread8_mid(v_mask_q.tap_2, v_mask_q.tap_5, v_mask_q.mode);
	v_partial_q.center    <= spread8_center(v_mask_q.tap_3, v_mask_q.tap_4, v_mask_q.mode);

	v_sum_q.safe   <= v_partial_q.safe;
	v_sum_q.x      <= v_partial_q.x;
	v_sum_q.y      <= v_partial_q.y;
	v_sum_q.epoch  <= v_partial_q.epoch;
	v_sum_q.energy <= v_partial_q.edge_pair + v_partial_q.near +
	                  v_partial_q.mid + v_partial_q.center + 22'd64;

	v_blur_q.safe  <= v_sum_q.safe;
	// Decode row boundaries before horizontal history and flush control.
	v_blur_q.row_start <= (v_sum_q.x == '0);
	v_blur_q.row_end   <= (coarse_width != '0) && (v_sum_q.x + 1'b1 >= coarse_width);
	v_blur_q.x         <= v_sum_q.x;
	v_blur_q.y         <= v_sum_q.y;
	v_blur_q.epoch     <= v_sum_q.epoch;
	v_blur_q.energy    <= v_sum_q.energy[HALO_W+6:7];
end

typedef struct packed {
	logic       active;
	logic [2:0] count;
	logic       epoch;
	logic [7:0] y;
} h_flush_t;

typedef struct packed {
	logic                valid;
	logic                row_start;
	logic                current_valid;
	logic [COARSE_W-1:0] x;
	logic                epoch;
	logic [7:0]          y;
	logic [HALO_W-1:0]   energy;
} h_input_t;

typedef struct packed {
	logic       safe;
	logic [1:0] bank;
	logic       epoch;
	logic [7:0] y;
} h_row_t;

typedef struct packed {
	logic                valid;
	logic                row_complete;
	logic [COARSE_W-1:0] x;
	logic [1:0]          bank;
	logic                epoch;
	logic [7:0]          y;
	logic [1:0]          mode;
	logic [HALO_W-1:0]   tap_0;
	logic [HALO_W-1:0]   tap_1;
	logic [HALO_W-1:0]   tap_2;
	logic [HALO_W-1:0]   tap_3;
	logic [HALO_W-1:0]   tap_4;
	logic [HALO_W-1:0]   tap_5;
	logic [HALO_W-1:0]   tap_6;
	logic [HALO_W-1:0]   tap_7;
} h_mask_t;

typedef struct packed {
	logic                valid;
	logic                row_complete;
	logic [COARSE_W-1:0] x;
	logic [1:0]          bank;
	logic                epoch;
	logic [7:0]          y;
	logic [HALO_W+6:0]   edge_pair;
	logic [HALO_W+6:0]   near;
	logic [HALO_W+6:0]   mid;
	logic [HALO_W+6:0]   center;
} h_partial_t;

typedef struct packed {
	logic                valid;
	logic                row_complete;
	logic [COARSE_W-1:0] x;
	logic [1:0]          bank;
	logic                epoch;
	logic [7:0]          y;
	logic [HALO_W+6:0]   outer_pair;
	logic [HALO_W+6:0]   inner_pair;
} h_total_t;

typedef struct packed {
	logic                valid;
	logic                row_complete;
	logic [COARSE_W-1:0] x;
	logic [1:0]          bank;
	logic                epoch;
	logic [7:0]          y;
	logic [HALO_W+6:0]   sum;
} h_sum_t;

typedef struct packed {
	logic                valid;
	logic                row_complete;
	logic [COARSE_W-1:0] x;
	logic [RECON_W-1:0]  raw;
	logic [15:0]         scaled;
	logic                compress;
	logic [1:0]          bank;
	logic                epoch;
	logic [7:0]          y;
} h_write_t;

h_flush_t   h_flush_q;
h_input_t   h_input;
h_row_t     h_row_q;
h_mask_t    h_mask_next;
h_mask_t    h_mask_q;
h_partial_t h_partial_q;
h_total_t   h_total_q;
h_sum_t     h_sum_q;
h_write_t   h_write_q;

logic [HALO_W-1:0] h_history [0:6];
logic [6:0]        h_history_valid_q;
logic              h_row_safe;
logic [6:0]        h_history_valid;
wire  [21:0]       h_combined = h_sum_q.sum + 22'd16;

always_comb begin
	h_input.valid  = v_blur_q.valid || h_flush_q.active;
	h_input.x      = h_flush_q.active ? coarse_width + (3'd4 - h_flush_q.count) : v_blur_q.x;
	h_input.epoch  = h_flush_q.active ? h_flush_q.epoch : v_blur_q.epoch;
	h_input.y      = h_flush_q.active ? h_flush_q.y : v_blur_q.y;
	h_input.energy = h_flush_q.active ? '0 : v_blur_q.energy;

	h_input.row_start     = v_blur_q.valid && !h_flush_q.active && v_blur_q.row_start;
	h_input.current_valid = v_blur_q.valid && !h_flush_q.active && (v_blur_q.x < coarse_width);
	h_history_valid       = h_input.row_start ? 7'd0 : h_history_valid_q;
	h_mask_next.tap_0     = h_input.energy;
	h_mask_next.tap_1     = mask_energy(h_history[0], h_history_valid[0]);
	h_mask_next.tap_2     = mask_energy(h_history[1], h_history_valid[1]);
	h_mask_next.tap_3     = mask_energy(h_history[2], h_history_valid[2]);
	h_mask_next.tap_4     = mask_energy(h_history[3], h_history_valid[3]);
	h_mask_next.tap_5     = mask_energy(h_history[4], h_history_valid[4]);
	h_mask_next.tap_6     = mask_energy(h_history[5], h_history_valid[5]);
	h_mask_next.tap_7     = mask_energy(h_history[6], h_history_valid[6]);

	if (h_input.x < 4)
		h_mask_next.x = coarse_width + h_input.x;
	else
		h_mask_next.x = h_input.x - 3'd4;

	h_mask_next.bank  = h_input.row_start ? write_bank[h_input.epoch] : h_row_q.bank;
	h_mask_next.epoch = h_input.row_start ? h_input.epoch : h_row_q.epoch;
	h_mask_next.y     = h_input.row_start ? h_input.y : h_row_q.y;
	h_mask_next.mode  = halo_spread_mode_q;
	h_row_safe        = h_input.row_start ? v_blur_q.safe : h_row_q.safe;

	h_mask_next.valid        = h_input.valid &&
	                           ((h_input.x < 4) || (h_mask_next.x < coarse_width)) &&
	                           (h_mask_next.y >= RECON_FIRST_ROW);
	h_mask_next.row_complete = (h_input.x >= 4) && (h_mask_next.x + 1'b1 >= coarse_width) &&
	                           h_row_safe;
end

// The epoch address bit separates current- and previous-frame row history.
(* ramstyle = "M10K, no_rw_check" *)
logic [RECON_W-1:0] halo_row_0 [0:EPOCH_RAM_DEPTH-1];
(* ramstyle = "M10K, no_rw_check" *)
logic [RECON_W-1:0] halo_row_1 [0:EPOCH_RAM_DEPTH-1];
(* ramstyle = "M10K, no_rw_check" *)
logic [RECON_W-1:0] halo_row_2 [0:EPOCH_RAM_DEPTH-1];
// Round once to Q4 from the Q9 blur sum. Compression is 3E/8 + 5T/8.
// The registered sum isolates the filter's add tree from this scale operation.
wire [23:0]        h_scaled           = {1'b0, h_sum_q.sum, 1'b0} + {2'd0, h_sum_q.sum} + 24'd128;
wire [RECON_W-1:0] h_write_compressed = {1'b0, h_write_q.scaled} + {5'd0, halo_knee_offset_q, 4'd0};
wire [RECON_W-1:0] h_write_energy     = h_write_q.compress ? h_write_compressed : h_write_q.raw;

// y modulo 3 selects a reconstruction bank: even bits weigh 1, odd bits weigh 2.
function automatic [1:0] bank_for_reduced_y(
	input logic [7:0] y
);
	logic [3:0] folded;
	begin
		folded = {3'd0, y[0]} + {3'd0, y[2]} +
		         {3'd0, y[4]} + {3'd0, y[6]} +
		         {2'd0, y[1], 1'b0} + {2'd0, y[3], 1'b0} +
		         {2'd0, y[5], 1'b0} + {2'd0, y[7], 1'b0};
		if (folded >= 4'd12) folded = folded - 4'd12;
		if (folded >= 4'd6)  folded = folded - 4'd6;
		if (folded >= 4'd3)  folded = folded - 4'd3;
		bank_for_reduced_y = folded[1:0];
	end
endfunction

function automatic logic row_in_recon_ring(
	input  logic [7:0] y,
	input  logic [7:0] rows_done
);
	logic [7:0] oldest_resident;
	begin
		if (y < RECON_FIRST_ROW || y >= rows_done) begin
			row_in_recon_ring = 1'b0;
		end else if (rows_done <= RECON_FIRST_ROW + 8'd3) begin
			row_in_recon_ring = 1'b1;
		end else begin
			oldest_resident   = rows_done - 8'd3;
			row_in_recon_ring = (y >= oldest_resident);
		end
	end
endfunction

function automatic [7:0] clamp_recon_bottom_y(
	input  logic [7:0] y,
	input  logic [7:0] rows_done
);
	begin
		if (y >= rows_done && rows_done > RECON_FIRST_ROW)
			clamp_recon_bottom_y = rows_done - 1'b1;
		else
			clamp_recon_bottom_y = y;
	end
endfunction

integer history_i;
always_ff @(posedge clk_sys) begin
	h_mask_q               <= h_mask_next;
	h_partial_q.valid      <= !reset && h_mask_q.valid;
	h_total_q.valid        <= !reset && h_partial_q.valid;
	h_sum_q.valid          <= !reset && h_total_q.valid;
	h_write_q.valid        <= !reset && h_sum_q.valid;
	h_mask_q.valid         <= !reset && h_mask_next.valid;
	h_total_q.row_complete <= h_partial_q.row_complete;
	h_total_q.x            <= h_partial_q.x;
	h_total_q.bank         <= h_partial_q.bank;
	h_total_q.epoch        <= h_partial_q.epoch;
	h_total_q.y            <= h_partial_q.y;
	h_total_q.outer_pair   <= h_partial_q.edge_pair + h_partial_q.near;
	h_total_q.inner_pair   <= h_partial_q.mid + h_partial_q.center;

	h_sum_q.row_complete   <= h_total_q.row_complete;
	h_sum_q.x              <= h_total_q.x;
	h_sum_q.bank           <= h_total_q.bank;
	h_sum_q.epoch          <= h_total_q.epoch;
	h_sum_q.y              <= h_total_q.y;
	h_sum_q.sum            <= h_total_q.outer_pair + h_total_q.inner_pair;
	h_write_q.row_complete <= h_sum_q.row_complete;
	h_write_q.x            <= h_sum_q.x;
	h_write_q.bank         <= h_sum_q.bank;
	h_write_q.epoch        <= h_sum_q.epoch;
	h_write_q.y            <= h_sum_q.y;
	h_write_q.raw          <= h_combined[21:5];
	h_write_q.scaled       <= h_scaled[23:8];
	h_write_q.compress     <= halo_knee_enable_q && (h_sum_q.sum > {1'b0, halo_knee_threshold_q, 9'd0});

	h_partial_q.row_complete <= h_mask_q.row_complete;
	h_partial_q.x            <= h_mask_q.x;
	h_partial_q.bank         <= h_mask_q.bank;
	h_partial_q.epoch        <= h_mask_q.epoch;
	h_partial_q.y            <= h_mask_q.y;
	h_partial_q.edge_pair    <= spread8_edge(h_mask_q.tap_0, h_mask_q.tap_7, h_mask_q.mode);
	h_partial_q.near         <= spread8_near(h_mask_q.tap_1, h_mask_q.tap_6, h_mask_q.mode);
	h_partial_q.mid          <= spread8_mid(h_mask_q.tap_2, h_mask_q.tap_5, h_mask_q.mode);
	h_partial_q.center       <= spread8_center(h_mask_q.tap_3, h_mask_q.tap_4, h_mask_q.mode);

	if (reset) begin
		h_flush_q         <= '0;
		write_bank[0]     <= RECON_FIRST_BANK;
		write_bank[1]     <= RECON_FIRST_BANK;
		completed_rows[0] <= 8'd0;
		completed_rows[1] <= 8'd0;
		h_row_q           <=   '0;
		for (history_i = 0; history_i < 7; history_i = history_i + 1)
			h_history[history_i] <= '0;
		h_history_valid_q <= 7'd0;
	end else begin
		if (source_frame_active_start) begin
			write_bank[next_source_epoch]     <= RECON_FIRST_BANK;
			completed_rows[next_source_epoch] <= 8'd0;
		end

		if (h_write_q.valid) begin
			case (h_write_q.bank)
				2'd0:    halo_row_0[{h_write_q.epoch, h_write_q.x}] <= h_write_energy;
				2'd1:    halo_row_1[{h_write_q.epoch, h_write_q.x}] <= h_write_energy;
				default: halo_row_2[{h_write_q.epoch, h_write_q.x}] <= h_write_energy;
			endcase

			if (h_write_q.row_complete) begin
				write_bank[h_write_q.epoch]     <= (h_write_q.bank == 2'd2) ? 2'd0 : h_write_q.bank + 1'b1;
				completed_rows[h_write_q.epoch] <= h_write_q.y + 8'd1;
			end
		end

		if (v_blur_q.valid && v_blur_q.row_end) begin
			h_flush_q.active <= 1'b1;
			h_flush_q.count  <= 3'd4;
			h_flush_q.epoch  <= v_blur_q.epoch;
			h_flush_q.y      <= v_blur_q.y;
		end else if (h_flush_q.active) begin
			if (h_flush_q.count == 3'd1) begin
				h_flush_q.active <= 1'b0;
				h_flush_q.count  <= 3'd0;
			end else begin
				h_flush_q.count <= h_flush_q.count - 1'b1;
			end
		end

		if (h_input.valid) begin
			if (h_input.row_start) begin
				h_row_q.safe  <= v_blur_q.safe;
				h_row_q.bank  <= write_bank[h_input.epoch];
				h_row_q.epoch <= h_input.epoch;
				h_row_q.y     <= h_input.y;
			end

			h_history[6] <= h_history[5];
			h_history[5] <= h_history[4];
			h_history[4] <= h_history[3];
			h_history[3] <= h_history[2];
			h_history[2] <= h_history[1];
			h_history[1] <= h_history[0];
			h_history[0] <= h_input.energy;
			if (h_input.row_start) begin
				h_history_valid_q <= {6'd0, h_input.current_valid};
			end else begin
				h_history_valid_q[6] <= h_history_valid_q[5];
				h_history_valid_q[5] <= h_history_valid_q[4];
				h_history_valid_q[4] <= h_history_valid_q[3];
				h_history_valid_q[3] <= h_history_valid_q[2];
				h_history_valid_q[2] <= h_history_valid_q[1];
				h_history_valid_q[1] <= h_history_valid_q[0];
				h_history_valid_q[0] <= h_input.current_valid;
			end
		end
	end
end

// Bilinear reconstruction centers the reduction grid and filter kernel.
localparam [11:0] RECONSTRUCTION_PIPELINE_X_ADVANCE = 12'd5;
localparam [11:0] RECONSTRUCTION_X_ADVANCE          = RECONSTRUCTION_PIPELINE_X_ADVANCE +
                                                      {8'd0, RECON_SAMPLE_X_ADVANCE};

typedef struct packed {
	logic       ready;
	logic [1:0] latest_bank;
	logic [1:0] prev_bank;
	logic       epoch;
	logic       latest_valid;
	logic       prev_valid;
	logic [4:0] v_weight;
} display_line_t;

typedef struct packed {
	logic        valid;
	logic [11:0] recon_line;
	logic        epoch;
} line_request_t;

typedef struct packed {
	logic       valid;
	logic       epoch;
	logic [7:0] latest_y;
	logic [7:0] prev_y;
	logic       prev_y_valid;
	logic [7:0] rows_done;
	logic       visible;
	logic [4:0] v_weight;
} line_coord_t;

typedef struct packed {
	logic       valid;
	logic       epoch;
	logic [1:0] latest_bank;
	logic [1:0] prev_bank;
	logic       latest_visible;
	logic       prev_visible;
	logic       any_visible;
	logic [4:0] v_weight;
} line_decode_t;

typedef struct packed {
	logic        valid;
	logic [11:0] x;
	logic [4:0]  v_weight;
	logic        rows_valid;
} recon_step_t;

typedef struct packed {
	logic               valid;
	logic [RECON_W-1:0] latest;
	logic [RECON_W-1:0] prev;
} h_pair_t;

typedef struct packed {
	logic                    valid;
	logic [4:0]              weight;
	logic [RECON_W-1:0]      prev;
	logic signed [RECON_W:0] delta;
} v_blend_t;

typedef struct packed {
	logic                      valid;
	logic signed [RECON_W+5:0] base;
	logic signed [RECON_W+5:0] scaled;
} v_product_t;

typedef struct packed {
	logic               valid;
	logic [RECON_W-1:0] energy;
} halo_output_t;

typedef struct packed {
	logic [COARSE_W-1:0] addr;
	logic                in_range;
} segment_prefetch_t;

typedef struct packed {
	logic                valid;
	logic                in_range;
	logic [COARSE_W-1:0] addr;
} segment_read_t;

typedef struct packed {
	logic               valid;
	logic               latest_valid;
	logic               prev_valid;
	logic [RECON_W-1:0] row_0;
	logic [RECON_W-1:0] row_1;
	logic [RECON_W-1:0] row_2;
} segment_rows_t;

typedef struct packed {
	logic [RECON_W-1:0] latest;
	logic [RECON_W-1:0] prev;
} segment_sample_t;

typedef struct packed {
	logic                    valid;
	logic signed [RECON_W:0] latest_delta;
	logic signed [RECON_W:0] prev_delta;
} segment_start_t;

display_line_t      display_line_q;
line_request_t      line_request_q;
line_coord_t        line_coord_q;
line_decode_t       line_decode_q;
recon_step_t        recon_q;
h_pair_t            h_pair_q;
v_blend_t           v_blend_q;
v_product_t         v_product_q;
halo_output_t       halo_output_q;
segment_prefetch_t  segment_prefetch_q;
segment_read_t      segment_read_q;
segment_rows_t      segment_rows_q;
segment_sample_t    segment_sample_q;
segment_start_t     segment_start_q;
logic               wide_active;
logic [11:0]        wide_x;
logic [RECON_W-1:0] right_latest;
logic [RECON_W-1:0] right_prev;

wire [12:0] line_packet_sample_line  = halo_grid_8 ?
                                       ((line_request_q.recon_line != 12'd0) ?
                                            {1'b0, line_request_q.recon_line} - 13'd1 :
                                            13'd0) :
                                       {1'b0, line_request_q.recon_line} + 13'd7;
wire [7:0]  line_packet_base_y       = full_line_to_coarse_y(line_packet_sample_line[11:0], halo_grid_8);
wire [7:0]  line_packet_latest_y     = line_packet_base_y + VERTICAL_CENTER_DELAY_ROWS;
wire [7:0]  line_packet_prev_y       = line_packet_latest_y - 1'b1;
wire        line_packet_prev_y_valid = (line_packet_latest_y != 8'd0);
wire [7:0]  line_packet_rows_done    = completed_rows[line_request_q.epoch];
wire        line_packet_visible      = (line_request_q.recon_line < prev_frame_lines);
wire [4:0]  line_packet_v_weight     = halo_grid_8 ? {line_packet_sample_line[2:0], 2'b10}
                                                   : {line_packet_sample_line[3:0], 1'b1};

wire [7:0] line_coord_latest_read_y   = clamp_recon_bottom_y(line_coord_q.latest_y, line_coord_q.rows_done);
wire [7:0] line_coord_prev_read_y     = clamp_recon_bottom_y(line_coord_q.prev_y, line_coord_q.rows_done);
wire [1:0] line_coord_latest_bank     = bank_for_reduced_y(line_coord_latest_read_y);
wire       line_coord_latest_visible  = line_coord_q.visible &&
                                        row_in_recon_ring(line_coord_latest_read_y, line_coord_q.rows_done);
wire [1:0] line_coord_prev_bank       = bank_for_reduced_y(line_coord_prev_read_y);
wire       line_coord_prev_visible    = (line_coord_q.visible &&
                                         line_coord_q.prev_y_valid &&
                                         row_in_recon_ring(line_coord_prev_read_y, line_coord_q.rows_done));
wire       line_coord_any_row_visible = line_coord_latest_visible || line_coord_prev_visible;

function automatic signed [RECON_W:0] interp_delta(
	input  logic [RECON_W-1:0] left,
	input  logic [RECON_W-1:0] right
);
	begin
		interp_delta = $signed({1'b0, right}) - $signed({1'b0, left});
	end
endfunction

wire        recon_next_valid      = line_decode_q.valid || wide_active;
wire [11:0] recon_next_x          = line_decode_q.valid ? RECONSTRUCTION_X_ADVANCE : wide_x;
wire [4:0]  recon_next_v_weight   = line_decode_q.valid ? line_decode_q.v_weight : display_line_q.v_weight;
wire        recon_next_rows_valid = line_decode_q.valid ?
                                    line_decode_q.any_visible :
                                    (display_line_q.ready &&
                                     (display_line_q.latest_valid || display_line_q.prev_valid));

logic signed [RECON_W:0]   latest_delta;
logic signed [RECON_W:0]   prev_delta;
logic signed [RECON_W+5:0] latest_ramp;
logic signed [RECON_W+5:0] prev_ramp;

wire [3:0]          recon_phase    = halo_grid_8 ? {1'b0, recon_q.x[2:0]} : recon_q.x[3:0];
wire [COARSE_W-1:0] recon_coarse_x = halo_grid_8 ? COARSE_W'(recon_q.x[10:3]) : COARSE_W'(recon_q.x[11:4]);

function automatic [RECON_W-1:0] row_bank_sample(
	input  logic [1:0]         bank,
	input  logic [RECON_W-1:0] row_0,
	input  logic [RECON_W-1:0] row_1,
	input  logic [RECON_W-1:0] row_2
);
	begin
		case (bank)
			2'd0:    row_bank_sample = row_0;
			2'd1:    row_bank_sample = row_1;
			default: row_bank_sample = row_2;
		endcase
	end
endfunction

function automatic signed [RECON_W+5:0] interp_start_from_delta(
	input  logic [RECON_W-1:0]      left,
	input  logic signed [RECON_W:0] delta,
	input  logic                    grid_8
);
	begin
		interp_start_from_delta = $signed({1'b0, left, 5'b00000}) +
		                          (grid_8 ? {{4{delta[RECON_W]}}, delta, 1'b0}
		                                  : {{5{delta[RECON_W]}}, delta}) +
		                          23'sd16;
	end
endfunction

function automatic signed [RECON_W+5:0] interp_advance(
	input  logic signed [RECON_W+5:0] ramp,
	input  logic signed [RECON_W:0]   delta,
	input  logic                      grid_8
);
	begin
		interp_advance = ramp + (grid_8 ? {{3{delta[RECON_W]}}, delta, 2'b00}
		                                : {{4{delta[RECON_W]}}, delta, 1'b0});
	end
endfunction

function automatic [RECON_W-1:0] interp_ramp_energy(
	input logic signed [RECON_W+5:0] ramp
);
	begin
		interp_ramp_energy = ramp[RECON_W+4:5];
	end
endfunction

function automatic signed [RECON_W+5:0] v_lerp_base(
	input logic [RECON_W-1:0] left
);
	begin
		// Include the rounding bias before the registered interpolation sum.
		v_lerp_base = $signed({1'b0, left, 5'b10000});
	end
endfunction

function automatic signed [RECON_W+5:0] v_lerp_scaled_delta(
	input  logic signed [RECON_W:0] delta,
	input  logic [4:0]              weight
);
	begin
		v_lerp_scaled_delta = delta * $signed({1'b0, weight});
	end
endfunction

function automatic [RECON_W-1:0] v_lerp_finish(
	input  logic signed [RECON_W+5:0] base,
	input  logic signed [RECON_W+5:0] scaled_delta
);
	logic signed [RECON_W+5:0] rounded;
	begin
		rounded       = base + scaled_delta;
		v_lerp_finish = rounded[RECON_W+4:5];
	end
endfunction

always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		// Sample the horizontal ramps once per output pixel.
		h_pair_q.latest <= interp_ramp_energy(latest_ramp);
		h_pair_q.prev   <= interp_ramp_energy(prev_ramp);

		// Vertical interpolation: (prev*32 + (latest-prev)*weight + 16) >> 5.
		// Only valid results can reach the visible halo.
		v_blend_q.weight     <= recon_q.v_weight;
		v_blend_q.prev       <= h_pair_q.prev;
		v_blend_q.delta      <= interp_delta(h_pair_q.prev, h_pair_q.latest);
		v_product_q.base     <= v_lerp_base(v_blend_q.prev);
		v_product_q.scaled   <= v_lerp_scaled_delta(v_blend_q.delta, v_blend_q.weight);

		halo_output_q.energy <= v_lerp_finish(v_product_q.base, v_product_q.scaled);
	end
	if (reset) begin
		display_line_q      <=    '0;
		wide_active         <=  1'b0;
		wide_x              <= 12'd0;
		right_latest        <=    '0;
		right_prev          <=    '0;
		source_line_y       <= 12'd0;
		prev_frame_lines    <= active_height_q;
		line_request_q      <=      '0;
		line_coord_q        <=      '0;
		line_decode_q       <=      '0;
		recon_q             <=      '0;
		h_pair_q.valid      <=    1'b0;
		latest_delta        <=  14'sd0;
		prev_delta          <=  14'sd0;
		latest_ramp         <= 23'sd16;
		prev_ramp           <= 23'sd16;
		v_blend_q.valid     <=    1'b0;
		v_product_q.valid   <=    1'b0;
		halo_output_q.valid <=    1'b0;
		segment_prefetch_q  <=      '0;
		segment_read_q      <=      '0;
		segment_rows_q      <=      '0;
		segment_sample_q    <=      '0;
		segment_start_q     <=      '0;
	end else if (ce_pix) begin
		segment_read_q.valid        <= 1'b0;
		segment_rows_q.valid        <= segment_read_q.valid;
		segment_rows_q.latest_valid <= segment_read_q.valid && segment_read_q.in_range &&
		                               display_line_q.latest_valid;
		segment_rows_q.prev_valid   <= segment_read_q.valid && segment_read_q.in_range &&
		                               display_line_q.prev_valid;
		h_pair_q.valid              <= recon_q.valid && recon_q.rows_valid;
		v_blend_q.valid             <= h_pair_q.valid;
		v_product_q.valid           <= v_blend_q.valid;

		// Prepare each span five pixels before its end: choose and register
		// the address, read row RAM, form the delta, then load the ramp.
		if (recon_q.valid && recon_phase == grid_prefetch_phase) begin
			logic [COARSE_W-1:0] prefetch_addr;
			logic [COARSE_W-1:0] last_addr;

			if (coarse_width == '0) begin
				segment_prefetch_q.addr     <=   '0;
				segment_prefetch_q.in_range <= 1'b0;
			end else if (recon_coarse_x < grid_recon_lead) begin
				segment_prefetch_q.addr     <=   '0;
				segment_prefetch_q.in_range <= 1'b0;
			end else if (recon_coarse_x < grid_recon_lag) begin
				segment_prefetch_q.addr     <= coarse_width + recon_coarse_x - grid_recon_lead;
				segment_prefetch_q.in_range <= 1'b1;
			end else begin
				last_addr     = coarse_width - 1'b1;
				prefetch_addr = recon_coarse_x - grid_recon_lag;
				if (prefetch_addr >= coarse_width)
					segment_prefetch_q.addr <= last_addr;
				else
					segment_prefetch_q.addr <= prefetch_addr;
				segment_prefetch_q.in_range <= 1'b1;
			end
		end

		if (recon_q.valid && recon_phase == grid_read_phase) begin
			segment_read_q.valid    <= 1'b1;
			segment_read_q.addr     <= segment_prefetch_q.addr;
			segment_read_q.in_range <= segment_prefetch_q.in_range;
		end

		if (segment_read_q.valid) begin
			segment_rows_q.row_0 <= halo_row_0[{display_line_q.epoch, segment_read_q.addr}];
			segment_rows_q.row_1 <= halo_row_1[{display_line_q.epoch, segment_read_q.addr}];
			segment_rows_q.row_2 <= halo_row_2[{display_line_q.epoch, segment_read_q.addr}];
		end

		if (segment_rows_q.valid) begin
			logic [RECON_W-1:0] latest_sample;
			logic [RECON_W-1:0] prev_sample;
			latest_sample = segment_rows_q.latest_valid ?
			                row_bank_sample(display_line_q.latest_bank, segment_rows_q.row_0,
			                                segment_rows_q.row_1, segment_rows_q.row_2) :
			                '0;
			prev_sample   = segment_rows_q.prev_valid ?
			                row_bank_sample(display_line_q.prev_bank, segment_rows_q.row_0,
			                                segment_rows_q.row_1, segment_rows_q.row_2) :
			                '0;
			segment_sample_q.latest      <= latest_sample;
			segment_sample_q.prev        <= prev_sample;
			segment_start_q.latest_delta <= interp_delta(right_latest, latest_sample);
			segment_start_q.prev_delta   <= interp_delta(right_prev, prev_sample);
			segment_start_q.valid        <= 1'b1;
		end

		if (recon_q.valid && recon_phase == grid_phase_last) begin
			right_latest <= segment_sample_q.latest;
			right_prev   <= segment_sample_q.prev;
			if (segment_start_q.valid) begin
				latest_delta <= segment_start_q.latest_delta;
				prev_delta   <= segment_start_q.prev_delta;
				latest_ramp  <= interp_start_from_delta(right_latest, segment_start_q.latest_delta,
				                                        halo_grid_8);
				prev_ramp    <= interp_start_from_delta(right_prev, segment_start_q.prev_delta,
				                                        halo_grid_8);
			end else begin
				latest_delta <=  14'sd0;
				prev_delta   <=  14'sd0;
				latest_ramp  <= 23'sd16;
				prev_ramp    <= 23'sd16;
			end
			segment_start_q.valid <= 1'b0;
		end else if (recon_q.valid) begin
			latest_ramp <= interp_advance(latest_ramp, latest_delta, halo_grid_8);
			prev_ramp   <= interp_advance(prev_ramp, prev_delta, halo_grid_8);
		end

		line_request_q.valid <= line_start;
		if (line_start) begin
			line_request_q.recon_line <= recon_line;
			line_request_q.epoch      <= recon_epoch;
		end
		line_coord_q.valid <= line_request_q.valid;
		if (line_request_q.valid) begin
			line_coord_q.epoch        <= line_request_q.epoch;
			line_coord_q.latest_y     <= line_packet_latest_y;
			line_coord_q.prev_y       <= line_packet_prev_y;
			line_coord_q.prev_y_valid <= line_packet_prev_y_valid;
			line_coord_q.rows_done    <= line_packet_rows_done;
			line_coord_q.visible      <= line_packet_visible;
			line_coord_q.v_weight     <= line_packet_v_weight;
		end
		line_decode_q.valid <= line_coord_q.valid;
		if (line_coord_q.valid) begin
			line_decode_q.epoch          <= line_coord_q.epoch;
			line_decode_q.latest_bank    <= line_coord_latest_bank;
			line_decode_q.prev_bank      <= line_coord_prev_bank;
			line_decode_q.latest_visible <= line_coord_latest_visible;
			line_decode_q.prev_visible   <= line_coord_prev_visible;
			line_decode_q.any_visible    <= line_coord_any_row_visible;
			line_decode_q.v_weight       <= line_coord_q.v_weight;
		end

		if (source_frame_active_start) begin
			prev_frame_lines <= (source_line_y != 12'd0) ? source_line_y : active_height_q;
			source_line_y    <= 12'd1;
		end else if (line_start) begin
			source_line_y <= source_line_y + 1'b1;
		end

		halo_output_q.valid <= v_product_q.valid;

		recon_q.valid       <= recon_next_valid;
		recon_q.x           <= recon_next_x;
		recon_q.v_weight    <= recon_next_v_weight;
		recon_q.rows_valid  <= recon_next_rows_valid;

		if (line_decode_q.valid) begin
			display_line_q.epoch        <= line_decode_q.epoch;
			display_line_q.latest_bank  <= line_decode_q.latest_bank;
			display_line_q.prev_bank    <= line_decode_q.prev_bank;
			display_line_q.latest_valid <= line_decode_q.latest_visible;
			display_line_q.prev_valid   <= line_decode_q.prev_visible;
			display_line_q.v_weight     <= line_decode_q.v_weight;
			display_line_q.ready        <= 1'b1;
		end

		if (line_start) begin
			display_line_q.ready    <=    1'b0;
			wide_active             <=    1'b0;
			right_latest            <=      '0;
			right_prev              <=      '0;
			latest_delta            <=  14'sd0;
			prev_delta              <=  14'sd0;
			latest_ramp             <= 23'sd16;
			prev_ramp               <= 23'sd16;
			segment_read_q.valid    <=    1'b0;
			segment_read_q.in_range <=    1'b0;
			segment_rows_q.valid    <=    1'b0;
			segment_start_q.valid   <=    1'b0;
		end else if (line_decode_q.valid) begin
			wide_active             <= 1'b1;
			wide_x                  <= RECONSTRUCTION_X_ADVANCE + 12'd1;
			right_latest            <=      '0;
			right_prev              <=      '0;
			latest_delta            <=  14'sd0;
			prev_delta              <=  14'sd0;
			latest_ramp             <= 23'sd16;
			prev_ramp               <= 23'sd16;
			segment_read_q.valid    <=    1'b0;
			segment_read_q.in_range <=    1'b0;
			segment_rows_q.valid    <=    1'b0;
			segment_start_q.valid   <=    1'b0;
		end else if (wide_active) begin
			if (wide_x == MAX_WIDTH + H_DELAY - 1)
				wide_active <= 1'b0;
			else
				wide_x <= wide_x + 1'b1;
		end
	end
end

always_comb begin
	HALO_ENERGY_OUT = halo_output_q.valid ? halo_output_q.energy : '0;
	HALO_VALID_OUT  = halo_output_q.valid;
end

endmodule

`default_nettype wire
