`timescale 1 ps / 1 ps
module pll_vfb (
		input  wire  refclk,
		input  wire  rst,
		output wire  outclk_0,   // 125 MHz
		output wire  locked
	);

	pll_vfb_core pll_vfb_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.locked   (locked)
	);

endmodule
