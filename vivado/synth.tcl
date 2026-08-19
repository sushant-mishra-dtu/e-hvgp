#==========================================================================
# synth.tcl -- AMD/Xilinx Vivado out-of-context synthesis of the E-HVGP core
#
#   vivado -mode batch -source vivado/synth.tcl -tclargs 0     # BASELINE
#   vivado -mode batch -source vivado/synth.tcl -tclargs 1     # E-HVGP
#
# Run from the repository root.  Produces vivado/out_<cfg>/ containing
# utilization and timing reports.  Both configurations are synthesised with
# the SAME constraints and the SAME target so the area/timing delta is
# attributable to the placement policy alone.
#==========================================================================

set ehvgp 0
if {$::argc > 0} { set ehvgp [lindex $::argv 0] }
set cfg [expr {$ehvgp ? "ehvgp" : "baseline"}]

set root   [pwd]
set outdir $root/vivado/out_$cfg
file mkdir $outdir

# ---- target device ------------------------------------------------------
# Change to whatever part you actually have; nothing in the RTL is
# device specific.
set part xc7a100tcsg324-1

# ---- sources ------------------------------------------------------------
set srcs [list \
   rtl/core/imem.v \
   rtl/decode/rv_decode.v \
   rtl/decode/rvv_decode.v \
   rtl/e_hvgp/topology_table.v \
   rtl/e_hvgp/bank_mapper.v \
   rtl/e_hvgp/topology_selector.v \
   rtl/e_hvgp/ehvgp_allocator.v \
   rtl/rename/vector_rename.v \
   rtl/vrf/vrf_bank.v \
   rtl/vrf/vrf_arbiter.v \
   rtl/vrf/vrf.v \
   rtl/vector/vector_config.v \
   rtl/vector/vector_alu.v \
   rtl/vector/vector_uop.v \
   rtl/vector/vector_unit.v \
   rtl/core/rv_core.v \
]

read_verilog -library work $srcs
set_property include_dirs [list $root/rtl/common] [current_fileset]

read_xdc vivado/constraints.xdc

# ---- synthesis ----------------------------------------------------------
synth_design -top rv_core -part $part -mode out_of_context \
             -generic EHVGP_ENABLE=$ehvgp

write_checkpoint -force $outdir/post_synth.dcp

report_utilization        -file $outdir/utilization.rpt
report_utilization -hierarchical -file $outdir/utilization_hier.rpt
report_timing_summary     -file $outdir/timing_summary.rpt
report_timing -max_paths 20 -sort_by group -file $outdir/timing_paths.rpt

# ---- Fmax estimate ------------------------------------------------------
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set clk [get_clocks -of_objects [get_ports clk]]
if {[llength $clk] > 0} {
   set period [get_property PERIOD $clk]
   if {$wns ne "" && $wns ne "NA"} {
      set fmax [expr {1000.0 / ($period - $wns)}]
      puts "=================================================="
      puts " config          : $cfg"
      puts " target period   : $period ns"
      puts " WNS             : $wns ns"
      puts " estimated Fmax  : [format %.2f $fmax] MHz"
      puts "=================================================="
      set fh [open $outdir/fmax.txt w]
      puts $fh "config $cfg"
      puts $fh "period $period"
      puts $fh "wns $wns"
      puts $fh "fmax_mhz [format %.2f $fmax]"
      close $fh
   }
}

puts "reports written to $outdir"
