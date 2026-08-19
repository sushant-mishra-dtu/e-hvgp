//==========================================================================
// vrf_bank.v -- one VRF bank
//
// Verilog-2001.
//
// Bank model (identical in BASELINE and E-HVGP):
//   * 1 functional read port  (asynchronous read -> LUTRAM/distributed RAM)
//   * 1 functional write port (synchronous)
//   * therefore AT MOST ONE READ AND ONE WRITE PER BANK PER CYCLE.
//     Arbitration to enforce that lives in vrf_arbiter.v.
//   * 1 extra debug read port used only by the testbench to dump final
//     architectural state.  It is never used by the pipeline, is identical
//     in both configurations, and therefore cannot bias the experiment.
//
// Deterministic power-on contents (same for both configurations) so the
// differential A/B architectural comparison has real data to compare.
//==========================================================================
module vrf_bank #(
   parameter VLEN    = 128,
   parameter DEPTH   = 16,
   parameter AW      = 4,
   parameter BANK_ID = 0
)(
   input  wire            clk,
   input  wire            we,
   input  wire [AW-1:0]   waddr,
   input  wire [VLEN-1:0] wdata,
   input  wire [AW-1:0]   raddr,
   output wire [VLEN-1:0] rdata,
   input  wire [AW-1:0]   dbg_raddr,
   output wire [VLEN-1:0] dbg_rdata
);

   reg [VLEN-1:0] mem [0:DEPTH-1];

   assign rdata     = mem[raddr];
   assign dbg_rdata = mem[dbg_raddr];

   always @(posedge clk)
      if (we) mem[waddr] <= wdata;

   //-----------------------------------------------------------------------
   // Deterministic initial contents.
   // preg id = BANK_ID*DEPTH + slot ; each 32-bit lane gets a fixed hash.
   //-----------------------------------------------------------------------
   integer        i;
   integer        j;
   reg [31:0]     lane;
   reg [31:0]     pid;
   reg [VLEN-1:0] v;

   initial begin
      for (i = 0; i < DEPTH; i = i + 1) begin
         pid = BANK_ID*DEPTH + i;
         v   = {VLEN{1'b0}};
         for (j = 0; j < VLEN/32; j = j + 1) begin
            lane = (pid * 32'h9E3779B9) ^ ((j+1) * 32'h85EBCA6B);
            v[j*32 +: 32] = lane;
         end
         mem[i] = v;
      end
   end

endmodule
