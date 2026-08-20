//==========================================================================
// rv_core.v -- E-HVGP research core (top level)
//
// Verilog-2001.
//
//   Fetch/Decode/Scalar-Exec/Rename-Allocate   (1 instruction / cycle, in order)
//        -> vector descriptor queue
//        -> micro-op expansion
//        -> operand collect  (banked VRF read arbitration)
//        -> execute
//        -> writeback        (banked VRF write arbitration)
//        -> in-order commit  (physical register release)
//
// EHVGP_ENABLE is the ONLY parameter that changes behaviour between the
// two experimental configurations.  It is forwarded to ehvgp_allocator
// and nowhere else.
//==========================================================================
`include "ehvgp_defs.vh"

module rv_core #(
   parameter VLEN          = 128,
   parameter VLEN_LOG2     = 7,
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
   parameter TAG_W         = 3,
   parameter CMTQ_DEPTH    = 8,
   parameter IMEM_AW       = 10,
   parameter EHVGP_ENABLE  = 0
)(
   input  wire        clk,
   input  wire        rst,
   output reg         halted,

   //--- performance counters --------------------------------------------
   output reg  [31:0] cycle_count,
   output reg  [31:0] instr_count,
   output reg  [31:0] vinstr_count,
   output wire [31:0] vuop_count,
   output reg  [31:0] vrf_read_requests,
   output reg  [31:0] vrf_write_requests,
   output reg  [31:0] bank_conflict_count,
   output reg  [31:0] bank_read_conflicts,
   output reg  [31:0] bank_write_conflicts,
   output reg  [31:0] bank_stall_cycles,
   output reg  [31:0] widening_count,
   output reg  [31:0] narrowing_count,
   output reg  [31:0] rename_stall_cycles,
   // Attribution of rename_stall_cycles by cause.  The three causes are not
   // mutually exclusive -- a cycle blocked by two of them increments both --
   // so these do NOT sum to rename_stall_cycles in general.
   output reg  [31:0] stall_alloc_cycles,
   output reg  [31:0] stall_desc_cycles,
   output reg  [31:0] stall_cmtq_cycles,
   output wire [NUM_TOPO*32-1:0] topo_alloc,

   //--- debug / architectural state dump ---------------------------------
   input  wire [4:0]        dbg_arch,
   output wire [PREG_W-1:0] dbg_preg,
   output wire [TID_W-1:0]  dbg_topo,
   output wire [SLOT_W-1:0] dbg_slot,
   output wire [IDX_W-1:0]  dbg_idx,
   output wire [VLEN-1:0]   dbg_vdata,
   output wire [10:0]       dbg_vtype,
   output wire [31:0]       dbg_vl,
   output wire              dbg_vill,
   output wire [31:0]       dbg_pc,
   input  wire [4:0]        dbg_xreg,
   output wire [31:0]       dbg_xdata
);

   localparam NRD = ISSUE_W*3;

   //=======================================================================
   // Fetch
   //=======================================================================
   reg  [31:0] pc;
   wire [31:0] instr;

   imem #(.DEPTH(1<<IMEM_AW), .AW(IMEM_AW)) u_imem (
      .addr (pc[IMEM_AW+1:2]),
      .data (instr)
   );
   assign dbg_pc = pc;

   //=======================================================================
   // Decode
   //=======================================================================
   wire [6:0]  opcode;
   wire [4:0]  rd, rs1, rs2;
   wire [2:0]  funct3;
   wire [6:0]  funct7;
   wire [31:0] imm_i, imm_u, imm_b;
   wire        is_lui, is_addi, is_add, is_sub, is_bne, is_halt, is_opv;
   wire        sc_wr_rd, sc_illegal;

   rv_decode u_sdec (
      .instr(instr), .opcode(opcode), .rd(rd), .rs1(rs1), .rs2(rs2),
      .funct3(funct3), .funct7(funct7),
      .imm_i(imm_i), .imm_u(imm_u), .imm_b(imm_b),
      .is_lui(is_lui), .is_addi(is_addi), .is_add(is_add), .is_sub(is_sub),
      .is_bne(is_bne), .is_halt(is_halt), .is_opv(is_opv),
      .sc_wr_rd(sc_wr_rd), .illegal(sc_illegal)
   );

   //=======================================================================
   // Scalar register file
   //=======================================================================
   reg  [31:0] xreg [0:31];
   wire [31:0] rs1v = (rs1 == 5'd0) ? 32'd0 : xreg[rs1];
   wire [31:0] rs2v = (rs2 == 5'd0) ? 32'd0 : xreg[rs2];
   assign dbg_xdata = (dbg_xreg == 5'd0) ? 32'd0 : xreg[dbg_xreg];

   //=======================================================================
   // vtype / vl
   //=======================================================================
   wire        is_vsetvli, is_vsetvl, avl_is_max_i;
   wire [10:0] vsetvli_vtype;
   wire        v_is_arith, v_is_widen, v_is_narrow, v_s1_used, v_s2_used;
   wire [3:0]  v_vop;
   wire [4:0]  vd_a, vs1_a, vs2_a;
   wire [3:0]  g_dst, g_s1, g_s2, n_uop;
   wire        v_illegal;

   wire [1:0]  sew_log2, lmul_log2;
   wire [31:0] vlmax;
   wire [31:0] cfg_next_vl;
   wire        cfg_next_vill;
   wire        v_cfg = is_vsetvli | is_vsetvl;

   wire [10:0] cfg_vtype = is_vsetvl ? rs2v[10:0] : vsetvli_vtype;
   wire        cfg_avlmax = is_vsetvl ? (rs1 == 5'd0) : avl_is_max_i;

   // forward declarations (front-end control, defined below)
   wire        stall;
   wire        v_active;

   vector_config #(.VLEN(VLEN)) u_vcfg (
      .clk        (clk),
      .rst        (rst),
      .set_valid  (v_cfg & ~stall & ~halted),
      .set_vtype  (cfg_vtype),
      .set_avl    (rs1v),
      .avl_is_max (cfg_avlmax),
      .vtype      (dbg_vtype),
      .vl         (dbg_vl),
      .vill       (dbg_vill),
      .sew_log2   (sew_log2),
      .lmul_log2  (lmul_log2),
      .vlmax      (vlmax),
      .next_vl    (cfg_next_vl),
      .next_vill  (cfg_next_vill)
   );

   rvv_decode u_vdec (
      .instr(instr), .lmul_log2(lmul_log2), .sew_log2(sew_log2),
      .is_vsetvli(is_vsetvli), .is_vsetvl(is_vsetvl),
      .vsetvli_vtype(vsetvli_vtype), .avl_is_max(avl_is_max_i),
      .is_varith(v_is_arith), .vop(v_vop),
      .is_widen(v_is_widen), .is_narrow(v_is_narrow),
      .s1_used(v_s1_used), .s2_used(v_s2_used),
      .vd(vd_a), .vs1(vs1_a), .vs2(vs2_a),
      .g_dst(g_dst), .g_s1(g_s1), .g_s2(g_s2), .n_uop(n_uop),
      .v_illegal(v_illegal)
   );

   //-----------------------------------------------------------------------
   // Micro-ops actually needed, clipped by VL.
   //   elements per destination register = VLEN / EEW_dst
   //   EEW_dst = 2*SEW for widening, SEW otherwise
   //-----------------------------------------------------------------------
   wire [3:0]  uop_shift  = VLEN_LOG2 - 3 - sew_log2 - (v_is_widen ? 1 : 0);
   wire [31:0] epr        = 32'd1 << uop_shift;
   wire [31:0] nreg_need  = (dbg_vl + epr - 32'd1) >> uop_shift;
   wire [3:0]  nuop_eff   = (nreg_need >= {28'd0, g_dst}) ? g_dst : nreg_need[3:0];

   wire        v_arith    = is_opv & v_is_arith & ~dbg_vill & ~v_illegal;
   assign      v_active   = v_arith & (nuop_eff != 4'd0);

   //=======================================================================
   // Rename / Allocate
   //=======================================================================
   wire                        alloc_ok;
   wire [MAX_GROUP*PREG_W-1:0] dst_pregs, s1_pregs, s2_pregs;
   wire [NUM_PHYS-1:0]         old_free_mask;
   wire [TID_W-1:0]            sel_topo;
   wire [SLOT_W-1:0]           sel_slot;
   wire [15:0]                 sel_cost;
   wire [BID_W-1:0]            dbg_rr_base;
   wire [NUM_PHYS-1:0]         dbg_free_vec;

   wire                        do_alloc;
   wire                        cq_free_valid;
   wire [NUM_PHYS-1:0]         cq_free_mask;

   vector_rename #(
      .VLEN(VLEN), .NUM_BANKS(NUM_BANKS), .REGS_PER_BANK(REGS_PER_BANK),
      .NUM_PHYS(NUM_PHYS), .NUM_ARCH(NUM_ARCH), .BID_W(BID_W), .TID_W(TID_W),
      .SLOT_W(SLOT_W), .PREG_W(PREG_W), .IDX_W(IDX_W), .MAX_GROUP(MAX_GROUP),
      .NUM_TOPO(NUM_TOPO), .ISSUE_W(ISSUE_W), .EHVGP_ENABLE(EHVGP_ENABLE)
   ) u_rename (
      .clk(clk), .rst(rst),
      .vd(vd_a), .vs1(vs1_a), .vs2(vs2_a),
      .g_dst(g_dst), .g_s1(g_s1), .g_s2(g_s2),
      .s1_used(v_s1_used), .s2_used(v_s2_used),
      .sew_log2(sew_log2), .is_widen(v_is_widen), .is_narrow(v_is_narrow),
      .do_alloc(do_alloc),
      .alloc_ok(alloc_ok),
      .dst_pregs(dst_pregs), .s1_pregs(s1_pregs), .s2_pregs(s2_pregs),
      .old_free_mask(old_free_mask),
      .sel_topo(sel_topo), .sel_slot(sel_slot), .sel_cost(sel_cost),
      .free_valid(cq_free_valid), .free_mask(cq_free_mask),
      .dbg_arch(dbg_arch), .dbg_preg(dbg_preg), .dbg_topo(dbg_topo),
      .dbg_slot(dbg_slot), .dbg_idx(dbg_idx),
      .dbg_free_vec(dbg_free_vec), .dbg_rr_base(dbg_rr_base)
   );

   // physical registers this instruction will actually write
   reg [NUM_PHYS-1:0] busy_mask;
   integer            bm;
   always @(*) begin
      busy_mask = {NUM_PHYS{1'b0}};
      for (bm = 0; bm < MAX_GROUP; bm = bm + 1)
         if (bm < nuop_eff)
            busy_mask[dst_pregs[bm*PREG_W +: PREG_W]] = 1'b1;
   end

   //=======================================================================
   // Commit queue (in-order, physical register release)
   //=======================================================================
   reg                cq_valid [0:CMTQ_DEPTH-1];
   reg [3:0]          cq_total [0:CMTQ_DEPTH-1];
   reg [3:0]          cq_done  [0:CMTQ_DEPTH-1];
   reg [NUM_PHYS-1:0] cq_free  [0:CMTQ_DEPTH-1];
   reg                cq_wide  [0:CMTQ_DEPTH-1];
   reg                cq_narr  [0:CMTQ_DEPTH-1];

   reg [TAG_W:0] cq_wr, cq_rd;
   wire [TAG_W:0] cq_cnt   = cq_wr - cq_rd;
   wire           cq_full  = (cq_cnt == CMTQ_DEPTH);
   wire           cq_empty = (cq_cnt == 0);
   wire [TAG_W-1:0] cq_head = cq_rd[TAG_W-1:0];
   wire [TAG_W-1:0] cq_tail = cq_wr[TAG_W-1:0];

   wire cq_commit = cq_valid[cq_head] && (cq_done[cq_head] == cq_total[cq_head]);
   assign cq_free_valid = cq_commit;
   assign cq_free_mask  = cq_free[cq_head];

   //=======================================================================
   // Vector unit + VRF
   //=======================================================================
   wire                    desc_ready;
   wire [ISSUE_W-1:0]      ret_valid;
   wire [ISSUE_W*TAG_W-1:0] ret_tag;
   wire                    vu_idle;

   wire [NRD-1:0]          rd_req;
   wire [NRD*PREG_W-1:0]   rd_preg;
   wire [NRD-1:0]          rd_grant;
   wire [NRD*VLEN-1:0]     rd_data;
   wire [ISSUE_W-1:0]      wr_req;
   wire [ISSUE_W*PREG_W-1:0] wr_preg;
   wire [ISSUE_W*VLEN-1:0]   wr_data;
   wire [ISSUE_W-1:0]      wr_grant;
   wire [7:0]              rd_denied, wr_denied;
   wire [NUM_BANKS-1:0]    rd_bank_en, wr_bank_en;

   vector_unit #(
      .VLEN(VLEN), .NUM_BANKS(NUM_BANKS), .REGS_PER_BANK(REGS_PER_BANK),
      .NUM_PHYS(NUM_PHYS), .PREG_W(PREG_W), .MAX_GROUP(MAX_GROUP),
      .ISSUE_W(ISSUE_W), .TAG_W(TAG_W)
   ) u_vu (
      .clk(clk), .rst(rst),
      .desc_valid(do_alloc), .desc_ready(desc_ready),
      .desc_vop(v_vop), .desc_sew_log2(sew_log2),
      .desc_is_widen(v_is_widen), .desc_is_narrow(v_is_narrow),
      .desc_s1_used(v_s1_used), .desc_s2_used(v_s2_used),
      .desc_nuop(nuop_eff), .desc_tag(cq_tail),
      .desc_dst_pregs(dst_pregs), .desc_s1_pregs(s1_pregs), .desc_s2_pregs(s2_pregs),
      .set_busy_valid(do_alloc), .set_busy_mask(busy_mask),
      .ret_valid(ret_valid), .ret_tag(ret_tag),
      .rd_req(rd_req), .rd_preg(rd_preg), .rd_grant(rd_grant), .rd_data(rd_data),
      .wr_req(wr_req), .wr_preg(wr_preg), .wr_data(wr_data), .wr_grant(wr_grant),
      .vu_idle(vu_idle), .uop_count(vuop_count),
      .dbg_preg_ready()
   );

   vrf #(
      .VLEN(VLEN), .NUM_BANKS(NUM_BANKS), .REGS_PER_BANK(REGS_PER_BANK),
      .BID_W(BID_W), .SLOT_W(SLOT_W), .PREG_W(PREG_W),
      .NRD(NRD), .NWR(ISSUE_W)
   ) u_vrf (
      .clk(clk),
      .rd_req(rd_req), .rd_preg(rd_preg), .rd_grant(rd_grant), .rd_data(rd_data),
      .wr_req(wr_req), .wr_preg(wr_preg), .wr_data(wr_data), .wr_grant(wr_grant),
      .rd_denied(rd_denied), .wr_denied(wr_denied),
      .rd_bank_en(rd_bank_en), .wr_bank_en(wr_bank_en),
      .dbg_preg(dbg_preg), .dbg_data(dbg_vdata)
   );

   //=======================================================================
   // Front-end control
   //=======================================================================
   wire v_can_go = alloc_ok & desc_ready & ~cq_full;
   assign stall  = v_active & ~v_can_go;

   assign do_alloc = v_active & v_can_go & ~halted & ~rst & ~is_halt;

   wire branch_taken = is_bne & (rs1v != rs2v);
   wire drain_done   = vu_idle & cq_empty;

   //=======================================================================
   // Sequential front end, commit, counters
   //=======================================================================
   integer i, j;
   reg [3:0] inc0, inc1, incs;
   reg [31:0] topo_cnt [0:NUM_TOPO-1];

   genvar gt;
   generate
      for (gt = 0; gt < NUM_TOPO; gt = gt + 1) begin : g_topo
         assign topo_alloc[gt*32 +: 32] = topo_cnt[gt];
      end
   endgenerate

   // popcount helpers
   integer pc_i;
   reg [7:0] n_rd_grant, n_wr_grant;
   always @(*) begin
      n_rd_grant = 8'd0;
      for (pc_i = 0; pc_i < NRD; pc_i = pc_i + 1)
         if (rd_grant[pc_i] && rd_req[pc_i]) n_rd_grant = n_rd_grant + 8'd1;
      n_wr_grant = 8'd0;
      for (pc_i = 0; pc_i < ISSUE_W; pc_i = pc_i + 1)
         if (wr_grant[pc_i] && wr_req[pc_i]) n_wr_grant = n_wr_grant + 8'd1;
   end

   always @(posedge clk or posedge rst) begin
      if (rst) begin
         pc                   <= 32'd0;
         halted               <= 1'b0;
         cycle_count          <= 32'd0;
         instr_count          <= 32'd0;
         vinstr_count         <= 32'd0;
         vrf_read_requests    <= 32'd0;
         vrf_write_requests   <= 32'd0;
         bank_conflict_count  <= 32'd0;
         bank_read_conflicts  <= 32'd0;
         bank_write_conflicts <= 32'd0;
         bank_stall_cycles    <= 32'd0;
         widening_count       <= 32'd0;
         narrowing_count      <= 32'd0;
         rename_stall_cycles  <= 32'd0;
         stall_alloc_cycles   <= 32'd0;
         stall_desc_cycles    <= 32'd0;
         stall_cmtq_cycles    <= 32'd0;
         cq_wr                <= 0;
         cq_rd                <= 0;
         for (i = 0; i < 32; i = i + 1) xreg[i] <= 32'd0;
         for (i = 0; i < CMTQ_DEPTH; i = i + 1) begin
            cq_valid[i] <= 1'b0;
            cq_done [i] <= 4'd0;
            cq_total[i] <= 4'd0;
         end
         for (i = 0; i < NUM_TOPO; i = i + 1) topo_cnt[i] <= 32'd0;
      end else if (!halted) begin
         //--------------------------------------------------------------
         // Counters
         //--------------------------------------------------------------
         cycle_count          <= cycle_count + 32'd1;
         vrf_read_requests    <= vrf_read_requests  + {24'd0, n_rd_grant};
         vrf_write_requests   <= vrf_write_requests + {24'd0, n_wr_grant};
         bank_read_conflicts  <= bank_read_conflicts  + {24'd0, rd_denied};
         bank_write_conflicts <= bank_write_conflicts + {24'd0, wr_denied};
         bank_conflict_count  <= bank_conflict_count  + {24'd0, rd_denied} + {24'd0, wr_denied};
         if ((rd_denied != 8'd0) || (wr_denied != 8'd0))
            bank_stall_cycles <= bank_stall_cycles + 32'd1;
         if (stall) begin
            rename_stall_cycles <= rename_stall_cycles + 32'd1;
            // v_can_go carries the three blocking conditions separately;
            // attribute the stalled cycle to every condition asserted in it.
            if (!alloc_ok)   stall_alloc_cycles <= stall_alloc_cycles + 32'd1;
            if (!desc_ready) stall_desc_cycles  <= stall_desc_cycles  + 32'd1;
            if (cq_full)     stall_cmtq_cycles  <= stall_cmtq_cycles  + 32'd1;
         end

         //--------------------------------------------------------------
         // Front end
         //--------------------------------------------------------------
         if (is_halt) begin
            if (drain_done) halted <= 1'b1;
         end else if (!stall) begin
            pc <= branch_taken ? (pc + imm_b) : (pc + 32'd4);

            if (sc_wr_rd && (rd != 5'd0)) begin
               if      (is_lui)  xreg[rd] <= imm_u;
               else if (is_addi) xreg[rd] <= rs1v + imm_i;
               else if (is_add)  xreg[rd] <= rs1v + rs2v;
               else if (is_sub)  xreg[rd] <= rs1v - rs2v;
            end
            if (v_cfg && (rd != 5'd0)) begin
               // vsetvli/vsetvl write the resulting VL
               xreg[rd] <= cfg_next_vl;
            end
         end

         // Retirement accounting: scalar/config instructions retire in the
         // fetch stage, vector instructions retire from the commit queue.
         // Combined into ONE assignment so a simultaneous pair is not lost.
         instr_count <= instr_count
                      + ((!is_halt && !stall && !v_active) ? 32'd1 : 32'd0)
                      + (cq_commit ? 32'd1 : 32'd0);

         //--------------------------------------------------------------
         // Rename push
         //--------------------------------------------------------------
         if (do_alloc) begin
            cq_valid[cq_tail] <= 1'b1;
            cq_total[cq_tail] <= nuop_eff;
            cq_done [cq_tail] <= 4'd0;
            cq_free [cq_tail] <= old_free_mask;
            cq_wide [cq_tail] <= v_is_widen;
            cq_narr [cq_tail] <= v_is_narrow;
            cq_wr             <= cq_wr + 1;
            topo_cnt[sel_topo] <= topo_cnt[sel_topo] + 32'd1;
         end

         //--------------------------------------------------------------
         // Micro-op completion accounting
         //--------------------------------------------------------------
         for (j = 0; j < CMTQ_DEPTH; j = j + 1) begin
            incs = 4'd0;
            if (ret_valid[0] && (ret_tag[0*TAG_W +: TAG_W] == j[TAG_W-1:0])) incs = incs + 4'd1;
            if (ret_valid[1] && (ret_tag[1*TAG_W +: TAG_W] == j[TAG_W-1:0])) incs = incs + 4'd1;
            if (do_alloc && (cq_tail == j[TAG_W-1:0]))
               cq_done[j] <= incs;                 // fresh entry
            else if (incs != 4'd0)
               cq_done[j] <= cq_done[j] + incs;
         end

         //--------------------------------------------------------------
         // In-order commit
         //--------------------------------------------------------------
         if (cq_commit) begin
            cq_valid[cq_head] <= 1'b0;
            cq_rd             <= cq_rd + 1;
            vinstr_count      <= vinstr_count + 32'd1;
            if (cq_wide[cq_head]) widening_count <= widening_count + 32'd1;
            if (cq_narr[cq_head]) narrowing_count <= narrowing_count + 32'd1;
         end
      end
   end

   // unused-signal keepalive for lint cleanliness
   // synthesis translate_off
   wire _unused = sc_illegal | (|funct7) | (|imm_i[31]) | (|vlmax) |
                  (|dbg_free_vec) | (|dbg_rr_base) | (|sel_cost) |
                  (|sel_slot) | (|n_uop) | (|g_s1) | (|g_s2) |
                  (|rd_bank_en) | (|wr_bank_en) | (|opcode);
   // synthesis translate_on

endmodule
