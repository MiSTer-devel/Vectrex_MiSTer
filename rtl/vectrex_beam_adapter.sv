//============================================================================
// Vectrex beam-to-framebuffer adapter.
//
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// Convert beam samples to framebuffer pixels, accumulate dwell intensity,
// and infer frame boundaries from Timer 2 reloads or a timed fallback.
//============================================================================

`default_nettype none

module vectrex_beam_adapter
(
	input wire               clk_source,
	input wire               reset,
	input wire               beam_ce,
	input wire signed [19:0] beam_x,
	input wire signed [19:0] beam_y,
	input wire        [7:0]  beam_z,
	input wire               beam_on,
	input wire               beam_zero_n,
	input wire               t2_reload,
	input wire        [15:0] t2_period,

	input wire [1:0] geometry_mode,
	input wire [1:0] orient,
	input wire       open_matte,
	input wire       zoom_normal,
	input wire       vertical_offset,
	input wire [4:0] beam_min_z,
	input wire [1:0] dwell_reference,
	input wire [1:0] velocity_mode,

	output logic        matte_open,
	output logic [11:0] matte_left,
	output logic [11:0] matte_right,
	output logic [11:0] matte_top,
	output logic [11:0] matte_bottom,
	output logic [10:0] pixel_x,
	output logic [10:0] pixel_y,
	output logic [11:0] pixel_z,
	output logic [13:0] pixel_dwell_dose,
	output logic        pixel_valid,
	output logic        pixel_replace,
	output logic        frame_done
);
import vfb_control_pkg::*;

// Before applying the view offset, the calibrated view spans beam coordinates
// X = -180000..180000 and Y = -135000..135000.
localparam integer      MAX_X                = 5625 * 4 * 8;
localparam integer      MAX_Y                = 5625 * 3 * 8;
localparam integer      PERCEPTUAL_OFFSET    =       3000;
localparam integer      SCALE_SHIFT          =         22;
localparam logic [15:0] EOF_T2_MIN_PERIOD    =    16'd300; // 200 us at 1.5 MHz
localparam logic [19:0] FALLBACK_MIN_SAMPLES = 20'd480000;
localparam logic [19:0] FALLBACK_PERIOD_MAX  =  20'h7ffff;
// For dwell sizing, sum max(Z-28, 0) over the dwell's 12 MHz beam samples,
// including the first sample. This subtraction of 28 is fixed;
// Beam Threshold and Brightness do not change it.
localparam logic [16:0] DWELL_DOSE_END = 17'd37728;
// The 19-bit sum allows dwell intensity to reach 4095 even with the largest
// Reference Dwell setting of 104 samples.
localparam logic [18:0]        DWELL_ENERGY_MAX =   19'h7ffff;
localparam logic [1:0]         ORIENT_NORMAL    =        2'd0;
localparam logic [1:0]         ORIENT_CCW       =        2'd1;
localparam logic [1:0]         ORIENT_CW        =        2'd2;
localparam logic signed [20:0] MATTE_X_MAX      = 21'sd360000;
localparam logic signed [20:0] MATTE_Y_MAX      = 21'sd270000;
localparam logic [6:0]         GEOMETRY_RESET   = {1'b1, 1'b0, GEOMETRY_720, 1'b0, ORIENT_NORMAL};

typedef struct packed {
	logic               open_matte;
	logic        [1:0]  orientation;
	logic signed [20:0] origin_x;
	logic        [11:0] fb_width;
	logic        [11:0] fb_height;
	logic signed [12:0] offset_x;
	logic signed [12:0] offset_y;
	logic signed [15:0] scale_x;
	logic signed [15:0] scale_y;
	logic        [11:0] matte_left;
	logic        [11:0] matte_right;
	logic        [11:0] matte_top;
	logic        [11:0] matte_bottom;
} geometry_t;

// Set the vector image size and position for each resolution and rotation.
// Overlay framing aligns the vectors with the artwork; Screen framing
// enlarges the picture.
// The matte bounds give the visible rectangle's limits in output pixels.
// With Open Matte off, vectors outside these limits are hidden.
function automatic geometry_t decode_geometry(input logic [6:0] select);
	geometry_t geometry;
	begin
		geometry            = '0;
		geometry.open_matte = select[5];
		case (select[1:0])
			ORIENT_CCW: geometry.orientation = ORIENT_CCW;
			ORIENT_CW:  geometry.orientation = ORIENT_CW;
			default:    geometry.orientation = ORIENT_NORMAL;
		endcase
		// In Normal orientation, beam X controls vertical position.
		// Include the view offset in origin_x so it rotates with the image.
		geometry.origin_x = 21'(MAX_X);
		if (select[6])
			geometry.origin_x = (geometry.orientation == ORIENT_CW) ?
			                    21'(MAX_X + PERCEPTUAL_OFFSET) :
			                    21'(MAX_X - PERCEPTUAL_OFFSET);
		case (select[4:3])
			GEOMETRY_1080: begin
				geometry.fb_width     = 12'd1360;
				geometry.fb_height    = 12'd1080;
				geometry.matte_left   =    12'd0;
				geometry.matte_right  = 12'd1359;
				geometry.matte_top    =    12'd0;
				geometry.matte_bottom = 12'd1079;
				if (geometry.orientation != ORIENT_NORMAL) begin
					geometry.offset_x = select[2] ? -13'sd57 : 13'sd25;
					geometry.offset_y = select[2] ? -13'sd13 : 13'sd49;
					geometry.scale_x  = select[2] ? 16'sd17160 : 16'sd15250;
					geometry.scale_y  = select[2] ? 16'sd17160 : 16'sd15250;
					if (!select[2]) begin
						geometry.matte_left   =   12'd25;
						geometry.matte_right  = 12'd1333;
						geometry.matte_top    =   12'd49;
						geometry.matte_bottom = 12'd1030;
					end
				end
				else begin
					geometry.offset_x    = select[2] ? 13'sd236 : 13'sd275;
					geometry.offset_y    = select[2] ? -13'sd52 : 13'sd0;
					geometry.scale_x     = select[2] ? 16'sd13782 : 16'sd12582;
					geometry.scale_y     = select[2] ? 16'sd13782 : 16'sd12582;
					geometry.matte_left  = select[2] ? 12'd236 : 12'd275;
					geometry.matte_right = select[2] ? 12'd1123 : 12'd1084;
				end
			end

			GEOMETRY_720: begin
				geometry.fb_width     = 12'd916;
				geometry.fb_height    = 12'd720;
				geometry.matte_left   =   12'd0;
				geometry.matte_right  = 12'd915;
				geometry.matte_top    =   12'd0;
				geometry.matte_bottom = 12'd719;
				if (geometry.orientation != ORIENT_NORMAL) begin
					geometry.offset_x = select[2] ? -13'sd33 : 13'sd17;
					geometry.offset_y = select[2] ? -13'sd9 : 13'sd29;
					geometry.scale_x  = select[2] ? 16'sd11440 : 16'sd10271;
					geometry.scale_y  = select[2] ? 16'sd11440 : 16'sd10271;
					if (!select[2]) begin
						geometry.matte_left   =  12'd17;
						geometry.matte_right  = 12'd898;
						geometry.matte_top    =  12'd29;
						geometry.matte_bottom = 12'd690;
					end
				end
				else begin
					geometry.offset_x    = select[2] ? 13'sd162 : 13'sd188;
					geometry.offset_y    = select[2] ? -13'sd35 : 13'sd0;
					geometry.scale_x     = select[2] ? 16'sd9188 : 16'sd8388;
					geometry.scale_y     = select[2] ? 16'sd9188 : 16'sd8388;
					geometry.matte_left  = select[2] ? 12'd162 : 12'd188;
					geometry.matte_right = select[2] ? 12'd753 : 12'd727;
				end
			end

			GEOMETRY_480: begin
				geometry.fb_width     = 12'd720;
				geometry.fb_height    = 12'd480;
				geometry.matte_left   =   12'd0;
				geometry.matte_right  = 12'd719;
				geometry.matte_top    =   12'd0;
				geometry.matte_bottom = 12'd479;
				if (geometry.orientation != ORIENT_NORMAL) begin
					geometry.offset_x = select[2] ? -13'sd9 : 13'sd27;
					geometry.offset_y = select[2] ? -13'sd6 : 13'sd18;
					geometry.scale_x  = select[2] ? 16'sd8580 : 16'sd7737;
					geometry.scale_y  = select[2] ? 16'sd7627 : 16'sd6867;
					if (!select[2]) begin
						geometry.matte_left   =  12'd27;
						geometry.matte_right  = 12'd691;
						geometry.matte_top    =  12'd18;
						geometry.matte_bottom = 12'd460;
					end
				end
				else begin
					geometry.offset_x    = select[2] ? 13'sd138 : 13'sd157;
					geometry.offset_y    = select[2] ? -13'sd23 : 13'sd0;
					geometry.scale_x     = select[2] ? 16'sd6891 : 16'sd6291;
					geometry.scale_y     = select[2] ? 16'sd6125 : 16'sd5592;
					geometry.matte_left  = select[2] ? 12'd138 : 12'd157;
					geometry.matte_right = select[2] ? 12'd581 : 12'd561;
				end
			end

			default: begin // GEOMETRY_240
				geometry.fb_width     = 12'd720;
				geometry.fb_height    = 12'd240;
				geometry.matte_left   =   12'd0;
				geometry.matte_right  = 12'd719;
				geometry.matte_top    =   12'd0;
				geometry.matte_bottom = 12'd239;
				if (geometry.orientation != ORIENT_NORMAL) begin
					geometry.offset_x = select[2] ? -13'sd9 : 13'sd27;
					geometry.offset_y = select[2] ? -13'sd3 : 13'sd9;
					geometry.scale_x  = select[2] ? 16'sd8580 : 16'sd7737;
					geometry.scale_y  = select[2] ? 16'sd3813 : 16'sd3433;
					if (!select[2]) begin
						geometry.matte_left   =  12'd27;
						geometry.matte_right  = 12'd691;
						geometry.matte_top    =   12'd9;
						geometry.matte_bottom = 12'd229;
					end
				end
				else begin
					geometry.offset_x    = select[2] ? 13'sd138 : 13'sd157;
					geometry.offset_y    = select[2] ? -13'sd12 : 13'sd0;
					geometry.scale_x     = select[2] ? 16'sd6891 : 16'sd6291;
					geometry.scale_y     = select[2] ? 16'sd3063 : 16'sd2796;
					geometry.matte_left  = select[2] ? 12'd138 : 12'd157;
					geometry.matte_right = select[2] ? 12'd581 : 12'd561;
				end
			end
		endcase
		decode_geometry = geometry;
	end
endfunction

wire  [6:0] geometry_in     = {vertical_offset, open_matte, geometry_mode, zoom_normal, orient};
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [6:0] geometry_meta   = GEOMETRY_RESET;
logic [6:0] geometry_sync   = GEOMETRY_RESET;
logic [6:0] geometry_sync_d = GEOMETRY_RESET;
logic [6:0] geometry_stable = GEOMETRY_RESET;
geometry_t  geometry_q      = decode_geometry(GEOMETRY_RESET);

assign matte_open   = geometry_q.open_matte;
assign matte_left   = geometry_q.matte_left;
assign matte_right  = geometry_q.matte_right;
assign matte_top    = geometry_q.matte_top;
assign matte_bottom = geometry_q.matte_bottom;

always_ff @(posedge clk_source) begin
	geometry_meta   <= geometry_in;
	geometry_sync   <= geometry_meta;
	geometry_sync_d <= geometry_sync;
	if (geometry_sync == geometry_sync_d) geometry_stable <= geometry_sync;
end

// Three 24 MHz processing stages: orient the beam coordinates and add the
// origin, scale to pixels, then add the framebuffer offset.
logic signed [20:0] source_h;
logic signed [20:0] source_v;
logic               source_in_matte_q;
logic signed [36:0] scaled_h;
logic signed [36:0] scaled_v;
logic        [10:0] raster_x;
logic        [10:0] raster_y;
logic               raster_in_bounds_q;
logic        [2:0]  ce_pipe;
logic        [2:0]  beam_on_pipe;
logic        [2:0]  beam_zero_pipe;
logic        [2:0]  t2_reload_pipe;
logic        [15:0] z_pipe;
logic        [7:0]  z_q;
logic signed [19:0] source_pos_x_q;
logic signed [19:0] source_pos_y_q;
logic        [2:0]  source_moved_pipe;
logic        [10:0] moving_base_q, moving_base_d, moving_z;
logic        [17:0] weighted_speed_q;
logic        [41:0] speed_loss_q;
logic        [23:0] velocity_coefficient_q = 24'((64'd6 << 32) / 2927);
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic        [3:0]  diagnostic_meta        = 4'b0010;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic        [3:0]  diagnostic_sync        = 4'b0010;
logic        [3:0]  diagnostic_sync_d      = 4'b0010;
logic        [3:0]  diagnostic_stable      = 4'b0010;
always_ff @(posedge clk_source) begin
	diagnostic_meta   <= {velocity_mode, dwell_reference};
	diagnostic_sync   <= diagnostic_meta;
	diagnostic_sync_d <= diagnostic_sync;
	if (diagnostic_sync == diagnostic_sync_d) diagnostic_stable <= diagnostic_sync;
end
wire signed [20:0] source_dx       = 21'(beam_x) - 21'(source_pos_x_q);
wire signed [20:0] source_dy       = 21'(beam_y) - 21'(source_pos_y_q);
wire        [20:0] speed_x         = source_dx[20] ? $unsigned(-source_dx) : $unsigned(source_dx);
wire        [20:0] speed_y         = source_dy[20] ? $unsigned(-source_dy) : $unsigned(source_dy);
wire        [20:0] source_speed    = speed_x > speed_y ? speed_x : speed_y;
wire        [6:0]  speed           = |source_speed[20:7] ? 7'd127 : source_speed[6:0];
wire        [6:0]  excess_speed    = speed > 7'd32 ? speed - 7'd32 : 7'd0;
wire        [10:0] input_intensity = 11'(source_intensity(beam_z[6:0], beam_min_z));
wire        [9:0]  speed_loss      = speed_loss_q[41:32] + 10'(speed_loss_q[31]);

// Beam velocity affects line brightness. Calculate the intensity reduction
// in three 24 MHz stages: multiply intensity by excess speed, multiply by the
// selected coefficient, then round and subtract the reduction from the
// original intensity.
always_ff @(posedge clk_source) begin
	case (diagnostic_stable[3:2])
		2'd0:    velocity_coefficient_q <= 24'((64'd6 << 32) / 2927);
		2'd1:    velocity_coefficient_q <= 24'((64'd8 << 32) / 3056);
		2'd2:    velocity_coefficient_q <= 24'((64'd10 << 32) / 3185);
		default: velocity_coefficient_q <= '0;
	endcase
	moving_base_q    <= input_intensity;
	moving_base_d    <= moving_base_q;
	weighted_speed_q <= input_intensity * excess_speed;
	speed_loss_q     <= weighted_speed_q * velocity_coefficient_q;
	moving_z         <= moving_base_d - {1'b0, speed_loss};
end

wire signed [20:0] matte_h_max = (geometry_q.orientation == ORIENT_NORMAL) ? MATTE_Y_MAX
                                                                           : MATTE_X_MAX;
wire signed [20:0] matte_v_max = (geometry_q.orientation == ORIENT_NORMAL) ? MATTE_X_MAX
                                                                           : MATTE_Y_MAX;
// With Open Matte off, reject beam positions outside the calibrated view
// after orientation and before scaling. Open Matte allows drawing beyond
// that view, but pixels outside the framebuffer's width or height are
// always discarded.
wire               source_h_in_matte = (source_h >= 21'sd0) && (source_h <= matte_h_max);
wire               source_v_in_matte = (source_v >= 21'sd0) && (source_v <= matte_v_max);
wire signed [13:0] scaled_h_px       = $signed(scaled_h[SCALE_SHIFT + 13:SCALE_SHIFT]);
wire signed [13:0] scaled_v_px       = $signed(scaled_v[SCALE_SHIFT + 13:SCALE_SHIFT]);
wire signed [13:0] raster_x_calc     = scaled_h_px +
                                       $signed({geometry_q.offset_x[12], geometry_q.offset_x});
wire signed [13:0] raster_y_calc     = scaled_v_px +
                                       $signed({geometry_q.offset_y[12], geometry_q.offset_y});
wire               raster_in_bounds  =
    source_in_matte_q
    && (raster_x_calc >= 14'sd0)
    && (raster_y_calc >= 14'sd0)
    && ($unsigned(raster_x_calc) < geometry_q.fb_width)
    && ($unsigned(raster_y_calc) < geometry_q.fb_height);

always_ff @(posedge clk_source) begin
	if (reset) begin
		source_h           <=   '0;
		source_v           <=   '0;
		source_in_matte_q  <= 1'b0;
		scaled_h           <=   '0;
		scaled_v           <=   '0;
		raster_x           <=   '0;
		raster_y           <=   '0;
		raster_in_bounds_q <= 1'b0;
		ce_pipe            <=   '0;
		beam_on_pipe       <=   '0;
		beam_zero_pipe     <=   '0;
		t2_reload_pipe     <=   '0;
		z_pipe             <=   '0;
		z_q                <=   '0;
		source_pos_x_q     <=   '0;
		source_pos_y_q     <=   '0;
		source_moved_pipe  <=   '0;
	end
	else begin
		case (geometry_q.orientation)
			ORIENT_CCW: begin
				source_h <= 21'(beam_x) + geometry_q.origin_x;
				source_v <= 21'(MAX_Y) - 21'(beam_y);
			end

			ORIENT_CW: begin
				source_h <= geometry_q.origin_x - 21'(beam_x);
				source_v <= 21'(beam_y) + 21'(MAX_Y);
			end

			default: begin
				source_h <= 21'(beam_y) + 21'(MAX_Y);
				source_v <= 21'(beam_x) + geometry_q.origin_x;
			end
		endcase

		source_in_matte_q  <= geometry_q.open_matte || (source_h_in_matte && source_v_in_matte);
		scaled_h           <= source_h * geometry_q.scale_x;
		scaled_v           <= source_v * geometry_q.scale_y;

		raster_x           <= raster_x_calc[10:0];
		raster_y           <= raster_y_calc[10:0];
		raster_in_bounds_q <= raster_in_bounds;

		ce_pipe            <= {ce_pipe[1:0], beam_ce};
		beam_on_pipe       <= {beam_on_pipe[1:0], beam_on};
		beam_zero_pipe     <= {beam_zero_pipe[1:0], ~beam_zero_n};
		t2_reload_pipe     <= {t2_reload_pipe[1:0], t2_reload};
		z_pipe             <= {z_pipe[7:0], beam_z};
		z_q                <= z_pipe[15:8];
		source_moved_pipe  <= {source_moved_pipe[1:0],
		                       beam_ce &&
		                       ((beam_x != source_pos_x_q) || (beam_y != source_pos_y_q))};
		if (beam_ce) begin
			source_pos_x_q <= beam_x;
			source_pos_y_q <= beam_y;
		end
	end
end

wire sample_ce      = ce_pipe[2];
wire beam_on_q      = beam_on_pipe[2];
wire beam_zero_q    = beam_zero_pipe[2];
wire source_moved_q = source_moved_pipe[2];

// Implements intensity = min(4095, round(dose / reference)), where dose is
// accumulated dwell intensity and reference is 46, 72, 88 or 104 beam samples.
// normalize_dwell multiplies by ceil(2^32 / reference), shifts right by 32,
// rounds and clamps to 4095. This is exact over the full 19-bit dose range.
function automatic [26:0] dwell_coefficient(input logic [1:0] reference_mode);
	case (reference_mode)
		2'd0: dwell_coefficient = 27'(((64'd1 << 32) + 45) / 46);
		2'd1: dwell_coefficient = 27'(((64'd1 << 32) + 71) / 72);
		2'd2: dwell_coefficient = 27'(((64'd1 << 32) + 87) / 88);
		2'd3: dwell_coefficient = 27'(((64'd1 << 32) + 103) / 104);
	endcase
endfunction

logic [26:0] dwell_coefficient_q;
always_ff @(posedge clk_source)
	dwell_coefficient_q <= dwell_coefficient(diagnostic_stable[1:0]);

function automatic [11:0] normalize_dwell(input logic [18:0] dose, input logic [26:0] coefficient);
	logic [45:0] product;
	logic [13:0] rounded;
	begin
		product         = dose * coefficient;
		rounded         = product[45:32] + 14'(product[31]);
		normalize_dwell = |rounded[13:12] ? 12'hfff : rounded[11:0];
	end
endfunction

// Detect dwell from unchanged beam coordinates. Beam movement within one
// framebuffer pixel does not count as dwell.
typedef struct packed {
	logic [10:0] x;
	logic [10:0] y;
	logic        valid;
	logic        is_dwell;
	logic        suppress;
	logic [11:0] line_z;
	logic [10:0] moving_z;
	logic [18:0] dwell_energy;
	logic [16:0] dwell_z_dose;
} beam_hold_t;

beam_hold_t hold_q;

wire beam_sample_visible = beam_on_q && raster_in_bounds_q;
// Z is signed; negative DAC levels blank the beam.
wire beam_visible = beam_sample_visible &&
                    !z_q[7] &&
                    (z_q[6:0] > {2'b00, beam_min_z});
// All brightness modes use round(1024 * max(0, Z-C) / (127-C)).
// Z 20/24/28 are the first positive levels; their cutoff floors are C=19/23/27.
// Off uses C=0 and accepts every positive Z.
// These multiply/shift forms are exact for every Z=0..127.
function automatic [11:0] source_intensity(
	input logic [6:0] z, input logic [4:0] cutoff
);
	logic [6:0]  excess;
	logic [20:0] scaled;
	begin
		excess = (z > {2'b00, cutoff}) ? z - {2'b00, cutoff} : 7'd0;
		if (cutoff == 5'd27) begin
			scaled           = 21'(excess) * 21'd5243 + 21'd243;
			source_intensity = {1'b0, scaled[19:9]};
		end else if (cutoff == 5'd23) begin
			scaled           = 21'(excess) * 21'd5041 + 21'd258;
			source_intensity = {1'b0, scaled[19:9]};
		end else if (cutoff == 5'd19) begin
			scaled           = 21'(excess) * 21'd9709 + 21'd497;
			source_intensity = {1'b0, scaled[20:10]};
		end else begin
			scaled           = 21'(z) * 21'd129 + 21'd8;
			source_intensity = {1'b0, scaled[14:4]};
		end
	end
endfunction
wire [11:0] line_z           = source_intensity(z_q[6:0], beam_min_z);
wire [19:0] dwell_energy_sum = {1'b0, hold_q.dwell_energy} + 20'(line_z);
wire [6:0]  dwell_dose_step  = z_q[6:0] > 7'd28 ? z_q[6:0] - 7'd28 : 7'd0;
// The dot-size curve ends at dose 37728. Keep the overflow bit set after
// the 16-bit sum wraps.
wire [16:0] dwell_z_sum = {1'b0, hold_q.dwell_z_dose[15:0]} + 17'(dwell_dose_step);
wire [11:0] dwell_z     = normalize_dwell(hold_q.dwell_energy, dwell_coefficient_q);
// Clamp dot-size dose at 37728, then divide by four, rounding down.
// Line pixels carry zero dwell dose.
wire [13:0] dwell_dose        = (hold_q.dwell_z_dose >= DWELL_DOSE_END) ? 14'd9432
                                                                        : hold_q.dwell_z_dose[15:2];
wire [11:0] dwell_output_z    = dwell_z > hold_q.line_z ? dwell_z : hold_q.line_z;
wire [11:0] hold_z            = !hold_q.is_dwell ? {1'b0, hold_q.moving_z} : dwell_output_z;
wire        hold_output_valid = hold_q.valid && (hold_z != 12'd0) &&
                                (hold_q.is_dwell || !hold_q.suppress);
wire        same_raster       = (raster_x == hold_q.x) && (raster_y == hold_q.y);

// Infer frame boundaries from Timer 2 reloads, with a timed fallback.
typedef enum logic [1:0] {
	EOF_RELOAD_DRIVEN,
	EOF_FALLBACK_ARMED,
	EOF_FALLBACK_RUNNING
} eof_state_t;

eof_state_t  eof_state          = EOF_RELOAD_DRIVEN;
logic        reload_pending     =  1'b0;
logic        cadence_measured   =  1'b0;
logic        cadence_contiguous =  1'b0;
logic [19:0] cadence_samples    = 20'd0;
logic [19:0] eof_count          = 20'd0;
logic [19:0] fallback_age       = 20'd0;
logic        fallback_recent    =  1'b0;

wire [15:0] loaded_period_nz        = |t2_period ? t2_period : 16'd1;
wire [19:0] loaded_period_samples   = {1'b0, loaded_period_nz, 3'b000};
wire [19:0] measured_period_samples = (eof_count >= FALLBACK_PERIOD_MAX - 20'd1) ?
                                      FALLBACK_PERIOD_MAX :
                                      eof_count + 20'd1;
wire [20:0] cadence_sum             = {1'b0, cadence_samples} + {1'b0, measured_period_samples};
wire [19:0] cadence_average         = cadence_sum[20:1] + {{19{1'b0}}, cadence_sum[0]};
wire [19:0] period_samples          = |cadence_samples ? cadence_samples : 20'd1;
wire [19:0] double_period_samples   = period_samples << 1;
wire [19:0] half_period_samples     = period_samples >> 1;
wire [19:0] fallback_period_samples = period_samples + half_period_samples;
wire [19:0] missing_limit           = double_period_samples > FALLBACK_MIN_SAMPLES ?
                                      double_period_samples :
                                      FALLBACK_MIN_SAMPLES;

wire reload_sample        = sample_ce && (reload_pending || t2_reload_pipe[2]);
wire reload_qualified     = reload_sample && t2_period >= EOF_T2_MIN_PERIOD;
wire reload_duplicate     = fallback_recent && fallback_age < half_period_samples;
wire reload_hit           = reload_qualified && !reload_duplicate;
wire fallback_zero_hit    = sample_ce && !reload_qualified && (eof_state == EOF_FALLBACK_ARMED) &&
                            beam_zero_q;
wire fallback_timeout_hit = sample_ce && !reload_qualified && (eof_state == EOF_FALLBACK_ARMED) &&
                            !beam_zero_q && (eof_count >= half_period_samples - 20'd1);
wire fallback_period_hit  = sample_ce && !reload_qualified && (eof_state == EOF_FALLBACK_RUNNING) &&
                            (eof_count >= fallback_period_samples - 20'd1);
wire fallback_hit         = fallback_zero_hit || fallback_timeout_hit || fallback_period_hit;
wire frame_request        = reload_hit || fallback_hit;
wire flush_hold           = hold_output_valid &&
                            (frame_request ||
                             !beam_visible ||
                             (source_moved_q && (hold_q.is_dwell || !same_raster)));

// Apply geometry settings during reset or at an inferred frame boundary.
always_ff @(posedge clk_source) begin
	if (reset || frame_request) geometry_q <= decode_geometry(geometry_stable);
end

always_ff @(posedge clk_source) begin
	if (reset) begin
		reload_pending <= 1'b0;
	end
	else begin
		if (t2_reload_pipe[2]) reload_pending <= 1'b1;
		if (reload_sample)     reload_pending <= 1'b0;
	end
end

// Timer 2 runs at 1.5 MHz; beam samples arrive at 12 MHz.
// Ignore reloads with a programmed period below 300 ticks (200 us), as these
// are likely from non-drawing events such as Spike's introductory speech.
// Initialize the estimated frame period from Timer 2, then update it from
// consecutive accepted reload intervals.
// Once a frame period is known, wait for the longer of two estimated
// periods or 40 ms without an accepted reload. Then emit EOF at integrator
// ZERO or after another half-period, whichever comes first. Further
// fallback markers occur approximately every 1.5 estimated periods.
always_ff @(posedge clk_source) begin
	if (reset) begin
		eof_state          <= EOF_RELOAD_DRIVEN;
		cadence_measured   <=  1'b0;
		cadence_contiguous <=  1'b0;
		cadence_samples    <= 20'd0;
		eof_count          <= 20'd0;
		fallback_age       <= 20'd0;
		fallback_recent    <=  1'b0;
	end
	else if (sample_ce) begin
		if (reload_sample) cadence_contiguous <= reload_qualified;

		if (reload_qualified) begin
			eof_state <= EOF_RELOAD_DRIVEN;
			if (!(|cadence_samples)) begin
				cadence_measured <= 1'b0;
				cadence_samples  <= loaded_period_samples;
			end
			else if (eof_state == EOF_RELOAD_DRIVEN && cadence_contiguous) begin
				cadence_measured <= 1'b1;
				cadence_samples  <= cadence_measured ? cadence_average : measured_period_samples;
			end
			eof_count       <= 20'd0;
			fallback_age    <= 20'd0;
			fallback_recent <=  1'b0;
		end
		else begin
			if (fallback_recent && fallback_age != 20'hfffff) fallback_age <= fallback_age + 20'd1;

			case (eof_state)
				EOF_RELOAD_DRIVEN: begin
					if (|cadence_samples) begin
						if (eof_count >= missing_limit - 20'd1) begin
							eof_state <= EOF_FALLBACK_ARMED;
							eof_count <= 20'd0;
						end
						else begin
							eof_count <= eof_count + 20'd1;
						end
					end
				end

				EOF_FALLBACK_ARMED: begin
					if (fallback_hit) begin
						eof_state       <= EOF_FALLBACK_RUNNING;
						eof_count       <= 20'd0;
						fallback_age    <= 20'd0;
						fallback_recent <=  1'b1;
					end
					else begin
						eof_count <= eof_count + 20'd1;
					end
				end

				default: begin // EOF_FALLBACK_RUNNING
					if (fallback_hit) begin
						eof_count       <= 20'd0;
						fallback_age    <= 20'd0;
						fallback_recent <=  1'b1;
					end
					else begin
						eof_count <= eof_count + 20'd1;
					end
				end
			endcase
		end
	end
end

logic frame_pending = 1'b0;

always_ff @(posedge clk_source) begin
	pixel_valid <= 1'b0;
	frame_done  <= 1'b0;

	if (reset) begin
		pixel_x          <= 11'd0;
		pixel_y          <= 11'd0;
		pixel_z          <= 12'd0;
		pixel_dwell_dose <= 14'd0;
		pixel_replace    <=  1'b0;
		hold_q           <=    '0;
		frame_pending    <=  1'b0;
	end
	else begin
		pixel_dwell_dose <= 14'd0;
		// Emit frame_done with sample_ce low, after sending any final held pixel.
		if (!sample_ce) begin
			if (frame_pending) begin
				frame_done    <= 1'b1;
				frame_pending <= 1'b0;
			end
		end

		if (sample_ce) begin
			if (flush_hold) begin
				pixel_x          <= hold_q.x;
				pixel_y          <= hold_q.y;
				pixel_z          <= hold_z;
				pixel_dwell_dose <= hold_q.is_dwell ? dwell_dose : 14'd0;
				pixel_valid      <= 1'b1;
				// During recurring fallback, overlapping pixels keep the higher energy.
				// Use addition for the final pixel before the first fallback marker.
				// A Timer 2 reload with a programmed period of at least 300 ticks
				// restores addition immediately.
				pixel_replace <= (eof_state == EOF_FALLBACK_RUNNING) && !reload_qualified;
			end

			if (frame_request) begin
				hold_q.valid        <=  1'b0;
				hold_q.is_dwell     <=  1'b0;
				hold_q.suppress     <=  1'b0;
				hold_q.dwell_energy <= 19'd0;
				hold_q.dwell_z_dose <= 17'd0;
				frame_pending       <=  1'b1;
			end
			else begin
				if (!beam_visible) begin
					hold_q.valid        <=  1'b0;
					hold_q.is_dwell     <=  1'b0;
					hold_q.suppress     <=  1'b0;
					hold_q.dwell_energy <= 19'd0;
					hold_q.dwell_z_dose <= 17'd0;
				end
				else if (!hold_q.valid) begin
					hold_q.x            <= raster_x;
					hold_q.y            <= raster_y;
					hold_q.valid        <= 1'b1;
					hold_q.is_dwell     <= 1'b0;
					hold_q.suppress     <= 1'b0;
					hold_q.line_z       <= line_z;
					hold_q.moving_z     <= moving_z;
					hold_q.dwell_energy <= 19'(line_z);
					hold_q.dwell_z_dose <= 17'(dwell_dose_step);
				end
				else if (source_moved_q) begin
					if (hold_q.is_dwell || !same_raster || hold_q.line_z == 12'd0) begin
						hold_q.x <= raster_x;
						hold_q.y <= raster_y;
						// After a dwell, omit the first line pixel if it maps to
						// the same framebuffer pixel as the dwell just sent.
						hold_q.suppress <= flush_hold && hold_q.is_dwell && same_raster;
						hold_q.line_z   <= line_z;
						hold_q.moving_z <= moving_z;
					end
					hold_q.is_dwell     <= 1'b0;
					hold_q.dwell_energy <= 19'(line_z);
					hold_q.dwell_z_dose <= 17'(dwell_dose_step);
				end
				else begin
					hold_q.is_dwell     <= 1'b1;
					hold_q.dwell_z_dose <= {hold_q.dwell_z_dose[16] | dwell_z_sum[16],
					                        dwell_z_sum[15:0]};
					if (dwell_energy_sum[19])
						hold_q.dwell_energy <= DWELL_ENERGY_MAX;
					else
						hold_q.dwell_energy <= dwell_energy_sum[18:0];
				end
			end
		end
	end
end

endmodule

`default_nettype wire
