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
	inout  [45:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output  [7:0] VIDEO_ARX,
	output  [7:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output  [1:0] VGA_SL,

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

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S, // 1 - signed audio samples, 0 - unsigned
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

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;

assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

assign VIDEO_ARX = status[1] ? 8'd16 : 8'd3;
assign VIDEO_ARY = status[1] ? 8'd9  : 8'd4; 

`include "build_id.v" 
localparam CONF_STR = {
	"VECTREX;;",
	"-;",
	"F1,VECBINROM;",
	"F2,OVR;",
	"OB,Skip logo,No,Yes;",
	"-;",
	"O1,Aspect ratio,4:3,16:9;",
	"O9,Frame,No,Yes;",
	"O4,Resolution,High,Low;",
	"O23,Phosphor persistance,1,2,3,4;",
	"O56,Pseudocolor,Off,1,2,3;",
	"O8,Overburn,No,Yes;",
	"OC,Port 2,Joystick,Speech;",
	"-;",
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
wire  [1:0] buttons;
wire [15:0] sdram_sz;


wire [15:0] joystick_0, joystick_1;
wire [15:0] joya_0, joya_1;
wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;


hps_io #(.STRLEN($size(CONF_STR)>>3)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.conf_str(CONF_STR),

	.buttons(buttons),
	.status(status),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(0),

   .sdram_sz(sdram_sz),


	.joystick_analog_0(joya_0),
	.joystick_analog_1(joya_1),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1)
);

wire [9:0] audio;
assign AUDIO_L = {audio, 6'd0};
assign AUDIO_R = {audio, 6'd0};
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

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
assign VGA_SL = 0;
assign VGA_F1 = 0;

assign VGA_HS = hblank;
assign VGA_VS = vblank;
assign VGA_DE = ~(hblank | vblank);

reg ce_pix;
always @(posedge clk_48) begin
       ce_pix <= !ce_pix;
end



reg [14:0] addr_mask;
always @(posedge clk_sys) begin
	reg old_download;
	
	old_download <= ioctl_download;
	if(~old_download & ioctl_download) addr_mask <= 0;
	if(ioctl_download && ioctl_wr && (ioctl_addr[14:0] & ~addr_mask)) addr_mask <= ((addr_mask<<1)|15'd1);
end

wire [4:0] pers[4]   = '{8,4,2,1};
wire [9:0] width[2]  = '{540, 332};
wire [9:0] height[2] = '{720, 410};

wire frame_line;
wire [7:0] r,g,b;

assign VGA_R = status[9] & frame_line ? 8'h40 : new_r;
assign VGA_G = status[9] & frame_line ? 8'h00 : new_g;
assign VGA_B = status[9] & frame_line ? 8'h00 : new_b;
//assign VGA_R = bg_r;
wire fg = |{r,g,b};

wire [7:0] new_r = (fg && !bg_a) ? r : {bg_r,bg_r};
wire [7:0] new_g = (fg && !bg_a) ? g : {bg_g,bg_g};
wire [7:0] new_b = (fg && !bg_a) ? b : {bg_b,bg_b};

wire rom_download = (ioctl_index==8'd1);

vectrex vectrex
(
	.reset(reset),
	.clock(clk_sys),
	.cpu(status[10]),

	.cart_data(ioctl_dout),
	.cart_addr(ioctl_addr),
	.cart_mask(addr_mask),
	.cart_wr(ioctl_wr & ioctl_download ),
	
	.video_r(r),
	.video_g(g),
	.video_b(b),

	.video_hblank(hblank),
	.video_vblank(vblank),

	.video_width(width[status[4]]),
	.video_height(height[status[4]]),

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


wire bg_download = ioctl_download && (ioctl_index == 2);

reg [7:0] ioctl_dout_r;
always @(posedge clk_sys) if(ioctl_wr & ~ioctl_addr[0]) ioctl_dout_r <= ioctl_dout;

wire [15:0] pic_data;
wire ram_ready;
sdram sdram
(
        .*,

        .init(~pll_locked),
        .clk(clk_mem),
        .addr(bg_download ? ioctl_addr[24:0] : pic_addr),
        .dout(pic_data),
        .din(ioctl_dout),
        .we(bg_download ? ioctl_wr : 1'b0),
        .rd(pic_req),
	.ready(ram_ready)
);


wire VSync = VGA_VS;
reg        pic_req;
reg [24:0] pic_addr;
reg  [3:0] bg_r,bg_g,bg_b,bg_a;
always @(posedge clk_48) begin
	reg old_vs;
	reg use_bg = 0;
	
	if(bg_download && sdram_sz[2:0]) use_bg <= 1;

	pic_req <= 0;

	if(use_bg) begin
		if(ce_pix) begin
			old_vs <= VSync;
			{bg_a,bg_b,bg_g,bg_r} <= pic_data;
			if(~(hblank|vblank)) begin
			if (status[4]) begin
				pic_addr <= pic_addr + 2'd4;
			end else begin
					pic_addr <= pic_addr + 2'd2;
			end
				pic_req <= 1;
			end
			
			if(~old_vs & VSync) begin
				pic_addr <= 0;
				pic_req <= 1;
			end
		end
	end
	else begin
		{bg_a,bg_b,bg_g,bg_r} <= 0;
	end
end

endmodule
