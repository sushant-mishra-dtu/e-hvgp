//==========================================================================
// ehvgp_allocator.v -- placement-policy selector (BASELINE vs E-HVGP)
//
// Verilog-2001.
//
// This is the ONLY module whose behaviour differs between the two
// configurations.  Everything else in the core -- ISA, micro-op model,
// VRF, bank count, arbitration, execution resources, free list -- is
// bit-identical.  See docs/ehvgp.md "Fairness".
//
//   EHVGP_ENABLE = 0  BASELINE
//        Fixed round-robin placement with starting-bank rotation:
//        topology = (rr_base, stride 1); after each allocation
//        rr_base <= (rr_base + gsize_dst) mod NUM_BANKS.
//        This is the documented non-strawman baseline from the
//        architecture notes Section 5 ("base rotates per allocation").
//
//   EHVGP_ENABLE = 1  E-HVGP
//        topology = topology_selector(EMUL_dst, EMUL_s1, EMUL_s2, SEW,
//                                     topo(s1), topo(s2))
//        Pure structural function; no occupancy input.
//
// NOTE the baseline degeneracy this targets: rotating by gsize means that
// whenever gsize_dst is a multiple of NUM_BANKS (e.g. a widening result
// with EMUL_dst = 4 and B = 4) the rotation is a NO-OP, so consecutive
// groups of that shape receive IDENTICAL bank sequences and collide on
// every co-read.  That is the structural, EMUL-driven collision described
// in architecture notes Section 2.
//==========================================================================
module ehvgp_allocator #(
   parameter NUM_BANKS     = 4,
   parameter REGS_PER_BANK = 16,
   parameter BID_W         = 2,
   parameter TID_W         = 3,
   parameter SLOT_W        = 4,
   parameter PREG_W        = 6,
   parameter NUM_TOPO      = 8,
   parameter MAX_GROUP     = 8,
   parameter ISSUE_W       = 2,
   parameter EHVGP_ENABLE  = 0
)(
   input  wire              clk,
   input  wire              rst,

   input  wire              alloc_commit,  // 1-cycle pulse: this topology was used
   input  wire [3:0]        gsize_dst,
   input  wire [3:0]        gsize_s1,
   input  wire [3:0]        gsize_s2,
   input  wire              s1_valid,
   input  wire              s2_valid,
   input  wire [TID_W-1:0]  s1_topo,
   input  wire [TID_W-1:0]  s2_topo,
   input  wire [1:0]        sew_log2,
   input  wire              is_widen,
   input  wire              is_narrow,

   output wire [TID_W-1:0]  topo_id,
   output wire [15:0]       sel_cost,
   output wire [BID_W-1:0]  dbg_rr_base
);

   //-----------------------------------------------------------------------
   // Baseline round-robin start-bank pointer
   //-----------------------------------------------------------------------
   reg [BID_W-1:0] rr_base;
   always @(posedge clk or posedge rst) begin
      if (rst)
         rr_base <= {BID_W{1'b0}};
      else if (alloc_commit)
         rr_base <= (rr_base + gsize_dst[BID_W-1:0]);   // mod NUM_BANKS by width
   end
   assign dbg_rr_base = rr_base;

   wire [TID_W-1:0] baseline_topo = {1'b0, rr_base};    // stride = 1

   //-----------------------------------------------------------------------
   // E-HVGP structural selector
   //-----------------------------------------------------------------------
   wire [TID_W-1:0] ehvgp_topo;
   wire [15:0]      ehvgp_cost;

   topology_selector #(
      .NUM_BANKS    (NUM_BANKS),
      .REGS_PER_BANK(REGS_PER_BANK),
      .BID_W        (BID_W),
      .TID_W        (TID_W),
      .SLOT_W       (SLOT_W),
      .PREG_W       (PREG_W),
      .NUM_TOPO     (NUM_TOPO),
      .MAX_GROUP    (MAX_GROUP),
      .ISSUE_W      (ISSUE_W)
   ) u_sel (
      .gsize_dst (gsize_dst),
      .gsize_s1  (gsize_s1),
      .gsize_s2  (gsize_s2),
      .s1_valid  (s1_valid),
      .s2_valid  (s2_valid),
      .s1_topo   (s1_topo),
      .s2_topo   (s2_topo),
      .sew_log2  (sew_log2),
      .is_widen  (is_widen),
      .is_narrow (is_narrow),
      .topo_id   (ehvgp_topo),
      .sel_cost  (ehvgp_cost)
   );

   generate
      if (EHVGP_ENABLE != 0) begin : g_ehvgp
         assign topo_id  = ehvgp_topo;
         assign sel_cost = ehvgp_cost;
      end else begin : g_baseline
         assign topo_id  = baseline_topo;
         assign sel_cost = 16'd0;
      end
   endgenerate

endmodule
