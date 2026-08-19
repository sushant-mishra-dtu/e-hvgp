#==========================================================================
# constraints.xdc -- minimal out-of-context constraints
#
# 100 MHz starting target.  This is a research prototype: the topology
# selector is a fully combinational exhaustive search over the topology
# space and is expected to be the critical path.  Do not optimise for PPA
# before the functional experiment is settled (project brief Section 22).
#==========================================================================

create_clock -period 10.000 -name clk [get_ports clk]

set_input_delay  -clock clk 2.000 [get_ports rst]
set_output_delay -clock clk 2.000 [get_ports halted]

# Performance counters and debug ports are observation-only.
set_false_path -to   [get_ports {cycle_count[*] instr_count[*] vinstr_count[*]}]
set_false_path -to   [get_ports {vuop_count[*] vrf_read_requests[*] vrf_write_requests[*]}]
set_false_path -to   [get_ports {bank_conflict_count[*] bank_read_conflicts[*]}]
set_false_path -to   [get_ports {bank_write_conflicts[*] bank_stall_cycles[*]}]
set_false_path -to   [get_ports {widening_count[*] narrowing_count[*] rename_stall_cycles[*]}]
set_false_path -to   [get_ports {topo_alloc[*]}]
set_false_path -from [get_ports {dbg_arch[*] dbg_xreg[*]}]
set_false_path -to   [get_ports {dbg_preg[*] dbg_topo[*] dbg_slot[*] dbg_idx[*]}]
set_false_path -to   [get_ports {dbg_vdata[*] dbg_vtype[*] dbg_vl[*] dbg_vill dbg_pc[*] dbg_xdata[*]}]
