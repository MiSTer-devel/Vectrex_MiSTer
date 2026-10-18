// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// Store RGBA palettes from the artwork file and precompute rendering
// coefficients for the selected plane. Rebuild when the plane or controls
// change; the caller must pause overlay readout while ready is low.
`default_nettype none

module vfb_palette (
	input wire        clk_sys, reset,
	input wire        write_enable,
	input wire [10:0] write_address,
	input wire [31:0] write_data,
	input wire        plane_valid,
	input wire [10:0] palette_offset,
	input wire [8:0]  palette_count,
	input wire [2:0]  color, tint,
	input wire        boost,
	input wire [6:0]  translucent_weight, opaque_weight,
	input wire        read_enable,
	input wire [7:0]  read_index,
	output vfb_color_pkg::color_coeff_t read_coeff,
	output logic                        ready
);
import vfb_color_pkg::*;
typedef struct packed {
	logic [10:0] offset;
	logic [8:0]  count;
	logic [2:0]  color, tint;
	logic        boost;
	logic [6:0]  translucent_weight, opaque_weight;
} config_t;
config_t requested, config_q;
assign   requested = {palette_offset, palette_count, color, tint, boost,
                      translucent_weight, opaque_weight};
wire     restart   = reset || !plane_valid || requested != config_q;

(* ramstyle = "M10K, no_rw_check" *) logic [31:0] raw_palette [0:2047];
(* ramstyle = "M10K, no_rw_check" *) color_coeff_t mapped_palette [0:255];
logic [7:0]   index;
logic [31:0]  rgba_q;
logic         calc_start, calc_done;
color_coeff_t calculated;
typedef enum logic [1:0] {READ, START, WAIT, COMPLETE} state_t;
state_t state;

always_ff @(posedge clk_sys) begin
	if (write_enable) raw_palette[write_address] <= write_data;
	rgba_q <= raw_palette[config_q.offset + {3'd0,index}];
	if (read_enable)           read_coeff            <= mapped_palette[read_index];
	if (calc_done && !restart) mapped_palette[index] <= calculated;
end

vfb_color_coeff builder (
	.clk_sys(clk_sys), .reset(restart), .start(calc_start), .rgba(rgba_q),
	.color(config_q.color), .tint(config_q.tint),
	.boost(config_q.boost),
	.translucent_weight(config_q.translucent_weight),
	.opaque_weight(config_q.opaque_weight), .done(calc_done), .coeff(calculated)
);

// restart cancels the builder and blocks mapped-palette writes; raw uploads are independent.
assign calc_start = state == START;
always_ff @(posedge clk_sys) begin
	if (restart) begin
		config_q <= requested;
		ready    <= 1'b0;
		index    <= 8'd0;
		state    <= READ;
	end else case (state)
		READ:     state <= START;
		START:    state <= WAIT;
		WAIT:     if (calc_done) begin
			if ({1'b0,index} + 9'd1 >= config_q.count) begin
				ready <= 1'b1;
				state <= COMPLETE;
			end else begin
				index <= index + 1'b1;
				state <= READ;
			end
		end
		COMPLETE: ;
		default:  state <= READ;
	endcase
end
endmodule

`default_nettype wire
