// ============================================================================
// Single-clock FIFO with registered head and lookahead words.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// ============================================================================

`default_nettype none

module vfb_sync_fifo #(
	parameter integer WIDTH = 32,
	parameter integer DEPTH = 256
) (
	input  wire  clk_sys,
	input  wire  reset,

	input  wire              wr_en,
	input  wire  [WIDTH-1:0] wr_data,
	output logic             full,

	input  wire              rd_en,
	output logic [WIDTH-1:0] rd_data,
	output logic             empty,

	output logic [$clog2(DEPTH):0] used
);

localparam integer          ADDR_W      = $clog2(DEPTH);
localparam logic [ADDR_W:0] DEPTH_COUNT = {1'b1, {ADDR_W{1'b0}}};

initial begin
	if (WIDTH < 1)
		$error("vfb_sync_fifo WIDTH must be positive");
	if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
		$error("vfb_sync_fifo DEPTH must be a power of two of at least two");
end

(* ramstyle = "M10K, no_rw_check" *) logic [WIDTH-1:0] memory [0:DEPTH-1];
logic [ADDR_W-1:0] write_ptr;
logic [ADDR_W-1:0] read_ptr;
logic [ADDR_W:0]   mem_used;
logic              head_valid;
logic              look_valid;
logic [WIDTH-1:0]  look_data;
logic              prefetch_pending;
logic [ADDR_W-1:0] prefetch_addr;

assign full  = (used == DEPTH_COUNT);
assign empty = !head_valid;

wire push = wr_en && !full;
wire pop  = rd_en && head_valid;

// Resolve the two output registers before deciding whether RAM needs a read.
wire head_kept = look_valid || (head_valid && !pop);
wire look_kept = look_valid && head_valid && !pop;
wire bypass    = push && !prefetch_pending && (mem_used == '0);
wire push_head = bypass && !head_kept;
wire push_look = bypass && head_kept && !look_kept;
wire ram_push  = push && !push_head && !push_look;
wire head_next = head_kept || push_head || prefetch_pending;
wire look_next = look_kept || push_look || (prefetch_pending && head_kept);
wire ram_read  = (!head_next || !look_next) && ((mem_used != '0) || ram_push);

always_ff @(posedge clk_sys) begin
	if (reset) begin
		write_ptr        <=   '0;
		read_ptr         <=   '0;
		mem_used         <=   '0;
		head_valid       <= 1'b0;
		look_valid       <= 1'b0;
		prefetch_pending <= 1'b0;
		prefetch_addr    <=   '0;
		rd_data          <=   '0;
		look_data        <=   '0;
		used             <=   '0;
	end else begin
		case ({push, pop})
			2'b10: used <= used + 1'b1;
			2'b01: used <= used - 1'b1;
			default: ;
		endcase
		case ({ram_push, ram_read})
			2'b10: mem_used <= mem_used + 1'b1;
			2'b01: mem_used <= mem_used - 1'b1;
			default: ;
		endcase

		head_valid <= head_next;
		look_valid <= look_next;
		if (look_valid && (!head_valid || pop)) rd_data   <= look_data;
		if (push_head)                          rd_data   <= wr_data;
		if (push_look)                          look_data <= wr_data;

		if (ram_push) begin
			memory[write_ptr] <= wr_data;
			write_ptr         <= write_ptr + 1'b1;
		end
		if (prefetch_pending) begin
			if (!head_kept)
				rd_data <= memory[prefetch_addr];
			else
				look_data <= memory[prefetch_addr];
		end

		prefetch_pending <= ram_read;
		if (ram_read) begin
			prefetch_addr <= read_ptr;
			read_ptr      <= read_ptr + 1'b1;
		end
	end
end

endmodule

`default_nettype wire
