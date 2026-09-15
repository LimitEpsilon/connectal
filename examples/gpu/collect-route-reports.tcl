set dcp [lindex $argv 0]
set outdir [lindex $argv 1]

file mkdir $outdir
open_checkpoint $dcp

report_timing_summary \
    -delay_type min_max -check_timing_verbose \
    -report_unconstrained -max_paths 10 \
    -input_pins -routable_nets \
    -file $outdir/timing-summary.rpt

report_timing \
    -setup -max_paths 100 -nworst 2 -unique_pins \
    -path_type full_clock_expanded -input_pins -routable_nets \
    -file $outdir/worst-setup-paths.rpt

report_design_analysis \
    -timing -setup -show_all -extend -max_paths 100 \
    -file $outdir/design-timing-analysis.rpt

report_design_analysis \
    -congestion -min_congestion_level 3 \
    -file $outdir/congestion.rpt

report_design_analysis \
    -complexity -hierarchical_depth 3 \
    -file $outdir/complexity.rpt

report_high_fanout_nets \
    -timing -load_types \
    -fanout_greater_than 100 -max_nets 100 \
    -file $outdir/high-fanout-load-types.rpt

report_high_fanout_nets \
    -timing -clock_regions \
    -fanout_greater_than 100 -max_nets 100 \
    -file $outdir/high-fanout-clock-regions.rpt

report_high_fanout_nets \
    -timing -slr \
    -fanout_greater_than 100 -max_nets 100 \
    -file $outdir/high-fanout-slr.rpt

report_clock_utilization -file $outdir/clock-utilization.rpt
report_route_status      -file $outdir/route-status.rpt
report_utilization       -hierarchical -file $outdir/utilization.rpt
