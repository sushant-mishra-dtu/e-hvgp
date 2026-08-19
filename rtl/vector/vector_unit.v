//==========================================================================
// vector_unit.v -- vector back end
//
//   descriptor FIFO -> micro-op expander -> micro-op FIFO
//        -> ISSUE_W operand-collect slots (bank arbitration happens here)
//        -> ISSUE_W execute pipes
//        -> ISSUE_W writeback pipes (bank arbitration again)
//        -> retire
//
// Verilog-2001.
//
//--------------------------------------------------------------------------
// TIMING MODEL (identical in BASELINE and E-HVGP)
//--------------------------------------------------------------------------
//   * ISSUE_W micro-ops may be in operand collection simultaneously.
//   * A slot presents a read request for each of its outstanding source
//     operands EVERY cycle, but only for operands whose producing physical
//     register is already written (preg_ready scoreboard).  A request that
//     is presented and loses bank arbitration is a BANK CONFLICT and costs
//     exactly one cycle; it re-presents unchanged next cycle.
//   * A slot leaves collection when all its sources are latched.
//   * Execute is a fixed 1 cycle.
//   * Writeback presents one write request; losing bank arbitration costs
//     one cycle, same rule.
//   * Arbitration priority is fixed: slot 0 source 0,1,2 then slot 1
//     source 0,1,2 for reads; slot 0 then slot 1 for writes.
//
// Nothing in this file is aware of EHVGP_ENABLE.  It only ever sees
// physical register numbers.
//==========================================================================
`include "ehvgp_defs.vh"

module vector_unit #(
   parameter VLEN          = 128,
   parameter NUM_BANKS     = 4,
   parameter REGS_PER_BANK = 16,
   parameter NUM_PHYS      = 64,
   parameter PREG_W        = 6,
   parameter MAX_GROUP     = 8,
   parameter ISSUE_W       = 2,
   parameter TAG_W         = 3,
   parameter DESCQ_DEPTH   = 4,
   parameter UOPQ_DEPTH    = 16,
   parameter UOPQ_AW       = 4
)(
   input  wire                            clk,
   input  wire                            rst,

   //--- descriptor input -------------------------------------------------
   input  wire                            desc_valid,
   output wire                            desc_ready,
   input  wire [3:0]                      desc_vop,
   input  wire [1:0]                      desc_sew_log2,
   input  wire                            desc_is_widen,
   input  wire                            desc_is_narrow,
   input  wire                            desc_s1_used,
   input  wire                            desc_s2_used,
   input  wire [3:0]                      desc_nuop,
   input  wire [TAG_W-1:0]                desc_tag,
   input  wire [MAX_GROUP*PREG_W-1:0]     desc_dst_pregs,
   input  wire [MAX_GROUP*PREG_W-1:0]     desc_s1_pregs,
   input  wire [MAX_GROUP*PREG_W-1:0]     desc_s2_pregs,

   //--- scoreboard -------------------------------------------------------
   input  wire                            set_busy_valid,
   input  wire [NUM_PHYS-1:0]             set_busy_mask,

   //--- retire -----------------------------------------------------------
   output wire [ISSUE_W-1:0]              ret_valid,
   output wire [ISSUE_W*TAG_W-1:0]        ret_tag,

   //--- VRF --------------------------------------------------------------
   output wire [ISSUE_W*3-1:0]            rd_req,
   output wire [ISSUE_W*3*PREG_W-1:0]     rd_preg,
   input  wire [ISSUE_W*3-1:0]            rd_grant,
   input  wire [ISSUE_W*3*VLEN-1:0]       rd_data,
   output wire [ISSUE_W-1:0]              wr_req,
   output wire [ISSUE_W*PREG_W-1:0]       wr_preg,
   output wire [ISSUE_W*VLEN-1:0]         wr_data,
   input  wire [ISSUE_W-1:0]              wr_grant,

   //--- status / counters ------------------------------------------------
   output wire                            vu_idle,
   output reg  [31:0]                     uop_count,
   output wire [NUM_PHYS-1:0]             dbg_preg_ready
);

   localparam NRD = ISSUE_W*3;

   //=======================================================================
   // Descriptor FIFO
   //=======================================================================
   localparam DQ_AW = 2;

   reg [3:0]                  dq_vop   [0:DESCQ_DEPTH-1];
   reg [1:0]                  dq_sew   [0:DESCQ_DEPTH-1];
   reg                        dq_wid   [0:DESCQ_DEPTH-1];
   reg                        dq_nar   [0:DESCQ_DEPTH-1];
   reg                        dq_s1u   [0:DESCQ_DEPTH-1];
   reg                        dq_s2u   [0:DESCQ_DEPTH-1];
   reg [3:0]                  dq_nuop  [0:DESCQ_DEPTH-1];
   reg [TAG_W-1:0]            dq_tag   [0:DESCQ_DEPTH-1];
   reg [MAX_GROUP*PREG_W-1:0] dq_dstp  [0:DESCQ_DEPTH-1];
   reg [MAX_GROUP*PREG_W-1:0] dq_s1p   [0:DESCQ_DEPTH-1];
   reg [MAX_GROUP*PREG_W-1:0] dq_s2p   [0:DESCQ_DEPTH-1];

   reg [DQ_AW:0] dq_wr, dq_rd;
   wire [DQ_AW:0] dq_cnt   = dq_wr - dq_rd;
   wire           dq_full  = (dq_cnt == DESCQ_DEPTH);
   wire           dq_empty = (dq_cnt == 0);

   assign desc_ready = ~dq_full;

   //=======================================================================
   // Micro-op FIFO
   //=======================================================================
   reg [3:0]        uq_vop  [0:UOPQ_DEPTH-1];
   reg [1:0]        uq_sew  [0:UOPQ_DEPTH-1];
   reg              uq_half [0:UOPQ_DEPTH-1];
   reg              uq_s0v  [0:UOPQ_DEPTH-1];
   reg              uq_s1v  [0:UOPQ_DEPTH-1];
   reg              uq_s2v  [0:UOPQ_DEPTH-1];
   reg [PREG_W-1:0] uq_s0p  [0:UOPQ_DEPTH-1];
   reg [PREG_W-1:0] uq_s1p  [0:UOPQ_DEPTH-1];
   reg [PREG_W-1:0] uq_s2p  [0:UOPQ_DEPTH-1];
   reg [PREG_W-1:0] uq_dp   [0:UOPQ_DEPTH-1];
   reg [TAG_W-1:0]  uq_tag  [0:UOPQ_DEPTH-1];

   reg  [UOPQ_AW:0] uq_wr, uq_rd;
   wire [UOPQ_AW:0] uq_cnt   = uq_wr - uq_rd;
   wire [UOPQ_AW:0] uq_space = UOPQ_DEPTH[UOPQ_AW:0] - uq_cnt;

   //=======================================================================
   // Expander
   //=======================================================================
   reg  [3:0] exp_i;

   wire [3:0]                  h_vop  = dq_vop [dq_rd[DQ_AW-1:0]];
   wire [1:0]                  h_sew  = dq_sew [dq_rd[DQ_AW-1:0]];
   wire                        h_wid  = dq_wid [dq_rd[DQ_AW-1:0]];
   wire                        h_nar  = dq_nar [dq_rd[DQ_AW-1:0]];
   wire                        h_s1u  = dq_s1u [dq_rd[DQ_AW-1:0]];
   wire                        h_s2u  = dq_s2u [dq_rd[DQ_AW-1:0]];
   wire [3:0]                  h_nuop = dq_nuop[dq_rd[DQ_AW-1:0]];
   wire [TAG_W-1:0]            h_tag  = dq_tag [dq_rd[DQ_AW-1:0]];
   wire [MAX_GROUP*PREG_W-1:0] h_dstp = dq_dstp[dq_rd[DQ_AW-1:0]];
   wire [MAX_GROUP*PREG_W-1:0] h_s1p  = dq_s1p [dq_rd[DQ_AW-1:0]];
   wire [MAX_GROUP*PREG_W-1:0] h_s2p  = dq_s2p [dq_rd[DQ_AW-1:0]];

   wire [3:0] remaining = dq_empty ? 4'd0 : (h_nuop - exp_i);
   reg  [3:0] n_emit;
   always @(*) begin
      n_emit = remaining;
      if (n_emit > ISSUE_W[3:0]) n_emit = ISSUE_W[3:0];
      if (n_emit > uq_space)     n_emit = uq_space[3:0];
   end

   // per-emission-lane micro-op field computation
   wire                  e_half [0:ISSUE_W-1];
   wire                  e_s0v  [0:ISSUE_W-1];
   wire                  e_s1v  [0:ISSUE_W-1];
   wire                  e_s2v  [0:ISSUE_W-1];
   wire [PREG_W-1:0]     e_s0p  [0:ISSUE_W-1];
   wire [PREG_W-1:0]     e_s1p  [0:ISSUE_W-1];
   wire [PREG_W-1:0]     e_s2p  [0:ISSUE_W-1];
   wire [PREG_W-1:0]     e_dp   [0:ISSUE_W-1];

   genvar ge;
   generate
      for (ge = 0; ge < ISSUE_W; ge = ge + 1) begin : g_exp
         vector_uop #(.PREG_W(PREG_W), .MAX_GROUP(MAX_GROUP)) u_uop (
            .uidx      (exp_i + ge[3:0]),
            .is_widen  (h_wid),
            .is_narrow (h_nar),
            .s1_used   (h_s1u),
            .s2_used   (h_s2u),
            .dst_pregs (h_dstp),
            .s1_pregs  (h_s1p),
            .s2_pregs  (h_s2p),
            .half_sel  (e_half[ge]),
            .s0_v      (e_s0v[ge]),
            .s0_preg   (e_s0p[ge]),
            .s1_v      (e_s1v[ge]),
            .s1_preg   (e_s1p[ge]),
            .s2_v      (e_s2v[ge]),
            .s2_preg   (e_s2p[ge]),
            .d_preg    (e_dp[ge])
         );
      end
   endgenerate

   //=======================================================================
   // Operand-collect slots
   //=======================================================================
   reg [1:0]        st_state [0:ISSUE_W-1];
   reg [3:0]        st_vop   [0:ISSUE_W-1];
   reg [1:0]        st_sew   [0:ISSUE_W-1];
   reg              st_half  [0:ISSUE_W-1];
   reg [TAG_W-1:0]  st_tag   [0:ISSUE_W-1];
   reg [PREG_W-1:0] st_dp    [0:ISSUE_W-1];
   reg [2:0]        st_sv    [0:ISSUE_W-1];   // source valid  (3 sources)
   reg [2:0]        st_got   [0:ISSUE_W-1];   // source latched
   reg [PREG_W-1:0] st_sp0   [0:ISSUE_W-1];
   reg [PREG_W-1:0] st_sp1   [0:ISSUE_W-1];
   reg [PREG_W-1:0] st_sp2   [0:ISSUE_W-1];
   reg [VLEN-1:0]   st_op0   [0:ISSUE_W-1];
   reg [VLEN-1:0]   st_op1   [0:ISSUE_W-1];
   reg [VLEN-1:0]   st_op2   [0:ISSUE_W-1];

   //--- scoreboard --------------------------------------------------------
   reg [NUM_PHYS-1:0] preg_ready;
   assign dbg_preg_ready = preg_ready;

   //--- read request generation ------------------------------------------
   wire [NRD-1:0]        rq_v;
   wire [NRD*PREG_W-1:0] rq_p;

   genvar gs;
   generate
      for (gs = 0; gs < ISSUE_W; gs = gs + 1) begin : g_rreq
         wire collecting = (st_state[gs] == `SLOT_COLLECT);
         assign rq_p[(gs*3+0)*PREG_W +: PREG_W] = st_sp0[gs];
         assign rq_p[(gs*3+1)*PREG_W +: PREG_W] = st_sp1[gs];
         assign rq_p[(gs*3+2)*PREG_W +: PREG_W] = st_sp2[gs];
         assign rq_v[gs*3+0] = collecting & st_sv[gs][0] & ~st_got[gs][0] & preg_ready[st_sp0[gs]];
         assign rq_v[gs*3+1] = collecting & st_sv[gs][1] & ~st_got[gs][1] & preg_ready[st_sp1[gs]];
         assign rq_v[gs*3+2] = collecting & st_sv[gs][2] & ~st_got[gs][2] & preg_ready[st_sp2[gs]];
      end
   endgenerate

   assign rd_req  = rq_v;
   assign rd_preg = rq_p;

   //--- collection completion --------------------------------------------
   wire [2:0] nxt_got [0:ISSUE_W-1];
   wire       coll_done [0:ISSUE_W-1];

   generate
      for (gs = 0; gs < ISSUE_W; gs = gs + 1) begin : g_done
         assign nxt_got[gs] = st_got[gs] | { rq_v[gs*3+2] & rd_grant[gs*3+2],
                                             rq_v[gs*3+1] & rd_grant[gs*3+1],
                                             rq_v[gs*3+0] & rd_grant[gs*3+0] };
         assign coll_done[gs] = (st_state[gs] == `SLOT_COLLECT) &&
                                ((st_sv[gs] & ~nxt_got[gs]) == 3'b000);
      end
   endgenerate

   //=======================================================================
   // Execute / writeback pipes
   //=======================================================================
   reg              ex_v   [0:ISSUE_W-1];
   reg [3:0]        ex_vop [0:ISSUE_W-1];
   reg [1:0]        ex_sew [0:ISSUE_W-1];
   reg              ex_half[0:ISSUE_W-1];
   reg [TAG_W-1:0]  ex_tag [0:ISSUE_W-1];
   reg [PREG_W-1:0] ex_dp  [0:ISSUE_W-1];
   reg [VLEN-1:0]   ex_a   [0:ISSUE_W-1];
   reg [VLEN-1:0]   ex_b   [0:ISSUE_W-1];
   reg [VLEN-1:0]   ex_c   [0:ISSUE_W-1];

   reg              wb_v   [0:ISSUE_W-1];
   reg [TAG_W-1:0]  wb_tag [0:ISSUE_W-1];
   reg [PREG_W-1:0] wb_dp  [0:ISSUE_W-1];
   reg [VLEN-1:0]   wb_res [0:ISSUE_W-1];

   wire [VLEN-1:0]  alu_res [0:ISSUE_W-1];

   generate
      for (gs = 0; gs < ISSUE_W; gs = gs + 1) begin : g_alu
         vector_alu #(.VLEN(VLEN)) u_alu (
            .vop      (ex_vop[gs]),
            .sew_log2 (ex_sew[gs]),
            .half_sel (ex_half[gs]),
            .opa      (ex_a[gs]),
            .opb      (ex_b[gs]),
            .opc      (ex_c[gs]),
            .res      (alu_res[gs])
         );
         assign wr_req [gs]                = wb_v[gs];
         assign wr_preg[gs*PREG_W +: PREG_W] = wb_dp[gs];
         assign wr_data[gs*VLEN   +: VLEN  ] = wb_res[gs];
      end
   endgenerate

   wire wb_fire  [0:ISSUE_W-1];
   wire wb_ready [0:ISSUE_W-1];
   wire ex_fire  [0:ISSUE_W-1];
   wire ex_ready [0:ISSUE_W-1];
   wire coll_fire[0:ISSUE_W-1];

   generate
      for (gs = 0; gs < ISSUE_W; gs = gs + 1) begin : g_flow
         assign wb_fire  [gs] = wb_v[gs] & wr_grant[gs];
         assign wb_ready [gs] = ~wb_v[gs] | wb_fire[gs];
         assign ex_fire  [gs] = ex_v[gs] & wb_ready[gs];
         assign ex_ready [gs] = ~ex_v[gs] | ex_fire[gs];
         assign coll_fire[gs] = coll_done[gs] & ex_ready[gs];
         assign ret_valid[gs] = wb_fire[gs];
         assign ret_tag[gs*TAG_W +: TAG_W] = wb_tag[gs];
      end
   endgenerate

   //=======================================================================
   // Slot refill arbitration (in program order out of the micro-op FIFO)
   //=======================================================================
   wire slot_free0 = (st_state[0] == `SLOT_EMPTY) | coll_fire[0];
   wire slot_free1 = (st_state[1] == `SLOT_EMPTY) | coll_fire[1];

   wire take0 = slot_free0 & (uq_cnt >= 1);
   wire take1 = slot_free1 & (uq_cnt >= (take0 ? 2 : 1));

   wire [UOPQ_AW-1:0] uq_i0 = uq_rd[UOPQ_AW-1:0];
   wire [UOPQ_AW-1:0] uq_i1 = uq_rd[UOPQ_AW-1:0] + (take0 ? 1 : 0);

   //=======================================================================
   // Sequential
   //=======================================================================
   integer n;

   always @(posedge clk or posedge rst) begin
      if (rst) begin
         dq_wr      <= 0;
         dq_rd      <= 0;
         uq_wr      <= 0;
         uq_rd      <= 0;
         exp_i      <= 4'd0;
         uop_count  <= 32'd0;
         preg_ready <= {NUM_PHYS{1'b1}};
         for (n = 0; n < ISSUE_W; n = n + 1) begin
            st_state[n] <= `SLOT_EMPTY;
            st_sv[n]    <= 3'b000;
            st_got[n]   <= 3'b000;
            ex_v[n]     <= 1'b0;
            wb_v[n]     <= 1'b0;
         end
      end else begin
         //--------------------------------------------------------------
         // Descriptor FIFO push
         //--------------------------------------------------------------
         if (desc_valid && desc_ready) begin
            dq_vop [dq_wr[DQ_AW-1:0]] <= desc_vop;
            dq_sew [dq_wr[DQ_AW-1:0]] <= desc_sew_log2;
            dq_wid [dq_wr[DQ_AW-1:0]] <= desc_is_widen;
            dq_nar [dq_wr[DQ_AW-1:0]] <= desc_is_narrow;
            dq_s1u [dq_wr[DQ_AW-1:0]] <= desc_s1_used;
            dq_s2u [dq_wr[DQ_AW-1:0]] <= desc_s2_used;
            dq_nuop[dq_wr[DQ_AW-1:0]] <= desc_nuop;
            dq_tag [dq_wr[DQ_AW-1:0]] <= desc_tag;
            dq_dstp[dq_wr[DQ_AW-1:0]] <= desc_dst_pregs;
            dq_s1p [dq_wr[DQ_AW-1:0]] <= desc_s1_pregs;
            dq_s2p [dq_wr[DQ_AW-1:0]] <= desc_s2_pregs;
            dq_wr <= dq_wr + 1;
         end

         //--------------------------------------------------------------
         // Expansion into the micro-op FIFO
         //--------------------------------------------------------------
         for (n = 0; n < ISSUE_W; n = n + 1)
            if (n < n_emit) begin
               uq_vop [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= h_vop;
               uq_sew [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= h_sew;
               uq_half[uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= e_half[n];
               uq_s0v [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= e_s0v[n];
               uq_s1v [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= e_s1v[n];
               uq_s2v [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= e_s2v[n];
               uq_s0p [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= e_s0p[n];
               uq_s1p [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= e_s1p[n];
               uq_s2p [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= e_s2p[n];
               uq_dp  [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= e_dp[n];
               uq_tag [uq_wr[UOPQ_AW-1:0] + n[UOPQ_AW-1:0]] <= h_tag;
            end
         if (n_emit != 0) begin
            uq_wr     <= uq_wr + n_emit;
            uop_count <= uop_count + n_emit;
            if ((exp_i + n_emit) >= h_nuop) begin
               exp_i <= 4'd0;
               dq_rd <= dq_rd + 1;
            end else begin
               exp_i <= exp_i + n_emit;
            end
         end

         //--------------------------------------------------------------
         // Scoreboard
         //--------------------------------------------------------------
         for (n = 0; n < NUM_PHYS; n = n + 1) begin
            if (set_busy_valid && set_busy_mask[n]) preg_ready[n] <= 1'b0;
            if ((wb_fire[0] && (wb_dp[0] == n[PREG_W-1:0])) ||
                (wb_fire[1] && (wb_dp[1] == n[PREG_W-1:0]))) preg_ready[n] <= 1'b1;
         end

         //--------------------------------------------------------------
         // Slot 0 / slot 1 operand collection
         //--------------------------------------------------------------
         for (n = 0; n < ISSUE_W; n = n + 1) begin
            if (st_state[n] == `SLOT_COLLECT) begin
               if (rq_v[n*3+0] & rd_grant[n*3+0]) st_op0[n] <= rd_data[(n*3+0)*VLEN +: VLEN];
               if (rq_v[n*3+1] & rd_grant[n*3+1]) st_op1[n] <= rd_data[(n*3+1)*VLEN +: VLEN];
               if (rq_v[n*3+2] & rd_grant[n*3+2]) st_op2[n] <= rd_data[(n*3+2)*VLEN +: VLEN];
               st_got[n] <= nxt_got[n];
               if (coll_fire[n]) st_state[n] <= `SLOT_EMPTY;
            end
         end

         //--------------------------------------------------------------
         // Execute pipe
         //--------------------------------------------------------------
         for (n = 0; n < ISSUE_W; n = n + 1) begin
            if (coll_fire[n]) begin
               ex_v   [n] <= 1'b1;
               ex_vop [n] <= st_vop[n];
               ex_sew [n] <= st_sew[n];
               ex_half[n] <= st_half[n];
               ex_tag [n] <= st_tag[n];
               ex_dp  [n] <= st_dp[n];
               ex_a   [n] <= (rq_v[n*3+0] & rd_grant[n*3+0]) ? rd_data[(n*3+0)*VLEN +: VLEN] : st_op0[n];
               ex_b   [n] <= (rq_v[n*3+1] & rd_grant[n*3+1]) ? rd_data[(n*3+1)*VLEN +: VLEN] : st_op1[n];
               ex_c   [n] <= (rq_v[n*3+2] & rd_grant[n*3+2]) ? rd_data[(n*3+2)*VLEN +: VLEN] : st_op2[n];
            end else if (ex_fire[n]) begin
               ex_v[n] <= 1'b0;
            end
         end

         //--------------------------------------------------------------
         // Writeback pipe
         //--------------------------------------------------------------
         for (n = 0; n < ISSUE_W; n = n + 1) begin
            if (ex_fire[n]) begin
               wb_v  [n] <= 1'b1;
               wb_tag[n] <= ex_tag[n];
               wb_dp [n] <= ex_dp[n];
               wb_res[n] <= alu_res[n];
            end else if (wb_fire[n]) begin
               wb_v[n] <= 1'b0;
            end
         end

         //--------------------------------------------------------------
         // Slot refill
         //--------------------------------------------------------------
         if (take0) begin
            st_state[0] <= `SLOT_COLLECT;
            st_vop  [0] <= uq_vop [uq_i0];
            st_sew  [0] <= uq_sew [uq_i0];
            st_half [0] <= uq_half[uq_i0];
            st_tag  [0] <= uq_tag [uq_i0];
            st_dp   [0] <= uq_dp  [uq_i0];
            st_sv   [0] <= {uq_s2v[uq_i0], uq_s1v[uq_i0], uq_s0v[uq_i0]};
            st_got  [0] <= 3'b000;
            st_sp0  [0] <= uq_s0p [uq_i0];
            st_sp1  [0] <= uq_s1p [uq_i0];
            st_sp2  [0] <= uq_s2p [uq_i0];
         end
         if (take1) begin
            st_state[1] <= `SLOT_COLLECT;
            st_vop  [1] <= uq_vop [uq_i1];
            st_sew  [1] <= uq_sew [uq_i1];
            st_half [1] <= uq_half[uq_i1];
            st_tag  [1] <= uq_tag [uq_i1];
            st_dp   [1] <= uq_dp  [uq_i1];
            st_sv   [1] <= {uq_s2v[uq_i1], uq_s1v[uq_i1], uq_s0v[uq_i1]};
            st_got  [1] <= 3'b000;
            st_sp0  [1] <= uq_s0p [uq_i1];
            st_sp1  [1] <= uq_s1p [uq_i1];
            st_sp2  [1] <= uq_s2p [uq_i1];
         end
         uq_rd <= uq_rd + (take0 ? 1 : 0) + (take1 ? 1 : 0);
      end
   end

   //=======================================================================
   // Idle
   //=======================================================================
   assign vu_idle = dq_empty && (uq_cnt == 0) &&
                    (st_state[0] == `SLOT_EMPTY) && (st_state[1] == `SLOT_EMPTY) &&
                    !ex_v[0] && !ex_v[1] && !wb_v[0] && !wb_v[1];

endmodule
