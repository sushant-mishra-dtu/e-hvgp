//==========================================================================
// vector_config.v -- vtype / vl state (vsetvli, vsetvl)
//
// Verilog-2001.
//
// Supported vtype subset (architecture notes Section 7):
//     vsew  : 000 = SEW 8, 001 = SEW 16, 010 = SEW 32
//             011 (SEW 64) -> vill  (ELEN = 32 for source elements; 64-bit
//                                    results only ever arise from widening)
//     vlmul : 000 = LMUL 1, 001 = LMUL 2, 010 = LMUL 4, 011 = LMUL 8
//             fractional LMUL (1xx) -> vill  (deferred, per notes)
//     vta/vma are decoded and stored but the prototype runs VL = VLMAX
//     workloads, so tail/mask policy is never exercised.  See
//     docs/verification.md "Known limitations".
//
//     VLMAX = (VLEN / SEW) * LMUL
//     VL    = min(AVL, VLMAX)
//
// AVL selection:
//     rs1 != x0            -> AVL = x[rs1]
//     rs1 == x0, rd != x0  -> AVL = VLMAX          (set-to-max form)
//     rs1 == x0, rd == x0  -> AVL = VLMAX          (documented deviation:
//                                                   RVV keeps old vl here)
//==========================================================================
module vector_config #(
   parameter VLEN = 128
)(
   input  wire        clk,
   input  wire        rst,

   input  wire        set_valid,
   input  wire [10:0] set_vtype,     // {..., vma, vta, vsew[2:0], vlmul[2:0]}
   input  wire [31:0] set_avl,
   input  wire        avl_is_max,    // rs1 == x0

   output reg  [10:0] vtype,
   output reg  [31:0] vl,
   output reg         vill,
   output wire [1:0]  sew_log2,
   output wire [1:0]  lmul_log2,
   output wire [31:0] vlmax,
   output wire [31:0] next_vl,     // VL this vsetvl* would produce
   output wire        next_vill
);

   wire [2:0] n_vsew  = set_vtype[5:3];
   wire [2:0] n_vlmul = set_vtype[2:0];
   wire       n_vill  = (n_vsew  >= 3'd3) | n_vlmul[2];

   wire [31:0] n_vlmax = (({32'd0, VLEN[15:0]} >> (3 + n_vsew)) << n_vlmul[1:0]);
   wire [31:0] n_avl   = avl_is_max ? n_vlmax : set_avl;
   wire [31:0] n_vl    = (n_avl > n_vlmax) ? n_vlmax : n_avl;

   assign next_vill = n_vill;
   assign next_vl   = n_vill ? 32'd0 : n_vl;

   assign sew_log2  = vtype[4:3];
   assign lmul_log2 = vtype[1:0];
   assign vlmax     = ((32'd0 + VLEN) >> (3 + vtype[5:3])) << vtype[1:0];

   always @(posedge clk or posedge rst) begin
      if (rst) begin
         vtype <= 11'd0;      // SEW=8, LMUL=1
         vl    <= 32'd0;
         vill  <= 1'b0;
      end else if (set_valid) begin
         vtype <= set_vtype;
         vill  <= n_vill;
         vl    <= n_vill ? 32'd0 : n_vl;
      end
   end

endmodule
