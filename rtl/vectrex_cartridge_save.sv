//============================================================================
// Saves and restores cartridge flash, EEPROM or game scores in MiSTer's per-ROM .sav file.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The 512-byte header stores ROM and sector CRC32 checksums.
// A flag for each sector indicates whether that sector has been saved.
// Each save copies one dirty 4 KiB sector at a time. Changes during a save mark it dirty again.
// EEPROM and RAM scores each use one data sector. Unused bytes read as 0xFF.
// Console reset leaves cartridge contents and pending saves intact.
//============================================================================
`default_nettype none

module vectrex_cartridge_save #(
	parameter integer QUIET_CLOCKS   =  24_000_000,
	parameter integer TIMEOUT_CLOCKS = 240_000_000
)(
	input  wire         clk,
	input  wire         download,
	input  wire         download_wr,
	input  wire  [7:0]  download_data,
	input  wire         flash_enabled,
	output logic [2:0]  eeprom_kind = 0,
	output logic [2:0]  score_kind = 0,
	input  wire         cart_busy,
	input  wire         cart_changed,
	input  wire  [5:0]  cart_sector,
	output logic [17:0] cart_addr,
	output logic [7:0]  cart_data,
	output logic        cart_wr,
	output wire         cart_req,
	input  wire         cart_ready,
	input  wire  [7:0]  cart_q,
	input  wire         autosave,
	input  wire         save_request,
	output logic        hold_reset = 0,
	output wire         pending,
	output wire         available,
	output logic        error = 0,
	input  wire         img_mounted,
	input  wire         img_readonly,
	input  wire  [63:0] img_size,
	output logic [31:0] sd_lba = 0,
	output logic        sd_rd = 0,
	output logic        sd_wr = 0,
	input  wire         sd_ack,
	input  wire  [13:0] sd_buff_addr,
	input  wire  [7:0]  sd_buff_dout,
	input  wire         sd_buff_wr,
	output logic [7:0]  sd_buff_din
);
import vectrex_save_catalog::*;
localparam integer SECTORS      = 48;
localparam integer ID_COUNT     = EEPROM_COUNT;
localparam integer QUIET_BITS   = $clog2(QUIET_CLOCKS+1);
localparam integer TIMEOUT_BITS = $clog2(TIMEOUT_CLOCKS+1);

typedef enum logic [4:0] {
	IDLE, BOOT, READY, LOAD_NEXT, HEADER_CHECK, CRC_START, CRC_WAIT,
	CRC_BYTE, RESTORE_START, RESTORE_WAIT, RESTORE_BYTE,
	CAPTURE_START, CAPTURE_WAIT, CAPTURE_BYTE, IO_REQUEST, IO_TRANSFER,
	READ_DONE, WRITE_DONE, STOPPED, WRITE_START, SCORE_LOOKUP
} state_t;
state_t                  state = IDLE;
logic                    download_q = 0, save_q = 0, mounted = 0, readonly_q = 0;
logic                    manual_pending = 0, writing = 0, header_io = 0, extending = 0;
logic [63:0]             size_q = 0;
logic [47:0]             dirty = 0, saved = 0, saved_inverse = 0;
logic [31:0]             sector_crc [0:SECTORS-1];
logic [31:0]             rom_crc = 32'hffffffff, crc = 32'hffffffff;
logic [24:0]             rom_size = 0;
logic [ID_COUNT-1:0]     id_match = 0;
logic                    pilot_i2c = 0;
wire  [ID_COUNT-1:0]     id_valid;
wire  [ID_COUNT-1:0]     id_active, id_start, id_char_match;
wire  [2:0]              id_kind [0:ID_COUNT-1];
logic [2:0]              detected_kind;
wire  [24:0]             byte_addr    = download_q ? rom_size : 25'd0;
wire                     unique_id    = (id_valid != 0) && ((id_valid & (id_valid - 1'b1)) == 0);
logic [31:0]             snapshot_crc = 0;
logic [5:0]              sector = 0, first_dirty;
logic [2:0]              block    = 0;
logic [11:0]             cursor   = 0;
logic [9:0]              received = 0;
logic                    bad_transfer = 0, last_sent = 0, bad_header = 0;
logic [QUIET_BITS-1:0]   quiet   = 0;
logic [TIMEOUT_BITS-1:0] timeout = 0;
(* ramstyle = "M10K, no_rw_check" *) logic [7:0] buffer_data [0:4095];
logic [7:0]  buffer_q;
logic [11:0] buffer_addr;
wire  [31:0] sector_lba   = 32'd1 + (32'(sector) << 3);
wire         score_save    = score_kind != SCORE_NONE;
wire         single_sector = score_save || eeprom_kind != 0;
wire  [5:0]  sector_count  = single_sector ? 6'd1 : 6'(SECTORS);
wire  [63:0] header_tag    = score_save ? "VXSCOR01" : eeprom_kind != 0 ? "VXEEP001" : "VXFLASH1";
localparam integer SCORE_ROW_BITS = SCORE_COUNT > 1 ? $clog2(SCORE_COUNT) : 1;
logic [SCORE_ROW_BITS-1:0] score_row = 0;
wire  [50:0] score_table [0:SCORE_COUNT-1];
wire  [50:0] score_entry   = score_table[score_row];

function automatic integer title_length(input logic [255:0] title);
	begin
		title_length = 0;
		for (integer b = 0; b < 32; b = b + 1)
			if (title[b*8 +: 8] != 0) title_length = title_length + 1;
	end
endfunction

genvar id_index, row;
generate
	for (row = 0; row < SCORE_COUNT; row = row + 1) begin : score_id
		assign score_table[row] = SCORE_ROMS[row*51 +: 51];
	end

	for (id_index = 0; id_index < ID_COUNT; id_index = id_index + 1) begin : cartridge_id
		localparam integer i = id_index;
		localparam logic [294:0] ROW      = EEPROM_ROMS[i*295 +: 295];
		localparam logic [15:0]  OFFSET   = ROW[291:276];
		localparam logic [16:0]  CAPACITY = ROW[275:259];
		localparam logic [255:0] TITLE    = ROW[255:0];
		localparam integer       LENGTH   = title_length(TITLE);

		wire [4:0] pos      = byte_addr[4:0] - OFFSET[4:0];
		wire       in_title = byte_addr >= 25'(OFFSET) && byte_addr < 25'(OFFSET) + 25'(LENGTH);
		assign id_active[i]     = in_title;
		assign id_start[i]      = pos == 0;
		assign id_char_match[i] = download_data[6:0] == TITLE[(LENGTH-1-int'(pos))*8 +: 7];
		assign id_kind[i]       = pilot_i2c && ROW[294:292] != EE_NONE ? ROW[294:292] : ROW[258:256];

		// Accept images larger than half the listed capacity, up to and including the full capacity.
		assign id_valid[i] = id_match[i] && rom_size > (25'(CAPACITY) >> 1) &&
		                     rom_size <= 25'(CAPACITY) && rom_size >= 25'(OFFSET) + 25'(LENGTH);
	end
endgenerate

wire [2:0] pilot_sig_pos    = byte_addr[2:0] - PILOT_I2C_OFFSET[2:0];
wire       pilot_sig_active = byte_addr >= 25'(PILOT_I2C_OFFSET) &&
                              byte_addr < 25'(PILOT_I2C_OFFSET) + 25'd8;

always_ff @(posedge clk) begin
	if (download && !download_q) begin
		id_match  <= 0;
		pilot_i2c <= 0;
	end
	if (download && download_wr) begin
		for (integer i = 0; i < ID_COUNT; i = i + 1)
			if (id_active[i]) id_match[i] <= (id_start[i] || id_match[i]) && id_char_match[i];
		if (pilot_sig_active)
			pilot_i2c <= (pilot_sig_pos == 0 || pilot_i2c) &&
			             download_data == PILOT_I2C_CODE[(7-int'(pilot_sig_pos))*8 +: 8];
	end
end

always_comb begin
	detected_kind = 0;
	for (integer i = 0; i < ID_COUNT; i = i + 1)
		if (id_valid[i]) detected_kind = id_kind[i];
end

function automatic [31:0] crc_byte(input logic [31:0] value, input logic [7:0] data);
	logic [31:0] c;
	begin
		c = value ^ {24'd0, data};
		for (integer b = 0; b < 8; b = b + 1)
			c = (c >> 1) ^ (c[0] ? 32'hedb88320 : 32'd0);
		crc_byte = c;
	end
endfunction

function automatic [7:0] header_byte(input logic [8:0] addr, input logic [63:0] tag);
	begin
		case (addr)
			0,1,2,3,4,5,6,7: header_byte = tag[63-addr[2:0]*8 -: 8];
			28:              header_byte = {5'd0, score_save ? score_kind : eeprom_kind};
			default: begin
				if (addr < 12) header_byte = 8'((~rom_crc) >> ((addr-8)*8));
				else if (addr < 16) header_byte = 8'(rom_crc >> ((addr-12)*8));
				else if (addr < 22) header_byte = 8'(saved >> ((addr-16)*8));
				else if (addr < 28) header_byte = 8'((~saved) >> ((addr-22)*8));
				else if (addr >= 32 && addr < 224)
					header_byte = saved[(addr-32)>>2] ?
					              8'(sector_crc[(addr-32)>>2] >> (addr[1:0]*8)) :
					              8'd0;
				else header_byte = 0;
			end
		endcase
	end
endfunction

assign available   = (flash_enabled || single_sector) && mounted;
assign pending     = (|dirty) || writing || state == CAPTURE_START || state == CAPTURE_WAIT ||
                     state == CAPTURE_BYTE;
assign cart_addr   = sector < 6'(SECTORS) ? {sector, cursor} : 18'd0;
assign cart_data   = buffer_q;
assign cart_wr     = state == RESTORE_BYTE && !download;
assign cart_req    = !download && (state == CAPTURE_START || state == CAPTURE_WAIT || cart_wr);
assign buffer_addr = writing && !header_io ? {block, sd_buff_addr[8:0]} : cursor;

always_comb begin
	first_dirty = 0;
	for (integer i = SECTORS-1; i >= 0; i = i - 1)
		if (dirty[i]) first_dirty = 6'(i);
end

// Read the sector buffer synchronously and register the data sent to HPS.
always_ff @(posedge clk) begin
	buffer_q    <= buffer_data[buffer_addr];
	sd_buff_din <= header_io ? header_byte(sd_buff_addr[8:0], header_tag) : extending ? 8'hff : buffer_q;
	if (!download) begin
		if (!writing && !header_io && sd_ack && sd_buff_wr && (state == IO_REQUEST || state == IO_TRANSFER))
			buffer_data[{block, sd_buff_addr[8:0]}] <= sd_buff_dout;
		else if (state == CAPTURE_BYTE && !cart_busy && !cart_changed)
			buffer_data[cursor] <= cart_q;
	end
end

always_ff @(posedge clk) begin
	download_q <= download;
	save_q     <= save_request;
	if (quiet != QUIET_BITS'(QUIET_CLOCKS)) quiet <= quiet + 1'b1;
	if (cart_busy || cart_changed)          quiet <= 0;
	if (save_request && !save_q) begin
		manual_pending <= 1;
		if (state == READY) error <= 0;
	end

	if (download && !download_q) begin
		state          <= IDLE;
		hold_reset     <= 1;
		dirty          <= 0;
		saved          <= 0;
		mounted        <= 0;
		manual_pending <= 0;
		writing        <= 0;
		extending      <= 0;
		error          <= 0;
		timeout        <= 0;
		rom_crc        <= download_wr ? crc_byte(32'hffffffff, download_data) : 32'hffffffff;
		rom_size       <= download_wr ? 25'd1 : 25'd0;
		eeprom_kind    <= 0;
		score_kind     <= SCORE_NONE;
		score_row      <= 0;
	end else if (download) begin
		if (download_wr) begin
			rom_crc  <= crc_byte(rom_crc, download_data);
			rom_size <= rom_size + 1'b1;
		end
	end else begin
		// Flash takes priority. Select an EEPROM only on a unique match.
		// Other ROMs under 64 KiB can match the score catalog if a save image is mounted.
		if (download_q && !flash_enabled && unique_id) eeprom_kind <= detected_kind;
		case (state)
			IDLE:          if (download_q)
				state <= !flash_enabled && !unique_id && mounted && rom_size[24:16] == 0 ?
				         SCORE_LOOKUP : BOOT;
			SCORE_LOOKUP:  begin
				if ({rom_size[15:0], ~rom_crc} == score_entry[50:3]) begin
					score_kind <= score_entry[2:0];
					state      <= BOOT;
				end else if (score_row == SCORE_ROW_BITS'(SCORE_COUNT-1)) state <= BOOT;
				else score_row <= score_row + 1'b1;
			end
			BOOT:          if (!cart_busy) begin
				// On a cartridge menu load, Main mounts the save image before ending the ROM download.
				if (available && size_q >= 512) begin
					header_io  <= 1;
					writing    <= 0;
					bad_header <= 0;
					sd_lba     <= 0;
					state      <= IO_REQUEST;
				end else begin
					if (available && size_q != 0) error <= 1;
					hold_reset <= 0;
					state      <= score_save && size_q != 0 ? STOPPED : READY;
				end
			end
			READY:         begin
				hold_reset <= 0;
				if (!(|dirty) && !cart_changed) manual_pending <= 0;
				if (available && (|dirty) && !cart_busy && !cart_changed &&
				    (manual_pending || (autosave && !error && quiet == QUIET_BITS'(QUIET_CLOCKS)))) begin
					if (readonly_q) begin
						error          <= 1;
						manual_pending <= 0;
					end else begin
						sector             <= first_dirty;
						dirty[first_dirty] <=            0;
						cursor             <=            0;
						crc                <= 32'hffffffff;
						state              <= CAPTURE_START;
					end
				end
			end
			HEADER_CHECK:  begin
				if (bad_header || (saved ^ saved_inverse) != 48'hffffffffffff ||
				    (single_sector && |saved[47:1])) begin
					saved      <= 0;
					error      <= 1;
					hold_reset <= 0;
					// A bad score header disables further score-file writes until the next cartridge load.
					state      <= score_save ? STOPPED : READY;
				end else begin
					sector <= 0;
					state  <= LOAD_NEXT;
				end
			end
			LOAD_NEXT:     begin
				if (sector == sector_count) state <= READY;
				else if (!saved[sector]) sector <= sector + 1'b1;
				else if (size_q < (64'd512 + ((64'(sector)+1) << 12))) begin
					saved[sector] <= 0;
					error         <= 1;
					sector        <= sector + 1'b1;
				end else begin
					block     <= 0;
					header_io <= 0;
					sd_lba    <= sector_lba;
					state     <= IO_REQUEST;
				end
			end
			CAPTURE_START: state                 <= CAPTURE_WAIT;
			CAPTURE_WAIT:  if (cart_ready) state <= CAPTURE_BYTE;
			CAPTURE_BYTE:  begin
				crc <= crc_byte(crc, cart_q);
				if (&cursor) begin
					snapshot_crc <= ~crc_byte(crc, cart_q);
					writing      <= 1;
					block        <= 0;
					state        <= WRITE_START;
				end else begin cursor <= cursor + 1'b1; state <= CAPTURE_START; end
			end
			WRITE_START:   begin
				// MiSTer Main creates save files at block 0 and grows them by
				// appending data. Fill missing data blocks with 0xFF before writing
				// the selected cartridge sector.
				extending <= size_q < (64'(sector_lba) << 9);
				header_io <= size_q < 512;
				sd_lba    <= size_q < (64'(sector_lba) << 9) ? size_q[40:9] : sector_lba;
				state     <= IO_REQUEST;
			end
			IO_REQUEST:    begin
				if (!sd_ack && !sd_rd && !sd_wr) begin
					sd_rd        <= !writing;
					sd_wr        <= writing;
					received     <= 0;
					bad_transfer <= 0;
					last_sent    <= 0;
					timeout      <= 0;
				end else if (sd_ack) begin
					sd_rd <= 0;
					sd_wr <= 0;
					state <= IO_TRANSFER;
				end
			end
			IO_TRANSFER:   if (!sd_ack) begin
				if (bad_transfer || (writing ? !last_sent : received != 512)) begin
					error <= 1;
					if (writing) dirty[sector] <= 1;
					writing        <= 0;
					manual_pending <= 0;
					hold_reset     <= 0;
					state          <= STOPPED;
				end else state <= writing ? WRITE_DONE : READ_DONE;
			end
			READ_DONE:     begin
				if (header_io) state <= HEADER_CHECK;
				else if (&block) begin
					cursor <=            0;
					crc    <= 32'hffffffff;
					state  <= CRC_START;
				end else begin
					block  <= block + 1'b1;
					sd_lba <= sd_lba + 1'b1;
					state  <= IO_REQUEST;
				end
			end
			CRC_START:     state <= CRC_WAIT;
			CRC_WAIT:      state <= CRC_BYTE;
			CRC_BYTE:      begin
				crc <= crc_byte(crc, buffer_q);
				if (&cursor) begin
					cursor <= 0;
					if (~crc_byte(crc, buffer_q) == sector_crc[sector]) state <= RESTORE_START;
					else begin
						error         <= 1;
						saved[sector] <= 0;
						sector        <= sector + 1'b1;
						state         <= LOAD_NEXT;
					end
				end else begin cursor <= cursor + 1'b1; state <= CRC_START; end
			end
			RESTORE_START: state <= RESTORE_WAIT;
			RESTORE_WAIT:  state <= RESTORE_BYTE;
			RESTORE_BYTE:  begin
				if (cart_ready) begin
					if (&cursor) begin
						sector <= sector + 1'b1;
						state  <= LOAD_NEXT;
					end else begin
						cursor <= cursor + 1'b1;
						state  <= RESTORE_START;
					end
				end
			end
			WRITE_DONE:    begin
				if (size_q < ((64'(sd_lba) + 1) << 9)) size_q <= (64'(sd_lba) + 1) << 9;
				if (extending) state <= WRITE_START;
				else if (header_io) begin
					writing <= 0;
					state   <= READY;
				end else if (&block) begin
					saved[sector]      <= 1;
					sector_crc[sector] <= snapshot_crc;
					sd_lba             <= 0;
					header_io          <= 1;
					state              <= IO_REQUEST;
				end else begin
					block  <= block + 1'b1;
					sd_lba <= sd_lba + 1'b1;
					state  <= IO_REQUEST;
				end
			end
			default:       ;
		endcase

		if ((state == CAPTURE_START || state == CAPTURE_WAIT || state == CAPTURE_BYTE) &&
			(cart_busy || cart_changed)) begin
			dirty[sector] <= 1;
			writing       <= 0;
			state         <= READY;
		end
		if (cart_changed && cart_sector < sector_count && !(score_save && state == STOPPED))
			dirty[cart_sector] <= 1;

		if (state == IO_REQUEST || state == IO_TRANSFER) begin
			// During a save, address 512 confirms that hps_io has read all 512 bytes.
			if (sd_ack && sd_buff_addr == 512) last_sent <= 1;
			if (!writing && sd_ack && sd_buff_wr) begin
				if (received >= 512 || sd_buff_addr != {4'd0, received}) bad_transfer <= 1;
				else received <= received + 1'b1;
				if (header_io) begin
					if ((sd_buff_addr < 16 || sd_buff_addr == 28) &&
					    sd_buff_dout != header_byte(sd_buff_addr[8:0], header_tag))
						bad_header <= 1;
					if (sd_buff_addr >= 16 && sd_buff_addr < 22)
						saved[(sd_buff_addr-16)*8 +: 8] <= sd_buff_dout;
					if (sd_buff_addr >= 22 && sd_buff_addr < 28)
						saved_inverse[(sd_buff_addr-22)*8 +: 8] <= sd_buff_dout;
					if (sd_buff_addr >= 32 && sd_buff_addr < 224)
						sector_crc[(sd_buff_addr-32)>>2][sd_buff_addr[1:0]*8 +: 8] <= sd_buff_dout;
				end
			end
			if (timeout != TIMEOUT_BITS'(TIMEOUT_CLOCKS)) begin
				if (sd_rd || sd_wr || state == IO_TRANSFER) timeout <= timeout + 1'b1;
			end
			else begin
				// SD replies have no request ID. Stop transfers after a timeout to
				// avoid treating a late reply as the response to a new request.
				sd_rd <= 0;
				sd_wr <= 0;
				if (writing) dirty[sector] <= 1;
				writing    <= 0;
				hold_reset <= 0;
				error      <= 1;
				state      <= STOPPED;
			end
		end
	end

	if (download) begin sd_rd <= 0; sd_wr <= 0; end
	if (img_mounted) begin
		mounted    <= 1;
		readonly_q <= img_readonly;
		size_q     <= img_size;
	end
end
endmodule

`default_nettype wire
