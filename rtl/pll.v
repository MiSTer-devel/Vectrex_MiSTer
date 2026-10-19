// 24 MHz machine clock derived from the 50 MHz board reference.
`timescale 1ns/10ps

module pll
(
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0("24.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.pll_type("General"),
		.pll_subtype("General")
	) pll_inst (
		.rst(rst),
		.outclk(outclk_0),
		.locked(locked),
		.fboutclk(),
		.fbclk(1'b0),
		.refclk(refclk)
	);

endmodule
