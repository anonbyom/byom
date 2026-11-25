# Reports (SLR use, worst paths, where the placer put the unanchored glue), then physical optimization.
set out [file join $::env(FPGA_OUTPUT) reports]
file mkdir $out
report_utilization -slr -file [file join $out tpu_anchor_slr_post_place.rpt]
report_timing -max_paths 100 -nworst 1 -file [file join $out tpu_anchor_worst100_post_place.rpt]
set core [get_cells -hier -filter {REF_NAME == tpu || ORIG_REF_NAME == tpu}]
set prefix "[get_property NAME $core]/"
set free [get_cells -hier -filter "IS_PRIMITIVE && NAME =~ ${prefix}* && PBLOCK !~ \"pblock_dynamic_SLR*\""]
set site_slr [dict create]
foreach slr {0 1 2} {
    foreach site [get_property NAME [get_sites -of_objects [get_slrs SLR$slr]]] {dict set site_slr $site $slr}
}
set counts [dict create]
foreach name [get_property NAME $free] loc [get_property LOC $free] {
    set slr [expr {[dict exists $site_slr $loc] ? [dict get $site_slr $loc] : "?"}]
    regsub -all {\[[0-9]+\]} [join [lrange [split [string range $name [string length $prefix] end] /] 0 1] /] {[*]} group
    dict incr counts "$group SLR$slr"
}
set report [open [file join $out tpu_anchor_free_cells.rpt] w]
dict for {key value} $counts {puts $report "$value\t$key"}
close $report
puts "TPU_ANCHOR free_primitives=[llength $free]"

phys_opt_design -directive AggressiveExplore
report_timing_summary -file [file join $out post_place_phys_opt_timing.rpt]
