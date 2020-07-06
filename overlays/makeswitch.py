import sys
print("module alpha_blend (")
print("(")
print("       input clk,")
print("       input [3:0] bg_a,")
print("       input [3:0] bg_r,")
print("       input [3:0] bg_g,")
print("       input [3:0] bg_b,")
print("       output [3:0] bga_r,")
print("       output [3:0] bga_g,")
print("       output [3:0] bga_b")
print(");")
print("")
print("always @(posedge clk) begin")
print("")

for colorname in ('r','g','b'):
 print("case({ bg_a, bg_"+colorname+"})")
 for alpha in range(0,16):
  for color in range(0,16):
    a = alpha/15.0
    c = int(color*a)
    #print(alpha,color,a,c)
    digit = (alpha << 4) | color&0x0F;
    #print(alpha,color,a,c)
    sys.stdout.write('    \'h{:02X}: '.format(digit))
    sys.stdout.write('bga_'+colorname+' <= 4\'h{:01X};\n'.format(c))
 print("endcase")
print("end")
print("endmodule")
