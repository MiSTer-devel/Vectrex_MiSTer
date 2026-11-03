// Standard-speed 1-Wire save commands used by DS2430A and DS2431 cartridges on PB6.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

module vectrex_1wire (
	input  wire        clk,
	input  wire        clear,
	input  wire        reset,
	input  wire        ds2431,

	input  wire        host_low,
	output wire        pull_low,
	input  wire        busy,

	output logic       page_clear  = 0,
	output logic       page_load   = 0,
	output logic       page_wr     = 0,
	output logic       page_commit = 0,

	output wire  [7:0] addr,
	output logic [7:0] data        = 0,
	input  wire  [7:0] scratch_q,
	output logic       rd          = 0,
	input  wire  [7:0] q,
	input  wire        ready
);
typedef enum logic [4:0] {
	ROM_COMMAND, MEM_COMMAND, ADDRESS_LO, ADDRESS_HI, WRITE_SP,
	WAIT_MEMORY, READ_MEMORY, READ_TA1, READ_TA2, READ_STATUS, READ_SP,
	COPY_TA1, COPY_TA2, COPY_STATUS, COPY_KEY, CRC_LO, CRC_HI, FINISHED, READ_ROM
} state_t;
// Fixed DS2431 ROM ID: family 2D, six zero serial bytes, CRC-8 D7; low byte first.
localparam logic [63:0] DS2431_ROM = 64'hd70000000000002d;
state_t      state = ROM_COMMAND;
logic [7:0]  command = 0, ptr = 0, wr_addr = 0, memory_q = 0;
logic [15:0] target = 0, crc = 0;
logic [2:0]  sp_end = 0;
logic        sp_valid = 0, copied = 0, copy_match = 0;
wire  [7:0]  sp_status = {copied, 1'b0, !sp_valid, 2'b00, sp_end};

// At 24 MHz: reset >= 480 us, presence after 30 us for 120 us.
// Accept bits on master release; a reset pulse cannot complete a partial byte.
logic        host_q = 0, slot_low = 0;
logic [13:0] low_ticks      =       0;
logic [11:0] presence_ticks =       0;
logic [10:0] slot_ticks     = 11'h7ff;
logic [2:0]  bit_index      =       0;
logic [7:0]  rx_shift       =       0;
wire         falling        = host_low && !host_q;
wire         reset_end      = !host_low && host_q && low_ticks >= 14'd11520;
wire         bit_done       = !host_low && host_q && presence_ticks == 0 &&
                              low_ticks >= 14'd24 && low_ticks <= 14'd2880;
wire         byte_done      = bit_done && &bit_index;
wire  [7:0]  rx_byte        = {low_ticks <= 14'd360, rx_shift[6:0]};
wire         transmit       = state == READ_MEMORY || state == READ_TA1 || state == READ_TA2 ||
                              state == READ_STATUS || state == READ_SP || state == CRC_LO ||
                              state == CRC_HI || state == FINISHED || state == READ_ROM;
logic [7:0]  tx_byte;

assign pull_low = (presence_ticks >= 12'd720) || (slot_low && slot_ticks < 11'd1440);
assign addr     = page_wr ? wr_addr : page_commit ? target[7:0] : ptr;

function automatic [15:0] crc_byte(input logic [15:0] value, input logic [7:0] byte_in);
	logic [15:0] c;
	begin
		c = value ^ {8'd0, byte_in};
		for (integer i = 0; i < 8; i = i + 1)
			c = (c >> 1) ^ (c[0] ? 16'ha001 : 16'd0);
		crc_byte = c;
	end
endfunction

always_comb begin
	case (state)
		READ_ROM:    tx_byte = DS2431_ROM[ptr[2:0]*8 +: 8];
		READ_MEMORY: tx_byte = memory_q;
		READ_TA1:    tx_byte = target[7:0];
		READ_TA2:    tx_byte = target[15:8];
		READ_STATUS: tx_byte = sp_status;
		READ_SP:     tx_byte = scratch_q;
		CRC_LO:      tx_byte = ~crc[7:0];
		CRC_HI:      tx_byte = ~crc[15:8];
		default:     tx_byte = 8'hff;
	endcase
end

always_ff @(posedge clk) begin
	host_q <= host_low;
	if (host_low) begin
		if (low_ticks != 14'd11520) low_ticks <= low_ticks + 1'b1;
	end else low_ticks <= 0;
	if (slot_ticks != 11'h7ff) slot_ticks     <= slot_ticks + 1'b1;
	if (presence_ticks != 0)
		presence_ticks <= presence_ticks == 12'd3599 ? 12'd0 : presence_ticks + 1'b1;
	if (falling && presence_ticks == 0) begin
		slot_ticks <= 0;
		slot_low   <= transmit && !tx_byte[bit_index];
	end
	if (bit_done) begin
		rx_shift[bit_index] <= low_ticks <= 14'd360;
		bit_index           <= bit_index + 1'b1;
	end
	if (reset_end) begin
		presence_ticks <= 1;
		slot_low       <= 0;
		bit_index      <= 0;
	end
	if (clear || reset) begin
		low_ticks      <=       0;
		presence_ticks <=       0;
		slot_ticks     <= 11'h7ff;
		slot_low       <=       0;
		bit_index      <=       0;
	end
end

always_ff @(posedge clk) begin
	page_clear  <= 0;
	page_load   <= 0;
	page_wr     <= 0;
	page_commit <= 0;
	rd          <= 0;
	if (ready && state == WAIT_MEMORY) begin
		memory_q <= q;
		state    <= READ_MEMORY;
	end
	if (byte_done) begin
		if (state != CRC_LO && state != CRC_HI)
			crc <= crc_byte(state == MEM_COMMAND ? 16'd0 : crc, transmit ? tx_byte : rx_byte);
		case (state)
			ROM_COMMAND:           begin
				if (ds2431 && rx_byte == 8'h33) ptr <= 0;
				state <= rx_byte == 8'hcc ? MEM_COMMAND :
				         ds2431 && rx_byte == 8'h33 ? READ_ROM : FINISHED;
			end
			READ_ROM:              begin
				ptr <= ptr + 1'b1;
				if (&ptr[2:0]) state <= MEM_COMMAND;
			end
			MEM_COMMAND:           begin
				command <= rx_byte;
				state   <= FINISHED;
				if (!busy) begin
					case (rx_byte)
						8'h0f:   begin
							sp_valid   <= 0;
							copied     <= 0;
							page_clear <= 1;
							state      <= ADDRESS_LO;
						end
						8'hf0:   begin
							// DS2430A Read Memory also refreshes its complete scratchpad.
							page_load <= !ds2431;
							if (!ds2431) sp_valid <= 1;
							state <= ADDRESS_LO;
						end
						8'haa:   begin
							ptr   <= target[7:0];
							state <= ds2431 ? READ_TA1 : ADDRESS_LO;
						end
						8'h55:   state <= ds2431 ? COPY_TA1 : COPY_KEY;
						default: ;
					endcase
				end
			end
			ADDRESS_LO:            begin
				ptr <= rx_byte;
				if (command == 8'h0f) target[7:0] <= rx_byte;
				if (ds2431) state <= ADDRESS_HI;
				else if (command == 8'h0f || command == 8'haa) begin
					ptr   <= {3'd0, rx_byte[4:0]};
					state <= command == 8'h0f ? WRITE_SP : READ_SP;
				end else if (rx_byte < 32) begin rd <= 1; state <= WAIT_MEMORY; end
				else state <= FINISHED;
			end
			ADDRESS_HI:            begin
				if (command == 8'h0f) begin
					target[15:8] <= rx_byte;
					state        <= WRITE_SP;
				end else if (rx_byte == 0 && ptr < 128) begin rd <= 1; state <= WAIT_MEMORY; end
				else state <= FINISHED;
			end
			WRITE_SP:              begin
				wr_addr <= ptr;
				data    <= rx_byte;
				page_wr <= 1;
				ptr     <= ds2431 ? ptr + 1'b1 : {3'd0, ptr[4:0] + 5'd1};
				sp_end  <= ptr[2:0];
				if (!ds2431) sp_valid <= 1;
				else if (&ptr[2:0]) begin
					sp_valid <= target[15:7] == 0 && target[2:0] == 0;
					state    <= CRC_LO;
				end
			end
			READ_MEMORY:           begin
				ptr <= ptr + 1'b1;
				if (ptr == (ds2431 ? 8'd127 : 8'd31)) state <= FINISHED;
				else begin rd <= 1; state <= WAIT_MEMORY; end
			end
			READ_TA1:              state <= READ_TA2;
			READ_TA2:              state <= READ_STATUS;
			READ_STATUS:           state <= READ_SP;
			READ_SP:               begin
				ptr <= ds2431 ? ptr + 1'b1 : {3'd0, ptr[4:0] + 5'd1};
				if (ds2431 && &ptr[2:0]) state <= CRC_LO;
			end
			COPY_TA1:              begin
				copy_match <= rx_byte == target[7:0];
				state      <= COPY_TA2;
			end
			COPY_TA2:              begin
				copy_match <= copy_match && rx_byte == target[15:8];
				state      <= COPY_STATUS;
			end
			COPY_STATUS, COPY_KEY: begin
				if (!busy && sp_valid &&
				    (ds2431 ? copy_match && rx_byte == sp_status : rx_byte == 8'ha5)) begin
					page_commit <= 1;
					copied      <= 1;
				end
				state <= FINISHED;
			end
			CRC_LO:                state <= CRC_HI;
			CRC_HI:                state <= FINISHED;
			default:               ;
		endcase
	end
	// A bus or console reset returns to ROM command decoding. Keep the scratchpad and target
	// address so a later Copy Scratchpad command can use them.
	if (reset_end || reset) state <= ROM_COMMAND;
	if (clear) begin
		state    <= ROM_COMMAND;
		target   <= 0;
		sp_valid <= 0;
		copied   <= 0;
	end
end
endmodule

`default_nettype wire
