// Build four monotone Hermite intervals when the dwell controls change.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

module vfb_dwell_config (
	input wire  clk_sys,
	input wire  reset,
	input wire  [10:0] settings,
	input wire  [1:0] segment,
	output vfb_dwell_pkg::dwell_curve_t curve,
	output logic expansion_enabled,
	output logic [15:0] onset
);
import vfb_dwell_pkg::*;

// MLAB ROMs store the low, middle and high dwell sizes.
// Addresses: low={resolution,low}; mid={resolution,low,mid}; high={resolution,low,mid,high}.
// Five hexadecimal digits occupy 20 bits; Q3.16 uses the lower 19 bits.
(* ramstyle = "MLAB" *) logic [19:0] low_rom [0:31];
(* ramstyle = "MLAB" *) logic [19:0] mid_rom [0:255];
(* ramstyle = "MLAB" *) logic [19:0] high_rom [0:2047];
initial begin
	$readmemh("rtl/videodr0me_fb/dwell_anchor_low.hex", low_rom);
	$readmemh("rtl/videodr0me_fb/dwell_anchor_mid.hex", mid_rom);
	$readmemh("rtl/videodr0me_fb/dwell_anchor_high.hex", high_rom);
end
logic [10:0] settings_q;
logic [18:0] low_q, mid_q, high_q;
always_ff @(posedge clk_sys) begin
	low_q  <= low_rom[settings_q[10:6]][18:0];
	mid_q  <= mid_rom[settings_q[10:3]][18:0];
	high_q <= high_rom[settings_q][18:0];
end

dwell_curve_t intervals [4];
// Store whether each interval's upper size exceeds one pixel.
// The rasterizer selects this bit instead of repeating the size comparison.
logic  [3:0] interval_expands;
assign       curve             = intervals[segment];
assign       expansion_enabled = interval_expands[segment];
// Four interval starts share the segment index; the final endpoint is separate.
logic [18:0] sizes [4];
logic [18:0] size_tail_q;
(* ramstyle = "logic" *) logic [23:0] slopes [4]; // unsigned Q0.32
(* ramstyle = "logic" *) logic [23:0] tangents [4];
logic [1:0]  index_q;
wire  [1:0]  next_index   = index_q + 2'd1;
wire  [18:0] size_next    = (index_q == 2'd3) ? size_tail_q : sizes[next_index];
wire  [23:0] tangent_next = (index_q == 2'd3) ? 24'd0 : tangents[next_index];
logic        initialized_q;
logic [18:0] size_delta_q;
logic [24:0] tail_ratio_q;
logic [43:0] tail_product_q;
logic [20:0] tail_size_q;
logic [20:0] reciprocal_q;
logic [39:0] slope_product_q;
logic [23:0] derivative_left_q, derivative_right_q;
logic [15:0] weight_left_q, weight_right_q;
logic [16:0] weight_sum_q;
logic        tangent_zero_q;
logic [47:0] tangent_product_q;
logic [40:0] tangent_weighted_low_q, tangent_weighted_high_q;
logic [39:0] tangent_left_q, tangent_right_q;
logic [63:0] tangent_numerator_q;
logic [39:0] tangent_denominator_q;
wire  [13:0] width_left   = dwell_width(settings_q[10:9], index_q - 2'd1);
wire  [13:0] width_right  = dwell_width(settings_q[10:9], index_q);
wire  [15:0] weight_left  = 16'(width_right) * 16'd2 + 16'(width_left);
wire  [15:0] weight_right = 16'(width_right) + 16'(width_left) * 16'd2;
wire  [16:0] weight_sum   = 17'(weight_left) + 17'(weight_right);

// A restoring divider is used only for the three weighted harmonic means.
// It has one bounded subtract per clock and no combinational variable divide.
logic [63:0] quotient_q;
logic [39:0] remainder_q, divisor_q;
logic [6:0]  divide_count_q;
wire  [40:0] trial         = {remainder_q, quotient_q[63]} - {1'b0, divisor_q};
wire  [63:0] quotient_next = {quotient_q[62:0], !trial[40]};

logic        [37:0] tangent_start_q, tangent_end_q;
logic signed [23:0] start_scaled_q, end_scaled_q, delta_q;
logic        [13:0] interval_width_q;

typedef enum logic [4:0] {
	CFG_IDLE, CFG_READ, CFG_LOAD, CFG_TAIL_MUL, CFG_TAIL_SCALE, CFG_TAIL_STORE,
	CFG_SLOPE_PREP, CFG_SLOPE_MUL, CFG_SLOPE_STORE,
	CFG_TANGENT_PREP, CFG_TANGENT_MUL, CFG_TANGENT_WEIGHT, CFG_TANGENT_SUM,
	CFG_DIVIDE_LOAD, CFG_DIVIDE,
	CFG_COEFF_PREP, CFG_COEFF_MUL, CFG_COEFF_SCALE, CFG_COEFF_STORE
} config_state_t;
config_state_t state;

always_ff @(posedge clk_sys) begin
	if (reset) begin
		state            <= CFG_IDLE;
		initialized_q    <=    1'b0;
		settings_q       <=   11'd0;
		onset            <=   16'd0;
		interval_expands <= 4'b0000;
		tangents[0]      <=   24'd0;
		sizes[0]         <= DWELL_SIZE_ONE;
		for (int i = 0; i < 4; i++) begin
			intervals[i] <= '{a:24'sd0, b:24'sd0, c:24'sd0, d:24'sd262144,
				lower:DWELL_SIZE_ONE, upper:DWELL_SIZE_ONE, reciprocal:21'd0, origin:16'd0};
		end
	end else begin
		case (state)
			CFG_IDLE:           if (!initialized_q || settings != settings_q) begin
				settings_q    <= settings;
				initialized_q <= 1'b1;
				state         <= CFG_READ;
			end
			CFG_READ:           state <= CFG_LOAD;
			CFG_LOAD:           begin
				sizes[1]     <= low_q;
				sizes[2]     <= mid_q;
				sizes[3]     <= high_q;
				size_delta_q <= high_q - DWELL_SIZE_ONE;
				tail_ratio_q <= dwell_tail_ratio(settings_q[10:9]);
				state        <= CFG_TAIL_MUL;
			end
			CFG_TAIL_MUL:       begin
				tail_product_q <= size_delta_q * tail_ratio_q;
				state          <= CFG_TAIL_SCALE;
			end
			CFG_TAIL_SCALE:     begin
				tail_size_q <= 21'd65536 + 21'((tail_product_q + 44'd8388608) >> 24);
				state       <= CFG_TAIL_STORE;
			end
			CFG_TAIL_STORE:     begin
				size_tail_q <= (tail_size_q >= 21'(DWELL_SIZE_MAX)) ? DWELL_SIZE_MAX :
				               (tail_size_q < 21'(sizes[3])) ? sizes[3] : tail_size_q[18:0];
				index_q     <= 2'd0;
				state       <= CFG_SLOPE_PREP;
			end
			CFG_SLOPE_PREP:     begin
				size_delta_q <= size_next - sizes[index_q];
				reciprocal_q <= dwell_reciprocal(settings_q[10:9], index_q);
				state        <= CFG_SLOPE_MUL;
			end
			CFG_SLOPE_MUL:      begin
				slope_product_q <= size_delta_q * reciprocal_q;
				state           <= CFG_SLOPE_STORE;
			end
			CFG_SLOPE_STORE:    begin
				slopes[index_q] <= 24'((slope_product_q + 40'd32768) >> 16);
				index_q         <= index_q + 2'd1;
				if (index_q == 2'd3) begin
					index_q <= 2'd1;
					state   <= CFG_TANGENT_PREP;
				end else state <= CFG_SLOPE_PREP;
			end
			CFG_TANGENT_PREP:   begin
				derivative_left_q  <= slopes[index_q - 2'd1];
				derivative_right_q <= slopes[index_q];
				weight_left_q      <= weight_left;
				weight_right_q     <= weight_right;
				weight_sum_q       <= weight_sum;
				state              <= CFG_TANGENT_MUL;
			end
			CFG_TANGENT_MUL:    begin
				tangent_product_q <= derivative_left_q * derivative_right_q;
				tangent_zero_q    <= (derivative_left_q == 24'd0) || (derivative_right_q == 24'd0);
				tangent_left_q    <= weight_left_q * derivative_right_q;
				tangent_right_q   <= weight_right_q * derivative_left_q;
				state             <= CFG_TANGENT_WEIGHT;
			end
			CFG_TANGENT_WEIGHT: begin
				// Register both 24-bit limbs before combining the weighted product.
				tangent_weighted_low_q  <= tangent_product_q[23:0] * weight_sum_q;
				tangent_weighted_high_q <= tangent_product_q[47:24] * weight_sum_q;
				state                   <= CFG_TANGENT_SUM;
			end
			CFG_TANGENT_SUM:    begin
				// Retain the unsigned product modulo 2^64 used by the divider.
				tangent_numerator_q   <= {tangent_weighted_high_q[39:0], 24'd0} +
				                         {23'd0, tangent_weighted_low_q};
				tangent_denominator_q <= tangent_left_q + tangent_right_q;
				state                 <= CFG_DIVIDE_LOAD;
			end
			CFG_DIVIDE_LOAD:    begin
				quotient_q     <= tangent_numerator_q + {25'd0, tangent_denominator_q[39:1]};
				divisor_q      <= tangent_denominator_q;
				remainder_q    <= 40'd0;
				divide_count_q <= 7'd64;
				state          <= CFG_DIVIDE;
			end
			CFG_DIVIDE:         begin
				quotient_q     <= quotient_next;
				remainder_q    <= trial[40] ? {remainder_q[38:0], quotient_q[63]} : trial[39:0];
				divide_count_q <= divide_count_q - 7'd1;
				if (divide_count_q == 7'd1) begin
					tangents[index_q] <= tangent_zero_q ? 24'd0 : quotient_next[23:0];
					index_q           <= index_q + 2'd1;
					state             <= (index_q == 2'd3) ? CFG_COEFF_PREP : CFG_TANGENT_PREP;
				end
			end
			CFG_COEFF_PREP:     begin
				interval_width_q   <= dwell_width(settings_q[10:9], index_q);
				derivative_left_q  <= tangents[index_q];
				derivative_right_q <= tangent_next;
				delta_q            <= 24'({size_next - sizes[index_q], 2'b00});
				state              <= CFG_COEFF_MUL;
			end
			CFG_COEFF_MUL:      begin
				tangent_start_q <= interval_width_q * derivative_left_q;
				tangent_end_q   <= interval_width_q * derivative_right_q;
				state           <= CFG_COEFF_SCALE;
			end
			CFG_COEFF_SCALE:    begin
				start_scaled_q <= 24'((tangent_start_q + 38'd8192) >> 14);
				end_scaled_q   <= 24'((tangent_end_q + 38'd8192) >> 14);
				state          <= CFG_COEFF_STORE;
			end
			CFG_COEFF_STORE:    begin
				intervals[index_q].a          <= -24'sd2 * delta_q + start_scaled_q + end_scaled_q;
				intervals[index_q].b          <= 24'sd3 * delta_q - 24'sd2 * start_scaled_q -
				                                 end_scaled_q;
				intervals[index_q].c          <= start_scaled_q;
				intervals[index_q].d          <= 24'({sizes[index_q], 2'b00});
				intervals[index_q].lower      <= sizes[index_q];
				intervals[index_q].upper      <= size_next;
				interval_expands[index_q]     <= (size_next > DWELL_SIZE_ONE);
				intervals[index_q].reciprocal <= dwell_reciprocal(settings_q[10:9], index_q);
				intervals[index_q].origin     <= dwell_origin(settings_q[10:9], index_q);
				onset                         <= dwell_origin(settings_q[10:9], 2'd0);
				index_q                       <= index_q + 2'd1;
				state                         <= (index_q == 2'd3) ? CFG_IDLE : CFG_COEFF_PREP;
			end
			default:            state <= CFG_IDLE;
		endcase
	end
end
endmodule

`default_nettype wire
