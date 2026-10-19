// ============================================================================
// Small dual-clock FIFO with Gray-coded pointer synchronization.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// ============================================================================

`default_nettype none

module vfb_async_fifo #(
	parameter integer WIDTH = 8,
	parameter integer DEPTH = 64,
	parameter integer ALMOST_FULL_MARGIN = 2
) (
	input  wire              wr_clk,
	input  wire              wr_reset,
	input  wire              wr_en,
	input  wire  [WIDTH-1:0] wr_data,
	output logic             wr_full,
	output logic             wr_almost_full,

	input  wire              rd_clk,
	input  wire              rd_reset,
	input  wire              rd_en,
	output logic [WIDTH-1:0] rd_data,
	output logic             rd_valid,
	output logic             rd_empty
);

localparam integer ADDR_W = $clog2(DEPTH);
localparam integer PTR_W = ADDR_W + 1;

initial begin
	if (WIDTH < 1)
		$error("vfb_async_fifo WIDTH must be positive");
	if ((DEPTH < 4) || ((DEPTH & (DEPTH - 1)) != 0))
		$error("vfb_async_fifo DEPTH must be a power of two of at least four");
	if ((ALMOST_FULL_MARGIN < 1) || (ALMOST_FULL_MARGIN >= DEPTH))
		$error("vfb_async_fifo ALMOST_FULL_MARGIN must be between one and DEPTH-1");
end

function automatic [PTR_W-1:0] to_gray(input logic [PTR_W-1:0] value);
	to_gray = (value >> 1) ^ value;
endfunction

function automatic [PTR_W-1:0] from_gray(input logic [PTR_W-1:0] value);
	integer bit_index;
	begin
		from_gray[PTR_W-1] = value[PTR_W-1];
		for (bit_index = PTR_W-2; bit_index >= 0; bit_index = bit_index - 1)
			from_gray[bit_index] = from_gray[bit_index+1] ^ value[bit_index];
	end
endfunction

(* ramstyle = "M10K, no_rw_check" *) logic [WIDTH-1:0] memory [0:DEPTH-1];

logic [PTR_W-1:0] wr_binary = '0;
logic [PTR_W-1:0] wr_gray = '0;
logic [PTR_W-1:0] rd_binary = '0;
logic [PTR_W-1:0] rd_gray = '0;

(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [PTR_W-1:0] rd_gray_meta = '0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [PTR_W-1:0] rd_gray_sync = '0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [PTR_W-1:0] wr_gray_meta = '0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [PTR_W-1:0] wr_gray_sync = '0;

wire             wr_push = wr_en && !wr_full;
wire             rd_pop = rd_en && !rd_empty;
wire [PTR_W-1:0] wr_binary_next = wr_binary + wr_push;
wire [PTR_W-1:0] rd_binary_next = rd_binary + rd_pop;
wire [PTR_W-1:0] wr_gray_next = to_gray(wr_binary_next);
wire [PTR_W-1:0] rd_gray_next = to_gray(rd_binary_next);
wire [PTR_W-1:0] rd_binary_sync = from_gray(rd_gray_sync);
wire [PTR_W-1:0] wr_used_next = wr_binary_next - rd_binary_sync;
localparam [PTR_W-1:0] ALMOST_FULL_LEVEL =
	PTR_W'(DEPTH - ALMOST_FULL_MARGIN);

wire [PTR_W-1:0] full_compare = {
	~rd_gray_sync[PTR_W-1:PTR_W-2],
	rd_gray_sync[PTR_W-3:0]
};
wire wr_full_next = (wr_gray_next == full_compare);
wire wr_almost_full_next = (wr_used_next >= ALMOST_FULL_LEVEL);
wire rd_empty_next = (rd_gray_next == wr_gray_sync);

always_ff @(posedge wr_clk) begin
	if (wr_reset) begin
		wr_binary      <= '0;
		wr_gray        <= '0;
		wr_full        <= 1'b0;
		wr_almost_full <= 1'b0;
	end else begin
		if (wr_push)
			memory[wr_binary[ADDR_W-1:0]] <= wr_data;
		wr_binary      <= wr_binary_next;
		wr_gray        <= wr_gray_next;
		wr_full        <= wr_full_next;
		wr_almost_full <= wr_almost_full_next;
	end
end

always_ff @(posedge rd_clk) begin
	if (rd_reset) begin
		rd_binary <= '0;
		rd_gray   <= '0;
		rd_empty  <= 1'b1;
		rd_data   <= '0;
		rd_valid  <= 1'b0;
	end else begin
		rd_valid <= rd_pop;
		if (rd_pop)
			rd_data <= memory[rd_binary[ADDR_W-1:0]];
		rd_binary <= rd_binary_next;
		rd_gray   <= rd_gray_next;
		rd_empty  <= rd_empty_next;
	end
end

always_ff @(posedge wr_clk) begin
	if (wr_reset) begin
		rd_gray_meta <= '0;
		rd_gray_sync <= '0;
	end else begin
		rd_gray_meta <= rd_gray;
		rd_gray_sync <= rd_gray_meta;
	end
end

always_ff @(posedge rd_clk) begin
	if (rd_reset) begin
		wr_gray_meta <= '0;
		wr_gray_sync <= '0;
	end else begin
		wr_gray_meta <= wr_gray;
		wr_gray_sync <= wr_gray_meta;
	end
end

endmodule

`default_nettype wire
