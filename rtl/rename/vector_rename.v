//==========================================================================
// vector_rename.v -- vector RAT + physical free list + group allocator
//
// Verilog-2001.
//
//--------------------------------------------------------------------------
// RAT FORM (architecture notes Section 6 / Section 13)
//--------------------------------------------------------------------------
// The notes recommend "physical_base_id + topology_id" instead of an
// explicit per-register physical list.  This implementation stores, per
// ARCHITECTURAL vector register:
//
//     rat_slot[a]  physical base slot of the group that last wrote a
//     rat_topo[a]  topology id      of that group
//     rat_idx [a]  a's index within that group
//
// so preg(a) = f_preg(rat_topo[a], rat_slot[a], rat_idx[a]) is DERIVED,
// never stored.  Total RAT state is (SLOT_W + TID_W + IDX_W) bits per
// architectural register (4+3+3 = 10 bits here) instead of a physical
// register list.  The extra rat_idx field over the notes' pure
// (base, topology) pair is what makes overlapping/re-aliased groups (e.g.
// a size-2 group written on top of registers covered by an older size-4
// group) resolve correctly; it costs 3 bits and removes a whole class of
// architectural corner cases.  Documented in docs/architecture.md.
//
//--------------------------------------------------------------------------
// FREE LIST
//--------------------------------------------------------------------------
// One free bit per physical register.  Allocating a group of G registers
// with topology t requires a base slot s such that all G derived physical
// registers are free.  The search is a lowest-slot-first scan; it is
// IDENTICAL in both configurations, so any behavioural difference comes
// from the topology, never from the allocation search.
//==========================================================================
module vector_rename #(
   parameter VLEN          = 128,
   parameter NUM_BANKS     = 4,
   parameter REGS_PER_BANK = 16,
   parameter NUM_PHYS      = 64,
   parameter NUM_ARCH      = 32,
   parameter BID_W         = 2,
   parameter TID_W         = 3,
   parameter SLOT_W        = 4,
   parameter PREG_W        = 6,
   parameter IDX_W         = 3,
   parameter MAX_GROUP     = 8,
   parameter NUM_TOPO      = 8,
   parameter ISSUE_W       = 2,
   parameter EHVGP_ENABLE  = 0
)(
   input  wire                        clk,
   input  wire                        rst,

   // rename request (combinational query; committed by do_alloc)
   input  wire [4:0]                  vd,
   input  wire [4:0]                  vs1,
   input  wire [4:0]                  vs2,
   input  wire [3:0]                  g_dst,
   input  wire [3:0]                  g_s1,
   input  wire [3:0]                  g_s2,
   input  wire                        s1_used,
   input  wire                        s2_used,
   input  wire [1:0]                  sew_log2,
   input  wire                        is_widen,
   input  wire                        is_narrow,
   input  wire                        do_alloc,

   output wire                        alloc_ok,
   output wire [MAX_GROUP*PREG_W-1:0] dst_pregs,
   output wire [MAX_GROUP*PREG_W-1:0] s1_pregs,
   output wire [MAX_GROUP*PREG_W-1:0] s2_pregs,
   output reg  [NUM_PHYS-1:0]         old_free_mask,
   output wire [TID_W-1:0]            sel_topo,
   output wire [SLOT_W-1:0]           sel_slot,
   output wire [15:0]                 sel_cost,

   // physical register release (from commit)
   input  wire                        free_valid,
   input  wire [NUM_PHYS-1:0]         free_mask,

   // debug / architectural-state dump
   input  wire [4:0]                  dbg_arch,
   output wire [PREG_W-1:0]           dbg_preg,
   output wire [TID_W-1:0]            dbg_topo,
   output wire [SLOT_W-1:0]           dbg_slot,
   output wire [IDX_W-1:0]            dbg_idx,
   output wire [NUM_PHYS-1:0]         dbg_free_vec,
   output wire [BID_W-1:0]            dbg_rr_base
);

`include "ehvgp_funcs.vh"

   //-----------------------------------------------------------------------
   // State
   //-----------------------------------------------------------------------
   reg [SLOT_W-1:0]  rat_slot [0:NUM_ARCH-1];
   reg [TID_W-1:0]   rat_topo [0:NUM_ARCH-1];
   reg [IDX_W-1:0]   rat_idx  [0:NUM_ARCH-1];
   reg [NUM_PHYS-1:0] free_vec;

   assign dbg_free_vec = free_vec;
   assign dbg_topo     = rat_topo[dbg_arch];
   assign dbg_slot     = rat_slot[dbg_arch];
   assign dbg_idx      = rat_idx [dbg_arch];
   assign dbg_preg     = f_preg(rat_topo[dbg_arch], rat_slot[dbg_arch],
                                {1'b0, rat_idx[dbg_arch]});

   //-----------------------------------------------------------------------
   // Source physical register lookup (snapshotted at rename)
   //-----------------------------------------------------------------------
   wire [4:0] a1 [0:MAX_GROUP-1];
   wire [4:0] a2 [0:MAX_GROUP-1];

   genvar gk;
   generate
      for (gk = 0; gk < MAX_GROUP; gk = gk + 1) begin : g_src
         assign a1[gk] = vs1 + gk[4:0];
         assign a2[gk] = vs2 + gk[4:0];
         assign s1_pregs[gk*PREG_W +: PREG_W] =
                f_preg(rat_topo[a1[gk]], rat_slot[a1[gk]], {1'b0, rat_idx[a1[gk]]});
         assign s2_pregs[gk*PREG_W +: PREG_W] =
                f_preg(rat_topo[a2[gk]], rat_slot[a2[gk]], {1'b0, rat_idx[a2[gk]]});
      end
   endgenerate

   //-----------------------------------------------------------------------
   // Topology selection: BASELINE round-robin vs E-HVGP structural selector
   //-----------------------------------------------------------------------
   ehvgp_allocator #(
      .NUM_BANKS    (NUM_BANKS),
      .REGS_PER_BANK(REGS_PER_BANK),
      .BID_W        (BID_W),
      .TID_W        (TID_W),
      .SLOT_W       (SLOT_W),
      .PREG_W       (PREG_W),
      .NUM_TOPO     (NUM_TOPO),
      .MAX_GROUP    (MAX_GROUP),
      .ISSUE_W      (ISSUE_W),
      .EHVGP_ENABLE (EHVGP_ENABLE)
   ) u_alloc_policy (
      .clk          (clk),
      .rst          (rst),
      .alloc_commit (do_alloc),
      .gsize_dst    (g_dst),
      .gsize_s1     (g_s1),
      .gsize_s2     (g_s2),
      .s1_valid     (s1_used),
      .s2_valid     (s2_used),
      .s1_topo      (rat_topo[vs1]),
      .s2_topo      (rat_topo[vs2]),
      .sew_log2     (sew_log2),
      .is_widen     (is_widen),
      .is_narrow    (is_narrow),
      .topo_id      (sel_topo),
      .sel_cost     (sel_cost),
      .dbg_rr_base  (dbg_rr_base)
   );

   //-----------------------------------------------------------------------
   // Physical group allocation: lowest base slot that fits
   //-----------------------------------------------------------------------
   integer            s, i;
   reg                ok;
   reg                found;
   reg [SLOT_W-1:0]   fslot;
   reg [PREG_W-1:0]   p;
   reg [15:0]         top_slot;

   always @(*) begin
      found = 1'b0;
      fslot = {SLOT_W{1'b0}};
      // reverse scan so the LOWEST feasible slot ends up latched
      for (s = REGS_PER_BANK-1; s >= 0; s = s - 1) begin
         ok       = 1'b1;
         top_slot = s + ((g_dst - 1) / NUM_BANKS);
         if (top_slot >= REGS_PER_BANK) ok = 1'b0;
         for (i = 0; i < MAX_GROUP; i = i + 1)
            if (i < g_dst) begin
               p = f_preg(sel_topo, s[SLOT_W-1:0], i[3:0]);
               if (!free_vec[p]) ok = 1'b0;
            end
         if (ok) begin
            found = 1'b1;
            fslot = s[SLOT_W-1:0];
         end
      end
   end

   assign alloc_ok = found;
   assign sel_slot = fslot;

   generate
      for (gk = 0; gk < MAX_GROUP; gk = gk + 1) begin : g_dstp
         assign dst_pregs[gk*PREG_W +: PREG_W] = f_preg(sel_topo, fslot, gk[3:0]);
      end
   endgenerate

   //-----------------------------------------------------------------------
   // Masks: newly allocated pregs, and the previous mapping being displaced
   //-----------------------------------------------------------------------
   reg [NUM_PHYS-1:0] alloc_mask;
   integer            j;
   reg [4:0]          ad;

   always @(*) begin
      alloc_mask    = {NUM_PHYS{1'b0}};
      old_free_mask = {NUM_PHYS{1'b0}};
      for (j = 0; j < MAX_GROUP; j = j + 1)
         if (j < g_dst) begin
            ad = vd + j[4:0];
            alloc_mask[f_preg(sel_topo, fslot, j[3:0])] = 1'b1;
            old_free_mask[f_preg(rat_topo[ad], rat_slot[ad], {1'b0, rat_idx[ad]})] = 1'b1;
         end
   end

   //-----------------------------------------------------------------------
   // State update
   //-----------------------------------------------------------------------
   integer            r;
   reg [NUM_PHYS-1:0] init_free;

   always @(posedge clk or posedge rst) begin
      if (rst) begin
         for (r = 0; r < NUM_ARCH; r = r + 1) begin
            rat_slot[r] <= r / NUM_BANKS;
            rat_topo[r] <= {1'b0, r[BID_W-1:0]};   // start = r mod B, stride 1
            rat_idx [r] <= {IDX_W{1'b0}};
         end
         // architectural v0..v31 occupy slots 0 .. (NUM_ARCH/NUM_BANKS - 1)
         // of every bank; everything above that is free.  Balanced across
         // banks so neither configuration starts with a bank advantage.
         for (r = 0; r < NUM_PHYS; r = r + 1)
            init_free[r] = (f_preg_slot(r[PREG_W-1:0]) >= (NUM_ARCH/NUM_BANKS));
         free_vec <= init_free;
      end else begin
         if (do_alloc) begin
            for (r = 0; r < MAX_GROUP; r = r + 1)
               if (r < g_dst) begin
                  rat_slot[vd + r[4:0]] <= fslot;
                  rat_topo[vd + r[4:0]] <= sel_topo;
                  rat_idx [vd + r[4:0]] <= r[IDX_W-1:0];
               end
         end
         free_vec <= (free_vec & ~(do_alloc ? alloc_mask : {NUM_PHYS{1'b0}}))
                   | (free_valid ? free_mask : {NUM_PHYS{1'b0}});
      end
   end

//==========================================================================
// Simulation-only checks and tracing (Verilog-2001, no SVA)
//==========================================================================
// synthesis translate_off
   integer ck_i, ck_j;
   reg     trace_on;

   initial trace_on = $test$plusargs("TRACE");

   always @(posedge clk) begin
      if (!rst && do_alloc) begin
         // 1. the selected topology must be legal for this group size
         if (!f_topo_legal(sel_topo, g_dst)) begin
            $display("[ASSERT-FAIL %0t] illegal topology %0d for group size %0d",
                     $time, sel_topo, g_dst);
            $fatal;
         end
         // 2. every allocated physical register must have been free
         for (ck_i = 0; ck_i < MAX_GROUP; ck_i = ck_i + 1)
            if (ck_i < g_dst)
               if (!free_vec[f_preg(sel_topo, fslot, ck_i[3:0])]) begin
                  $display("[ASSERT-FAIL %0t] allocating busy preg %0d",
                           $time, f_preg(sel_topo, fslot, ck_i[3:0]));
                  $fatal;
               end
         // 3. the group's physical registers must be pairwise distinct
         for (ck_i = 0; ck_i < MAX_GROUP; ck_i = ck_i + 1)
            for (ck_j = 0; ck_j < MAX_GROUP; ck_j = ck_j + 1)
               if ((ck_i < ck_j) && (ck_j < g_dst))
                  if (f_preg(sel_topo, fslot, ck_i[3:0]) ==
                      f_preg(sel_topo, fslot, ck_j[3:0])) begin
                     $display("[ASSERT-FAIL %0t] duplicate preg in group", $time);
                     $fatal;
                  end

         if (trace_on)
            $display("[ALLOC %0t] vd=v%0d G=%0d topo=%0d(start=%0d,stride=%0d) slot=%0d | s1=v%0d topo=%0d G=%0d | s2=v%0d topo=%0d G=%0d | wid=%0d nar=%0d cost=%0d",
                     $time, vd, g_dst, sel_topo, sel_topo[BID_W-1:0],
                     sel_topo[TID_W-1] ? (NUM_BANKS-1) : 1, fslot,
                     vs1, rat_topo[vs1], g_s1, vs2, rat_topo[vs2], g_s2,
                     is_widen, is_narrow, sel_cost);
      end
   end
// synthesis translate_on

endmodule
