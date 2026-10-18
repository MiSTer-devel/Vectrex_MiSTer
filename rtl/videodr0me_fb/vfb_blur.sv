// ============================================================================
// Local 5x5 bloom blur, retaining three fractional energy bits.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// ============================================================================

`default_nettype none

module vfb_blur (
	input  wire  clk_sys,
	input  wire  ce_pix,
	input  wire  reset,

	input  wire  [10:0] active_x_in,
	input  wire         hblank_in,
	input  wire         enable,
	input  wire  [17:0] energy_in,

	output logic [10:0] active_x_out,
	output logic        hblank_out,
	output logic [17:0] energy_out
);

localparam int BLUR_LATENCY = 7;

logic [10:0] active_x_d [1:BLUR_LATENCY+1];
logic        hblank_d [1:BLUR_LATENCY+1];
logic [17:0] energy_in_d [1:2];

always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		active_x_d[1]  <= active_x_in;
		hblank_d[1]    <= hblank_in;
		energy_in_d[1] <= energy_in;
		energy_in_d[2] <= energy_in_d[1];
		for (int i = 2; i <= BLUR_LATENCY+1; i++) begin
			active_x_d[i] <= active_x_d[i-1];
			hblank_d[i]   <= hblank_d[i-1];
		end
	end
end

// Four 1472-pixel energy line buffers.
(* ramstyle = "M10K, no_rw_check" *) logic [17:0] lb_0 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [17:0] lb_1 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [17:0] lb_2 [0:1471];
(* ramstyle = "M10K, no_rw_check" *) logic [17:0] lb_3 [0:1471];

logic        clearing;
logic [10:0] clear_addr;

always_ff @(posedge clk_sys) begin
	if (reset) begin
		clearing   <= 1'b1;
		clear_addr <= 11'd0;
	end else if (clearing && ce_pix) begin
		if (clear_addr < 11'd1471)
			clear_addr <= clear_addr + 11'd1;
		else
			clearing <= 1'b0;
	end
end

logic [17:0] lb_0_ram, lb_1_ram, lb_2_ram, lb_3_ram;
logic [17:0] lb_1_reg;
logic [20:0] v_outer_sum_q;
logic [19:0] v_inner_sum_q;
wire [17:0]  lb_0_out = hblank_d[2] ? 18'd0 : lb_0_ram;
wire [17:0]  lb_1_out = hblank_d[2] ? 18'd0 : lb_1_ram;
wire [17:0]  lb_2_out = hblank_d[2] ? 18'd0 : lb_2_ram;
wire [17:0]  lb_3_out = hblank_d[2] ? 18'd0 : lb_3_ram;

always_ff @(posedge clk_sys) begin
	if (ce_pix) begin
		lb_0_ram <= clearing ? 18'd0 : lb_0[active_x_d[1]];
		lb_1_ram <= clearing ? 18'd0 : lb_1[active_x_d[1]];
		lb_2_ram <= clearing ? 18'd0 : lb_2[active_x_d[1]];
		lb_3_ram <= clearing ? 18'd0 : lb_3[active_x_d[1]];

		if (!hblank_d[2] || clearing) begin
			lb_0[clearing ? clear_addr : active_x_d[2]] <= clearing ? 18'd0 : energy_in_d[2];
			lb_1[clearing ? clear_addr : active_x_d[2]] <= clearing ? 18'd0 : lb_0_out;
			lb_2[clearing ? clear_addr : active_x_d[2]] <= clearing ? 18'd0 : lb_1_out;
			lb_3[clearing ? clear_addr : active_x_d[2]] <= clearing ? 18'd0 : lb_2_out;
		end

		lb_1_reg <= lb_1_out;
		// Prepare both partial sums before the vertical output stage.
		// a+4b+6c+4d+e+8 = (a+e+2c+8) + 4*(b+c+d).
		v_outer_sum_q <= (21'(energy_in_d[2]) + 21'(lb_3_out)) + {2'd0, lb_1_out, 1'b0} + 21'd8;
		v_inner_sum_q <= 20'(lb_0_out) + 20'(lb_1_out) + 20'(lb_2_out);
	end
end

logic [17:0] v_blur;
logic [17:0] h_shift [0:3];
logic [20:0] h_outer_sum_q;
logic [19:0] h_inner_sum_q;

always_ff @(posedge clk_sys) begin
	if (ce_pix && !clearing) begin
		if (enable) begin
			v_blur <= 18'((22'(v_outer_sum_q) + {v_inner_sum_q, 2'b00}) >> 4);
		end else begin
			v_blur <= lb_1_reg;
		end

		h_shift[0] <= v_blur;
		h_shift[1] <= h_shift[0];
		h_shift[2] <= h_shift[1];
		h_shift[3] <= h_shift[2];

		// a+4b+6c+4d+e+8 = (a+e+2c+8) + 4*(b+c+d).
		// Split the rounded sum across two output stages.
		if (enable) begin
			h_outer_sum_q <= (21'(v_blur) + 21'(h_shift[3])) + {2'd0, h_shift[1], 1'b0} + 21'd8;
			h_inner_sum_q <= 20'(h_shift[0]) + 20'(h_shift[1]) + 20'(h_shift[2]);
		end else begin
			h_outer_sum_q <= 21'd0;
			h_inner_sum_q <= {h_shift[1], 2'b00};
		end

		energy_out <= 18'((22'(h_outer_sum_q) + {h_inner_sum_q, 2'b00}) >> 4);
	end
end

assign active_x_out = active_x_d[BLUR_LATENCY+1];
assign hblank_out   = hblank_d[BLUR_LATENCY+1];

endmodule

`default_nettype wire
