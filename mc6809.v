`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    08:11:34 09/23/2016 
// Design Name: 
// Module Name:    mc6809e 
// Project Name: 
// Target Devices: 
// Tool versions: 
// Description: 
//
// Dependencies: 
//
// Revision: 
// Revision 0.01  - File Created
// Revision 0.01s - Syncronous version (by Sorgelig)
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
module mc6809
(
    input          CLK,
    input          CLKEN,
    input          nRESET,
       
    output reg     E,
	 output reg     riseE,
	 output reg     fallE, // everything except interrupts/dma registered/latched here
       
    output reg     Q,
	 output reg     riseQ,
	 output reg     fallQ, // NMI,IRQ,FIRQ,DMA,HALT registered here

    input    [7:0] Din,
    output   [7:0] Dout,
    output  [15:0] ADDR,
    output         RnW,

    output         BS,
    output         BA,
    input          nIRQ,
    input          nFIRQ,
    input          nNMI,
    input          nHALT,	 
    input          MRDY,
    input          nDMA
);

mc6809is cpucore
(
	.CLK(CLK),
	.D(Din),
	.DOut(Dout),
	.ADDR(ADDR),
	.RnW(RnW),
	.fallE_en(fallE),
	.fallQ_en(fallQ),
	.BS(BS),
	.BA(BA),
	.nIRQ(nIRQ),
	.nFIRQ(nFIRQ),
	.nNMI(nNMI),
	.nHALT(nHALT),
	.nRESET(nRESET),
	.nDMABREQ(nDMA)
);

always @(posedge CLK)
begin
	reg [1:0] clk_phase =0;

	fallE <= 0;
	fallQ <= 0;
	riseE <= 0;
	riseQ <= 0;

	if (MRDY && CLKEN) begin
		clk_phase <= clk_phase + 1'd1;
		case (clk_phase)
			2'b00: begin E <= 0; fallE <= 1; end
			2'b01: begin Q <= 1; riseQ <= 1; end
			2'b10: begin E <= 1; riseE <= 1; end
			2'b11: begin Q <= 0; fallQ <= 1; end
		endcase
	end
end

endmodule

