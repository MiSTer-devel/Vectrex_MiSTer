`timescale 1ns / 1ps

// Vectrex clock-phase wrapper for Greg Miller's synchronous MC6809 core.
// Four-phase enable wrapper by Sorgelig.
module mc6809
(
	input         CLK,
	input         CLKEN,
	input         nRESET,

	output reg    riseE,
	output reg    fallE, // Falling-E enable for CPU state and bus-cycle updates.

	output reg    riseQ,

	input   [7:0] Din,
	output  [7:0] Dout,
	output [15:0] ADDR,
	output        RnW,

	input         nIRQ,
	input         nFIRQ
);

reg fallQ;

mc6809is cpu_core
(
	.CLK(CLK),
	.D(Din),
	.DOut(Dout),
	.ADDR(ADDR),
	.RnW(RnW),
	.BS(),
	.BA(),
	.fallE_en(fallE),
	.fallQ_en(fallQ),
	.nIRQ(nIRQ),
	.nFIRQ(nFIRQ),
	.nNMI(1'b1),
	.nHALT(1'b1),
	.nRESET(nRESET),
	.nDMABREQ(1'b1),
	// AVMA predicts a future bus cycle; board accesses use the E/Q phase pulses.
	.AVMA(),
	.BUSY(),
	.LIC(),
	.RegData()
);

reg [1:0] clk_phase = 2'd0;
always @(posedge CLK)
begin
	fallE <= 0;
	fallQ <= 0;
	riseE <= 0;
	riseQ <= 0;

	if (CLKEN) begin
		clk_phase <= clk_phase + 1'd1;
		case (clk_phase)
			2'b00: fallE <= 1;
			2'b01: riseQ <= 1;
			2'b10: riseE <= 1;
			2'b11: fallQ <= 1;
		endcase
	end
end

endmodule
