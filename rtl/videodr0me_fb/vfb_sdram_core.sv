// ============================================================================
// Open-row 32-bit to 16-bit SDR SDRAM controller.
//
// The command engine is derived from ultraembedded/core_sdram_axi4
// (Copyright 2015-2019 Ultra-Embedded.com, GPL-2.0-or-later).
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Open-row reads or writes can sustain one 32-bit request per two clocks.
// Turnarounds and refresh interrupt this rate. Banks keep rows open
// until a row miss or refresh requires precharge.
//
// Modified by Videodr0me:
// - Single request stream with full 32-bit writes and read responses.
// - 125 MHz/CAS 3 defaults, with mode-register selection for CAS 2 or 3.
// - Read-sampling and write-data pipelines for Cyclone V I/O timing.
// - Synchronous resets, local DQ output-enable reset and registered startup commands.
// - Parameter checks for address widths and timing-counter ranges.
// ============================================================================

`default_nettype none

module vfb_sdram_core #(
	parameter integer SDRAM_MHZ          = 125,
	parameter integer SDRAM_ADDR_W       = 24,
	parameter integer SDRAM_COL_W        = 9,
	parameter integer SDRAM_READ_LATENCY = 3
) (
	input  wire  clk_sys,
	input  wire  reset,

	input  wire         req_valid,
	input  wire         req_write,
	input  wire  [31:0] req_addr,
	input  wire  [31:0] req_wdata,
	output logic        req_ready,

	output logic        rsp_valid,
	output logic [31:0] rsp_rdata,
	output logic        init_done,

	input  wire  [15:0] sdram_data_in,
	output logic [15:0] sdram_data_out,
	output logic        sdram_data_oe,
	output logic        sdram_cke,
	output logic        sdram_cs,
	output logic        sdram_ras,
	output logic        sdram_cas,
	output logic        sdram_we,
	output logic [1:0]  sdram_dqm,
	output logic [12:0] sdram_addr,
	output logic [1:0]  sdram_ba
);

localparam integer BANK_W = 2;
localparam integer BANKS = 1 << BANK_W;
localparam integer ROW_W = SDRAM_ADDR_W - SDRAM_COL_W - BANK_W;
localparam integer REFRESH_ROWS = 1 << ROW_W;
localparam integer START_DELAY = SDRAM_MHZ * 100; // 100 us
localparam integer REFRESH_CYCLES =
	((64000 * SDRAM_MHZ) / REFRESH_ROWS) - 1;
localparam [16:0] START_TIMER_LOAD =
	17'(START_DELAY + 100);
localparam integer CYCLE_NS = 1000 / SDRAM_MHZ;
localparam integer TRCD_CYCLES = (20 + CYCLE_NS - 1) / CYCLE_NS;
localparam integer TRP_CYCLES  = (20 + CYCLE_NS - 1) / CYCLE_NS;
localparam integer TRFC_CYCLES = (60 + CYCLE_NS - 1) / CYCLE_NS;
localparam [2:0] CAS_CODE =
	(SDRAM_READ_LATENCY >= 3) ? 3'b011 : 3'b010;

initial begin
	if (SDRAM_READ_LATENCY != 2 && SDRAM_READ_LATENCY != 3)
		$error("vfb_sdram_core supports CAS latency 2 or 3");
	if (SDRAM_COL_W < 2 || SDRAM_COL_W > 10 || ROW_W < 1 || ROW_W > 13)
		$error("vfb_sdram_core address fields must fit the SDRAM pins");
	if (SDRAM_MHZ < 1 || SDRAM_MHZ > 1000 || TRFC_CYCLES > 15 ||
		START_DELAY + 100 >= (1 << 17) || REFRESH_CYCLES < 1 ||
		REFRESH_CYCLES >= (1 << 17))
		$error("vfb_sdram_core timing parameters exceed the counter ranges");
end

localparam [3:0] CMD_NOP       = 4'b0111;
localparam [3:0] CMD_ACTIVE    = 4'b0011;
localparam [3:0] CMD_READ      = 4'b0101;
localparam [3:0] CMD_WRITE     = 4'b0100;
localparam [3:0] CMD_PRECHARGE = 4'b0010;
localparam [3:0] CMD_REFRESH   = 4'b0001;
localparam [3:0] CMD_MODE      = 4'b0000;

// Sequential burst, burst length 2, programmed write burst enabled.
localparam [12:0] MODE_REG = {3'b000, 1'b0, 2'b00, CAS_CODE, 1'b0, 3'b001};

typedef enum logic [3:0] {
	ST_INIT,
	ST_DELAY,
	ST_IDLE,
	ST_ACTIVATE,
	ST_READ,
	ST_READ_WAIT,
	ST_WRITE0,
	ST_WRITE1,
	ST_PRECHARGE,
	ST_REFRESH
} state_t;

state_t state;
state_t next_state;
state_t target_state;
state_t next_target;
state_t delay_target;

logic [3:0]  delay_count;
logic [3:0]  next_delay;
logic        refresh_pending;
logic [16:0] refresh_timer;

logic [BANKS-1:0] row_open;
logic [ROW_W-1:0] active_row [0:BANKS-1];

wire [ROW_W-1:0] request_row =
	req_addr[SDRAM_ADDR_W:SDRAM_COL_W+3];
wire [BANK_W-1:0] request_bank =
	req_addr[SDRAM_COL_W+2:SDRAM_COL_W+1];
wire [SDRAM_COL_W-1:0] request_col =
	{req_addr[SDRAM_COL_W:2], 1'b0};
wire request_row_hit =
	row_open[request_bank] && active_row[request_bank] == request_row;

always_comb begin
	next_state  = state;
	next_target = target_state;

	case (state)
		ST_INIT:
			if (refresh_pending)
				next_state = ST_IDLE;

		ST_IDLE: begin
			if (refresh_pending) begin
				next_target = ST_REFRESH;
				next_state  = (|row_open) ? ST_PRECHARGE : ST_REFRESH;
			end else if (req_valid) begin
				next_target = req_write ? ST_WRITE0 : ST_READ;
				if (request_row_hit)
					next_state = req_write ? ST_WRITE0 : ST_READ;
				else if (row_open[request_bank])
					next_state = ST_PRECHARGE;
				else
					next_state = ST_ACTIVATE;
			end
		end

		ST_ACTIVATE:
			next_state = target_state;

		ST_READ:
			next_state = ST_READ_WAIT;

		ST_READ_WAIT: begin
			next_state = ST_IDLE;
			if (!refresh_pending && req_valid && !req_write && request_row_hit)
				next_state = ST_READ;
		end

		ST_WRITE0:
			next_state = ST_WRITE1;

		ST_WRITE1: begin
			next_state = ST_IDLE;
			if (!refresh_pending && req_valid && req_write && request_row_hit)
				next_state = ST_WRITE0;
		end

		ST_PRECHARGE:
			next_state = (target_state == ST_REFRESH) ? ST_REFRESH : ST_ACTIVATE;

		ST_REFRESH:
			next_state = ST_IDLE;

		ST_DELAY:
			next_state = delay_target;

		default:
			next_state = ST_INIT;
	endcase
end

always_comb begin
	next_delay = 4'd0;
	case (state)
		ST_ACTIVATE:  next_delay = TRCD_CYCLES[3:0];
		ST_PRECHARGE: next_delay = TRP_CYCLES[3:0];
		ST_REFRESH:   next_delay = TRFC_CYCLES[3:0];
		ST_READ_WAIT: begin
			next_delay = SDRAM_READ_LATENCY[3:0];
			if (!refresh_pending && req_valid && !req_write &&
				request_row_hit)
				next_delay = 4'd0;
		end
		ST_DELAY:
			next_delay = delay_count - 4'd1;
		default:
			next_delay = 4'd0;
	endcase
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		state        <= ST_INIT;
		target_state <= ST_IDLE;
		delay_target <= ST_IDLE;
		delay_count  <= 4'd0;
	end else begin
		target_state <= next_target;
		if (state != ST_DELAY && next_delay != 0)
			delay_target <= next_state;
		delay_count <= next_delay;
		state       <= (next_delay != 0) ? ST_DELAY : next_state;
	end
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		refresh_timer   <= START_TIMER_LOAD;
		refresh_pending <= 1'b0;
		init_done       <= 1'b0;
	end else begin
		if (refresh_timer == 0)
			refresh_timer <= REFRESH_CYCLES[16:0];
		else
			refresh_timer <= refresh_timer - 17'd1;

		if (refresh_timer == 0)
			refresh_pending <= 1'b1;
		else if (state == ST_REFRESH)
			refresh_pending <= 1'b0;

		if (state == ST_INIT && refresh_pending)
			init_done <= 1'b1;
	end
end

logic [3:0]       command;
logic [3:0]       init_command_q;
logic             init_cke_q;
logic [ROW_W-1:0] command_addr;
logic [15:0]      write_beat_data;
logic [1:0]       write_beat_dqm;
logic             write_beat_oe;
(* preserve, dont_merge *) logic sdram_output_reset_q = 1'b1;

// Register startup commands one clock before their scheduled SDRAM command cycle.
always_ff @(posedge clk_sys) begin
	if (reset) begin
		init_command_q <= CMD_NOP;
		init_cke_q     <= 1'b0;
	end else begin
		init_cke_q <= (refresh_timer == 17'd51);
		case (refresh_timer)
			17'd41:         init_command_q <= CMD_PRECHARGE;
			17'd31, 17'd21: init_command_q <= CMD_REFRESH;
			17'd11:         init_command_q <= CMD_MODE;
			default:        init_command_q <= CMD_NOP;
		endcase
	end
end

// Reset the DQ output enable next to its output register.
always_ff @(posedge clk_sys) begin
	sdram_output_reset_q <= reset;
	if (sdram_output_reset_q)
		sdram_data_oe <= 1'b0;
	else
		sdram_data_oe <= write_beat_oe;
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		command         <= CMD_NOP;
		command_addr    <= '0;
		sdram_ba        <= 2'd0;
		sdram_data_out  <= 16'd0;
		sdram_dqm       <= 2'b00;
		sdram_cke       <= 1'b0;
		write_beat_data <= 16'd0;
		write_beat_dqm  <= 2'b00;
		write_beat_oe   <= 1'b0;
		row_open        <= '0;
		active_row[0]   <= '0;
		active_row[1]   <= '0;
		active_row[2]   <= '0;
		active_row[3]   <= '0;
	end else begin
		command        <= CMD_NOP;
		command_addr   <= '0;
		sdram_ba       <= 2'd0;
		sdram_data_out <= write_beat_data;
		sdram_dqm      <= write_beat_dqm;
		write_beat_oe  <= 1'b0;
		write_beat_dqm <= 2'b00;

		case (state)
			ST_INIT: begin
				command <= init_command_q;
				if (init_cke_q)
					sdram_cke <= 1'b1;
				if (init_command_q == CMD_PRECHARGE) begin
					command_addr[10] <= 1'b1;
					row_open         <= '0;
				end else if (init_command_q == CMD_MODE) begin
					command_addr <= MODE_REG[ROW_W-1:0];
				end
			end

			ST_ACTIVATE: begin
				command                  <= CMD_ACTIVE;
				command_addr             <= request_row;
				sdram_ba                 <= request_bank;
				active_row[request_bank] <= request_row;
				row_open[request_bank]   <= 1'b1;
			end

			ST_PRECHARGE: begin
				command <= CMD_PRECHARGE;
				if (target_state == ST_REFRESH) begin
					command_addr[10] <= 1'b1;
					row_open         <= '0;
				end else begin
					sdram_ba               <= request_bank;
					row_open[request_bank] <= 1'b0;
				end
			end

			ST_REFRESH:
				command <= CMD_REFRESH;

			ST_READ: begin
				command                       <= CMD_READ;
				command_addr[SDRAM_COL_W-1:0] <= request_col;
				command_addr[10]              <= 1'b0;
				sdram_ba                      <= request_bank;
				sdram_dqm                     <= 2'b00;
			end

			ST_WRITE0: begin
				command                       <= CMD_WRITE;
				command_addr[SDRAM_COL_W-1:0] <= request_col;
				command_addr[10]              <= 1'b0;
				sdram_ba                      <= request_bank;
			end

			default: ;
		endcase

		// Prepare SDRAM write data, byte masks, and output enable one clock
		// before the output registers.
		if (state == ST_WRITE0) begin
			write_beat_data <= req_wdata[31:16];
			write_beat_dqm  <= 2'b00;
			write_beat_oe   <= 1'b1;
		end else begin
			if (req_valid && req_write)
				write_beat_data <= req_wdata[15:0];

			if (next_delay == 4'd0 && next_state == ST_WRITE0) begin
				write_beat_dqm <= 2'b00;
				write_beat_oe  <= 1'b1;
			end
		end
	end
end

always_comb begin
	sdram_cs              = command[3];
	sdram_ras             = command[2];
	sdram_cas             = command[1];
	sdram_we              = command[0];
	sdram_addr            = 13'd0;
	sdram_addr[ROW_W-1:0] = command_addr;
end

(* preserve, dont_merge *) logic [15:0] read_sample_0;
(* preserve, dont_merge *) logic [15:0] read_sample_1;
logic [15:0] read_sample_2;
logic [15:0] read_low;
// SDRAM returns two BL2 halfwords after CAS latency. The input register adds
// one clock to the assembled response.
logic [SDRAM_READ_LATENCY+3:0] read_pipe;

always_ff @(posedge clk_sys) begin
	read_sample_0 <= sdram_data_in;
	read_sample_1 <= read_sample_0;
	read_sample_2 <= read_sample_1;
	if (read_pipe[SDRAM_READ_LATENCY+3])
		read_low <= read_sample_2;
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		read_pipe <= '0;
		rsp_valid <= 1'b0;
	end else begin
		read_pipe <= {read_pipe[SDRAM_READ_LATENCY+2:0],
			(state == ST_READ)};
		rsp_valid <= read_pipe[SDRAM_READ_LATENCY+3];
	end
end

always_comb rsp_rdata = {read_sample_2, read_low};

always_comb begin
	req_ready = req_valid &&
		((state == ST_READ && !req_write) ||
		 (state == ST_WRITE0 && req_write));
end

endmodule

`default_nettype wire
