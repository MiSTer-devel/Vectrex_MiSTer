// ============================================================================
// PiTrex mode: command player (machine clock domain, clk_sys = 24 MHz).
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Replays the ARM's timestamped command stream (see pitrex-mister PROTOCOL.md)
// as Vectrex bus cycles. Each command waits `delta` E-cycles, then occupies one
// E-cycle on the bus, presented from the same falling-E enable the 6809 uses.
// When no command is queued the player asks the machine to pause, so the whole
// simulated Vectrex (VIA timers, integrators, beam) stops instead of drawing
// with broken timing. A snapshot of stream time and inputs is published for
// the DDR side every 4096 clocks (toggle handshake; data held stable).
//
// Command word: op[63:56] delta[55:40] addr[39:24] data[23:16]
// ============================================================================

`default_nettype none

module pitrex_player (
	input  wire        clk,
	input  wire        enable,        // OSD PiTrex mode
	input  wire        e_fall,        // falling-E enable from the CPU wrapper

	// command FIFO read side (vfb_async_fifo: data valid the cycle after rd_en)
	output logic       fifo_rd_en,
	input  wire [63:0] fifo_rd_data,
	input  wire        fifo_rd_valid,
	input  wire        fifo_rd_empty,

	// bus override towards vectrex.vhd
	output logic [15:0] bus_addr,
	output logic [7:0]  bus_do,
	output logic        bus_rw,
	output wire         stall,

	// inputs to publish (as the core's comparator and PSG port A see them)
	input  wire [31:0] pots,          // {y2, x2, y1, x1}
	input  wire [7:0]  psg_ioa,

	// snapshot for the DDR side
	output logic [47:0] snap_cycles,
	output logic [15:0] snap_frames,
	output logic [15:0] snap_underruns,
	output logic [31:0] snap_pots,
	output logic [7:0]  snap_ioa,
	output logic        snap_toggle
);

localparam logic [7:0] OP_WRITE = 8'h01;
localparam logic [7:0] OP_WAIT  = 8'h02;
localparam logic [7:0] OP_READ  = 8'h04;
localparam logic [7:0] OP_FRAME = 8'h10;

logic        cur_valid = 1'b0;
logic [7:0]  cur_op;
logic [15:0] cur_cnt;
logic [15:0] cur_addr;
logic [7:0]  cur_data;
logic        loading = 1'b0;

logic [47:0] stream_cycles = '0;
logic [15:0] frames = '0;
logic [15:0] underruns = '0;
logic        in_underrun = 1'b0;
logic [11:0] snap_div = '0;

// Pause only when nothing at all is queued; a pop in flight is not an underrun.
assign stall = enable && !cur_valid && !loading && fifo_rd_empty;

wire [7:0]  in_op    = fifo_rd_data[63:56];
wire [15:0] in_delta = fifo_rd_data[55:40];

always_ff @(posedge clk) begin
	fifo_rd_en <= 1'b0;

	if (!enable) begin
		cur_valid     <= 1'b0;
		loading       <= 1'b0;
		bus_addr      <= 16'hFFFF;
		bus_rw        <= 1'b1;
		bus_do        <= 8'h00;
		stream_cycles <= '0;
		frames        <= '0;
		underruns     <= '0;
		in_underrun   <= 1'b0;
	end else begin
		// ---- fetch the next command ----
		if (!cur_valid && !loading && !fifo_rd_empty && !fifo_rd_en) begin
			fifo_rd_en <= 1'b1;
			loading    <= 1'b1;
		end
		if (fifo_rd_valid) begin
			loading <= 1'b0;
			case (in_op)
				OP_WRITE, OP_READ: begin
					cur_valid <= 1'b1;
					cur_op    <= in_op;
					cur_cnt   <= in_delta;
					cur_addr  <= fifo_rd_data[39:24];
					cur_data  <= fifo_rd_data[23:16];
				end
				OP_WAIT: if (in_delta != 16'd0) begin
					cur_valid <= 1'b1;
					cur_op    <= OP_WAIT;
					cur_cnt   <= in_delta;
				end
				OP_FRAME: frames <= frames + 1'd1;
				default: ;                    // RESET_SYNC and unknown: no bus time
			endcase
		end

		// ---- one E-cycle ----
		if (e_fall) begin
			bus_addr <= 16'hFFFF;             // idle: harmless BIOS read
			bus_rw   <= 1'b1;
			if (cur_valid) begin
				in_underrun   <= 1'b0;
				stream_cycles <= stream_cycles + 1'd1;
				if (cur_op == OP_WAIT) begin
					cur_cnt <= cur_cnt - 1'd1;
					if (cur_cnt == 16'd1) cur_valid <= 1'b0;
				end else if (cur_cnt != 16'd0) begin
					cur_cnt <= cur_cnt - 1'd1;
				end else begin
					bus_addr  <= cur_addr;
					bus_do    <= cur_data;
					bus_rw    <= (cur_op == OP_READ);
					cur_valid <= 1'b0;
				end
			end else if (!loading && !in_underrun) begin
				in_underrun <= 1'b1;
				underruns   <= underruns + 1'd1;
			end
		end
	end

	// ---- snapshot for the 125 MHz side (stable for 4096 clocks) ----
	snap_div <= snap_div + 1'd1;
	if (snap_div == '0) begin
		snap_cycles    <= stream_cycles;
		snap_frames    <= frames;
		snap_underruns <= underruns;
		snap_pots      <= pots;
		snap_ioa       <= psg_ioa;
		snap_toggle    <= ~snap_toggle;
	end
end

endmodule

`default_nettype wire
