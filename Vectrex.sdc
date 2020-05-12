derive_pll_clocks
derive_clock_uncertainty

set_multicycle_path -from {emu|vectrex|limited_*} -setup 2
set_multicycle_path -from {emu|vectrex|limited_*} -hold 1

set_false_path -from {emu|hps_io|status*}
