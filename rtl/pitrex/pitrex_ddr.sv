// ============================================================================
// PiTrex mode: DDR ring reader (renderer clock domain, clk_125).
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A read client and a write client on vfb_ddr_arbiter. The ARM (HPS) writes
// 64-bit commands into a ring in DDR3 and publishes a write index in a header;
// this module polls the header, fetches up to 32 commands per burst into the
// command FIFO, and writes back its read index, the machine's stream time and
// the input block. Layout in 64-bit words from PTX_BASE (byte = word * 8):
//   word 0      {version, magic "PTRX"}      ARM
//   word 2      wr_idx                       ARM
//   word 3      {~hb ^ "PTRX", hb}           ARM heartbeat (coded; must keep changing)
//   word 8      rd_idx                       core
//   word 9      core_cycles (stream time)    core
//   word 10     {underruns, frames}          core
//   word 11     {0, build, "PTXC"}           core (identifies the core build)
//   word 16     {pad, psg_ioa, y2, x2, y1, x1}  core
//   word 17     {0, seq}                     core
//   word 0x200  ring, 65536 entries
// ============================================================================

`default_nettype none

module pitrex_ddr #(
	parameter logic [28:0] PTX_BASE = 29'h06800000,
	parameter logic [7:0]  BUILD    = 8'd0
) (
	input  wire         clk,
	input  wire         enable,          // synchronised to clk by the caller
	output logic        present,         // a live ARM program is streaming (coded heartbeat)

	// arbiter read client
	output logic        rd_ready,
	input  wire         rd_grant,
	output logic [28:0] rd_addr,
	output logic [7:0]  rd_burstcnt,
	input  wire  [63:0] rd_data,
	input  wire         rd_data_valid,

	// arbiter write client
	output logic        wr_ready,
	input  wire         wr_grant,
	input  wire         wr_done,
	output logic [28:0] wr_addr,
	output logic [7:0]  wr_burstcnt,
	output logic [63:0] wr_data,
	output logic [7:0]  wr_be,
	input  wire         wr_advance,

	// command FIFO write side
	output logic        fifo_wr_en,
	output logic [63:0] fifo_wr_data,
	input  wire         fifo_almost_full,  // fewer than one burst free

	// snapshot from the machine domain (held stable between toggles)
	input  wire [47:0]  snap_cycles,
	input  wire [15:0]  snap_frames,
	input  wire [15:0]  snap_underruns,
	input  wire [31:0]  snap_pots,
	input  wire [7:0]   snap_ioa,
	input  wire         snap_toggle
);

localparam logic [31:0] MAGIC     = 32'h58525450;   // "PTRX" little-endian
localparam logic [28:0] RING_BASE = PTX_BASE + 29'h200;
localparam integer      RING_LOG2 = 16;
localparam logic [15:0] POLL_GAP  = 16'd250;        // 2 us between idle polls
localparam logic [15:0] STATUS_GAP = 16'd62500;     // 0.5 ms between status writes

typedef enum logic [2:0] {
	S_IDLE, S_HDR_REQ, S_HDR_DATA, S_RING_REQ, S_RING_DATA, S_STAT_REQ, S_STAT_DATA, S_SETTLE
} state_t;
state_t state = S_IDLE;

logic [63:0] rd_idx = '0;
logic [16:0] wr_lo = '0;          // low bits suffice: the ARM is never > 65536 ahead
logic        magic_ok = 1'b0;
logic [31:0] hb_last = '0;
logic [23:0] hb_timer = '0;
localparam logic [23:0] HB_TIMEOUT = 24'd12_500_000;   // 100 ms at 125 MHz
logic [2:0]  beat = '0;
logic [5:0]  fetch_n = '0;
logic [5:0]  fetch_left = '0;
logic [15:0] poll_timer = '0;
logic [15:0] status_timer = '0;
logic        status_due = 1'b0;

// snapshot capture: the toggle is synchronised, the data has been stable for
// thousands of clocks by the time the toggle edge is seen
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [2:0]  tog_sync = '0;
logic [47:0] cap_cycles = '0;
logic [15:0] cap_frames = '0, cap_underruns = '0;
logic [31:0] cap_pots = '0;
logic [7:0]  cap_ioa = 8'hFF;
logic [31:0] seq = '0;

always_ff @(posedge clk) begin
	tog_sync <= {tog_sync[1:0], snap_toggle};
	if (tog_sync[2] != tog_sync[1]) begin
		cap_cycles    <= snap_cycles;
		cap_frames    <= snap_frames;
		cap_underruns <= snap_underruns;
		cap_pots      <= snap_pots;
		cap_ioa       <= snap_ioa;
		seq           <= seq + 1'd1;
	end
end

// ring fetch size: min(32, available, words before the ring wraps), computed
// one cycle ahead in registers to keep the 125 MHz paths short
logic [16:0] avail_q = '0;
logic [5:0]  n_fetch_q = '0;
wire  [16:0] avail_d   = wr_lo - rd_idx[16:0];
wire  [16:0] to_wrap   = 17'h10000 - {1'b0, rd_idx[RING_LOG2-1:0]};
wire  [5:0]  n_avail   = (avail_d > 17'd32) ? 6'd32 : avail_d[5:0];
always_ff @(posedge clk) begin
	avail_q   <= avail_d;
	n_fetch_q <= ({11'd0, n_avail} > to_wrap) ? to_wrap[5:0] : n_avail;
end

// status burst: words 8..17 (10 beats); byte enables off on words 11..15.
// The arbiter takes DIN combinationally and pulses wr_advance per accepted beat.
logic [3:0] wbeat = '0;
always_comb begin
	wr_be   = 8'hFF;
	wr_data = 64'd0;
	case (wbeat)
		4'd0: wr_data = rd_idx;
		4'd1: wr_data = {16'd0, cap_cycles};
		4'd2: wr_data = {16'd0, cap_underruns, 16'd0, cap_frames};
		4'd3: wr_data = {24'd0, BUILD, 32'h43585450};   // "PTXC"
		4'd8: wr_data = {24'd0, cap_ioa, cap_pots};
		4'd9: wr_data = {32'd0, seq};
		default: wr_be = 8'h00;
	endcase
end

always_ff @(posedge clk) begin
	fifo_wr_en <= 1'b0;
	if (poll_timer != 0)   poll_timer <= poll_timer - 1'd1;
	if (status_timer != 0) status_timer <= status_timer - 1'd1;
	else                   status_due <= 1'b1;
	if (hb_timer != 0)     hb_timer <= hb_timer - 1'd1;
	else                   present <= 1'b0;     // heartbeat stopped: hand back

	if (wr_advance) wbeat <= wbeat + 1'd1;      // may fire in the grant cycle

	if (!enable) begin
		state      <= S_IDLE;
		rd_ready   <= 1'b0;
		wr_ready   <= 1'b0;
		rd_idx     <= '0;
		wr_lo      <= '0;
		magic_ok   <= 1'b0;
		present    <= 1'b0;
		hb_timer   <= '0;
		status_due <= 1'b1;
	end else begin
		case (state)
			S_IDLE: begin
				if (status_due) begin
					wr_addr     <= PTX_BASE + 29'd8;
					wr_burstcnt <= 8'd10;
					wbeat       <= '0;
					wr_ready    <= 1'b1;
					state       <= S_STAT_REQ;
				end else if (magic_ok && present && avail_q != 0 && !fifo_almost_full) begin
					rd_addr     <= RING_BASE + {13'd0, rd_idx[RING_LOG2-1:0]};
					rd_burstcnt <= {2'd0, n_fetch_q};
					fetch_n     <= n_fetch_q;
					fetch_left  <= n_fetch_q;
					rd_ready    <= 1'b1;
					state       <= S_RING_REQ;
				end else if (poll_timer == 0) begin
					rd_addr     <= PTX_BASE;
					rd_burstcnt <= 8'd4;
					beat        <= '0;
					rd_ready    <= 1'b1;
					state       <= S_HDR_REQ;
				end
			end

			S_HDR_REQ: if (rd_grant) begin rd_ready <= 1'b0; state <= S_HDR_DATA; end
			S_HDR_DATA: if (rd_data_valid) begin
				beat <= beat + 1'd1;
				if (beat == 3'd0) begin
					magic_ok <= (rd_data[31:0] == MAGIC);
					if (rd_data[31:0] != MAGIC) present <= 1'b0;   // program exited
				end
				if (beat == 3'd2) wr_lo <= rd_data[16:0];
				if (beat == 3'd3) begin
					// accept a heartbeat only if it is coded correctly and has moved on
					if (magic_ok && rd_data[63:32] == (~rd_data[31:0] ^ MAGIC) &&
					    rd_data[31:0] != hb_last) begin
						hb_last  <= rd_data[31:0];
						hb_timer <= HB_TIMEOUT;
						present  <= 1'b1;
					end
					poll_timer <= POLL_GAP;
					state      <= S_SETTLE;
				end
			end

			S_RING_REQ: if (rd_grant) begin rd_ready <= 1'b0; state <= S_RING_DATA; end
			S_RING_DATA: if (rd_data_valid) begin
				fifo_wr_en   <= 1'b1;
				fifo_wr_data <= rd_data;
				fetch_left   <= fetch_left - 1'd1;
				if (fetch_left == 6'd1) begin
					rd_idx <= rd_idx + {58'd0, fetch_n};
					state  <= S_SETTLE;         // re-poll only when the ring runs dry
				end
			end

			S_STAT_REQ: if (wr_grant) begin wr_ready <= 1'b0; state <= S_STAT_DATA; end
			S_STAT_DATA: begin
				if (wr_done) begin
					status_due   <= 1'b0;
					status_timer <= STATUS_GAP;
					state        <= S_IDLE;
				end
			end

			S_SETTLE: state <= S_IDLE;       // let avail_q/n_fetch_q catch up
			default: state <= S_IDLE;
		endcase
	end
end

endmodule

`default_nettype wire
