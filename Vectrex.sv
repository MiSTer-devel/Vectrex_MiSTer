//============================================================================
//  Vectrex for MiSTer
//
//  Original MiSTer port:
//  Copyright (C) 2017-2019 Sorgelig
//
//  Enhanced core rebuild and subsequent modifications:
//  Copyright (C) 2026 Videodr0me
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Based on Dar's original Vectrex FPGA implementation.
//  Incorporates earlier Vectrex development by Alan Steremberg (alanswx).
//  Extensively modified in 2026; see CHANGELOG.md for details.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

wire       ioctl_download;
wire       rom_download;
wire       direct_video;
wire       vfb_ioctl_wait;
wire       vfb_hblank, vfb_vblank, vfb_field;
wire       video_is_15khz, video_supports_120hz;
wire       vfb_video_mode_toggle, vfb_video_freeze;
wire [1:0] vfb_profile_res;
wire       fifo_full_led;
wire       save_hold_reset, save_pending, save_available, save_error;
logic [22:0] reset_timeout = 23'd0;

// Default values for unused framework ports.
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;


assign LED_USER       = ioctl_download | fifo_full_led | save_pending | save_error;
assign LED_DISK       = 0;
assign LED_POWER      = 0;
assign BUTTONS        = 0;
assign VGA_SCALER     = 0;
assign VGA_DISABLE    = 0;
assign HDMI_BLACKOUT  = 0;
assign HDMI_BOB_DEINT = 0;

`include "build_id.v"
// PiTrex mode build number: shown in Core Info and reported in the ring's
// status block. Bump both together for every build that goes on a MiSTer.
localparam [7:0] PTX_BUILD = 8'd5;

localparam CONF_STR = {
	"VECTREX;;",
	"-;",
	"f1,ART;",
	"FS1,VECBINROM;",
	"F2,ART,Load Overlay;",
	"-;",
	// Fixed profiles and two independently saved custom profiles.
	"H7P1,Video Profiles & Effects;",
	"P1O[68:66],Profile,80s Cruise Control,80s Overdrive,Neon Blue,Red Alert,Ultraviolet,Custom 1,Custom 2,A Touch of CRT;",
	"H9HAHBHCHDHEP1-;",
	"H9HAHBHCHDHEP1-,Crisp vectors. Gentle glow.;",
	"H9HAHBHCHDHEP1-,A conservatively adjusted;",
	"H9HAHBHCHDHEP1-,Vectrex for those who keep;",
	"H9HAHBHCHDHEP1-,the box and want the tube;",
	"H9HAHBHCHDHEP1-,to last forever.;",
	"H9HAHBHCHDHEP1-;",
	"H9HAHBHCHDHEP1-,For advanced settings;",
	"H9HAHBHCHDHEP1-,select Custom Profiles 1/2;",
	"h9HAP1-;",
	"h9HAP1-,The familiar Vectrex glow.;",
	"h9HAP1-,Luminous lines and bright;",
	"h9HAP1-,sparks against the dark.;",
	"h9HAP1-,Full of character with;",
	"h9HAP1-,the glow kept in balance.;",
	"h9HAP1-;",
	"h9HAP1-,For advanced settings;",
	"h9HAP1-,select Custom Profiles 1/2;",
	"hAH9P1-;",
	"hAH9P1-,Hot vectors and fuller glow;",
	"hAH9P1-,with trails that linger.;",
	"hAH9P1-,Vectrex turned up a notch.;",
	"hAH9P1-,A gentle phosphor shimmer;",
	"hAH9P1-,gives it a livelier pulse.;",
	"hAH9P1-;",
	"hAH9P1-,For advanced settings;",
	"hAH9P1-,select Custom Profiles 1/2;",
	"h9hAP1-;",
	"h9hAP1-,Electric blue neon blazes;",
	"h9hAP1-,white at its brightest.;",
	"h9hAP1-,A subdued blue halo hangs;",
	"h9hAP1-,in the dark behind it.;",
	"h9hAP1-;",
	"h9hAP1-,Best without an overlay.;",
	"h9hAP1-,Inspired by Neon Hawk.;",
	"h9hAP1-;",
	"h9hAP1-,For advanced settings;",
	"h9hAP1-,select Custom Profiles 1/2;",
	"hBP1-;",
	"hBP1-,Red warning lights ablaze.;",
	"hBP1-,Wild flicker. Fierce glow.;",
	"hBP1-,Long restless trails.;",
	"hBP1-,The CRT pushed past its;",
	"hBP1-,limits. An arcade meltdown.;",
	"hBP1-;",
	"hBP1-,Best without an overlay.;",
	"hBP1-;",
	"hBP1-,     Epilepsy warning:;",
	"hBP1-,    excessive flashing;",
	"hCP1-;",
	"hCP1-,Violet arcade fever dream.;",
	"hCP1-,Boosted until the phosphor;",
	"hCP1-,almost burns through.;",
	"hCP1-,Neon haze and long trails.;",
	"hCP1-,Spectacular explosions;",
	"hCP1-,flood the screen.;",
	"hCP1-;",
	"hCP1-,Best without an overlay.;",
	"hCP1-;",
	"hCP1-,     Epilepsy warning:;",
	"hCP1-,    excessive flashing;",
	"hDP1O[54:52],> Dwell Low Size,1,2,3,4,5,6,7,8;",
	"hDP1O[71:69],> Dwell Mid Growth,Same,+1,+2,+3,+4,+5,+6,+7;",
	"hDP1O[6:4],> Dwell High Growth,Same,+1,+2,+3,+4,+5,+6,+7;",
	"hDP1O[73:72],> Brightness,Reduced,Standard,Bright,Boost;",
	"hDP1O[76:74],> Bloom Width,Off,Thin,Tight,Soft,Normal,Broad,Wide-,Wide;",
	"hDH5P1O[79:77],> Bloom Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hDP1O[82:80],> Halo,Off,0.25x,0.33x,0.5x,0.75x,1.0x,1.25x,1.5x;",
	"hDH6P1O[43:41],> Halo Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hDH6P1O[84:83],> Halo Spread,Original,Wide 1,Wide 2,Focus;",
	"hDH6P1O[57:55],> Halo Compression,Off,2,4,6,8,10,16,24;",
	"hDH6P1O[38],> Halo Grid,16x16,8x8;",
	"hDP1O[86:85],> Inter-Frame Decay,Off,Short,Medium,Long;",
	"hDP1O[88:87],> Intra-Frame Decay,Off,LUT A,LUT B,LUT C;",
	"hDP1O[91:89],> Vector Color,Vectrex P4,Deluxe Blue,White,Red,Purple,Cyan,Blue;",
	"hEP1O[126:124],> Dwell Low Size,1,2,3,4,5,6,7,8;",
	"hEP1O[94:92],> Dwell Mid Growth,Same,+1,+2,+3,+4,+5,+6,+7;",
	"hEP1O[15:13],> Dwell High Growth,Same,+1,+2,+3,+4,+5,+6,+7;",
	"hEP1O[96:95],> Brightness,Reduced,Standard,Bright,Boost;",
	"hEP1O[99:97],> Bloom Width,Off,Thin,Tight,Soft,Normal,Broad,Wide-,Wide;",
	"hEH5P1O[102:100],> Bloom Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hEP1O[105:103],> Halo,Off,0.25x,0.33x,0.5x,0.75x,1.0x,1.25x,1.5x;",
	"hEH6P1O[46:44],> Halo Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hEH6P1O[107:106],> Halo Spread,Original,Wide 1,Wide 2,Focus;",
	"hEH6P1O[60:58],> Halo Compression,Off,2,4,6,8,10,16,24;",
	"hEH6P1O[28],> Halo Grid,16x16,8x8;",
	"hEP1O[109:108],> Inter-Frame Decay,Off,Short,Medium,Long;",
	"hEP1O[111:110],> Intra-Frame Decay,Off,LUT A,LUT B,LUT C;",
	"hEP1O[114:112],> Vector Color,Vectrex P4,Deluxe Blue,White,Red,Purple,Cyan,Blue;",
	"P2,Video Overlay & Geometry;",
	"P2-;",
	"P2O[24],Overlay,On,Off;",
	"h3P2O[10:8],Tint Strength,0,+1,+2,+3,+4,+5,+6,-1;",
	"h3P2O[27:25],Translucent Blend,50%,60%,70%,80%,10%,20%,30%,40%;",
	"h3P2O[34:32],Opaque Brightness,50%,60%,70%,80%,10%,20%,30%,40%;",
	"P2-;",
	"P2O[21:20],Orientation,Normal,90 CCW,90 CW;",
	"P2O[30],Framing,Overlay,Screen;",
	"P2O[31],View Area,Standard,Open Matte;",
	"P2O[29],Offset,Compensated,Zero;",
	"P2-;",
	"d0D1P2O[122],120Hz (720p only),Off,On;",
	"h0h1P2O[121],Direct Video Scan Rate,15 kHz,31 kHz;",
	"h2P2O[120],15 kHz Format,480i,240p;",
	"h1P2O[3:1],CRT Vertical Offset,0,+1,+2,+3,-1,-2,-3;",
	"-;",
	"P3,System;",
	"P3-;",
	"P3O[35],BIOS,Rev 3,Rev 1;",
	"P3O[11],Quick Boot,Yes,No;",
	"P3O[23:22],Beam Threshold,Z 20,Z 24,Z 28,Off;",
	"P3O[12],Port 2,Joystick,VecVoice (SP0256);",
	"P3O[36],PiTrex Mode,Off,On;",
	"d8P3O[19:18],Speech Level,Normal,Low,High;",
	"hFP3O[118],Cartridge Autosave,On,Off;",
	"hFP3R[119],Save Cartridge;",
	"h4P3-,Cartridge save error;",
	"P3-;",
	"P3O[116],Pause when OSD open,Off,On;",
	"P3O[117],Dim video after 60s,On,Off;",
	"P4,Diagnostic;",
	"P4-;",
	"P4O[123],Effects Bypass,Off,On;",
	"P4O[48:47],Reference Dwell,46,72,Standard,104;",
	"P4O[50:49],Velocity Comp.,0.3,0.4,0.5,Off;",
	"P4O[64:63],Halo Correction,None,50%,75%,100%;",
	"P4-;",
	"P4O[40:39],Buffer Mode,EOF + VBL,VBL,EOF;",
	"P4O[17:16],Aspect Ratio,Optimized,Stretched,Pixel Perfect;",
	"-;",
	"P5,Core Info;",
	"P5-;",
	"P5-,Enhanced Vectrex core;",
	"P5-,     by Videodr0me 2026;",
	"P5-;",
	"P5-,Based on Sorgelig's MiSTer;",
	"P5-,port of Dar's original;",
	"P5-,DE10-Lite core, with;",
	"P5-,additional work by alanswx.;",
	"P5-;",
	"P5-,PiTrex mode: build B5;",
	"P5-;",
	"P5-,If you enjoy reliving the;",
	"P5-,golden age of vector games,;",
	"P5-,please support my work and;",
	"P5-,future updates:;",
	"P5-;",
	"P5-,buymeacoffee.com/videodr0me;",
	"-;",
	"R7,Reset;",
	"J1,Button 1,Button 2,Button 3,Button 4,Pause,View;",
	"jn,A,B,X,Y,Select,R;",
	"I,",
	"Overlay On / Framing: Overlay,",
	"Overlay Off / Framing: Overlay,",
	"Overlay Off / Framing: Screen,",
	"Overlay Off / Open Matte,",
	"Profile: 80s Cruise Control,",
	"Profile: 80s Overdrive,",
	"Profile: Neon Blue,",
	"Profile: Red Alert,",
	"Profile: Ultraviolet,",
	"Profile: Custom 1,",
	"Profile: Custom 2,",
	"Profile: A Touch of CRT,",
	"Copied to Custom 1,",
	"Copied to Custom 2;",
	// Keep version metadata after selectable entries; MiSTer counts it during action lookup.
	"v,1;",
	"V,v1.0.",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire        clk_sys;
wire        machine_pll_locked_raw;
logic [1:0] machine_pll_lock_sync = 2'b00;

pll pll
(
	.refclk  (CLK_50M),
	.rst     (1'b0),
	.outclk_0(clk_sys),
	.locked  (machine_pll_locked_raw)
);

always_ff @(posedge clk_sys or negedge machine_pll_locked_raw) begin
	if (!machine_pll_locked_raw) machine_pll_lock_sync <= 2'b00;
	else machine_pll_lock_sync <= {machine_pll_lock_sync[0], 1'b1};
end

// videodr0me_fb runs at 125 MHz; see rtl/pll_vfb for why it needs its own PLL.
wire clk_125;
wire pll_vfb_locked;
pll_vfb pll_vfb
(
	.refclk  (CLK_50M),
	.rst     (1'b0),
	.outclk_0(clk_125),
	.locked  (pll_vfb_locked)
);

///////////////////////////////////////////////////

wire [127:0] status;
vfb_control_pkg::profile_settings_t profile_settings;
vfb_control_pkg::diagnostic_settings_t diagnostic_settings;
wire         profile_bypass;
wire [15:0]  profile_menu_mask;
wire [127:0] profile_status_in;
wire         profile_status_set;
wire         menu_info_req;
wire [7:0]   menu_info;
wire [10:0]  ps2_key;
wire [15:0]  joystick_0, joystick_1;
wire         artwork_valid_125;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
logic artwork_valid_meta = 1'b0, artwork_valid_sync = 1'b0;
logic artwork_valid_seen = 1'b0;
always_ff @(posedge clk_sys) begin
	artwork_valid_meta <= artwork_valid_125;
	artwork_valid_sync <= artwork_valid_meta;
	if (!artwork_valid_sync)
		artwork_valid_seen <= 1'b0;
	else if (!RESET)
		artwork_valid_seen <= 1'b1;
end
wire artwork_loaded = artwork_valid_sync && !artwork_valid_seen;
// Touch is the only profile for which mask bits 14:9 are all clear.
wire [15:0] status_menu_mask = {save_available, profile_menu_mask[14:9],
	status[12], profile_menu_mask[7:5], save_error, profile_menu_mask[3:0]};

vfb_profile_resolver profile_resolver (
	.clk_sys             (clk_sys),
	.reset               (RESET),
	.status              (status),
	.profile_resolution  (vfb_profile_res),
	.video_freeze        (vfb_video_freeze),
	.video_is_15khz      (video_is_15khz),
	.video_supports_120hz(video_supports_120hz),
	.direct_video        (direct_video),
	.artwork_loaded      (artwork_loaded),
	.artwork_present     (artwork_valid_sync),
	.view_button         (joystick_0[9] | joystick_1[9]),
	.osd_open            (OSD_STATUS),
	.ps2_key             (ps2_key),

	.profile_settings    (profile_settings),
	.diagnostic_settings (diagnostic_settings),
	.effects_bypass      (profile_bypass),
	.menu_mask           (profile_menu_mask),
	.status_in           (profile_status_in),
	.status_set          (profile_status_set),
	.info_req            (menu_info_req),
	.info                (menu_info)
);
wire  [1:0] buttons;

wire [15:0] joya_0, joya_1;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire [7:0]  ioctl_dout;
wire [15:0] ioctl_index;
wire [32:0] timestamp;
wire [17:0] backup_addr;
wire [7:0]  backup_data, backup_q;
wire        backup_wr, flash_enabled, flash_busy, flash_changed;
wire [5:0]  flash_sector;
wire [31:0] sd_lba;
wire        sd_rd, sd_wr, sd_ack, sd_buff_wr;
wire [13:0] sd_buff_addr;
wire [7:0]  sd_buff_dout, sd_buff_din;
wire        img_mounted, img_readonly;
wire [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys            (clk_sys),
	.HPS_BUS            (HPS_BUS),

	.buttons            (buttons),
	.status             (status),
	.status_in          (profile_status_in),
	.status_set         (profile_status_set),
	.info_req           (menu_info_req),
	.info               (menu_info),
	.ps2_key            (ps2_key),
	.status_menumask    (status_menu_mask),
	.direct_video       (direct_video),
	.new_vmode          (vfb_video_mode_toggle),
	.TIMESTAMP          (timestamp),
	.img_mounted        (img_mounted),
	.img_readonly       (img_readonly),
	.img_size           (img_size),
	.sd_lba             ('{sd_lba}),
	.sd_blk_cnt         ('{6'd0}),
	.sd_rd              (sd_rd),
	.sd_wr              (sd_wr),
	.sd_ack             (sd_ack),
	.sd_buff_addr       (sd_buff_addr),
	.sd_buff_dout       (sd_buff_dout),
	.sd_buff_din        ('{sd_buff_din}),
	.sd_buff_wr         (sd_buff_wr),

	.ioctl_download     (ioctl_download),
	.ioctl_wr           (ioctl_wr),
	.ioctl_addr         (ioctl_addr),
	.ioctl_dout         (ioctl_dout),
	.ioctl_index        (ioctl_index),
	.ioctl_wait         (vfb_ioctl_wait),

	.joystick_l_analog_0(joya_0),
	.joystick_l_analog_1(joya_1),
	.joystick_0         (joystick_0),
	.joystick_1         (joystick_1)
);

vectrex_flash_save flash_save (
	.clk          (clk_sys),
	.download     (rom_download),
	.download_wr  (ioctl_wr && rom_download),
	.download_data(ioctl_dout),
	.flash_enabled(flash_enabled),
	.flash_busy   (flash_busy),
	.flash_changed(flash_changed),
	.flash_sector (flash_sector),
	.cart_addr    (backup_addr),
	.cart_data    (backup_data),
	.cart_wr      (backup_wr),
	.cart_q       (backup_q),
	.autosave     (!status[118]),
	.save_request (status[119]),
	.hold_reset   (save_hold_reset),
	.pending      (save_pending),
	.available    (save_available),
	.error        (save_error),
	.img_mounted  (img_mounted),
	.img_readonly (img_readonly),
	.img_size     (img_size),
	.sd_lba       (sd_lba),
	.sd_rd        (sd_rd),
	.sd_wr        (sd_wr),
	.sd_ack       (sd_ack),
	.sd_buff_addr (sd_buff_addr),
	.sd_buff_dout (sd_buff_dout),
	.sd_buff_wr   (sd_buff_wr),
	.sd_buff_din  (sd_buff_din)
);

wire       pause_cpu;
wire [9:0] audio;
assign AUDIO_L   = pause_cpu ? 16'd0 : {audio, 6'd0};
assign AUDIO_R   = pause_cpu ? 16'd0 : {audio, 6'd0};
assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;

// Span two MC6809 fall-E reset samples without disturbing video state.
logic       bios_factory_q = 1'b0;
logic [5:0] bios_reset_cnt = 6'd0;
always_ff @(posedge clk_sys) begin
	if (bios_factory_q != status[35]) begin
		bios_factory_q <= status[35];
		bios_reset_cnt <= 6'd32;
	end
	else if (bios_reset_cnt != 0)
		bios_reset_cnt <= bios_reset_cnt - 1'b1;
end
wire bios_reset = bios_reset_cnt != 0;

// Cartridge loading and menu reset stop machine/source timing while the
// current framebuffer continues presenting. Framework resets restart both.
wire video_reset = !machine_pll_lock_sync[1] | RESET | status[0] | buttons[1];
wire delayed_reset = (reset_timeout != 23'd0) &&
	(reset_timeout <= 23'd999);
// PiTrex mode: a short machine reset on every mode change (clean VIA state on
// entry; a normal BIOS boot on exit).
// PiTrex takes over only while the option is on AND a live ARM program
// is detected (coded heartbeat); assigned in the PiTrex block below.
wire      ptx_active;
reg       ptx_mode_q = 1'b0;
reg [4:0] ptx_mode_reset_cnt = 5'd0;
always_ff @(posedge clk_sys) begin
	ptx_mode_q <= ptx_active;
	if (ptx_mode_q != ptx_active)
		ptx_mode_reset_cnt <= 5'd31;
	else if (ptx_mode_reset_cnt != 5'd0)
		ptx_mode_reset_cnt <= ptx_mode_reset_cnt - 1'd1;
end
wire ptx_mode_reset = ptx_mode_reset_cnt != 5'd0;
wire machine_reset = video_reset | status[7] | rom_download | save_hold_reset | delayed_reset | ptx_mode_reset;
wire core_reset = machine_reset | bios_reset;

// A delayed warm reset preserves RAM state and skips the GCE startup animation.
always_ff @(posedge clk_sys) begin
	if ((rom_download || save_hold_reset) && !status[11])
		reset_timeout <= 23'd5_000_001;
	else if (reset_timeout != 23'd0)
		reset_timeout <= reset_timeout - 1'b1;
end


assign VGA_SL      = 0;
assign VGA_F1      = vfb_field;
assign HDMI_FREEZE = vfb_video_freeze;
assign VGA_DE      = ~(vfb_hblank | vfb_vblank);

wire        vfb_clk_video, vfb_ce_pixel;
wire [7:0]  vfb_r, vfb_g, vfb_b;
wire        vfb_hs, vfb_vs;
wire [23:0] paused_rgb;

pause #(.RW(8), .GW(8), .BW(8), .CLK_HZ(24_000_000)) pause_inst
(
	.clk_sys      (clk_sys),
	.reset        (machine_reset),
	.user_button  (joystick_0[8] | joystick_1[8]),
	.pause_request(1'b0),
	.options      ({~status[117], status[116]}),
	.OSD_STATUS   (OSD_STATUS),
	.r            (vfb_r),
	.g            (vfb_g),
	.b            (vfb_b),
	.pause_cpu    (pause_cpu),
	.rgb_out      (paused_rgb)
);

assign CLK_VIDEO = vfb_clk_video;
assign CE_PIXEL  = vfb_ce_pixel;
assign VGA_R     = paused_rgb[23:16];
assign VGA_G     = paused_rgb[15:8];
assign VGA_B     = paused_rgb[7:0];
assign VGA_HS    = vfb_hs;
assign VGA_VS    = vfb_vs;

// Beam state exported by the machine core to the external renderer.
wire signed [19:0] beam_x, beam_y;
wire [7:0]         beam_z;
wire               beam_on, beam_ce, beam_zero_n;
wire               t2_reload;
wire [15:0]        t2_period;


// boot2.rom contains artwork; boot.rom remains the startup cartridge.
assign rom_download = ioctl_download && (ioctl_index[4:0] <= 1) &&
	(ioctl_index[9:8] == 0) && (ioctl_index != 16'h0080);

// ---------------------------------------------------------------------------
// PiTrex mode: the ARM streams timestamped VIA writes through a DDR ring
// (pitrex_ddr, clk_125, on the framebuffer's DDR arbiter) and a cross-clock
// FIFO into pitrex_player (clk_sys), which drives the machine bus while the
// 6809 is held in reset. Stream format: PiTrex-on-MiSTer PROTOCOL.md.
// ---------------------------------------------------------------------------
wire        ptx_enable = status[36];      // option on: listen for a program
wire        ptx_present_125;
(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
reg [1:0]   ptx_present_sys = 2'b00;
always_ff @(posedge clk_sys) ptx_present_sys <= {ptx_present_sys[0], ptx_present_125};
assign      ptx_active = ptx_enable && ptx_present_sys[1];
wire signed [7:0] pot_x1 = joya_0[7:0]  ? joya_0[7:0]   : {joystick_0[1], {7{joystick_0[0]}}};
wire signed [7:0] pot_y1 = joya_0[15:8] ? ~joya_0[15:8] : {joystick_0[2], {7{joystick_0[3]}}};
wire signed [7:0] pot_x2 = joya_1[7:0]  ? joya_1[7:0]   : {joystick_1[1], {7{joystick_1[0]}}};
wire signed [7:0] pot_y2 = joya_1[15:8] ? ~joya_1[15:8] : {joystick_1[2], {7{joystick_1[3]}}};

wire [15:0] ptx_addr;
wire [7:0]  ptx_do;
wire        ptx_rw;
wire        ptx_stall;
wire        vec_e_fall;
wire [7:0]  vec_psg_ioa;

wire        ptx_fifo_rd_en, ptx_fifo_rd_valid, ptx_fifo_rd_empty;
wire [63:0] ptx_fifo_rd_data;
wire        ptx_fifo_wr_en, ptx_fifo_almost_full;
wire [63:0] ptx_fifo_wr_data;

wire [47:0] ptx_snap_cycles;
wire [15:0] ptx_snap_frames, ptx_snap_underruns;
wire [31:0] ptx_snap_pots;
wire [7:0]  ptx_snap_ioa;
wire        ptx_snap_toggle;

pitrex_player pitrex_player
(
	.clk            (clk_sys),
	.enable         (ptx_active),
	.e_fall         (vec_e_fall),
	.fifo_rd_en     (ptx_fifo_rd_en),
	.fifo_rd_data   (ptx_fifo_rd_data),
	.fifo_rd_valid  (ptx_fifo_rd_valid),
	.fifo_rd_empty  (ptx_fifo_rd_empty),
	.bus_addr       (ptx_addr),
	.bus_do         (ptx_do),
	.bus_rw         (ptx_rw),
	.stall          (ptx_stall),
	.pots           ({pot_y2, pot_x2, pot_y1, pot_x1}),
	.psg_ioa        (vec_psg_ioa),
	.snap_cycles    (ptx_snap_cycles),
	.snap_frames    (ptx_snap_frames),
	.snap_underruns (ptx_snap_underruns),
	.snap_pots      (ptx_snap_pots),
	.snap_ioa       (ptx_snap_ioa),
	.snap_toggle    (ptx_snap_toggle)
);

(* altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
reg [1:0] ptx_enable_125 = 2'b00;
always_ff @(posedge clk_125) ptx_enable_125 <= {ptx_enable_125[0], ptx_enable};

vfb_async_fifo #(.WIDTH(64), .DEPTH(128), .ALMOST_FULL_MARGIN(40)) pitrex_fifo
(
	.wr_clk         (clk_125),
	.wr_reset       (!(ptx_enable_125[1] && ptx_present_125)),
	.wr_en          (ptx_fifo_wr_en),
	.wr_data        (ptx_fifo_wr_data),
	.wr_full        (),
	.wr_almost_full (ptx_fifo_almost_full),
	.rd_clk         (clk_sys),
	.rd_reset       (!ptx_active),
	.rd_en          (ptx_fifo_rd_en),
	.rd_data        (ptx_fifo_rd_data),
	.rd_valid       (ptx_fifo_rd_valid),
	.rd_empty       (ptx_fifo_rd_empty)
);

wire        ptx_read_ready, ptx_read_grant, ptx_read_data_valid;
wire [28:0] ptx_read_addr;
wire [7:0]  ptx_read_burstcnt;
wire [63:0] ptx_read_data;
wire        ptx_write_ready, ptx_write_grant, ptx_write_done, ptx_write_advance;
wire [28:0] ptx_write_addr;
wire [7:0]  ptx_write_burstcnt, ptx_write_be;
wire [63:0] ptx_write_data;

pitrex_ddr #(.BUILD(PTX_BUILD)) pitrex_ddr
(
	.clk              (clk_125),
	.enable           (ptx_enable_125[1]),
	.present          (ptx_present_125),
	.rd_ready         (ptx_read_ready),
	.rd_grant         (ptx_read_grant),
	.rd_addr          (ptx_read_addr),
	.rd_burstcnt      (ptx_read_burstcnt),
	.rd_data          (ptx_read_data),
	.rd_data_valid    (ptx_read_data_valid),
	.wr_ready         (ptx_write_ready),
	.wr_grant         (ptx_write_grant),
	.wr_done          (ptx_write_done),
	.wr_addr          (ptx_write_addr),
	.wr_burstcnt      (ptx_write_burstcnt),
	.wr_data          (ptx_write_data),
	.wr_be            (ptx_write_be),
	.wr_advance       (ptx_write_advance),
	.fifo_wr_en       (ptx_fifo_wr_en),
	.fifo_wr_data     (ptx_fifo_wr_data),
	.fifo_almost_full (ptx_fifo_almost_full),
	.snap_cycles      (ptx_snap_cycles),
	.snap_frames      (ptx_snap_frames),
	.snap_underruns   (ptx_snap_underruns),
	.snap_pots        (ptx_snap_pots),
	.snap_ioa         (ptx_snap_ioa),
	.snap_toggle      (ptx_snap_toggle)
);

vectrex vectrex
(
	.reset        (core_reset),
	.pause        ((pause_cpu && !bios_reset) || ptx_stall),
	.clock        (clk_sys),
	.bios_factory (bios_factory_q),
	.boot_reset   (status[0]),
	.timestamp    (timestamp),

	.cart_download(rom_download),
	.cart_data    (ioctl_dout),
	.cart_addr    (ioctl_addr),
	.cart_wr      (ioctl_wr && rom_download),
	.backup_addr  (backup_addr),
	.backup_data  (backup_data),
	.backup_wr    (backup_wr),
	.backup_q     (backup_q),
	.flash_enabled(flash_enabled),
	.flash_busy   (flash_busy),
	.flash_changed(flash_changed),
	.flash_sector (flash_sector),

	.speech_mode  (status[12]),
	.speech_level (status[19:18]),
	.audio_out    (audio),

	.up_1         (joystick_0[4]),
	.dn_1         (joystick_0[5]),
	.lf_1         (joystick_0[6]),
	.rt_1         (joystick_0[7]),
	.pot_x_1      (pot_x1),
	.pot_y_1      (pot_y1),

	.up_2         (joystick_1[4]),
	.dn_2         (joystick_1[5]),
	.lf_2         (joystick_1[6]),
	.rt_2         (joystick_1[7]),
	.pot_x_2      (pot_x2),
	.pot_y_2      (pot_y2),

	.beam_x       (beam_x),
	.beam_y       (beam_y),
	.beam_on      (beam_on),
	.beam_z       (beam_z),
	.beam_ce      (beam_ce),
	.beam_zero_n  (beam_zero_n),
	.t2_reload    (t2_reload),
	.t2_period    (t2_period),

	.ptx_enable   (ptx_active),
	.ptx_addr     (ptx_addr),
	.ptx_do       (ptx_do),
	.ptx_rw       (ptx_rw),
	.e_fall_o     (vec_e_fall),
	.psg_ioa_o    (vec_psg_ioa)
);


// ---------------------------------------------------------------------------
// vectrex_video maps the emulated beam into the selected raster and feeds the
// external framebuffer and CRT-effects pipeline.
// ---------------------------------------------------------------------------
vectrex_video vectrex_video
(
	.clk_sys            (clk_sys),
	.clk_50             (CLK_50M),
	.clk_125            (clk_125),
	.reset              (video_reset),
	.vfb_clock_reset    (!pll_vfb_locked),
	.reset_source       (machine_reset),

	.beam_x             (beam_x),
	.beam_y             (beam_y),
	.beam_z             (beam_z),
	.beam_on            (beam_on),
	.beam_tick          (beam_ce),
	.beam_zero_n        (beam_zero_n),
	.t2_reload          (t2_reload),
	.t2_period          (t2_period),

	.hdmi_height        (HDMI_HEIGHT),
	.direct_video       (direct_video),
	.direct_video_31khz (status[121]),
	.crt_15khz_480i     (!status[120]),
	.crt_vertical_position (status[3:1]),
	.mode_120hz         (status[122]),
	.aspect_ratio       (status[17:16]),

	.v_orient           (status[21:20]),
	.open_matte         (status[31]),
	.zoom_normal        (status[30]),
	.vertical_offset    (!status[29]),
	.beam_threshold     (status[23:22]),

	.overlay_off        (status[24]),
	.ovl_tint           (status[10:8]),
	.ovl_bright         (status[27:25]),
	.ovl_opaque_bright  (status[34:32]),
	.profile_settings   (profile_settings),
	.diagnostic_settings(diagnostic_settings),
	.effects_bypass     (profile_bypass),
	.ioctl_download     (ioctl_download),
	.ioctl_wr           (ioctl_wr),
	.ioctl_index        (ioctl_index),
	.ioctl_addr         (ioctl_addr),
	.ioctl_data         (ioctl_dout),
	.ioctl_wait         (vfb_ioctl_wait),
	.artwork_valid      (artwork_valid_125),
	// Mode 0 promotes completed redraws at VBLANK. Accepted Timer 2 reloads
	// define normal boundaries; the armed fallback uses ZERO or timeout.
	.buffer_mode        (status[40:39]),
	.clk_video          (vfb_clk_video),
	.ce_pixel           (vfb_ce_pixel),
	.vga_r              (vfb_r),
	.vga_g              (vfb_g),
	.vga_b              (vfb_b),
	.vga_hs             (vfb_hs),
	.vga_vs             (vfb_vs),
	.vga_hblank         (vfb_hblank),
	.vga_vblank         (vfb_vblank),
	.field              (vfb_field),
	.video_arx          (VIDEO_ARX),
	.video_ary          (VIDEO_ARY),
	.mode_is_15khz      (video_is_15khz),
	.mode_supports_120hz(video_supports_120hz),
	.profile_resolution (vfb_profile_res),
	.video_mode_toggle  (vfb_video_mode_toggle),
	.video_freeze       (vfb_video_freeze),

	.ddram_clk          (DDRAM_CLK),
	.ddram_busy         (DDRAM_BUSY),
	.ddram_burstcnt     (DDRAM_BURSTCNT),
	.ddram_addr         (DDRAM_ADDR),
	.ddram_dout         (DDRAM_DOUT),
	.ddram_dout_ready   (DDRAM_DOUT_READY),
	.ddram_rd           (DDRAM_RD),
	.ddram_din          (DDRAM_DIN),
	.ddram_be           (DDRAM_BE),
	.ddram_we           (DDRAM_WE),
	.ptx_read_ready     (ptx_read_ready),
	.ptx_read_grant     (ptx_read_grant),
	.ptx_read_addr      (ptx_read_addr),
	.ptx_read_burstcnt  (ptx_read_burstcnt),
	.ptx_read_data      (ptx_read_data),
	.ptx_read_data_valid(ptx_read_data_valid),
	.ptx_write_ready    (ptx_write_ready),
	.ptx_write_grant    (ptx_write_grant),
	.ptx_write_done     (ptx_write_done),
	.ptx_write_addr     (ptx_write_addr),
	.ptx_write_burstcnt (ptx_write_burstcnt),
	.ptx_write_data     (ptx_write_data),
	.ptx_write_be       (ptx_write_be),
	.ptx_write_advance  (ptx_write_advance),

	.sdram_dq           (SDRAM_DQ),
	.sdram_clk          (SDRAM_CLK),
	.sdram_cke          (SDRAM_CKE),
	.sdram_ncs          (SDRAM_nCS),
	.sdram_nras         (SDRAM_nRAS),
	.sdram_ncas         (SDRAM_nCAS),
	.sdram_nwe          (SDRAM_nWE),
	.sdram_dqml         (SDRAM_DQML),
	.sdram_dqmh         (SDRAM_DQMH),
	.sdram_a            (SDRAM_A),
	.sdram_ba           (SDRAM_BA),

	.fifo_full_led      (fifo_full_led)
);

endmodule
