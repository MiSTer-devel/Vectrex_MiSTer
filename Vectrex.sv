//============================================================================
//  Vectrex
//
//  Port to MiSTer
//  Copyright (C) 2017-2019 Sorgelig
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
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM (USE_FB=1 in qsf)
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign HDMI_FREEZE = 0;

assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

assign LED_USER  = ioctl_download;

wire [1:0] ar = status[17:16];
video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),

	.ARX((!ar) ? 12'd9  : (ar - 1'd1)),
	.ARY((!ar) ? 12'd11 : 12'd0),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[19:18])
);

// Status Bit Map:
//              Upper                          Lower
// 0         1         2         3          4         5         6
// 01234567890123456789012345678901 23456789012345678901234567890123
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// X XX XXXXXXXXXXXXXXX

`include "build_id.v" 
localparam CONF_STR = {
	"VECTREX;;",
	"-;",
	"f1,OVR;",
	"F1,VECBINROM;",
	"F2,OVR,Load Overlay;",
	"OB,Skip logo,No,Yes;",
	"-;",
	"OGH,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"OIJ,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O9,Frame,No,Yes;",
	//"O4,Resolution,High,Low;", // AJS - remove this because it ruins the
	//overlay
	"O23,Phosphor persistance,1,2,3,4;",
	"O56,Pseudocolor,Off,1,2,3;",
	"O8,Overburn,No,Yes;",
	"-;",
	// overlay alpha is useful for debugging
	"OD,Overlay Alpha,On,Off;",
	// blend the vector with the overlay
	"OE,Color Vector,Overlay On,White always;",
	//  tint the vector towards white
	"OF,Tint Vector White,On,Off;",
	"-;",
	"OC,Port 2,Joystick,Speech;",
	"OA,CPU Model,1,2;",
	"-;",
	"R7,Reset;",
	"J1,Button 1,Button 2,Button 3,Button 4;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;
wire clk_mem;
wire clk_48;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_mem),
	.outclk_2(clk_48),
	.locked(pll_locked)
);

///////////////////////////////////////////////////

wire [31:0] status;
wire [ 1:0] buttons;
wire [15:0] sdram_sz;

wire [15:0] joystick_0, joystick_1;
wire [15:0] joya_0, joya_1;
wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire [ 7:0] ioctl_dout;
wire [15:0] ioctl_index;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(0),

	.sdram_sz(sdram_sz),

	.joystick_l_analog_0(joya_0),
	.joystick_l_analog_1(joya_1),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1)
);

wire [9:0] audio;
assign AUDIO_L = {audio, 6'd0};
assign AUDIO_R = {audio, 6'd0};
assign AUDIO_S = 1;

wire reset = (RESET | status[0] | status[7] | buttons[1] | ioctl_download | second_reset);

reg second_reset = 0;
always @(posedge clk_sys) begin
	integer timeout = 0;

	if(ioctl_download && status[11]) timeout <= 5000000;
	else begin
		if(!timeout) second_reset <= 0;
		else begin
			timeout <= timeout - 1;
			if(timeout < 1000) second_reset <= 1;
		end
	end
end


wire hblank, vblank;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = 1;


assign VGA_HS = hblank;
assign VGA_VS = vblank;
assign VGA_DE = ~(hblank | vblank);

reg ce_pix;
always @(posedge clk_48) ce_pix <= !ce_pix;

wire [4:0] pers[4]   = '{8,4,2,1};
wire [9:0] width[2]  = '{540, 332};
wire [9:0] height[2] = '{720, 410};

wire frame_line;
wire [7:0] r, g, b;

assign VGA_R = status[9] & frame_line ? 8'h40 : new_r;
assign VGA_G = status[9] & frame_line ? 8'h00 : new_g;
assign VGA_B = status[9] & frame_line ? 8'h00 : new_b;
//assign VGA_R = bg_r;
wire fg = |{r, g, b};
wire bg = |{bg_r, bg_g, bg_b};

//
// if fg is non zero, then the beam is at this pixel
//    make the color either:
//       -- the background color (no alpha) if pixel is dark
//       -- the background color tinted towards white if the beam is bright
// if fg is zero, we use the background after an alpha * black has been applied

wire [7:0] new_r = fg  ? bbrw : ~status[13] ? bga_r : {bg_r,bg_r};
wire [7:0] new_g = fg  ? bbgw : ~status[13] ? bga_g : {bg_g,bg_g};
wire [7:0] new_b = fg  ? bbbw : ~status[13] ? bga_b : {bg_b,bg_b};

wire [7:0] bbrw = ~status[15] ? blend_r_w : blend_r;
wire [7:0] bbgw = ~status[15] ? blend_g_w : blend_g;
wire [7:0] bbbw = ~status[15] ? blend_b_w : blend_b;


// tint it towards white when it is brighter, otherwise use the background
// color (no alpha)
// r + (255-r)*tint
// to simplify we want tint ~ 3/4 =  ( 1/4 + 1/2 )
wire [7:0] blend_r_w = r > 108 ? (blend_r + ((8'd255-blend_r)>>1) + ((8'd255-blend_r)>>2) ) : blend_r;
wire [7:0] blend_g_w = r > 108 ? (blend_g + ((8'd255-blend_g)>>1) + ((8'd255-blend_g)>>2) ) : blend_g;
wire [7:0] blend_b_w = r > 108 ? (blend_b + ((8'd255-blend_b)>>1) + ((8'd255-blend_b)>>2) ) : blend_b;


wire [7:0] blend_r = ~status[14] ? bg ? { bg_r << 2 | bg_r[0] , bg_r << 2 | bg_r[0]} : r : r;
wire [7:0] blend_g = ~status[14] ? bg ? { bg_g << 2 | bg_g[0] , bg_g << 2 | bg_g[0]} : g : g;
wire [7:0] blend_b = ~status[14] ? bg ? { bg_b << 2 | bg_b[0] , bg_b << 2 | bg_b[0]} : b : b;


wire rom_download = ioctl_download &&  (ioctl_index[4:0] <= 1) && (ioctl_index[9:8] == 0);
wire bg_download  = ioctl_download && ((ioctl_index[4:0] == 2) || (ioctl_index[9:8] == 1));

reg [14:0] addr_mask;
always @(posedge clk_sys) begin
	reg old_download;
	
	old_download <= rom_download;
	if(~old_download & rom_download) addr_mask <= 0;
	if(rom_download && ioctl_wr && (ioctl_addr[14:0] & ~addr_mask)) addr_mask <= ((addr_mask<<1)|15'd1);
end

vectrex vectrex
(
	.reset(reset),
	.clock(clk_sys),
	.cpu(status[10]),

	.cart_data(ioctl_dout),
	.cart_addr(ioctl_addr),
	.cart_mask(addr_mask),
	.cart_wr(ioctl_wr & ioctl_download & rom_download ),
	
	.video_r(r),
	.video_g(g),
	.video_b(b),

	.video_hblank(hblank),
	.video_vblank(vblank),

	.video_width(width[0]), //status[4]]),
	.video_height(height[0]), //status[4]]),

	.color(status[6:5]),
	.pers(pers[status[3:2]]),
	.overburn(status[8]),
	.frame_line(frame_line),

	.speech_mode(status[12]),
	.audio_out(audio),

	.up_1(joystick_0[4]),
	.dn_1(joystick_0[5]),
	.lf_1(joystick_0[6]),
	.rt_1(joystick_0[7]),
	.pot_x_1(joya_0[7:0]  ? joya_0[7:0]   : {joystick_0[1], {7{joystick_0[0]}}}),
	.pot_y_1(joya_0[15:8] ? ~joya_0[15:8] : {joystick_0[2], {7{joystick_0[3]}}}),

	.up_2(joystick_1[4]),
	.dn_2(joystick_1[5]),
	.lf_2(joystick_1[6]),
	.rt_2(joystick_1[7]),
	.pot_x_2(joya_1[7:0]  ? joya_1[7:0]   : {joystick_1[1], {7{joystick_1[0]}}}),
	.pot_y_2(joya_1[15:8] ? ~joya_1[15:8] : {joystick_1[2], {7{joystick_1[3]}}})
);

//
// Load 16bit color data from the ioctl as a file load
//
// the format is RBGA with each channel taking 4 bits
//

reg [7:0] ioctl_dout_r;
always @(posedge clk_sys) if(ioctl_wr & ~ioctl_addr[0]) ioctl_dout_r <= ioctl_dout;

wire [31:0] sd_data;
wire ram_ready;
sdram sdram
(
	.*,
	
	.init(~pll_locked),
	.clk(clk_mem),
	.ch1_addr(bg_download ? ioctl_addr[24:1] : {pic_addr[24:2],1'b0}),
	.ch1_dout(sd_data),
	.ch1_din({ioctl_dout, ioctl_dout_r}),
	.ch1_req(bg_download ? (ioctl_wr & ioctl_addr[0]) : pic_req),
	.ch1_rnw(~bg_download)
);

//
// Alpha Blend is a table lookup to mix the color with black
//
// we can't hardcode it, because when the light comes through
// the overlay we need the original color
//
wire [7:0] bga_r, bga_g, bga_b;
alphablend alphablend(
	.clk(clk_48),
	.bg_a(bg_a),
	.bg_r(bg_r),
	.bg_g(bg_g),
	.bg_b(bg_b),
	.bga_r(bga_r),
	.bga_g(bga_g),
	.bga_b(bga_b)
);

wire VSync = VGA_VS;
reg [15:0] pic_data[2];
reg        pic_req;
reg [24:1] pic_addr;
reg [ 3:0] bg_r, bg_g, bg_b, bg_a;
always @(posedge clk_48) begin
	reg old_vs;
	reg use_bg = 0;
	reg [1:0] cnt;
	
	if(rom_download) use_bg <= 0;
	if(bg_download && sdram_sz[2:0]) use_bg <= 1;

	pic_req <= 0;

	if(use_bg & ~bg_download) begin
		if(ce_pix) begin
			
			cnt <= cnt >> 1;
			if(cnt[0]) {pic_data[1],pic_data[0]} <= sd_data;
			
			old_vs <= VSync;
			if(~(hblank|vblank)) begin
				{bg_a, bg_b, bg_g, bg_r} <= pic_data[~pic_addr[1]];
				pic_addr <= pic_addr + 2'd1;
				if(pic_addr[1]) begin
					pic_req <= 1;
					cnt <= 2;
				end
			end
			
			if(~old_vs & VSync) begin
				pic_addr <= 0;
				pic_req <= 1;
				cnt <= 2;
			end
		end
	end
	else begin
		{bg_a, bg_b, bg_g, bg_r} <= 0;
	end
end

endmodule
