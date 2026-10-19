//============================================================================
//  720x480p to 720x480i field converter
//
// Copyright (C) 2026 Videodr0me
// SPDX-License-Identifier: GPL-2.0-or-later
//============================================================================

`default_nettype none

module vfb_interlacer
(
	input  wire              clk_sys,
	input  wire              reset,
	input  wire              enable,
	input  wire signed [4:0] vertical_offset,

	input  wire       ce_pix_in,
	input  wire [7:0] r_in,
	input  wire [7:0] g_in,
	input  wire [7:0] b_in,
	input  wire       hsync_in,
	input  wire       vsync_in,
	input  wire       hblank_in,
	input  wire       vblank_in,

	output logic       ce_pix_out,
	output logic [7:0] r_out,
	output logic [7:0] g_out,
	output logic [7:0] b_out,
	output logic       hsync_out,
	output logic       vsync_out,
	output logic       hblank_out,
	output logic       vblank_out,
	output logic       field_out
);

localparam logic  [9:0] H_ACTIVE          = 10'd720;
localparam logic  [9:0] LINE_SAMPLES      = 10'd884;
localparam logic  [9:0] HALF_LINE         = LINE_SAMPLES / 10'd2;
localparam logic  [9:0] HS_START          = 10'd755;
localparam logic  [9:0] HS_END            = 10'd821;
localparam logic [18:0] VS_SAMPLES        = 19'(3 * LINE_SAMPLES);
localparam logic [18:0] VS_END            = HS_START + VS_SAMPLES;
localparam logic [18:0] FIELD_SAMPLES     = 19'(264 * LINE_SAMPLES + HALF_LINE);
localparam logic [18:0] ACTIVE_START_EVEN = 19'(18 * LINE_SAMPLES);
localparam logic [18:0] ACTIVE_START_ODD  = ACTIVE_START_EVEN + HALF_LINE;
localparam logic [18:0] ACTIVE_END_EVEN   = ACTIVE_START_EVEN + 19'(240 * LINE_SAMPLES);
localparam logic [18:0] ACTIVE_END_ODD    = ACTIVE_END_EVEN + HALF_LINE;
localparam logic [18:0] FIELD_PHASE_INIT  = ACTIVE_START_EVEN - HALF_LINE;

function automatic logic [18:0] shift_phase(input logic [18:0] base,
                                          input logic signed [19:0] shift);
	return 19'($signed({1'b0, base}) + shift);
endfunction

typedef struct packed {
	logic valid;
	logic ready;
	logic hblank;
	logic vblank;
	logic hsync;
	logic vsync;
	logic field;
} timing_sample_t;

typedef struct packed {
	logic        ce;
	logic [23:0] rgb;
	logic        hblank;
	logic        vblank;
	logic        hsync;
	logic        vsync;
	logic        field;
} interlaced_sample_t;

logic       input_hblank_q    =  1'b1;
logic       input_vblank_q    =  1'b1;
logic [9:0] source_x          = 10'd0;
logic [8:0] source_y          =  9'd0;
logic       input_vblank_seen =  1'b0;
logic       stream_locked     =  1'b0;

logic [18:0] field_phase      = FIELD_PHASE_INIT;
logic [9:0]  output_x         = HALF_LINE;
logic        output_field     = 1'b0;
logic        active_line_bank = 1'b0;
logic        output_primed    = 1'b0;
logic        output_divider   = 1'b0;

(* preserve *) logic signed [4:0] vertical_offset_q = 5'sd0;
logic signed [19:0] vertical_shift;
logic        [18:0] active_start_even = ACTIVE_START_EVEN;
logic        [18:0] active_start_odd  = ACTIVE_START_ODD;
logic        [18:0] active_end_even   = ACTIVE_END_EVEN;
logic        [18:0] active_end_odd    = ACTIVE_END_ODD;
logic        [18:0] field_phase_init  = FIELD_PHASE_INIT;

logic [18:0] active_start;
logic [18:0] active_end;
logic        current_hblank;
logic        current_vblank;
logic        current_hsync;
logic        current_vsync;
logic [10:0] read_address;
logic [10:0] write_address;
logic        write_line;
logic [10:0] read_address_q  = 11'd0;
logic [10:0] write_address_q = 11'd0;
logic [23:0] write_data_q    = 24'd0;
logic        write_line_q    =  1'b0;

(* ramstyle = "M10K, no_rw_check" *)
logic [23:0] line_memory [0:1439];
logic [23:0] line_read_q = 24'd0;

timing_sample_t     sample_q [0:1];
interlaced_sample_t interlaced_q;

wire input_frame_start = ce_pix_in && input_vblank_seen && input_vblank_q && !vblank_in;
wire output_step       = enable && ce_pix_in && output_divider;

// Shift the active window and phase together: only the porches change,
// while line-buffer delivery and the half-line field relationship stay fixed.
always_ff @(posedge clk_sys) begin
	vertical_offset_q <= vertical_offset;
	active_start_even <= shift_phase(ACTIVE_START_EVEN, vertical_shift);
	active_start_odd  <= shift_phase(ACTIVE_START_ODD, vertical_shift);
	active_end_even   <= shift_phase(ACTIVE_END_EVEN, vertical_shift);
	active_end_odd    <= shift_phase(ACTIVE_END_ODD, vertical_shift);
	field_phase_init  <= shift_phase(FIELD_PHASE_INIT, vertical_shift);
end

always_comb begin
	case (vertical_offset_q)
		5'sd4:   vertical_shift = 20'(2 * int'(LINE_SAMPLES));
		5'sd8:   vertical_shift = 20'(4 * int'(LINE_SAMPLES));
		5'sd12:  vertical_shift = 20'(6 * int'(LINE_SAMPLES));
		-5'sd4:  vertical_shift = 20'(-2 * int'(LINE_SAMPLES));
		-5'sd8:  vertical_shift = 20'(-4 * int'(LINE_SAMPLES));
		-5'sd10: vertical_shift = 20'(-5 * int'(LINE_SAMPLES));
		default: vertical_shift =  20'sd0;
	endcase

	active_start   = output_field ? active_start_odd : active_start_even;
	active_end     = output_field ? active_end_odd : active_end_even;
	current_hblank = output_x >= H_ACTIVE;
	current_vblank = (field_phase < active_start) || (field_phase >= active_end);
	current_hsync  = !((output_x >= HS_START) && (output_x < HS_END));
	current_vsync  = !((field_phase >= HS_START) && (field_phase < VS_END));

	read_address   = active_line_bank ? (11'd720 + {1'b0, output_x}) : {1'b0, output_x};
	if (output_x >= H_ACTIVE) read_address = 11'd0;

	// Capture field-matching line parity; source_y[1] alternates the two line banks.
	// Output consumes them at half the input pixel-enable rate.
	write_address = source_y[1] ? (11'd720 + {1'b0, source_x}) : {1'b0, source_x};
	write_line    = ce_pix_in && !hblank_in && !vblank_in && (source_x < H_ACTIVE) &&
	                (source_y[0] == output_field);
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		input_hblank_q    <=  1'b1;
		input_vblank_q    <=  1'b1;
		source_x          <= 10'd0;
		source_y          <=  9'd0;
		input_vblank_seen <=  1'b0;
		stream_locked     <=  1'b0;
	end else if (ce_pix_in) begin
		input_hblank_q <= hblank_in;
		input_vblank_q <= vblank_in;

		if (vblank_in)         input_vblank_seen <= 1'b1;
		if (input_frame_start) stream_locked     <= 1'b1;

		if (vblank_in) begin
			source_x <= 10'd0;
			source_y <=  9'd0;
		end else if (hblank_in) begin
			source_x <= 10'd0;
			if (!input_hblank_q && !input_vblank_q && (source_y < 9'd479))
				source_y <= source_y + 1'd1;
		end else begin
			source_x <= source_x + 1'd1;
		end
	end
end

always_ff @(posedge clk_sys) begin
	if (reset)
		output_divider <= 1'b0;
	else if (input_frame_start)
		output_divider <= 1'b0;
	else if (enable && ce_pix_in)
		output_divider <= !output_divider;
end

always_ff @(posedge clk_sys) begin
	if (reset) begin
		write_line_q     <=  1'b0;
		read_address_q   <= 11'd0;
		field_phase      <= field_phase_init;
		output_x         <= HALF_LINE;
		output_field     <=  1'b0;
		active_line_bank <=  1'b0;
		output_primed    <=  1'b0;
		line_read_q      <= 24'd0;
		sample_q[0]      <= {2'b00, 4'b1111, 1'b0};
		sample_q[1]      <= {2'b00, 4'b1111, 1'b0};
		interlaced_q     <= {1'b0, 24'd0, 4'b1111, 1'b0};
	end else begin
		if (write_line_q) line_memory[write_address_q] <= write_data_q;
		write_line_q <= write_line;
		if (write_line) begin
			write_address_q <= write_address;
			write_data_q    <= {r_in, g_in, b_in};
		end

		interlaced_q.ce <= 1'b0;

		if (input_frame_start && !stream_locked) begin
			field_phase       <= field_phase_init;
			output_x          <= HALF_LINE;
			output_field      <=  1'b0;
			active_line_bank  <=  1'b0;
			output_primed     <=  1'b0;
			read_address_q    <= 11'd0;
			line_read_q       <= 24'd0;
			sample_q[0].valid <=  1'b0;
			sample_q[0].ready <=  1'b0;
			sample_q[1].valid <=  1'b0;
			sample_q[1].ready <=  1'b0;
		end else if (output_step && stream_locked) begin
			interlaced_q.ce     <= sample_q[1].valid && sample_q[1].ready;
			interlaced_q.rgb    <= (sample_q[1].valid && !sample_q[1].hblank &&
			                        !sample_q[1].vblank) ? line_read_q : 24'd0;
			interlaced_q.hblank <= sample_q[1].hblank;
			interlaced_q.vblank <= sample_q[1].vblank;
			interlaced_q.hsync  <= sample_q[1].hsync;
			interlaced_q.vsync  <= sample_q[1].vsync;
			interlaced_q.field  <= sample_q[1].field;

			line_read_q    <= line_memory[read_address_q];
			read_address_q <= read_address;
			sample_q[1]    <= sample_q[0];
			sample_q[0]    <= {1'b1, output_primed, current_hblank, current_vblank, current_hsync,
			                   current_vsync, output_field};

			if (field_phase == active_start - 1'd1)
				active_line_bank <= 1'b0;
			else if (!current_vblank && (output_x == LINE_SAMPLES - 1'd1))
				active_line_bank <= !active_line_bank;

			output_x <= (output_x == LINE_SAMPLES - 1'd1) ? 10'd0 : output_x + 1'd1;
			if (field_phase == FIELD_SAMPLES - 1'd1) begin
				field_phase   <= 19'd0;
				output_field  <= !output_field;
				output_primed <= 1'b1;
			end else begin
				field_phase <= field_phase + 1'd1;
			end
		end

		// One progressive input frame lasts exactly one output field.
		// Re-anchor every frame without changing field parity.
		if (input_frame_start && stream_locked) begin
			field_phase <= field_phase_init;
			if (output_step && (field_phase == FIELD_SAMPLES - 1'd1))
				output_x <= !output_field ? 10'd0 : HALF_LINE;
			else
				output_x <= output_field ? 10'd0 : HALF_LINE;
		end
	end
end

always_comb begin
	if (enable) begin
		ce_pix_out = interlaced_q.ce;
		r_out      = interlaced_q.rgb[23:16];
		g_out      = interlaced_q.rgb[15:8];
		b_out      = interlaced_q.rgb[7:0];
		hsync_out  = interlaced_q.hsync;
		vsync_out  = interlaced_q.vsync;
		hblank_out = interlaced_q.hblank;
		vblank_out = interlaced_q.vblank;
		field_out  = interlaced_q.field;
	end else begin
		ce_pix_out = ce_pix_in;
		r_out      = r_in;
		g_out      = g_in;
		b_out      = b_in;
		hsync_out  = hsync_in;
		vsync_out  = vsync_in;
		hblank_out = hblank_in;
		vblank_out = vblank_in;
		field_out  = 1'b0;
	end
end

endmodule

`default_nettype wire
