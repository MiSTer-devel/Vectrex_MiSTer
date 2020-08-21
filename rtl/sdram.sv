//
// sdram
// Copyright (c) 2015-2019 Sorgelig
// 
// Simplified version, for circular frame reading, without refresh.
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. 
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

module sdram
(
	input             init,        // reset to initialize RAM
	input             clk,         // clock ~100MHz

	inout  reg [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
	output            SDRAM_DQML,  // two byte masks
	output            SDRAM_DQMH,  // 
	output reg  [1:0] SDRAM_BA,    // two banks
	output            SDRAM_nCS,   // a single chip select
	output            SDRAM_nWE,   // write enable
	output            SDRAM_nRAS,  // row address select
	output            SDRAM_nCAS,  // columns address select
	output            SDRAM_CKE,   // clock enable
	output            SDRAM_CLK,   // clock for chip

	input      [24:1] ch1_addr,    // 25 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
	output reg [31:0] ch1_dout,    // data output to cpu
	input      [15:0] ch1_din,     // data input from cpu
	input             ch1_req,     // request
	input             ch1_rnw      // 1 - read, 0 - write
);

assign SDRAM_nCS  = 0;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];


// Burst length = 4
localparam BURST_LENGTH        = 2;
localparam BURST_CODE          = (BURST_LENGTH == 8) ? 3'b011 : (BURST_LENGTH == 4) ? 3'b010 : (BURST_LENGTH == 2) ? 3'b001 : 3'b000;  // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd2;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_CODE};

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
wire [2:0] CMD_NOP             = 3'b111;
wire [2:0] CMD_ACTIVE          = 3'b011;
wire [2:0] CMD_READ            = 3'b101;
wire [2:0] CMD_WRITE           = 3'b100;
wire [2:0] CMD_PRECHARGE       = 3'b010;
wire [2:0] CMD_AUTO_REFRESH    = 3'b001;
wire [2:0] CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command;

localparam STATE_STARTUP = 0;
localparam STATE_WAIT    = 1;
localparam STATE_RW1     = 2;
localparam STATE_IDLE    = 3;


always @(posedge clk) begin
	reg [CAS_LATENCY+BURST_LENGTH:0] data_ready_delay;

	reg        saved_wr;
	reg [12:0] cas_addr;
	reg [31:0] saved_data;
	reg [15:0] dq_reg;
	reg  [3:0] state = STATE_STARTUP;
	reg        ch1_rq;

	refresh_count <= refresh_count+1'b1;

	ch1_rq <= ch1_req;
	data_ready_delay <= data_ready_delay>>1;

	dq_reg <= SDRAM_DQ;

	if(data_ready_delay[1]) ch1_dout[15:00] <= dq_reg;
	if(data_ready_delay[0]) ch1_dout[31:16] <= dq_reg;

	SDRAM_DQ <= 16'bZ;

	command <= CMD_NOP;
	case (state)
		STATE_STARTUP: begin
			SDRAM_A    <= 0;
			SDRAM_BA   <= 0;

			// All the commands during the startup are NOPS, except these
			if (refresh_count == startup_refresh_max-31) begin
				// ensure all rows are closed
				command     <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1;  // all banks
				SDRAM_BA    <= 2'b00;
			end
			if (refresh_count == startup_refresh_max-23) begin
				// these refreshes need to be at least tREF (66ns) apart
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-15) begin
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-7) begin
				// Now load the mode register
				command     <= CMD_LOAD_MODE;
				SDRAM_A     <= MODE;
			end

			if (!refresh_count) begin
				state   <= STATE_IDLE;
				refresh_count <= 0;
			end
		end

		STATE_IDLE: begin
			if(~ch1_rq & ch1_req) begin
				{cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 2'b10, ch1_addr[24:1]};
				saved_data <= ch1_din;
				saved_wr   <= ~ch1_rnw;
				command    <= CMD_ACTIVE;
				state      <= STATE_WAIT;
			end
		end

		STATE_WAIT: state <= STATE_RW1;
		STATE_RW1: begin
			SDRAM_A <= cas_addr;
			if(saved_wr) begin
				command  <= CMD_WRITE;
				SDRAM_DQ <= saved_data[15:0];
				state <= STATE_IDLE;
			end
			else begin
				command <= CMD_READ;
				state   <= STATE_IDLE;
				data_ready_delay[CAS_LATENCY+BURST_LENGTH] <= 1;
			end
		end
	endcase

	if (init) begin
		state <= STATE_STARTUP;
		refresh_count <= startup_refresh_max - sdram_startup_cycles;
	end
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
