//==========================================================================
// vector_alu.v -- one-physical-register-wide vector ALU
//
// Verilog-2001.  Purely combinational.
//
// Operates on ONE destination physical register (VLEN bits) per micro-op,
// matching the register-granularity micro-op model (architecture notes
// Section 5.1, register-granularity decomposition).
//
// Operand naming follows RVV .vv encoding:
//     opa = vs1
//     opb = vs2            (widening/same-width) or vs2 low  half (narrowing)
//     opc = vs2 high half  (narrowing only)
//
// sew_log2 is the vtype SEW, i.e. the NARROWER width in both the widening
// and narrowing cases, exactly as RVV defines it:
//     same-width : src EEW = dst EEW = SEW
//     widening   : src EEW = SEW,   dst EEW = 2*SEW
//     narrowing  : src EEW = 2*SEW, dst EEW = SEW
//
// half_sel selects which half of the source registers a widening micro-op
// consumes (dst register i of a 2*EMUL group consumes half i[0] of source
// register i>>1).
//==========================================================================
`include "ehvgp_defs.vh"

module vector_alu #(
   parameter VLEN = 128
)(
   input  wire [3:0]      vop,
   input  wire [1:0]      sew_log2,     // 0:SEW=8  1:SEW=16  2:SEW=32
   input  wire            half_sel,
   input  wire [VLEN-1:0] opa,
   input  wire [VLEN-1:0] opb,
   input  wire [VLEN-1:0] opc,
   output reg  [VLEN-1:0] res
);

   integer            k;
   integer            si;
   reg signed [63:0]  sa, sb;
   reg        [63:0]  ua, ub;
   reg        [63:0]  wide;
   reg        [63:0]  prod;
   reg        [5:0]   sh;

   always @(*) begin
      res  = {VLEN{1'b0}};
      sa   = 64'd0;  sb = 64'd0;
      ua   = 64'd0;  ub = 64'd0;
      wide = 64'd0;  prod = 64'd0;  sh = 6'd0;
      si   = 0;

      case (sew_log2)
      //=================================================================
      // SEW = 8
      //=================================================================
      2'd0: begin
         case (vop)
         `VOP_ADD : for (k=0;k<VLEN/8;k=k+1) res[k*8 +: 8] = opb[k*8 +: 8] + opa[k*8 +: 8];
         `VOP_SUB : for (k=0;k<VLEN/8;k=k+1) res[k*8 +: 8] = opb[k*8 +: 8] - opa[k*8 +: 8];
         `VOP_MV  : res = opa;

         `VOP_WADD, `VOP_WADDU, `VOP_WSUB, `VOP_WMUL, `VOP_WMULU:
            for (k=0;k<VLEN/16;k=k+1) begin
               si = (half_sel ? (VLEN/16) : 0) + k;
               sa = {{56{opa[si*8+7]}}, opa[si*8 +: 8]};
               sb = {{56{opb[si*8+7]}}, opb[si*8 +: 8]};
               ua = {56'd0, opa[si*8 +: 8]};
               ub = {56'd0, opb[si*8 +: 8]};
               case (vop)
               `VOP_WADD : prod = sb + sa;
               `VOP_WSUB : prod = sb - sa;
               `VOP_WADDU: prod = ub + ua;
               `VOP_WMUL : prod = sb * sa;
               default   : prod = ub * ua;      // VOP_WMULU
               endcase
               res[k*16 +: 16] = prod[15:0];
            end

         `VOP_NSRL, `VOP_NSRA:
            for (k=0;k<VLEN/8;k=k+1) begin
               if (k < (VLEN/16)) wide = {48'd0, opb[k*16 +: 16]};
               else               wide = {48'd0, opc[(k-(VLEN/16))*16 +: 16]};
               sh = {2'd0, opa[k*8 +: 4]};                  // log2(2*SEW)=4
               if (vop == `VOP_NSRA)
                  res[k*8 +: 8] = $signed({{48{wide[15]}}, wide[15:0]}) >>> sh;
               else
                  res[k*8 +: 8] = wide[15:0] >> sh;
            end

         default : res = {VLEN{1'b0}};
         endcase
      end

      //=================================================================
      // SEW = 16
      //=================================================================
      2'd1: begin
         case (vop)
         `VOP_ADD : for (k=0;k<VLEN/16;k=k+1) res[k*16 +: 16] = opb[k*16 +: 16] + opa[k*16 +: 16];
         `VOP_SUB : for (k=0;k<VLEN/16;k=k+1) res[k*16 +: 16] = opb[k*16 +: 16] - opa[k*16 +: 16];
         `VOP_MV  : res = opa;

         `VOP_WADD, `VOP_WADDU, `VOP_WSUB, `VOP_WMUL, `VOP_WMULU:
            for (k=0;k<VLEN/32;k=k+1) begin
               si = (half_sel ? (VLEN/32) : 0) + k;
               sa = {{48{opa[si*16+15]}}, opa[si*16 +: 16]};
               sb = {{48{opb[si*16+15]}}, opb[si*16 +: 16]};
               ua = {48'd0, opa[si*16 +: 16]};
               ub = {48'd0, opb[si*16 +: 16]};
               case (vop)
               `VOP_WADD : prod = sb + sa;
               `VOP_WSUB : prod = sb - sa;
               `VOP_WADDU: prod = ub + ua;
               `VOP_WMUL : prod = sb * sa;
               default   : prod = ub * ua;
               endcase
               res[k*32 +: 32] = prod[31:0];
            end

         `VOP_NSRL, `VOP_NSRA:
            for (k=0;k<VLEN/16;k=k+1) begin
               if (k < (VLEN/32)) wide = {32'd0, opb[k*32 +: 32]};
               else               wide = {32'd0, opc[(k-(VLEN/32))*32 +: 32]};
               sh = {1'b0, opa[k*16 +: 5]};                 // log2(2*SEW)=5
               if (vop == `VOP_NSRA)
                  res[k*16 +: 16] = $signed({{32{wide[31]}}, wide[31:0]}) >>> sh;
               else
                  res[k*16 +: 16] = wide[31:0] >> sh;
            end

         default : res = {VLEN{1'b0}};
         endcase
      end

      //=================================================================
      // SEW = 32
      //=================================================================
      default: begin
         case (vop)
         `VOP_ADD : for (k=0;k<VLEN/32;k=k+1) res[k*32 +: 32] = opb[k*32 +: 32] + opa[k*32 +: 32];
         `VOP_SUB : for (k=0;k<VLEN/32;k=k+1) res[k*32 +: 32] = opb[k*32 +: 32] - opa[k*32 +: 32];
         `VOP_MV  : res = opa;

         `VOP_WADD, `VOP_WADDU, `VOP_WSUB, `VOP_WMUL, `VOP_WMULU:
            for (k=0;k<VLEN/64;k=k+1) begin
               si = (half_sel ? (VLEN/64) : 0) + k;
               sa = {{32{opa[si*32+31]}}, opa[si*32 +: 32]};
               sb = {{32{opb[si*32+31]}}, opb[si*32 +: 32]};
               ua = {32'd0, opa[si*32 +: 32]};
               ub = {32'd0, opb[si*32 +: 32]};
               case (vop)
               `VOP_WADD : prod = sb + sa;
               `VOP_WSUB : prod = sb - sa;
               `VOP_WADDU: prod = ub + ua;
               `VOP_WMUL : prod = sb * sa;
               default   : prod = ub * ua;
               endcase
               res[k*64 +: 64] = prod[63:0];
            end

         `VOP_NSRL, `VOP_NSRA:
            for (k=0;k<VLEN/32;k=k+1) begin
               if (k < (VLEN/64)) wide = opb[k*64 +: 64];
               else               wide = opc[(k-(VLEN/64))*64 +: 64];
               sh = opa[k*32 +: 6];                          // log2(2*SEW)=6
               if (vop == `VOP_NSRA)
                  res[k*32 +: 32] = $signed(wide) >>> sh;
               else
                  res[k*32 +: 32] = wide >> sh;
            end

         default : res = {VLEN{1'b0}};
         endcase
      end
      endcase
   end

endmodule
