derive_pll_clocks
derive_clock_uncertainty


set_false_path -from {emu|hps_io|status*}

# Treat the machine and renderer as asynchronous timing domains.
# Their crossings use dedicated FIFOs or synchronizers.
set core_clk [get_clocks {emu|pll|pll_inst|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set vfb_clk  [get_clocks {emu|pll_vfb|pll_vfb_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set hps_clk  [get_clocks {*|h2f_user0_clk}]

# Framework audio, HDMI, HPS, and board clocks are also asynchronous to the
# machine and renderer domains.
set aud_clk  [get_clocks {pll_audio|*divclk}]
set hdmi_clk [get_clocks {pll_hdmi|*output_counter|divclk}]
set brd_clk  [get_clocks {FPGA_CLK1_50 FPGA_CLK2_50 FPGA_CLK3_50}]

set_clock_groups -asynchronous \
	-group $core_clk \
	-group $vfb_clk \
	-group $hps_clk \
	-group $aud_clk \
	-group $hdmi_clk \
	-group $brd_clk

# Bound Gray-pointer routes to 80% of their source period (24 MHz / 125 MHz).
# set_net_delay remains effective across the asynchronous clock groups in Q17.
set_net_delay -max 33.333 \
	-from [get_registers {*|rasterizer_inst|wr_ptr_g[*]}] \
	-to [get_registers {*|rasterizer_inst|wr_ptr_g_sync1[*]}]
set_net_delay -max 6.400 \
	-from [get_registers {*|rasterizer_inst|rd_ptr_g[*]}] \
	-to [get_registers {*|rasterizer_inst|rd_ptr_g_sync1_12[*]}]

# Draw phase: registered Gray code from the 24 MHz source to the renderer.
set_net_delay -max 33.333 \
	-from [get_registers {*|phosphor_timing_inst|draw_gray_source[*]}] \
	-to [get_registers {*|phosphor_timing_inst|draw_gray_meta[*]}]

# Artwork upload FIFO: clk_io (24 MHz) to clk_sys (125 MHz), and back.
set_net_delay -max 33.333 \
	-from [get_registers {*|artwork_overlay|loader|upload_fifo|wr_gray[*]}] \
	-to [get_registers {*|artwork_overlay|loader|upload_fifo|wr_gray_meta[*]}]
set_net_delay -max 6.400 \
	-from [get_registers {*|artwork_overlay|loader|upload_fifo|rd_gray[*]}] \
	-to [get_registers {*|artwork_overlay|loader|upload_fifo|rd_gray_meta[*]}]

# PiTrex command FIFO: clk_125 (DDR ring reader) to clk_sys (24 MHz player), and back.
set_net_delay -max 8.000 \
	-from [get_registers {*|pitrex_fifo|wr_gray[*]}] \
	-to [get_registers {*|pitrex_fifo|wr_gray_meta[*]}]
set_net_delay -max 8.000 \
	-from [get_registers {*|pitrex_fifo|rd_gray[*]}] \
	-to [get_registers {*|pitrex_fifo|rd_gray_meta[*]}]
