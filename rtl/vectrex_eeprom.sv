// Cartridge EEPROM protocols share a page buffer and unused cartridge RAM.
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
`default_nettype none

module vectrex_eeprom #(
	parameter integer WRITE_CLOCKS = 120_000
)(
	input  wire        clk,
	input  wire        download,
	input  wire        reset,
	input  wire  [2:0] kind,  // Device ID from vectrex_save_catalog.
	input  wire        pb6,
	input  wire        host_low,
	input  wire        irq_n,
	output wire        line_out,
	output wire        busy,
	output logic       changed = 0,
	output logic [1:0] protect = 0,
	input  wire        protect_restore,
	input  wire  [1:0] protect_data,
	output wire        mem_req,
	output wire        mem_wr,
	output wire  [7:0] mem_addr,
	output wire  [7:0] mem_data,
	input  wire  [7:0] mem_q,
	input  wire        mem_ready
);
typedef enum logic [2:0] {IDLE, ISSUE, WAIT_MEMORY, NEXT_BYTE} state_t;
state_t      state  = IDLE;
logic [2:0]  kind_q = 0;
logic [1:0]  bulk_q = 0;
logic        initializing = 0, loading = 0, programming = 0, read_pending = 0;
logic [7:0]  index     = 0;
logic [31:0] page_mask = 0;
(* ramstyle = "logic" *) logic [7:0] page_data [0:31];
localparam integer     TIMER_BITS = $clog2(2*WRITE_CLOCKS+1);
logic [TIMER_BITS-1:0] timer      = 0;
wire unio   = kind == 1;
wire i2c    = kind == 2;
wire ds2430 = kind == 3;
wire dallas = ds2430 || kind == 4;

wire [7:0] unio_addr, unio_data, i2c_addr, i2c_data, dallas_addr, dallas_data;
wire       unio_clear, unio_wr, unio_commit, unio_rd, unio_drive, unio_level;
wire       i2c_clear, i2c_wr, i2c_commit, i2c_rd, i2c_low;
wire       dallas_clear, dallas_load, dallas_wr, dallas_commit, dallas_rd, dallas_low;
wire       protect_wr;
wire [1:0] new_protect, bulk;

wire       page_clear  = dallas ? dallas_clear  : unio ? unio_clear  : i2c_clear;
wire       page_wr     = dallas ? dallas_wr     : unio ? unio_wr     : i2c_wr;
wire       page_commit = dallas ? dallas_commit : unio ? unio_commit : i2c_commit;
wire       rd          = dallas ? dallas_rd     : unio ? unio_rd     : i2c_rd;
wire [7:0] addr        = dallas ? dallas_addr   : unio ? unio_addr   : i2c_addr;
wire [7:0] data        = dallas ? dallas_data   : unio ? unio_data   : i2c_data;

wire [4:0] page_index    = ds2430 ? addr[4:0] :
                           unio   ? {1'b0, addr[3:0]} : {2'b00, addr[2:0]};
wire [4:0] program_index = ds2430 ? index[4:0] :
                           unio   ? {1'b0, index[3:0]} : {2'b00, index[2:0]};
wire [7:0] base          = ds2430 ? 8'd0 : unio ? {addr[7:4], 4'd0} : {addr[7:3], 3'd0};
wire       last_byte     = ds2430 ? &index[4:0] : unio ? &index[3:0] : &index[2:0];
wire [7:0] page_q        = page_data[programming ? program_index : page_index];
wire       enabled       = unio || i2c || dallas;

// The scratchpad receives erased bytes, data read from DS2430A memory, or serial writes.
wire       page_serial_wr = !busy && enabled && page_wr;
wire       page_store     = !download &&
                            !(kind != kind_q && enabled) &&
                            (page_serial_wr ||
                             (loading && state == WAIT_MEMORY && mem_ready) ||
                             (initializing && state == NEXT_BYTE && index < 32));
wire [4:0] page_wr_index  = page_serial_wr ? page_index : index[4:0];
wire [7:0] page_wr_data   = page_serial_wr ? data : state == WAIT_MEMORY ? mem_q : 8'hff;

assign line_out = unio && unio_drive ? unio_level : !((i2c && i2c_low) || (dallas && dallas_low));
assign busy     = enabled &&
                  (timer != 0 || programming || (state != IDLE && !loading) || kind != kind_q);
assign mem_req  = !download && enabled && (state == ISSUE || (state == IDLE && !programming && rd));
assign mem_wr   = state == ISSUE && !loading;
assign mem_addr = state == ISSUE ? index : addr;
assign mem_data = initializing || bulk_q == 2 ? 8'hff : bulk_q == 1 ? 8'h00 : page_q;

vectrex_11aa010 unio_device (
	.clk(clk), .clear(download || !unio), .reset(reset), .scio(pb6),
	.drive(unio_drive), .level(unio_level), .busy(busy), .protect(protect),
	.protect_wr(protect_wr), .protect_data(new_protect),
	.page_clear(unio_clear), .page_wr(unio_wr), .page_commit(unio_commit), .bulk(bulk),
	.addr(unio_addr), .data(unio_data), .rd(unio_rd),
	.q(mem_q), .ready(mem_ready && read_pending && unio)
);

vectrex_24c02 i2c_device (
	.clk(clk), .reset(download || reset || !i2c), .sda(pb6), .scl(irq_n),
	.sda_low(i2c_low), .busy(busy),
	.page_clear(i2c_clear), .page_wr(i2c_wr), .page_commit(i2c_commit),
	.addr(i2c_addr), .data(i2c_data), .rd(i2c_rd),
	.q(mem_q), .ready(mem_ready && read_pending && i2c)
);

vectrex_1wire dallas_device (
	.clk(clk), .clear(download || !dallas), .reset(reset), .ds2431(kind == 4),
	.host_low(host_low), .pull_low(dallas_low), .busy(busy),
	.page_clear(dallas_clear), .page_load(dallas_load),
	.page_wr(dallas_wr), .page_commit(dallas_commit),
	.addr(dallas_addr), .data(dallas_data), .scratch_q(page_q), .rd(dallas_rd),
	.q(mem_q), .ready(mem_ready && read_pending && dallas)
);

always_ff @(posedge clk) begin
	kind_q  <= kind;
	changed <= 0;
	if (page_store) page_data[page_wr_index] <= page_wr_data;

	if (timer != 0)                                     timer        <= timer - 1'b1;
	if (mem_ready)                                      read_pending <= 0;
	if (state == IDLE && !programming && rd && enabled) read_pending <= 1;
	if (protect_restore && unio)                        protect      <= protect_data;

	if (download) begin
		state        <= IDLE;
		kind_q       <= 0;
		timer        <= 0;
		protect      <= 0;
		page_mask    <= 0;
		read_pending <= 0;
		programming  <= 0;
		initializing <= 0;
		loading      <= 0;
	end else if (kind != kind_q && enabled) begin
		// Fill the 256-byte backing store with 0xFF when a new EEPROM is selected.
		initializing <= 1;
		index        <= 0;
		bulk_q       <= 0;
		state        <= ISSUE;
	end else begin
		case (state)
			ISSUE:       state <= WAIT_MEMORY;
			WAIT_MEMORY: if (mem_ready) begin
				state <= NEXT_BYTE;
			end
			NEXT_BYTE:   begin
				if (initializing || loading || bulk_q != 0) begin
					if (index == (initializing ? 8'd255 : loading ? 8'd31 : 8'd127)) begin
						initializing <= 0;
						loading      <= 0;
						state        <= IDLE;
					end else begin index <= index + 1'b1; state <= ISSUE; end
				end else begin
					page_mask[program_index] <= 0;
					if (last_byte) programming <= 0;
					else index <= index + 1'b1;
					state <= IDLE;
				end
			end
			IDLE:        begin
				if (programming && bulk_q == 0) begin
					if (page_mask[program_index]) state <= ISSUE;
					else if (last_byte) programming <= 0;
					else index <= index + 1'b1;
				end
			end
			default:     ;
		endcase

		// Collect incoming bytes in the scratchpad. A page commit starts writing them to EEPROM.
		if (!busy && enabled) begin
			if (page_clear) page_mask <= 0;
			if (page_wr) begin
				page_mask[page_index] <= 1;
			end
			if (page_commit) begin
				timer       <= dallas ? TIMER_BITS'(2*WRITE_CLOCKS) : TIMER_BITS'(WRITE_CLOCKS);
				changed     <= 1;
				bulk_q      <= 0;
				programming <= 1;
				index       <= base;
				if (dallas) page_mask <= ds2430 ? 32'hffffffff : 32'h000000ff;
			end
			if (dallas && dallas_load) begin
				loading <= 1;
				index   <= 0;
				state   <= ISSUE;
			end
			if (unio && protect_wr) begin
				protect <= new_protect;
				timer   <= TIMER_BITS'(WRITE_CLOCKS);
				changed <= 1;
			end
			if (unio && bulk != 0) begin
				bulk_q    <= bulk;
				timer     <= TIMER_BITS'(2*WRITE_CLOCKS);
				index     <= 0;
				page_mask <= 0;
				state     <= ISSUE;
				changed   <= 1;
			end
		end
	end
end
endmodule

`default_nettype wire
