# Report the existing fitted database; no synthesis, fitting or database export.
# Usage: quartus_sta -t tcl/report_current_timing.tcl <external-output-directory> ?near-pair-limit?
# Reuses the complete Vectrex endpoint/corner extraction queries.
set project_dir [file normalize [file join [file dirname [info script]] ..]]
if {[llength $quartus(args)] < 1 || [llength $quartus(args)] > 2} {
	error "Expected an external output directory and optional near-pair limit"
}
set out_dir [file normalize [lindex $quartus(args) 0]]
set pair_limit 0
if {[llength $quartus(args)] == 2} {
	set pair_limit [lindex $quartus(args) 1]
	if {![string is integer -strict $pair_limit] || $pair_limit < 0} {
		error "Near-pair limit must be a non-negative integer; zero means all pairs"
	}
}
file mkdir $out_dir

proc clock_name {path direction} {
	set clk [get_path_info $path -${direction}_clock]
	if {$clk eq ""} { return "" }
	return [get_clock_info $clk -name]
}

proc inventory {filename paths} {
	set f [open $filename w]
	puts $f "slack\ttype\tfrom\tto\tfrom_clock\tto_clock\tlogic_levels\tdata_delay\tclock_skew\tclock_relationship"
	set count 0
	foreach_in_collection path $paths {
		incr count
		set values [list [get_path_info $path -slack] [get_path_info $path -type] \
			[get_node_info [get_path_info $path -from] -name] \
			[get_node_info [get_path_info $path -to] -name] \
			[clock_name $path from] [clock_name $path to] \
			[get_path_info $path -num_logic_levels] [get_path_info $path -data_delay] \
			[get_path_info $path -clock_skew] [get_path_info $path -clock_relationship]]
		puts $f [join $values "\t"]
	}
	close $f
	return $count
}

puts "Report-only extraction: expected 3-10 minutes; no synthesis, fitting or database export."
cd $project_dir
project_open -revision Vectrex Vectrex
create_timing_netlist
read_sdc
update_timing_netlist

set corners [get_available_operating_conditions]
set total [get_collection_size $corners]
set index 0
set stats [open $out_dir/counts.tsv w]
puts $stats "corner\tmodel\ttemperature\tvoltage\tsetup_endpoints\tnear_pairs\tfailing_endpoints\thold_failing\trecovery_failing\tremoval_failing"

foreach_in_collection corner $corners {
	incr index
	set model [get_operating_conditions_info $corner -model]
	set temp [get_operating_conditions_info $corner -temperature]
	set voltage [get_operating_conditions_info $corner -voltage]
	set prefix "corner${index}_${model}_${temp}c_${voltage}mv"
	puts "PROGRESS [expr {10+75*($index-1)/$total}]%: $prefix"
	set_operating_conditions $corner
	update_timing_netlist

	set endpoints [inventory $out_dir/${prefix}_all_endpoints.tsv \
		[get_timing_paths -setup -npaths 0 -nworst 1]]
	set fails [inventory $out_dir/${prefix}_failing_endpoints.tsv \
		[get_timing_paths -setup -npaths 0 -nworst 1 -less_than_slack 0.000]]
	puts "$prefix: endpoints=$endpoints failing_endpoints=$fails; extracting full paths"

	report_timing -setup -npaths 0 -nworst 1 -less_than_slack 0.000 -detail full_path \
		-show_routing -file $out_dir/${prefix}_failing_detail.rpt
	report_timing -setup -npaths 0 -nworst 1 -less_than_slack 0.500 \
		-detail full_path -file $out_dir/${prefix}_near_endpoints_detail.rpt
	set near [inventory $out_dir/${prefix}_near_pairs.tsv \
		[get_timing_paths -setup -npaths $pair_limit -pairs_only -less_than_slack 0.500]]
	puts "$prefix: near_pairs=$near (limit=$pair_limit; endpoint reports remain complete)"

	foreach kind {hold recovery removal} {
		set bad($kind) [inventory $out_dir/${prefix}_${kind}_failing.tsv \
			[get_timing_paths -$kind -npaths 0 -nworst 1 -less_than_slack 0.000]]
		report_timing -$kind -npaths 5 -nworst 1 -detail full_path \
			-file $out_dir/${prefix}_${kind}_worst.rpt
	}

	puts $stats [join [list $prefix $model $temp $voltage $endpoints $near $fails \
		$bad(hold) $bad(recovery) $bad(removal)] "\t"]
	flush $stats
}

close $stats
delete_timing_netlist
project_close
puts "PROGRESS 100%: report-only extraction complete."
