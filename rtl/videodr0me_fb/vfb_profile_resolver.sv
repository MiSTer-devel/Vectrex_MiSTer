// ============================================================================
// CRT profile resolver and menu control.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
// ============================================================================

`default_nettype none

module vfb_profile_resolver (
	input wire         clk_sys,
	input wire         reset,
	input wire [127:0] status,
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
	output logic [127:0]                          status_in,
	output logic                                  status_set = 1'b0,
	output logic                                  info_req = 1'b0,
	output logic [7:0]                            info = 8'd0
);
import vfb_control_pkg::*;

localparam logic [2:0] CUSTOM1_SEED_PROFILE = PROFILE_CRUISE;
localparam logic [2:0] CUSTOM2_SEED_PROFILE = PROFILE_OVERDRIVE;
localparam integer     CUSTOM_INIT_BIT      = 127;

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
logic [2:0] profile_mode_meta   = {1'b1, GEOMETRY_720};
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic [2:0] profile_mode_sync   = {1'b1, GEOMETRY_720};
logic [2:0] profile_mode_sync_d = {1'b1, GEOMETRY_720};

profile_settings_t custom1_status, custom2_status;
profile_settings_t custom1_default, custom2_default;
logic [2:0]        profile;
logic [2:0]        selected_profile;
logic              custom_active;
logic              custom_seed_ready;
logic              custom_bloom_off;
logic              custom_halo_off;
logic              custom_update_active     = 1'b0;
logic              diagnostic_update_active = 1'b0;

localparam diagnostic_settings_t DIAGNOSTIC_DEFAULT = '{
	halo_correction: HALO_CORRECTION_100,
	velocity_comp:   2'd0,
	reference_dwell: 2'd2
};
localparam integer               DIAGNOSTIC_INIT_BIT = 115;

logic       view_button_q       =   1'b1;
logic       view_update_pending =   1'b0;
logic       view_update_active  =   1'b0;
logic [2:0] view_pending_target = 3'b000;
logic [2:0] view_target         = 3'b000;

logic       key_toggle_q           =  1'b0;
logic [1:0] profile_keys_down      = 2'b00;
logic       profile_update_pending =  1'b0;
logic       profile_update_active  =  1'b0;
logic [2:0] profile_pending_target = PROFILE_CRUISE;
logic [2:0] profile_target         = PROFILE_CRUISE;

logic [1:0]        control_keys_down   = 2'b00;
logic [1:0]        shift_keys_down     = 2'b00;
logic [1:0]        copy_keys_down      = 2'b00;
logic              copy_update_pending =  1'b0;
logic              copy_update_active  =  1'b0;
logic              copy_pending_target =  1'b0;
logic              copy_target         =  1'b0;
profile_settings_t copy_pending_settings, copy_settings;

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

wire [2:0] view_status         = {status[31], status[30], status[24]};
wire       view_press          = view_button && !view_button_q && !osd_open;
wire [2:0] view_base           = view_update_pending ? view_pending_target :
                                 view_update_active ? view_target : view_status;
wire       view_request        = view_update_pending || artwork_loaded || view_press;
wire [2:0] view_request_target = artwork_loaded ? 3'b000 :
                                 view_press ? next_view(view_base, artwork_present) :
                                     view_pending_target;
wire       view_update_needed  = view_request && (view_request_target != view_status);

// The minus and equals keys select the previous and next profile.
wire key_event        = ps2_key[10] != key_toggle_q;
wire profile_prev_key = ps2_key[7:0] == 8'h4e;
wire profile_next_key = ps2_key[7:0] == 8'h55;
wire profile_press    = key_event && ps2_key[9] && !ps2_key[8] && !osd_open &&
                        ((profile_prev_key && !profile_keys_down[0]) ||
                         (profile_next_key && !profile_keys_down[1]));

wire [2:0] profile_base           = profile_update_pending ? profile_pending_target :
                                    profile_update_active ? profile_target : profile;
wire       profile_request        = profile_update_pending || profile_press;
wire [2:0] profile_request_target = profile_press ? profile_base + (profile_next_key ? 3'd1 : 3'd7)
                                                  : profile_pending_target;
wire       profile_update_needed  = profile_request && (profile_request_target != profile);

// Ctrl+Shift plus the physical 1/2 key copies the visible profile once per press.
wire               copy_first_key      = ps2_key[7:0] == 8'h16;
wire               copy_second_key     = ps2_key[7:0] == 8'h1e;
wire               copy_press          = key_event && ps2_key[9] && !ps2_key[8] && !osd_open &&
                                         (|control_keys_down) && (|shift_keys_down) &&
                                         ((copy_first_key && !copy_keys_down[0] &&
                                           profile != PROFILE_CUSTOM1) ||
                                          (copy_second_key && !copy_keys_down[1] &&
                                           profile != PROFILE_CUSTOM2));
wire               copy_request        = copy_update_pending || copy_press;
wire               copy_request_target = copy_press ? copy_second_key : copy_pending_target;
profile_settings_t copy_request_settings;
assign             copy_request_settings = copy_press ? profile_settings : copy_pending_settings;
wire               copy_update_needed    = copy_request && custom_seed_ready;

always_ff @(posedge clk_sys) begin
	// Consume events during reset/OSD too, so they cannot become late presses.
	key_toggle_q <= ps2_key[10];
	// Main consumes releases in the menu. Forget held keys while it is open.
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

assign profile       = status[68:66];
assign custom_active = (profile == PROFILE_CUSTOM1) || (profile == PROFILE_CUSTOM2);
// Decode all stored controls before testing whether a Custom profile is empty.
assign custom1_status = '{
	dwell_high_growth: status[6:4],   halo_grid:      status[38],
	halo_knee:         status[57:55], dwell_low_size: status[54:52],
	dwell_mid_growth:  status[71:69], tone:           status[73:72],
	bloom_width:       status[76:74], bloom_curve:    status[79:77],
	halo_gain:         status[82:80], halo_curve:     status[43:41],
	halo_spread:       status[84:83], inter_decay:    status[86:85],
	intra_decay:       status[88:87], color:          status[91:89]};
assign custom2_status = '{
	dwell_high_growth: status[15:13],   halo_grid:      status[28],
	halo_knee:         status[60:58],   dwell_low_size: status[126:124],
	dwell_mid_growth:  status[94:92],   tone:           status[96:95],
	bloom_width:       status[99:97],   bloom_curve:    status[102:100],
	halo_gain:         status[105:103], halo_curve:     status[46:44],
	halo_spread:       status[107:106], inter_decay:    status[109:108],
	intra_decay:       status[111:110], color:          status[114:112]};

always_ff @(posedge clk_sys) begin
	profile_mode_meta   <= {video_freeze, profile_resolution};
	profile_mode_sync   <= profile_mode_meta;
	profile_mode_sync_d <= profile_mode_sync;
end

assign custom_seed_ready        = (profile_mode_sync == profile_mode_sync_d) &&
                                  !profile_mode_sync[2];
wire   custom_update_needed     = (custom_active || copy_request) && !status[CUSTOM_INIT_BIT] &&
                                  custom_seed_ready;
wire   diagnostic_update_needed = !status[DIAGNOSTIC_INIT_BIT] && custom_seed_ready;
wire   status_update_ack        = (!custom_update_active || status[CUSTOM_INIT_BIT]) &&
                                  (!diagnostic_update_active || status[DIAGNOSTIC_INIT_BIT]) &&
                                  (!view_update_active || (view_status == view_target)) &&
                                  (!profile_update_active || (profile == profile_target)) &&
                                  (!copy_update_active ||
                                   ((copy_target ? custom2_status : custom1_status) ==
                                    copy_settings));
assign diagnostic_settings      = status[DIAGNOSTIC_INIT_BIT] ?
                                  {status[64:63], status[50:49], status[48:47]} :
                                  DIAGNOSTIC_DEFAULT;
assign custom1_default          = fixed_profile(CUSTOM1_SEED_PROFILE, profile_mode_sync[1:0]);
assign custom2_default          = fixed_profile(CUSTOM2_SEED_PROFILE, profile_mode_sync[1:0]);
// Empty custom slots preview their seed until HPS acknowledges it.
assign selected_profile = !status[CUSTOM_INIT_BIT] && (profile == PROFILE_CUSTOM1) &&
                          !(|custom1_status) ?
                          CUSTOM1_SEED_PROFILE :
                          !status[CUSTOM_INIT_BIT] && (profile == PROFILE_CUSTOM2) &&
                          !(|custom2_status) ?
                              CUSTOM2_SEED_PROFILE :
                              profile;
// Effects Bypass changes presentation only; beam settings follow this profile.
always_comb begin
	case (selected_profile)
		PROFILE_CUSTOM1: profile_settings = custom1_status;
		PROFILE_CUSTOM2: profile_settings = custom2_status;
		default:         profile_settings = fixed_profile(selected_profile, profile_mode_sync[1:0]);
	endcase
end

assign effects_bypass   = status[123];
assign custom_bloom_off = custom_active &&
                          (((profile == PROFILE_CUSTOM2) ? custom2_status.bloom_width
                                                         : custom1_status.bloom_width) ==
                           BLOOM_OFF);
assign custom_halo_off  = custom_active &&
                          (((profile == PROFILE_CUSTOM2) ? custom2_status.halo_gain
                                                         : custom1_status.halo_gain) == HALO_OFF);

always_comb begin
	status_in = status;
	if ((custom_update_active && !(|custom1_status)) || (copy_update_active && !copy_target)) begin
		{status_in[6:4], status_in[38], status_in[57:55], status_in[54:52],
		 status_in[71:69], status_in[73:72], status_in[76:74], status_in[79:77],
		 status_in[82:80], status_in[43:41], status_in[84:83], status_in[86:85],
		 status_in[88:87], status_in[91:89]} =
		    (copy_update_active && !copy_target) ? copy_settings : custom1_default;
	end
	if ((custom_update_active && !(|custom2_status)) || (copy_update_active && copy_target)) begin
		{status_in[15:13], status_in[28], status_in[60:58], status_in[126:124],
		 status_in[94:92], status_in[96:95], status_in[99:97], status_in[102:100],
		 status_in[105:103], status_in[46:44], status_in[107:106],
		 status_in[109:108], status_in[111:110], status_in[114:112]} =
		    (copy_update_active && copy_target) ? copy_settings : custom2_default;
	end
	if (custom_update_active) status_in[CUSTOM_INIT_BIT] = 1'b1;
	// Each request changes only the fields owned by its active operation.
	if (diagnostic_update_active) begin
		{status_in[64:63], status_in[50:49], status_in[48:47]} = DIAGNOSTIC_DEFAULT;
		status_in[DIAGNOSTIC_INIT_BIT]                         = 1'b1;
		// Seed 60% on first use; preserve nonzero saved values.
		if (status[27:25] == 3'd0) status_in[27:25] = 3'd1;
	end
	if (view_update_active)    {status_in[31], status_in[30], status_in[24]} = view_target;
	if (profile_update_active) status_in[68:66]                              = profile_target;
end

// Keep the active request fixed until HPS acknowledges it. Additional presses
// advance queued targets; a new artwork load overrides the queued view.
always_ff @(posedge clk_sys) begin
	// Track releases during reset and OSD use to prevent a held-button step.
	view_button_q <= view_button;
	info_req      <= 1'b0;
	if (reset) begin
		status_set               <= 1'b0;
		info_pending             <= 1'b0;
		custom_update_active     <= 1'b0;
		diagnostic_update_active <= 1'b0;
		view_update_pending      <= view_update_pending || view_update_active || artwork_loaded;
		if (artwork_loaded)
			view_pending_target <= 3'b000;
		else if (!view_update_pending && view_update_active)
			view_pending_target <= view_target;
		view_update_active     <= 1'b0;
		profile_update_pending <= profile_update_pending || profile_update_active;
		if (!profile_update_pending && profile_update_active)
			profile_pending_target <= profile_target;
		profile_update_active <= 1'b0;
		copy_update_pending   <= copy_update_pending || copy_update_active;
		if (!copy_update_pending && copy_update_active) begin
			copy_pending_target   <= copy_target;
			copy_pending_settings <= copy_settings;
		end
		copy_update_active <= 1'b0;
	end else begin
		// The latest action owns the notification; copy wins simultaneous presses.
		if (copy_press || profile_press || (view_press && !artwork_loaded)) begin
			info_pending <= 1'b1;
			info_kind    <= copy_press ? INFO_COPY : profile_press ? INFO_PROFILE : INFO_VIEW;
			if (copy_press) info_copy_target <= copy_second_key;
		end else if (osd_open || (artwork_loaded && info_kind == INFO_VIEW)) begin
			info_pending <= 1'b0;
		end else if (info_pending && !info_req && !status_set &&
			!view_request && !profile_request && !copy_request &&
			!custom_update_needed && !diagnostic_update_needed) begin
			// Show the settled selection after all queued changes are acknowledged.
			info_pending <= 1'b0;
			info_req     <= !osd_open;
			if (info_kind == INFO_COPY)
				info <= info_copy_target ? 8'd14 : 8'd13;
			else if (info_kind == INFO_PROFILE)
				info <= 8'd5 + {5'd0, profile};
			else begin
				case (view_status)
					3'b000:  info     <= 8'd1;
					3'b001:  info     <= 8'd2;
					3'b011:  info     <= 8'd3;
					3'b111:  info     <= 8'd4;
					default: info_req <= 1'b0;
				endcase
			end
		end
		if (artwork_loaded || view_press) begin
			view_update_pending <= 1'b1;
			view_pending_target <= view_request_target;
		end
		if (profile_press) begin
			profile_update_pending <= 1'b1;
			profile_pending_target <= profile_request_target;
		end
		if (copy_press) begin
			copy_update_pending   <= 1'b1;
			copy_pending_target   <= copy_request_target;
			copy_pending_settings <= copy_request_settings;
		end

		if (status_set) begin
			if (status_update_ack) begin
				status_set               <= 1'b0;
				custom_update_active     <= 1'b0;
				diagnostic_update_active <= 1'b0;
				view_update_active       <= 1'b0;
				profile_update_active    <= 1'b0;
				copy_update_active       <= 1'b0;
			end
		end else begin
			view_update_pending    <= 1'b0;
			profile_update_pending <= 1'b0;
			if (copy_update_needed) copy_update_pending <= 1'b0;
			if (view_update_needed || profile_update_needed ||
				custom_update_needed || diagnostic_update_needed || copy_update_needed) begin
				status_set               <= 1'b1;
				custom_update_active     <= custom_update_needed;
				diagnostic_update_active <= diagnostic_update_needed;
				view_update_active       <= view_update_needed;
				view_target              <= view_request_target;
				profile_update_active    <= profile_update_needed;
				profile_target           <= profile_request_target;
				copy_update_active       <= copy_update_needed;
				copy_target              <= copy_request_target;
				copy_settings            <= copy_request_settings;
			end
		end
	end
end

// [0]=120 Hz supported or Direct Video, [1]=below 720p, [2]=15 kHz,
// [3]=overlay requested, [4]=unused,
// [5]=bloom off, [6]=halo off, [7]=effects bypass, [8]=Touch,
// [9]=Cruise or Neon Blue, [10]=Overdrive or Neon Blue,
// [11]=Red Alert, [12]=Ultraviolet,
// [13]=Custom 1, [14]=Custom 2, and [15]=unused.
// Neon Blue uses both bits 9 and 10 to fit the shared OSD mask.
assign menu_mask = {1'b0, profile == PROFILE_CUSTOM2, profile == PROFILE_CUSTOM1,
                    profile == PROFILE_ULTRAVIOLET, profile == PROFILE_RED_ALERT,
                    (profile == PROFILE_OVERDRIVE) || (profile == PROFILE_NEON_BLUE),
                    (profile == PROFILE_CRUISE)    || (profile == PROFILE_NEON_BLUE),
                    profile == PROFILE_TOUCH, effects_bypass, custom_halo_off,
                    custom_bloom_off, 1'b0, !status[24], video_is_15khz,
                    !profile_mode_sync[1], video_supports_120hz || direct_video};

endmodule

`default_nettype wire
