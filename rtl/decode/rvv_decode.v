//==========================================================================
// rvv_decode.v -- RVV subset decode + EMUL/LMUL group-size computation
//
// Verilog-2001.  Purely combinational.
//
// Implemented subset (architecture notes Section 7):
//     vsetvli / vsetvl                          (configuration)
//     vadd.vv  vsub.vv  vmv.v.v                 EMUL_d = EMUL_s = LMUL
//     vwadd.vv vwaddu.vv vwsub.vv               EMUL_d = 2*LMUL
//     vwmul.vv vwmulu.vv                        EMUL_d = 2*LMUL
//     vnsrl.wv vnsra.wv                         EMUL_s2 = 2*LMUL
//
// ARCHITECTURAL GROUPING (this module) is kept strictly separate from
// PHYSICAL PLACEMENT (rtl/e_hvgp/*).  RVV specifies the former and says
// nothing about the latter; the topology is our microarchitectural choice.
//==========================================================================
`include "ehvgp_defs.vh"

module rvv_decode (
   input  wire [31:0] instr,
   input  wire [1:0]  lmul_log2,      // from current vtype
   input  wire [1:0]  sew_log2,       // from current vtype

   // configuration instructions
   output wire        is_vsetvli,
   output wire        is_vsetvl,
   output wire [10:0] vsetvli_vtype,
   output wire        avl_is_max,     // rs1 == x0

   // arithmetic
   output reg         is_varith,
   output reg  [3:0]  vop,
   output reg         is_widen,       // EMUL_dst = 2*LMUL
   output reg         is_narrow,      // EMUL_s2  = 2*LMUL
   output reg         s1_used,
   output reg         s2_used,

   output wire [4:0]  vd,
   output wire [4:0]  vs1,
   output wire [4:0]  vs2,

   // group sizes in PHYSICAL REGISTERS
   output wire [3:0]  g_dst,
   output wire [3:0]  g_s1,
   output wire [3:0]  g_s2,
   output wire [3:0]  n_uop,          // micro-ops = EMUL_dst registers

   output wire        v_illegal
);

   wire [6:0] opcode = instr[6:0];
   wire [2:0] funct3 = instr[14:12];
   wire [5:0] funct6 = instr[31:26];
   wire       vm     = instr[25];

   assign vd  = instr[11:7];
   assign vs1 = instr[19:15];
   assign vs2 = instr[24:20];

   //-----------------------------------------------------------------------
   // Configuration
   //-----------------------------------------------------------------------
   wire opv = (opcode == `OPC_OPV);
   assign is_vsetvli    = opv && (funct3 == `F3_OPCFG) && (instr[31] == 1'b0);
   assign is_vsetvl     = opv && (funct3 == `F3_OPCFG) && (instr[31:25] == 7'b1000000);
   assign vsetvli_vtype = instr[30:20];
   assign avl_is_max    = (instr[19:15] == 5'd0);

   //-----------------------------------------------------------------------
   // Arithmetic decode
   //-----------------------------------------------------------------------
   reg [1:0] emul_d_log2;
   reg [1:0] emul_s1_log2;
   reg [1:0] emul_s2_log2;
   reg       ovf;

   always @(*) begin
      is_varith    = 1'b0;
      vop          = `VOP_NOP;
      is_widen     = 1'b0;
      is_narrow    = 1'b0;
      s1_used      = 1'b0;
      s2_used      = 1'b0;
      emul_d_log2  = lmul_log2;
      emul_s1_log2 = lmul_log2;
      emul_s2_log2 = lmul_log2;

      if (opv && (funct3 == `F3_OPIVV)) begin
         case (funct6)
         6'b000000: begin vop=`VOP_ADD;  is_varith=1; s1_used=1; s2_used=1; end
         6'b000010: begin vop=`VOP_SUB;  is_varith=1; s1_used=1; s2_used=1; end
         6'b010111: begin vop=`VOP_MV;   is_varith=1; s1_used=1; s2_used=0; end
         6'b101100: begin vop=`VOP_NSRL; is_varith=1; s1_used=1; s2_used=1;
                          is_narrow=1;  emul_s2_log2 = lmul_log2 + 2'd1; end
         6'b101101: begin vop=`VOP_NSRA; is_varith=1; s1_used=1; s2_used=1;
                          is_narrow=1;  emul_s2_log2 = lmul_log2 + 2'd1; end
         default:   begin vop=`VOP_NOP;  is_varith=0; end
         endcase
      end else if (opv && (funct3 == `F3_OPMVV)) begin
         case (funct6)
         6'b110001: begin vop=`VOP_WADD;  is_varith=1; s1_used=1; s2_used=1;
                          is_widen=1; emul_d_log2 = lmul_log2 + 2'd1; end
         6'b110000: begin vop=`VOP_WADDU; is_varith=1; s1_used=1; s2_used=1;
                          is_widen=1; emul_d_log2 = lmul_log2 + 2'd1; end
         6'b110011: begin vop=`VOP_WSUB;  is_varith=1; s1_used=1; s2_used=1;
                          is_widen=1; emul_d_log2 = lmul_log2 + 2'd1; end
         6'b111011: begin vop=`VOP_WMUL;  is_varith=1; s1_used=1; s2_used=1;
                          is_widen=1; emul_d_log2 = lmul_log2 + 2'd1; end
         6'b111000: begin vop=`VOP_WMULU; is_varith=1; s1_used=1; s2_used=1;
                          is_widen=1; emul_d_log2 = lmul_log2 + 2'd1; end
         default:   begin vop=`VOP_NOP;   is_varith=0; end
         endcase
      end
   end

   //-----------------------------------------------------------------------
   // Group sizes.  EMUL of 16 registers is not representable in a 2-bit
   // log2 field, so widening/narrowing with LMUL = 8 is rejected rather
   // than silently wrapping.
   //-----------------------------------------------------------------------
   wire widen_ovf  = is_widen  && (lmul_log2 == 2'd3);
   wire narrow_ovf = is_narrow && (lmul_log2 == 2'd3);

   assign g_dst = (4'd1 << emul_d_log2);
   assign g_s1  = s1_used ? (4'd1 << emul_s1_log2) : 4'd0;
   assign g_s2  = s2_used ? (4'd1 << emul_s2_log2) : 4'd0;
   assign n_uop = g_dst;

   assign v_illegal = widen_ovf | narrow_ovf;

   // vm is decoded but masking is deferred (architecture notes Section 7);
   // all supported instructions must be unmasked (vm = 1).
   // synthesis translate_off
   wire _unused_vm = vm & (|sew_log2);
   // synthesis translate_on

endmodule
