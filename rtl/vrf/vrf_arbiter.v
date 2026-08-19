//==========================================================================
// vrf_arbiter.v -- fixed-priority per-bank arbiter
//
// Verilog-2001.  Purely combinational.
//
//--------------------------------------------------------------------------
// ARBITRATION POLICY (identical for BASELINE and E-HVGP)
//--------------------------------------------------------------------------
//   * Each bank accepts AT MOST ONE request per cycle.
//   * Among the requests targeting a given bank in a cycle, the one with
//     the LOWEST request index wins.  Request indices are assigned in
//     program/slot order (slot 0 sources first, then slot 1 sources), so
//     the policy is "oldest micro-op wins, first source operand first".
//   * Losers are not granted and re-present the identical request next
//     cycle.  There is no reordering, no bypass, no replay penalty beyond
//     the lost cycle.
//
//   Every presented-but-not-granted request counts as ONE bank conflict.
//   A cycle in which at least one request was denied counts as ONE bank
//   stall cycle.
//--------------------------------------------------------------------------
module vrf_arbiter #(
   parameter NREQ      = 6,
   parameter NUM_BANKS = 4,
   parameter BID_W     = 2
)(
   input  wire [NREQ-1:0]           req_valid,
   input  wire [NREQ*BID_W-1:0]     req_bank,

   output reg  [NREQ-1:0]           grant,
   output reg  [NUM_BANKS-1:0]      bank_en,
   output reg  [NUM_BANKS*BID_W-1:0] bank_sel_dbg,  // winning req idx (debug)
   output reg  [7:0]                n_denied
);

   integer            r;
   reg [NUM_BANKS-1:0] taken;
   reg [BID_W-1:0]     b;

   always @(*) begin
      grant        = {NREQ{1'b0}};
      taken        = {NUM_BANKS{1'b0}};
      bank_en      = {NUM_BANKS{1'b0}};
      bank_sel_dbg = {NUM_BANKS*BID_W{1'b0}};
      n_denied     = 8'd0;

      for (r = 0; r < NREQ; r = r + 1) begin
         b = req_bank[r*BID_W +: BID_W];
         if (req_valid[r]) begin
            if (!taken[b]) begin
               taken[b]   = 1'b1;
               grant[r]   = 1'b1;
               bank_en[b] = 1'b1;
               bank_sel_dbg[b*BID_W +: BID_W] = r[BID_W-1:0];
            end else begin
               n_denied = n_denied + 8'd1;
            end
         end
      end
   end

endmodule
