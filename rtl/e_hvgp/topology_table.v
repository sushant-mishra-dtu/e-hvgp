//==========================================================================
// topology_table.v  -- (start_bank, stride) topology table
//
// Verilog-2001.  Purely combinational.
//
// Topology space for NUM_BANKS = 4 (TID_W = 3, NUM_TOPO = 8):
//
//   id  start  stride     bank sequence (i = 0..3)
//   --  -----  ------     ------------------------
//    0    0      1        0 1 2 3
//    1    1      1        1 2 3 0
//    2    2      1        2 3 0 1
//    3    3      1        3 0 1 2
//    4    0      3        0 3 2 1
//    5    1      3        1 0 3 2
//    6    2      3        2 1 0 3
//    7    3      3        3 2 1 0
//
// Note: for a group of G = NUM_BANKS registers stride 1 and stride B-1 use
// the same bank SET, only a different ORDER -- which still matters because
// accesses are issued in index order in windows of ISSUE_W.  For G < B the
// two strides produce genuinely different bank SETS (e.g. G=2, start=0:
// {0,1} vs {0,3}).  That is the second degree of freedom the architecture
// notes (Section 6.1) identify as the non-prior-art part of the mechanism.
//==========================================================================
module topology_table #(
   parameter NUM_BANKS = 4,
   parameter BID_W     = 2,
   parameter TID_W     = 3
)(
   input  wire [TID_W-1:0] topo_id,
   output wire [BID_W-1:0] start_bank,
   output wire [BID_W-1:0] stride
);

   assign start_bank = topo_id[BID_W-1:0];
   assign stride     = topo_id[TID_W-1] ? (NUM_BANKS-1) : 1;

endmodule
