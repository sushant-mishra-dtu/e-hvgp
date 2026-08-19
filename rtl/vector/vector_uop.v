//==========================================================================
// vector_uop.v -- micro-op expansion field computation
//
// Verilog-2001.  Purely combinational.
//
//--------------------------------------------------------------------------
// MICRO-OP MODEL  (identical in BASELINE and E-HVGP)
//--------------------------------------------------------------------------
// Register-granularity decomposition (architecture notes Section 5.1,
// recommended option): ONE micro-op per DESTINATION physical register.
//
//   number of micro-ops = EMUL_dst (in registers), clipped by VL
//
//   same-width  (EMUL_d = EMUL_s1 = EMUL_s2 = LMUL)
//        uop i : reads vs1[i], vs2[i]              -> 2 VRF reads
//                writes vd[i]                      -> 1 VRF write
//
//   widening    (EMUL_d = 2*LMUL)
//        uop i : reads vs1[i>>1], vs2[i>>1]        -> 2 VRF reads
//                half_sel = i[0] selects which half of the source
//                registers' elements are consumed
//                writes vd[i]                      -> 1 VRF write
//
//   narrowing   (EMUL_s2 = 2*LMUL)
//        uop i : reads vs1[i], vs2[2i], vs2[2i+1]  -> 3 VRF reads
//                writes vd[i]                      -> 1 VRF write
//
//   vmv.v.v     uop i : reads vs1[i]               -> 1 VRF read
//
// The asymmetric read counts are the direct structural consequence of
// EMUL != LMUL and are exactly what the experiment measures.
//==========================================================================
module vector_uop #(
   parameter PREG_W    = 6,
   parameter MAX_GROUP = 8
)(
   input  wire [3:0]                  uidx,        // micro-op index in group
   input  wire                        is_widen,
   input  wire                        is_narrow,
   input  wire                        s1_used,
   input  wire                        s2_used,
   input  wire [MAX_GROUP*PREG_W-1:0] dst_pregs,
   input  wire [MAX_GROUP*PREG_W-1:0] s1_pregs,
   input  wire [MAX_GROUP*PREG_W-1:0] s2_pregs,

   output wire                        half_sel,
   output wire                        s0_v,
   output wire [PREG_W-1:0]           s0_preg,
   output wire                        s1_v,
   output wire [PREG_W-1:0]           s1_preg,
   output wire                        s2_v,
   output wire [PREG_W-1:0]           s2_preg,
   output wire [PREG_W-1:0]           d_preg
);

   // Narrowing can only occur with EMUL_s2 = 2*LMUL <= MAX_GROUP, i.e.
   // uidx <= 3, so 2*uidx+1 <= 7.  The masks below make that bound explicit
   // so no part-select can ever run off the end of the group vectors.
   wire [2:0] i_s1    = is_widen ? uidx[3:1] : uidx[2:0];
   wire [2:0] i_s2_lo = is_narrow ? {uidx[1:0], 1'b0} :
                        (is_widen ? uidx[3:1] : uidx[2:0]);
   wire [2:0] i_s2_hi = {uidx[1:0], 1'b0} | 3'd1;

   assign half_sel = is_widen ? uidx[0] : 1'b0;

   assign s0_v     = s1_used;
   assign s0_preg  = s1_pregs[i_s1     * PREG_W +: PREG_W];
   assign s1_v     = s2_used;
   assign s1_preg  = s2_pregs[i_s2_lo  * PREG_W +: PREG_W];
   assign s2_v     = is_narrow & s2_used;
   assign s2_preg  = s2_pregs[i_s2_hi  * PREG_W +: PREG_W];
   assign d_preg   = dst_pregs[uidx[2:0] * PREG_W +: PREG_W];

endmodule
