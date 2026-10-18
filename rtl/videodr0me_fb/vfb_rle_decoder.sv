// ============================================================================
// Line-local RLE decoder for 12-bit beam-energy samples.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A small run FIFO prefetches boundaries so decoding sustains one pixel per
// advance while input data is available.
// ============================================================================

`default_nettype none

module vfb_rle_decoder (
	input  wire  clk_sys,
	input  wire  reset,

	input  wire         token_valid,
	output logic        token_ready,
	input  wire  [15:0] token_data,
	input  wire         token_eol,

	input  wire         advance,
	output logic [11:0] canonical_out,
	output logic        line_done,
	output logic        underflow
);

localparam integer RUN_FIFO_DEPTH = 16;
localparam integer RUN_FIFO_AW = $clog2(RUN_FIFO_DEPTH);
typedef struct packed {
	logic        eol;
	logic [12:0] count;
	logic [11:0] sample;
} run_entry_t;

logic [11:0] previous_sample;
(* ramstyle = "logic" *) run_entry_t run_fifo [0:RUN_FIFO_DEPTH-1];
logic [RUN_FIFO_AW-1:0] fifo_wr_ptr;
logic [RUN_FIFO_AW-1:0] fifo_rd_ptr;
logic [RUN_FIFO_AW:0]   fifo_used;
logic [11:0]            run_sample;
logic [12:0]            run_remaining;
logic                   run_eol;

wire fifo_full    = (fifo_used == RUN_FIFO_DEPTH);
wire fifo_empty   = (fifo_used == 0);
wire consume_run  = advance && (run_remaining != 0);
wire consume_fifo = advance && (run_remaining == 0) && !fifo_empty;
wire fifo_pop     = consume_fifo;

logic        token_supported;
logic [11:0] push_sample;
logic [12:0] push_count;
always_comb begin
	token_supported = 1'b1;
	push_sample     = 12'd0;
	push_count      = 13'd0;

	case (token_data[15:12])
		4'hf: begin
			push_sample = token_data[11:0];
			push_count  = 13'd1;
			if (token_data[11:0] == 0)
				token_supported = 1'b0;
		end
		4'h0: begin
			push_sample = 12'd0;
			push_count  = {1'b0, token_data[11:0]} + 1'b1;
		end
		4'h1: begin
			push_sample = previous_sample;
			push_count  = {1'b0, token_data[11:0]} + 1'b1;
		end
		default: token_supported = 1'b0;
	endcase
end

// When full, accept another token only on the clock after an entry
// has been removed, avoiding simultaneous reads and writes to that slot.
assign token_ready = !fifo_full;
wire fifo_push = token_valid && token_ready && token_supported;

always_comb begin
	if (run_remaining != 0)
		canonical_out = run_sample;
	else if (!fifo_empty)
		canonical_out = run_fifo[fifo_rd_ptr].sample;
	else
		canonical_out = 12'd0;
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		previous_sample <= 12'd0;
		fifo_wr_ptr     <= '0;
		fifo_rd_ptr     <= '0;
		fifo_used       <= '0;
		run_sample      <= 12'd0;
		run_remaining   <= 13'd0;
		run_eol         <= 1'b0;
		line_done       <= 1'b0;
		underflow       <= 1'b0;
	end else begin
		line_done <= 1'b0;

		if (token_valid && token_ready) begin
			if (token_supported) begin
				run_fifo[fifo_wr_ptr].sample <= push_sample;
				run_fifo[fifo_wr_ptr].count  <= push_count;
				run_fifo[fifo_wr_ptr].eol    <= token_eol;
				fifo_wr_ptr                  <= fifo_wr_ptr + 1'b1;
				if (token_data[15:12] == 4'hf)
					previous_sample <= push_sample;
				else if (token_data[15:12] == 4'h0)
					previous_sample <= 12'd0;
				if (token_eol)
					previous_sample <= 12'd0;
			end else begin
				underflow <= 1'b1;
			end
		end

		if (consume_run) begin
			if (run_remaining == 13'd1) begin
				run_remaining <= 13'd0;
				if (run_eol)
					line_done <= 1'b1;
			end else begin
				run_remaining <= run_remaining - 1'b1;
			end
		end else if (consume_fifo) begin
			run_sample <= run_fifo[fifo_rd_ptr].sample;
			run_eol    <= run_fifo[fifo_rd_ptr].eol;
			if (run_fifo[fifo_rd_ptr].count == 13'd1) begin
				run_remaining <= 13'd0;
				if (run_fifo[fifo_rd_ptr].eol)
					line_done <= 1'b1;
			end else begin
				run_remaining <= run_fifo[fifo_rd_ptr].count - 1'b1;
			end
			fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
		end else if (advance) begin
			underflow <= 1'b1;
		end

		case ({fifo_push, fifo_pop})
			2'b10:   fifo_used <= fifo_used + 1'b1;
			2'b01:   fifo_used <= fifo_used - 1'b1;
			default: fifo_used <= fifo_used;
		endcase
	end
end

endmodule

`default_nettype wire
