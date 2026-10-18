// Presentation control codes and settings shared by the resolver and video pipeline.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

package vfb_control_pkg;

// IDs follow CONF_STR and notification order; index zero is the reset default.
localparam logic [2:0] PROFILE_CRUISE      = 3'd0;
localparam logic [2:0] PROFILE_OVERDRIVE   = 3'd1;
localparam logic [2:0] PROFILE_NEON_BLUE   = 3'd2;
localparam logic [2:0] PROFILE_RED_ALERT   = 3'd3;
localparam logic [2:0] PROFILE_ULTRAVIOLET = 3'd4;
localparam logic [2:0] PROFILE_CUSTOM1     = 3'd5;
localparam logic [2:0] PROFILE_CUSTOM2     = 3'd6;
localparam logic [2:0] PROFILE_TOUCH       = 3'd7;

// Menu size levels select resolution-specific anchors; growth is relative.
localparam logic [2:0] DWELL_SIZE_1 = 3'd0;
localparam logic [2:0] DWELL_SIZE_2 = 3'd1;
localparam logic [2:0] DWELL_SIZE_3 = 3'd2;
localparam logic [2:0] DWELL_SIZE_4 = 3'd3;
localparam logic [2:0] DWELL_SIZE_5 = 3'd4;
localparam logic [2:0] DWELL_SIZE_6 = 3'd5;
localparam logic [2:0] DWELL_SIZE_7 = 3'd6;
localparam logic [2:0] DWELL_SIZE_8 = 3'd7;
localparam logic [2:0] DWELL_GROWTH_SAME = 3'd0;
localparam logic [2:0] DWELL_GROWTH_1    = 3'd1;
localparam logic [2:0] DWELL_GROWTH_2    = 3'd2;
localparam logic [2:0] DWELL_GROWTH_3    = 3'd3;
localparam logic [2:0] DWELL_GROWTH_4    = 3'd4;
localparam logic [2:0] DWELL_GROWTH_5    = 3'd5;
localparam logic [2:0] DWELL_GROWTH_6    = 3'd6;
localparam logic [2:0] DWELL_GROWTH_7    = 3'd7;

localparam logic [1:0] TONE_REDUCED  = 2'd0;
localparam logic [1:0] TONE_STANDARD = 2'd1;
localparam logic [1:0] TONE_BRIGHT   = 2'd2;
localparam logic [1:0] TONE_BOOST    = 2'd3;

localparam logic [2:0] BLOOM_OFF    = 3'd0;
localparam logic [2:0] BLOOM_THIN   = 3'd1;
localparam logic [2:0] BLOOM_TIGHT  = 3'd2;
localparam logic [2:0] BLOOM_SOFT   = 3'd3;
localparam logic [2:0] BLOOM_NORMAL = 3'd4;
localparam logic [2:0] BLOOM_BROAD  = 3'd5;
localparam logic [2:0] BLOOM_WIDE_M = 3'd6;
localparam logic [2:0] BLOOM_WIDE   = 3'd7;

localparam logic [2:0] CURVE_MINIMAL  = 3'd0;
localparam logic [2:0] CURVE_MIN_PLUS = 3'd1;
localparam logic [2:0] CURVE_MILD     = 3'd2;
localparam logic [2:0] CURVE_MILD_P   = 3'd3;
localparam logic [2:0] CURVE_MODERATE = 3'd4;
localparam logic [2:0] CURVE_MOD_P    = 3'd5;
localparam logic [2:0] CURVE_STRONG_M = 3'd6;
localparam logic [2:0] CURVE_STRONG   = 3'd7;

localparam logic [2:0] HALO_OFF  = 3'd0;
localparam logic [2:0] HALO_025X = 3'd1;
localparam logic [2:0] HALO_033X = 3'd2;
localparam logic [2:0] HALO_050X = 3'd3;
localparam logic [2:0] HALO_075X = 3'd4;
localparam logic [2:0] HALO_100X = 3'd5;
localparam logic [2:0] HALO_125X = 3'd6;
localparam logic [2:0] HALO_150X = 3'd7;

localparam logic [1:0] HALO_CORRECTION_NONE = 2'd0;
localparam logic [1:0] HALO_CORRECTION_50   = 2'd1;
localparam logic [1:0] HALO_CORRECTION_75   = 2'd2;
localparam logic [1:0] HALO_CORRECTION_100  = 2'd3;

localparam logic [1:0] SPREAD_ORIGINAL = 2'd0;
localparam logic [1:0] SPREAD_WIDE1    = 2'd1;
localparam logic [1:0] SPREAD_WIDE2    = 2'd2;
localparam logic [1:0] SPREAD_FOCUS    = 2'd3;
localparam logic [2:0] KNEE_OFF        = 3'd0;
localparam logic [2:0] KNEE_2          = 3'd1;
localparam logic [2:0] KNEE_4          = 3'd2;
localparam logic [2:0] KNEE_6          = 3'd3;
localparam logic [2:0] KNEE_8          = 3'd4;
localparam logic [2:0] KNEE_10         = 3'd5;
localparam logic [2:0] KNEE_16         = 3'd6;
localparam logic [2:0] KNEE_24         = 3'd7;
localparam logic       HALO_GRID_16     = 1'b0;
localparam logic       HALO_GRID_8      = 1'b1;

localparam logic [1:0] BUFFER_EOF_VBL = 2'd0;
localparam logic [1:0] BUFFER_VBL     = 2'd1;
localparam logic [1:0] BUFFER_EOF     = 2'd2;

localparam logic [1:0] INTER_OFF    = 2'd0;
localparam logic [1:0] INTER_SHORT  = 2'd1;
localparam logic [1:0] INTER_MEDIUM = 2'd2;
localparam logic [1:0] INTER_LONG   = 2'd3;

localparam logic [1:0] INTRA_OFF   = 2'd0;
localparam logic [1:0] INTRA_LUT_A = 2'd1;
localparam logic [1:0] INTRA_LUT_B = 2'd2;
localparam logic [1:0] INTRA_LUT_C = 2'd3;

localparam logic [2:0] COLOR_VECTREX_P4   = 3'd0;
localparam logic [2:0] COLOR_DELUXE_BLUE  = 3'd1;
localparam logic [2:0] COLOR_WHITE        = 3'd2;
localparam logic [2:0] COLOR_RED          = 3'd3;
localparam logic [2:0] COLOR_PURPLE       = 3'd4;
localparam logic [2:0] COLOR_CYAN         = 3'd5;
localparam logic [2:0] COLOR_BLUE         = 3'd6;

localparam logic [1:0] GEOMETRY_240  = 2'd0;
localparam logic [1:0] GEOMETRY_480  = 2'd1;
localparam logic [1:0] GEOMETRY_720  = 2'd2;
localparam logic [1:0] GEOMETRY_1080 = 2'd3;

// Field order is the 36-bit profile interface, from most to least significant.
typedef struct packed {
	logic [2:0] dwell_high_growth;
	logic       halo_grid;
	logic [2:0] halo_knee;
	logic [2:0] dwell_low_size;
	logic [2:0] dwell_mid_growth;
	logic [1:0] tone;
	logic [2:0] bloom_width;
	logic [2:0] bloom_curve;
	logic [2:0] halo_gain;
	logic [2:0] halo_curve;
	logic [1:0] halo_spread;
	logic [1:0] inter_decay;
	logic [1:0] intra_decay;
	logic [2:0] color;
} profile_settings_t;

typedef struct packed {
	logic [1:0] halo_correction;
	logic [1:0] velocity_comp;
	logic [1:0] reference_dwell;
} diagnostic_settings_t;

endpackage

`default_nettype wire
