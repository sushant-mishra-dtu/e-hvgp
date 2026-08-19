//==========================================================================
// rv_decode.v -- minimal scalar RV32I decode
//
// Verilog-2001.  Purely combinational.
//
// The scalar side exists only to (a) supply AVL to vsetvli/vsetvl and
// (b) drive loop control for the stress workload.  Supported:
//     LUI, ADDI, ADD, SUB, BNE, ECALL(=halt)
// plus recognition of the OP-V opcode which is handed to rvv_decode.v.
//==========================================================================
`include "ehvgp_defs.vh"

module rv_decode (
   input  wire [31:0] instr,

   output wire [6:0]  opcode,
   output wire [4:0]  rd,
   output wire [4:0]  rs1,
   output wire [4:0]  rs2,
   output wire [2:0]  funct3,
   output wire [6:0]  funct7,

   output wire [31:0] imm_i,
   output wire [31:0] imm_u,
   output wire [31:0] imm_b,

   output wire        is_lui,
   output wire        is_addi,
   output wire        is_add,
   output wire        is_sub,
   output wire        is_bne,
   output wire        is_halt,
   output wire        is_opv,
   output wire        sc_wr_rd,     // writes a scalar register
   output wire        illegal
);

   assign opcode = instr[6:0];
   assign rd     = instr[11:7];
   assign funct3 = instr[14:12];
   assign rs1    = instr[19:15];
   assign rs2    = instr[24:20];
   assign funct7 = instr[31:25];

   assign imm_i  = {{20{instr[31]}}, instr[31:20]};
   assign imm_u  = {instr[31:12], 12'd0};
   assign imm_b  = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

   assign is_lui  = (opcode == `OPC_LUI);
   assign is_addi = (opcode == `OPC_OPIMM)  && (funct3 == 3'b000);
   assign is_add  = (opcode == `OPC_OP)     && (funct3 == 3'b000) && (funct7 == 7'b0000000);
   assign is_sub  = (opcode == `OPC_OP)     && (funct3 == 3'b000) && (funct7 == 7'b0100000);
   assign is_bne  = (opcode == `OPC_BRANCH) && (funct3 == 3'b001);
   assign is_halt = (opcode == `OPC_SYSTEM);
   assign is_opv  = (opcode == `OPC_OPV);

   assign sc_wr_rd = is_lui | is_addi | is_add | is_sub;

   assign illegal = ~(is_lui | is_addi | is_add | is_sub | is_bne | is_halt | is_opv);

endmodule
