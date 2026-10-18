// Continuous, centered dwell footprints.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

package vfb_dwell_pkg;
import vfb_control_pkg::*;

localparam logic [18:0] DWELL_SIZE_ONE = 19'd65536;
localparam logic [18:0] DWELL_SIZE_MAX = 19'd327680;
localparam logic [13:0] DWELL_HIGH_DOSE = 14'd4824;

// Horner coefficients use signed Q6.18; sizes use unsigned Q3.16.
typedef struct packed {
	logic signed [23:0] a, b, c, d;
	logic        [18:0] lower, upper;
	logic        [20:0] reciprocal;
	logic        [15:0] origin;
} dwell_curve_t;

// Origins and widths use four times the packed dose. The first interval starts
// at 4019 for 1080-line output and zero for other resolutions.
function automatic logic [15:0] dwell_origin(input logic [1:0] resolution, segment);
	case (segment)
		2'd0: dwell_origin = (resolution == GEOMETRY_1080) ? 16'd4019 : 16'd0;
		2'd1: dwell_origin = 16'd7705;
		2'd2: dwell_origin = 16'd19296;
		2'd3: dwell_origin = 16'd28512;
	endcase
endfunction

function automatic logic [13:0] dwell_width(input logic [1:0] resolution, segment);
	case (segment)
		2'd0:    dwell_width = (resolution == GEOMETRY_1080) ? 14'd3686 : 14'd7705;
		2'd1:    dwell_width = 14'd11591;
		default: dwell_width =  14'd9216;
	endcase
endfunction

// round(2^32 / interval width), selected only from constant intervals.
function automatic logic [20:0] dwell_reciprocal(input logic [1:0] resolution, segment);
	case (segment)
		2'd0:    dwell_reciprocal = (resolution == GEOMETRY_1080) ?
		                            21'(((64'd1 << 32) + 1843) / 3686) :
		                            21'(((64'd1 << 32) + 3852) / 7705);
		2'd1:    dwell_reciprocal = 21'(((64'd1 << 32) + 5795) / 11591);
		default: dwell_reciprocal = 21'(((64'd1 << 32) + 4608) / 9216);
	endcase
endfunction

// Ratio of endpoint excess size to bullet excess size, unsigned Q1.24.
function automatic logic [24:0] dwell_tail_ratio(input logic [1:0] resolution);
	case (resolution)
		GEOMETRY_240:  dwell_tail_ratio = 25'(((64'd42 << 24) + 14) / 29);
		GEOMETRY_480:  dwell_tail_ratio = 25'(((64'd35 << 24) + 16) / 32);
		GEOMETRY_720:  dwell_tail_ratio = 25'(((64'd117 << 24) + 38) / 77);
		GEOMETRY_1080: dwell_tail_ratio = 25'(((64'd400 << 24) + 175) / 351);
	endcase
endfunction

function automatic logic [10:0] dwell_pack(input logic [11:0] intensity);
	logic [12:0] rounded;
	begin
		rounded = {1'b0, intensity} + 13'd1;
		dwell_pack = rounded[12] ? 11'h7ff : rounded[11:1];
	end
endfunction

// Prepare the weight numerator and its optional division by three together.
// The rasterizer registers preparation, division and the final Q0.16 clamp.
typedef struct packed {
	logic        divide_three;
	logic [19:0] numerator;
} dwell_weight_input_t;

// T is size squared in Q5.12. Five symmetric groups fill outwards;
// their weighted multiplicities sum to T, including the unit primary.
function automatic dwell_weight_input_t dwell_weight_input(input logic [16:0] area, input logic [2:0] group_index);
	dwell_weight_input_t value;
	logic [16:0]         excess;
	begin
		// Whole-area thresholds omit fractional bits. At each inclusive lower
		// bound the subtraction is zero, preserving the zero-clamped result.
		excess             = (area[16:12] >= 5'd1) ? area - 17'd4096 : 17'd0;
		value.divide_three = (group_index == 3'd0) ||
		                     ((group_index == 3'd1) && (area[16:12] < 5'd7));
		case (group_index)
			3'd0:    value.numerator = (20'(excess) << 3) + 20'd1;
			3'd1:    value.numerator = (area[16:12] < 5'd7) ? (20'(excess) << 2) + 20'd1
			                                                : (20'(area) - 20'd20480) << 2;
			3'd2:    value.numerator = (area[16:12] >= 5'd9) ? (20'(area) - 20'd36864) << 1 : 20'd0;
			3'd3:    value.numerator = (area[16:12] < 5'd17) ?
			                           ((area[16:12] >= 5'd9) ? 20'(area) - 20'd36864 : 20'd0) :
			                           (20'(area) - 20'd53248) << 1;
			default: value.numerator = (area[16:12] >= 5'd21) ? (20'(area) - 20'd86016) << 2 : 20'd0;
		endcase
		dwell_weight_input = value;
	end
endfunction

// {dx,dy}, each signed three bits. Members are written in reflected pairs.
function automatic logic [5:0] dwell_offset(input logic [2:0] group_index, member_index);
	logic signed [2:0] dx, dy, radius;
	begin
		radius = (group_index < 3'd2) ? 3'sd1 : 3'sd2;
		dx     = 3'sd0;
		dy     = 3'sd0;
		case (group_index)
			3'd0, 3'd2: begin
				if (!member_index[1]) dx = member_index[0] ? radius : -radius;
				else dy = member_index[0] ? radius : -radius;
			end
			3'd1, 3'd4: begin
				dx = member_index[0] ? radius : -radius;
				dy = member_index[1] ? radius : -radius;
			end
			3'd3:       begin
				dx = member_index[0] ? (member_index[2] ? 3'sd1 : 3'sd2)
				                     : (member_index[2] ? -3'sd1 : -3'sd2);
				dy = member_index[1] ? (member_index[2] ? 3'sd2 : 3'sd1)
				                     : (member_index[2] ? -3'sd2 : -3'sd1);
			end
			default:    begin end
		endcase
		dwell_offset = {dx, dy};
	end
endfunction

endpackage

`default_nettype wire
