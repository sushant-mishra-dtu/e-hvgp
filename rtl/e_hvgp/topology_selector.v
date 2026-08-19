//==========================================================================
// topology_selector.v -- E-HVGP topology selection policy (v1)
//
// Verilog-2001.  Purely combinational.
//
//--------------------------------------------------------------------------
// WHAT THIS MODULE IS
//--------------------------------------------------------------------------
// At Rename/Allocate, when a NEW destination vector register group is
// created, this block picks the (start_bank, stride) topology the group
// will be placed with.
//
// Per architecture notes Section 11.4, v1 selection is a PURE FUNCTION of
// structural rename-time information:
//
//     ( EMUL_dst, EMUL_s1, EMUL_s2, SEW, topo(s1), topo(s2) )
//
// There is NO runtime bank-occupancy input, NO bank-busy counters and NO
// allocation history.  That keeps the research claim ("structural, EMUL-
// derived topology selection") separable from prior-art dynamic bank-aware
// allocation.  Occupancy-based tie-breaking is deliberately deferred.
//
//--------------------------------------------------------------------------
// WHY SOURCE TOPOLOGIES ARE AN INPUT (and why that is not "occupancy")
//--------------------------------------------------------------------------
// Architecture notes Section 4 [ARCHITECTURAL CONCERN]: a physical vector
// register's bank is fixed when it is allocated as a DESTINATION and only
// read later as a source.  So the destination topology chosen now has no
// effect on the current instruction's reads -- its only leverage is on the
// FUTURE reads of this group.  The only structural predictor of "what will
// this group be read alongside" available at rename, with zero new state,
// is the current instruction's own source groups (dependence chains
// overwhelmingly re-read the producer's siblings).  topo(s1)/topo(s2) are
// rename-map state, not runtime history.
//
//--------------------------------------------------------------------------
// COST FUNCTION
//--------------------------------------------------------------------------
// For each candidate topology t:
//
//   D[i] = bank of destination register i under t
//   S[j] = bank of register j of the REFERENCE source group (the source
//          with the larger EMUL; s1 on a tie)
//
//   Projected consumer: a later same-width instruction that reads this
//   group together with the reference source group, issuing ISSUE_W micro-
//   ops per cycle (exactly the machine's real operand-collect width).
//   For each window of ISSUE_W consecutive micro-ops, gather the read
//   requests {D[i], S[i & (Gs-1)]} and count
//
//        conflicts = n_requests - n_distinct_banks
//
//   coread_cost(t) = sum of that over all windows.
//
//   stride_class(t): EMUL-derived preference.  A group whose EMUL_dst is
//   LARGER than its sources' EMUL (a widening result) is preferentially
//   given stride NUM_BANKS-1; every other group prefers stride 1.  This
//   decorrelates the bank sequence of a 2*LMUL group from the LMUL groups
//   it will be read against -- the exact EMUL != LMUL case the mechanism
//   targets (architecture notes Section 2).
//
//   start_penalty(t): +1 per source group whose start_bank equals t's.
//
//   total(t) = W_PRED*coread_cost + W_CLASS*stride_mismatch + start_penalty
//              + ILLEGAL_COST*(!legal)
//
// Selection = argmin(total), lowest topology id on a tie.  Fully
// deterministic; identical inputs always give identical output.
//
//--------------------------------------------------------------------------
// NOTE ON SEW
//--------------------------------------------------------------------------
// sew_log2 is an input for completeness and for waveform/debug visibility,
// but under REGISTER-granularity banking (architecture notes Section 1 and
// Section 11.1) SEW influences placement only through EMUL: the number of
// physical registers in a group is EMUL, independent of SEW.  This is an
// honest structural finding, documented in docs/ehvgp.md, not an omission.
//==========================================================================
module topology_selector #(
   parameter NUM_BANKS     = 4,
   parameter REGS_PER_BANK = 16,
   parameter BID_W         = 2,
   parameter TID_W         = 3,
   parameter SLOT_W        = 4,
   parameter PREG_W        = 6,
   parameter NUM_TOPO      = 8,
   parameter MAX_GROUP     = 8,
   parameter ISSUE_W       = 2,
   // cost weights
   parameter W_PRED        = 4,
   parameter W_CLASS       = 2,
   parameter ILLEGAL_COST  = 1024
)(
   input  wire [3:0]        gsize_dst,   // EMUL_dst in physical registers
   input  wire [3:0]        gsize_s1,    // EMUL of vs1 group (0 if unused)
   input  wire [3:0]        gsize_s2,    // EMUL of vs2 group (0 if unused)
   input  wire              s1_valid,
   input  wire              s2_valid,
   input  wire [TID_W-1:0]  s1_topo,
   input  wire [TID_W-1:0]  s2_topo,
   input  wire [1:0]        sew_log2,    // 0:SEW8 1:SEW16 2:SEW32  (debug/doc)
   input  wire              is_widen,    // EMUL_dst > EMUL_src
   input  wire              is_narrow,   // EMUL_s2  > EMUL_dst

   output reg  [TID_W-1:0]  topo_id,
   output reg  [15:0]       sel_cost     // cost of the winner (debug)
);

`include "ehvgp_funcs.vh"

   //-----------------------------------------------------------------------
   // Reference source group: the one with the larger EMUL (s1 on a tie).
   //-----------------------------------------------------------------------
   wire              ref_valid = s1_valid | s2_valid;
   wire              use_s2    = s2_valid & (~s1_valid | (gsize_s2 > gsize_s1));
   wire [TID_W-1:0]  ref_topo  = use_s2 ? s2_topo  : s1_topo;
   wire [3:0]        ref_gsize = use_s2 ? gsize_s2 : gsize_s1;
   wire [3:0]        ref_mask  = (ref_gsize == 0) ? 4'd0 : (ref_gsize - 4'd1);

   wire [BID_W-1:0]  s1_start  = s1_topo[BID_W-1:0];
   wire [BID_W-1:0]  s2_start  = s2_topo[BID_W-1:0];

   // EMUL-derived stride class
   wire              want_stride_hi = is_widen;

   //-----------------------------------------------------------------------
   // Exhaustive cost evaluation over the (small) topology space
   //-----------------------------------------------------------------------
   integer                 t;
   integer                 w;
   integer                 u;
   integer                 bcnt;
   reg [TID_W-1:0]         tid;
   reg [3:0]               idx;
   reg [NUM_BANKS-1:0]     bmask;
   reg [7:0]               nreq;
   reg [7:0]               ndist;
   reg [15:0]              coread;
   reg [15:0]              total;
   reg [15:0]              best_cost;
   reg [TID_W-1:0]         best_id;
   reg                     lg;

   always @(*) begin
      best_cost = 16'hFFFF;
      best_id   = {TID_W{1'b0}};

      for (t = 0; t < NUM_TOPO; t = t + 1) begin
         tid    = t[TID_W-1:0];
         lg     = f_topo_legal(tid, gsize_dst);
         coread = 16'd0;

         // walk the destination group in operand-collect windows
         for (w = 0; w < MAX_GROUP; w = w + ISSUE_W) begin
            bmask = {NUM_BANKS{1'b0}};
            nreq  = 8'd0;
            for (u = 0; u < ISSUE_W; u = u + 1) begin
               idx = (w + u);
               if ((w + u) < gsize_dst) begin
                  // destination group read request
                  bmask[f_bank(tid, idx)] = 1'b1;
                  nreq = nreq + 8'd1;
                  // co-read request from the reference source group
                  if (ref_valid) begin
                     bmask[f_bank(ref_topo, idx & ref_mask)] = 1'b1;
                     nreq = nreq + 8'd1;
                  end
               end
            end
            ndist = 8'd0;
            for (bcnt = 0; bcnt < NUM_BANKS; bcnt = bcnt + 1)
               if (bmask[bcnt]) ndist = ndist + 8'd1;
            coread = coread + {8'd0, (nreq - ndist)};
         end

         total = W_PRED * coread;
         if ((tid[TID_W-1] ? 1'b1 : 1'b0) != want_stride_hi)
            total = total + W_CLASS;
         if (s1_valid && (tid[BID_W-1:0] == s1_start)) total = total + 16'd1;
         if (s2_valid && (tid[BID_W-1:0] == s2_start)) total = total + 16'd1;
         if (!lg) total = total + ILLEGAL_COST;

         if (total < best_cost) begin
            best_cost = total;
            best_id   = tid;
         end
      end

      topo_id  = best_id;
      sel_cost = best_cost;
   end

   // is_narrow / sew_log2 are structural context inputs; under register-
   // granularity banking they influence placement only via gsize_*.  Keep
   // them referenced so they stay visible in SimVision and are not pruned.
   // synthesis translate_off
   wire _unused = is_narrow | (|sew_log2);
   // synthesis translate_on

endmodule
