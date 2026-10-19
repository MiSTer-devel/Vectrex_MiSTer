// ============================================================================
// RLE-compressed scanline delay in the MiSTer SDRAM.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Twelve-bit beam-energy samples are encoded into independent 8 KiB line slots. Readout
// follows the current horizontal timing and uses timing from the matching line.
// ============================================================================

`default_nettype none

module vfb_sdram_delay #(
	parameter integer SDRAM_MHZ  = 125,
	parameter integer SLOT_COUNT = 128,
	parameter integer FIFO_DEPTH = 256,
	parameter integer READ_FIFO_DEPTH = 512
) (
	input  wire         clk_sys,
	input  wire         reset,
	input  wire         ce_pix,
	input  wire  [11:0] line_delay,

	input  wire  [11:0] CANONICAL_IN,
	input  wire         VGA_HS_IN,
	input  wire         VGA_VS_IN,
	input  wire         VGA_HBLANK_IN,
	input  wire         VGA_VBLANK_IN,

	output logic [11:0] CANONICAL_OUT,
	output logic        VGA_HS_OUT,
	output logic        VGA_VS_OUT,
	output logic        VGA_HBLANK_OUT,
	output logic        VGA_VBLANK_OUT,

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
	output logic [1:0]  sdram_ba,

	output logic overflow,
	output logic underflow,
	output logic init_done
);

// One compressed scanline occupies an 8 KiB slot in SDRAM.
localparam integer SLOT_BYTE_SHIFT = 13;
localparam integer SLOT_BYTES      = 1 << SLOT_BYTE_SHIFT;
localparam integer SLOT_W          = $clog2(SLOT_COUNT);
localparam integer FIFO_AW         = $clog2(FIFO_DEPTH);
localparam integer RD_FIFO_AW      = $clog2(READ_FIFO_DEPTH);
localparam integer MAX_WORDS       = SLOT_BYTES / 2;
localparam integer MAX_PAIRS       = SLOT_BYTES / 4;
localparam integer WORD_W          = $clog2(MAX_WORDS);
localparam integer PAIR_W          = $clog2(MAX_PAIRS);
// READ_FIFO_DEPTH counts 16-bit codec words; storage holds half as many
// 32-bit SDRAM response entries.
localparam integer RD_PAIR_FIFO_DEPTH = READ_FIFO_DEPTH / 2;
localparam integer RD_PAIR_FIFO_AW    = $clog2(RD_PAIR_FIFO_DEPTH);
localparam integer RD_FIFO_W          = 34;
localparam integer RD_DESC_DEPTH      = 4;
localparam integer RD_DESC_AW         = $clog2(RD_DESC_DEPTH);
localparam [5:0]   ARB_QUOTA          = 6'd32;
localparam integer WR_URGENT_LEVEL    = (FIFO_DEPTH > 128) ? (FIFO_DEPTH - 64) : (FIFO_DEPTH - 8);
localparam integer RD_URGENT_LEVEL    = (RD_PAIR_FIFO_DEPTH > 128) ? 64 : (RD_PAIR_FIFO_DEPTH / 4);
localparam integer WR_READY_MARGIN    = (FIFO_DEPTH > 16) ? 8 : (FIFO_DEPTH > 8) ? 4 : 1;

typedef struct packed {
	logic              eol;
	logic [SLOT_W-1:0] slot;
	logic [PAIR_W-1:0] index;
	logic [31:0]       data;
} wr_pair_t;

localparam integer WR_FIFO_W = $bits(wr_pair_t);

typedef struct packed {
	logic              valid;
	logic [15:0]       word;
	logic [PAIR_W-1:0] pair_index;
	logic [SLOT_W-1:0] slot;
} packed_word_t;

typedef struct packed {
	logic     valid;
	wr_pair_t pair;
} wr_head_t;

typedef struct packed {
	logic [WORD_W:0] words;
	logic            vsync;
	logic            vblank;
	logic            valid;
	logic            written;
} line_desc_t;

typedef struct packed {
	logic              pending;
	logic [SLOT_W-1:0] slot;
	logic              vsync;
	logic              vblank;
} line_finalize_t;

typedef struct packed {
	logic              pending;
	logic              warmed;
	logic [SLOT_W-1:0] slot;
} desc_lookup_t;

typedef struct packed {
	logic              pending;
	logic              warmed;
	logic [SLOT_W-1:0] slot;
	line_desc_t        line;
} desc_apply_t;

typedef struct packed {
	logic valid;
	logic vsync;
	logic vblank;
} line_status_t;
localparam line_status_t BLANK_LINE_STATUS = {1'b0, 1'b1, 1'b1};

typedef struct packed {
	logic [SLOT_W-1:0] slot;
	logic [WORD_W:0]   words;
} rd_desc_t;

typedef struct packed {
	logic              valid;
	logic              wr;
	logic [31:0]       addr;
	logic [31:0]       wdata;
	logic              wr_eol;
	logic [SLOT_W-1:0] wr_slot;
	logic              rd_more;
} mem_req_t;

initial begin
	if (SLOT_COUNT < 2 || SLOT_COUNT > 4096 || (SLOT_COUNT & (SLOT_COUNT - 1)) != 0)
		$error("vfb_sdram_delay SLOT_COUNT must be a power of two between 2 and 4096");
	if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0)
		$error("vfb_sdram_delay FIFO_DEPTH must be a power of two");
	if ((READ_FIFO_DEPTH & (READ_FIFO_DEPTH - 1)) != 0)
		$error("vfb_sdram_delay READ_FIFO_DEPTH must be a power of two");
	if (READ_FIFO_DEPTH < 4)
		$error("vfb_sdram_delay READ_FIFO_DEPTH must be at least four");
	if ((RD_DESC_DEPTH & (RD_DESC_DEPTH - 1)) != 0)
		$error("vfb_sdram_delay RD_DESC_DEPTH must be a power of two");
end

// Derive line_start and line_end from horizontal-blanking transitions.
// Encode the 12-bit beam-energy samples during active video.
logic              hblank_d;
logic              line_had_pixels;
logic              line_vsync;
logic              line_vblank;
logic [15:0]       line_sequence;
logic [SLOT_W-1:0] enc_slot;
logic [WORD_W-1:0] enc_word_index;

wire active_pixel = ce_pix && !VGA_HBLANK_IN && !VGA_VBLANK_IN;
wire line_start   = ce_pix && hblank_d && !VGA_HBLANK_IN;
wire line_end     = ce_pix && !hblank_d && VGA_HBLANK_IN;

always_ff @(posedge clk_sys) begin
	if (reset)
		hblank_d <= 1'b1;
	else if (ce_pix)
		hblank_d <= VGA_HBLANK_IN;
end

logic        enc_token_valid;
logic        enc_token_ready;
logic [15:0] enc_token_data;
logic        enc_token_eol;
logic        enc_overflow;

vfb_rle_encoder encoder (
	.clk_sys     (clk_sys),
	.reset       (reset),
	.pixel_valid (active_pixel),
	.canonical_in(CANONICAL_IN),
	.line_end    (line_end),
	.token_valid (enc_token_valid),
	.token_ready (enc_token_ready),
	.token_data  (enc_token_data),
	.token_eol   (enc_token_eol),
	.overflow    (enc_overflow)
);

// Each queued 32-bit word carries its line slot and word index, so writing
// can begin before the line ends.
logic             wr_fifo_empty;
wr_pair_t         wr_fifo_data;
logic [FIFO_AW:0] wr_fifo_used;
packed_word_t     pack_pending_q;
logic             wr_fifo_room_q;
logic             enc_fifo_room_q;
logic             wr_pair_valid_q;
wr_pair_t         wr_pair_q;
wire              enc_token_accept = enc_token_valid && enc_token_ready;
wire              wr_pair_accept   = enc_token_accept && (pack_pending_q.valid || enc_token_eol);
wr_pair_t         wr_pair;
wire  [WORD_W:0]  enc_words_next = {1'b0, enc_word_index} + {{WORD_W{1'b0}}, 1'b1};
wire              wr_fifo_pop;
wr_head_t         wr_head_q;
wire              wr_head_take;

always_comb begin
	wr_pair.data  = 32'd0;
	wr_pair.index = enc_word_index[WORD_W-1:1];
	wr_pair.slot  = enc_slot;
	wr_pair.eol   = 1'b0;

	if (pack_pending_q.valid) begin
		wr_pair.data  = { enc_token_data, pack_pending_q.word };
		wr_pair.index = pack_pending_q.pair_index;
		wr_pair.slot  = pack_pending_q.slot;
		wr_pair.eol   = enc_token_eol;
	end else begin
		wr_pair.data = {16'd0, enc_token_data};
		wr_pair.eol  = enc_token_eol;
	end
end

assign enc_token_ready = !(pack_pending_q.valid || enc_token_eol) || enc_fifo_room_q;

vfb_sync_fifo #(
	.WIDTH(WR_FIFO_W),
	.DEPTH(FIFO_DEPTH)
) wr_fifo (
	.clk_sys(clk_sys),
	.reset  (reset),
	.wr_en  (wr_pair_valid_q),
	.wr_data(wr_pair_q),
	.full   (),
	.rd_en  (wr_fifo_pop),
	.rd_data(wr_fifo_data),
	.empty  (wr_fifo_empty),
	.used   (wr_fifo_used)
);

// Register available-space checks and reserve room for accepted encoder
// data that has not reached the FIFO yet.
always_ff @(posedge clk_sys) begin
	if (reset) begin
		wr_fifo_room_q  <= 1'b0;
		enc_fifo_room_q <= 1'b0;
		wr_pair_valid_q <= 1'b0;
	end else begin
		wr_fifo_room_q  <= (wr_fifo_used < (FIFO_DEPTH - WR_READY_MARGIN));
		enc_fifo_room_q <= wr_fifo_room_q;
		wr_pair_valid_q <= wr_pair_accept;
		if (wr_pair_accept) wr_pair_q <= wr_pair;
	end
end

assign wr_fifo_pop = !wr_fifo_empty && (!wr_head_q.valid || wr_head_take);

always_ff @(posedge clk_sys) begin
	if (reset) begin
		wr_head_q <= '0;
	end else begin
		if (wr_fifo_pop) begin
			wr_head_q.valid <= 1'b1;
			wr_head_q.pair  <= wr_fifo_data;
		end else if (wr_head_take) begin
			wr_head_q.valid <= 1'b0;
		end
	end
end

// Line descriptors
line_desc_t     line_desc [0:SLOT_COUNT-1];
line_finalize_t finalize_q;
line_finalize_t blank_finalize_q;
desc_lookup_t   desc_lookup_q;
desc_apply_t    desc_apply_q;

// Read preparation runs one line ahead. A line selected after line N is
// stored in prefetch_line, moved to pending_line at the next line start,
// and shown at the following line start. SDRAM therefore has one full line
// to prepare the data.
line_status_t prefetch_line_q;
line_status_t pending_line_q;
line_status_t output_line_q;

logic [15:0] delayed_sequence;
always_comb
	delayed_sequence = line_sequence + 16'd2 - {4'd0, line_delay};
logic delay_warmed_r;
wire  delay_warmed_now = (line_sequence + 16'd2 >= {4'd0, line_delay});
wire  delay_warmed     = delay_warmed_r || delay_warmed_now;

logic                     rd_fifo_full;
logic                     rd_fifo_empty;
logic [RD_FIFO_W-1:0]     rd_fifo_data;
logic [RD_PAIR_FIFO_AW:0] rd_fifo_used;
logic                     rd_fifo_push;
logic                     rd_fifo_pop;
logic [RD_FIFO_W-1:0]     rd_fifo_wdata;

vfb_sync_fifo #(
	.WIDTH(RD_FIFO_W),
	.DEPTH(RD_PAIR_FIFO_DEPTH)
) rd_fifo (
	.clk_sys(clk_sys),
	.reset  (reset),
	.wr_en  (rd_fifo_push),
	.wr_data(rd_fifo_wdata),
	.full   (rd_fifo_full),
	.rd_en  (rd_fifo_pop),
	.rd_data(rd_fifo_data),
	.empty  (rd_fifo_empty),
	.used   (rd_fifo_used)
);

logic                rd_active;
logic [SLOT_W-1:0]   rd_slot;
logic [PAIR_W:0]     rd_pair_count;
logic [PAIR_W:0]     rd_pair_index;
logic [PAIR_W:0]     rd_pairs_left;
logic                rd_words_odd;
logic [RD_FIFO_AW:0] rd_outstanding;

rd_desc_t              rd_desc [0:RD_DESC_DEPTH-1];
logic [RD_DESC_AW-1:0] rd_desc_wr_ptr;
logic [RD_DESC_AW-1:0] rd_desc_rd_ptr;
logic [RD_DESC_AW:0]   rd_desc_used;

wire                rd_engine_idle    = !rd_active && (rd_outstanding == 0);
wire                desc_usable       = desc_apply_q.pending &&
                                        desc_apply_q.warmed &&
                                        desc_apply_q.line.valid &&
                                        desc_apply_q.line.written;
wire                desc_needs_rd     = desc_usable && (desc_apply_q.line.words != 0);
wire                rd_desc_pop       = rd_engine_idle && (rd_desc_used != 0);
wire [RD_DESC_AW:0] rd_desc_after_pop = rd_desc_used - {{RD_DESC_AW{1'b0}}, rd_desc_pop};
wire                rd_desc_can_push  = (rd_desc_after_pop < RD_DESC_DEPTH);
wire                rd_desc_push      = desc_needs_rd &&
                                        !(rd_engine_idle && (rd_desc_used == 0)) &&
                                        rd_desc_can_push;
wire                rd_desc_overflow  = desc_needs_rd &&
                                        !(rd_engine_idle && (rd_desc_used == 0)) &&
                                        !rd_desc_can_push;
wire                rd_start_direct   = desc_needs_rd && rd_engine_idle && (rd_desc_used == 0);
wire                rd_start_queued   = rd_desc_pop;
wire                rd_start          = rd_start_direct || rd_start_queued;
wire [SLOT_W-1:0]   rd_start_slot     = rd_start_queued ? rd_desc[rd_desc_rd_ptr].slot
                                                        : desc_apply_q.slot;
wire [WORD_W:0]     rd_start_words    = rd_start_queued ? rd_desc[rd_desc_rd_ptr].words
                                                        : desc_apply_q.line.words;
wire [PAIR_W:0]     rd_start_pairs    = rd_start_words[WORD_W:1] +
                                        {{PAIR_W{1'b0}}, rd_start_words[0]};

logic [11:0] decoded_canonical;
logic        decoded_line_done;
logic        dec_underflow;
logic        dec_token_ready;
// Four 16-bit words buffer two 32-bit SDRAM responses across RLE-token boundaries.
logic [63:0] dec_words;
logic [3:0]  dec_word_eol;
logic [2:0]  dec_word_count;
logic [63:0] dec_words_next;
logic [3:0]  dec_word_eol_next;
logic [2:0]  dec_word_count_next;

wire dec_token_valid  = (dec_word_count != 0);
wire dec_token_accept = dec_token_valid && dec_token_ready;
wire dec_token_eol    = dec_word_eol[0];

wire       rd_pair_high_valid = rd_fifo_data[32];
wire       rd_pair_eol        = rd_fifo_data[33];
wire [2:0] rd_pair_words      = rd_pair_high_valid ? 3'd2 : 3'd1;
wire [2:0] dec_words_left     = dec_word_count - (dec_token_accept ? 3'd1 : 3'd0);

assign rd_fifo_pop = !rd_fifo_empty && (dec_words_left + rd_pair_words <= 3'd4);

always_comb begin
	dec_words_next      = dec_words;
	dec_word_eol_next   = dec_word_eol;
	dec_word_count_next = dec_word_count;

	if (dec_token_accept) begin
		dec_words_next      = {16'd0, dec_words[63:16]};
		dec_word_eol_next   = {1'b0, dec_word_eol[3:1]};
		dec_word_count_next = dec_word_count - 1'b1;
	end

	if (rd_fifo_pop) begin
		case (dec_word_count_next)
			3'd0: begin
				dec_words_next[15:0] = rd_fifo_data[15:0];
				dec_word_eol_next[0] = rd_pair_eol && !rd_pair_high_valid;
				if (rd_pair_high_valid) begin
					dec_words_next[31:16] = rd_fifo_data[31:16];
					dec_word_eol_next[1]  = rd_pair_eol;
				end
			end

			3'd1: begin
				dec_words_next[31:16] = rd_fifo_data[15:0];
				dec_word_eol_next[1]  = rd_pair_eol && !rd_pair_high_valid;
				if (rd_pair_high_valid) begin
					dec_words_next[47:32] = rd_fifo_data[31:16];
					dec_word_eol_next[2]  = rd_pair_eol;
				end
			end

			3'd2: begin
				dec_words_next[47:32] = rd_fifo_data[15:0];
				dec_word_eol_next[2]  = rd_pair_eol && !rd_pair_high_valid;
				if (rd_pair_high_valid) begin
					dec_words_next[63:48] = rd_fifo_data[31:16];
					dec_word_eol_next[3]  = rd_pair_eol;
				end
			end

			default: begin
				dec_words_next[63:48] = rd_fifo_data[15:0];
				dec_word_eol_next[3]  = rd_pair_eol;
			end
		endcase
		dec_word_count_next = dec_word_count_next + rd_pair_words;
	end
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		dec_words      <= 64'd0;
		dec_word_eol   <= 4'd0;
		dec_word_count <= 3'd0;
	end else begin
		dec_words      <= dec_words_next;
		dec_word_eol   <= dec_word_eol_next;
		dec_word_count <= dec_word_count_next;
	end
end

// Select the pending line at line start and hold its timing through the line.
wire  current_line_valid  = line_start ? pending_line_q.valid : output_line_q.valid;
wire  current_line_vsync  = line_start ? pending_line_q.vsync : output_line_q.vsync;
wire  current_line_vblank = line_start ? pending_line_q.vblank : output_line_q.vblank;
logic dec_line_complete;
wire  dec_line_open      = !(line_start ? 1'b0 : dec_line_complete) &&
                           !decoded_line_done;

// Qualify line state independently; ce_pix gates only the final advance.
wire dec_active_allowed = !VGA_HBLANK_IN &&
                          !(hblank_d ? pending_line_q.vblank : output_line_q.vblank) &&
                          (hblank_d || !dec_line_complete);
wire dec_drain_allowed  = VGA_HBLANK_IN && output_line_q.valid &&
                          !output_line_q.vblank && !dec_line_complete;
wire dec_advance        = ce_pix && !decoded_line_done &&
                          (dec_active_allowed || dec_drain_allowed);

always_ff @(posedge clk_sys) begin
	if (reset || line_start)
		dec_line_complete <= 1'b0;
	else if (decoded_line_done)
		dec_line_complete <= 1'b1;
end

vfb_rle_decoder decoder (
	.clk_sys      (clk_sys),
	.reset        (reset),
	.token_valid  (dec_token_valid),
	.token_ready  (dec_token_ready),
	.token_data   (dec_words[15:0]),
	.token_eol    (dec_token_eol),
	.advance      (dec_advance),
	.canonical_out(decoded_canonical),
	.line_done    (decoded_line_done),
	.underflow    (dec_underflow)
);

always_ff @(posedge clk_sys) begin
	if (reset) begin
		CANONICAL_OUT  <= 12'd0;
		VGA_HS_OUT     <= 1'b1;
		VGA_VS_OUT     <= 1'b1;
		VGA_HBLANK_OUT <= 1'b1;
		VGA_VBLANK_OUT <= 1'b1;
	end else if (ce_pix) begin
		// Present the current decoded pixel before advancing the decoder.
		if (current_line_valid && !VGA_HBLANK_IN &&
			!current_line_vblank && dec_line_open) begin
			CANONICAL_OUT <= decoded_canonical;
		end else begin
			CANONICAL_OUT <= 12'd0;
		end
		VGA_HS_OUT     <= VGA_HS_IN;
		VGA_HBLANK_OUT <= VGA_HBLANK_IN;
		VGA_VS_OUT     <= current_line_vsync;
		VGA_VBLANK_OUT <= current_line_vblank;
	end
end

// Open-row SDRAM controller and read/write scheduler
logic        mem_req_ready;
logic        mem_rsp_valid;
logic [31:0] mem_rsp_rdata;

mem_req_t req_q;
logic     req_load;
wire      req_rd = req_q.valid && !req_q.wr;
wire      req_wr = req_q.valid && req_q.wr;

vfb_sdram_core #(
	.SDRAM_MHZ(SDRAM_MHZ)
) sdram_controller (
	.clk_sys       (clk_sys),
	.reset         (reset),
	.req_valid     (req_q.valid),
	.req_write     (req_q.wr),
	.req_addr      (req_q.addr),
	.req_wdata     (req_q.wdata),
	.req_ready     (mem_req_ready),
	.rsp_valid     (mem_rsp_valid),
	.rsp_rdata     (mem_rsp_rdata),
	.init_done     (init_done),
	.sdram_data_in (sdram_data_in),
	.sdram_data_out(sdram_data_out),
	.sdram_data_oe (sdram_data_oe),
	.sdram_cke     (sdram_cke),
	.sdram_cs      (sdram_cs),
	.sdram_ras     (sdram_ras),
	.sdram_cas     (sdram_cas),
	.sdram_we      (sdram_we),
	.sdram_dqm     (sdram_dqm),
	.sdram_addr    (sdram_addr),
	.sdram_ba      (sdram_ba)
);

wire [RD_FIFO_AW+1:0] rd_reserved   = (RD_FIFO_AW + 2)'(rd_fifo_used) +
                                      (RD_FIFO_AW + 2)'(rd_outstanding);
wire                  rd_available  = rd_active &&
                                      (rd_pair_index < rd_pair_count) &&
                                      (rd_reserved < RD_PAIR_FIFO_DEPTH - 2);
wire                  wr_available  = wr_head_q.valid;
wire                  rd_more_after = (rd_pair_index + 1'b1 < rd_pair_count) &&
                                      (rd_reserved + 1'b1 < RD_PAIR_FIFO_DEPTH - 2);
wire                  wr_more_after = wr_head_q.valid || !wr_fifo_empty;
wire                  wr_urgent     = (wr_fifo_used >= WR_URGENT_LEVEL);
wire                  rd_urgent     = rd_active && (rd_reserved <= RD_URGENT_LEVEL);
wire                  rd_preferred  = rd_available && (!wr_available || rd_urgent || !wr_urgent);

logic       arb_locked;
logic       arb_rd;
logic [5:0] arb_left;
logic       rd_available_q;
logic       wr_available_q;
logic       rd_preferred_q;
logic       wr_more_after_q;

wire arb_rd_effective   = (arb_locked && rd_preferred_q) ? 1'b1 : arb_rd;
wire selected_available = arb_rd_effective ? rd_available_q : wr_available_q;

assign req_load = !req_q.valid && init_done && arb_locked && selected_available;

wire req_accept    = mem_req_ready && req_q.valid;
wire rd_req_accept = req_accept && req_rd;
wire wr_req_accept = req_accept && req_wr;
// Queue another request of the same type while its quota remains, avoiding
// an idle clock between accesses to the same row.
wire            req_chain_rd     = rd_req_accept && (arb_left > 1) && req_q.rd_more;
wire            req_chain_wr     = wr_req_accept && (arb_left > 1) && wr_head_q.valid;
wire [PAIR_W:0] chained_rd_index = rd_pair_index + {{PAIR_W{1'b0}}, 1'b1};
wire            chained_rd_more  = (chained_rd_index + {{PAIR_W{1'b0}}, 1'b1} < rd_pair_count) &&
                                   (rd_reserved + 2'd2 < RD_PAIR_FIFO_DEPTH - 2);

assign wr_head_take = (req_load && !arb_rd_effective) || req_chain_wr;

always_ff @(posedge clk_sys) begin
	if (reset) begin
		rd_available_q  <= 1'b0;
		wr_available_q  <= 1'b0;
		rd_preferred_q  <= 1'b0;
		wr_more_after_q <= 1'b0;
	end else begin
		rd_available_q  <= rd_available;
		wr_available_q  <= wr_available;
		rd_preferred_q  <= rd_preferred;
		wr_more_after_q <= wr_more_after;
	end
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		req_q <= '0;
	end else if (req_chain_rd) begin
		req_q.valid   <= 1'b1;
		req_q.wr      <= 1'b0;
		req_q.rd_more <= chained_rd_more;
		req_q.addr    <= ({{(32-SLOT_W){1'b0}}, rd_slot} << SLOT_BYTE_SHIFT) +
		                 ({{(32-PAIR_W){1'b0}}, chained_rd_index[PAIR_W-1:0]} << 2);
	end else if (req_chain_wr) begin
		req_q.valid   <= 1'b1;
		req_q.wr      <= 1'b1;
		req_q.rd_more <= 1'b0;
		req_q.wr_eol  <= wr_head_q.pair.eol;
		req_q.wr_slot <= wr_head_q.pair.slot;
		req_q.wdata   <= wr_head_q.pair.data;
		req_q.addr    <= ({{(32-SLOT_W){1'b0}}, wr_head_q.pair.slot} << SLOT_BYTE_SHIFT) +
		                 ({{(32-PAIR_W){1'b0}}, wr_head_q.pair.index} << 2);
	end else if (req_accept) begin
		req_q.valid   <= 1'b0;
		req_q.rd_more <= 1'b0;
	end else if (!req_q.valid) begin
		req_q.valid   <= req_load;
		req_q.wr      <= req_load && !arb_rd_effective;
		req_q.rd_more <= req_load && arb_rd_effective && rd_more_after;
		if (req_load) begin
			req_q.wr_eol  <= !arb_rd_effective && wr_head_q.pair.eol;
			req_q.wr_slot <= wr_head_q.pair.slot;
			req_q.wdata   <= wr_head_q.pair.data;
			if (arb_rd_effective)
				req_q.addr <= ({{(32-SLOT_W){1'b0}}, rd_slot} << SLOT_BYTE_SHIFT) +
				              ({{(32-PAIR_W){1'b0}}, rd_pair_index[PAIR_W-1:0]} << 2);
			else
				req_q.addr <= ({{(32-SLOT_W){1'b0}}, wr_head_q.pair.slot} << SLOT_BYTE_SHIFT) +
				              ({{(32-PAIR_W){1'b0}}, wr_head_q.pair.index} << 2);
		end
	end
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		arb_locked <= 1'b0;
		arb_rd     <= 1'b0;
		arb_left   <= ARB_QUOTA;
	end else if (!arb_locked) begin
		if (rd_available_q || wr_available_q) begin
			arb_locked <= 1'b1;
			arb_rd     <= rd_preferred_q;
			arb_left   <= ARB_QUOTA;
		end
	end else if (!selected_available) begin
		arb_locked <= 1'b0;
	end else if (req_accept) begin
		if (arb_left > 1 && (arb_rd_effective ? req_q.rd_more : wr_more_after_q)) begin
			arb_left <= arb_left - 1'b1;
			arb_rd   <= arb_rd_effective;
		end else if (arb_rd_effective && wr_available_q && !rd_preferred_q) begin
			arb_rd   <= 1'b0;
			arb_left <= ARB_QUOTA;
		end else if (!arb_rd_effective && rd_available_q && rd_preferred_q) begin
			arb_rd   <= 1'b1;
			arb_left <= ARB_QUOTA;
		end else if (arb_rd_effective ? req_q.rd_more : wr_more_after_q) begin
			arb_rd   <= arb_rd_effective;
			arb_left <= ARB_QUOTA;
		end else begin
			arb_locked <= 1'b0;
		end
	end
end

// Every requested pair contains a low word. Only the final high word can
// be padding when a line contains an odd number of RLE words.
wire rd_rsp_last  = (rd_pairs_left == 1);
wire rd_high_real = mem_rsp_valid && (!rd_rsp_last || !rd_words_odd);

assign rd_fifo_push  = mem_rsp_valid && !rd_fifo_full;
assign rd_fifo_wdata = { rd_rsp_last,
                       rd_high_real,
                       mem_rsp_rdata };

integer slot_i;
always_ff @(posedge clk_sys) begin
	if (reset) begin
		line_had_pixels  <= 1'b0;
		line_vsync       <= 1'b1;
		line_vblank      <= 1'b1;
		line_sequence    <= 16'd0;
		delay_warmed_r   <= 1'b0;
		enc_slot         <= '0;
		enc_word_index   <= '0;
		pack_pending_q   <= '0;
		finalize_q       <= {1'b0, {SLOT_W{1'b0}}, 2'b11};
		blank_finalize_q <= {1'b0, {SLOT_W{1'b0}}, 2'b11};
		desc_lookup_q    <= '0;
		desc_apply_q     <= '0;
		prefetch_line_q  <= BLANK_LINE_STATUS;
		pending_line_q   <= BLANK_LINE_STATUS;
		output_line_q    <= BLANK_LINE_STATUS;
		rd_active        <= 1'b0;
		rd_slot          <= '0;
		rd_pair_count    <= '0;
		rd_pair_index    <= '0;
		rd_pairs_left    <= '0;
		rd_words_odd     <= 1'b0;
		rd_outstanding   <= '0;
		rd_desc_wr_ptr   <= '0;
		rd_desc_rd_ptr   <= '0;
		rd_desc_used     <= '0;
		overflow         <= 1'b0;
		underflow        <= 1'b0;
		for (slot_i = 0; slot_i < SLOT_COUNT; slot_i = slot_i + 1) begin
			line_desc[slot_i] <= {{(WORD_W+1){1'b0}}, 2'b11, 2'b00};
		end
	end else begin
		// Register an empty-line descriptor one cycle after detection.
		if (blank_finalize_q.pending) begin
			line_desc[blank_finalize_q.slot].words   <= '0;
			line_desc[blank_finalize_q.slot].vsync   <= blank_finalize_q.vsync;
			line_desc[blank_finalize_q.slot].vblank  <= blank_finalize_q.vblank;
			line_desc[blank_finalize_q.slot].valid   <= 1'b1;
			line_desc[blank_finalize_q.slot].written <= 1'b1;
			blank_finalize_q.pending                 <= 1'b0;
			enc_slot                                 <= blank_finalize_q.slot + 1'b1;
			enc_word_index                           <= '0;
			pack_pending_q.valid                     <= 1'b0;
		end

		if (line_start) begin
			line_had_pixels <= 1'b0;
			line_vsync      <= VGA_VS_IN;
			line_vblank     <= VGA_VBLANK_IN;
			output_line_q   <= pending_line_q;
			pending_line_q  <= prefetch_line_q;
			prefetch_line_q <= BLANK_LINE_STATUS;
		end

		if (active_pixel) line_had_pixels <= 1'b1;

		if (enc_token_accept) begin
			if ((enc_words_next > MAX_WORDS) || ((enc_words_next == MAX_WORDS) && !enc_token_eol))
				overflow <= 1'b1;

			if (pack_pending_q.valid || enc_token_eol) begin
				pack_pending_q.valid <= 1'b0;
			end else begin
				pack_pending_q.valid      <= 1'b1;
				pack_pending_q.word       <= enc_token_data;
				pack_pending_q.pair_index <= enc_word_index[WORD_W-1:1];
				pack_pending_q.slot       <= enc_slot;
			end

			if (enc_token_eol) begin
				finalize_q.pending <= 1'b0;
				enc_slot           <= enc_slot + 1'b1;
				enc_word_index     <= '0;
			end else begin
				enc_word_index <= enc_words_next[WORD_W-1:0];
			end
		end

		// EOL always flushes a pair, independent of a pending first half.
		if (enc_token_valid && enc_token_eol && enc_fifo_room_q) begin
			line_desc[finalize_q.slot].words   <= enc_words_next;
			line_desc[finalize_q.slot].vsync   <= finalize_q.vsync;
			line_desc[finalize_q.slot].vblank  <= finalize_q.vblank;
			line_desc[finalize_q.slot].valid   <= 1'b1;
			line_desc[finalize_q.slot].written <= 1'b0;
		end

		if (wr_req_accept && req_q.wr_eol) line_desc[req_q.wr_slot].written <= 1'b1;

		if (desc_lookup_q.pending) begin
			desc_lookup_q.pending <= 1'b0;
			desc_apply_q.pending  <= 1'b1;
			desc_apply_q.warmed   <= desc_lookup_q.warmed;
			desc_apply_q.slot     <= desc_lookup_q.slot;
			desc_apply_q.line     <= line_desc[desc_lookup_q.slot];
		end

		if (desc_apply_q.pending) begin
			desc_apply_q.pending <= 1'b0;
			if (desc_apply_q.warmed && desc_apply_q.line.valid && desc_apply_q.line.written) begin
				prefetch_line_q.valid  <= 1'b1;
				prefetch_line_q.vsync  <= desc_apply_q.line.vsync;
				prefetch_line_q.vblank <= desc_apply_q.line.vblank;
			end else if (desc_apply_q.warmed) begin
				prefetch_line_q <= BLANK_LINE_STATUS;
				underflow       <= 1'b1;
			end
		end

		if (rd_desc_push) begin
			rd_desc[rd_desc_wr_ptr].slot  <= desc_apply_q.slot;
			rd_desc[rd_desc_wr_ptr].words <= desc_apply_q.line.words;
			rd_desc_wr_ptr                <= rd_desc_wr_ptr + 1'b1;
		end
		if (rd_desc_pop) rd_desc_rd_ptr <= rd_desc_rd_ptr + 1'b1;
		case ({rd_desc_push, rd_desc_pop})
			2'b10:   rd_desc_used <= rd_desc_used + 1'b1;
			2'b01:   rd_desc_used <= rd_desc_used - 1'b1;
			default: rd_desc_used <= rd_desc_used;
		endcase
		if (rd_desc_overflow) underflow <= 1'b1;

		if (rd_start) begin
			rd_slot       <= rd_start_slot;
			rd_pair_count <= rd_start_pairs;
			rd_pair_index <= '0;
			rd_pairs_left <= rd_start_pairs;
			rd_words_odd  <= rd_start_words[0];
			rd_active     <= 1'b1;
		end

		if (line_end) begin
			line_sequence  <= line_sequence + 1'b1;
			delay_warmed_r <= delay_warmed;

			if (line_had_pixels) begin
				finalize_q.pending <= 1'b1;
				finalize_q.slot    <= enc_slot;
				finalize_q.vsync   <= line_vsync;
				finalize_q.vblank  <= line_vblank;
			end else begin
				blank_finalize_q.pending <= 1'b1;
				blank_finalize_q.slot    <= enc_slot;
				blank_finalize_q.vsync   <= line_vsync;
				blank_finalize_q.vblank  <= line_vblank;
			end

			desc_lookup_q.pending <= 1'b1;
			desc_lookup_q.warmed  <= delay_warmed;
			desc_lookup_q.slot    <= delayed_sequence[SLOT_W-1:0];
		end

		if (rd_req_accept) rd_pair_index <= rd_pair_index + 1'b1;

		case ({rd_req_accept, mem_rsp_valid})
			2'b10:   rd_outstanding <= rd_outstanding + 1'b1;
			2'b01:   rd_outstanding <= rd_outstanding - 1'b1;
			default: rd_outstanding <= rd_outstanding;
		endcase

		if (mem_rsp_valid) begin
			if (rd_fifo_full) overflow <= 1'b1;
			rd_pairs_left <= rd_pairs_left - 1'b1;
			if (rd_rsp_last) rd_active <= 1'b0;
		end

		if (enc_overflow)                         overflow  <= 1'b1;
		if (dec_underflow && output_line_q.valid) underflow <= 1'b1;
		if (finalize_q.pending && line_start)     overflow  <= 1'b1;
		if (blank_finalize_q.pending && line_end) overflow  <= 1'b1;
	end
end

endmodule

`default_nettype wire
