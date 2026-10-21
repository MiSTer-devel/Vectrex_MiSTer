// ============================================================================
// Fixed-priority DDRAM burst arbiter.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// Priority is readout, flush, fill, composition, PiTrex ring read/write,
// artwork upload, then artwork readout. The arbiter routes requests, drains in-flight bursts across reset,
// and completes invalid bursts locally without accessing DDRAM.
// ============================================================================

`default_nettype none

module vfb_ddr_arbiter (
	input  wire  clk_sys,
	input  wire  rst_sys,

	// DDRAM interface
	input  wire         DDRAM_BUSY,
	output logic [7:0]  DDRAM_BURSTCNT,
	output logic [28:0] DDRAM_ADDR,
	output wire         DDRAM_RD,
	output wire         DDRAM_WE,
	output wire [63:0]  DDRAM_DIN,
	output wire [7:0]   DDRAM_BE,
	input  wire  [63:0] DDRAM_DOUT,
	input  wire         DDRAM_DOUT_READY,

	// Client interfaces

	// Framebuffer readout (highest priority)
	input  wire         readout_ready,
	output logic        readout_grant,
	input  wire  [28:0] readout_addr,
	input  wire  [8:0]  readout_burstcnt,
	output logic [63:0] readout_data,
	output logic        readout_data_valid,

	// Cache fill
	input  wire         fill_ready,
	output logic        fill_grant,
	input  wire  [28:0] fill_addr,
	input  wire  [7:0]  fill_burstcnt,
	output logic [63:0] fill_data,
	output logic        fill_data_valid,

	// Cache flush
	input  wire         flush_ready,
	output logic        flush_grant,
	output logic        flush_done,         // Pulse: last beat accepted
	input  wire  [28:0] flush_addr,
	input  wire  [7:0]  flush_burstcnt,
	input  wire  [63:0] flush_din,          // Current beat data from requester
	input  wire  [7:0]  flush_be,           // Current beat byte enables
	output wire         flush_advance,      // Beat accepted; present next beat

	// Inter-frame composition
	input  wire         compose_read_ready,
	output logic        compose_read_grant,
	input  wire  [28:0] compose_read_addr,
	input  wire  [7:0]  compose_read_burstcnt,
	output logic [63:0] compose_read_data,
	output logic        compose_read_data_valid,

	input  wire         compose_write_ready,
	output logic        compose_write_grant,
	output logic        compose_write_done,
	input  wire  [28:0] compose_write_addr,
	input  wire  [7:0]  compose_write_burstcnt,
	input  wire  [63:0] compose_write_data,
	input  wire  [7:0]  compose_write_be,
	output wire         compose_write_advance,

	// Artwork upload
	input  wire         upload_write_ready,
	output logic        upload_write_done,
	input  wire  [28:0] upload_write_addr,
	input  wire  [7:0]  upload_write_burstcnt,
	input  wire  [63:0] upload_write_data,
	input  wire  [7:0]  upload_write_be,
	output wire         upload_write_advance,

	// PiTrex command ring (between composition and artwork upload)
	input  wire         ptx_read_ready,
	output logic        ptx_read_grant,
	input  wire  [28:0] ptx_read_addr,
	input  wire  [7:0]  ptx_read_burstcnt,
	output logic [63:0] ptx_read_data,
	output logic        ptx_read_data_valid,

	input  wire         ptx_write_ready,
	output logic        ptx_write_grant,
	output logic        ptx_write_done,
	input  wire  [28:0] ptx_write_addr,
	input  wire  [7:0]  ptx_write_burstcnt,
	input  wire  [63:0] ptx_write_data,
	input  wire  [7:0]  ptx_write_be,
	output wire         ptx_write_advance,

	// Artwork readout (lowest priority)
	input  wire         artwork_read_ready,
	output logic        artwork_read_grant,
	input  wire  [28:0] artwork_read_addr,
	input  wire  [7:0]  artwork_read_burstcnt,
	output logic [63:0] artwork_read_data,
	output logic        artwork_read_data_valid,

	output wire         reset_busy,         // High while processing a reset request and draining outstanding bursts.
	output wire         reset_busy_d        // Value captured by reset_busy on the next clk_sys edge.
);
import vfb_layout_pkg::*;

typedef enum logic [3:0] {
	ARB_IDLE,
	ARB_READOUT,
	ARB_FILL,
	ARB_FLUSH,
	ARB_COMPOSE_READ,
	ARB_COMPOSE_WRITE,
	ARB_PTX_READ,
	ARB_PTX_WRITE,
	ARB_UPLOAD_WRITE,
	ARB_ARTWORK_READ
} arb_state_t;

arb_state_t arb_state = ARB_IDLE;

localparam logic [8:0] SELECT_READOUT       = 9'b100000000;
localparam logic [8:0] SELECT_FLUSH         = 9'b010000000;
localparam logic [8:0] SELECT_FILL          = 9'b001000000;
localparam logic [8:0] SELECT_COMPOSE_READ  = 9'b000100000;
localparam logic [8:0] SELECT_COMPOSE_WRITE = 9'b000010000;
localparam logic [8:0] SELECT_PTX_READ      = 9'b000001000;
localparam logic [8:0] SELECT_PTX_WRITE     = 9'b000000100;
localparam logic [8:0] SELECT_UPLOAD_WRITE  = 9'b000000010;
localparam logic [8:0] SELECT_ARTWORK_READ  = 9'b000000001;

(* keep *) logic [8:0] arb_select;
logic [8:0]  arb_select_q   = '0;
logic [28:0] arb_addr_q     = '0;
logic [7:0]  arb_burstcnt_q = '0;
logic [8:0]  arb_target_q   = '0;
always_comb begin
	arb_select = '0;
	if (readout_ready)
		arb_select = SELECT_READOUT;
	else if (flush_ready)
		arb_select = SELECT_FLUSH;
	else if (fill_ready)
		arb_select = SELECT_FILL;
	else if (compose_read_ready)
		arb_select = SELECT_COMPOSE_READ;
	else if (compose_write_ready)
		arb_select = SELECT_COMPOSE_WRITE;
	else if (ptx_read_ready)
		arb_select = SELECT_PTX_READ;
	else if (ptx_write_ready)
		arb_select = SELECT_PTX_WRITE;
	else if (upload_write_ready)
		arb_select = SELECT_UPLOAD_WRITE;
	else if (artwork_read_ready)
		arb_select = SELECT_ARTWORK_READ;
end

logic [8:0] burst_counter = 0;
logic [8:0] burst_target  = 0;    // Latched burstcnt for drain tracking

// rst_sys is synchronous to clk_sys at this module boundary. Treat each
// assertion as one request and finish any active burst before resetting
// clients. A held reset may then admit artwork uploads for the next launch.
logic rst_sys_q = 1'b0;
always_ff @(posedge clk_sys) rst_sys_q <= rst_sys;
wire reset_start = rst_sys && !rst_sys_q;

logic reset_pending = 0;
wire  rst_active    = reset_start || reset_pending;
logic reset_busy_q  = 1'b1;
always_ff @(posedge clk_sys) reset_busy_q <= rst_active;
wire [8:0] arb_select_allowed = rst_sys ? (upload_write_ready ? SELECT_UPLOAD_WRITE : 9'd0)
                                        : arb_select;

// Sample the one-hot-selected payload independently; arb_select_q accepts it.
always_ff @(posedge clk_sys) begin
	unique case (1'b1)
		arb_select_allowed[8]: begin
			arb_addr_q     <= readout_addr;
			arb_burstcnt_q <= readout_burstcnt[7:0];
			arb_target_q   <= readout_burstcnt;
		end
		arb_select_allowed[7]: begin
			arb_addr_q     <= flush_addr;
			arb_burstcnt_q <= flush_burstcnt;
			arb_target_q   <= {1'b0, flush_burstcnt};
		end
		arb_select_allowed[6]: begin
			arb_addr_q     <= fill_addr;
			arb_burstcnt_q <= fill_burstcnt;
			arb_target_q   <= {1'b0, fill_burstcnt};
		end
		arb_select_allowed[5]: begin
			arb_addr_q     <= compose_read_addr;
			arb_burstcnt_q <= compose_read_burstcnt;
			arb_target_q   <= {1'b0, compose_read_burstcnt};
		end
		arb_select_allowed[4]: begin
			arb_addr_q     <= compose_write_addr;
			arb_burstcnt_q <= compose_write_burstcnt;
			arb_target_q   <= {1'b0, compose_write_burstcnt};
		end
		arb_select_allowed[3]: begin
			arb_addr_q     <= ptx_read_addr;
			arb_burstcnt_q <= ptx_read_burstcnt;
			arb_target_q   <= {1'b0, ptx_read_burstcnt};
		end
		arb_select_allowed[2]: begin
			arb_addr_q     <= ptx_write_addr;
			arb_burstcnt_q <= ptx_write_burstcnt;
			arb_target_q   <= {1'b0, ptx_write_burstcnt};
		end
		arb_select_allowed[1]: begin
			arb_addr_q     <= upload_write_addr;
			arb_burstcnt_q <= upload_write_burstcnt;
			arb_target_q   <= {1'b0, upload_write_burstcnt};
		end
		arb_select_allowed[0]: begin
			arb_addr_q     <= artwork_read_addr;
			arb_burstcnt_q <= artwork_read_burstcnt;
			arb_target_q   <= {1'b0, artwork_read_burstcnt};
		end
		default: begin end
	endcase
end

// Registered DDRAM read and write requests.
logic internal_rd = 0;
logic internal_we = 0;
logic discard_q = 1'b0;

// Check the burst length and address range before issuing a DDRAM request.
wire request_artwork = arb_select_q[1] || arb_select_q[0];
wire request_ptx = arb_select_q[3] || arb_select_q[2];
wire        request_has_beats = arb_target_q != 9'd0;
wire [29:0] request_last = {1'b0, arb_addr_q} +
	{21'd0, arb_target_q} - 30'd1;
wire request_safe = request_has_beats &&
	(request_ptx
		? ((arb_addr_q >= VFB_PITREX_BASE) &&
		   (request_last <= {1'b0, VFB_PITREX_LAST}))
	: request_artwork
		? ((arb_addr_q >= VFB_ARTWORK_BASE) &&
		   (request_last <= {1'b0, VFB_ARTWORK_LAST}))
		: ((arb_addr_q >= VFB_FRAMEBUFFER_BASE) &&
		   (request_last <= {1'b0, VFB_FRAMEBUFFER_LAST})));

assign DDRAM_WE = internal_we && !discard_q;
assign DDRAM_RD = internal_rd && !discard_q;
wire        read_command_accepted = DDRAM_RD && !DDRAM_BUSY;
wire        read_beat = discard_q || DDRAM_DOUT_READY;
wire        write_beat = discard_q || (DDRAM_WE && !DDRAM_BUSY);
wire [63:0] read_beat_data = discard_q ? 64'd0 : DDRAM_DOUT;

assign DDRAM_DIN =
	(arb_state == ARB_FLUSH) ? flush_din :
	(arb_state == ARB_COMPOSE_WRITE) ? compose_write_data :
	(arb_state == ARB_UPLOAD_WRITE) ? upload_write_data :
	(arb_state == ARB_PTX_WRITE) ? ptx_write_data :
	64'd0;
assign DDRAM_BE =
	(arb_state == ARB_FLUSH) ? flush_be :
	(arb_state == ARB_COMPOSE_WRITE) ? compose_write_be :
	(arb_state == ARB_UPLOAD_WRITE) ? upload_write_be :
	(arb_state == ARB_PTX_WRITE) ? ptx_write_be :
	8'h00;

assign flush_advance         = (arb_state == ARB_FLUSH) && write_beat;
assign compose_write_advance = (arb_state == ARB_COMPOSE_WRITE) &&
	write_beat;
assign upload_write_advance = (arb_state == ARB_UPLOAD_WRITE) &&
	write_beat;
assign ptx_write_advance = (arb_state == ARB_PTX_WRITE) && write_beat;
assign reset_busy = reset_busy_q;
assign reset_busy_d = rst_active;

// The valid pulse qualifies return data; discarded requests return zero locally.
always_ff @(posedge clk_sys) begin
	artwork_read_data <= DDRAM_DOUT;
	if (discard_q) artwork_read_data <= 64'd0;
end

always_ff @(posedge clk_sys) begin
	// Allow artwork uploads after outstanding bursts drain, even while
	// game reset remains asserted.
	if (reset_start) begin
		if (arb_state != ARB_IDLE) reset_pending <= 1;
	end else if (arb_state == ARB_IDLE) begin
		reset_pending <= 0;
	end

	readout_grant           <= 0;
	fill_grant              <= 0;
	flush_grant             <= 0;
	flush_done              <= 0;
	compose_read_grant      <= 0;
	compose_write_grant     <= 0;
	compose_write_done      <= 0;
	upload_write_done       <= 0;
	artwork_read_grant      <= 0;
	ptx_read_grant          <= 0;
	ptx_write_grant         <= 0;
	ptx_write_done          <= 0;
	ptx_read_data_valid     <= 0;
	readout_data_valid      <= 0;
	fill_data_valid         <= 0;
	compose_read_data_valid <= 0;
	artwork_read_data_valid <= 0;

	case (arb_state)
		ARB_IDLE: begin
			burst_counter <= 0;
			internal_rd   <= 1'b0;
			internal_we   <= 1'b0;
			discard_q     <= 1'b0;

			if (rst_active) begin
				arb_select_q <= '0;
			end else if (arb_select_q != '0) begin
				// Issue only registered requests so client priority and address
				// generation are outside the DDRAM request path.
				DDRAM_ADDR     <= arb_addr_q;
				DDRAM_BURSTCNT <= arb_burstcnt_q;
				burst_target   <= request_has_beats ? arb_target_q : 9'd1;
				discard_q      <= !request_safe;
				unique case (1'b1)
				arb_select_q[8]: begin
					arb_state     <= ARB_READOUT;
					internal_rd   <= request_safe;
					readout_grant <= 1;
				end
				arb_select_q[7]: begin
					arb_state   <= ARB_FLUSH;
					internal_we <= request_safe;
					flush_grant <= 1;
				end
				arb_select_q[6]: begin
					arb_state   <= ARB_FILL;
					internal_rd <= request_safe;
					fill_grant  <= 1;
				end
				arb_select_q[5]: begin
					arb_state          <= ARB_COMPOSE_READ;
					internal_rd        <= request_safe;
					compose_read_grant <= 1;
				end
				arb_select_q[4]: begin
					arb_state           <= ARB_COMPOSE_WRITE;
					internal_we         <= request_safe;
					compose_write_grant <= 1;
				end
				arb_select_q[3]: begin
					arb_state      <= ARB_PTX_READ;
					internal_rd    <= request_safe;
					ptx_read_grant <= 1;
				end
				arb_select_q[2]: begin
					arb_state       <= ARB_PTX_WRITE;
					internal_we     <= request_safe;
					ptx_write_grant <= 1;
				end
				arb_select_q[1]: begin
					arb_state   <= ARB_UPLOAD_WRITE;
					internal_we <= request_safe;
				end
				arb_select_q[0]: begin
					arb_state          <= ARB_ARTWORK_READ;
					internal_rd        <= request_safe;
					artwork_read_grant <= 1;
				end
				default: begin end
				endcase
				arb_select_q <= '0;
			end else begin
				arb_select_q <= arb_select_allowed;
			end
		end

		ARB_READOUT: begin
			if (read_command_accepted) internal_rd <= 0;

			if (read_beat) begin
				if (!rst_active) begin
					readout_data       <= read_beat_data;
					readout_data_valid <= 1;
				end
				burst_counter <= burst_counter + 1'b1;
				if (burst_counter == burst_target - 1)
					arb_state <= ARB_IDLE;
			end
		end

		ARB_FILL: begin
			if (read_command_accepted) internal_rd <= 0;

			if (read_beat) begin
				if (!rst_active) begin
					fill_data       <= read_beat_data;
					fill_data_valid <= 1;
				end
				burst_counter <= burst_counter + 1'b1;
				if (burst_counter == burst_target - 1)
					arb_state <= ARB_IDLE;
			end
		end

		ARB_FLUSH: begin
			if (flush_advance) begin
				burst_counter <= burst_counter + 1'b1;

				if (burst_counter == burst_target - 1) begin
					internal_we <= 0;
					if (!rst_active) flush_done <= 1;
					arb_state <= ARB_IDLE;
				end
			end
		end

		ARB_COMPOSE_READ: begin
			if (read_command_accepted) internal_rd <= 0;

			if (read_beat) begin
				if (!rst_active) begin
					compose_read_data       <= read_beat_data;
					compose_read_data_valid <= 1;
				end
				burst_counter <= burst_counter + 1'b1;
				if (burst_counter == burst_target - 1'b1)
					arb_state <= ARB_IDLE;
			end
		end

		ARB_COMPOSE_WRITE: begin
			if (compose_write_advance) begin
				burst_counter <= burst_counter + 1'b1;
				if (burst_counter == burst_target - 1'b1) begin
					internal_we <= 0;
					if (!rst_active) compose_write_done <= 1;
					arb_state <= ARB_IDLE;
				end
			end
		end

		ARB_PTX_READ: begin
			if (read_command_accepted) internal_rd <= 0;

			if (read_beat) begin
				if (!rst_active) begin
					ptx_read_data       <= read_beat_data;
					ptx_read_data_valid <= 1;
				end
				burst_counter <= burst_counter + 1'b1;
				if (burst_counter == burst_target - 1'b1)
					arb_state <= ARB_IDLE;
			end
		end

		ARB_PTX_WRITE: begin
			if (ptx_write_advance) begin
				burst_counter <= burst_counter + 1'b1;
				if (burst_counter == burst_target - 1'b1) begin
					internal_we <= 0;
					if (!rst_active) ptx_write_done <= 1;
					arb_state <= ARB_IDLE;
				end
			end
		end

		ARB_UPLOAD_WRITE: begin
			if (upload_write_advance) begin
				burst_counter <= burst_counter + 1'b1;
				if (burst_counter == burst_target - 1'b1) begin
					internal_we <= 0;
					if (!rst_active) upload_write_done <= 1;
					arb_state <= ARB_IDLE;
				end
			end
		end

		ARB_ARTWORK_READ: begin
			if (read_command_accepted) internal_rd <= 0;

			if (read_beat) begin
				if (!rst_active) begin
					artwork_read_data_valid <= 1;
				end
				burst_counter <= burst_counter + 1'b1;
				if (burst_counter == burst_target - 1'b1)
					arb_state <= ARB_IDLE;
			end
		end

		default: begin
			arb_state               <= ARB_IDLE;
			arb_select_q            <= '0;
			reset_pending           <= 1'b0;
			internal_rd             <= 1'b0;
			internal_we             <= 1'b0;
			discard_q               <= 1'b0;
			burst_counter           <= '0;
			burst_target            <= '0;
			readout_data_valid      <= 1'b0;
			fill_data_valid         <= 1'b0;
			flush_done              <= 1'b0;
			compose_read_data_valid <= 1'b0;
			compose_write_done      <= 1'b0;
			upload_write_done       <= 1'b0;
			artwork_read_data_valid <= 1'b0;
			ptx_read_data_valid     <= 1'b0;
			ptx_write_done          <= 1'b0;
		end
	endcase
end

endmodule

`default_nettype wire
