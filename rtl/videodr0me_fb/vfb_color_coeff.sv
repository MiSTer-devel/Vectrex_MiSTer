// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// Precompute beam color mapping and ambient light for one artwork palette entry.
// Linear light uses 16 fractional bits; optical depth = -log2(transmission)
// uses 12. Normalize in log space before converting back to linear light,
// so dark filters do not round entirely to zero.
`default_nettype none

module vfb_color_coeff (
	input wire  clk_sys, reset, start,
	input wire  [31:0] rgba,
	input wire  [2:0] color, tint,
	input wire  boost,
	input wire  [6:0] translucent_weight, opaque_weight,
	output logic done,
	output vfb_color_pkg::color_coeff_t coeff
);
import vfb_color_pkg::*;
localparam logic [18:0] DARK = 19'h7ffff;

// ROM widths match the hex files; read casts remove unused upper zero bits.
(* ramstyle = "M10K" *) logic [35:0] decode_rom [0:255];
(* ramstyle = "M10K" *) logic [19:0] density_rom [0:255];
(* ramstyle = "M10K" *) logic [11:0] log_rom [0:4095];
(* ramstyle = "M10K" *) logic [19:0] exp_rom [0:4095];
initial begin
	$readmemh("rtl/videodr0me_fb/vfb_color_decode.hex", decode_rom);
	$readmemh("rtl/videodr0me_fb/vfb_color_density.hex", density_rom);
	$readmemh("rtl/videodr0me_fb/vfb_color_log.hex", log_rom);
	$readmemh("rtl/videodr0me_fb/vfb_color_exp.hex", exp_rom);
end

typedef enum logic [5:0] {
	IDLE, PREPARE, ALPHA_WEIGHT, AMBIENT, AMBIENT_READ, AMBIENT_TAKE,
	READ_COLOR, MULTIPLY, TRANSMIT,
	LOG_NORMALIZE, LOG_READ, LOG_TAKE, NEXT_COLOR, PEAK,
	EXP_READ, EXP_SHIFT, EXP_TAKE, LUMA_MULTIPLY, LUMA_SUM, LUMA_TAKE,
	DENSITY_FACTOR, DENSITY_SUBTRACT, DENSITY_MULTIPLY, DENSITY_TAKE,
	RETAIN_READ, RETAIN_SHIFT, RETAIN_TAKE,
	RETAIN_MULTIPLY, RETAIN_DIVIDE, RETAIN_RESULT, RETAIN_GAIN_MULTIPLY, RETAIN_GAIN_SUM,
	SLOPE_DIVIDE, SLOPE_RESULT, DIVIDE, FINISH
} state_t;
state_t           state = IDLE, return_state;
beam_color_t      beam;
logic [2:0][7:0]  rgb, ambient_rgb;
logic [7:0]       alpha;
logic [2:0]       tint_q;
logic             boost_q;
logic [6:0]       tint_n;
logic             nominal;
logic [18:0]      density, nominal_density;
logic [32:0]      decoded;
logic [1:0]       channel;
logic [2:0][18:0] depth;
logic [18:0]      peak_depth;
logic [2:0][16:0] normalized;
logic [16:0]      tau, luma, peak_light;
logic [34:0]      depth_product;
logic [35:0]      light_product;
logic [42:0]      density_product;
logic [24:0]      density_factor;
logic [33:0]      retention_product;
logic [2:0][32:0] luma_product;
logic [34:0]      luma_sum;
logic [14:0]      alpha_product;
logic [6:0]       ambient_weight;
logic [11:0]      log_address, log_value;
logic [16:0]      log_base, exp_value;
logic [18:0]      exp_depth;
logic [17:0]      exp_shifted;
logic             exp_dark;
logic             high_slope;

// Separate the retention clamp, gain multiply and gain sum for timing.
(* dont_retime *) logic [16:0] retained_q;
(* dont_retime *) logic [18:0] gain_product_q;

// Shared unsigned divider for the compensation gain and RGB slopes.
logic [33:0] numerator, quotient;
logic [16:0] denominator;
logic [17:0] remainder;
logic [5:0]  divide_count;
wire  [17:0] trial      = {remainder[16:0], numerator[33]};
wire  [18:0] difference = {1'b0, trial} - {2'b0, denominator};
wire         divide_bit = !difference[18];

function automatic [4:0] leading_bit(input logic [16:0] value);
	begin
		leading_bit = 5'd0;
		for (int i = 0; i < 17; i++) if (value[i]) leading_bit = 5'(i);
	end
endfunction

always_ff @(posedge clk_sys) begin
	done <= 1'b0;
	case (state)
		IDLE: if (start) begin
			rgb     <= {rgba[7:0], rgba[15:8], rgba[23:16]};
			alpha   <= rgba[31:24];
			beam    <= overlay_beam(color);
			tint_q  <= tint;
			boost_q <= boost;
			// Menu codes 0..7 display 0,+1,+2,+3,+4,+5,+6,-1.
			// Only -1 and 0 reduce optical density; +1..+6 use nominal density.
			case (tint)
				3'd0:    tint_n <=  7'd4;
				3'd7:    tint_n <= 7'd16;
				default: tint_n <=  7'd0;
			endcase
			density        <= 19'(density_rom[rgba[31:24]]);
			ambient_weight <= (&rgba[31:24]) ? opaque_weight : translucent_weight;
			coeff          <= '0;
			state          <= PREPARE;
		end
		PREPARE: begin
			alpha_product   <= alpha * ambient_weight;
			nominal_density <= density;
			nominal         <= |tint_n;
			channel         <= 2'd0;
			peak_depth      <= DARK;
			state           <= ALPHA_WEIGHT;
		end
		ALPHA_WEIGHT: begin
			logic [14:0] rounded;
			// Apply alpha: round(alpha * ambient_weight / 255), with weight 64 = 100%.
			rounded = alpha_product + 15'd128;
			ambient_weight <= 7'((rounded + (rounded >> 8)) >> 8);
			state          <= AMBIENT;
		end
		AMBIENT: begin
			for (int c = 0; c < 3; c++)
				ambient_rgb[c] <= 8'((15'(rgb[c]) * 15'(ambient_weight) + 15'd32) >> 6);
			// For transmission only, replace RGB (0,0,0) with (1,1,1) when alpha
			// is below 255. Ambient artwork retains the original black.
			if (rgb == 24'd0 && alpha != 8'hff) rgb <= 24'h010101;
			coeff.knee <= COLOR_ONE;
			state      <= AMBIENT_READ;
		end
		AMBIENT_READ, READ_COLOR: begin
			// Use the same sRGB decode ROM for ambient artwork and beam filtering.
			decoded <= 33'(decode_rom[(state == AMBIENT_READ) ? ambient_rgb[channel] : rgb[channel]]);
			state <= (state == AMBIENT_READ) ? AMBIENT_TAKE : MULTIPLY;
		end
		AMBIENT_TAKE: begin
			coeff.ambient[channel] <= decoded[16:0];
			channel                <= (channel == 2'd2) ? 2'd0 : channel + 1'b1;
			state <= (channel == 2'd2) ? ((&alpha) ? FINISH : READ_COLOR) : AMBIENT_READ;
		end
		MULTIPLY: begin
			depth_product <= decoded[32:17] * density;
			light_product <= decoded[16:0] * density;
			state         <= TRANSMIT;
		end
		TRANSMIT: begin
			if (density >= 19'd65536) begin
				depth[channel] <= (rgb[channel] == 0) ?
				                  DARK :
				                  19'((depth_product + 35'd32768) >> 16) +
				                  {3'd0, beam.depth[channel]};
				state          <= NEXT_COLOR;
			end else begin
				tau   <= COLOR_ONE - density[16:0] + 17'((light_product + 36'd32768) >> 16);
				state <= LOG_NORMALIZE;
			end
		end
		LOG_NORMALIZE: begin
			logic [4:0]  msb;
			logic [28:0] mantissa;
			msb      = leading_bit(tau);
			mantissa = ({12'd0, tau} << 12) >> msb;
			log_address <= mantissa[11:0];
			log_base    <= (17'd16 - {12'd0, msb}) << 12;
			state       <= LOG_READ;
		end
		LOG_READ: begin
			log_value <= log_rom[log_address];
			log_base  <= log_base + 17'(beam.depth[channel]);
			state     <= LOG_TAKE;
		end
		LOG_TAKE: begin
			depth[channel] <= (tau == 0) ? DARK : {2'd0, log_base} - {7'd0, log_value};
			state          <= NEXT_COLOR;
		end
		NEXT_COLOR: begin
			peak_depth <= depth[channel] < peak_depth ? depth[channel] : peak_depth;
			channel    <= channel + 1'b1;
			state      <= (channel == 2'd2) ? PEAK : READ_COLOR;
		end
		PEAK: begin
			channel   <= 2'd0;
			exp_depth <= depth[0] - peak_depth;
			if (peak_depth == DARK && nominal) begin
				luma  <= 17'd0;
				state <= DENSITY_FACTOR;
			end else state <= (peak_depth == DARK) ? FINISH : EXP_READ;
		end
		EXP_READ: begin
			exp_value <= 17'(exp_rom[exp_depth[11:0]]);
			exp_dark  <= depth[channel] == DARK;
			state     <= EXP_SHIFT;
		end
		EXP_SHIFT, RETAIN_SHIFT: begin
			// Retain one extra bit for rounding in EXP_TAKE or RETAIN_TAKE.
			exp_shifted <= {exp_value, 1'b0} >> exp_depth[18:12];
			state       <= (state == EXP_SHIFT) ? EXP_TAKE : RETAIN_TAKE;
		end
		EXP_TAKE: begin
			normalized[channel] <= exp_dark ? 17'd0 : exp_shifted[17:1] + 17'(exp_shifted[0]);
			channel             <= channel + 1'b1;
			if (channel != 2'd2) exp_depth <= depth[channel + 1'b1] - peak_depth;
			state <= (channel == 2'd2) ? LUMA_MULTIPLY : EXP_READ;
		end
		LUMA_MULTIPLY: begin
			// Rec.709 rounded to Q16; coefficients sum to exactly one.
			luma_product[2] <= normalized[2] * 16'd13933;
			luma_product[1] <= normalized[1] * 16'd46871;
			luma_product[0] <= normalized[0] * 16'd4732;
			state           <= LUMA_SUM;
		end
		LUMA_SUM: begin
			luma_sum <= {2'd0,luma_product[2]} + {2'd0,luma_product[1]} + {2'd0,luma_product[0]} +
			            35'd32768;
			state    <= LUMA_TAKE;
		end
		LUMA_TAKE: begin
			luma <= luma_sum[32:16];
			// Measure luminance after scaling the strongest filtered channel to 1.
			// Use it for tint adjustment, compensation and the normal spill start.
			// Boost uses BOOST_KNEE for colored light. Equal RGB stays white,
			// so its spill start remains 1.
			coeff.knee <= boost_q && normalized != {3{COLOR_ONE}} ? BOOST_KNEE : luma_sum[32:16];
			state      <= nominal ? DENSITY_FACTOR : RETAIN_READ;
		end
		DENSITY_FACTOR: begin
			density_factor <= (18'(COLOR_ONE) + 18'(luma)) * tint_n;
			state          <= DENSITY_SUBTRACT;
		end
		DENSITY_SUBTRACT: begin
			density_factor <= 25'd16777216 - density_factor;
			state          <= DENSITY_MULTIPLY;
		end
		DENSITY_MULTIPLY: begin
			// d = (A/51) * (1 - (1+L)*n/256), where A is the 8-bit artwork alpha.
			// L is beam luminance (0..1) after filtering at density A/51 and scaling
			// the strongest RGB channel to 1.
			// n=16 at Tint -1, n=4 at Tint 0; +1..+6 keep d = A/51.
			density_product <= nominal_density * density_factor;
			state           <= DENSITY_TAKE;
		end
		DENSITY_TAKE: begin
			density    <= 19'((density_product + 43'd8388608) >> 24);
			nominal    <= 1'b0;
			channel    <= 2'd0;
			peak_depth <= DARK;
			state      <= READ_COLOR;
		end
		RETAIN_READ: begin
			exp_value  <= 17'(exp_rom[peak_depth[11:0]]);
			exp_depth  <= peak_depth;
			channel    <= 2'd0;
			high_slope <= 1'b0;
			coeff.gain <= COLOR_ONE;
			state      <= (tint_q >= 3'd2 && tint_q <= 3'd6) ? RETAIN_SHIFT : SLOPE_DIVIDE;
		end
		RETAIN_TAKE: begin
			peak_light <= exp_shifted[17:1] + 17'(exp_shifted[0]);
			state      <= RETAIN_MULTIPLY;
		end
		RETAIN_MULTIPLY: begin
			retention_product <= peak_light * luma;
			state             <= RETAIN_DIVIDE;
		end
		RETAIN_DIVIDE: begin
			numerator    <= retention_product + 34'(beam.luminance >> 1);
			denominator  <= beam.luminance;
			quotient     <=    '0;
			remainder    <=    '0;
			divide_count <= 6'd33;
			return_state <= RETAIN_RESULT;
			state        <= DIVIDE;
		end
		// r is filtered/unfiltered beam luminance, clamped to 1.
		// Gain = c + (1-c)*r. Tint +2..+6 restore 75%, 62.5%, 50%,
		// 37.5%, 25% of filter losses; -1, 0 and +1 restore all losses.
		RETAIN_RESULT: begin
			retained_q <= quotient > 34'd65536 ? COLOR_ONE : quotient[16:0];
			state      <= RETAIN_GAIN_MULTIPLY;
		end
		RETAIN_GAIN_MULTIPLY: begin
			gain_product_q <= retained_q * tint_q;
			state          <= RETAIN_GAIN_SUM;
		end
		RETAIN_GAIN_SUM: begin
			// k=tint_q: round(((8-k)*65536 + k*r)/8). Pack the constant and bias.
			coeff.gain <= 17'(({(4'd8 - {1'b0, tint_q}), 16'd4} +
			                    {1'b0, gain_product_q}) >> 3);
			state      <= SLOPE_DIVIDE;
		end
		SLOPE_DIVIDE: begin
			logic [16:0] den, value;
			den   = high_slope ? COLOR_ONE-coeff.knee : coeff.knee;
			value = high_slope ? COLOR_ONE-normalized[channel] : normalized[channel];
			numerator    <= {1'b0,value,16'd0} + 34'(den >> 1);
			denominator  <= den;
			quotient     <=    '0;
			remainder    <=    '0;
			divide_count <= 6'd33;
			return_state <= SLOPE_RESULT;
			state <= (high_slope ? coeff.knee == COLOR_ONE : coeff.knee == 0)
				? SLOPE_RESULT : DIVIDE;
		end
		DIVIDE: begin
			numerator    <= {numerator[32:0],1'b0};
			quotient     <= {quotient[32:0],divide_bit};
			remainder    <= divide_bit ? difference[17:0] : trial;
			divide_count <= divide_count - 1'b1;
			if (divide_count == 0) state <= return_state;
		end
		SLOPE_RESULT: begin
			if (high_slope) coeff.high[channel] <= quotient[20:0];
			else coeff.low[channel] <= quotient[20:0];
			high_slope <= !high_slope;
			if (high_slope) channel <= channel + 1'b1;
			state <= (high_slope && channel == 2'd2) ? FINISH : SLOPE_DIVIDE;
		end
		FINISH: begin
			done  <= 1'b1;
			state <= IDLE;
		end
		default: state <= IDLE;
	endcase
	// Reset cancels the calculation; the next start clears coeff and reloads the inputs.
	if (reset) begin
		state <= IDLE;
		done  <= 1'b0;
	end
end
endmodule

`default_nettype wire
