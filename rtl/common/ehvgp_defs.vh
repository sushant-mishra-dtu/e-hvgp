//==========================================================================
// ehvgp_defs.vh -- global macro definitions (Verilog-2001)
//
// E-HVGP : EMUL-Driven Heterogeneous Vector-Group Placement
//==========================================================================
`ifndef EHVGP_DEFS_VH
`define EHVGP_DEFS_VH

//--------------------------------------------------------------------------
// Internal vector opcodes (micro-op level)
//--------------------------------------------------------------------------
`define VOP_W       4
`define VOP_NOP     4'd0
`define VOP_ADD     4'd1     // vadd.vv    vd = vs2 + vs1                (EMUL_d = LMUL)
`define VOP_SUB     4'd2     // vsub.vv    vd = vs2 - vs1                (EMUL_d = LMUL)
`define VOP_MV      4'd3     // vmv.v.v    vd = vs1                      (EMUL_d = LMUL)
`define VOP_WADD    4'd4     // vwadd.vv   vd = sext(vs2)+sext(vs1)      (EMUL_d = 2*LMUL)
`define VOP_WADDU   4'd5     // vwaddu.vv  vd = zext(vs2)+zext(vs1)      (EMUL_d = 2*LMUL)
`define VOP_WSUB    4'd6     // vwsub.vv   vd = sext(vs2)-sext(vs1)      (EMUL_d = 2*LMUL)
`define VOP_WMUL    4'd7     // vwmul.vv   vd = sext(vs2)*sext(vs1)      (EMUL_d = 2*LMUL)
`define VOP_WMULU   4'd8     // vwmulu.vv  vd = zext(vs2)*zext(vs1)      (EMUL_d = 2*LMUL)
`define VOP_NSRL    4'd9     // vnsrl.wv   vd = vs2 >>l vs1              (EMUL_s2 = 2*LMUL)
`define VOP_NSRA    4'd10    // vnsra.wv   vd = vs2 >>a vs1              (EMUL_s2 = 2*LMUL)

//--------------------------------------------------------------------------
// RISC-V opcodes used by the scalar shim
//--------------------------------------------------------------------------
`define OPC_LUI     7'b0110111
`define OPC_OPIMM   7'b0010011
`define OPC_OP      7'b0110011
`define OPC_BRANCH  7'b1100011
`define OPC_SYSTEM  7'b1110011
`define OPC_OPV     7'b1010111

//--------------------------------------------------------------------------
// OPV funct3 sub-encodings (RVV 1.0)
//--------------------------------------------------------------------------
`define F3_OPIVV    3'b000
`define F3_OPMVV    3'b010
`define F3_OPCFG    3'b111

//--------------------------------------------------------------------------
// Vector micro-op slot states
//--------------------------------------------------------------------------
`define SLOT_EMPTY   2'd0
`define SLOT_COLLECT 2'd1
`define SLOT_EXEC    2'd2
`define SLOT_WB      2'd3

`endif // EHVGP_DEFS_VH
