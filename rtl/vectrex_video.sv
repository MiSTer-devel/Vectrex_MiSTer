//============================================================================
// Vectrex vector presentation.
//
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Converts the emulated beam into fixed progressive rasters, manages atomic
// output-mode transitions, drives the framebuffer and CRT-effects pipeline,
// and converts 720x480p timing into fields for 480i output.
// HD modes use 916x720 and 1360x1080. CRT modes use 720 samples horizontally.
//============================================================================

`default_nettype none

module vectrex_video
#(
	parameter logic [24:0] HEIGHT_STABLE_CYCLES = 25'd25_000_000
)
(
	input wire clk_sys,        // 24 MHz, the core's clock
	input wire clk_50,
	input wire clk_125,        // framebuffer and SDRAM clock
	input wire reset,
	input wire vfb_clock_reset,
	input wire reset_source,

	// In normal orientation, beam_y maps to raster x and beam_x to raster y.
	input wire signed [19:0] beam_x,
	input wire signed [19:0] beam_y,
	input wire        [7:0]  beam_z,
	input wire               beam_on,
	input wire               beam_tick,    // clken_12
	input wire               beam_zero_n,  // CA2: integrators held at zero
	input wire               t2_reload,
	input wire        [15:0] t2_period,

	input wire [11:0] hdmi_height,
	input wire        direct_video,
	input wire        direct_video_31khz,
	input wire        crt_15khz_480i,
	input wire [2:0]  crt_vertical_position,
	input wire        mode_120hz,
	input wire [1:0]  aspect_ratio,

	// Resolved presentation profile and Vectrex-specific overrides.
	input vfb_control_pkg::profile_settings_t    profile_settings,
	input vfb_control_pkg::diagnostic_settings_t diagnostic_settings,
	input wire                                   effects_bypass,
	input wire [1:0]                             buffer_mode,
	input wire [1:0]                             v_orient,       // 0 = normal, 1 = 90 CCW, 2 = 90 CW
	input wire                                   open_matte,
	input wire                                   zoom_normal,
	input wire                                   vertical_offset,
	input wire [1:0]                             beam_threshold,

	// VART artwork is stored in DDRAM and composited after CRT effects to model
	// a physical overlay in front of the display.
	input  wire        overlay_off,
	input  wire [2:0]  ovl_tint,
	input  wire [2:0]  ovl_bright,
	input  wire [2:0]  ovl_opaque_bright,
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [15:0] ioctl_index,
	input  wire [24:0] ioctl_addr,
	input  wire [7:0]  ioctl_data,
	output wire        ioctl_wait,
	output wire        artwork_valid,

	// Video out
	output wire         clk_video,
	output wire         ce_pixel,
	output wire  [7:0]  vga_r,
	output wire  [7:0]  vga_g,
	output wire  [7:0]  vga_b,
	output wire         vga_hs,
	output wire         vga_vs,
	output wire         vga_hblank,
	output wire         vga_vblank,
	output wire         field,
	output logic [12:0] video_arx,
	output logic [12:0] video_ary,
	output wire         mode_is_15khz,
	output wire         mode_supports_120hz,
	output wire  [1:0]  profile_resolution,
	output wire         video_mode_toggle,
	output wire         video_freeze,

	// Framebuffer memory
	output wire        ddram_clk,
	input  wire        ddram_busy,
	output wire [7:0]  ddram_burstcnt,
	output wire [28:0] ddram_addr,
	input  wire [63:0] ddram_dout,
	input  wire        ddram_dout_ready,
	output wire        ddram_rd,
	output wire [63:0] ddram_din,
	output wire [7:0]  ddram_be,
	output wire        ddram_we,

	inout  wire [15:0] sdram_dq,
	output wire        sdram_clk,
	output wire        sdram_cke,
	output wire        sdram_ncs,
	output wire        sdram_nras,
	output wire        sdram_ncas,
	output wire        sdram_nwe,
	output wire        sdram_dqml,
	output wire        sdram_dqmh,
	output wire [12:0] sdram_a,
	output wire [1:0]  sdram_ba,

	// PiTrex command ring client (clk_125 domain)
	input  wire        ptx_read_ready,
	output wire        ptx_read_grant,
	input  wire [28:0] ptx_read_addr,
	input  wire [7:0]  ptx_read_burstcnt,
	output wire [63:0] ptx_read_data,
	output wire        ptx_read_data_valid,
	input  wire        ptx_write_ready,
	output wire        ptx_write_grant,
	output wire        ptx_write_done,
	input  wire [28:0] ptx_write_addr,
	input  wire [7:0]  ptx_write_burstcnt,
	input  wire [63:0] ptx_write_data,
	input  wire [7:0]  ptx_write_be,
	output wire        ptx_write_advance,

	output wire fifo_full_led
);
import vfb_control_pkg::*;

// ----------------------------------------------------------------- reset ---
logic [1:0] reset_pipe_125 = 2'b11;
always_ff @(posedge clk_125 or posedge reset) begin
	if (reset) reset_pipe_125 <= 2'b11;
	else       reset_pipe_125 <= {reset_pipe_125[0], 1'b0};
end
wire reset_125 = reset_pipe_125[1];

(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic clock_reset_125_meta = 1'b1, clock_reset_125 = 1'b1;
always_ff @(posedge clk_125) begin
	clock_reset_125_meta <= vfb_clock_reset;
	clock_reset_125      <= clock_reset_125_meta;
end

// ----------------------------------------------------------- mode input ---
// Accept an input height after it stays unchanged for HEIGHT_STABLE_CYCLES at 50 MHz.
// With Direct Video off, keep the accepted HDMI height until video clock reset.
// With Direct Video on, allow height changes from the 15/31 kHz selection.
// The 240p/480i setting selects the final framebuffer height separately.
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [11:0] height_meta_50 = 12'd0, height_sync_50 = 12'd0;
logic [11:0] height_candidate_50 = 12'd0, height_stable_50 = 12'd0;
logic [24:0] height_timer_50 = 25'd0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic        direct_video_meta_50 = 1'b0, direct_video_sync_50 = 1'b0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic        direct_31khz_meta_50 = 1'b0, direct_31khz_sync_50 = 1'b0;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic        clock_reset_50_meta = 1'b1, clock_reset_50 = 1'b1;

wire [11:0] requested_height_50 = direct_video_sync_50 ? (direct_31khz_sync_50 ? 12'd480 : 12'd240)
                                                       : hdmi_height;

always_ff @(posedge clk_50) begin
	clock_reset_50_meta  <= vfb_clock_reset;
	clock_reset_50       <= clock_reset_50_meta;
	direct_video_meta_50 <= direct_video;
	direct_video_sync_50 <= direct_video_meta_50;
	direct_31khz_meta_50 <= direct_video_31khz;
	direct_31khz_sync_50 <= direct_31khz_meta_50;
	height_meta_50       <= requested_height_50;
	height_sync_50       <= height_meta_50;

	if (clock_reset_50) begin
		height_candidate_50 <= 12'd0;
		height_stable_50    <= 12'd0;
		height_timer_50     <= 25'd0;
	end else if ((height_stable_50 == 12'd0) || direct_video_sync_50) begin
		if ((height_sync_50 <= 12'd200) || (height_sync_50 != height_candidate_50)) begin
			height_candidate_50 <= height_sync_50;
			height_timer_50     <= 25'd0;
		end else if (height_candidate_50 != height_stable_50) begin
			if (height_timer_50 < HEIGHT_STABLE_CYCLES - 1'd1)
				height_timer_50 <= height_timer_50 + 1'd1;
			else begin
				height_stable_50 <= height_candidate_50;
				height_timer_50  <= 25'd0;
			end
		end else begin
			height_timer_50 <= 25'd0;
		end
	end else begin
		height_candidate_50 <= height_stable_50;
		height_timer_50     <= 25'd0;
	end
end

wire  [19:0] control_in = {crt_vertical_position, height_stable_50, mode_120hz, effects_bypass,
                          direct_video, direct_video_31khz, crt_15khz_480i};
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [19:0] control_meta = '0, control_sync = '0;
logic [19:0] control_sync_d = '0, control_stable = '0;

always_ff @(posedge clk_125) begin
	control_meta   <= control_in;
	control_sync   <= control_meta;
	control_sync_d <= control_sync;
	if (control_sync == control_sync_d) control_stable <= control_sync;
end

// ---------------------------------------------------------------- modes ---
localparam logic [1:0] PIXEL_FULL       = 2'd0;
localparam logic [1:0] PIXEL_HALF       = 2'd1;
localparam logic [1:0] PIXEL_FRACTIONAL = 2'd3;

typedef struct packed {
	logic        [11:0] fb_width;
	logic        [11:0] fb_height;
	logic        [12:0] optimized_arx;
	logic        [12:0] optimized_ary;
	logic        [11:0] h_total;
	logic        [11:0] v_total;
	logic        [11:0] hs_start;
	logic        [11:0] hs_end;
	logic        [11:0] vs_start;
	logic        [11:0] vs_end;
	logic        [1:0]  pixel_mode;
	logic        [18:0] pixel_step;
	logic signed [19:0] pixel_wrap_step;
	logic               is_1080p;
	logic               is_720p;
	logic               is_480p;
	logic               is_240p;
	logic               is_120hz;
	logic               is_interlaced;
	logic signed [4:0]  crt_vertical_offset;
} video_mode_t;

typedef struct packed {
	video_mode_t timing;
	logic        bypass;
} video_path_mode_t;

function automatic video_mode_t decode_video_mode(
	input  logic [11:0] height,
	input  logic        requested_120hz,
	input  logic        requested_interlace,
	input  logic [2:0]  requested_crt_position
);
	video_mode_t mode;
	logic signed [4:0] crt_offset;
	begin
		case (requested_crt_position)
			3'd1:    crt_offset = height < 12'd480 ?  5'sd2 :  5'sd4;
			3'd2:    crt_offset = height < 12'd480 ?  5'sd4 :  5'sd8;
			3'd3:    crt_offset = height < 12'd480 ?  5'sd6 :  5'sd12;
			3'd4:    crt_offset = height < 12'd480 ? -5'sd2 : -5'sd4;
			3'd5:    crt_offset = height < 12'd480 ? -5'sd4 : -5'sd8;
			3'd6:    crt_offset = height < 12'd480 ? -5'sd6 : -5'sd10;
			default: crt_offset = 5'sd0;
		endcase

		mode               =      '0;
		mode.fb_width      = 12'd916;
		mode.fb_height     = 12'd720;
		mode.optimized_arx = (height >= 12'd1440) ? (13'h1000 | 13'd1832) : (13'h1000 | 13'd916);
		mode.optimized_ary = (height >= 12'd1440) ? (13'h1000 | 13'd1440) : (13'h1000 | 13'd720);
		mode.h_total       = 12'd1388;
		mode.v_total       =  12'd748;
		mode.hs_start      = 12'd1108;
		mode.hs_end        = 12'd1196;
		mode.vs_start      =  12'd728;
		mode.vs_end        =  12'd733;
		mode.pixel_mode    = requested_120hz ? PIXEL_FULL : PIXEL_HALF;
		mode.is_720p       = 1'b1;
		mode.is_120hz      = requested_120hz;

		if ((height >= 12'd1080) && (height < 12'd1400)) begin
			mode.fb_width      = 12'd1360;
			mode.fb_height     = 12'd1080;
			mode.optimized_arx = 13'h1000 | 13'd1360;
			mode.optimized_ary = 13'h1000 | 13'd1080;
			mode.h_total       = 12'd1851;
			mode.v_total       = 12'd1124;
			mode.hs_start      = 12'd1600;
			mode.hs_end        = 12'd1688;
			mode.vs_start      = 12'd1088;
			mode.vs_end        = 12'd1093;
			mode.pixel_mode    = PIXEL_FULL;
			mode.is_1080p      = 1'b1;
			mode.is_720p       = 1'b0;
			mode.is_120hz      = 1'b0;
		end else if (height < 12'd480) begin
			mode.fb_width        = 12'd720;
			mode.fb_height       = 12'd240;
			mode.optimized_arx   = 13'h1000 | 13'd720;
			mode.optimized_ary   = 13'h1000 | 13'd240;
			mode.h_total         = 12'd883;
			mode.v_total         = 12'd263;
			mode.hs_start        = 12'd755;
			mode.hs_end          = 12'd821;
			mode.vs_start        = 12'(13'sd246 - crt_offset);
			mode.vs_end          = 12'(13'sd249 - crt_offset);
			mode.pixel_mode      = PIXEL_FRACTIONAL;
			mode.pixel_step      =  19'd29172;
			mode.pixel_wrap_step = -20'sd231505;
			mode.is_720p         = 1'b0;
			mode.is_240p         = 1'b1;
			mode.is_120hz        = 1'b0;

			mode.crt_vertical_offset = crt_offset;
		end else if (height < 12'd720) begin
			mode.fb_width        = 12'd720;
			mode.fb_height       = 12'd480;
			mode.optimized_arx   = 13'h1000 | 13'd720;
			mode.optimized_ary   = 13'h1000 | 13'd480;
			mode.h_total         = 12'd883;
			mode.v_total         = 12'd528;
			mode.hs_start        = 12'd755;
			mode.hs_end          = 12'd821;
			mode.vs_start        = 12'(13'sd493 - crt_offset);
			mode.vs_end          = 12'(13'sd499 - crt_offset);
			mode.pixel_mode      = PIXEL_FRACTIONAL;
			mode.pixel_step      = 19'd116909;
			mode.pixel_wrap_step = -20'sd404445;
			mode.is_720p         = 1'b0;
			mode.is_480p         = 1'b1;
			mode.is_120hz        = 1'b0;
			mode.is_interlaced   = requested_interlace;

			mode.crt_vertical_offset = crt_offset;
		end

		decode_video_mode = mode;
	end
endfunction

wire [11:0] stable_height         = control_stable[16:5];
wire        stable_120hz          = control_stable[4];
wire        request_bypass        = control_stable[3];
wire        stable_direct_video   = control_stable[2];
wire        stable_direct_31khz   = control_stable[1];
wire        stable_480i           = control_stable[0];
wire        height_supports_120hz = !stable_direct_video && (stable_height >= 12'd720) &&
                                    (stable_height <= 12'd768);
wire        request_120hz         = stable_120hz && height_supports_120hz;

logic [11:0] request_height;
logic        request_interlaced;
always_comb begin
	request_height     = stable_height;
	request_interlaced = 1'b0;
	if (stable_direct_video) begin
		request_height     = stable_direct_31khz ? 12'd480 : (stable_480i ? 12'd480 : 12'd240);
		request_interlaced = !stable_direct_31khz && stable_480i;
	end else if (stable_height < 12'd480) begin
		request_height     = stable_480i ? 12'd480 : 12'd240;
		request_interlaced = stable_480i;
	end
end

logic             request_valid = 1'b0;
video_path_mode_t requested_path;
always_ff @(posedge clk_125) begin
	request_valid         <= stable_height > 12'd200;
	requested_path.timing <= decode_video_mode(request_height, request_120hz, request_interlaced,
	                                          control_stable[19:17]);
	requested_path.bypass <= request_bypass;
end

// Freeze at active VBL; commit timing/geometry at frame wrap.
// Switch at target VBL or restart wrap, then hold one target frame.
typedef enum logic [2:0] {
	MODE_WAIT_START,
	MODE_START_TIMING,
	MODE_START_HOLD,
	MODE_RUN,
	MODE_WAIT_ACTIVE_VBLANK,
	MODE_WAIT_TIMING_WRAP,
	MODE_WAIT_TARGET_VBLANK,
	MODE_HOLD_TARGET_FRAME
} mode_state_t;

mode_state_t      mode_state = MODE_WAIT_START;
video_path_mode_t active_path_q;
video_path_mode_t pending_path_q;
logic             mode_ready               = 1'b0;
logic             video_mode_toggle_q      = 1'b0;
logic             video_freeze_q           = 1'b1;
logic             processed_path_prepare_q = 1'b0;
logic             transition_timing_q      = 1'b0;
logic             transition_restart_q     = 1'b0;
logic             mode_restart_q           = 1'b0;
logic             frame_wrap;
logic             raw_path_vblank, processed_path_vblank;
logic             raw_path_vblank_q = 1'b1, processed_path_vblank_q = 1'b1;
logic             output_vblank_q = 1'b1, output_vblank_entry_q = 1'b0;

wire raw_path_vblank_entry       = raw_path_vblank       && !raw_path_vblank_q;
wire processed_path_vblank_entry = processed_path_vblank && !processed_path_vblank_q;

wire progressive_active_vblank_entry = active_path_q.bypass ? raw_path_vblank_entry
                                                            : processed_path_vblank_entry;
wire progressive_target_vblank_entry = pending_path_q.bypass ? raw_path_vblank_entry
                                                             : processed_path_vblank_entry;

wire active_path_vblank_entry = active_path_q.timing.is_interlaced ?
                                output_vblank_entry_q :
                                progressive_active_vblank_entry;
wire target_path_vblank_entry = pending_path_q.timing.is_interlaced ?
                                output_vblank_entry_q :
                                progressive_target_vblank_entry;

wire request_mode_changed = (requested_path.timing.fb_height != active_path_q.timing.fb_height) ||
    (requested_path.timing.is_120hz != active_path_q.timing.is_120hz) ||
    (requested_path.timing.is_interlaced != active_path_q.timing.is_interlaced) ||
    (requested_path.timing.crt_vertical_offset != active_path_q.timing.crt_vertical_offset);
wire request_changed      = request_mode_changed || (requested_path.bypass != active_path_q.bypass);

wire profile_path_commit = (mode_state == MODE_WAIT_TARGET_VBLANK) && !transition_restart_q &&
                           target_path_vblank_entry &&
                           (pending_path_q.bypass != active_path_q.bypass);
wire mode_commit         = (mode_state == MODE_WAIT_TIMING_WRAP) && frame_wrap;
wire timing_reset        = !mode_ready;

logic mode_commit_q = 1'b0;
always_ff @(posedge clk_125) begin
	if (clock_reset_125 || timing_reset)
		mode_commit_q <= 1'b0;
	else
		mode_commit_q <= mode_commit;
end

logic [1:0] renderer_reset_pipe = 2'b11;
always_ff @(posedge clk_125)
	renderer_reset_pipe <= {renderer_reset_pipe[0], reset_125 || !mode_ready || mode_restart_q};
wire renderer_reset = renderer_reset_pipe[1];

logic [1:0] source_reset_pipe = 2'b11;
always_ff @(posedge clk_sys)
	source_reset_pipe <= {source_reset_pipe[0], reset_source || !mode_ready || mode_restart_q};
wire source_reset = source_reset_pipe[1];

assign video_mode_toggle = video_mode_toggle_q;
assign video_freeze      = video_freeze_q;

always_ff @(posedge clk_125) begin
	if (clock_reset_125 || !mode_ready) begin
		raw_path_vblank_q       <= 1'b1;
		processed_path_vblank_q <= 1'b1;
		output_vblank_q         <= 1'b1;
		output_vblank_entry_q   <= 1'b0;
	end else begin
		raw_path_vblank_q       <= raw_path_vblank;
		processed_path_vblank_q <= processed_path_vblank;
		output_vblank_entry_q   <= ce_pixel && vga_vblank && !output_vblank_q;
		if (ce_pixel) output_vblank_q <= vga_vblank;
	end
end

always_ff @(posedge clk_125) begin
	if (clock_reset_125) begin
		active_path_q.timing     <= decode_video_mode(12'd720, 1'b0, 1'b0, 3'd0);
		active_path_q.bypass     <= 1'b1;
		pending_path_q.timing    <= decode_video_mode(12'd720, 1'b0, 1'b0, 3'd0);
		pending_path_q.bypass    <= 1'b1;
		processed_path_prepare_q <= 1'b0;
		transition_timing_q      <= 1'b0;
		transition_restart_q     <= 1'b0;
		mode_restart_q           <= 1'b0;
		mode_state               <= MODE_WAIT_START;
		mode_ready               <= 1'b0;
		video_mode_toggle_q      <= 1'b0;
		video_freeze_q           <= 1'b1;
	end else begin
		case (mode_state)
			MODE_WAIT_START: begin
				mode_ready     <= 1'b0;
				video_freeze_q <= 1'b1;
				mode_restart_q <= 1'b0;
				if (request_valid) begin
					active_path_q            <= requested_path;
					pending_path_q           <= requested_path;
					processed_path_prepare_q <= !requested_path.bypass;
					mode_state               <= MODE_START_TIMING;
				end
			end

			MODE_START_TIMING: begin
				mode_ready     <= 1'b1;
				video_freeze_q <= 1'b1;
				mode_state     <= MODE_START_HOLD;
			end

			MODE_START_HOLD: begin
				if (frame_wrap) begin
					video_freeze_q <= 1'b0;
					mode_state     <= MODE_RUN;
				end
			end

			MODE_RUN: begin
				video_freeze_q       <= 1'b0;
				mode_restart_q       <= 1'b0;
				transition_restart_q <= 1'b0;
				if (request_valid && request_changed) begin
					pending_path_q <= requested_path;
					if (!requested_path.bypass) processed_path_prepare_q <= 1'b1;
					mode_state <= MODE_WAIT_ACTIVE_VBLANK;
				end
			end

			MODE_WAIT_ACTIVE_VBLANK: begin
				if (request_valid && !request_changed) begin
					processed_path_prepare_q <= !active_path_q.bypass;
					mode_state               <= MODE_RUN;
				end else if (request_valid) begin
					pending_path_q <= requested_path;
					if (!requested_path.bypass) processed_path_prepare_q <= 1'b1;
					if (active_path_vblank_entry) begin
						transition_timing_q  <= (requested_path.timing.h_total !=
						     active_path_q.timing.h_total) ||
						    (requested_path.timing.v_total != active_path_q.timing.v_total) ||
						    (requested_path.timing.pixel_mode != active_path_q.timing.pixel_mode) ||
						    (requested_path.timing.is_interlaced !=
						     active_path_q.timing.is_interlaced) ||
						    (requested_path.timing.crt_vertical_offset !=
						     active_path_q.timing.crt_vertical_offset);
						transition_restart_q <= (requested_path.timing.fb_width !=
						     active_path_q.timing.fb_width) ||
						    (requested_path.timing.fb_height != active_path_q.timing.fb_height);
						video_freeze_q       <= 1'b1;
						mode_state           <= request_mode_changed ? MODE_WAIT_TIMING_WRAP
						                                             : MODE_WAIT_TARGET_VBLANK;
					end
				end
			end

			MODE_WAIT_TIMING_WRAP: begin
				video_freeze_q <= 1'b1;
				if (frame_wrap) begin
					active_path_q.timing <= pending_path_q.timing;
					if (transition_timing_q) video_mode_toggle_q <= !video_mode_toggle_q;
					mode_restart_q <= transition_restart_q;
					mode_state     <= MODE_WAIT_TARGET_VBLANK;
				end
			end

			MODE_WAIT_TARGET_VBLANK: begin
				video_freeze_q <= 1'b1;
				if (transition_restart_q && frame_wrap) begin
					mode_restart_q           <= 1'b0;
					active_path_q.bypass     <= pending_path_q.bypass;
					processed_path_prepare_q <= !pending_path_q.bypass;
					mode_state               <= MODE_HOLD_TARGET_FRAME;
				end else if (!transition_restart_q && target_path_vblank_entry) begin
					active_path_q.bypass     <= pending_path_q.bypass;
					processed_path_prepare_q <= !pending_path_q.bypass;
					if (!transition_timing_q && (pending_path_q.bypass != active_path_q.bypass))
						video_mode_toggle_q <= !video_mode_toggle_q;
					mode_state <= MODE_HOLD_TARGET_FRAME;
				end
			end

			MODE_HOLD_TARGET_FRAME: begin
				video_freeze_q <= 1'b1;
				if (transition_restart_q && frame_wrap) begin
					transition_restart_q <= 1'b0;
					video_freeze_q       <= 1'b0;
					mode_state           <= MODE_RUN;
				end else if (!transition_restart_q && target_path_vblank_entry) begin
					video_freeze_q <= 1'b0;
					mode_state     <= MODE_RUN;
				end
			end

			default: mode_state <= MODE_WAIT_START;
		endcase
	end
end

video_mode_t active_mode;
assign       active_mode = active_path_q.timing;

wire [11:0] fb_width  = active_mode.fb_width;
wire [11:0] fb_height = active_mode.fb_height;

wire [1:0] geometry_mode = active_mode.is_1080p ? GEOMETRY_1080 :
                           active_mode.is_720p ? GEOMETRY_720 :
                               active_mode.is_480p ? GEOMETRY_480 : GEOMETRY_240;

always_comb begin
	case (aspect_ratio)
		2'd0:    begin
			video_arx = active_mode.optimized_arx;
			video_ary = active_mode.optimized_ary;
		end
		2'd1:    begin video_arx = 13'd0;         video_ary = 13'd0;         end
		default: begin
			video_arx = 13'h1000 | {1'b0, fb_width};
			video_ary = 13'h1000 | {1'b0, fb_height};
		end
	endcase
end
assign mode_is_15khz       = mode_ready && (active_mode.is_240p || active_mode.is_interlaced);
assign mode_supports_120hz = mode_ready && height_supports_120hz;
assign profile_resolution  = geometry_mode;
assign clk_video           = clk_125;

// -------------------------------------------------------------- timing ---
logic [1:0] integer_phase = 2'd0;
// Store phase minus the wrap threshold; a nonnegative phase emits a pixel enable.
logic signed [19:0] fractional_phase = 20'sd0;
logic        [10:0] h_cnt = 11'd0, v_cnt = 11'd0;
logic               progressive_ce_pixel = 1'b0;
(* preserve, dont_merge *) logic ce_pix_ovl = 1'b0;
logic v_end_q = 1'b0;
logic raw_hsync, raw_vsync, raw_hblank, raw_vblank;

wire   h_end      = h_cnt >= active_mode.h_total[10:0];
assign frame_wrap = progressive_ce_pixel && h_end && v_end_q;

always_ff @(posedge clk_125) begin
	if (timing_reset || mode_commit_q)
		v_end_q <= 1'b0;
	else
		v_end_q <= v_cnt >= active_mode.v_total[10:0];
end

always_ff @(posedge clk_125) begin
	if (timing_reset) begin
		integer_phase        <=  2'd0;
		fractional_phase     <= active_mode.pixel_wrap_step;
		h_cnt                <= active_mode.h_total[10:0];
		v_cnt                <= active_mode.fb_height[10:0] + 11'd2;
		progressive_ce_pixel <= 1'b0;
		ce_pix_ovl           <= 1'b0;
	end else if (mode_commit_q) begin
		integer_phase        <=  2'd0;
		fractional_phase     <= active_mode.pixel_wrap_step;
		h_cnt                <= 11'd0;
		v_cnt                <= 11'd0;
		progressive_ce_pixel <=  1'b0;
		ce_pix_ovl           <=  1'b0;
	end else begin
		integer_phase <= integer_phase + 1'd1;
		case (active_mode.pixel_mode)
			PIXEL_FULL: begin
				progressive_ce_pixel <= 1'b1;
				ce_pix_ovl           <= 1'b1;
			end
			PIXEL_HALF: begin
				progressive_ce_pixel <= !integer_phase[0];
				ce_pix_ovl           <= !integer_phase[0];
			end
			default:    begin
				if (fractional_phase[19])
					fractional_phase <= fractional_phase + $signed({1'b0, active_mode.pixel_step});
				else
					fractional_phase <= fractional_phase + active_mode.pixel_wrap_step;
				progressive_ce_pixel <= !fractional_phase[19];
				ce_pix_ovl           <= !fractional_phase[19];
			end
		endcase

		if (progressive_ce_pixel) begin
			if (h_end) begin
				h_cnt <= 11'd0;
				v_cnt <= v_end_q ? 11'd0 : v_cnt + 1'd1;
			end else begin
				h_cnt <= h_cnt + 1'd1;
			end
		end
	end
end

always_comb begin
	raw_hsync  = !((h_cnt >= active_mode.hs_start[10:0]) && (h_cnt < active_mode.hs_end[10:0]));
	raw_vsync  = !((v_cnt >= active_mode.vs_start[10:0]) && (v_cnt < active_mode.vs_end[10:0]));
	raw_hblank = h_cnt >= fb_width[10:0];
	raw_vblank = v_cnt >= fb_height[10:0];
end

wire [7:0] fb_vga_r, fb_vga_g, fb_vga_b;
wire       fb_vga_hs, fb_vga_vs, fb_vga_hblank, fb_vga_vblank;

wire [10:0] beam_pixel_x;
wire [10:0] beam_pixel_y;
wire [11:0] beam_pixel_z;
wire [13:0] beam_pixel_dwell_dose;
wire        beam_pixel_valid;
wire        beam_pixel_replace;
wire        frame_done_adapter;
wire        beam_matte_open;
wire [11:0] beam_matte_left;
wire [11:0] beam_matte_right;
wire [11:0] beam_matte_top;
wire [11:0] beam_matte_bottom;

// Exclusive cutoff floor; the menu names the first positive Z level.
logic [4:0] beam_min_z = 5'd19;
always_ff @(posedge clk_sys) begin
	case (beam_threshold)
		2'd1:    beam_min_z <= 5'd23;
		2'd2:    beam_min_z <= 5'd27;
		2'd3:    beam_min_z <=  5'd0;
		default: beam_min_z <= 5'd19;
	endcase
end

vectrex_beam_adapter beam_adapter
(
	.clk_source      (clk_sys),
	.reset           (source_reset),
	.beam_ce         (beam_tick),
	.beam_x          (beam_x),
	.beam_y          (beam_y),
	.beam_z          (beam_z),
	.beam_on         (beam_on),
	.beam_zero_n     (beam_zero_n),
	.t2_reload       (t2_reload),
	.t2_period       (t2_period),
	.geometry_mode   (geometry_mode),
	.orient          (v_orient),
	.open_matte      (open_matte),
	.zoom_normal     (zoom_normal),
	.vertical_offset (vertical_offset),
	.beam_min_z      (beam_min_z),
	.dwell_reference (diagnostic_settings.reference_dwell),
	.velocity_mode   (diagnostic_settings.velocity_comp),
	.matte_open      (beam_matte_open),
	.matte_left      (beam_matte_left),
	.matte_right     (beam_matte_right),
	.matte_top       (beam_matte_top),
	.matte_bottom    (beam_matte_bottom),
	.pixel_x         (beam_pixel_x),
	.pixel_y         (beam_pixel_y),
	.pixel_z         (beam_pixel_z),
	.pixel_dwell_dose (beam_pixel_dwell_dose),
	.pixel_valid     (beam_pixel_valid),
	.pixel_replace   (beam_pixel_replace),
	.frame_done      (frame_done_adapter)
);

// --------------------------------------------------------- framebuffer ---
logic        sdram_dq_oe;
logic [15:0] sdram_dq_out;
logic [1:0]  sdram_dqm;

assign sdram_dq   = sdram_dq_oe ? sdram_dq_out : 16'hzzzz;
assign sdram_clk  = ~clk_125;
assign sdram_dqml = sdram_dqm[0];
assign sdram_dqmh = sdram_dqm[1];

vfb_top framebuffer
(
	.clk_sys                  (clk_125),
	// Pixel-valid and end-of-frame pulses use the beam adapter's 24 MHz clock.
	.clk_source               (clk_sys),
	.reset                    (renderer_reset),
	.reset_d                  (renderer_reset_pipe[0]),
	.source_reset             (source_reset),
	.client_reset             (reset_125),
	.upload_reset             (vfb_clock_reset),
	.video_timing_reset       (timing_reset),

	.X_VECTOR                 (beam_pixel_x),
	.Y_VECTOR                 (beam_pixel_y),
	.Z_VECTOR                 (beam_pixel_z),
	.DWELL_DOSE               (beam_pixel_dwell_dose),
	.BEAM_ON                  (beam_pixel_valid),
	.RMW_REPLACE              (beam_pixel_replace),

	.DDRAM_CLK                (ddram_clk),
	.DDRAM_BUSY               (ddram_busy),
	.DDRAM_BURSTCNT           (ddram_burstcnt),
	.DDRAM_ADDR               (ddram_addr),
	.DDRAM_DOUT               (ddram_dout),
	.DDRAM_DOUT_READY         (ddram_dout_ready),
	.DDRAM_RD                 (ddram_rd),
	.DDRAM_DIN                (ddram_din),
	.DDRAM_BE                 (ddram_be),
	.DDRAM_WE                 (ddram_we),
	.ptx_read_ready           (ptx_read_ready),
	.ptx_read_grant           (ptx_read_grant),
	.ptx_read_addr            (ptx_read_addr),
	.ptx_read_burstcnt        (ptx_read_burstcnt),
	.ptx_read_data            (ptx_read_data),
	.ptx_read_data_valid      (ptx_read_data_valid),
	.ptx_write_ready          (ptx_write_ready),
	.ptx_write_grant          (ptx_write_grant),
	.ptx_write_done           (ptx_write_done),
	.ptx_write_addr           (ptx_write_addr),
	.ptx_write_burstcnt       (ptx_write_burstcnt),
	.ptx_write_data           (ptx_write_data),
	.ptx_write_be             (ptx_write_be),
	.ptx_write_advance        (ptx_write_advance),

	.SDRAM_DQ_IN              (sdram_dq),
	.SDRAM_DQ_OUT             (sdram_dq_out),
	.SDRAM_DQ_OE              (sdram_dq_oe),
	.SDRAM_CKE                (sdram_cke),
	.SDRAM_nCS                (sdram_ncs),
	.SDRAM_nRAS               (sdram_nras),
	.SDRAM_nCAS               (sdram_ncas),
	.SDRAM_nWE                (sdram_nwe),
	.SDRAM_DQM                (sdram_dqm),
	.SDRAM_A                  (sdram_a),
	.SDRAM_BA                 (sdram_ba),

	.RENDER_WIDTH             (fb_width),
	.RENDER_HEIGHT            (fb_height),
	.MATTE_OPEN               (beam_matte_open),
	.MATTE_LEFT               (beam_matte_left),
	.MATTE_RIGHT              (beam_matte_right),
	.MATTE_TOP                (beam_matte_top),
	.MATTE_BOTTOM             (beam_matte_bottom),

	.VGA_R                    (fb_vga_r),
	.VGA_G                    (fb_vga_g),
	.VGA_B                    (fb_vga_b),
	.VGA_HS                   (fb_vga_hs),
	.VGA_VS                   (fb_vga_vs),
	.VGA_HBLANK               (fb_vga_hblank),
	.VGA_VBLANK               (fb_vga_vblank),

	.h_cnt                    (h_cnt),
	.v_cnt                    (v_cnt),
	.ce_pix                   (progressive_ce_pixel),
	.ce_pix_overlay           (ce_pix_ovl),
	.hsync                    (raw_hsync),
	.vsync                    (raw_vsync),
	.hblank                   (raw_hblank),
	.vblank                   (raw_vblank),

	.OSD_120HZ                (active_mode.is_120hz),
	.FRAME_DONE               (frame_done_adapter),
	.BUFFER_MODE              (buffer_mode),
	.PROFILE_SETTINGS         (profile_settings),
	.HALO_DOT_REDUCTION       (diagnostic_settings.halo_correction),
	.FIFO_FULL_LED            (fifo_full_led),
	.full_bypass_active       (active_path_q.bypass),
	.processed_path_prepare   (processed_path_prepare_q),
	// Vectrex overlays are independent of CRT profiles.
	.artwork_enable           (!overlay_off),
	.artwork_tint             (ovl_tint),
	.artwork_blend            (ovl_bright),
	.artwork_opaque_brightness(ovl_opaque_bright),
	.ioctl_download           (ioctl_download),
	.ioctl_wr                 (ioctl_wr),
	.ioctl_index              (ioctl_index),
	.ioctl_addr               (ioctl_addr),
	.ioctl_data               (ioctl_data),
	.ioctl_wait               (ioctl_wait),
	.artwork_valid            (artwork_valid),
	.raw_path_vblank          (raw_path_vblank),
	.processed_path_vblank    (processed_path_vblank)
);

localparam logic [1:0] INTERLACER_PATH_RESTART_CYCLES = 2'd3;
logic [1:0]            interlacer_restart_count       = 2'd0;

always_ff @(posedge clk_125) begin
	if (clock_reset_125 || timing_reset || !active_mode.is_interlaced)
		interlacer_restart_count <= 2'd0;
	else if (profile_path_commit)
		interlacer_restart_count <= INTERLACER_PATH_RESTART_CYCLES;
	else if (interlacer_restart_count != 2'd0)
		interlacer_restart_count <= interlacer_restart_count - 1'd1;
end

vfb_interlacer interlacer
(
	.clk_sys   (clk_125),
	.reset     (timing_reset || mode_commit_q ||
		mode_restart_q || !active_mode.is_interlaced ||
		(interlacer_restart_count != 2'd0)),
	.enable    (active_mode.is_interlaced),
	.vertical_offset (active_mode.crt_vertical_offset),
	.ce_pix_in (progressive_ce_pixel),
	.r_in      (fb_vga_r),
	.g_in      (fb_vga_g),
	.b_in      (fb_vga_b),
	.hsync_in  (fb_vga_hs),
	.vsync_in  (fb_vga_vs),
	.hblank_in (fb_vga_hblank),
	.vblank_in (fb_vga_vblank),
	.ce_pix_out(ce_pixel),
	.r_out     (vga_r),
	.g_out     (vga_g),
	.b_out     (vga_b),
	.hsync_out (vga_hs),
	.vsync_out (vga_vs),
	.hblank_out(vga_hblank),
	.vblank_out(vga_vblank),
	.field_out (field)
);

endmodule

`default_nettype wire
