// ============================================================================
// VART package upload, descriptor validation, and palette writes.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// ============================================================================

`default_nettype none

module vfb_vart_loader (
	input  wire         clk_sys,
	input  wire         clk_io,
	input  wire         upload_reset,
	input  wire         arbiter_ready,
	input  wire         ioctl_download,
	input  wire         ioctl_wr,
	input  wire [15:0]  ioctl_index,
	input  wire [24:0]  ioctl_addr,
	input  wire [7:0]   ioctl_data,
	output wire         ioctl_wait,
	output wire         artwork_valid,
	output wire         upload_reset_sys,
	output wire [vfb_layout_pkg::VFB_ARTWORK_PLANES-1:0] plane_valid,
	output vfb_layout_pkg::vfb_artwork_plane_t plane_info [0:vfb_layout_pkg::VFB_ARTWORK_PLANES-1],
	output wire         palette_write_enable,
	output wire [10:0]  palette_write_address,
	output wire [31:0]  palette_write_data,

	output wire         upload_write_ready,
	input  wire         upload_write_done,
	output wire [28:0]  upload_write_addr,
	output wire [7:0]   upload_write_burstcnt,
	output wire [63:0]  upload_write_data,
	output wire [7:0]   upload_write_be,
	input  wire         upload_write_advance
);

import vfb_layout_pkg::*;

localparam integer     MAX_PLANES         = VFB_ARTWORK_PLANES;
localparam integer     PALETTE_BYTES      = 8192;
localparam integer     PALETTE_WORDS      = PALETTE_BYTES / 4;
localparam integer     PALETTE_ADDR_W     = $clog2(PALETTE_WORDS);
localparam logic [7:0] PLANE_ROLE_OVERLAY = 8'd0;

typedef struct packed {
	logic        start;
	logic        finish;
	logic        has_data;
	logic [24:0] addr;
	logic [7:0]  data;
} upload_event_t;

typedef struct packed {
	logic [11:0] width;
	logic [11:0] height;
	logic [7:0]  layer;
	logic [7:0]  role;
	logic [7:0]  index_bits;
	logic [7:0]  flags;
	logic [15:0] palette_entries;
	logic [31:0] palette_offset;
	logic [31:0] palette_size;
	logic [31:0] payload_offset;
	logic [31:0] payload_size;
	logic [31:0] pixel_count;
	logic [31:0] row_count;
	logic [31:0] layout;
} plane_descriptor_t;

localparam integer UPLOAD_EVENT_W = $bits(upload_event_t);

function automatic [31:0] crc32_byte(
	input  logic [31:0] crc_in,
	input  logic [7:0]  data
);
	logic   [31:0] crc;
	integer        bit_index;
	begin
		crc = crc_in ^ {24'd0, data};
		for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
			crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
		crc32_byte = crc;
	end
endfunction

function automatic [5:0] descriptor_byte_offset(
	input  logic [24:0] address,
	input  integer      plane_index
);
	logic [24:0] offset;
	begin
		offset                 = address - 25'(64 + plane_index * 48);
		descriptor_byte_offset = offset[5:0];
	end
endfunction

function automatic logic valid_geometry(
	input  logic [11:0] width,
	input  logic [11:0] height,
	input  logic [31:0] pixel_count,
	input  logic [31:0] row_count
);
	begin
		// Each artwork plane covers the full framebuffer at one supported resolution.
		case ({width, height, pixel_count, row_count})
			{12'd1360, 12'd1080, 32'd1468800, 32'd1080},
			{12'd916,  12'd720,  32'd659520,  32'd720},
			{12'd720,  12'd480,  32'd345600,  32'd480},
			{12'd720,  12'd240,  32'd172800,  32'd240}: valid_geometry = 1'b1;
			default:                                    valid_geometry = 1'b0;
		endcase
	end
endfunction

// HPS holds game reset until boot files finish loading. Upload reset follows
// clock startup instead, with release synchronized in each clock domain.
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [1:0] upload_reset_io_pipe  = 2'b11;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [1:0] upload_reset_sys_pipe = 2'b11;
always_ff @(posedge clk_io or posedge upload_reset) begin
	if (upload_reset) upload_reset_io_pipe <= 2'b11;
	else              upload_reset_io_pipe <= {upload_reset_io_pipe[0], 1'b0};
end
always_ff @(posedge clk_sys or posedge upload_reset) begin
	if (upload_reset) upload_reset_sys_pipe <= 2'b11;
	else              upload_reset_sys_pipe <= {upload_reset_sys_pipe[0], 1'b0};
end
wire   upload_reset_io  = upload_reset_io_pipe[1];
assign upload_reset_sys = upload_reset_sys_pipe[1];

// Accept manual F2 uploads, companion art files (bits 9:8 = 1), and boot2.rom
// (index 0x0080). All three use the same ART package format.
wire           upload_active        = ioctl_download &&
                                      ((ioctl_index[4:0] == 5'd2) ||
                                       (ioctl_index[9:8] == 2'b01) ||
                                       (ioctl_index == 16'h0080));
logic          upload_active_q      = 1'b0;
logic          upload_start_pending = 1'b0;
logic          upload_end_pending   = 1'b0;
logic          upload_fifo_wr;
upload_event_t upload_fifo_wdata;
wire           upload_fifo_full;
wire           upload_fifo_almost_full;
wire           upload_rise           = upload_active && !upload_active_q;
wire           upload_fall           = !upload_active && upload_active_q;
logic          arbiter_ready_io_meta = 1'b0;
logic          arbiter_ready_io      = 1'b0;

assign ioctl_wait = upload_active && (!arbiter_ready_io || upload_fifo_almost_full);

always_ff @(posedge clk_io) begin
	if (upload_reset_io) begin
		arbiter_ready_io_meta <= 1'b0;
		arbiter_ready_io      <= 1'b0;
	end else begin
		arbiter_ready_io_meta <= arbiter_ready;
		arbiter_ready_io      <= arbiter_ready_io_meta;
	end
end

always_comb begin
	upload_fifo_wr    = 1'b0;
	upload_fifo_wdata =   '0;

	if (upload_active && ioctl_wr) begin
		upload_fifo_wr             = 1'b1;
		upload_fifo_wdata.start    = upload_start_pending || upload_rise;
		upload_fifo_wdata.has_data = 1'b1;
		upload_fifo_wdata.addr     = ioctl_addr;
		upload_fifo_wdata.data     = ioctl_data;
	end else if (upload_start_pending || upload_rise) begin
		upload_fifo_wr          = 1'b1;
		upload_fifo_wdata.start = 1'b1;
	end else if (upload_end_pending || upload_fall) begin
		upload_fifo_wr           = 1'b1;
		upload_fifo_wdata.finish = 1'b1;
	end
end

always_ff @(posedge clk_io) begin
	if (upload_reset_io) begin
		upload_active_q      <= 1'b0;
		upload_start_pending <= 1'b0;
		upload_end_pending   <= 1'b0;
	end else begin
		upload_active_q <= upload_active;

		if (upload_rise) upload_start_pending <= 1'b1;
		if (upload_fall) upload_end_pending   <= 1'b1;

		if (upload_fifo_wr && !upload_fifo_full) begin
			if (upload_active && ioctl_wr) begin
				upload_start_pending <= 1'b0;
			end else if (upload_start_pending || upload_rise) begin
				upload_start_pending <= 1'b0;
			end else if (upload_end_pending || upload_fall) begin
				upload_end_pending <= 1'b0;
			end
		end
	end
end

logic          upload_fifo_rd = 1'b0;
upload_event_t upload_fifo_rdata;
wire           upload_fifo_rd_valid;
wire           upload_fifo_empty;
upload_event_t upload_event_q;
logic          upload_event_valid = 1'b0;
logic [7:0]    upload_byte_lane_q;

logic [MAX_PLANES-1:0] descriptor_match_q;
logic [5:0]            descriptor_byte_q;

vfb_async_fifo #(
	.WIDTH             (UPLOAD_EVENT_W),
	.DEPTH             (64),
	.ALMOST_FULL_MARGIN(2)
) upload_fifo (
	.wr_clk        (clk_io),
	.wr_reset      (upload_reset_io),
	.wr_en         (upload_fifo_wr),
	.wr_data       (upload_fifo_wdata),
	.wr_full       (upload_fifo_full),
	.wr_almost_full(upload_fifo_almost_full),
	.rd_clk        (clk_sys),
	.rd_reset      (upload_reset_sys),
	.rd_en         (upload_fifo_rd),
	.rd_data       (upload_fifo_rdata),
	.rd_valid      (upload_fifo_rd_valid),
	.rd_empty      (upload_fifo_empty)
);

// Decode byte and descriptor positions alongside the event payload.
always_ff @(posedge clk_sys) begin
	if (upload_reset_sys) begin
		upload_event_q     <=   '0;
		upload_event_valid <= 1'b0;
		upload_byte_lane_q <= 8'd0;
		descriptor_match_q <=   '0;
		descriptor_byte_q  <= 6'd0;
	end else if (upload_fifo_rd_valid) begin
		upload_event_q     <= upload_fifo_rdata;
		upload_event_valid <= 1'b1;
		upload_byte_lane_q <= 8'b1 << upload_fifo_rdata.addr[2:0];
		descriptor_match_q <= '0;
		for (integer index = 0; index < MAX_PLANES; index = index + 1) begin
			if ((upload_fifo_rdata.addr >= 25'(64 + index * 48)) &&
				(upload_fifo_rdata.addr < 25'(112 + index * 48))) begin
				descriptor_match_q[index] <= 1'b1;
				descriptor_byte_q         <= descriptor_byte_offset(upload_fifo_rdata.addr, index);
			end
		end
	end else if (upload_event_valid) begin
		upload_event_valid <= 1'b0;
	end
end

// ------------------------------------------------------------------------
// VART upload, metadata, and palette capture
// ------------------------------------------------------------------------

logic         package_valid         = 1'b0;
assign        artwork_valid         = package_valid;
logic         upload_in_progress    =         1'b0;
logic         upload_event_pending  =         1'b0;
logic         upload_finalize       =         1'b0;
logic  [1:0] upload_validate       =         2'b00;
logic         upload_final_write    =         1'b0;
logic         upload_error          =         1'b0;
logic  [24:0] upload_expected_addr  =        25'd0;
logic  [31:0] upload_received_bytes =        32'd0;
logic  [31:0] upload_crc            = 32'hffffffff;
logic  [63:0] upload_pack_data      =        64'd0;
logic  [7:0]  upload_pack_be        =         8'd0;
logic         upload_qword_pending  =         1'b0;
logic  [28:0] upload_qword_addr     = VFB_ARTWORK_BASE;
logic  [63:0] upload_qword_data     = 64'd0;
logic  [7:0]  upload_qword_be       =  8'd0;

logic [7:0]  vart_layer_count       =  8'd0;
logic [7:0]  vart_plane_count       =  8'd0;
logic [31:0] vart_total_size        = 32'd0;
logic [31:0] vart_expected_crc      = 32'd0;
logic [31:0] vart_descriptor_offset = 32'd0;
logic [15:0] vart_descriptor_size   = 16'd0;

plane_descriptor_t plane [0:MAX_PLANES-1];

logic [23:0] palette_upload_rgb = 24'd0;

always_ff @(posedge clk_sys) begin
	if (upload_reset_sys || (upload_event_valid && upload_event_q.start)) begin
		palette_upload_rgb <= 24'd0;
	end else if (upload_event_valid && upload_event_q.has_data &&
		upload_in_progress && (upload_event_q.addr < PALETTE_BYTES)) begin
		case (upload_event_q.addr[1:0])
			2'd0:    palette_upload_rgb[7:0]   <= upload_event_q.data;
			2'd1:    palette_upload_rgb[15:8]  <= upload_event_q.data;
			2'd2:    palette_upload_rgb[23:16] <= upload_event_q.data;
			default: ;
		endcase
	end
end

logic                        metadata_global_valid_q = 1'b0;
logic  [MAX_PLANES-1:0][3:0] metadata_plane_checks_q =   '0;
wire   [MAX_PLANES-1:0]      metadata_plane_valid_q;
logic  [MAX_PLANES-1:0]      metadata_plane_declared_q =   '0;
logic                        metadata_valid            = 1'b0;
logic  [32:0]                payload_end_q [0:MAX_PLANES-1];
logic  [32:0]                palette_end_q [0:MAX_PLANES-1];
genvar                       metadata_plane;
generate
	for (metadata_plane = 0; metadata_plane < MAX_PLANES;
		metadata_plane = metadata_plane + 1) begin : metadata_checks
		assign metadata_plane_valid_q[metadata_plane] = &metadata_plane_checks_q[metadata_plane];
		assign plane_valid[metadata_plane]            = (metadata_plane < vart_plane_count) &&
		                                                metadata_plane_valid_q[metadata_plane] &&
		                                                (plane[metadata_plane].role ==
		                                                 PLANE_ROLE_OVERLAY);
		assign plane_info[metadata_plane] = '{
			width:          plane[metadata_plane].width,
			height:         plane[metadata_plane].height,
			index_bits:     plane[metadata_plane].index_bits,
			palette_offset: plane[metadata_plane].palette_offset,
			payload_offset: plane[metadata_plane].payload_offset,
			payload_size:   plane[metadata_plane].payload_size
		};
	end
endgenerate

integer metadata_index;
always_ff @(posedge clk_sys) begin
	metadata_global_valid_q <=
	    !upload_error
	    && (vart_layer_count == 8'd1)
	    && (vart_plane_count == 8'd4)
	    && (vart_descriptor_offset == 32'd64)
	    && (vart_descriptor_size == 16'd48)
	    && (vart_total_size >= (32'd64 + ({24'd0, vart_plane_count} * 32'd48)))
	    && (vart_total_size <= 32'd4194304)
	    && ((({3'd0, vart_total_size} + 35'd7) >> 3) <=
	        ({6'd0, VFB_ARTWORK_LAST} - {6'd0, VFB_ARTWORK_BASE} + 1'b1))
	    && (upload_received_bytes == vart_total_size)
	    && ((~upload_crc) == vart_expected_crc);

	for (metadata_index = 0;
		metadata_index < MAX_PLANES;
		metadata_index = metadata_index + 1) begin
		metadata_plane_declared_q[metadata_index] <= (metadata_index < vart_plane_count);
		payload_end_q[metadata_index] <= {1'b0, plane[metadata_index].payload_offset} +
		                                 {1'b0, plane[metadata_index].payload_size};
		palette_end_q[metadata_index] <= {1'b0, plane[metadata_index].palette_offset} +
		                                 {1'b0, plane[metadata_index].palette_size};
		// Register descriptor checks before reducing to plane validity.
		metadata_plane_checks_q[metadata_index][0] <=
		    valid_geometry(plane[metadata_index].width, plane[metadata_index].height,
		                   plane[metadata_index].pixel_count, plane[metadata_index].row_count);
		metadata_plane_checks_q[metadata_index][1] <=
		    (plane[metadata_index].layer == 8'd0)
		    && (plane[metadata_index].role == PLANE_ROLE_OVERLAY)
		    && ((plane[metadata_index].index_bits == 8'd4) ||
		        (plane[metadata_index].index_bits == 8'd6) ||
		        (plane[metadata_index].index_bits == 8'd8))
		    && ((plane[metadata_index].flags & 8'hfc) == 8'd0)
		    && plane[metadata_index].flags[0]
		    && (plane[metadata_index].palette_entries ==
		        (16'd1 << plane[metadata_index].index_bits))
		    && (plane[metadata_index].layout == 32'd0);
		metadata_plane_checks_q[metadata_index][2] <=
		    (plane[metadata_index].palette_size ==
		     ({16'd0, plane[metadata_index].palette_entries} << 2)) &&
		    (plane[metadata_index].palette_offset[2:0] == 3'd0) &&
		    (palette_end_q[metadata_index] <= 33'(PALETTE_BYTES)) &&
		    (palette_end_q[metadata_index] <= {1'b0, vart_total_size});
		metadata_plane_checks_q[metadata_index][3] <=
		    (plane[metadata_index].payload_offset[2:0] == 3'd0) &&
		    (plane[metadata_index].payload_size[2:0] == 3'd0) &&
		    (plane[metadata_index].payload_size != 32'd0) &&
		    (payload_end_q[metadata_index] <= {1'b0, vart_total_size});
	end

	metadata_valid <= metadata_global_valid_q &&
	                  |(metadata_plane_valid_q & metadata_plane_declared_q);
end

assign upload_write_ready    = upload_qword_pending;
assign upload_write_addr     = upload_qword_addr;
assign upload_write_burstcnt = 8'd1;
assign upload_write_data     = upload_qword_data;
assign upload_write_be       = upload_qword_be;

integer upload_clear_index;
integer descriptor_index;
always_ff @(posedge clk_sys) begin
	upload_fifo_rd <= 1'b0;

	if (upload_reset_sys) begin
		upload_in_progress   <=  1'b0;
		upload_event_pending <=  1'b0;
		upload_finalize      <=  1'b0;
		upload_validate      <= 2'b00;
		upload_final_write   <=  1'b0;
		upload_qword_pending <=  1'b0;
		upload_pack_data     <= 64'd0;
		upload_pack_be       <=  8'd0;
	end else begin
		upload_validate <= {upload_validate[0], 1'b0};
		if (upload_write_advance) upload_qword_pending <= 1'b0;

		if (arbiter_ready && !upload_event_pending &&
			!upload_fifo_empty && !upload_qword_pending &&
			!upload_finalize && !upload_validate) begin
			upload_fifo_rd       <= 1'b1;
			upload_event_pending <= 1'b1;
		end

		if (upload_event_valid) begin
			logic [63:0] next_pack_data;
			logic [7:0]  next_pack_be;
			logic [31:0] crc_base;

			upload_event_pending <= 1'b0;

			if (upload_event_q.start) begin
				package_valid          <=         1'b0;
				upload_in_progress     <=         1'b1;
				upload_finalize        <=         1'b0;
				upload_validate        <=        2'b00;
				upload_final_write     <=         1'b0;
				upload_error           <=         1'b0;
				upload_expected_addr   <=        25'd0;
				upload_received_bytes  <=        32'd0;
				upload_crc             <= 32'hffffffff;
				upload_pack_data       <=        64'd0;
				upload_pack_be         <=         8'd0;
				vart_layer_count       <=         8'd0;
				vart_plane_count       <=         8'd0;
				vart_total_size        <=        32'd0;
				vart_expected_crc      <=        32'd0;
				vart_descriptor_offset <=        32'd0;
				vart_descriptor_size   <=        16'd0;
				for (upload_clear_index = 0;
					upload_clear_index < MAX_PLANES;
					upload_clear_index = upload_clear_index + 1) begin
					plane[upload_clear_index] <= '0;
				end
			end

			if (upload_event_q.has_data && (upload_in_progress || upload_event_q.start)) begin
				next_pack_data = upload_event_q.start ? 64'd0 : upload_pack_data;
				next_pack_be   = upload_event_q.start ? 8'd0 : upload_pack_be;
				crc_base       = upload_event_q.start ? 32'hffffffff : upload_crc;

				if (upload_event_q.addr != (upload_event_q.start ? 25'd0 : upload_expected_addr))
					upload_error <= 1'b1;
				upload_expected_addr  <= upload_event_q.addr + 1'b1;
				upload_received_bytes <= (upload_event_q.start ? 32'd0 : upload_received_bytes) +
				                         1'b1;

				for (integer lane = 0; lane < 8; lane = lane + 1) begin
					if (upload_byte_lane_q[lane]) begin
						next_pack_data[lane * 8 +: 8] = upload_event_q.data;
						next_pack_be[lane]            = 1'b1;
					end
				end
				if (upload_byte_lane_q[7]) begin
					// Reject data beyond the reserved artwork window.
					upload_qword_pending <= (VFB_ARTWORK_BASE +
					                         {7'd0, upload_event_q.addr[24:3]}) <= VFB_ARTWORK_LAST;
					upload_qword_addr    <= VFB_ARTWORK_BASE + {7'd0, upload_event_q.addr[24:3]};
					upload_qword_data    <= next_pack_data;
					upload_qword_be      <= next_pack_be;
					upload_pack_data     <= 64'd0;
					upload_pack_be       <=  8'd0;
				end else begin
					upload_pack_data <= next_pack_data;
					upload_pack_be   <= next_pack_be;
				end

				if (upload_event_q.addr >= 25'd64)
					upload_crc <= crc32_byte(crc_base, upload_event_q.data);

				case (upload_event_q.addr)
					25'd0:  if (upload_event_q.data != 8'h56) upload_error <= 1'b1;
					25'd1:  if (upload_event_q.data != 8'h41) upload_error <= 1'b1;
					25'd2:  if (upload_event_q.data != 8'h52) upload_error <= 1'b1;
					25'd3:  if (upload_event_q.data != 8'h54) upload_error <= 1'b1;
					25'd4:  if (upload_event_q.data != 8'd1) upload_error <= 1'b1;
					25'd5:  if (upload_event_q.data != 8'd0) upload_error <= 1'b1;
					25'd6:  vart_layer_count              <= upload_event_q.data;
					25'd7:  vart_plane_count              <= upload_event_q.data;
					25'd8:  vart_total_size[7:0]          <= upload_event_q.data;
					25'd9:  vart_total_size[15:8]         <= upload_event_q.data;
					25'd10: vart_total_size[23:16]        <= upload_event_q.data;
					25'd11: vart_total_size[31:24]        <= upload_event_q.data;
					25'd12: vart_expected_crc[7:0]        <= upload_event_q.data;
					25'd13: vart_expected_crc[15:8]       <= upload_event_q.data;
					25'd14: vart_expected_crc[23:16]      <= upload_event_q.data;
					25'd15: vart_expected_crc[31:24]      <= upload_event_q.data;
					25'd16: vart_descriptor_offset[7:0]   <= upload_event_q.data;
					25'd17: vart_descriptor_offset[15:8]  <= upload_event_q.data;
					25'd18: vart_descriptor_offset[23:16] <= upload_event_q.data;
					25'd19: vart_descriptor_offset[31:24] <= upload_event_q.data;
					25'd20: vart_descriptor_size[7:0]     <= upload_event_q.data;
					25'd21: vart_descriptor_size[15:8]    <= upload_event_q.data;
					default:
						if ((upload_event_q.addr >= 25'd22) &&
							(upload_event_q.addr < 25'd64) &&
							(upload_event_q.data != 8'd0))
							upload_error <= 1'b1;
				endcase

				for (descriptor_index = 0;
					descriptor_index < MAX_PLANES;
					descriptor_index = descriptor_index + 1) begin
					if ((descriptor_index < vart_plane_count) && descriptor_match_q[descriptor_index]) begin
						case (descriptor_byte_q)
							0:  plane[descriptor_index].width[7:0] <= upload_event_q.data;
							1:  begin
								plane[descriptor_index].width[11:8] <= upload_event_q.data[3:0];
								if (upload_event_q.data[7:4] != 4'd0) upload_error <= 1'b1;
							end
							2:  plane[descriptor_index].height[7:0] <= upload_event_q.data;
							3:  begin
								plane[descriptor_index].height[11:8] <= upload_event_q.data[3:0];
								if (upload_event_q.data[7:4] != 4'd0) upload_error <= 1'b1;
							end
							4:  plane[descriptor_index].layer                 <= upload_event_q.data;
							5:  plane[descriptor_index].role                  <= upload_event_q.data;
							6:  plane[descriptor_index].index_bits            <= upload_event_q.data;
							7:  plane[descriptor_index].flags                 <= upload_event_q.data;
							8:  plane[descriptor_index].palette_entries[7:0]  <= upload_event_q.data;
							9:  plane[descriptor_index].palette_entries[15:8] <= upload_event_q.data;
							12: plane[descriptor_index].palette_offset[7:0]   <= upload_event_q.data;
							13: plane[descriptor_index].palette_offset[15:8]  <= upload_event_q.data;
							14: plane[descriptor_index].palette_offset[23:16] <= upload_event_q.data;
							15: plane[descriptor_index].palette_offset[31:24] <= upload_event_q.data;
							16: plane[descriptor_index].palette_size[7:0]     <= upload_event_q.data;
							17: plane[descriptor_index].palette_size[15:8]    <= upload_event_q.data;
							18: plane[descriptor_index].palette_size[23:16]   <= upload_event_q.data;
							19: plane[descriptor_index].palette_size[31:24]   <= upload_event_q.data;
							20: plane[descriptor_index].payload_offset[7:0]   <= upload_event_q.data;
							21: plane[descriptor_index].payload_offset[15:8]  <= upload_event_q.data;
							22: plane[descriptor_index].payload_offset[23:16] <= upload_event_q.data;
							23: plane[descriptor_index].payload_offset[31:24] <= upload_event_q.data;
							24: plane[descriptor_index].payload_size[7:0]     <= upload_event_q.data;
							25: plane[descriptor_index].payload_size[15:8]    <= upload_event_q.data;
							26: plane[descriptor_index].payload_size[23:16]   <= upload_event_q.data;
							27: plane[descriptor_index].payload_size[31:24]   <= upload_event_q.data;
							28: plane[descriptor_index].pixel_count[7:0]      <= upload_event_q.data;
							29: plane[descriptor_index].pixel_count[15:8]     <= upload_event_q.data;
							30: plane[descriptor_index].pixel_count[23:16]    <= upload_event_q.data;
							31: plane[descriptor_index].pixel_count[31:24]    <= upload_event_q.data;
							32: plane[descriptor_index].row_count[7:0]        <= upload_event_q.data;
							33: plane[descriptor_index].row_count[15:8]       <= upload_event_q.data;
							34: plane[descriptor_index].row_count[23:16]      <= upload_event_q.data;
							35: plane[descriptor_index].row_count[31:24]      <= upload_event_q.data;
							36: plane[descriptor_index].layout[7:0]           <= upload_event_q.data;
							37: plane[descriptor_index].layout[15:8]          <= upload_event_q.data;
							38: plane[descriptor_index].layout[23:16]         <= upload_event_q.data;
							39: plane[descriptor_index].layout[31:24]         <= upload_event_q.data;
							10, 11, 40, 41, 42, 43, 44, 45, 46, 47:
								if (upload_event_q.data != 8'd0) upload_error <= 1'b1;
							default: ;
						endcase
					end
				end
			end

			if (upload_event_q.finish && upload_in_progress) begin
				upload_finalize    <= 1'b1;
				upload_final_write <= (upload_pack_be != 8'd0) &&
				    ((VFB_ARTWORK_BASE + {7'd0, upload_expected_addr[24:3]}) <= VFB_ARTWORK_LAST);
				if ((upload_pack_be != 8'd0) &&
					((VFB_ARTWORK_BASE + {7'd0, upload_expected_addr[24:3]})
						<= VFB_ARTWORK_LAST)) begin
					upload_qword_pending <= 1'b1;
					upload_qword_addr    <= VFB_ARTWORK_BASE + {7'd0, upload_expected_addr[24:3]};
					upload_qword_data    <= upload_pack_data;
					upload_qword_be      <= upload_pack_be;
					upload_pack_data     <= 64'd0;
					upload_pack_be       <=  8'd0;
				end
			end
		end

		if (upload_finalize &&
			(!upload_final_write || upload_write_done)) begin
			upload_finalize    <= 1'b0;
			// Allow end-address sums, descriptor checks and validity reduction to settle.
			upload_validate    <= 2'b01;
			upload_final_write <= 1'b0;
		end

		if (upload_validate[1]) begin
			package_valid      <= metadata_valid;
			upload_in_progress <= 1'b0;
		end
	end
end

assign palette_write_enable  =
    !upload_reset_sys
    && upload_event_valid
    && !upload_event_q.start
    && upload_event_q.has_data
    && upload_in_progress
    && (upload_event_q.addr < PALETTE_BYTES)
    && (&upload_event_q.addr[1:0]);
assign palette_write_address = upload_event_q.addr[PALETTE_ADDR_W+1:2];
assign palette_write_data    = {upload_event_q.data, palette_upload_rgb};

endmodule

`default_nettype wire
