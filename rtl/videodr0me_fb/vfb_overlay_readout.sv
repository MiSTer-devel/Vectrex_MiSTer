// ============================================================================
// Read and decode the selected overlay plane into display palette indices.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// ============================================================================

`default_nettype none

module vfb_overlay_readout (
	input  wire         clk_sys,
	input  wire         reset,
	input  wire         video_timing_reset,
	input  wire         run_requested,
	input  wire [1:0]   active_index_mode,
	input  wire [31:0]  active_payload_offset,
	input  wire [31:0]  active_payload_size,
	input  wire [11:0]  render_width,
	input  wire [11:0]  render_height,
	input  wire         ce_pix,
	input  wire         video_hblank_in,
	input  wire         video_vblank_in,
	output logic [7:0]  palette_read_index = 8'd0,
	output logic        palette_index_valid,
	output wire [11:0]  pixel_x,
	output wire [11:0]  pixel_y,

	output logic        artwork_read_ready,
	input  wire         artwork_read_grant,
	output logic [28:0] artwork_read_addr,
	output logic [7:0]  artwork_read_burstcnt,
	input  wire [63:0]  artwork_read_data,
	input  wire         artwork_read_data_valid
);

import vfb_layout_pkg::*;

localparam integer MAX_WIDTH              = 1360;
localparam integer COMPRESSED_FIFO_DEPTH  =  128;
localparam integer COMPRESSED_FIFO_ADDR_W = $clog2(COMPRESSED_FIFO_DEPTH);
localparam integer ROW_ADDR_W             = $clog2(MAX_WIDTH);

function automatic [10:0] row_word_count(input logic [15:0] encoded_bits);
	logic [16:0] padded_bits;
	begin
		padded_bits    = {1'b0, encoded_bits} + 17'd79;
		row_word_count = padded_bits[16:6];
	end
endfunction

// ------------------------------------------------------------------------
// Lowest-priority sequential DDRAM reader
// ------------------------------------------------------------------------

logic                            fifo_reset =  1'b1;
logic                            fifo_wr    =  1'b0;
logic [63:0]                     fifo_wdata = 64'd0;
logic                            fifo_rd    =  1'b0;
wire  [63:0]                     fifo_data;
wire                             fifo_full;
wire                             fifo_empty;
wire  [COMPRESSED_FIFO_ADDR_W:0] fifo_used;

vfb_sync_fifo #(
	.WIDTH(64),
	.DEPTH(COMPRESSED_FIFO_DEPTH)
) compressed_fifo (
	.clk_sys(clk_sys),
	.reset  (fifo_reset),
	.wr_en  (fifo_wr),
	.wr_data(fifo_wdata),
	.full   (fifo_full),
	.rd_en  (fifo_rd),
	.rd_data(fifo_data),
	.empty  (fifo_empty),
	.used   (fifo_used)
);

logic        packet_vblank_q      = 1'b1;
logic        run_requested_q      = 1'b0;
logic        restart_pending      = 1'b0;
logic        stream_active        = 1'b0;
logic        stream_discard       = 1'b1;
logic        stream_decoder_reset = 1'b1;
logic        read_inflight        = 1'b0;
logic [7:0]  read_beats_left      = 8'd0;
logic [28:0] stream_fetch_addr    = VFB_ARTWORK_BASE;
logic [31:0] stream_words_left    = 32'd0;

wire vblank_rise         = ce_pix && video_vblank_in && !packet_vblank_q;
wire start_during_vblank = run_requested && !run_requested_q && video_vblank_in;
wire restart_now         = vblank_rise || start_during_vblank;

always_ff @(posedge clk_sys) begin
	fifo_wr              <= 1'b0;
	fifo_reset           <= 1'b0;
	stream_decoder_reset <= 1'b0;
	run_requested_q      <= run_requested;
	if (ce_pix) packet_vblank_q <= video_vblank_in;

	if (reset || video_timing_reset) begin
		artwork_read_ready   <=  1'b0;
		read_inflight        <=  1'b0;
		read_beats_left      <=  8'd0;
		restart_pending      <=  1'b0;
		stream_active        <=  1'b0;
		stream_discard       <=  1'b1;
		fifo_reset           <=  1'b1;
		stream_decoder_reset <=  1'b1;
		fifo_wdata           <= 64'd0;
		packet_vblank_q      <=  1'b1;
		run_requested_q      <=  1'b0;
	end else begin
		if (!run_requested) begin
			artwork_read_ready   <= 1'b0;
			restart_pending      <= 1'b0;
			stream_active        <= 1'b0;
			stream_discard       <= 1'b1;
			fifo_reset           <= 1'b1;
			stream_decoder_reset <= 1'b1;
		end else if (restart_now) begin
			// Hold a pending request until its registered arbiter grant arrives.
			restart_pending <= 1'b1;
			stream_active   <= 1'b0;
			stream_discard  <= 1'b1;
		end

		if (artwork_read_grant) begin
			artwork_read_ready <= 1'b0;
			read_inflight      <= 1'b1;
			read_beats_left    <= artwork_read_burstcnt;
			stream_fetch_addr  <= stream_fetch_addr + {21'd0, artwork_read_burstcnt};
			stream_words_left  <= stream_words_left - {24'd0, artwork_read_burstcnt};
		end

		if (artwork_read_data_valid && read_inflight) begin
			if (!stream_discard && !restart_now && !fifo_full) begin
				fifo_wr    <= 1'b1;
				fifo_wdata <= artwork_read_data;
			end
			if (read_beats_left == 8'd1) begin
				read_beats_left <= 8'd0;
				read_inflight   <= 1'b0;
			end else begin
				read_beats_left <= read_beats_left - 1'b1;
			end
		end

		if (restart_pending && !read_inflight && !artwork_read_ready) begin
			fifo_reset           <= 1'b1;
			stream_decoder_reset <= 1'b1;
			stream_fetch_addr    <= VFB_ARTWORK_BASE + active_payload_offset[31:3];
			stream_words_left    <= active_payload_size >> 3;
			restart_pending      <= 1'b0;
			stream_active        <= 1'b1;
			stream_discard       <= 1'b0;
		end else if (stream_active && !read_inflight &&
			!artwork_read_ready && (stream_words_left != 0) &&
			(fifo_used <= 8'd64)) begin
			artwork_read_addr     <= stream_fetch_addr;
			artwork_read_burstcnt <= (stream_words_left >= 32'd32) ? 8'd32 : stream_words_left[7:0];
			artwork_read_ready    <= 1'b1;
		end
	end
end

// ------------------------------------------------------------------------
// The active row decoder emits one pixel per clock while encoded input
// is available.
// ------------------------------------------------------------------------

typedef enum logic [3:0] {
	DEC_IDLE,
	DEC_ROW_START,
	DEC_TOKEN,
	DEC_LITERAL,
	DEC_REPEAT,
	DEC_COPY,
	DEC_FINISH,
	DEC_ERROR,
	DEC_ROW_PRIME
} decode_state_t;

decode_state_t decode_state = DEC_IDLE;

// decode_front is byte-aligned; front_pair_offset selects a two-bit
// position (0 to 3) within its first byte.
logic [31:0] decode_front      = 32'd0;
logic [1:0]  front_pair_offset =  2'd0;
logic [79:0] decode_tail       = 80'd0;
logic [3:0]  tail_bytes        =  4'd0;
logic [6:0]  buffered_pairs    =  7'd0;
logic [14:0] row_pairs_left    = 15'd0;
logic [10:0] row_words_left    = 11'd0;
logic        row_has_words     =  1'b0;

logic [11:0] decode_row      = 12'd0;
logic [11:0] decode_x        = 12'd0;
logic [11:0] row_pixels_left = 12'd0;
logic [7:0]  run_pixels_left =  8'd0;
logic [7:0]  repeat_index    =  8'd0;

logic        row_write_enable =  1'b0;
logic        row_write_bank   =  1'b0;
logic [11:0] row_write_addr   = 12'd0;
logic [7:0]  row_write_data   =  8'd0;

logic [1:0]  row_valid = 2'b00;
logic [11:0] row_number [0:1];

logic        stream_error       =  1'b0;
logic [63:0] decode_input_word  = 64'd0;
logic        decode_input_valid =  1'b0;

(* ramstyle = "M10K, no_rw_check" *) logic [7:0] row0_memory [0:MAX_WIDTH-1];
(* ramstyle = "M10K, no_rw_check" *) logic [7:0] row1_memory [0:MAX_WIDTH-1];
logic [ROW_ADDR_W-1:0] row0_port_a_addr;
logic [ROW_ADDR_W-1:0] row1_port_a_addr;
logic [7:0]            row0_copy_data    = 8'd0;
logic [7:0]            row1_copy_data    = 8'd0;
logic [7:0]            row0_display_data = 8'd0;
logic [7:0]            row1_display_data = 8'd0;
logic [ROW_ADDR_W-1:0] display_read_addr =   '0;

wire       decode_target_bank = decode_row[0];
wire       prev_row_bank      = ~decode_target_bank;
wire [7:0] prev_row_data      = prev_row_bank ? row1_copy_data : row0_copy_data;

logic [15:0] decode_window;
always_comb begin
	case (front_pair_offset)
		2'd0:    decode_window = decode_front[15:0];
		2'd1:    decode_window = decode_front[17:2];
		2'd2:    decode_window = decode_front[19:4];
		default: decode_window = decode_front[21:6];
	endcase
end

// Tokens: 0lllllll = l+1 literal indices; 10llllll = repeat one index l+1 times;
// 11llllll = copy l+1 indices from the previous row at the same columns.
// Indices use the selected 4/6/8-bit width.
// All encoded fields contain an even number of bits, so counts use two-bit pairs.
logic       index_4_q = 1'b0, index_6_q = 1'b0;
logic [2:0] active_index_pairs = 3'd4;

// Hold one coherent format for the stream, decoded before its first token.
always_ff @(posedge clk_sys) begin
	if (stream_decoder_reset) begin
		index_4_q          <= active_index_mode == INDEX_MODE_4;
		index_6_q          <= active_index_mode == INDEX_MODE_6;
		active_index_pairs <= (active_index_mode == INDEX_MODE_4) ? 3'd2 :
		                      (active_index_mode == INDEX_MODE_6) ? 3'd3 : 3'd4;
	end
end

wire token_is_literal = !decode_window[7];
wire token_is_repeat  = decode_window[7:6] == 2'b10;
wire token_is_copy    = decode_window[7:6] == 2'b11;

wire [6:0] token_len_m1         = token_is_literal ? decode_window[6:0] : {1'b0, decode_window[5:0]};
wire [3:0] token_required_pairs = token_is_copy ? 4'd4 : ({1'b0, active_index_pairs} + 4'd4);

wire token_fits   = {5'd0, token_len_m1} < row_pixels_left;
wire row_finished = (row_pixels_left == 0) && (row_pairs_left == 0);
wire token_valid  = (row_pixels_left != 0) && token_fits && (row_pairs_left >= {11'd0, token_required_pairs});

wire literal_valid = (row_pixels_left != 0) &&
                     (run_pixels_left != 0) &&
                     (row_pairs_left >= {12'd0, active_index_pairs});

wire [10:0] row_start_word_count = row_word_count(decode_input_word[15:0]);

wire       decoder_stream_state = (decode_state == DEC_TOKEN)   || (decode_state == DEC_LITERAL) ||
                                  (decode_state == DEC_REPEAT)  || (decode_state == DEC_COPY);
wire       token_rd_state       = (decode_state == DEC_TOKEN) || (decode_state == DEC_LITERAL);
wire [3:0] index_pair_sum       = {2'd0, front_pair_offset} + {1'b0, active_index_pairs};

logic [3:0] token_rd_pairs;
logic [1:0] token_rd_byte_shift;
logic [1:0] token_rd_pair_next;

always_comb begin
	token_rd_pairs      = 4'd0;
	token_rd_byte_shift = 2'd0;
	token_rd_pair_next  = front_pair_offset;

	case (decode_state)
		DEC_TOKEN:   begin
			token_rd_pairs = token_required_pairs;
			if (token_is_copy) begin
				token_rd_byte_shift = 2'd1;
			end else begin
				token_rd_byte_shift = index_pair_sum[3:2] + 2'd1;
				token_rd_pair_next  = index_pair_sum[1:0];
			end
		end
		DEC_LITERAL: begin
			token_rd_pairs      = {1'b0, active_index_pairs};
			token_rd_byte_shift = index_pair_sum[3:2];
			token_rd_pair_next  = index_pair_sum[1:0];
		end
		default:     begin end
	endcase
end

wire tail_refill = (decoder_stream_state || (decode_state == DEC_ROW_PRIME)) &&
                   (tail_bytes <= 4'd2) && row_has_words && decode_input_valid;

logic [79:0] decode_tail_refilled;
logic [3:0]  tail_bytes_refilled;

always_comb begin
	decode_tail_refilled = decode_tail;
	tail_bytes_refilled  = tail_bytes;
	if (tail_refill) begin
		case (tail_bytes)
			4'd0:    decode_tail_refilled = {16'd0, decode_input_word};
			4'd1:    decode_tail_refilled = {8'd0, decode_input_word, decode_tail[7:0]};
			default: decode_tail_refilled = {decode_input_word, decode_tail[15:0]};
		endcase
		tail_bytes_refilled = tail_bytes + 4'd8;
	end
end

logic buffered_pairs_ok;
always_comb begin
	buffered_pairs_ok = 1'b1;
	case (decode_state)
		DEC_TOKEN:   begin
			if (token_is_copy) begin
				buffered_pairs_ok = buffered_pairs >= 7'd4;
			end else begin
				case (1'b1)
					index_4_q: buffered_pairs_ok = buffered_pairs >= 7'd6;
					index_6_q: buffered_pairs_ok = buffered_pairs >= 7'd7;
					default:   buffered_pairs_ok = buffered_pairs >= 7'd8;
				endcase
			end
		end
		DEC_LITERAL: begin
			case (1'b1)
				index_4_q: buffered_pairs_ok = buffered_pairs >= 7'd2;
				index_6_q: buffered_pairs_ok = buffered_pairs >= 7'd3;
				default:   buffered_pairs_ok = buffered_pairs >= 7'd4;
			endcase
		end
		default:     begin end
	endcase
end
// Do not shift missing tail bytes into the four-byte front while another
// source word remains. A delayed DDR refill must stall rather than insert
// zero padding into the middle of a row.
wire front_refill_ok      = !row_has_words ||
                            (tail_bytes >= {2'd0, token_rd_byte_shift});
wire decoder_stream_ready = tail_refill || (buffered_pairs_ok && front_refill_ok);

// Calculate token and literal next states with and without enough encoded data.
// decoder_stream_ready selects between these states.
decode_state_t token_ready_state, token_wait_state;
decode_state_t literal_ready_state, literal_wait_state;
always_comb begin
	if (row_finished)
		token_ready_state = DEC_FINISH;
	else if (!token_valid)
		token_ready_state = DEC_ERROR;
	else if (token_len_m1 == 0)
		token_ready_state = DEC_TOKEN;
	else if (token_is_literal)
		token_ready_state = DEC_LITERAL;
	else if (token_is_repeat)
		token_ready_state = DEC_REPEAT;
	else
		token_ready_state = DEC_COPY;

	if (row_finished)
		token_wait_state = DEC_FINISH;
	else if (!token_valid || !row_has_words)
		token_wait_state = DEC_ERROR;
	else
		token_wait_state = DEC_TOKEN;

	if (!literal_valid)
		literal_ready_state = DEC_ERROR;
	else if (run_pixels_left == 8'd1)
		literal_ready_state = DEC_TOKEN;
	else
		literal_ready_state = DEC_LITERAL;

	literal_wait_state = (literal_valid && row_has_words) ? DEC_LITERAL : DEC_ERROR;
end

logic front_advance_ok;
always_comb begin
	front_advance_ok = 1'b0;
	case (decode_state)
		DEC_TOKEN:
			front_advance_ok = token_valid;
		DEC_LITERAL:
			front_advance_ok = (row_pairs_left >= {12'd0, active_index_pairs}) && (row_pixels_left != 0);
		default: begin end
	endcase
end

logic run_bounds_ok;
always_comb begin
	run_bounds_ok = 1'b0;
	case (decode_state)
		DEC_TOKEN:
			run_bounds_ok = (row_pixels_left != 0) && token_fits;
		DEC_LITERAL, DEC_REPEAT, DEC_COPY:
			run_bounds_ok = (row_pixels_left != 0) && (run_pixels_left != 0);
		default: begin end
	endcase
end

wire prev_row_col_no_refill = run_bounds_ok && buffered_pairs_ok && front_refill_ok;
wire prev_row_col_advance   = tail_refill ? run_bounds_ok : prev_row_col_no_refill;

wire decoder_consumes_front    = front_advance_ok && decoder_stream_ready;
wire decoder_pair_count_commit = decoder_consumes_front &&
                                 ((decode_state == DEC_TOKEN) || (run_pixels_left != 0));

wire decoder_row_load = (decode_state == DEC_ROW_START) && decode_input_valid &&
                        !decode_input_word[0];

// A refill occurs with at most two tail bytes, so occupancy is below 32 pairs.
wire [6:0] buffered_pairs_refilled = {1'b0, 1'b1, buffered_pairs[4:0]};

logic [31:0] decode_front_next;
logic [79:0] decode_tail_next;
logic [3:0]  tail_bytes_next;
always_comb begin
	case (token_rd_byte_shift)
		2'd1:    begin
			decode_front_next = {decode_tail_refilled[7:0], decode_front[31:8]};
			decode_tail_next  = decode_tail_refilled >> 8;
		end
		2'd2:    begin
			decode_front_next = {decode_tail_refilled[15:0], decode_front[31:16]};
			decode_tail_next  = decode_tail_refilled >> 16;
		end
		default: begin
			decode_front_next = decode_front;
			decode_tail_next  = decode_tail_refilled;
		end
	endcase
	tail_bytes_next = (tail_bytes_refilled >= {2'd0, token_rd_byte_shift}) ?
	                  (tail_bytes_refilled - {2'd0, token_rd_byte_shift}) :
	                  4'd0;
end

logic [11:0] prev_row_col;
logic [11:0] prev_row_col_next = 12'd1;
always_comb begin
	if ((decode_state == DEC_IDLE) || (decode_state == DEC_ROW_START))
		prev_row_col = 12'd0;
	else if (decoder_stream_state && decoder_stream_ready)
		prev_row_col = prev_row_col_next;
	else
		prev_row_col = decode_x;
end

always_comb begin
	row0_port_a_addr = '0;
	row1_port_a_addr = '0;
	if (row_write_enable && !row_write_bank)
		row0_port_a_addr = row_write_addr[ROW_ADDR_W-1:0];
	else if (prev_row_bank == 1'b0)
		row0_port_a_addr = prev_row_col[ROW_ADDR_W-1:0];

	if (row_write_enable && row_write_bank)
		row1_port_a_addr = row_write_addr[ROW_ADDR_W-1:0];
	else if (prev_row_bank == 1'b1)
		row1_port_a_addr = prev_row_col[ROW_ADDR_W-1:0];
end

always_ff @(posedge clk_sys) begin
	if (row_write_enable && !row_write_bank)
		row0_memory[row0_port_a_addr] <= row_write_data;
	else
		row0_copy_data <= row0_memory[row0_port_a_addr];
	if (ce_pix) row0_display_data <= row0_memory[display_read_addr];
end

always_ff @(posedge clk_sys) begin
	if (row_write_enable && row_write_bank)
		row1_memory[row1_port_a_addr] <= row_write_data;
	else
		row1_copy_data <= row1_memory[row1_port_a_addr];
	if (ce_pix) row1_display_data <= row1_memory[display_read_addr];
end

logic        packet_hblank_q  =  1'b1;
logic [11:0] display_line     = 12'd0;
logic        display_bank     =  1'b0;
logic        frame_artwork_ok =  1'b0;

wire        input_line_start   = !video_hblank_in && packet_hblank_q;
wire        input_frame_start  = !video_vblank_in && packet_vblank_q;
wire        active_line_start  = ce_pix && input_line_start;
wire        active_frame_start = active_line_start && input_frame_start;
wire [11:0] next_line          = display_line + 12'd1;
wire [11:0] line_at_start      = input_frame_start ? 12'd0 : next_line;
wire        bank_at_start      = line_at_start[0];
// Compare candidates before selection, keeping CE and blanking off the
// row-number comparison path. State updates still use the qualified pulses.
wire first_row_ready    = row_valid[0] && (row_number[0] == 12'd0);
wire next_row_ready     = row_valid[next_line[0]] && (row_number[next_line[0]] == next_line);
wire row_ready_at_start = input_frame_start ? first_row_ready : next_row_ready;

// Display position remains valid while the artwork decoder is disabled.
always_ff @(posedge clk_sys) begin
	if (reset || video_timing_reset) begin
		packet_hblank_q <=  1'b1;
		display_line    <= 12'd0;
	end else if (ce_pix) begin
		packet_hblank_q <= video_hblank_in;
		if (active_line_start && !video_vblank_in) display_line <= line_at_start;
	end
end

// Row start replaces stale payload before decoder state permits its use.
always_ff @(posedge clk_sys) begin
	if (decoder_row_load) begin
		decode_front      <= decode_input_word[47:16];
		front_pair_offset <= 2'd0;
	end else if (decoder_consumes_front) begin
		decode_front      <= decode_front_next;
		front_pair_offset <= token_rd_pair_next;
	end
end

always_ff @(posedge clk_sys) begin
	fifo_rd          <= 1'b0;
	row_write_enable <= 1'b0;

	if (stream_decoder_reset) begin
		decode_state       <= DEC_IDLE;
		decode_tail        <= 80'd0;
		tail_bytes         <=  4'd0;
		buffered_pairs     <=  7'd0;
		row_pairs_left     <= 15'd0;
		row_words_left     <= 11'd0;
		row_has_words      <=  1'b0;
		decode_row         <= 12'd0;
		decode_x           <= 12'd0;
		prev_row_col_next  <= 12'd1;
		row_pixels_left    <= 12'd0;
		run_pixels_left    <=  8'd0;
		row_valid          <= 2'b00;
		row_number[0]      <= 12'd0;
		row_number[1]      <= 12'd0;
		stream_error       <=  1'b0;
		display_bank       <=  1'b0;
		frame_artwork_ok   <=  1'b0;
		decode_input_word  <= 64'd0;
		decode_input_valid <=  1'b0;
	end else begin
		if (!decode_input_valid && !fifo_empty) begin
			fifo_rd            <= 1'b1;
			decode_input_word  <= fifo_data;
			decode_input_valid <= 1'b1;
		end
		if (decode_state == DEC_TOKEN) run_pixels_left <= {1'b0, token_len_m1};

		if (tail_refill) begin
			decode_input_valid <= 1'b0;
			row_words_left     <= row_words_left - 1'b1;
			row_has_words      <= (row_words_left != 11'd1);
		end
		if (tail_refill) begin
			// Prepare the payload independently of token validation. Invalid
			// tokens enter DEC_ERROR before any prepared bytes can be used.
			decode_tail <= token_rd_state ? decode_tail_next : decode_tail_refilled;
			tail_bytes  <= front_advance_ok ? tail_bytes_next : tail_bytes_refilled;
		end else if (token_rd_state && decoder_stream_ready && (token_rd_byte_shift != 0)) begin
			decode_tail <= decode_tail_next;
			if (front_advance_ok) tail_bytes <= tail_bytes_next;
		end
		if (tail_refill) begin
			if (front_advance_ok)
				buffered_pairs <= buffered_pairs_refilled - {3'd0, token_rd_pairs};
			else
				buffered_pairs <= buffered_pairs_refilled;
		end else if (decoder_consumes_front) begin
			buffered_pairs <= buffered_pairs - {3'd0, token_rd_pairs};
		end
		if (decoder_pair_count_commit)
			row_pairs_left <= row_pairs_left - {11'd0, token_rd_pairs};
		if (prev_row_col_advance)      prev_row_col_next <= prev_row_col_next + 1'b1;

		if (vblank_rise) frame_artwork_ok <= 1'b0;

		// A missing row suppresses artwork until a new frame starts with row zero ready.
		if (active_line_start && !video_vblank_in) begin
			if (active_frame_start) begin
				display_bank     <= 1'b0;
				frame_artwork_ok <= run_requested && row_ready_at_start;
			end else begin
				row_valid[display_bank] <= 1'b0;
				display_bank            <= bank_at_start;
				if (!row_ready_at_start) frame_artwork_ok <= 1'b0;
			end
		end

		case (decode_state)
			DEC_IDLE: begin
				if (stream_active && !stream_error &&
					(decode_row < render_height) &&
					!row_valid[decode_target_bank] &&
					((decode_row == 0) ||
						(row_valid[prev_row_bank] &&
						(row_number[prev_row_bank] == decode_row - 1'b1))) &&
					decode_input_valid)
					decode_state <= DEC_ROW_START;
			end

			DEC_ROW_START: begin
				if (decode_input_valid) begin
					decode_input_valid <= 1'b0;
					if (decode_input_word[0]) begin
						decode_state <= DEC_ERROR;
					end else begin
						row_pairs_left    <= decode_input_word[15:1];
						row_words_left    <= row_start_word_count - 1'b1;
						row_has_words     <= (row_start_word_count > 11'd1);
						decode_tail       <= {64'd0, decode_input_word[63:48]};
						tail_bytes        <=  4'd2;
						buffered_pairs    <= 7'd24;
						decode_x          <= 12'd0;
						prev_row_col_next <= 12'd1;
						row_pixels_left   <= render_width;
						run_pixels_left   <= 8'd0;
						decode_state      <= DEC_ROW_PRIME;
					end
				end
			end

			DEC_ROW_PRIME: begin
				// Prime the tail before a token can shift the initial bytes.
				if (!row_has_words || tail_refill) decode_state <= DEC_TOKEN;
			end

			DEC_TOKEN: begin
				decode_state <= decoder_stream_ready ? token_ready_state : token_wait_state;
				if (token_valid && decoder_stream_ready) begin
					row_write_enable <= 1'b1;
					row_write_bank   <= decode_target_bank;
					row_write_addr   <= decode_x;
					decode_x         <= decode_x + 1'b1;
					row_pixels_left  <= row_pixels_left - 1'b1;

					if (token_is_literal || token_is_repeat) begin
						case (1'b1)
							index_4_q: begin
								row_write_data <= {4'd0, decode_window[11:8]};
								repeat_index   <= {4'd0, decode_window[11:8]};
							end
							index_6_q: begin
								row_write_data <= {2'd0, decode_window[13:8]};
								repeat_index   <= {2'd0, decode_window[13:8]};
							end
							default:   begin
								row_write_data <= decode_window[15:8];
								repeat_index   <= decode_window[15:8];
							end
						endcase
					end else begin
						row_write_data <= prev_row_data;
					end
				end
			end

			DEC_LITERAL: begin
				decode_state <= decoder_stream_ready ? literal_ready_state : literal_wait_state;
				if (literal_valid && decoder_stream_ready) begin
					row_write_enable <= 1'b1;
					row_write_bank   <= decode_target_bank;
					row_write_addr   <= decode_x;
					case (1'b1)
						index_4_q: begin
							row_write_data <= {4'd0, decode_window[3:0]};
						end
						index_6_q: begin
							row_write_data <= {2'd0, decode_window[5:0]};
						end
						default:   begin
							row_write_data <= decode_window[7:0];
						end
					endcase
					decode_x        <= decode_x + 1'b1;
					row_pixels_left <= row_pixels_left - 1'b1;
					run_pixels_left <= run_pixels_left - 1'b1;
				end
			end

			DEC_REPEAT: begin
				if ((row_pixels_left == 0) || (run_pixels_left == 0)) begin
					decode_state <= DEC_ERROR;
				end else begin
					row_write_enable <= 1'b1;
					row_write_bank   <= decode_target_bank;
					row_write_addr   <= decode_x;
					row_write_data   <= repeat_index;
					decode_x         <= decode_x + 1'b1;
					row_pixels_left  <= row_pixels_left - 1'b1;
					run_pixels_left  <= run_pixels_left - 1'b1;
					if (run_pixels_left == 8'd1) decode_state <= DEC_TOKEN;
				end
			end

			DEC_COPY: begin
				if ((row_pixels_left == 0) || (run_pixels_left == 0)) begin
					decode_state <= DEC_ERROR;
				end else begin
					row_write_enable <= 1'b1;
					row_write_bank   <= decode_target_bank;
					row_write_addr   <= decode_x;
					row_write_data   <= prev_row_data;
					decode_x         <= decode_x + 1'b1;
					row_pixels_left  <= row_pixels_left - 1'b1;
					run_pixels_left  <= run_pixels_left - 1'b1;
					if (run_pixels_left == 8'd1) decode_state <= DEC_TOKEN;
				end
			end

			DEC_FINISH: begin
				if (!row_write_enable) begin
					if (row_words_left != 0) begin
						decode_state <= DEC_ERROR;
					end else begin
						row_valid[decode_target_bank]  <= 1'b1;
						row_number[decode_target_bank] <= decode_row;
						decode_row                     <= decode_row + 1'b1;
						decode_state                   <= DEC_IDLE;
					end
				end
			end

			DEC_ERROR: begin
				stream_error     <= 1'b1;
				frame_artwork_ok <= 1'b0;
			end

			default: decode_state <= DEC_ERROR;
		endcase
	end
end

logic [11:0] display_x         = 12'd0;
wire  [11:0] input_line_number = input_line_start ? line_at_start : display_line;
wire         input_row_bank    = input_line_start ? bank_at_start : display_bank;
logic        input_line_ready, input_line_in_range;

always_comb begin
	input_line_ready    = frame_artwork_ok && row_valid[display_bank] &&
	                      (row_number[display_bank] == display_line);
	input_line_in_range = display_line < render_height;
	if (input_line_start) begin
		if (input_frame_start) begin
			input_line_ready    = first_row_ready;
			input_line_in_range = render_height != 12'd0;
		end else begin
			input_line_ready    = frame_artwork_ok && next_row_ready;
			input_line_in_range = next_line < render_height;
		end
	end
end

assign pixel_x = display_x;
assign pixel_y = input_line_number;

logic art_valid_s0;
logic art_row_ready_s0 = 1'b0;
logic row_bank_s0;

// Align the selected row's index and validity with the synchronous RAM read.
always_ff @(posedge clk_sys) begin
	if (reset || video_timing_reset) begin
		display_x           <= 12'd0;
		display_read_addr   <=    '0;
		palette_read_index  <=    '0;
		art_valid_s0        <=  1'b0;
		art_row_ready_s0    <=  1'b0;
		row_bank_s0         <=  1'b0;
		palette_index_valid <=  1'b0;
	end else if (ce_pix) begin
		if (video_hblank_in || video_vblank_in) begin
			display_x         <= 12'd0;
			display_read_addr <=    '0;
		end else begin
			display_read_addr <= display_x[ROW_ADDR_W-1:0] + 1'b1;
			display_x         <= display_x + 1'b1;
		end

		art_valid_s0        <= run_requested && !video_hblank_in && !video_vblank_in &&
		                       input_line_in_range;
		art_row_ready_s0    <= input_line_ready;
		row_bank_s0         <= input_row_bank;
		palette_index_valid <= art_valid_s0 && art_row_ready_s0;
		palette_read_index  <= row_bank_s0 ? row1_display_data : row0_display_data;
	end
end

endmodule

`default_nettype wire
