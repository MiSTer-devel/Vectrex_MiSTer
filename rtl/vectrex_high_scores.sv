// Capture completed high scores and best times in work RAM and restore them at startup.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

module vectrex_high_scores (
	input  wire        clk, reset, download,
	input  wire  [2:0] score_kind,
	input  wire        cpu_read, ram_write,
	input  wire [15:0] cpu_addr,
	input  wire  [7:0] cpu_data,
	output wire        ram_wr,
	output logic [9:0] ram_addr,
	output logic [7:0] ram_data,
	input  wire        ram_ready,
	output logic       changed = 0,

	input  wire        backup_req, backup_wr,
	input  wire [11:0] backup_addr,
	input  wire  [7:0] backup_data,
	output logic       backup_ready = 0,
	output logic [7:0] backup_q
);
import vectrex_save_catalog::*;

wire bios_score = score_kind == SCORE_BIOS;
wire team       = score_kind == SCORE_TEAM;
wire race       = score_kind == SCORE_RACE;
wire bird       = score_kind == SCORE_BIRD;
wire agon       = score_kind == SCORE_AGON;
wire enabled    = score_kind != SCORE_NONE;

// Bits [7:0] hold the character at the lowest RAM address of each record.
// Unused bytes in the save sector read as 0xFF.
localparam [47:0] EMPTY_TIME = 48'h30303a302020; // "  0:00"
wire [47:0] initial_score = agon         ? EMPTY_TIME :
                            race         ? 48'hff39353a3935 : // "59:59"
                            team || bird ? 48'hffffffff3020 : 48'h302020202020;
wire [2:0] last_byte = team || bird ? 3'd1 : race ? 3'd4 : 3'd5;
wire [3:0] file_size = agon ? 4'd12 : {1'b0, last_byte} + 1'b1;

logic [47:0] retained [0:1];
logic [47:0] staging;
logic        valid = 0, running = 0, installing = 0;
logic [4:0]  install_pos = 0;
logic [2:0]  count = 0;
logic        second_mode = 0;

wire [9:0] address = cpu_addr[9:0]; // Physical address within the mirrored 1 KiB work RAM.
wire       mode2   = agon && address[3];
wire [9:0] base    = agon         ? (mode2 ? 10'h0f8 : 10'h0f0) :
                     team || bird ? 10'h3ef : 10'h3eb;
wire [9:0] offset  = address - base;
wire       watched = ram_write && offset[9:3] == 0 &&
                     offset[2:0] <= (bios_score ? 3'd6 : last_byte);
// Tour de France and Veccy Bird write their records from high address to low.
// The BIOS score is complete only after the high-bit terminator follows all six characters.
wire [2:0] first   = race || bird ? last_byte : 3'd0;
wire [2:0] next    = race || bird ? last_byte - count : count;
wire       start   = offset[2:0] == first;
wire       ordered = count != 0 && offset[2:0] == next && mode2 == second_mode;
wire       finish  = bios_score ? count == 6 && cpu_data[7] : count == last_byte;
// Veccy Bird displays a leading zero in the tens position as a space.
wire [7:0] digit   = bird && offset == 0 && cpu_data == "0" ? 8'h20 : cpu_data;
logic [47:0] candidate;
always_comb begin
	candidate = start ? 48'hffffffffffff : staging;
	if (offset < 6) candidate[offset[2:0]*8 +: 8] = digit;
end

// For BIOS-based restoration, wait for the CPU read at $F06C after score initialization.
// Vectrexagon is ready when it writes 1 to $C91A after initializing both best times.
wire restart = cpu_read && (cpu_addr == 16'hf000 || (agon && cpu_addr == 16'h0022));
wire ready   = agon ? ram_write && address == 10'h11a && cpu_data == 1
                    : cpu_read && cpu_addr == 16'hf06c;

wire [4:0] install_last = agon ? 5'd17 : race ? 5'd5 : {2'b00, last_byte};
wire [4:0] install_byte = install_pos >= 12 ? install_pos - 5'd12 :
                          install_pos >= 6  ? install_pos - 5'd6  : install_pos;
always_comb begin
	ram_addr = (team || bird ? 10'h3ef : 10'h3eb) + {5'b0, install_pos};
	if (agon) begin
		// Restore both best times, then copy mode 1's time to the display buffer.
		if (install_pos < 6)       ram_addr = 10'h0f0 + {7'b0, install_byte[2:0]};
		else if (install_pos < 12) ram_addr = 10'h0f8 + {7'b0, install_byte[2:0]};
		else                       ram_addr = 10'h0e0 + {7'b0, install_byte[2:0]};
	end
	ram_data = retained[agon && install_pos >= 6 && install_pos < 12][install_byte[2:0]*8 +: 8];
	if (race && install_pos == 5) ram_data = " ";
end
assign ram_wr = installing && !reset && !download;

wire [3:0] file_byte = backup_addr[3:0] - (backup_addr >= 6 ? 4'd6 : 4'd0);
wire       in_file   = backup_addr[11:4] == 0 && backup_addr[3:0] < file_size;
always_ff @(posedge clk) begin
	backup_ready <= backup_req && enabled && !download;
	if (backup_req) begin
		backup_q <= in_file ? retained[backup_addr >= 6][file_byte[2:0]*8 +: 8] : 8'hff;
	end
	changed <= 0;
	if (download || !enabled) begin
		valid       <= 0;
		retained[0] <= '1;
		retained[1] <= '1;
	end else if (backup_wr && backup_ready) begin
		// The save controller verifies the sector CRC before restoring these bytes.
		if (in_file)
			retained[backup_addr >= 6][file_byte[2:0]*8 +: 8] <= backup_data;
		if (&backup_addr) valid <= 1;
	end else if (!reset && running && watched && ordered && finish) begin
		if (candidate != (valid ? retained[mode2] : initial_score)) begin
			retained[mode2] <= candidate;
			if (!valid && agon) retained[!mode2] <= EMPTY_TIME;
			valid   <= 1;
			changed <= 1;
		end
	end

	if (download || !enabled || reset || restart) begin
		running    <= 0;
		installing <= 0;
		count      <= 0;
	end else if (installing) begin
		if (ram_ready) begin
			install_pos <= install_pos + 1'b1;
			if (install_pos == install_last) begin
				installing <= 0;
				running    <= 1;
			end
		end
	end else if (!running) begin
		if (ready) begin
			install_pos <= 0;
			installing  <= valid;
			running     <= !valid;
		end
	end else if (watched) begin
		if (start || ordered) begin
			staging     <= candidate;
			second_mode <= mode2;
			count       <= start ? 3'd1 : count + 1'b1;
			if (!start && (finish || (bios_score && count == 6))) count <= 0;
		end else count <= 0;
	end
end
endmodule

`default_nettype wire
