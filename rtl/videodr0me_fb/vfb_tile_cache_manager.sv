// ============================================================================
// Tile cache manager for sparse vector pixel writes.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Stores 8x8 tiles with four phase bits, a dwell-excess bit and 11 energy bits.
// Associative slots are flushed and filled in DDRAM bursts. Clean tilemaps clear
// the background without rewriting it. A first write to an empty pixel skips RMW.
// ============================================================================

`default_nettype none

module vfb_tile_cache_manager #(
	parameter integer BUFFER_COUNT = 5,
	parameter integer BUF_IDX_W = 3
) (
	input  wire  clk_sys,
	input  wire  reset,

	input  wire  [11:0] FB_HEIGHT,

	// Rasterizer
	input  wire         pixel_valid,
	output logic        pixel_ready,
	input  wire  [15:0] pixel_tile_id,
	input  wire  [5:0]  pixel_offset,  // 64 pixels per tile
	input  wire  [15:0] pixel_data,    // phase[15:12], dwell_excess[11], energy[10:0]
	input  wire         pixel_replace,
	input  wire         pixel_dwell_high_dose,

	input  wire         eof_token,
	input  wire  [15:0] eof_completed_frame_tick_clks,

	// Buffer controller
	output logic                    eof_token_popped,
	output logic [15:0]             eof_frame_tick_clks_popped,
	output logic [15:0]             eof_elapsed_frame_tick_clks_popped,
	input  wire                     flush_req,
	output logic                    flush_done = 1'b0,
	input  wire                     clear_req,
	input  wire  [BUF_IDX_W-1:0]    clear_buf_idx,
	output logic                    clear_done,
	input  wire  [BUF_IDX_W-1:0]    buf_draw,
	input  wire  [BUF_IDX_W-1:0]    buf_display,
	input  wire                     display_valid,
	input  wire                     has_draw_buf,
	input  wire  [BUFFER_COUNT-1:0] buf_draw_hot,

	// DDRAM fill
	output logic        fill_ready,
	input  wire         fill_grant,
	output logic [28:0] fill_addr,
	output logic [7:0]  fill_burstcnt,
	input  wire  [63:0] fill_data,
	input  wire         fill_data_valid,

	// DDRAM flush
	output logic        flush_ready,
	input  wire         flush_grant,
	input  wire         flush_done_in,
	output logic [28:0] flush_addr,
	output logic [7:0]  flush_burstcnt,
	output logic [63:0] flush_din,      // Current beat data
	output logic [7:0]  flush_be,       // Current beat byte enables
	input  wire         flush_advance,  // Beat accepted, present next

	// Readout tilemap
	input  wire  [14:0] display_tile_addr,
	output logic        display_tile_dirty,

	// Compositor tilemap port. All maps are read in parallel; only the
	// composing destination map may be written through this port.
	input  wire  [14:0]             compose_tilemap_addr,
	input  wire  [BUFFER_COUNT-1:0] compose_tilemap_write_hot,
	input  wire                     compose_tilemap_write_din,
	output logic [BUFFER_COUNT-1:0] compose_tilemap_dout
);

import vfb_layout_pkg::*;

localparam integer CACHE_COUNT = 4;
localparam integer CACHE_IDX_W = $clog2(CACHE_COUNT);

// Delay the renderer reset by two clocks before restarting cache state.
logic [1:0] reset_delay = 2'b11;
always_ff @(posedge clk_sys) reset_delay <= {reset_delay[0], reset};
wire cache_reset = reset_delay[1];

localparam TILEMAP_ADDR_W = 15;
localparam TILEMAP_DEPTH  = 1 << TILEMAP_ADDR_W;

typedef struct packed {
	logic                      eof;
	logic [15:0]               completed_frame_tick_clks;
	logic [15:0]               pixel_data;
	logic                      pixel_replace;
	logic                      dwell_high_dose;
	logic [15:0]               tile_id;
	logic [3:0]                offset_word;
	logic [1:0]                pixel_lane;
	logic [63:0]               offset_mask;
	logic [TILEMAP_ADDR_W-1:0] tilemap_addr;
} raster_request_t;

typedef struct packed {
	logic            valid;
	raster_request_t request;
} input_slot_t;

typedef struct packed {
	logic                   active;
	logic [CACHE_IDX_W-1:0] slot;
	logic                   is_eof;
	logic                   modified_during_flush;
} flush_context_t;

logic [63:0] pixel_offset_mask;
genvar offset_bit;
generate
	for (offset_bit = 0; offset_bit < 64; offset_bit = offset_bit + 1) begin : gen_pixel_offset_mask
		localparam logic [5:0] OFFSET                        = offset_bit[5:0];
		assign                 pixel_offset_mask[offset_bit] = (pixel_offset == OFFSET);
	end
endgenerate

// Two-entry input buffer.
raster_request_t        input_request;
input_slot_t            input_front_q;
input_slot_t            input_spill_q;
logic [CACHE_COUNT-1:0] r_hit_hot;
logic                   r_hit_valid;

always_comb begin
	input_request.eof                       = eof_token;
	input_request.completed_frame_tick_clks = eof_completed_frame_tick_clks;
	input_request.pixel_data                = pixel_data;
	input_request.pixel_replace             = pixel_replace;
	input_request.dwell_high_dose           = pixel_dwell_high_dose;
	input_request.tile_id                   = pixel_tile_id;
	input_request.offset_word               = pixel_offset[5:2];
	input_request.pixel_lane                = pixel_offset[1:0];
	input_request.offset_mask               = pixel_offset_mask;
	input_request.tilemap_addr              = vfb_linear_tile_addr(pixel_tile_id);
end

logic s0_ready;

logic  load_primary, load_buffer, unload_buffer;
assign load_primary  = pixel_ready && pixel_valid &&
                       (!input_front_q.valid || s0_ready) && !input_spill_q.valid;
assign load_buffer   = pixel_ready && pixel_valid &&
                       input_front_q.valid && !s0_ready;
assign unload_buffer = s0_ready && input_spill_q.valid;

// Stop input when both entries are occupied.
assign pixel_ready = !input_spill_q.valid;

always_ff @(posedge clk_sys) begin
	if (cache_reset) begin
		input_front_q.valid <= 1'b0;
		input_spill_q.valid <= 1'b0;
	end else begin
		if (load_primary || unload_buffer)
			input_front_q.valid <= 1'b1;
		else if (s0_ready)
			input_front_q.valid <= 1'b0;

		if (load_buffer)
			input_spill_q.valid <= 1'b1;
		else if (unload_buffer)
			input_spill_q.valid <= 1'b0;

		if (load_buffer) input_spill_q.request <= input_request;
		if (load_primary) begin
			input_front_q.request <= input_request;
		end else if (unload_buffer) begin
			input_front_q.request <= input_spill_q.request;
		end
	end
end

wire             s0_valid = input_front_q.valid;
raster_request_t s0;
assign           s0 = input_front_q.request;

// Read-modify-write states.
typedef enum logic [3:0] {
	RMW_IDLE,
	RMW_READ,
	RMW_READ2,
	RMW_BLEND,
	RMW_WAIT_FILL,
	RMW_WAIT_FILL_FINISH,
	RMW_MODIFY,
	RMW_WAIT_DIRTY_BIT,
	RMW_FLUSH_ALL,
	RMW_WAIT_FLUSH_REQ_LOW
} rmw_state_t;
rmw_state_t rmw_state;




wire [28:0] draw_buf_base = vfb_buffer_base(buf_draw);

// Each cache slot holds one 8x8 tile as sixteen 64-bit words.
logic [3:0]             s1_offset_word;
logic [1:0]             s1_pixel_lane;
logic [CACHE_IDX_W-1:0] s1_cache_idx;
logic [CACHE_IDX_W-1:0] hit_idx;

flush_context_t flush_q;

// Cache writes are prepared here and applied one clock later.
logic        cache_wr_en [0:CACHE_COUNT-1];
logic        cache_wr_full [0:CACHE_COUNT-1];     // 1: full-word fill; 0: 16-bit pixel write
logic [3:0]  cache_wr_word [0:CACHE_COUNT-1];
logic [1:0]  cache_wr_lane [0:CACHE_COUNT-1];     // 16-bit position within the word
logic [15:0] cache_wr_data_16_q;                  // shared partial write data
logic [63:0] cache_wr_data_64 [0:CACHE_COUNT-1];  // full write data (fill)

// All slots read the same registered word address.
logic [3:0]  cache_read_addr_q;
logic [63:0] cache_ram_out [0:CACHE_COUNT-1];

(* ramstyle = "logic" *) logic [63:0] cache_ram [0:CACHE_COUNT-1][0:15];

always_ff @(posedge clk_sys) begin
	for(int i=0; i<CACHE_COUNT; i++) begin
		if (cache_wr_en[i]) begin
			if (cache_wr_full[i]) begin
				cache_ram[i][cache_wr_word[i]] <= cache_wr_data_64[i];
			end else begin
				if (cache_wr_lane[i] == 2'd0)
					cache_ram[i][cache_wr_word[i]][15:0] <= cache_wr_data_16_q;
				if (cache_wr_lane[i] == 2'd1)
					cache_ram[i][cache_wr_word[i]][31:16] <= cache_wr_data_16_q;
				if (cache_wr_lane[i] == 2'd2)
					cache_ram[i][cache_wr_word[i]][47:32] <= cache_wr_data_16_q;
				if (cache_wr_lane[i] == 2'd3)
					cache_ram[i][cache_wr_word[i]][63:48] <= cache_wr_data_16_q;
			end
		end
	end

	for (int i = 0; i < CACHE_COUNT; i++) begin
		cache_ram_out[i] <= cache_ram[i][cache_read_addr_q];
	end
end

logic        cache_valid [0:CACHE_COUNT-1];
logic        cache_dirty [0:CACHE_COUNT-1];
logic [15:0] cache_tile_id [0:CACHE_COUNT-1];
logic [63:0] cache_bitmap [0:CACHE_COUNT-1];

// Find a matching cache slot.
logic [CACHE_COUNT-1:0] cache_hit_hot;
logic                   cache_hit;
logic                   dirty_hit;

logic [CACHE_COUNT-1:0] slot_dirty_hit;
always_comb begin
	hit_idx        =  0;
	slot_dirty_hit = '0;
	for (int i = 0; i < CACHE_COUNT; i++) begin
		if (cache_hit_hot[i]) hit_idx = i[CACHE_IDX_W-1:0];
		slot_dirty_hit[i] = |(cache_bitmap[i] & s0.offset_mask);
	end
	cache_hit = |cache_hit_hot;

	// Test the requested pixel against each matching bitmap.
	dirty_hit = |(cache_hit_hot & slot_dirty_hit);
end

assign cache_hit_hot = r_hit_hot;

// Pseudo-LRU replacement.
logic [2:0]             plru_state      = 3'b0;
wire                    sel_right_half  = plru_state[0];
wire                    sel_qtr         = sel_right_half ? plru_state[2] : plru_state[1];
wire  [CACHE_IDX_W-1:0] plru_victim_way = {sel_right_half, sel_qtr};

// Select slots for allocation and eviction.

// Register slot state before replacement selection.
logic [CACHE_COUNT-1:0] slot_dirty;

always_ff @(posedge clk_sys) begin
	for (int i = 0; i < CACHE_COUNT; i++) begin
		slot_dirty[i] <= cache_valid[i] && cache_dirty[i];
	end
end

// Register the selected free slot.
logic [CACHE_COUNT-1:0] slot_avail_d;
logic [CACHE_IDX_W-1:0] free_idx_d;
logic                   has_free_d;
logic [CACHE_IDX_W-1:0] free_idx_q;
logic                   has_free_q;

always_comb begin
	for (int i = 0; i < CACHE_COUNT; i++) begin
		slot_avail_d[i] = (!cache_valid[i] || !cache_dirty[i]);
	end

	has_free_d = |slot_avail_d;
	free_idx_d = plru_victim_way;

	if (!slot_avail_d[plru_victim_way]) begin
		if      (slot_avail_d[plru_victim_way + 2'd1]) free_idx_d = plru_victim_way + 2'd1;
		else if (slot_avail_d[plru_victim_way + 2'd2]) free_idx_d = plru_victim_way + 2'd2;
		else                                           free_idx_d = plru_victim_way + 2'd3;
	end
end

// Register the eviction priority-encoder result.
logic [CACHE_IDX_W-1:0] lru_dirty_idx;
logic                   has_lru_dirty;

always_ff @(posedge clk_sys) begin
	has_lru_dirty <= |slot_dirty;
	lru_dirty_idx <= plru_victim_way;

	// If the PLRU victim is clean, select the next dirty slot in circular order.
	if (!slot_dirty[plru_victim_way]) begin
		if      (slot_dirty[plru_victim_way + 2'd1]) lru_dirty_idx <= plru_victim_way + 2'd1;
		else if (slot_dirty[plru_victim_way + 2'd2]) lru_dirty_idx <= plru_victim_way + 2'd2;
		else                                         lru_dirty_idx <= plru_victim_way + 2'd3;
	end
end

// Per-framebuffer dirty maps.
// The maps support up to 184 x 135 tiles. A 192-tile row stride keeps
// addressing to shifts and adds while each map remains within 32K entries.
logic [TILEMAP_ADDR_W-1:0] buf_tilemap_addr [0:BUFFER_COUNT-1];
logic                      buf_tilemap_we [0:BUFFER_COUNT-1];
logic                      buf_tilemap_din [0:BUFFER_COUNT-1];
logic                      buf_tilemap_dout [0:BUFFER_COUNT-1];

genvar g;
generate
	for (g = 0; g < BUFFER_COUNT; g++) begin : gen_dirty_ram
		(* ramstyle = "no_rw_check, M10K" *) logic buf_tilemap [0:TILEMAP_DEPTH-1];
		wire                      compose_write       = compose_tilemap_write_hot[g];
		wire                      tilemap_port_a_we   = compose_write || buf_tilemap_we[g];
		wire [TILEMAP_ADDR_W-1:0] tilemap_port_a_addr = compose_write ? compose_tilemap_addr
		                                                              : buf_tilemap_addr[g];
		wire                      tilemap_port_a_din  = compose_write ? compose_tilemap_write_din
		                                                              : buf_tilemap_din[g];

		always_ff @(posedge clk_sys) begin
			if (tilemap_port_a_we) buf_tilemap[tilemap_port_a_addr] <= tilemap_port_a_din;
			buf_tilemap_dout[g]     <= buf_tilemap[tilemap_port_a_addr];
			compose_tilemap_dout[g] <= buf_tilemap[compose_tilemap_addr];
		end
	end
endgenerate

// Tilemap clearing.
logic [TILEMAP_ADDR_W-1:0] bg_clear_tile;
logic [BUF_IDX_W-1:0]      active_clear_buf;

typedef enum logic [1:0] {
	CLEAR_INIT,
	CLEAR_IDLE,
	CLEAR_PROCESS,
	CLEAR_WAIT_FINISH
} clear_state_t;
clear_state_t clear_state = CLEAR_INIT;

logic clearer_init_done = 0;
always_ff @(posedge clk_sys) begin
	if (cache_reset) clearer_init_done <= 0;
	else if (!clearer_init_done && clear_state != CLEAR_INIT)
		clearer_init_done <= 1;
end

// Mode-dependent clear limit. FB_HEIGHT changes only as part of a
// framebuffer mode reset.
localparam [8:0]                TILE_ROWS_DEFAULT      = 9'd60;     // 480p
localparam [15:0]               TILEMAP_ENTRIES_DEFAULT = VFB_TILEMAP_ENTRIES_480;
localparam [TILEMAP_ADDR_W-1:0] TILEMAP_MAX_DEFAULT     = 15'd11519;

logic [8:0]                tile_rows_r       = TILE_ROWS_DEFAULT;
logic [15:0]               tilemap_entries_r = TILEMAP_ENTRIES_DEFAULT;
logic [TILEMAP_ADDR_W-1:0] tilemap_max       = TILEMAP_MAX_DEFAULT;

always_ff @(posedge clk_sys) begin
	if (cache_reset) begin
		tile_rows_r       <= TILE_ROWS_DEFAULT;
		tilemap_entries_r <= TILEMAP_ENTRIES_DEFAULT;
		tilemap_max       <= TILEMAP_MAX_DEFAULT;
	end else begin
		tile_rows_r       <= vfb_tile_rows(FB_HEIGHT);
		tilemap_entries_r <= vfb_tilemap_entries(tile_rows_r);
		tilemap_max       <= tilemap_entries_r[TILEMAP_ADDR_W-1:0] - 1'b1;
	end
end

logic [15:0]            s1_pixel_data;
logic                   s1_pixel_replace;
logic                   s1_dwell_high_dose;
logic [15:0]            s1_tile_id;
logic [CACHE_IDX_W-1:0] s1_alloc_idx;
logic [63:0]            s1_offset_mask_reg;

// Keep the selected slot fixed while waiting for DDRAM.
logic [CACHE_IDX_W-1:0] flush_evict_idx;

// Update replacement history.
logic                   s1_lru_en  = 0;
logic [CACHE_IDX_W-1:0] s1_lru_idx = 0;

always_ff @(posedge clk_sys) begin
	if (cache_reset) begin
		plru_state <= 3'b0;
	end else if (s1_lru_en) begin
		plru_state[0] <= ~s1_lru_idx[1];
		if (s1_lru_idx[1] == 1'b0) plru_state[1] <= ~s1_lru_idx[0];
		else                       plru_state[2] <= ~s1_lru_idx[0];
	end
end


// Select the cached pixel after the RAM read.
logic [11:0] s2_cached_pixel;
always_ff @(posedge clk_sys) begin
	if (rmw_state == RMW_READ2) begin
		case (s1_pixel_lane)
			2'b00: s2_cached_pixel <= cache_ram_out[s1_cache_idx][11:0];
			2'b01: s2_cached_pixel <= cache_ram_out[s1_cache_idx][27:16];
			2'b10: s2_cached_pixel <= cache_ram_out[s1_cache_idx][43:32];
			2'b11: s2_cached_pixel <= cache_ram_out[s1_cache_idx][59:48];
		endcase
	end
end

// Fallback selects the stronger energy/marker pair; ties take the new pair.
// Accumulation adds energy and uses the stronger contribution's marker,
// favoring unmarked ties and clearing excess on a high-dose overlap.
wire [10:0] energy_new        = s1_pixel_data[10:0];
wire [10:0] energy_old        = s2_cached_pixel[10:0];
wire [11:0] energy_sum        = {1'b0, energy_old} + {1'b0, energy_new};
wire [11:0] replacement_pixel = (energy_new >= energy_old) ? s1_pixel_data[11:0] : s2_cached_pixel;
wire        dwell_excess      = s1_pixel_replace ? replacement_pixel[11] :
                                (energy_old == 11'd0) ? s1_pixel_data[11] :
                                    s1_dwell_high_dose ? 1'b0 :
                                        (energy_new > energy_old) ? s1_pixel_data[11] :
                                            (energy_new < energy_old) ? s2_cached_pixel[11] :
                                                (s1_pixel_data[11] && s2_cached_pixel[11]);

logic [11:0] blend_energy_q;
logic        blend_dwell_excess_q;
logic [3:0]  blend_draw_idx_q;
wire  [10:0] energy_saturated = blend_energy_q[11] ? 11'h7ff : blend_energy_q[10:0];

vfb_frame_pixel_t blended_pixel;
assign            blended_pixel.phase        = blend_draw_idx_q;
assign            blended_pixel.dwell_excess = blend_dwell_excess_q && (|energy_saturated);
assign            blended_pixel.energy       = energy_saturated;

// Cache-flush request and data path.
logic                   flush_all                  = 0;
logic [CACHE_IDX_W-1:0] eof_flush_idx              = 0;
wire                    normal_flush_releases_slot = flush_done_in && !flush_all &&
                                                     !flush_q.modified_during_flush &&
                                                     !cache_wr_en[flush_q.slot];

always_ff @(posedge clk_sys) begin
	if (cache_reset) begin
		has_free_q <= 1'b0;
		free_idx_q <=   '0;
	end else if (normal_flush_releases_slot) begin
		// Expose the just-flushed slot immediately so allocation does not start
		// another eviction before the free-slot scan updates.
		has_free_q <= 1'b1;
		free_idx_q <= flush_q.slot;
	end else begin
		has_free_q <= has_free_d;
		free_idx_q <= free_idx_d;
	end
end

// Flush beat counter owned by cache manager, advanced by arbiter.
logic [3:0] flush_beat_int = 0;

// The requested slot is captured before a flush becomes visible to DDRAM.
// Keep the live EOF scan index out of the cache RAM address path.
wire [CACHE_IDX_W-1:0] flush_read_idx = flush_q.active ? flush_q.slot : flush_evict_idx;

// Preload words 0/1 and per-slot word 2 while arbitration is pending.
// Read each slot one beat ahead of slot selection; stalls hold both stages.
logic [63:0] flush_data_cur;
logic [63:0] flush_data_nxt;
logic [63:0] flush_prefetch_q [0:CACHE_COUNT-1];
// Keep the registered word decode local to each slot's wide read mux.
(* preserve, dont_merge *) logic [15:0] flush_fetch_hot_q [0:CACHE_COUNT-1];
wire [63:0] flush_fetch_data [0:CACHE_COUNT-1];

genvar flush_slot, flush_bit, flush_word;
generate
	for (flush_slot = 0; flush_slot < CACHE_COUNT; flush_slot = flush_slot + 1) begin : flush_word_select
		for (flush_bit = 0; flush_bit < 64; flush_bit = flush_bit + 1) begin : data_bit
			wire [15:0] selected_bits;
			for (flush_word = 0; flush_word < 16; flush_word = flush_word + 1) begin : word_bit
				assign selected_bits[flush_word] = cache_ram[flush_slot][flush_word][flush_bit] &
				                                   flush_fetch_hot_q[flush_slot][flush_word];
			end
			assign flush_fetch_data[flush_slot][flush_bit] = |selected_bits;
		end
	end
endgenerate

always_ff @(posedge clk_sys) begin
	if (flush_advance) begin
		flush_data_cur <= flush_data_nxt;
		flush_data_nxt <= flush_prefetch_q[flush_read_idx];
		for (int i = 0; i < CACHE_COUNT; i++) begin
			flush_prefetch_q[i] <= flush_fetch_data[i];
			// After accepting beat N, prepare word N+4 for the next fetch.
			for (int w = 0; w < 16; w++)
				flush_fetch_hot_q[i][w] <= (flush_beat_int == 4'(w - 4));
		end
	end else if (flush_ready && !flush_q.active) begin
		flush_data_cur <= cache_ram[flush_evict_idx][4'd0];
		flush_data_nxt <= cache_ram[flush_evict_idx][4'd1];
		for (int i = 0; i < CACHE_COUNT; i++) begin
			flush_prefetch_q[i]  <= cache_ram[i][4'd2];
			flush_fetch_hot_q[i] <= 16'h0008;
		end
	end
end

logic [63:0] flush_bitmap_reg;

// Flush complete words, writing zero to pixel lanes absent from the bitmap.
assign flush_din = {
	flush_bitmap_reg[{flush_beat_int, 2'd3}] ? flush_data_cur[63:48] : 16'd0,
	flush_bitmap_reg[{flush_beat_int, 2'd2}] ? flush_data_cur[47:32] : 16'd0,
	flush_bitmap_reg[{flush_beat_int, 2'd1}] ? flush_data_cur[31:16] : 16'd0,
	flush_bitmap_reg[{flush_beat_int, 2'd0}] ? flush_data_cur[15:0]  : 16'd0
};

// Each 8x8 tile occupies sixteen 64-bit DDRAM beats.
assign flush_burstcnt = 8'd16;

assign flush_be = 8'hFF;

logic  [3:0] fill_beat_int =     0;
assign       fill_burstcnt = 8'd16;

// Prepare the row before the synchronous cache-array read. Active read
// states retain the accepted pixel row while IDLE prepares the front entry.
always_ff @(posedge clk_sys)
	cache_read_addr_q <= (rmw_state == RMW_IDLE) ? s0.offset_word : s1_offset_word;

// Wait one clock for the synchronous tilemap read.
logic s1_dirty_valid = 0;
logic s1_tile_clean  = 0;

// Delay buf_display to match the tilemap RAM.
logic [BUF_IDX_W-1:0] buf_display_d1;
always_ff @(posedge clk_sys) begin
	buf_display_d1 <= buf_display;
end

// Report clean until initialization completes.
assign display_tile_dirty = (clearer_init_done && display_valid) ? buf_tilemap_dout[buf_display_d1]
                                                                 : 1'b0;

logic [TILEMAP_ADDR_W-1:0] s1_tilemap_addr;
logic [TILEMAP_ADDR_W-1:0] draw_tilemap_addr;
logic                      draw_we;
logic                      draw_din;
logic [TILEMAP_ADDR_W-1:0] rmw_tilemap_addr_q;
logic                      rmw_tilemap_mark_q;

always_comb begin
	draw_tilemap_addr = s0.tilemap_addr;
	draw_we           = 0;
	draw_din          = 0;

	if (rmw_tilemap_mark_q) begin
		draw_tilemap_addr = rmw_tilemap_addr_q;
		draw_we           = 1;
		draw_din          = 1;
	end
end

always_comb begin
	for (int i = 0; i < BUFFER_COUNT; i++) begin
		buf_tilemap_we[i]   = 0;
		buf_tilemap_addr[i] = 0;
		buf_tilemap_din[i]  = 0;
	end

	if (!clearer_init_done) begin
		for (int i = 0; i < BUFFER_COUNT; i++) begin
			buf_tilemap_addr[i] = bg_clear_tile;
			buf_tilemap_din[i]  = 0;
			buf_tilemap_we[i]   = 1;
		end
	end else begin
		for (int i = 0; i < BUFFER_COUNT; i++) begin
			automatic logic is_display = display_valid && (buf_display == BUF_IDX_W'(i));
			automatic logic is_clear   =
			    (clear_state == CLEAR_PROCESS && active_clear_buf == BUF_IDX_W'(i));
			automatic logic is_draw    = buf_draw_hot[i];

			if (is_display) begin
				buf_tilemap_addr[i] = display_tile_addr;
			end else if (is_clear) begin
				buf_tilemap_addr[i] = bg_clear_tile;
				if (clear_state == CLEAR_PROCESS) begin
					buf_tilemap_we[i]  = 1;
					buf_tilemap_din[i] = 0;
				end
			end else if (is_draw) begin
				buf_tilemap_addr[i] = draw_tilemap_addr;
				buf_tilemap_we[i]   = draw_we;
				buf_tilemap_din[i]  = draw_din;
			end
		end
	end
end

// Clear tilemaps.
always_ff @(posedge clk_sys) begin
	if (cache_reset) begin
		clear_state      <= CLEAR_INIT;
		bg_clear_tile    <=  0;
		clear_done       <=  0;
		active_clear_buf <= '0;
	end else begin
		case (clear_state)
			CLEAR_INIT: begin
				if (bg_clear_tile == TILEMAP_ADDR_W'(TILEMAP_DEPTH-1)) begin
					clear_state   <= CLEAR_IDLE;
					bg_clear_tile <= 0;
				end else begin
					bg_clear_tile <= bg_clear_tile + 1'b1;
				end
			end

			CLEAR_IDLE: begin
				if (clear_req) begin
					bg_clear_tile    <= 0;
					active_clear_buf <= clear_buf_idx;  // Keep fixed for the sweep.
					clear_state      <= CLEAR_PROCESS;
				end
			end

			CLEAR_PROCESS: begin
				if (bg_clear_tile >= tilemap_max) clear_state <= CLEAR_WAIT_FINISH;
				else bg_clear_tile <= bg_clear_tile + 1'b1;
			end

			CLEAR_WAIT_FINISH: begin
				// Hold completion until the request is released.
				if (!clear_req) begin
					clear_done  <= 0;
					clear_state <= CLEAR_IDLE;
				end else begin
					clear_done <= 1;
				end
			end
		endcase
	end
end

// Match cache tags before selecting the next input entry.
logic [CACHE_COUNT-1:0] primary_tag_match_hot;
logic [CACHE_COUNT-1:0] buffered_tag_match_hot;
logic [CACHE_COUNT-1:0] current_tag_match_hot;
always_comb begin
	primary_tag_match_hot  = '0;
	buffered_tag_match_hot = '0;
	current_tag_match_hot  = '0;
	for (int i = 0; i < CACHE_COUNT; i++) begin
		primary_tag_match_hot[i]  = cache_valid[i] && (cache_tile_id[i] == pixel_tile_id);
		buffered_tag_match_hot[i] = cache_valid[i] &&
		                            (cache_tile_id[i] == input_spill_q.request.tile_id);
		current_tag_match_hot[i]  = cache_valid[i] && (cache_tile_id[i] == s0.tile_id);
	end
end

wire fast_tag_allocation = (rmw_state == RMW_WAIT_DIRTY_BIT) && s1_dirty_valid &&
                           has_free_q && s1_tile_clean;
wire fill_tag_allocation = (rmw_state == RMW_WAIT_FILL) && fill_data_valid &&
                           (fill_beat_int == 4'd15);
wire tag_map_unstable    = (rmw_state == RMW_FLUSH_ALL) ||
                           fast_tag_allocation || fill_tag_allocation;

// Accept pixels after initialization while no full flush is active.
logic manager_ready = 0;
always_ff @(posedge clk_sys) begin
	manager_ready <= has_draw_buf && clearer_init_done;
end

assign s0_ready = (rmw_state == RMW_IDLE) && manager_ready &&
                  !flush_req && (!s0_valid || r_hit_valid);

always_ff @(posedge clk_sys) begin
	if (cache_reset) begin
		r_hit_hot   <=   '0;
		r_hit_valid <= 1'b0;
	end else if (tag_map_unstable) begin
		r_hit_valid <= 1'b0;
	end else if (load_primary) begin
		r_hit_hot   <= primary_tag_match_hot;
		r_hit_valid <= 1'b1;
	end else if (unload_buffer) begin
		r_hit_hot   <= buffered_tag_match_hot;
		r_hit_valid <= 1'b1;
	end else if (input_front_q.valid && !r_hit_valid) begin
		r_hit_hot   <= current_tag_match_hot;
		r_hit_valid <= 1'b1;
	end else if (s0_ready && input_front_q.valid) begin
		r_hit_valid <= 1'b0;
	end
end

// Cache controller.
always_ff @(posedge clk_sys) begin
	if (cache_reset) begin
		rmw_state                          <= RMW_IDLE;
		fill_ready                         <=     0;
		flush_ready                        <=     0;
		flush_q                            <=    '0;
		flush_all                          <=     0;
		flush_done                         <=     0;
		eof_token_popped                   <=     0;
		eof_frame_tick_clks_popped         <= 16'd0;
		eof_elapsed_frame_tick_clks_popped <= 16'd0;
		flush_beat_int                     <=     0;
		fill_beat_int                      <=     0;
		s1_dirty_valid                     <=  1'b0;
		s1_tile_clean                      <=  1'b0;
		s1_tilemap_addr                    <=    '0;
		rmw_tilemap_addr_q                 <=    '0;
		rmw_tilemap_mark_q                 <=  1'b0;
		for(int i=0; i<CACHE_COUNT; i++) begin
			cache_valid[i]  <= 0;
			cache_dirty[i]  <= 0;
			cache_bitmap[i] <= 0;
			cache_wr_en[i]  <= 0;
		end
	end else begin

		eof_token_popped                   <= 0;
		eof_frame_tick_clks_popped         <= s0.pixel_data;
		eof_elapsed_frame_tick_clks_popped <= s0.completed_frame_tick_clks;
		flush_done                         <= 0;

		for (int i = 0; i < CACHE_COUNT; i++) cache_wr_en[i] <= 0;
		s1_lru_en          <=    0;
		rmw_tilemap_mark_q <= 1'b0;

		// Clear dirty only if the slot did not change during its flush.
		if (flush_done_in) begin
			flush_q.active                <= 1'b0;
			flush_q.modified_during_flush <= 1'b0;

			if (normal_flush_releases_slot) begin
				cache_dirty[flush_q.slot] <= 0;
			end
		end

		// Snapshot the cache bitmap when the arbiter grants this flush.
		if (flush_ready && flush_grant) begin
			flush_ready      <=    0;
			flush_q.active   <= 1'b1;
			flush_q.slot     <= flush_evict_idx;
			flush_q.is_eof   <= flush_all;
			flush_bitmap_reg <= cache_bitmap[flush_evict_idx];

			// A cache write on this edge may be newer than the prepared flush word.
			flush_q.modified_during_flush <= cache_wr_en[flush_evict_idx];

		end else if (flush_q.active && cache_wr_en[flush_q.slot]) begin
			// A write during the burst makes the DDRAM copy outdated.
			flush_q.modified_during_flush <= 1'b1;
		end

		if (fill_ready && fill_grant) begin
			fill_ready <= 0;
		end

		if (flush_advance)   flush_beat_int <= flush_beat_int + 1'b1;
		if (fill_data_valid) fill_beat_int  <= fill_beat_int + 1'b1;

		case (rmw_state)
			RMW_IDLE: begin
				if (flush_req || flush_all) begin
					flush_all     <= 1;
					eof_flush_idx <= 0;
					rmw_state     <= RMW_FLUSH_ALL;
				end else if (s0_valid && s0_ready) begin
					if (s0.eof) begin
						// EOF reached the front of the input buffer.
						eof_token_popped <= 1;
					end else begin
						s1_pixel_data      <= s0.pixel_data;
						s1_pixel_replace   <= s0.pixel_replace;
						s1_dwell_high_dose <= s0.dwell_high_dose;
						s1_tile_id         <= s0.tile_id;
						s1_tilemap_addr    <= s0.tilemap_addr;
						s1_offset_word     <= s0.offset_word;
						s1_pixel_lane      <= s0.pixel_lane;
						s1_offset_mask_reg <= s0.offset_mask;

						// Write a previously untouched cached pixel directly.
						cache_wr_data_16_q <= s0.pixel_data;
						for (int i = 0; i < CACHE_COUNT; i++) begin
							cache_wr_full[i] <= 0;
							cache_wr_word[i] <= s0.offset_word;
							cache_wr_lane[i] <= s0.pixel_lane;
						end

						for (int i = 0; i < CACHE_COUNT; i++) begin
							if (cache_hit_hot[i]) begin
								cache_dirty[i] <= 1'b1;
								if (!slot_dirty_hit[i]) begin
									cache_wr_en[i]  <= 1;
									cache_bitmap[i] <= cache_bitmap[i] | s0.offset_mask;
								end
							end
						end

						if (cache_hit) begin
							s1_lru_en  <= 1;
							s1_lru_idx <= hit_idx;

							// Keep the selected slot for a possible RMW operation.
							s1_cache_idx <= hit_idx;

							if (dirty_hit) begin
								// Existing pixel: read and blend.
								rmw_state <= RMW_READ;
							end
						end else begin
							// Cache miss: read the tilemap.
							s1_dirty_valid <= 0;
							rmw_state      <= RMW_WAIT_DIRTY_BIT;
						end
					end
				end
			end

			RMW_WAIT_DIRTY_BIT: begin
				if (!s1_dirty_valid) begin
					// Wait for the synchronous tilemap result.
					s1_dirty_valid <= 1;
					s1_tile_clean  <= !buf_tilemap_dout[buf_draw];
				end else begin
					if (has_free_q) begin
						if (s1_tile_clean) begin
							// Clean tile: allocate and write directly.
							cache_valid[free_idx_q]   <= 1;
							cache_tile_id[free_idx_q] <= s1_tile_id;
							cache_dirty[free_idx_q]   <= 1;
							cache_bitmap[free_idx_q]  <= s1_offset_mask_reg;

							s1_lru_en  <= 1;
							s1_lru_idx <= free_idx_q;

							cache_wr_en[free_idx_q]   <= 1;
							cache_wr_full[free_idx_q] <= 0;
							cache_wr_word[free_idx_q] <= s1_offset_word;
							cache_wr_lane[free_idx_q] <= s1_pixel_lane;
							cache_wr_data_16_q        <= s1_pixel_data;
							rmw_tilemap_addr_q        <= s1_tilemap_addr;
							rmw_tilemap_mark_q        <= 1'b1;

							rmw_state <= RMW_IDLE;
						end else begin
							// Dirty tile: fetch it from DDRAM.
							fill_ready    <= 1;
							fill_beat_int <= 0;
							fill_addr     <= draw_buf_base + ({13'd0, s1_tile_id} << 4);
							s1_alloc_idx  <= free_idx_q;
							rmw_state     <= RMW_WAIT_FILL;
						end
					end else begin
						// All slots are dirty; flush one before retrying.
						if (has_lru_dirty && !flush_ready && !flush_q.active) begin
							flush_ready      <= 1;
							flush_beat_int   <= 0;
							flush_evict_idx  <= lru_dirty_idx;
							flush_addr       <= draw_buf_base +
							                    ({13'd0, cache_tile_id[lru_dirty_idx]} << 4);
							flush_bitmap_reg <= cache_bitmap[lru_dirty_idx];
						end
					end
				end
			end

			RMW_FLUSH_ALL: begin
				if (cache_valid[eof_flush_idx] && cache_dirty[eof_flush_idx]) begin
					if (!flush_ready && !flush_q.active) begin
						flush_ready      <= 1;
						flush_beat_int   <= 0;
						flush_evict_idx  <= eof_flush_idx; // Select slot for flush pre-read.
						flush_addr       <= draw_buf_base +
						                    ({13'd0, cache_tile_id[eof_flush_idx]} << 4);
						flush_bitmap_reg <= cache_bitmap[eof_flush_idx];
					end else if (flush_q.active && (flush_q.slot == eof_flush_idx)) begin
						// Wait for the active flush to finish.
					end
				end

				if ((cache_valid[eof_flush_idx] && cache_dirty[eof_flush_idx] &&
						flush_q.active && (flush_q.slot == eof_flush_idx) &&
						flush_done_in && flush_q.is_eof) ||
					!(cache_valid[eof_flush_idx] && cache_dirty[eof_flush_idx])) begin

					if (eof_flush_idx == (CACHE_COUNT - 1)) begin
						flush_all  <= 0;
						rmw_state  <= RMW_WAIT_FLUSH_REQ_LOW;
						flush_done <= 1;
						for (int i = 0; i < CACHE_COUNT; i++) begin
							cache_valid[i]  <= 0;
							cache_dirty[i]  <= 0;
							cache_bitmap[i] <= 0;
						end
					end else begin
						eof_flush_idx <= eof_flush_idx + 1'b1;
					end
				end
			end

			RMW_WAIT_FILL: begin
				if (fill_grant) fill_ready <= 0;
				if (fill_data_valid) begin
					cache_wr_en[s1_alloc_idx]      <= 1;
					cache_wr_full[s1_alloc_idx]    <= 1;
					cache_wr_word[s1_alloc_idx]    <= fill_beat_int;
					cache_wr_data_64[s1_alloc_idx] <= fill_data;
				end
				if (fill_data_valid && fill_beat_int == 4'd15) begin
					cache_valid[s1_alloc_idx]   <= 1;
					cache_tile_id[s1_alloc_idx] <= s1_tile_id;
					// The filled tile now contains every pixel.
					cache_bitmap[s1_alloc_idx] <= 64'hFFFFFFFFFFFFFFFF;
					cache_dirty[s1_alloc_idx]  <=                    0;

					s1_lru_en    <= 1;
					s1_lru_idx   <= s1_alloc_idx;
					s1_cache_idx <= s1_alloc_idx;

					rmw_state <= RMW_WAIT_FILL_FINISH;
				end
			end

			RMW_WAIT_FILL_FINISH: begin
				rmw_state <= RMW_READ;
			end

			RMW_READ: begin
				// The requested cache row is now available.
				rmw_state <= RMW_READ2;
			end
			RMW_READ2: begin
				rmw_state <= RMW_BLEND;
			end

			RMW_BLEND: begin
				blend_energy_q       <= s1_pixel_replace ? {1'b0, replacement_pixel[10:0]}
				                                         : energy_sum;
				blend_draw_idx_q     <= s1_pixel_data[15:12];
				blend_dwell_excess_q <= dwell_excess;

				rmw_tilemap_addr_q <= s1_tilemap_addr;
				rmw_tilemap_mark_q <= 1'b1;
				rmw_state          <= RMW_MODIFY;
			end

			RMW_MODIFY: begin
				cache_wr_en[s1_cache_idx]   <= 1;
				cache_wr_full[s1_cache_idx] <= 0;
				cache_wr_word[s1_cache_idx] <= s1_offset_word;
				cache_wr_lane[s1_cache_idx] <= s1_pixel_lane;
				cache_wr_data_16_q          <= blended_pixel;

				cache_bitmap[s1_cache_idx] <= cache_bitmap[s1_cache_idx] | s1_offset_mask_reg;
				cache_dirty[s1_cache_idx]  <= 1'b1;
				rmw_state                  <= RMW_IDLE;
			end

			RMW_WAIT_FLUSH_REQ_LOW: begin
				if (!flush_req) begin
					rmw_state  <= RMW_IDLE;
					flush_done <= 0;
				end else begin
					flush_done <= 1;
				end
			end
		endcase
	end
end
endmodule

`default_nettype wire
