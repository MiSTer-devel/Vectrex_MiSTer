# Check the existing fit with current FIFO route constraints; never fit or save.
# Usage: quartus_sta -t tcl/report_fifo_cdc.tcl <external-output-directory>
load_package sta
if {[llength $quartus(args)] != 1} { error "Expected an external output directory" }
set project_dir [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file normalize [lindex $quartus(args) 0]]
if {[string equal -nocase $out_dir $project_dir] ||
	[string match -nocase "$project_dir/*" $out_dir]} {
	error "Reports must be outside the production repository"
}
file mkdir $out_dir
cd $project_dir
puts "Expected full-run wall time: 30-90 seconds. Progress: 0% - read existing fitted database"
project_open -revision Vectrex Vectrex
create_timing_netlist
read_sdc
update_timing_netlist

set coverage [open [file join $out_dir coverage.txt] w]
foreach stage {wr_ptr_g_sync1 wr_ptr_g_sync2 rd_ptr_g_sync1_12 rd_ptr_g_sync2_12} {
	set pattern [format {*|rasterizer_inst|%s[*]} $stage]
	set count [get_collection_size [get_registers $pattern]]
	puts $coverage "$stage: $count registers"
	if {$count < 11} { error "Incomplete FIFO synchronizer coverage: $stage" }
}
foreach stage {wr_gray rd_gray wr_gray_meta rd_gray_meta wr_gray_sync rd_gray_sync} {
	set pattern [format {*|artwork_overlay|loader|upload_fifo|%s[*]} $stage]
	set count [get_collection_size [get_registers $pattern]]
	puts $coverage "upload_fifo/$stage: $count registers"
	if {$count != 7} { error "Incomplete artwork FIFO pointer coverage: $stage" }
}
close $coverage

set corners [get_available_operating_conditions]
set total [get_collection_size $corners]
set index 0
foreach_in_collection corner $corners {
	incr index
	set_operating_conditions $corner
	update_timing_netlist
	set report [file join $out_dir corner${index}_net_delay.rpt]
	report_net_delay -file $report
	set input [open $report r]
	set targets [dict create]
	while {[gets $input line] >= 0} {
		set cells [split $line {;}]
		if {[llength $cells] < 8 || [string trim [lindex $cells 1]] ne "--"} { continue }
		set target [string trim [lindex $cells 6]]
		if {![regexp {\|(?:wr_ptr_g_sync1|rd_ptr_g_sync1_12|wr_gray_meta|rd_gray_meta)\[[0-9]+\]$} $target]} { continue }
		set slack [string trim [lindex $cells 2]]
		if {![string is double -strict $slack] || $slack < 0} {
			error "FIFO pointer route misses its limit: $line"
		}
		dict set targets $target 1
	}
	close $input
	if {[dict size $targets] != 36} { error "Expected 36 constrained FIFO pointer bits, found [dict size $targets]" }
	puts "Progress: [expr {10 + 80*$index/$total}]% - corner $index: all 36 FIFO pointer routes covered and within limits"
}
report_metastability -file [file join $out_dir metastability.rpt]
delete_timing_netlist
project_close
puts "Progress: 100% - PASS FIFO route coverage at all corners. Inspect synchronizer identification and settling in metastability.rpt for this fit."
