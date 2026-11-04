// AT24C02 cartridge interface. PB6 carries SDA and the cartridge IRQ pin carries SCL.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

module vectrex_24c02 (
	input  wire        clk,
	input  wire        reset,

	input  wire        sda,
	input  wire        scl,
	output logic       sda_low     = 0,
	input  wire        busy,

	output logic       page_clear  = 0,
	output logic       page_wr     = 0,
	output logic       page_commit = 0,

	output logic [7:0] addr        = 0,
	output logic [7:0] data        = 0,
	output logic       rd          = 0,
	input  wire  [7:0] q,
	input  wire        ready
);
typedef enum logic [3:0] {IDLE, RECEIVE, ACK_BEGIN, ACK_HIGH, ACK_END,
                         TRANSMIT, MASTER_ACK, READ_NEXT} state_t;
typedef enum logic [1:0] {DEVICE, ADDRESS, WRITE_DATA, READ_DATA} stage_t;
state_t     state = IDLE, after_ack = IDLE;
stage_t     stage = DEVICE;
logic       scl_q = 1, sda_q = 1, ack = 0, have_data = 0;
logic [3:0] bits = 0;
logic [7:0] shift = 0, read_byte = 0;
wire        rise     = !scl_q && scl;
wire        fall     = scl_q && !scl;
wire        start    = scl && scl_q && sda_q && !sda;
wire        stop     = scl && scl_q && !sda_q && sda;
wire  [7:0] received = {shift[6:0], sda};

always_ff @(posedge clk) begin
	scl_q       <= scl;
	sda_q       <= sda;
	page_clear  <= 0;
	page_wr     <= 0;
	page_commit <= 0;
	rd          <= 0;
	if (ready) read_byte <= q;

	if (reset) begin
		state      <= IDLE;
		sda_low    <= 0;
		have_data  <= 0;
		page_clear <= 1;
	end else if (start) begin
		// START clears pending page writes but keeps the byte address for a repeated START read.
		state      <= RECEIVE;
		stage      <= DEVICE;
		bits       <= 0;
		sda_low    <= 0;
		have_data  <= 0;
		page_clear <= 1;
	end else if (stop) begin
		page_commit <= have_data && !busy;
		have_data   <= 0;
		sda_low     <= 0;
		state       <= IDLE;
	end else begin
		case (state)
			RECEIVE:    if (rise) begin
				shift <= received;
				bits  <= bits + 1'b1;
				if (bits == 7) begin
					bits      <= 0;
					ack       <= 1;
					after_ack <= RECEIVE;
					state     <= ACK_BEGIN;
					case (stage)
						DEVICE:     if (received[7:1] != 7'h50 || busy) begin
							ack       <= 0;
							after_ack <= IDLE;
						end else if (received[0]) begin
							stage     <= READ_DATA;
							after_ack <= TRANSMIT;
							rd        <= 1;
						end else stage <= ADDRESS;
						ADDRESS:    begin
							addr  <= received;
							stage <= WRITE_DATA;
						end
						WRITE_DATA: begin
							data      <= received;
							page_wr   <= 1;
							have_data <= 1;
						end
						default:    ;
					endcase
				end
			end
			ACK_BEGIN:  if (fall) begin
				sda_low <= ack;
				state   <= ACK_HIGH;
			end
			ACK_HIGH:   if (rise) state <= ACK_END;
			ACK_END:    if (fall) begin
				state   <= after_ack;
				sda_low <= after_ack == TRANSMIT && !read_byte[7];
				if (stage == WRITE_DATA && have_data) addr <= {addr[7:3], addr[2:0] + 3'd1};
			end
			TRANSMIT:   begin
				if (rise) begin
					bits <= bits + 1'b1;
					if (bits == 7) begin
						addr <= addr + 1'b1;
						rd   <= 1;
					end
				end
				if (fall) begin
					if (bits == 8) begin
						sda_low <= 0;
						state   <= MASTER_ACK;
					end else sda_low <= !read_byte[7-bits];
				end
			end
			MASTER_ACK: if (rise) state <= sda ? IDLE : READ_NEXT;
			READ_NEXT:  if (fall) begin
				bits    <= 0;
				sda_low <= !read_byte[7];
				state   <= TRANSMIT;
			end
			default:    ;
		endcase
	end
end
endmodule

`default_nettype wire
