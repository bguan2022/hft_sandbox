# ============================================================================
# build.tcl - synthesize and place & route the LMD design for the VCU118
#
#   vivado -mode batch -nojournal -source vivado/build.tcl
#   vivado -mode batch -nojournal -source vivado/build.tcl -tclargs synth
#   vivado -mode batch -nojournal -source vivado/build.tcl -tclargs impl lmd_rx_top
#
# Target: AMD/Xilinx VCU118, Virtex UltraScale+ XCVU9P (xcvu9p-flga2104-2L-e).
# Runs out-of-context (no I/O buffers), which is how the decoder is
# characterized before it is integrated behind the Ethernet MAC.
# Outputs: vivado/out/{*.dcp, *_utilization.rpt, *_timing.rpt}
# ============================================================================

set part   xcvu9p-flga2104-2L-e
set stage  [expr {$argc > 0 ? [lindex $argv 0] : "impl"}]             ;# synth | impl
set top    [expr {$argc > 1 ? [lindex $argv 1] : "lmd_trader_top"}]   ;# or lmd_rx_top

set root    [file dirname [file dirname [file normalize [info script]]]]
set out_dir [file join $root vivado out]
file mkdir $out_dir

# ---- sources
read_verilog -sv [lsort [glob [file join $root rtl *.sv]]]
read_xdc -mode out_of_context [file join $root constraints lmd_ooc.xdc]

# ---- synthesis
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt
write_checkpoint -force [file join $out_dir ${top}_synth.dcp]
report_utilization    -file [file join $out_dir ${top}_synth_utilization.rpt]
report_timing_summary -file [file join $out_dir ${top}_synth_timing.rpt]

proc check_timing_met {label} {
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "INFO: $label worst setup slack = $wns ns"
    if {$wns ne "" && $wns < 0} {
        puts "CRITICAL WARNING: $label timing not met"
    }
}
check_timing_met "post-synthesis"

if {$stage eq "synth"} { return }

# ---- implementation
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out_dir ${top}_routed.dcp]
report_utilization    -file [file join $out_dir ${top}_routed_utilization.rpt]
report_timing_summary -file [file join $out_dir ${top}_routed_timing.rpt]
check_timing_met "post-route"
