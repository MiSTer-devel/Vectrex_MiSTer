//============================================================================
//  Generic pause handling for MiSTer cores.
//
//  https://github.com/JimmyStones/Pause_MiSTer
//
//  Copyright (c) 2021 Jim Gregory
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================
/*
 Features:
  - Pause can be triggered by user input, another module, or the OSD.
  - Video can be dimmed after sixty seconds to reduce burn-in.
  - Reset cancels a user-triggered pause.

 Version history:
 0001 - 2021-03-15 - First marked release
 0002 - 2021-08-28 - Add optional dim_video output
 0003 - 2021-09-22 - Register dim_video to ease timing
 0004 - 2021-10-07 - Register pause_cpu to ease timing
 0005 - 2026-08-31 - Extend the dim-video delay to sixty seconds
============================================================================
*/
module pause #(
	parameter RW = 8,
	parameter GW = 8,
	parameter BW = 8,
	parameter CLK_HZ = 12_000_000
)
(
	input                         clk_sys,
	input                         reset,
	input                         user_button,
	input                         pause_request,
	input                   [1:0] options,
	input                         OSD_STATUS,
	input              [RW-1:0] r,
	input              [GW-1:0] g,
	input              [BW-1:0] b,
	output reg                    pause_cpu,
`ifdef PAUSE_OUTPUT_DIM
	output reg                    dim_video,
`endif
	output [RW+GW+BW-1:0] rgb_out
);

localparam PAUSE_IN_OSD = 1'b0;
localparam DIM_VIDEO_TIMER = 1'b1;
localparam [31:0] DIM_TIMEOUT = CLK_HZ * 60;

reg        pause_toggle = 1'b0;
reg [31:0] pause_timer = 32'd0;
reg        user_button_last = 1'b0;
`ifndef PAUSE_OUTPUT_DIM
reg        dim_video = 1'b0;
`endif

always @(posedge clk_sys) begin
	user_button_last <= user_button;
	if (!user_button_last && user_button) pause_toggle <= ~pause_toggle;
	if (reset) pause_toggle <= 1'b0;

	if (reset)
		pause_cpu <= 1'b0;
	else
		pause_cpu <= pause_request | pause_toggle |
		             (OSD_STATUS & options[PAUSE_IN_OSD]);

	if (pause_cpu && options[DIM_VIDEO_TIMER]) begin
		if (pause_timer < DIM_TIMEOUT) begin
			pause_timer <= pause_timer + 1'b1;
			dim_video <= 1'b0;
		end
		else begin
			dim_video <= 1'b1;
		end
	end
	else begin
		pause_timer <= 32'd0;
		dim_video <= 1'b0;
	end
end

assign rgb_out = dim_video ? {r >> 1, g >> 1, b >> 1} : {r, g, b};

endmodule
