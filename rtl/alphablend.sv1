module alphablend 
(
	input        clk,
	input  [3:0] bg_a,
	input  [3:0] bg_r,
	input  [3:0] bg_g,
	input  [3:0] bg_b,
	output [3:0] bga_r,
	output [3:0] bga_g,
	output [3:0] bga_b
);

wire [23:0] irgb = {4'h0,bg_r,4'h0,bg_g,4'h0,bg_b};

reg [23:0] orgb;
always @(*) begin
	orgb = irgb;
	if(bg_a[0]) orgb = orgb + irgb;
	if(bg_a[1]) orgb = orgb + {irgb[22:0], 1'd0};
	if(bg_a[2]) orgb = orgb + {irgb[21:0], 2'd0};
	if(bg_a[3]) orgb = orgb + {irgb[20:0], 3'd0};
end

always @(posedge clk) begin
	bga_r <= orgb[23:20];
	bga_g <= orgb[15:12];
	bga_b <= orgb[7:4];
end

endmodule
