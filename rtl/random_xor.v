module random_xor (
	input             clock,
	input             reset,
	input      [31:0] seed,
	output reg [31:0] lfsr
);

wire [31:0] shift13 = lfsr ^ (lfsr << 13);
wire [31:0] shift17 = shift13 ^ (shift13 >> 17);

always @(posedge clock) begin
	if (reset) lfsr <= (seed != 0) ? seed : 32'h1234abcd;
	else       lfsr <= shift17 ^ (shift17 << 5);
end

endmodule
