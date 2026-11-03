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

import vfb_control_pkg::*;

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
localparam CONF_STR = {
	"VECTREX;;",
	"-;",
	"f1,ART;",
	"FS1,VECBINROM;",
	"F2,ART,Load Overlay;",
	"-;",
	// Fixed profiles and two independently saved custom profiles.
	"H7P1,Video Profiles & Effects;",
	"P1O[14:12],Profile,80s Cruise Control,80s Overdrive,Neon Blue,Red Alert,Ultraviolet,Custom 1,Custom 2,A Touch of CRT;",
	"h9hAhBP1-;",
	"h9hAhBP1-,Crisp vectors. Gentle glow.;",
	"h9hAhBP1-,A conservatively adjusted;",
	"h9hAhBP1-,Vectrex for those who keep;",
	"h9hAhBP1-,the box and want the tube;",
	"h9hAhBP1-,to last forever.;",
	"h9hAhBP1-;",
	"h9hAhBP1-,For advanced settings;",
	"h9hAhBP1-,select Custom Profiles 1/2;",
	"H9HAHBP1-;",
	"H9HAHBP1-,The familiar Vectrex glow.;",
	"H9HAHBP1-,Luminous lines and bright;",
	"H9HAHBP1-,sparks against the dark.;",
	"H9HAHBP1-,Full of character with;",
	"H9HAHBP1-,the glow kept in balance.;",
	"H9HAHBP1-;",
	"H9HAHBP1-,For advanced settings;",
	"H9HAHBP1-,select Custom Profiles 1/2;",
	"h9HAHBP1-;",
	"h9HAHBP1-,Hot vectors and fuller glow;",
	"h9HAHBP1-,with trails that linger.;",
	"h9HAHBP1-,Vectrex turned up a notch.;",
	"h9HAHBP1-,A gentle phosphor shimmer;",
	"h9HAHBP1-,gives it a livelier pulse.;",
	"h9HAHBP1-;",
	"h9HAHBP1-,For advanced settings;",
	"h9HAHBP1-,select Custom Profiles 1/2;",
	"H9hAHBP1-;",
	"H9hAHBP1-,Electric blue neon blazes;",
	"H9hAHBP1-,white at its brightest.;",
	"H9hAHBP1-,A subdued blue halo hangs;",
	"H9hAHBP1-,in the dark behind it.;",
	"H9hAHBP1-;",
	"H9hAHBP1-,Best without an overlay.;",
	"H9hAHBP1-,Inspired by Neon Hawk.;",
	"H9hAHBP1-;",
	"H9hAHBP1-,For advanced settings;",
	"H9hAHBP1-,select Custom Profiles 1/2;",
	"h9hAHBP1-;",
	"h9hAHBP1-,Red warning lights ablaze.;",
	"h9hAHBP1-,Wild flicker. Fierce glow.;",
	"h9hAHBP1-,Long restless trails.;",
	"h9hAHBP1-,The CRT pushed past its;",
	"h9hAHBP1-,limits. An arcade meltdown.;",
	"h9hAHBP1-;",
	"h9hAHBP1-,Best without an overlay.;",
	"h9hAHBP1-;",
	"h9hAHBP1-,     Epilepsy warning:;",
	"h9hAHBP1-,    excessive flashing;",
	"H9HAhBP1-;",
	"H9HAhBP1-,Violet arcade fever dream.;",
	"H9HAhBP1-,Boosted until the phosphor;",
	"H9HAhBP1-,almost burns through.;",
	"H9HAhBP1-,Neon haze and long trails.;",
	"H9HAhBP1-,Spectacular explosions;",
	"H9HAhBP1-,flood the screen.;",
	"H9HAhBP1-;",
	"H9HAhBP1-,Best without an overlay.;",
	"H9HAhBP1-;",
	"H9HAhBP1-,     Epilepsy warning:;",
	"H9HAhBP1-,    excessive flashing;",
	"hCh9P1O[23:21],> Dwell Low Size,1,2,3,4,5,6,7,8;",
	"hCh9P1O[26:24],> Dwell Mid Growth,Same,+1,+2,+3,+4,+5,+6,+7;",
	"hCh9P1O[29:27],> Dwell High Growth,Same,+1,+2,+3,+4,+5,+6,+7;",
	"hCh9P1O[17:16],> Brightness,Reduced,Standard,Bright,Boost;",
	"hCh9P1O[36:34],> Bloom Width,Off,Thin,Tight,Soft,Normal,Broad,Wide-,Wide;",
	"hCh9H5P1O[39:37],> Bloom Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hCh9P1O[42:40],> Halo,Off,0.25x,0.33x,0.5x,0.75x,1.0x,1.25x,1.5x;",
	"hCh9H6P1O[45:43],> Halo Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hCh9H6P1O[47:46],> Halo Spread,Original,Wide 1,Wide 2,Focus;",
	"hCh9H6P1O[50:48],> Halo Compression,Off,2,4,6,8,10,16,24;",
	"hCh9H6P1O[51],> Halo Grid,16x16,8x8;",
	"hCh9P1O[31:30],> Inter-Frame Decay,Off,Short,Medium,Long;",
	"hCh9P1O[33:32],> Intra-Frame Decay,Off,LUT A,LUT B,LUT C;",
	"hCh9P1O[20:18],> Vector Color,Vectrex P4,Deluxe Blue,White,Red,Purple,Cyan,Blue;",
	"hCH9P1O[87:85],> Dwell Low Size,1,2,3,4,5,6,7,8;",
	"hCH9P1O[90:88],> Dwell Mid Growth,Same,+1,+2,+3,+4,+5,+6,+7;",
	"hCH9P1O[93:91],> Dwell High Growth,Same,+1,+2,+3,+4,+5,+6,+7;",
	"hCH9P1O[81:80],> Brightness,Reduced,Standard,Bright,Boost;",
	"hCH9P1O[100:98],> Bloom Width,Off,Thin,Tight,Soft,Normal,Broad,Wide-,Wide;",
	"hCH9H5P1O[103:101],> Bloom Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hCH9P1O[106:104],> Halo,Off,0.25x,0.33x,0.5x,0.75x,1.0x,1.25x,1.5x;",
	"hCH9H6P1O[109:107],> Halo Curve,Minimal,Min+,Mild,Mild+,Moderate,Mod+,Strong-,Strong;",
	"hCH9H6P1O[111:110],> Halo Spread,Original,Wide 1,Wide 2,Focus;",
	"hCH9H6P1O[114:112],> Halo Compression,Off,2,4,6,8,10,16,24;",
	"hCH9H6P1O[115],> Halo Grid,16x16,8x8;",
	"hCH9P1O[95:94],> Inter-Frame Decay,Off,Short,Medium,Long;",
	"hCH9P1O[97:96],> Intra-Frame Decay,Off,LUT A,LUT B,LUT C;",
	"hCH9P1O[84:82],> Vector Color,Vectrex P4,Deluxe Blue,White,Red,Purple,Cyan,Blue;",
	"P2,Video Overlay & Geometry;",
	"P2-;",
	"P2O[63],Overlay,On,Off;",
	"h3P2O[68:66],Tint Strength,0,+1,+2,+3,+4,+5,+6,-1;",
	"h3P2O[71:69],Translucent Blend,60%,70%,80%,10%,20%,30%,40%,50%;",
	"h3P2O[74:72],Opaque Brightness,50%,60%,70%,80%,10%,20%,30%,40%;",
	"P2-;",
	"P2O[76:75],Orientation,Normal,90 CCW,90 CW;",
	"P2O[64],Framing,Overlay,Screen;",
	"P2O[65],View Area,Standard,Open Matte;",
	"P2O[77],Offset,Compensated,Zero;",
	"P2-;",
	"d0D1P2O[56],120Hz (720p only),Off,On;",
	"h0h1P2O[55],Direct Video Scan Rate,15 kHz,31 kHz;",
	"h2P2O[54],15 kHz Format,480i,240p;",
	"h1P2O[59:57],CRT Vertical Offset,0,+1,+2,+3,-1,-2,-3;",
	"h1P2O[62:60],CRT Horizontal Offset,0,+1,+2,+3,-1,-2,-3;",
	"-;",
	"P3,System;",
	"P3-;",
	"P3O[1],BIOS,Rev 3,Rev 1;",
	"P3O[2],Quick Boot,Yes,No;",
	"P3O[4:3],Beam Threshold,Z 20,Z 24,Z 28,Off;",
	"P3O[8],Port 2,Joystick,VecVoice (SP0256);",
	"d8P3O[10:9],Speech Level,Normal,Low,High;",
	"hFP3O[118],Cartridge Autosave,On,Off;",
	"hFP3R[119],Save Cartridge;",
	"h4P3-,Cartridge save error;",
	"P3-;",
	"P3O[5],Pause when OSD open,Off,On;",
	"P3O[6],Dim video after 60s,On,Off;",
	"P4,Diagnostic;",
	"P4-;",
	"P4O[11],Effects Bypass,Off,On;",
	"P4O[121:120],Reference Dwell,Standard,104,46,72;",
	"P4O[123:122],Velocity Comp.,0.3,0.4,0.5,Off;",
	"P4O[125:124],Halo Correction,100%,75%,50%,None;",
	"P4-;",
	"P4O[127:126],Buffer Mode,EOF + VBL,VBL,EOF;",
	"P4O[79:78],Aspect Ratio,Optimized,Stretched,Pixel Perfect;",
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
	"v,2;",
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

wire [127:0] status, host_status, stored_status;
wire [35:0]  settings_bus;

profile_settings_t    profile_settings;
diagnostic_settings_t diagnostic_settings;
wire                  profile_bypass;
wire [15:0]           profile_menu_mask;
wire                  settings_commit, settings_echo, settings_clear, reply_pending, capture_reply;

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
// Bits 11:9 select the profile text. Bit 12 enables the selected Custom controls.
wire [15:0] status_menu_mask = {save_available, profile_menu_mask[14:9], status[ST_SPEECH],
                                profile_menu_mask[7:5], save_error, profile_menu_mask[3:0]};

// At startup, wait until Main asserts reset, then completes a settings write with reset clear.
// Only then can the profile resolver send changes back to Main.
logic main_reset_seen = 1'b0;
logic settings_ready  = 1'b0;

always_ff @(posedge clk_sys) begin
	if (host_status[ST_MAIN_RESET])
		main_reset_seen <= 1'b1;
	if (main_reset_seen && settings_commit && !host_status[ST_MAIN_RESET])
		settings_ready <= 1'b1;
end

vectrex_status_guard status_guard (
	.clk_sys       (clk_sys),
	.ext_bus       (settings_bus),
	.incoming      (host_status),
	.stored        (stored_status),
	.commit        (settings_commit),
	.echo          (settings_echo),
	.clear_settings(settings_clear),
	.reply_pending (reply_pending),
	.reply_zero    (status == 128'd0),
	.capture       (capture_reply)
);

vfb_profile_resolver profile_resolver (
	.clk_sys             (clk_sys),
	.reset               (RESET || !settings_ready),
	.commit              (settings_commit),
	.echo                (settings_echo),
	.clear_settings      (settings_clear),
	.stored              (stored_status),
	.incoming            (host_status),
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
	.status              (status),
	.reply_pending       (reply_pending),
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
wire        backup_wr, backup_req, backup_ready, flash_enabled, cart_busy, cart_changed;
wire [5:0]  cart_sector;
wire [2:0]  eeprom_kind, score_kind;
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
	.EXT_BUS            (settings_bus),
	.status             (host_status),
	.status_in          (status),
	.status_set         (capture_reply),
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

vectrex_cartridge_save cartridge_save (
	.clk          (clk_sys),
	.download     (rom_download),
	.download_wr  (ioctl_wr && rom_download),
	.download_data(ioctl_dout),
	.flash_enabled(flash_enabled),
	.eeprom_kind  (eeprom_kind),
	.score_kind   (score_kind),
	.cart_busy    (cart_busy),
	.cart_changed (cart_changed),
	.cart_sector  (cart_sector),
	.cart_addr    (backup_addr),
	.cart_data    (backup_data),
	.cart_wr      (backup_wr),
	.cart_req     (backup_req),
	.cart_ready   (backup_ready),
	.cart_q       (backup_q),
	.autosave     (!status[ST_AUTOSAVE_OFF]),
	.save_request (host_status[ST_SAVE_CART]),
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
	if (bios_factory_q != status[ST_BIOS]) begin
		bios_factory_q <= status[ST_BIOS];
		bios_reset_cnt <= 6'd32;
	end
	else if (bios_reset_cnt != 0)
		bios_reset_cnt <= bios_reset_cnt - 1'b1;
end
wire bios_reset = bios_reset_cnt != 0;

// Cartridge loading and menu reset stop machine/source timing while the
// current framebuffer continues presenting. Framework resets restart both.
wire video_reset   = !machine_pll_lock_sync[1] | RESET | host_status[ST_MAIN_RESET] | buttons[1];
wire delayed_reset = (reset_timeout != 23'd0) && (reset_timeout <= 23'd999);
wire machine_reset = video_reset | host_status[ST_GAME_RESET] | rom_download |
                     save_hold_reset | delayed_reset;
wire core_reset    = machine_reset | bios_reset;

// A delayed warm reset preserves RAM state and skips the GCE startup animation.
always_ff @(posedge clk_sys) begin
	if ((rom_download || save_hold_reset) && !status[ST_QUICK_BOOT])
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
	.options      ({~status[ST_DIM], status[ST_OSD_PAUSE]}),
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


// Index 0x80 is boot2.rom artwork. boot.rom loads as a cartridge at index 0.
assign rom_download = ioctl_download && (ioctl_index[4:0] <= 1) &&
	(ioctl_index[9:8] == 0) && (ioctl_index != 16'h0080);

vectrex vectrex
(
	.reset        (core_reset),
	.pause        (pause_cpu && !bios_reset),
	.clock        (clk_sys),
	.bios_factory (bios_factory_q),
	.boot_reset   (host_status[ST_MAIN_RESET]),
	.timestamp    (timestamp),

	.cart_download(rom_download),
	.cart_data    (ioctl_dout),
	.cart_addr    (ioctl_addr),
	.cart_wr      (ioctl_wr && rom_download),
	.backup_addr  (backup_addr),
	.backup_data  (backup_data),
	.backup_wr    (backup_wr),
	.backup_req   (backup_req),
	.backup_ready (backup_ready),
	.backup_q     (backup_q),
	.eeprom_kind  (eeprom_kind),
	.score_kind   (score_kind),
	.flash_enabled(flash_enabled),
	.cart_busy    (cart_busy),
	.cart_changed (cart_changed),
	.cart_sector  (cart_sector),

	.speech_mode  (status[ST_SPEECH]),
	.speech_level (status[SPEECH_LEVEL_LSB +: 2]),
	.audio_out    (audio),

	.up_1         (joystick_0[4]),
	.dn_1         (joystick_0[5]),
	.lf_1         (joystick_0[6]),
	.rt_1         (joystick_0[7]),
	.pot_x_1      (joya_0[7:0]  ? joya_0[7:0]   : {joystick_0[1], {7{joystick_0[0]}}}),
	.pot_y_1      (joya_0[15:8] ? ~joya_0[15:8] : {joystick_0[2], {7{joystick_0[3]}}}),

	.up_2         (joystick_1[4]),
	.dn_2         (joystick_1[5]),
	.lf_2         (joystick_1[6]),
	.rt_2         (joystick_1[7]),
	.pot_x_2      (joya_1[7:0]  ? joya_1[7:0]   : {joystick_1[1], {7{joystick_1[0]}}}),
	.pot_y_2      (joya_1[15:8] ? ~joya_1[15:8] : {joystick_1[2], {7{joystick_1[3]}}}),

	.beam_x       (beam_x),
	.beam_y       (beam_y),
	.beam_on      (beam_on),
	.beam_z       (beam_z),
	.beam_ce      (beam_ce),
	.beam_zero_n  (beam_zero_n),
	.t2_reload    (t2_reload),
	.t2_period    (t2_period)
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
	.direct_video_31khz (status[ST_DIRECT_31KHZ]),
	.crt_15khz_480i     (!status[ST_CRT_240P]),
	.crt_vertical_position (status[CRT_VERTICAL_LSB +: 3]),
	.crt_horizontal_position (status[CRT_HORIZONTAL_LSB +: 3]),
	.mode_120hz         (status[ST_120HZ]),
	.aspect_ratio       (status[ASPECT_LSB +: 2]),

	.v_orient           (status[ORIENTATION_LSB +: 2]),
	.open_matte         (status[ST_OPEN_MATTE]),
	.zoom_normal        (status[ST_SCREEN_FRAMING]),
	.vertical_offset    (!status[ST_ZERO_OFFSET]),
	.beam_threshold     (status[BEAM_THRESHOLD_LSB +: 2]),

	.overlay_off        (status[ST_OVERLAY_OFF]),
	.ovl_tint           (status[TINT_LSB +: 3]),
	.ovl_bright         (status[BLEND_LSB +: 3] + 3'd1),
	.ovl_opaque_bright  (status[OPAQUE_LSB +: 3]),
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
	// EOF + VBL presents a completed redraw at vertical blank.
	.buffer_mode        (status[BUFFER_MODE_LSB +: 2]),
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
