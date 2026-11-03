// 11AA010 cartridge EEPROM: Manchester-coded UNI/O on PB6.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

module vectrex_11aa010 (
	input  wire        clk,
	input  wire        clear,
	input  wire        reset,

	input  wire        scio,
	output wire        drive,
	output wire        level,
	input  wire        busy,
	input  wire  [1:0] protect,

	output logic       protect_wr   = 0,
	output logic [1:0] protect_data = 0,

	output logic       page_clear   = 0,
	output logic       page_wr      = 0,
	output logic       page_commit  = 0,
	output logic [1:0] bulk         = 0,

	output logic [7:0] addr         = 0,
	output logic [7:0] data         = 0,
	output logic       rd           = 0,

	input  wire  [7:0] q,
	input  wire        ready
);
typedef enum logic [3:0] {IDLE, STANDBY, HEADER_LOW, HEADER_FIRST, HEADER_BITS, HEADER_END,
                         RX_BYTE, RX_MAK, TX_SAK, TX_BYTE} state_t;
typedef enum logic [3:0] {HEADER, DEVICE, COMMAND, ADDRESS_HI, ADDRESS_LO,
                         WRITE_DATA, READ_DATA, STATUS_READ, STATUS_WRITE} stage_t;
state_t       state = IDLE;
stage_t       stage = HEADER;
logic         scio_q = 1, wel = 0, mid_seen = 0, rx_bit = 0, mak = 0, sak = 0, advance_addr = 0;
// At 24 MHz, standby requires 600 us high and the start header requires at least 5 us low.
logic  [15:0] idle_ticks = 0;
logic  [11:0] edge_ticks = 0, half_ticks = 120, bit_ticks = 240;
logic  [12:0] phase = 0;
logic  [3:0]  bits  = 0;
logic  [7:0]  shift = 0, byte_q = 0, command = 0, read_byte = 0;
wire          edge_seen      = scio != scio_q;
wire          receiving      = state == RX_BYTE || state == RX_MAK;
wire          bit_end        = phase == {1'b0, bit_ticks} - 1'b1;
wire          tx_bit         = state == TX_SAK ? 1'b1 : read_byte[7-bits];
wire          protected_addr = protect == 3 || (protect == 2 && addr[6]) ||
                               (protect == 1 && addr[6:5] == 2'b11);
assign        drive          = (state == TX_BYTE) || (state == TX_SAK && sak);
assign        level          = phase < {1'b0, half_ticks} ? !tx_bit : tx_bit;

always_ff @(posedge clk) begin
	scio_q      <= scio;
	page_clear  <= 0;
	page_wr     <= 0;
	page_commit <= 0;
	protect_wr  <= 0;
	bulk        <= 0;
	rd          <= 0;
	if (ready) read_byte <= q;
	if (scio && !drive) begin
		if (idle_ticks != 14400) idle_ticks <= idle_ticks + 1'b1;
	end else idle_ticks <= 0;
	if (edge_ticks != 4095)  edge_ticks <= edge_ticks + 1'b1;
	if (edge_seen)           edge_ticks <= 0;
	if (state >= HEADER_END) phase      <= bit_end ? 13'd0 : phase + 1'b1;

	// Ignore transitions at the start of each bit period. Use the next transition to read the
	// data level and align the receiver clock to the middle of the bit.
	if (receiving && edge_seen && !mid_seen && phase >= {2'b00, half_ticks[11:1]}) begin
		phase    <= {1'b0, half_ticks};
		mid_seen <= 1;
		rx_bit   <= scio;
	end

	if (clear || reset) begin
		state      <= IDLE;
		idle_ticks <= 0;
		page_clear <= 1;
		if (clear) begin wel <= 0; addr <= 0; end
	end else if (idle_ticks == 14400 && scio && !drive) begin
		state      <= STANDBY;
		page_clear <= 1;
	end else begin
		case (state)
			STANDBY:      if (edge_seen && !scio) state <= HEADER_LOW;
			HEADER_LOW:   if (edge_seen && scio) begin
				if (edge_ticks >= 119) state <= HEADER_FIRST;
				else state <= IDLE;
			end
			HEADER_FIRST: if (edge_seen) begin
				if (!scio && edge_ticks >= 119 && edge_ticks <= 1199) begin
					half_ticks <= edge_ticks + 1'b1;
					bits       <= 1;
					state      <= HEADER_BITS;
				end else state <= IDLE;
			end
			HEADER_BITS:  if (edge_seen) begin
				if (scio != bits[0] || edge_ticks < 239 || edge_ticks > 2399) state <= IDLE;
				else begin
					bit_ticks  <= edge_ticks + 1'b1;
					half_ticks <= (edge_ticks + 1'b1) >> 1;
					bits       <= bits + 1'b1;
					if (bits == 7) begin
						stage    <= HEADER;
						state    <= HEADER_END;
						phase    <= (edge_ticks + 1'b1) >> 1;
						mid_seen <= 1;
					end
				end
			end
			HEADER_END:   if (bit_end) begin
				state    <= RX_MAK;
				mid_seen <= 0;
			end
			RX_BYTE:      if (bit_end && !(edge_seen && !mid_seen)) begin
				mid_seen <= 0;
				if (!mid_seen) state <= IDLE;
				else begin
					shift <= {shift[6:0], rx_bit};
					bits  <= bits + 1'b1;
					if (bits == 7) begin
						byte_q <= {shift[6:0], rx_bit};
						state  <= RX_MAK;
					end
				end
			end
			RX_MAK:       if (bit_end && !(edge_seen && !mid_seen)) begin
				mid_seen     <= 0;
				mak          <= rx_bit;
				sak          <= 1;
				state        <= TX_SAK;
				advance_addr <= 0;
				if (!mid_seen) state <= IDLE;
				else case (stage)
					HEADER:                 begin
						sak   <= 0;
						stage <= DEVICE;
						if (!rx_bit) state <= IDLE;
					end
					DEVICE:
						if (byte_q != 8'ha0) begin
							sak <= 0;
							mak <= 0;
						end else stage <= COMMAND;
					COMMAND:                begin
						command <= byte_q;
						case (byte_q)
							8'h96, 8'h91: begin // WREN, WRDI
								if (!rx_bit) wel <= byte_q == 8'h96;
								else begin
									sak <= 0;
									mak <= 0;
								end
							end
							8'h05:        stage <= STATUS_READ; // RDSR
							8'h03, 8'h6c: // READ, WRITE
								if (!busy && rx_bit) stage <= ADDRESS_HI;
								else begin
									sak <= 0;
									mak <= 0;
								end
							8'h06:        // CRRD
								if (!busy && rx_bit) begin
									stage <= READ_DATA;
									rd    <= 1;
								end else begin
									sak <= 0;
									mak <= 0;
								end
							8'h6e:        // WRSR
								if (!busy && rx_bit) stage <= STATUS_WRITE;
								else begin
									sak <= 0;
									mak <= 0;
								end
							8'h6d, 8'h67: begin // ERAL, SETAL
								if (!busy && !rx_bit) begin
									if (wel && protect == 0) bulk <= byte_q == 8'h6d ? 2'd1 : 2'd2;
									wel <= 0;
								end else begin
									sak <= 0;
									mak <= 0;
								end
							end
							default:      begin
								sak <= 0;
								mak <= 0;
							end
						endcase
					end
					ADDRESS_HI:             begin
						stage <= ADDRESS_LO;
						if (!rx_bit) begin
							sak <= 0;
							mak <= 0;
						end
					end
					ADDRESS_LO:             begin
						addr  <= {1'b0, byte_q[6:0]};
						stage <= command == 8'h03 ? READ_DATA : WRITE_DATA;
						rd    <= command == 8'h03 && rx_bit;
						if (!rx_bit) begin
							sak <= 0;
							mak <= 0;
						end
					end
					WRITE_DATA:             begin
						advance_addr <= 1;
						data         <= byte_q;
						page_wr      <= wel && !protected_addr;
						if (!rx_bit) begin
							page_commit <= wel && !protected_addr;
							wel         <= 0;
						end
					end
					STATUS_WRITE:           begin
						if (!rx_bit) begin
							protect_data <= byte_q[3:2];
							protect_wr   <= wel;
							wel          <= 0;
						end else begin
							sak <= 0;
							mak <= 0;
						end
					end
					READ_DATA, STATUS_READ: begin
						if (stage == READ_DATA) begin
							addr <= {1'b0, addr[6:0] + 7'd1};
							rd   <= rx_bit;
						end
					end
					default:                ;
				endcase
			end
			TX_SAK:       if (bit_end) begin
				bits     <= 0;
				mid_seen <= 0;
				if (advance_addr) addr <= {1'b0, addr[6:4], addr[3:0] + 4'd1};
				if (!mak) state <= sak ? STANDBY : IDLE;
				else if (stage == READ_DATA || stage == STATUS_READ) begin
					state <= TX_BYTE;
					if (stage == STATUS_READ) read_byte <= {4'd0, protect, wel, busy};
				end else begin
					state <= RX_BYTE;
				end
			end
			TX_BYTE:      if (bit_end) begin
				bits <= bits + 1'b1;
				if (bits == 7) begin
					state    <= RX_MAK;
					mid_seen <= 0;
				end
			end
			default:      ;
		endcase
	end
end
endmodule

`default_nettype wire
