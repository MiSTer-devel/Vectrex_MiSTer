// ============================================================================
// Tile-based sparse vector framebuffer and CRT effect pipeline.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// ============================================================================

`default_nettype none

module vfb_top (
	input  wire          clk_sys,
	input  wire          clk_source,
	input  wire          reset,
	input  wire          reset_d,
	input  wire          source_reset,
	input  wire          client_reset,
	input  wire          upload_reset,
	input  wire          video_timing_reset, // Resyncs presentation without clearing framebuffer state.

	// Source pixels and ordered EOF markers
	input  wire  [10:0]  X_VECTOR,
	input  wire  [10:0]  Y_VECTOR,
	input  wire  [11:0]  Z_VECTOR,
	input  wire  [13:0]  DWELL_DOSE,
	input  wire          BEAM_ON,
	input  wire          RMW_REPLACE, // Source-pixel RMW policy, carried through the FIFO.

	// Framebuffer DDRAM
	output wire          DDRAM_CLK,
	input  wire          DDRAM_BUSY,
	output wire  [7:0]   DDRAM_BURSTCNT,
	output wire  [28:0]  DDRAM_ADDR,
	input  wire  [63:0]  DDRAM_DOUT,
	input  wire          DDRAM_DOUT_READY,
	output wire          DDRAM_RD,
	output wire  [63:0]  DDRAM_DIN,
	output wire  [7:0]   DDRAM_BE,
	output wire          DDRAM_WE,

	// Compressed primary delay
	input  wire  [15:0]  SDRAM_DQ_IN,
	output wire  [15:0]  SDRAM_DQ_OUT,
	output wire          SDRAM_DQ_OE,
	output wire          SDRAM_CKE,
	output wire          SDRAM_nCS,
	output wire          SDRAM_nRAS,
	output wire          SDRAM_nCAS,
	output wire          SDRAM_nWE,
	output wire  [1:0]   SDRAM_DQM,
	output wire  [12:0]  SDRAM_A,
	output wire  [1:0]   SDRAM_BA,

	// Raster dimensions
	input  wire  [11:0]  RENDER_WIDTH,
	input  wire  [11:0]  RENDER_HEIGHT,
	input  wire          MATTE_OPEN,
	input  wire  [11:0]  MATTE_LEFT,
	input  wire  [11:0]  MATTE_RIGHT,
	input  wire  [11:0]  MATTE_TOP,
	input  wire  [11:0]  MATTE_BOTTOM,

	// Video output
	output logic [7:0]   VGA_R,
	output logic [7:0]   VGA_G,
	output logic [7:0]   VGA_B,
	output logic         VGA_HS,
	output logic         VGA_VS,
	output logic         VGA_HBLANK,
	output logic         VGA_VBLANK,

	input  wire  [10:0]  h_cnt,
	input  wire  [10:0]  v_cnt,
	input  wire          ce_pix,
	input  wire          ce_pix_overlay,
	input  wire          hsync,
	input  wire          vsync,
	input  wire          hblank,
	input  wire          vblank,

	// Frame, buffer, and CRT controls
	input  wire          OSD_120HZ,
	input  wire          FRAME_DONE,
	input  wire  [1:0]   BUFFER_MODE,
	input  vfb_control_pkg::profile_settings_t PROFILE_SETTINGS,
	input  wire  [1:0]   HALO_DOT_REDUCTION,
	output wire          FIFO_FULL_LED,

	input  wire          full_bypass_active,
	input  wire          processed_path_prepare,
	input  wire          artwork_enable,
	input  wire  [2:0]   artwork_tint,
	input  wire  [2:0]   artwork_blend,
	input  wire  [2:0]   artwork_opaque_brightness,

	input  wire          ioctl_download,
	input  wire          ioctl_wr,
	input  wire  [15:0]  ioctl_index,
	input  wire  [24:0]  ioctl_addr,
	input  wire  [7:0]   ioctl_data,
	output wire          ioctl_wait,
	output wire          artwork_valid,
	output wire          raw_path_vblank,
	output wire          processed_path_vblank,
	// PiTrex command ring client (clk_125 domain)
	input  wire         ptx_read_ready,
	output wire         ptx_read_grant,
	input  wire [28:0]  ptx_read_addr,
	input  wire [7:0]   ptx_read_burstcnt,
	output wire [63:0]  ptx_read_data,
	output wire         ptx_read_data_valid,
	input  wire         ptx_write_ready,
	output wire         ptx_write_grant,
	output wire         ptx_write_done,
	input  wire [28:0]  ptx_write_addr,
	input  wire [7:0]   ptx_write_burstcnt,
	input  wire [63:0]  ptx_write_data,
	input  wire [7:0]   ptx_write_be,
	output wire         ptx_write_advance
);
import vfb_layout_pkg::*;
import vfb_control_pkg::*;

localparam BUFFER_COUNT   = VFB_BUFFER_COUNT;
localparam BUF_IDX_W      =  3;
localparam TILEMAP_ADDR_W = 15;

// Rasterizer and tile cache
logic        pixel_valid;
logic        pixel_ready;
logic [15:0] pixel_tile_id;
logic [5:0]  pixel_offset;
logic [15:0] pixel_data;
logic        pixel_replace;
logic        pixel_dwell_high_dose;
wire         rasterizer_fifo_full_led;


// Readout and DDRAM arbiter
wire        readout_ready;
wire        readout_grant;
wire [15:0] readout_tile_id;
wire [63:0] readout_data;
wire        readout_data_valid;
wire        flush_done_arbiter;

// End-of-frame timing
// EOF metadata carries the rounded frame period / 16.
wire        eof_token;
wire        eof_token_popped;
wire [15:0] eof_frame_tick_clks_popped;
wire [15:0] eof_elapsed_frame_tick_clks_popped;
wire [15:0] eof_completed_frame_tick_clks;

// VBLANK display request
wire vbl_swap_req;
wire readout_frame_start;

wire [BUF_IDX_W-1:0]    buf_display;
wire [BUF_IDX_W-1:0]    buf_draw;
wire [BUFFER_COUNT-1:0] buf_draw_hot;
wire                    arbiter_reset_busy;
wire                    arbiter_reset_busy_d;

assign DDRAM_CLK = clk_sys;

logic [2:0]  osd_bloom_width_vid           = BLOOM_OFF;
logic [1:0]  osd_tone_mapping_vid          = TONE_REDUCED;
logic [1:0]  osd_halo_spread_vid           = SPREAD_ORIGINAL;
logic [2:0]  osd_halo_knee_vid             = KNEE_OFF;
logic [2:0]  osd_presentation_color_vid    = COLOR_VECTREX_P4;
logic        full_bypass_active_q          = 1'b1;
logic        processed_path_prepare_q      = 1'b0;
logic [2:0]  bloom_curve_mode              = CURVE_MINIMAL;
logic [2:0]  halo_curve_mode               = CURVE_MINIMAL;
logic [2:0]  halo_filter_mode              = HALO_OFF;
logic [1:0]  osd_phosphor_mode_vid         = INTRA_OFF;
logic [1:0]  inter_frame_mode_vid          = INTER_OFF;
logic [2:0]  dwell_low_size_vid            = DWELL_SIZE_2;
logic [2:0]  dwell_mid_growth_vid          = DWELL_GROWTH_2;
logic [2:0]  dwell_high_growth_vid         = DWELL_GROWTH_SAME;
logic [1:0]  buffer_mode_vid               = BUFFER_EOF_VBL;
logic        osd_120hz_vid                 = 1'b0;
logic        artwork_enable_vid            = 1'b0;
logic [2:0]  artwork_tint_vid              = 3'd0;
logic [2:0]  artwork_blend_vid             = 3'd0;
logic [2:0]  artwork_opaque_brightness_vid = 3'd0;
logic [23:0] render_size_q                 = {12'd720, 12'd480};

always_ff @(posedge clk_sys) begin
	full_bypass_active_q     <= full_bypass_active;
	processed_path_prepare_q <= processed_path_prepare;
	render_size_q            <= {RENDER_WIDTH, RENDER_HEIGHT};
end
wire [11:0] render_width_q  = render_size_q[23:12];
wire [11:0] render_height_q = render_size_q[11:0];

// Transfer the frame-latched matte rectangle as one stable geometry packet.
typedef struct packed {
	logic        open;
	logic [11:0] left, right, top, bottom;
} matte_geometry_t;

localparam matte_geometry_t MATTE_RESET =
    '{open:1'b0, left:12'd188, right:12'd727, top:12'd0, bottom:12'd719};

matte_geometry_t matte_geometry_in;

assign matte_geometry_in = '{open:MATTE_OPEN,
                             left:MATTE_LEFT, right:MATTE_RIGHT,
                             top:MATTE_TOP,   bottom:MATTE_BOTTOM};

(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
matte_geometry_t matte_geometry_meta   = MATTE_RESET;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
matte_geometry_t matte_geometry_sync   = MATTE_RESET;
matte_geometry_t matte_geometry_sync_d = MATTE_RESET;
matte_geometry_t matte_geometry_stable = MATTE_RESET;

always_ff @(posedge clk_sys) begin
	matte_geometry_meta   <= matte_geometry_in;
	matte_geometry_sync   <= matte_geometry_meta;
	matte_geometry_sync_d <= matte_geometry_sync;
	if (matte_geometry_sync == matte_geometry_sync_d) matte_geometry_stable <= matte_geometry_sync;
end

// Register the next reset and arbiter-busy values so the client reset
// changes on the same clock edge.
(* preserve, maxfan = 64 *) logic fb_client_reset_q = 1'b1;
always_ff @(posedge clk_sys)
	fb_client_reset_q <= reset_d | arbiter_reset_busy_d;

logic filter_reset_q = 1'b1;
always_ff @(posedge clk_sys)
	filter_reset_q <= reset | video_timing_reset;

// Preserve the client-reset edge; isolate the presentation restart locally.
(* preserve, maxfan = 64 *) logic readout_reset_q = 1'b1;
always_ff @(posedge clk_sys)
	readout_reset_q <= reset_d | arbiter_reset_busy_d | video_timing_reset;

// Store each frame's draw-phase duration in source-clock ticks.
wire [3:0]           draw_idx;
wire [15:0]          active_frame_tick_clks;
wire [15:0]          completed_frame_tick_clks;
wire [3:0]           readout_draw_idx;
wire [63:0]          readout_age_map;
wire                 compose_req;
wire                 compose_done;
wire [BUF_IDX_W-1:0] compose_source_buf;
wire [BUF_IDX_W-1:0] compose_target_buf;
wire                 compose_has_source;
wire                 compose_source_is_composed;
wire                 raw_frame_dropped;
wire [BUF_IDX_W-1:0] raw_frame_dropped_buf;
wire [3:0]           compose_draw_idx;
wire [63:0]          compose_age_map;
wire [3:0]           compose_frame_age;
wire                 compose_metadata_ready;

vfb_phosphor_timing #(
	.BUFFER_COUNT (BUFFER_COUNT),
	.BUF_IDX_W    (BUF_IDX_W)
) phosphor_timing_inst (
	.clk_source                         (clk_source),
	.clk_sys                            (clk_sys),
	.reset_source                       (source_reset),
	.reset_sys                          (fb_client_reset_q),
	.frame_done                         (FRAME_DONE),

	.eof_token_popped                   (eof_token_popped),
	.eof_frame_tick_clks_popped         (eof_frame_tick_clks_popped),
	.eof_elapsed_frame_tick_clks_popped (eof_elapsed_frame_tick_clks_popped),
	.buf_draw                           (buf_draw),
	.buf_display                        (buf_display),
	.vbl_swap_req                       (vbl_swap_req),
	.presentation_120hz                 (osd_120hz_vid),
	.BUFFER_MODE                        (buffer_mode_vid),
	.compose_req                        (compose_req),
	.compose_buf                        (compose_target_buf),
	.raw_frame_dropped                  (raw_frame_dropped),
	.raw_frame_dropped_buf              (raw_frame_dropped_buf),
	.compose_draw_idx                   (compose_draw_idx),
	.compose_age_map                    (compose_age_map),
	.compose_frame_age                  (compose_frame_age),
	.compose_metadata_ready             (compose_metadata_ready),

	.draw_idx                           (draw_idx),
	.active_frame_tick_clks             (active_frame_tick_clks),
	.completed_frame_tick_clks          (completed_frame_tick_clks),
	.readout_draw_idx                   (readout_draw_idx),
	.readout_age_map                    (readout_age_map)
);

vfb_rasterizer rasterizer_inst (
	.clk_sys                       (clk_sys),
	.clk_source                    (clk_source),
	.reset                         (fb_client_reset_q),

	// Source pixels and ordered EOF markers
	.X_VECTOR                      (X_VECTOR),
	.Y_VECTOR                      (Y_VECTOR),
	.Z_VECTOR                      (Z_VECTOR),
	.DWELL_DOSE                    (DWELL_DOSE),
	.DWELL_LOW_SIZE                (dwell_low_size_vid),
	.BEAM_ON                       (BEAM_ON),
	.RMW_REPLACE                   (RMW_REPLACE),
	.FRAME_DONE                    (FRAME_DONE),
	.DWELL_MID_GROWTH              (dwell_mid_growth_vid),
	.DWELL_HIGH_GROWTH             (dwell_high_growth_vid),
	.FB_WIDTH                      (render_width_q),
	.FB_HEIGHT                     (render_height_q),

	// Tile cache output
	.pixel_valid                   (pixel_valid),
	.pixel_ready                   (pixel_ready),
	.pixel_tile_id                 (pixel_tile_id),
	.pixel_offset                  (pixel_offset),
	.pixel_data                    (pixel_data),
	.pixel_replace                 (pixel_replace),
	.pixel_dwell_high_dose         (pixel_dwell_high_dose),
	.draw_idx                      (draw_idx),
	.frame_tick_clks               (active_frame_tick_clks),
	.completed_frame_tick_clks     (completed_frame_tick_clks),


	.eof_token                     (eof_token),
	.eof_completed_frame_tick_clks (eof_completed_frame_tick_clks),
	.fifo_full_led                 (rasterizer_fifo_full_led)
);

wire        fill_ready, fill_grant;
wire [28:0] fill_addr;
wire [7:0]  fill_burstcnt;
wire [63:0] fill_data;
wire        fill_data_valid;

wire        flush_ready, flush_grant, flush_done, flush_advance;
wire [28:0] flush_addr;
wire [7:0]  flush_burstcnt;
wire [63:0] flush_din;
wire [7:0]  flush_be;

wire [14:0] display_tile_addr;
wire        display_tile_dirty;

wire                      flush_req;
wire                      clear_req;
wire [BUF_IDX_W-1:0]      clear_buf_idx;
wire                      clear_done;
wire                      has_draw_buf;
wire                      display_valid;
wire                      display_is_composed;
wire [TILEMAP_ADDR_W-1:0] compose_tilemap_addr;
wire [BUFFER_COUNT-1:0]   compose_tilemap_write_hot;
wire                      compose_tilemap_write_din;
wire [BUFFER_COUNT-1:0]   compose_tilemap_dout;

vfb_buffer_controller #(
	.BUFFER_COUNT (BUFFER_COUNT),
	.BUF_IDX_W    (BUF_IDX_W)
) buffer_controller_inst (
	.clk_sys                    (clk_sys),
	.reset                      (fb_client_reset_q),

	.BUFFER_MODE                (buffer_mode_vid),
	.inter_frame_mode           (inter_frame_mode_vid),

	.eof_token_popped           (eof_token_popped),
	.vbl_swap_req               (vbl_swap_req),

	.flush_req                  (flush_req),
	.flush_done                 (flush_done),

	.clear_req                  (clear_req),
	.clear_buf_idx              (clear_buf_idx),
	.clear_done                 (clear_done),
	.compose_req                (compose_req),
	.compose_source_buf         (compose_source_buf),
	.compose_target_buf         (compose_target_buf),
	.compose_has_source         (compose_has_source),
	.compose_source_is_composed (compose_source_is_composed),
	.compose_done               (compose_done),

	.buf_draw                   (buf_draw),
	.buf_display_out            (buf_display),
	.display_valid              (display_valid),
	.display_is_composed        (display_is_composed),

	.has_draw_buf               (has_draw_buf),
	.buf_draw_hot               (buf_draw_hot),
	.raw_frame_dropped          (raw_frame_dropped),
	.raw_frame_dropped_buf      (raw_frame_dropped_buf),
	.readout_frame_start        (readout_frame_start)
);

assign FIFO_FULL_LED = rasterizer_fifo_full_led;

vfb_tile_cache_manager #(
	.BUFFER_COUNT (BUFFER_COUNT),
	.BUF_IDX_W    (BUF_IDX_W)
) cache_manager_inst (
	.clk_sys                            (clk_sys),
	.reset                              (fb_client_reset_q),

	.FB_HEIGHT                          (render_height_q),

	// Rasterizer
	.pixel_valid                        (pixel_valid),
	.pixel_ready                        (pixel_ready),
	.pixel_tile_id                      (pixel_tile_id),
	.pixel_offset                       (pixel_offset),
	.pixel_data                         (pixel_data),
	.pixel_replace                      (pixel_replace),
	.pixel_dwell_high_dose              (pixel_dwell_high_dose),

	.eof_token                          (eof_token),
	.eof_completed_frame_tick_clks      (eof_completed_frame_tick_clks),

	// Buffer controller
	.eof_token_popped                   (eof_token_popped),
	.eof_frame_tick_clks_popped         (eof_frame_tick_clks_popped),
	.eof_elapsed_frame_tick_clks_popped (eof_elapsed_frame_tick_clks_popped),
	.flush_req                          (flush_req),
	.flush_done                         (flush_done),
	.clear_req                          (clear_req),
	.clear_buf_idx                      (clear_buf_idx),
	.clear_done                         (clear_done),
	.buf_draw                           (buf_draw),
	.buf_display                        (buf_display),
	.display_valid                      (display_valid),
	.has_draw_buf                       (has_draw_buf),
	.buf_draw_hot                       (buf_draw_hot),

	// DDRAM arbiter
	.fill_ready                         (fill_ready),
	.fill_grant                         (fill_grant),
	.fill_addr                          (fill_addr),
	.fill_burstcnt                      (fill_burstcnt),
	.fill_data                          (fill_data),
	.fill_data_valid                    (fill_data_valid),

	.flush_ready                        (flush_ready),
	.flush_grant                        (flush_grant),
	.flush_done_in                      (flush_done_arbiter),
	.flush_addr                         (flush_addr),
	.flush_burstcnt                     (flush_burstcnt),
	.flush_din                          (flush_din),
	.flush_be                           (flush_be),
	.flush_advance                      (flush_advance),

	.display_tile_addr                  (display_tile_addr),
	.display_tile_dirty                 (display_tile_dirty),
	.compose_tilemap_addr               (compose_tilemap_addr),
	.compose_tilemap_write_hot          (compose_tilemap_write_hot),
	.compose_tilemap_write_din          (compose_tilemap_write_din),
	.compose_tilemap_dout               (compose_tilemap_dout)
);

wire [28:0] readout_addr = vfb_buffer_base(buf_display) + ({13'd0, readout_tile_id} << 4);
wire [8:0]  readout_burstcnt;

wire        compose_read_ready;
wire        compose_read_grant;
wire [28:0] compose_read_addr;
wire [7:0]  compose_read_burstcnt;
wire [63:0] compose_read_data;
wire        compose_read_data_valid;
wire        compose_write_ready;
wire        compose_write_grant;
wire        compose_write_done;
wire [28:0] compose_write_addr;
wire [7:0]  compose_write_burstcnt;
wire [63:0] compose_write_data;
wire [7:0]  compose_write_be;
wire        compose_write_advance;
wire        upload_write_ready;
wire        upload_write_done;
wire [28:0] upload_write_addr;
wire [7:0]  upload_write_burstcnt;
wire [63:0] upload_write_data;
wire [7:0]  upload_write_be;
wire        upload_write_advance;
wire        artwork_read_ready;
wire        artwork_read_grant;
wire [28:0] artwork_read_addr;
wire [7:0]  artwork_read_burstcnt;
wire [63:0] artwork_read_data;
wire        artwork_read_data_valid;

vfb_phosphor_compositor #(
	.BUFFER_COUNT   (BUFFER_COUNT),
	.BUF_IDX_W      (BUF_IDX_W),
	.TILEMAP_ADDR_W (TILEMAP_ADDR_W)
) phosphor_compositor_inst (
	.clk_sys                    (clk_sys),
	.reset                      (fb_client_reset_q),
	.render_width               (render_width_q),
	.render_height              (render_height_q),
	.intra_frame_mode           (osd_phosphor_mode_vid),
	.inter_frame_mode           (inter_frame_mode_vid),
	.compose_req                (compose_req),
	.compose_source_buf         (compose_source_buf),
	.compose_target_buf         (compose_target_buf),
	.compose_has_source         (compose_has_source),
	.compose_source_is_composed (compose_source_is_composed),
	.compose_done               (compose_done),
	.raw_reference_draw_idx     (compose_draw_idx),
	.raw_age_map                (compose_age_map),
	.raw_frame_age              (compose_frame_age),
	.raw_metadata_ready         (compose_metadata_ready),
	.tilemap_addr               (compose_tilemap_addr),
	.tilemap_write_hot          (compose_tilemap_write_hot),
	.tilemap_write_din          (compose_tilemap_write_din),
	.tilemap_dout               (compose_tilemap_dout),
	.read_ready                 (compose_read_ready),
	.read_grant                 (compose_read_grant),
	.read_addr                  (compose_read_addr),
	.read_burstcnt              (compose_read_burstcnt),
	.read_data                  (compose_read_data),
	.read_data_valid            (compose_read_data_valid),
	.write_ready                (compose_write_ready),
	.write_grant                (compose_write_grant),
	.write_done                 (compose_write_done),
	.write_addr                 (compose_write_addr),
	.write_burstcnt             (compose_write_burstcnt),
	.write_data                 (compose_write_data),
	.write_be                   (compose_write_be),
	.write_advance              (compose_write_advance)
);

vfb_ddr_arbiter ddr_arbiter_inst (
	.clk_sys                 (clk_sys),
	.rst_sys                 (client_reset),

	// DDRAM Avalon-MM
	.DDRAM_BUSY              (DDRAM_BUSY),
	.DDRAM_BURSTCNT          (DDRAM_BURSTCNT),
	.DDRAM_ADDR              (DDRAM_ADDR),
	.DDRAM_RD                (DDRAM_RD),
	.DDRAM_WE                (DDRAM_WE),
	.DDRAM_DIN               (DDRAM_DIN),
	.DDRAM_BE                (DDRAM_BE),
	.DDRAM_DOUT              (DDRAM_DOUT),
	.DDRAM_DOUT_READY        (DDRAM_DOUT_READY),

	// Readout
	.readout_ready           (readout_ready),
	.readout_grant           (readout_grant),
	.readout_addr            (readout_addr),
	.readout_burstcnt        (readout_burstcnt),
	.readout_data            (readout_data),
	.readout_data_valid      (readout_data_valid),

	// Fill
	.fill_ready              (fill_ready),
	.fill_grant              (fill_grant),
	.fill_addr               (fill_addr),
	.fill_burstcnt           (fill_burstcnt),
	.fill_data               (fill_data),
	.fill_data_valid         (fill_data_valid),

	// Flush
	.flush_ready             (flush_ready),
	.flush_grant             (flush_grant),
	.flush_done              (flush_done_arbiter),
	.flush_addr              (flush_addr),
	.flush_burstcnt          (flush_burstcnt),
	.flush_din               (flush_din),
	.flush_be                (flush_be),
	.flush_advance           (flush_advance),
	.compose_read_ready      (compose_read_ready),
	.compose_read_grant      (compose_read_grant),
	.compose_read_addr       (compose_read_addr),
	.compose_read_burstcnt   (compose_read_burstcnt),
	.compose_read_data       (compose_read_data),
	.compose_read_data_valid (compose_read_data_valid),
	.compose_write_ready     (compose_write_ready),
	.compose_write_grant     (compose_write_grant),
	.compose_write_done      (compose_write_done),
	.compose_write_addr      (compose_write_addr),
	.compose_write_burstcnt  (compose_write_burstcnt),
	.compose_write_data      (compose_write_data),
	.compose_write_be        (compose_write_be),
	.compose_write_advance   (compose_write_advance),
	.upload_write_ready      (upload_write_ready),
	.upload_write_done       (upload_write_done),
	.upload_write_addr       (upload_write_addr),
	.upload_write_burstcnt   (upload_write_burstcnt),
	.upload_write_data       (upload_write_data),
	.upload_write_be         (upload_write_be),
	.upload_write_advance    (upload_write_advance),
	.artwork_read_ready      (artwork_read_ready),
	.artwork_read_grant      (artwork_read_grant),
	.artwork_read_addr       (artwork_read_addr),
	.artwork_read_burstcnt   (artwork_read_burstcnt),
	.artwork_read_data       (artwork_read_data),
	.artwork_read_data_valid (artwork_read_data_valid),
	.ptx_read_ready          (ptx_read_ready),
	.ptx_read_grant          (ptx_read_grant),
	.ptx_read_addr           (ptx_read_addr),
	.ptx_read_burstcnt       (ptx_read_burstcnt),
	.ptx_read_data           (ptx_read_data),
	.ptx_read_data_valid     (ptx_read_data_valid),
	.ptx_write_ready         (ptx_write_ready),
	.ptx_write_grant         (ptx_write_grant),
	.ptx_write_done          (ptx_write_done),
	.ptx_write_addr          (ptx_write_addr),
	.ptx_write_burstcnt      (ptx_write_burstcnt),
	.ptx_write_data          (ptx_write_data),
	.ptx_write_be            (ptx_write_be),
	.ptx_write_advance       (ptx_write_advance),
	.reset_busy              (arbiter_reset_busy),
	.reset_busy_d            (arbiter_reset_busy_d)
);

wire  [7:0]  raw_vga_r;
wire  [7:0]  raw_vga_g;
wire  [7:0]  raw_vga_b;
wire         raw_vga_hs;
wire         raw_vga_vs;
wire         raw_vga_hblank;
wire         raw_vga_vblank;
logic [27:0] raw_packet_q = {24'd0, 4'b1111};

// Synchronize OSD settings to clk_sys.
typedef struct packed {
	logic [1:0]        halo_correction;
	logic [2:0]        artwork_opaque_brightness;
	logic [2:0]        artwork_tint;
	profile_settings_t profile;
	logic [2:0]        artwork_blend;
	logic              artwork_enable;
	logic              mode_120hz;
	logic [1:0]        buffer_mode;
} osd_control_t;
osd_control_t osd_control_in;
assign        osd_control_in.halo_correction           = HALO_DOT_REDUCTION;
assign        osd_control_in.artwork_opaque_brightness = artwork_opaque_brightness;
assign        osd_control_in.artwork_tint              = artwork_tint;
assign        osd_control_in.profile                   = PROFILE_SETTINGS;
assign        osd_control_in.artwork_blend             = artwork_blend;
assign        osd_control_in.artwork_enable            = artwork_enable;
assign        osd_control_in.mode_120hz                = OSD_120HZ;
assign        osd_control_in.buffer_mode               = BUFFER_MODE;

(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
osd_control_t      osd_control_meta       = '0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
osd_control_t      osd_control_sync       = '0;
osd_control_t      osd_control_sync_d     = '0;
osd_control_t      osd_control_stable     = '0;
logic  [1:0]       halo_dot_reduction_vid = HALO_CORRECTION_NONE;
profile_settings_t profile_control_stable;
assign             profile_control_stable = osd_control_stable.profile;
logic              halo_grid_8_vid        = HALO_GRID_16;

always_ff @(posedge clk_sys) begin
	osd_control_meta   <= osd_control_in;
	osd_control_sync   <= osd_control_meta;
	osd_control_sync_d <= osd_control_sync;
	if (osd_control_sync == osd_control_sync_d) osd_control_stable <= osd_control_sync;

	buffer_mode_vid               <= osd_control_stable.buffer_mode;
	halo_dot_reduction_vid        <= osd_control_stable.halo_correction;
	osd_120hz_vid                 <= osd_control_stable.mode_120hz;
	artwork_enable_vid            <= osd_control_stable.artwork_enable;
	artwork_blend_vid             <= osd_control_stable.artwork_blend;
	artwork_tint_vid              <= osd_control_stable.artwork_tint;
	artwork_opaque_brightness_vid <= osd_control_stable.artwork_opaque_brightness;
	halo_grid_8_vid               <= profile_control_stable.halo_grid;
	dwell_high_growth_vid         <= profile_control_stable.dwell_high_growth;

	osd_halo_knee_vid             <= profile_control_stable.halo_knee;
	dwell_low_size_vid            <= profile_control_stable.dwell_low_size;
	dwell_mid_growth_vid          <= profile_control_stable.dwell_mid_growth;
	osd_tone_mapping_vid          <= profile_control_stable.tone;
	osd_bloom_width_vid           <= profile_control_stable.bloom_width;
	bloom_curve_mode              <= profile_control_stable.bloom_curve;
	halo_filter_mode              <= profile_control_stable.halo_gain;
	halo_curve_mode               <= profile_control_stable.halo_curve;
	osd_halo_spread_vid           <= profile_control_stable.halo_spread;
	inter_frame_mode_vid          <= profile_control_stable.inter_decay;
	osd_phosphor_mode_vid         <= profile_control_stable.intra_decay;
	osd_presentation_color_vid    <= profile_control_stable.color;
end

wire [15:0] raw_canonical_pixel;
wire [15:0] readout_energy;
wire        readout_hs, readout_vs, readout_hblank, readout_vblank;
// Capture readout intensity, then set it to zero outside active video.
// Carry sync and blanking through both stages alongside the intensity.
logic [11:0] raw_energy_q, visible_energy_q;
logic        raw_dwell_excess_q, visible_dwell_excess_q;
logic [3:0]  tone_sync_q, energy_sync_q;
always_ff @(posedge clk_sys) begin
	if (readout_reset_q) begin
		raw_energy_q           <=   12'd0;
		visible_energy_q       <=   12'd0;
		raw_dwell_excess_q     <=    1'b0;
		visible_dwell_excess_q <=    1'b0;
		tone_sync_q            <= 4'b1111;
		energy_sync_q          <= 4'b1111;
	end else if (ce_pix) begin
		raw_energy_q           <= readout_energy[11:0];
		raw_dwell_excess_q     <= readout_energy[12];
		tone_sync_q            <= {readout_hs, readout_vs, readout_hblank, readout_vblank};
		visible_energy_q       <= (|tone_sync_q[1:0]) ? 12'd0 : raw_energy_q;
		visible_dwell_excess_q <= !(|tone_sync_q[1:0]) && raw_dwell_excess_q;
		energy_sync_q          <= tone_sync_q;
	end
end
assign raw_canonical_pixel = {4'd0, visible_energy_q};
assign {raw_vga_hs, raw_vga_vs, raw_vga_hblank, raw_vga_vblank} = energy_sync_q;
assign raw_vga_r = vfb_energy_to_level(visible_energy_q);
assign raw_vga_g = raw_vga_r;
assign raw_vga_b = raw_vga_r;

vfb_readout readout_inst (
	.clk_sys             (clk_sys),
	.reset               (readout_reset_q),

	// DDRAM arbiter interface
	.readout_ready       (readout_ready),
	.readout_grant       (readout_grant),
	.readout_tile_id     (readout_tile_id),
	.readout_burstcnt    (readout_burstcnt),
	.readout_data        (readout_data),
	.readout_data_valid  (readout_data_valid),

	.vbl_swap_req        (vbl_swap_req),
	.frame_start_req     (readout_frame_start),

	// Readout output
	.CANONICAL_PIXEL     (readout_energy),
	.VGA_HS              (readout_hs),
	.VGA_VS              (readout_vs),
	.VGA_HBLANK          (readout_hblank),
	.VGA_VBLANK          (readout_vblank),

	.display_tile_addr   (display_tile_addr),
	.display_tile_dirty  (display_tile_dirty),

	.h_cnt               (h_cnt),
	.v_cnt               (v_cnt),
	.ce_pix              (ce_pix),
	.hsync               (hsync),
	.vsync               (vsync),
	.hblank              (hblank),
	.vblank              (vblank),

	.RENDER_WIDTH        (render_width_q),
	.RENDER_HEIGHT       (render_height_q),
	.draw_idx            (readout_draw_idx),
	.phosphor_age_map    (readout_age_map),
	.osd_phosphor_mode   (osd_phosphor_mode_vid),
	.display_is_composed (display_is_composed)
);

// Isolate grayscale conversion from final path selection while keeping the
// complete raw video sample aligned.
always_ff @(posedge clk_sys) begin
	if (readout_reset_q)
		raw_packet_q <= {24'd0, 4'b1111};
	else if (ce_pix)
		raw_packet_q <= {raw_vga_r, raw_vga_g, raw_vga_b,
		                raw_vga_hs, raw_vga_vs, raw_vga_hblank, raw_vga_vblank};
end

vfb_energy_q4_t              filtered_energy;
wire                         filtered_vga_hs;
wire                         filtered_vga_vs;
wire                         filtered_vga_hblank;
wire                         filtered_vga_vblank;
vfb_energy_q4_t              artwork_energy;
wire                         overlay_active;
vfb_color_pkg::color_coeff_t artwork_coeff;
wire                         artwork_meta_hs;
wire                         artwork_meta_vs;
wire                         artwork_meta_hblank;
wire                         artwork_meta_vblank;
wire   [7:0]                 artwork_vga_r;
wire   [7:0]                 artwork_vga_g;
wire   [7:0]                 artwork_vga_b;
wire                         artwork_vga_hs;
wire                         artwork_vga_vs;
wire                         artwork_vga_hblank;
wire                         artwork_vga_vblank;
assign                       raw_path_vblank       = raw_packet_q[0];
assign                       processed_path_vblank = artwork_vga_vblank;

wire halo_memory_overflow, halo_memory_underflow, halo_memory_ready;
vfb_halo_pipeline filter_inst (
	.clk_sys            (clk_sys),
	.ce_pix             (ce_pix),
	.reset              (filter_reset_q),

	.osd_bloom_width    (osd_bloom_width_vid),
	.bloom_curve_mode   (bloom_curve_mode),
	.halo_curve_mode    (halo_curve_mode),
	.halo_filter_mode   (halo_filter_mode),
	.overlay_active     (overlay_active),
	.halo_spread_mode   (osd_halo_spread_vid),
	.halo_knee_mode     (osd_halo_knee_vid),
	.halo_grid_8        (halo_grid_8_vid),
	.active_height      (render_height_q),

	.CANONICAL_IN       (raw_canonical_pixel[11:0]),
	.HALO_SOURCE_IN     (visible_energy_q),
	.DWELL_EXCESS_IN    (visible_dwell_excess_q),
	.halo_dot_reduction (halo_dot_reduction_vid),
	.VGA_HS_IN          (raw_vga_hs),
	.VGA_VS_IN          (raw_vga_vs),
	.VGA_HBLANK_IN      (raw_vga_hblank),
	.VGA_VBLANK_IN      (raw_vga_vblank),

	.ENERGY_OUT         (filtered_energy),
	.VGA_HS_OUT         (filtered_vga_hs),
	.VGA_VS_OUT         (filtered_vga_vs),
	.VGA_HBLANK_OUT     (filtered_vga_hblank),
	.VGA_VBLANK_OUT     (filtered_vga_vblank),

	.sdram_data_in      (SDRAM_DQ_IN),
	.sdram_data_out     (SDRAM_DQ_OUT),
	.sdram_data_oe      (SDRAM_DQ_OE),
	.sdram_cke          (SDRAM_CKE),
	.sdram_cs           (SDRAM_nCS),
	.sdram_ras          (SDRAM_nRAS),
	.sdram_cas          (SDRAM_nCAS),
	.sdram_we           (SDRAM_nWE),
	.sdram_dqm          (SDRAM_DQM),
	.sdram_addr         (SDRAM_A),
	.sdram_ba           (SDRAM_BA),
	.memory_overflow    (halo_memory_overflow),
	.memory_underflow   (halo_memory_underflow),
	.memory_ready       (halo_memory_ready)
);

vfb_overlay artwork_overlay (
	.clk_sys                   (clk_sys),
	.clk_io                    (clk_source),
	.reset                     (reset),
	.upload_reset              (upload_reset),
	.arbiter_ready             (!arbiter_reset_busy),
	.video_timing_reset        (video_timing_reset),
	.processed_path_active     (processed_path_prepare_q),
	.artwork_enable            (artwork_enable_vid),
	.artwork_tint              (artwork_tint_vid),
	.presentation_color        (osd_presentation_color_vid),
	.presentation_boost        (osd_tone_mapping_vid == TONE_BOOST),
	.artwork_blend             (artwork_blend_vid),
	.artwork_opaque_brightness (artwork_opaque_brightness_vid),
	.render_width              (render_width_q),
	.render_height             (render_height_q),
	.matte_open                (matte_geometry_stable.open),
	.matte_left                (matte_geometry_stable.left),
	.matte_right               (matte_geometry_stable.right),
	.matte_top                 (matte_geometry_stable.top),
	.matte_bottom              (matte_geometry_stable.bottom),
	.ioctl_download            (ioctl_download),
	.ioctl_wr                  (ioctl_wr),
	.ioctl_index               (ioctl_index),
	.ioctl_addr                (ioctl_addr),
	.ioctl_data                (ioctl_data),
	.ioctl_wait                (ioctl_wait),
	.artwork_valid             (artwork_valid),
	.overlay_active            (overlay_active),
	.ce_pix                    (ce_pix_overlay),
	.video_energy_in           (filtered_energy),
	.video_hs_in               (filtered_vga_hs),
	.video_vs_in               (filtered_vga_vs),
	.video_hblank_in           (filtered_vga_hblank),
	.video_vblank_in           (filtered_vga_vblank),
	.video_energy_out          (artwork_energy),
	.color_coeff_out           (artwork_coeff),
	.video_hs_out              (artwork_meta_hs),
	.video_vs_out              (artwork_meta_vs),
	.video_hblank_out          (artwork_meta_hblank),
	.video_vblank_out          (artwork_meta_vblank),
	.upload_write_ready        (upload_write_ready),
	.upload_write_done         (upload_write_done),
	.upload_write_addr         (upload_write_addr),
	.upload_write_burstcnt     (upload_write_burstcnt),
	.upload_write_data         (upload_write_data),
	.upload_write_be           (upload_write_be),
	.upload_write_advance      (upload_write_advance),
	.artwork_read_ready        (artwork_read_ready),
	.artwork_read_grant        (artwork_read_grant),
	.artwork_read_addr         (artwork_read_addr),
	.artwork_read_burstcnt     (artwork_read_burstcnt),
	.artwork_read_data         (artwork_read_data),
	.artwork_read_data_valid   (artwork_read_data_valid)
);

vfb_final_present final_present (
	.clk_sys        (clk_sys),
	.reset          (filter_reset_q),
	.ce_pix         (ce_pix_overlay),
	.tone_mapping   (osd_tone_mapping_vid),
	.ENERGY_IN      (artwork_energy),
	.COEFF_IN       (artwork_coeff),
	.VGA_HS_IN      (artwork_meta_hs),
	.VGA_VS_IN      (artwork_meta_vs),
	.VGA_HBLANK_IN  (artwork_meta_hblank),
	.VGA_VBLANK_IN  (artwork_meta_vblank),
	.VGA_R_OUT      (artwork_vga_r),
	.VGA_G_OUT      (artwork_vga_g),
	.VGA_B_OUT      (artwork_vga_b),
	.VGA_HS_OUT     (artwork_vga_hs),
	.VGA_VS_OUT     (artwork_vga_vs),
	.VGA_HBLANK_OUT (artwork_vga_hblank),
	.VGA_VBLANK_OUT (artwork_vga_vblank)
);


// Full bypass selects the unfiltered readout.
always_ff @(posedge clk_sys) begin
	if (fb_client_reset_q | video_timing_reset) begin
		VGA_R      <= 8'd0;
		VGA_G      <= 8'd0;
		VGA_B      <= 8'd0;
		VGA_HS     <= 1'b1;
		VGA_VS     <= 1'b1;
		VGA_HBLANK <= 1'b1;
		VGA_VBLANK <= 1'b1;
	end else if (ce_pix) begin
		if (full_bypass_active_q) begin
			{VGA_R, VGA_G, VGA_B, VGA_HS, VGA_VS, VGA_HBLANK, VGA_VBLANK} <= raw_packet_q;
		end else begin
			VGA_R      <= artwork_vga_r;
			VGA_G      <= artwork_vga_g;
			VGA_B      <= artwork_vga_b;
			VGA_HS     <= artwork_vga_hs;
			VGA_VS     <= artwork_vga_vs;
			VGA_HBLANK <= artwork_vga_hblank;
			VGA_VBLANK <= artwork_vga_vblank;
		end
	end
end

endmodule

`default_nettype wire
