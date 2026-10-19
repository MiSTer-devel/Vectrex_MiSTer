// ============================================================================
// Line-local RLE encoder for 12-bit beam-energy samples.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Encodes each line independently using 16-bit tokens:
//   Fxxx: one nonzero 12-bit sample xxx.
//   0nnn: nnn+1 black pixels.
//   1nnn: nnn+1 additional pixels with the previous sample value.
// Runs contain at most 4096 pixels; nonzero runs begin with a literal.
// Example: five pixels of value 12'h345 become 16'hf345, 16'h1003.
// token_eol is a separate signal marking the final token of a line.
// ============================================================================

`default_nettype none

module vfb_rle_encoder (
	input  wire  clk_sys,
	input  wire  reset,

	input  wire         pixel_valid,
	input  wire  [11:0] canonical_in,
	input  wire         line_end,

	output logic        token_valid,
	input  wire         token_ready,
	output logic [15:0] token_data,
	output logic        token_eol,

	output logic        overflow
);

localparam integer RUN_FIFO_DEPTH = 16;
localparam integer RUN_FIFO_AW    = $clog2(RUN_FIFO_DEPTH);

typedef struct packed {
	logic        eol;
	logic [12:0] count;
	logic [11:0] sample;
} run_entry_t;

typedef struct packed {
	logic       valid;
	run_entry_t entry;
} run_slot_t;

typedef enum logic [1:0] {
	EMIT_IDLE,
	EMIT_BLACK,
	EMIT_LITERAL,
	EMIT_REPEAT
} emit_state_t;

function automatic logic [11:0] count_m1_4096(
	input logic [12:0] count
);
	count_m1_4096 = (count >= 13'd4096) ? 12'hfff : count[11:0] - 12'd1;
endfunction

logic        input_valid;
logic [11:0] input_sample;
logic        input_line_end;
logic        run_valid;
logic [11:0] run_sample;
logic [12:0] run_count;

(* ramstyle = "logic" *) run_entry_t run_fifo [0:RUN_FIFO_DEPTH-1];
logic [RUN_FIFO_AW:0]   run_fifo_used;
logic [RUN_FIFO_AW-1:0] run_fifo_rd_ptr;
logic [RUN_FIFO_AW-1:0] run_fifo_wr_ptr;
run_slot_t              pending_q;
run_slot_t              prefetch_q;

emit_state_t emit_state;
logic [11:0] emit_sample;
logic [12:0] emit_remaining;
logic        emit_eol;

wire        run_fifo_empty = (run_fifo_used == 0);
wire        run_fifo_full  = (run_fifo_used == RUN_FIFO_DEPTH);
run_entry_t run_fifo_head;
run_entry_t start_entry;
run_entry_t completed_run;

assign run_fifo_head   = run_fifo[run_fifo_rd_ptr];
wire   emit_can_write  = !token_valid || token_ready;
wire   emit_busy       = (emit_state != EMIT_IDLE);
wire   emit_finishes   = emit_can_write && emit_busy &&
                         (((emit_state == EMIT_LITERAL) && (emit_remaining == 13'd1)) ||
                          (emit_state != EMIT_LITERAL));
wire   emit_available  = !emit_busy || emit_finishes;
wire   run_fifo_pop    = !prefetch_q.valid && !run_fifo_empty;
wire   start_prefetch  = emit_available && prefetch_q.valid;
wire   start_fifo_head = emit_available && !prefetch_q.valid && run_fifo_pop;
wire   start_emit      = start_prefetch || start_fifo_head;
assign start_entry     = prefetch_q.valid ? prefetch_q.entry : run_fifo_head;

wire   run_fifo_can_push  = !run_fifo_full || run_fifo_pop;
wire   run_fifo_push      = pending_q.valid && run_fifo_can_push;
wire   pixel_extends_run  = input_valid && run_valid &&
                            (input_sample == run_sample) && (run_count < 13'd4096);
wire   pixel_finishes_run = input_valid && run_valid && !pixel_extends_run;
wire   line_finishes_run  = input_line_end && run_valid;
wire   run_close_request  = pixel_finishes_run || line_finishes_run;
wire   pending_ready      = !pending_q.valid || run_fifo_can_push;
wire   run_close_accept   = run_close_request && pending_ready;
assign completed_run      = { line_finishes_run, run_count, run_sample };

always_ff @(posedge clk_sys) begin
	if (reset) begin
		token_valid     <= 1'b0;
		token_data      <= 16'd0;
		token_eol       <= 1'b0;
		input_valid     <= 1'b0;
		input_sample    <= 12'd0;
		input_line_end  <= 1'b0;
		run_valid       <= 1'b0;
		run_sample      <= 12'd0;
		run_count       <= 13'd0;
		run_fifo_used   <= '0;
		run_fifo_rd_ptr <= '0;
		run_fifo_wr_ptr <= '0;
		pending_q       <= '0;
		prefetch_q      <= '0;
		emit_state      <= EMIT_IDLE;
		emit_sample     <= 12'd0;
		emit_remaining  <= 13'd0;
		emit_eol        <= 1'b0;
		overflow        <= 1'b0;
	end else begin
		input_valid    <= pixel_valid;
		input_sample   <= canonical_in;
		input_line_end <= line_end;

		if (token_valid && token_ready)
			token_valid <= 1'b0;

		if (emit_busy && emit_can_write) begin
			token_valid <= 1'b1;
			case (emit_state)
				EMIT_BLACK: begin
					token_data <= {4'h0, count_m1_4096(emit_remaining)};
					emit_state <= EMIT_IDLE;
					token_eol  <= emit_eol;
				end

				EMIT_LITERAL: begin
					token_data <= {4'hf, emit_sample};
					if (emit_remaining > 13'd1) begin
						emit_remaining <= emit_remaining - 13'd1;
						emit_state     <= EMIT_REPEAT;
						token_eol      <= 1'b0;
					end else begin
						emit_state <= EMIT_IDLE;
						token_eol  <= emit_eol;
					end
				end

				EMIT_REPEAT: begin
					token_data <= {4'h1, count_m1_4096(emit_remaining)};
					emit_state <= EMIT_IDLE;
					token_eol  <= emit_eol;
				end

				default: begin
					token_valid <= 1'b0;
					token_data  <= 16'd0;
					token_eol   <= 1'b0;
					emit_state  <= EMIT_IDLE;
				end
			endcase
		end

		if (start_emit) begin
			emit_sample    <= start_entry.sample;
			emit_remaining <= start_entry.count;
			emit_eol       <= start_entry.eol;
			emit_state     <= (start_entry.sample == 0) ? EMIT_BLACK : EMIT_LITERAL;
		end

		if (start_prefetch)
			prefetch_q.valid <= 1'b0;
		if (run_fifo_pop) begin
			if (!start_fifo_head) begin
				prefetch_q.entry <= run_fifo_head;
				prefetch_q.valid <= 1'b1;
			end
			run_fifo_rd_ptr <= run_fifo_rd_ptr + 1'b1;
		end
		if (run_fifo_push) begin
			run_fifo[run_fifo_wr_ptr] <= pending_q.entry;
			run_fifo_wr_ptr           <= run_fifo_wr_ptr + 1'b1;
		end
		case ({run_fifo_push, run_fifo_pop})
			2'b10:   run_fifo_used <= run_fifo_used + 1'b1;
			2'b01:   run_fifo_used <= run_fifo_used - 1'b1;
			default: run_fifo_used <= run_fifo_used;
		endcase

		if (run_fifo_push)
			pending_q.valid <= 1'b0;
		if (run_close_request) begin
			if (pending_ready) begin
				pending_q.entry <= completed_run;
				pending_q.valid <= 1'b1;
			end else begin
				overflow <= 1'b1;
			end
		end

		if (line_finishes_run && run_close_accept) begin
			run_valid <= 1'b0;
			run_count <= 13'd0;
		end

		if (input_valid) begin
			if (!run_valid) begin
				run_valid  <= 1'b1;
				run_sample <= input_sample;
				run_count  <= 13'd1;
			end else if (pixel_extends_run) begin
				run_count <= run_count + 1'b1;
			end else begin
				run_valid  <= 1'b1;
				run_sample <= input_sample;
				run_count  <= 13'd1;
			end
		end
	end
end

endmodule

`default_nettype wire
