// ============================================================================
// Select the active CRT profile, initialize the Custom slots and handle profile and view changes.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// ============================================================================

`default_nettype none

module vfb_profile_resolver (
	input wire         clk_sys,
	input wire         reset,
	input wire         commit, echo, clear_settings,
	input wire [127:0] stored, incoming,
	input wire [1:0]   profile_resolution,
	input wire         video_freeze,
	input wire         video_is_15khz,
	input wire         video_supports_120hz,
	input wire         direct_video,
	input wire         artwork_loaded,
	input wire         artwork_present,
	input wire         view_button,
	input wire         osd_open,
	input wire [10:0]  ps2_key,

	output vfb_control_pkg::profile_settings_t    profile_settings,
	output vfb_control_pkg::diagnostic_settings_t diagnostic_settings,
	output logic                                  effects_bypass,
	output logic [15:0]                           menu_mask,
	output logic [127:0]                          status,
	output wire                                   reply_pending,
	output logic                                  info_req = 1'b0,
	output logic [7:0]                            info = 8'd0
);
import vfb_control_pkg::*;

localparam logic [2:0] CUSTOM1_SEED_PROFILE = PROFILE_CRUISE;
localparam logic [2:0] CUSTOM2_SEED_PROFILE = PROFILE_OVERDRIVE;

function automatic profile_settings_t fixed_240p;
	input logic [2:0] profile_i;
	begin
		case (profile_i)
			PROFILE_CRUISE:      fixed_240p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_STANDARD,  color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_THIN,     bloom_curve:       CURVE_MILD,
				halo_gain:        HALO_150X,      halo_curve:        CURVE_MILD,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_2, halo_grid: HALO_GRID_8,
				inter_decay: INTER_OFF, intra_decay: INTRA_OFF
			};
			PROFILE_OVERDRIVE:   fixed_240p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_3, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_BRIGHT,    color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_THIN,     bloom_curve:       CURVE_MILD_P,
				halo_gain:        HALO_150X,      halo_curve:        CURVE_MIN_PLUS,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_2, halo_grid: HALO_GRID_8,
				inter_decay: INTER_SHORT, intra_decay: INTRA_OFF
			};
			PROFILE_NEON_BLUE:   fixed_240p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_STANDARD,  color:             COLOR_BLUE,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_STRONG_M,
				halo_gain:        HALO_033X,      halo_curve:        CURVE_MOD_P,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_24, halo_grid: HALO_GRID_8,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_OFF
			};
			PROFILE_RED_ALERT:   fixed_240p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_3, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_REDUCED,   color:             COLOR_RED,
				bloom_width:      BLOOM_THIN,     bloom_curve:       CURVE_STRONG,
				halo_gain:        HALO_075X,      halo_curve:        CURVE_STRONG,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_OFF, halo_grid: HALO_GRID_8,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_LUT_C
			};
			PROFILE_ULTRAVIOLET: fixed_240p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_3, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_BOOST,     color:             COLOR_PURPLE,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_MILD,
				halo_gain:        HALO_075X,      halo_curve:        CURVE_STRONG_M,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_OFF, halo_grid: HALO_GRID_8,
				inter_decay: INTER_SHORT, intra_decay: INTRA_LUT_B
			};
			PROFILE_TOUCH:       fixed_240p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_1,
				tone:             TONE_STANDARD,  color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_THIN,     bloom_curve:       CURVE_MINIMAL,
				halo_gain:        HALO_150X,      halo_curve:        CURVE_MIN_PLUS,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_2, halo_grid: HALO_GRID_8,
				inter_decay: INTER_OFF, intra_decay: INTRA_OFF
			};
			default:             fixed_240p = '0;
		endcase
	end
endfunction

function automatic profile_settings_t fixed_480p;
	input logic [2:0] profile_i;
	begin
		case (profile_i)
			PROFILE_CRUISE:      fixed_480p = '{
				dwell_low_size: DWELL_SIZE_4,
				dwell_mid_growth: DWELL_GROWTH_SAME, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_STANDARD,     color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_THIN,        bloom_curve:       CURVE_STRONG_M,
				halo_gain:        HALO_050X,         halo_curve:        CURVE_STRONG,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_10, halo_grid: HALO_GRID_8,
				inter_decay: INTER_SHORT, intra_decay: INTRA_OFF
			};
			PROFILE_OVERDRIVE:   fixed_480p = '{
				dwell_low_size: DWELL_SIZE_4,
				dwell_mid_growth: DWELL_GROWTH_SAME, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_STANDARD,     color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_TIGHT,       bloom_curve:       CURVE_MILD_P,
				halo_gain:        HALO_100X,         halo_curve:        CURVE_MOD_P,
				halo_spread: SPREAD_ORIGINAL, halo_knee: KNEE_6, halo_grid: HALO_GRID_8,
				inter_decay: INTER_SHORT, intra_decay: INTRA_OFF
			};
			PROFILE_NEON_BLUE:   fixed_480p = '{
				dwell_low_size: DWELL_SIZE_4,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_STANDARD,  color:             COLOR_BLUE,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_STRONG_M,
				halo_gain:        HALO_033X,      halo_curve:        CURVE_MOD_P,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_24, halo_grid: HALO_GRID_16,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_LUT_A
			};
			PROFILE_RED_ALERT:   fixed_480p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_REDUCED,   color:             COLOR_RED,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_STRONG_M,
				halo_gain:        HALO_125X,      halo_curve:        CURVE_STRONG,
				halo_spread: SPREAD_WIDE1, halo_knee: KNEE_OFF, halo_grid: HALO_GRID_8,
				inter_decay: INTER_LONG, intra_decay: INTRA_LUT_C
			};
			PROFILE_ULTRAVIOLET: fixed_480p = '{
				dwell_low_size: DWELL_SIZE_2,
				dwell_mid_growth: DWELL_GROWTH_3, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_BOOST,     color:             COLOR_PURPLE,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_MILD_P,
				halo_gain:        HALO_100X,      halo_curve:        CURVE_STRONG,
				halo_spread: SPREAD_WIDE1, halo_knee: KNEE_OFF, halo_grid: HALO_GRID_8,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_LUT_B
			};
			PROFILE_TOUCH:       fixed_480p = '{
				dwell_low_size: DWELL_SIZE_4,
				dwell_mid_growth: DWELL_GROWTH_SAME, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_STANDARD,     color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_THIN,        bloom_curve:       CURVE_MOD_P,
				halo_gain:        HALO_033X,         halo_curve:        CURVE_STRONG,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_10, halo_grid: HALO_GRID_8,
				inter_decay: INTER_OFF, intra_decay: INTRA_OFF
			};
			default:             fixed_480p = '0;
		endcase
	end
endfunction

function automatic profile_settings_t fixed_720p;
	input logic [2:0] profile_i;
	begin
		case (profile_i)
			PROFILE_CRUISE:      fixed_720p = '{
				dwell_low_size: DWELL_SIZE_4,
				dwell_mid_growth: DWELL_GROWTH_1, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_STANDARD,  color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_MODERATE,
				halo_gain:        HALO_125X,      halo_curve:        CURVE_MODERATE,
				halo_spread: SPREAD_ORIGINAL, halo_knee: KNEE_4, halo_grid: HALO_GRID_8,
				inter_decay: INTER_SHORT, intra_decay: INTRA_OFF
			};
			PROFILE_OVERDRIVE:   fixed_720p = '{
				dwell_low_size: DWELL_SIZE_4,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_STANDARD,  color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_STRONG_M,
				halo_gain:        HALO_150X,      halo_curve:        CURVE_STRONG_M,
				halo_spread: SPREAD_ORIGINAL, halo_knee: KNEE_2, halo_grid: HALO_GRID_8,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_LUT_A
			};
			PROFILE_NEON_BLUE:   fixed_720p = '{
				dwell_low_size: DWELL_SIZE_4,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_BRIGHT,    color:             COLOR_BLUE,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_STRONG_M,
				halo_gain:        HALO_025X,      halo_curve:        CURVE_MOD_P,
				halo_spread: SPREAD_ORIGINAL, halo_knee: KNEE_16, halo_grid: HALO_GRID_16,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_LUT_C
			};
			PROFILE_RED_ALERT:   fixed_720p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_4, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_REDUCED,   color:             COLOR_RED,
				bloom_width:      BLOOM_NORMAL,   bloom_curve:       CURVE_MILD_P,
				halo_gain:        HALO_150X,      halo_curve:        CURVE_MODERATE,
				halo_spread: SPREAD_ORIGINAL, halo_knee: KNEE_OFF, halo_grid: HALO_GRID_16,
				inter_decay: INTER_LONG, intra_decay: INTRA_LUT_C
			};
			PROFILE_ULTRAVIOLET: fixed_720p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_3, dwell_high_growth: DWELL_GROWTH_4,
				tone:             TONE_BOOST,     color:             COLOR_PURPLE,
				bloom_width:      BLOOM_NORMAL,   bloom_curve:       CURVE_MILD_P,
				halo_gain:        HALO_100X,      halo_curve:        CURVE_STRONG,
				halo_spread: SPREAD_WIDE1, halo_knee: KNEE_OFF, halo_grid: HALO_GRID_16,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_LUT_B
			};
			PROFILE_TOUCH:       fixed_720p = '{
				dwell_low_size: DWELL_SIZE_4,
				dwell_mid_growth: DWELL_GROWTH_1, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_STANDARD,  color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_MILD_P,
				halo_gain:        HALO_150X,      halo_curve:        CURVE_MILD,
				halo_spread: SPREAD_ORIGINAL, halo_knee: KNEE_4, halo_grid: HALO_GRID_8,
				inter_decay: INTER_SHORT, intra_decay: INTRA_OFF
			};
			default:             fixed_720p = '0;
		endcase
	end
endfunction

function automatic profile_settings_t fixed_1080p;
	input logic [2:0] profile_i;
	begin
		case (profile_i)
			PROFILE_CRUISE:      fixed_1080p = '{
				dwell_low_size: DWELL_SIZE_2,
				dwell_mid_growth: DWELL_GROWTH_1, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_STANDARD,  color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_SOFT,     bloom_curve:       CURVE_MODERATE,
				halo_gain:        HALO_100X,      halo_curve:        CURVE_MOD_P,
				halo_spread: SPREAD_WIDE1, halo_knee: KNEE_6, halo_grid: HALO_GRID_8,
				inter_decay: INTER_SHORT, intra_decay: INTRA_OFF
			};
			PROFILE_OVERDRIVE:   fixed_1080p = '{
				dwell_low_size: DWELL_SIZE_2,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_2,
				tone:             TONE_STANDARD,  color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_SOFT,     bloom_curve:       CURVE_STRONG_M,
				halo_gain:        HALO_150X,      halo_curve:        CURVE_MOD_P,
				halo_spread: SPREAD_ORIGINAL, halo_knee: KNEE_2, halo_grid: HALO_GRID_16,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_LUT_A
			};
			PROFILE_NEON_BLUE:   fixed_1080p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_BRIGHT,    color:             COLOR_BLUE,
				bloom_width:      BLOOM_NORMAL,   bloom_curve:       CURVE_MODERATE,
				halo_gain:        HALO_050X,      halo_curve:        CURVE_MOD_P,
				halo_spread: SPREAD_ORIGINAL, halo_knee: KNEE_10, halo_grid: HALO_GRID_16,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_LUT_C
			};
			PROFILE_RED_ALERT:   fixed_1080p = '{
				dwell_low_size: DWELL_SIZE_2,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_REDUCED,   color:             COLOR_RED,
				bloom_width:      BLOOM_BROAD,    bloom_curve:       CURVE_MILD_P,
				halo_gain:        HALO_150X,      halo_curve:        CURVE_STRONG_M,
				halo_spread: SPREAD_WIDE1, halo_knee: KNEE_OFF, halo_grid: HALO_GRID_16,
				inter_decay: INTER_LONG, intra_decay: INTRA_LUT_C
			};
			PROFILE_ULTRAVIOLET: fixed_1080p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_BOOST,     color:             COLOR_PURPLE,
				bloom_width:      BLOOM_BROAD,    bloom_curve:       CURVE_MILD_P,
				halo_gain:        HALO_100X,      halo_curve:        CURVE_STRONG,
				halo_spread: SPREAD_WIDE1, halo_knee: KNEE_OFF, halo_grid: HALO_GRID_16,
				inter_decay: INTER_MEDIUM, intra_decay: INTRA_LUT_B
			};
			PROFILE_TOUCH:       fixed_1080p = '{
				dwell_low_size: DWELL_SIZE_3,
				dwell_mid_growth: DWELL_GROWTH_2, dwell_high_growth: DWELL_GROWTH_3,
				tone:             TONE_STANDARD,  color:             COLOR_VECTREX_P4,
				bloom_width:      BLOOM_TIGHT,    bloom_curve:       CURVE_MOD_P,
				halo_gain:        HALO_050X,      halo_curve:        CURVE_STRONG,
				halo_spread: SPREAD_FOCUS, halo_knee: KNEE_6, halo_grid: HALO_GRID_8,
				inter_decay: INTER_SHORT, intra_decay: INTRA_OFF
			};
			default:             fixed_1080p = '0;
		endcase
	end
endfunction

function automatic profile_settings_t fixed_profile;
	input  logic [2:0] profile_i;
	input  logic [1:0] resolution_i;
	begin
		case (resolution_i)
			GEOMETRY_480:  fixed_profile = fixed_480p(profile_i);
			GEOMETRY_720:  fixed_profile = fixed_720p(profile_i);
			GEOMETRY_1080: fixed_profile = fixed_1080p(profile_i);
			default:       fixed_profile = fixed_240p(profile_i);
		endcase
	end
endfunction

(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [3:0] profile_mode_meta   = {2'b01, GEOMETRY_720};
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [3:0] profile_mode_sync   = {2'b01, GEOMETRY_720};
logic [3:0] profile_mode_sync_d = {2'b01, GEOMETRY_720};
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic menu_120hz_meta = 1'b0, menu_120hz_sync = 1'b0;

profile_settings_t custom1_status, custom2_status;
profile_settings_t custom1_default, custom2_default;
wire [2:0] profile, view_status;
wire       custom_active = profile == PROFILE_CUSTOM1 || profile == PROFILE_CUSTOM2;
wire       initialized, custom_bloom_off, custom_halo_off;
wire [3:0] pending;

logic       view_button_q = 1, key_toggle_q = 0, art_waiting = 0;
logic [1:0] profile_keys_down = 0, control_keys_down = 0, shift_keys_down = 0, copy_keys_down = 0;
wire        art = artwork_loaded || art_waiting;

logic info_pending = 1'b0;
typedef enum logic [1:0] {INFO_VIEW, INFO_PROFILE, INFO_COPY} info_kind_t;
info_kind_t info_kind        = INFO_VIEW;
logic       info_copy_target = 1'b0;

// {Open Matte, Screen framing, Overlay off}.
function automatic logic [2:0] next_view(
	input logic [2:0] current_view, input logic has_artwork);
	case (current_view)
		3'b000:  next_view = 3'b001;
		3'b001:  next_view = 3'b011;
		3'b011:  next_view = 3'b111;
		default: next_view = has_artwork ? 3'b000 : 3'b001;
	endcase
endfunction

wire view_press = view_button && !view_button_q && !osd_open;

// The minus and equals keys select the previous and next profile.
wire key_event        = ps2_key[10] != key_toggle_q;
wire profile_prev_key = ps2_key[7:0] == 8'h4e;
wire profile_next_key = ps2_key[7:0] == 8'h55;
wire profile_press    = key_event && ps2_key[9] && !ps2_key[8] && !osd_open &&
                        ((profile_prev_key && !profile_keys_down[0]) ||
                         (profile_next_key && !profile_keys_down[1]));

// Ctrl+Shift+1 and Ctrl+Shift+2 copy the active profile to the corresponding Custom slot.
wire copy_first_key  = ps2_key[7:0] == 8'h16;
wire copy_second_key = ps2_key[7:0] == 8'h1e;
wire copy_key = key_event && ps2_key[9] && !ps2_key[8] && !osd_open &&
                (|control_keys_down) && (|shift_keys_down) &&
                ((copy_first_key  && !copy_keys_down[0] && profile != PROFILE_CUSTOM1) ||
                 (copy_second_key && !copy_keys_down[1] && profile != PROFILE_CUSTOM2));

always_ff @(posedge clk_sys) begin
	// Track the PS/2 event toggle during reset and while the OSD is open so old events cannot replay.
	key_toggle_q <= ps2_key[10];
	// Clear held-key flags in the OSD because Main may handle the key release there.
	if (osd_open) begin
		profile_keys_down <= 2'b00;
		control_keys_down <= 2'b00;
		shift_keys_down   <= 2'b00;
		copy_keys_down    <= 2'b00;
	end else if (key_event) begin
		if (ps2_key[7:0] == 8'h14) control_keys_down[ps2_key[8]] <= ps2_key[9];
		if (!ps2_key[8]) begin
			if (profile_prev_key)      profile_keys_down[0] <= ps2_key[9];
			if (profile_next_key)      profile_keys_down[1] <= ps2_key[9];
			if (ps2_key[7:0] == 8'h12) shift_keys_down[0]   <= ps2_key[9];
			if (ps2_key[7:0] == 8'h59) shift_keys_down[1]   <= ps2_key[9];
			if (copy_first_key)        copy_keys_down[0]    <= ps2_key[9];
			if (copy_second_key)       copy_keys_down[1]    <= ps2_key[9];
		end
	end
end

always_ff @(posedge clk_sys) begin
	profile_mode_meta   <= {video_is_15khz, video_freeze, profile_resolution};
	profile_mode_sync   <= profile_mode_meta;
	profile_mode_sync_d <= profile_mode_sync;
	menu_120hz_meta     <= video_supports_120hz;
	menu_120hz_sync     <= menu_120hz_meta;
end

wire mode_ready = !profile_mode_sync[2] && profile_mode_sync == profile_mode_sync_d;
// A settings write can select a new CRT format and a Custom profile together.
// Wait for the active resolution to match the requested CRT format before using its preset table.
wire [1:0] crt_table = stored[ST_CRT_240P] && !(direct_video && stored[ST_DIRECT_31KHZ]) ?
                       GEOMETRY_240 : GEOMETRY_480;
wire table_ready = !(direct_video || profile_mode_sync[3]) || profile_mode_sync[1:0] == crt_table;
wire can_seed    = mode_ready && table_ready && !reset && !commit;
wire can_reply   = !reset &&
                   !(stored[ST_MAIN_RESET] || stored[ST_GAME_RESET] || stored[ST_SAVE_CART]);

// Copying between initialized Custom slots uses stored settings, even during a video transition.
wire       copy_press = copy_key && can_reply && (can_seed || (initialized && custom_active));
wire [1:0] copy_to    = {copy_press && copy_second_key, copy_press && copy_first_key};
wire       need_table = !initialized && (custom_active || copy_press);
wire       seed       = can_seed && need_table;
wire [1:0] slot_valid;
assign initialized = &slot_valid;

// Menu index zero selects full halo correction and the standard reference dwell.
assign diagnostic_settings = stored[DIAG_LSB +: $bits(diagnostic_settings_t)] ^
                             {HALO_CORRECTION_100, 2'd0, 2'd2};
assign reply_pending = can_reply && (|pending) && !need_table;

// Local changes can override the view, the selected profile, or either whole Custom slot.
// All other settings come from Main's last complete write.
vfb_profile_field #(3) view_edit (
	.*,
	.set      (!reset && (art || view_press)),
	.target   (art ? 3'b000 : next_view(view_status, artwork_present)),
	.old_value(stored[VIEW_LSB +: 3]),
	.new_value(incoming[VIEW_LSB +: 3]),
	.value    (view_status),
	.pending  (pending[0])
);
vfb_profile_field #(3) profile_edit (
	.*,
	.set      (!reset && profile_press),
	.target   (profile + (profile_next_key ? 3'd1 : 3'd7)),
	.old_value(stored[PROFILE_LSB +: 3]),
	.new_value(incoming[PROFILE_LSB +: 3]),
	.value    (profile),
	.pending  (pending[1])
);
vfb_profile_field #(1 + PROFILE_BITS) custom1_edit (
	.*,
	.set      (seed || copy_to[0]),
	.target   ({1'b1, copy_to[0] ? profile_settings : custom1_default}),
	.old_value({stored[CUSTOM_INIT_BIT], stored[CUSTOM1_LSB +: PROFILE_BITS]}),
	.new_value({incoming[CUSTOM_INIT_BIT], incoming[CUSTOM1_LSB +: PROFILE_BITS]}),
	.value    ({slot_valid[0], custom1_status}),
	.pending  (pending[2])
);
vfb_profile_field #(1 + PROFILE_BITS) custom2_edit (
	.*,
	.set      (seed || copy_to[1]),
	.target   ({1'b1, copy_to[1] ? profile_settings : custom2_default}),
	.old_value({stored[CUSTOM_INIT_BIT], stored[CUSTOM2_LSB +: PROFILE_BITS]}),
	.new_value({incoming[CUSTOM_INIT_BIT], incoming[CUSTOM2_LSB +: PROFILE_BITS]}),
	.value    ({slot_valid[1], custom2_status}),
	.pending  (pending[3])
);
assign custom1_default = fixed_profile(CUSTOM1_SEED_PROFILE, profile_mode_sync[1:0]);
assign custom2_default = fixed_profile(CUSTOM2_SEED_PROFILE, profile_mode_sync[1:0]);

always_comb begin
	case (profile)
		PROFILE_CUSTOM1: profile_settings = initialized ? custom1_status : custom1_default;
		PROFILE_CUSTOM2: profile_settings = initialized ? custom2_status : custom2_default;
		default:         profile_settings = fixed_profile(profile, profile_mode_sync[1:0]);
	endcase
end

assign effects_bypass   = status[ST_BYPASS];
assign custom_bloom_off = custom_active &&
                          (((profile == PROFILE_CUSTOM2) ? custom2_status.bloom_width
                                                         : custom1_status.bloom_width) ==
                           BLOOM_OFF);
assign custom_halo_off  = custom_active &&
                          (((profile == PROFILE_CUSTOM2) ? custom2_status.halo_gain
                                                         : custom1_status.halo_gain) == HALO_OFF);

// Use the same resolved settings for the display and for the reply to Main.
always_comb begin
	status = stored;
	status[VIEW_LSB +: 3]               = view_status;
	status[PROFILE_LSB +: 3]            = profile;
	status[CUSTOM_INIT_BIT]             = initialized;
	status[CUSTOM1_LSB +: PROFILE_BITS] = custom1_status;
	status[CUSTOM2_LSB +: PROFILE_BITS] = custom2_status;
end

always_ff @(posedge clk_sys) begin
	view_button_q <= view_button;
	art_waiting   <= reset && art;
	info_req      <= 0;
	if (reset || osd_open || clear_settings) info_pending <= 0;
	else if (copy_press || profile_press || (view_press && !art)) begin
		info_pending     <= 1;
		info_kind        <= copy_press ? INFO_COPY : profile_press ? INFO_PROFILE : INFO_VIEW;
		info_copy_target <= copy_second_key;
	end else if (art && info_kind == INFO_VIEW) info_pending <= 0;
	else if (info_pending && !(|pending) && !seed) begin
		info_pending <= 0;
		info_req     <= 1;
		case (info_kind)
			INFO_COPY:    info <= info_copy_target ? 8'd14 : 8'd13;
			INFO_PROFILE: info <= 8'd5 + {5'd0, profile};
			default:
				case (view_status)
					3'b000:  info     <= 8'd1;
					3'b001:  info     <= 8'd2;
					3'b011:  info     <= 8'd3;
					3'b111:  info     <= 8'd4;
					default: info_req <= 0;
				endcase
		endcase
	end
end

// Show Custom controls once Main has restored or acknowledged both preset slots.
wire custom_editable = custom_active && stored[CUSTOM_INIT_BIT] && !reset;
assign menu_mask = {3'b000, custom_editable, profile, 1'b0, effects_bypass, custom_halo_off,
                    custom_bloom_off, 1'b0, !status[ST_OVERLAY_OFF], profile_mode_sync[3],
                    !profile_mode_sync[1], menu_120hz_sync || direct_video};

endmodule

// Keep the requested value until Main returns it, changes the field in a separate write,
// or resets the settings.
module vfb_profile_field #(parameter WIDTH = 1) (
	input  wire             clk_sys, commit, echo, clear_settings, set,
	input  wire [WIDTH-1:0] target, old_value, new_value,
	output wire [WIDTH-1:0] value,
	output logic            pending = 0
);
logic [WIDTH-1:0] wanted;
assign value = pending ? wanted : old_value;
always_ff @(posedge clk_sys) begin
	if (clear_settings) pending <= 0;
	else if (set) begin
		wanted  <= target;
		pending <= pending || target != (commit ? new_value : old_value);
	end else if (commit && ((new_value == wanted) || (!echo && new_value != old_value)))
		pending <= 0;
end
endmodule

`default_nettype wire
