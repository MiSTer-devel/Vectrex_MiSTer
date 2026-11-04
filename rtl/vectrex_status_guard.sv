// Accept complete settings writes from MiSTer Main and advertise pending replies.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-3.0-or-later

`default_nettype none

module vectrex_status_guard (
	input  wire          clk_sys,
	inout  wire [35:0]   ext_bus,
	input  wire [127:0]  incoming,
	input  wire          reply_pending, reply_zero,
	output logic [127:0] stored = '0,
	output wire          commit, echo, clear_settings, capture
);

typedef enum logic [1:0] {IDLE, OTHER, WRITE_CFG, READ_REPLY} command_t;
command_t command = IDLE;

wire        select_io = ext_bus[34], strobe = ext_bus[33];
wire [15:0] data_in   = ext_bus[31:16];

logic [3:0] words = 0, reply_number = 0;
logic       have_cfg = 0, nonzero = 0,
            await_echo = 0, header = 0, offered = 0;
logic       offered_zero = 0;

wire get_header = select_io && strobe && command == IDLE && data_in == 16'h0029;

assign commit = !select_io && command == WRITE_CFG && words == 8;

// After Main reads all eight reply words, treat its next complete write as an echo.
// An all-zero write clears settings unless that reply was also all zero.
assign echo           = commit && await_echo && (nonzero || offered_zero);
assign clear_settings = commit && !nonzero && !echo;

// A status poll returns zero if no reply is ready. Otherwise the guard returns
// 0x00A0 through 0x00AF, with the reply number in bits [3:0].
// On the poll command strobe, hps_io captures the pending settings for the next eight 16-bit reads.
assign capture        = get_header && have_cfg && reply_pending;
assign ext_bus[32]    = select_io && header;
assign ext_bus[15:0]  = offered ? {8'd0, 4'ha, reply_number} : 16'd0;

always_ff @(posedge clk_sys) begin
	if (!select_io) begin
		if (commit) begin
			stored     <= incoming;
			have_cfg   <= 1;
			await_echo <= 0;
		end
		if (command == READ_REPLY) await_echo <= words == 8;
		command <= IDLE;
		header  <= 0;
	end else if (strobe) begin
		header <= get_header;
		if (command == IDLE) begin
			command <= OTHER;
			words   <= 0;
			nonzero <= 0;
			offered <= capture;
			if (data_in == 16'h001e) command <= WRITE_CFG;
			if (capture) begin
				command      <= READ_REPLY;
				offered_zero <= reply_zero;
				reply_number <= reply_number + 1'b1;
			end
		end else if ((command == WRITE_CFG || command == READ_REPLY) && words < 8) begin
			words   <= words + 1'b1;
			nonzero <= nonzero || (|data_in);
		end
	end
end
endmodule

`default_nettype wire
