module alphablend 
(
	input        clk,
	input  [3:0] bg_a,
	input  [3:0] bg_r,
	input  [3:0] bg_g,
	input  [3:0] bg_b,
	output [7:0] bga_r,
	output [7:0] bga_g,
	output [7:0] bga_b
);

function [7:0] mul4x4; input [7:0] c; input [3:0] a;
	begin
		mul4x4 = 0;
		if(a[0]) mul4x4 = mul4x4 + c[7:4];
		if(a[1]) mul4x4 = mul4x4 + c[7:3];
		if(a[2]) mul4x4 = mul4x4 + c[7:2];
		if(a[3]) mul4x4 = mul4x4 + c[7:1];
	end
endfunction 

always @(posedge clk) begin
	bga_r <= mul4x4({bg_r,bg_r}, bg_a);
	bga_g <= mul4x4({bg_g,bg_g}, bg_a);
	bga_b <= mul4x4({bg_b,bg_b}, bg_a);
end

endmodule
