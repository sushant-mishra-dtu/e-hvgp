//==========================================================================
// bank_mapper.v -- topology -> (bank, slot, preg) mapping, plus legality
//
// Verilog-2001.  Purely combinational.
//
// This module is the single structural definition of physical placement.
// Both the BASELINE and the E-HVGP configurations use it unchanged; only
// the topology_id fed into it differs.  That is what makes the A/B
// comparison fair (see docs/ehvgp.md, Fairness).
//==========================================================================
module bank_mapper #(
   parameter NUM_BANKS     = 4,
   parameter REGS_PER_BANK = 16,
   parameter BID_W         = 2,
   parameter TID_W         = 3,
   parameter SLOT_W        = 4,
   parameter PREG_W        = 6
)(
   input  wire [TID_W-1:0]  topo_id,
   input  wire [SLOT_W-1:0] base_slot,
   input  wire [3:0]        idx,        // register index within the group
   input  wire [3:0]        gsize,      // group size in physical registers

   output wire [BID_W-1:0]  bank,
   output wire [SLOT_W-1:0] slot,
   output wire [PREG_W-1:0] preg,
   output wire              legal
);

`include "ehvgp_funcs.vh"

   assign bank  = f_bank(topo_id, idx);
   assign slot  = f_slot(base_slot, idx);
   assign preg  = f_preg(topo_id, base_slot, idx);
   assign legal = f_topo_legal(topo_id, gsize);

endmodule
