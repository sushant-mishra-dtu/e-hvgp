//==========================================================================
// vrf.v -- banked vector register file with per-bank arbitration
//
// Verilog-2001.
//
//   NUM_PHYS = NUM_BANKS * REGS_PER_BANK physical vector registers,
//   each VLEN bits, register-granularity banked:
//
//       preg = bank * REGS_PER_BANK + slot
//
//   Bandwidth (identical in BASELINE and E-HVGP):
//       NUM_BANKS read  accesses / cycle, max 1 per bank
//       NUM_BANKS write accesses / cycle, max 1 per bank
//
//   NRD read requesters and NWR write requesters contend; fixed-priority
//   per-bank arbitration (see vrf_arbiter.v).  Denied requests are
//   reported so the core can count conflicts and stall cycles.
//==========================================================================
module vrf #(
   parameter VLEN          = 128,
   parameter NUM_BANKS     = 4,
   parameter REGS_PER_BANK = 16,
   parameter BID_W         = 2,
   parameter TID_W         = 3,   // used only by the shared placement functions
   parameter SLOT_W        = 4,
   parameter PREG_W        = 6,
   parameter NRD           = 6,
   parameter NWR           = 2
)(
   input  wire                      clk,

   // read requests
   input  wire [NRD-1:0]            rd_req,
   input  wire [NRD*PREG_W-1:0]     rd_preg,
   output wire [NRD-1:0]            rd_grant,
   output wire [NRD*VLEN-1:0]       rd_data,

   // write requests
   input  wire [NWR-1:0]            wr_req,
   input  wire [NWR*PREG_W-1:0]     wr_preg,
   input  wire [NWR*VLEN-1:0]       wr_data,
   output wire [NWR-1:0]            wr_grant,

   // conflict reporting
   output wire [7:0]                rd_denied,
   output wire [7:0]                wr_denied,
   output wire [NUM_BANKS-1:0]      rd_bank_en,
   output wire [NUM_BANKS-1:0]      wr_bank_en,

   // debug/backdoor read port (combinational, no arbitration, TB only)
   input  wire [PREG_W-1:0]         dbg_preg,
   output wire [VLEN-1:0]           dbg_data
);

`include "ehvgp_funcs.vh"

   //-----------------------------------------------------------------------
   // Split requester preg into (bank, slot)
   //-----------------------------------------------------------------------
   wire [NRD*BID_W-1:0]  rd_bank;
   wire [NRD*SLOT_W-1:0] rd_slot;
   wire [NWR*BID_W-1:0]  wr_bank;
   wire [NWR*SLOT_W-1:0] wr_slot;

   genvar gi;
   generate
      for (gi = 0; gi < NRD; gi = gi + 1) begin : g_rdsplit
         assign rd_bank[gi*BID_W  +: BID_W ] = f_preg_bank(rd_preg[gi*PREG_W +: PREG_W]);
         assign rd_slot[gi*SLOT_W +: SLOT_W] = f_preg_slot(rd_preg[gi*PREG_W +: PREG_W]);
      end
      for (gi = 0; gi < NWR; gi = gi + 1) begin : g_wrsplit
         assign wr_bank[gi*BID_W  +: BID_W ] = f_preg_bank(wr_preg[gi*PREG_W +: PREG_W]);
         assign wr_slot[gi*SLOT_W +: SLOT_W] = f_preg_slot(wr_preg[gi*PREG_W +: PREG_W]);
      end
   endgenerate

   //-----------------------------------------------------------------------
   // Arbitration
   //-----------------------------------------------------------------------
   wire [NUM_BANKS*BID_W-1:0] rd_sel_dbg;
   wire [NUM_BANKS*BID_W-1:0] wr_sel_dbg;

   vrf_arbiter #(.NREQ(NRD), .NUM_BANKS(NUM_BANKS), .BID_W(BID_W)) u_rarb (
      .req_valid    (rd_req),
      .req_bank     (rd_bank),
      .grant        (rd_grant),
      .bank_en      (rd_bank_en),
      .bank_sel_dbg (rd_sel_dbg),
      .n_denied     (rd_denied)
   );

   vrf_arbiter #(.NREQ(NWR), .NUM_BANKS(NUM_BANKS), .BID_W(BID_W)) u_warb (
      .req_valid    (wr_req),
      .req_bank     (wr_bank),
      .grant        (wr_grant),
      .bank_en      (wr_bank_en),
      .bank_sel_dbg (wr_sel_dbg),
      .n_denied     (wr_denied)
   );

   //-----------------------------------------------------------------------
   // Per-bank address / data muxes
   //-----------------------------------------------------------------------
   reg  [NUM_BANKS*SLOT_W-1:0] bank_raddr;
   reg  [NUM_BANKS*SLOT_W-1:0] bank_waddr;
   reg  [NUM_BANKS*VLEN-1:0]   bank_wdata;
   wire [NUM_BANKS*VLEN-1:0]   bank_rdata;
   wire [NUM_BANKS*VLEN-1:0]   bank_rdata_dbg;

   integer b, r;
   always @(*) begin
      bank_raddr = {NUM_BANKS*SLOT_W{1'b0}};
      bank_waddr = {NUM_BANKS*SLOT_W{1'b0}};
      bank_wdata = {NUM_BANKS*VLEN{1'b0}};
      for (b = 0; b < NUM_BANKS; b = b + 1) begin
         for (r = 0; r < NRD; r = r + 1)
            if (rd_grant[r] && (rd_bank[r*BID_W +: BID_W] == b[BID_W-1:0]))
               bank_raddr[b*SLOT_W +: SLOT_W] = rd_slot[r*SLOT_W +: SLOT_W];
         for (r = 0; r < NWR; r = r + 1)
            if (wr_grant[r] && (wr_bank[r*BID_W +: BID_W] == b[BID_W-1:0])) begin
               bank_waddr[b*SLOT_W +: SLOT_W] = wr_slot[r*SLOT_W +: SLOT_W];
               bank_wdata[b*VLEN   +: VLEN  ] = wr_data[r*VLEN   +: VLEN  ];
            end
      end
   end

   //-----------------------------------------------------------------------
   // Banks
   //-----------------------------------------------------------------------
   wire [SLOT_W-1:0] dbg_slot;
   wire [BID_W-1:0]  dbg_bank;
   assign dbg_bank = f_preg_bank(dbg_preg);
   assign dbg_slot = f_preg_slot(dbg_preg);

   generate
      for (gi = 0; gi < NUM_BANKS; gi = gi + 1) begin : g_bank
         vrf_bank #(
            .VLEN   (VLEN),
            .DEPTH  (REGS_PER_BANK),
            .AW     (SLOT_W),
            .BANK_ID(gi)
         ) u_bank (
            .clk       (clk),
            .we        (wr_bank_en[gi]),
            .waddr     (bank_waddr[gi*SLOT_W +: SLOT_W]),
            .wdata     (bank_wdata[gi*VLEN   +: VLEN  ]),
            .raddr     (bank_raddr[gi*SLOT_W +: SLOT_W]),
            .rdata     (bank_rdata[gi*VLEN   +: VLEN  ]),
            .dbg_raddr (dbg_slot),
            .dbg_rdata (bank_rdata_dbg[gi*VLEN +: VLEN])
         );
      end
   endgenerate

   //-----------------------------------------------------------------------
   // Read data return (each requester sees its own bank's output)
   //-----------------------------------------------------------------------
   reg [NRD*VLEN-1:0] rd_data_r;
   integer            k;
   always @(*) begin
      rd_data_r = {NRD*VLEN{1'b0}};
      for (k = 0; k < NRD; k = k + 1)
         for (b = 0; b < NUM_BANKS; b = b + 1)
            if (rd_bank[k*BID_W +: BID_W] == b[BID_W-1:0])
               rd_data_r[k*VLEN +: VLEN] = bank_rdata[b*VLEN +: VLEN];
   end
   assign rd_data = rd_data_r;

   //-----------------------------------------------------------------------
   // Debug backdoor read
   //-----------------------------------------------------------------------
   reg [VLEN-1:0] dbg_data_r;
   always @(*) begin
      dbg_data_r = {VLEN{1'b0}};
      for (b = 0; b < NUM_BANKS; b = b + 1)
         if (dbg_bank == b[BID_W-1:0])
            dbg_data_r = bank_rdata_dbg[b*VLEN +: VLEN];
   end
   assign dbg_data = dbg_data_r;

endmodule
