//==========================================================================
// tb_top.v -- E-HVGP experiment testbench
//
// Verilog-2001 only.  No SystemVerilog assertions, no classes, no
// interfaces.  Uses initial/always, tasks, functions, $display, $finish.
//
// Plusargs:
//   +HEX=<file>    program image (required)
//   +ARCH=<file>   write architectural state dump here
//   +PLACE=<file>  write physical placement dump here
//   +NAME=<str>    test name for the banner
//   +MAXCYC=<n>    timeout (default 200000)
//   +WAVE          enable waveform dump
//
// Compile-time:
//   +define+EHVGP  build the E-HVGP configuration (else BASELINE)
//==========================================================================
`timescale 1ns/1ps

module tb_top;

`ifdef EHVGP
   localparam EHVGP_ENABLE = 1;
`else
   localparam EHVGP_ENABLE = 0;
`endif

   localparam VLEN          = 128;
   localparam VLEN_LOG2     = 7;
   localparam NUM_BANKS     = 4;
   localparam REGS_PER_BANK = 16;
   localparam NUM_PHYS      = 64;
   localparam NUM_ARCH      = 32;
   localparam BID_W         = 2;
   localparam TID_W         = 3;
   localparam SLOT_W        = 4;
   localparam PREG_W        = 6;
   localparam IDX_W         = 3;
   localparam MAX_GROUP     = 8;
   localparam NUM_TOPO      = 8;
   localparam ISSUE_W       = 2;

   reg  clk = 1'b0;
   reg  rst = 1'b1;

   wire        halted;
   wire [31:0] cycle_count, instr_count, vinstr_count, vuop_count;
   wire [31:0] vrf_read_requests, vrf_write_requests;
   wire [31:0] bank_conflict_count, bank_read_conflicts, bank_write_conflicts;
   wire [31:0] bank_stall_cycles, widening_count, narrowing_count;
   wire [31:0] rename_stall_cycles;
   wire [31:0] stall_alloc_cycles, stall_desc_cycles, stall_cmtq_cycles;
   wire [NUM_TOPO*32-1:0] topo_alloc;

   reg  [4:0]        dbg_arch = 5'd0;
   wire [PREG_W-1:0] dbg_preg;
   wire [TID_W-1:0]  dbg_topo;
   wire [SLOT_W-1:0] dbg_slot;
   wire [IDX_W-1:0]  dbg_idx;
   wire [VLEN-1:0]   dbg_vdata;
   wire [10:0]       dbg_vtype;
   wire [31:0]       dbg_vl;
   wire              dbg_vill;
   wire [31:0]       dbg_pc;
   reg  [4:0]        dbg_xreg = 5'd0;
   wire [31:0]       dbg_xdata;

   //=======================================================================
   // DUT
   //=======================================================================
   rv_core #(
      .VLEN(VLEN), .VLEN_LOG2(VLEN_LOG2), .NUM_BANKS(NUM_BANKS),
      .REGS_PER_BANK(REGS_PER_BANK), .NUM_PHYS(NUM_PHYS), .NUM_ARCH(NUM_ARCH),
      .BID_W(BID_W), .TID_W(TID_W), .SLOT_W(SLOT_W), .PREG_W(PREG_W),
      .IDX_W(IDX_W), .MAX_GROUP(MAX_GROUP), .NUM_TOPO(NUM_TOPO),
      .ISSUE_W(ISSUE_W), .EHVGP_ENABLE(EHVGP_ENABLE)
   ) dut (
      .clk(clk), .rst(rst), .halted(halted),
      .cycle_count(cycle_count), .instr_count(instr_count),
      .vinstr_count(vinstr_count), .vuop_count(vuop_count),
      .vrf_read_requests(vrf_read_requests),
      .vrf_write_requests(vrf_write_requests),
      .bank_conflict_count(bank_conflict_count),
      .bank_read_conflicts(bank_read_conflicts),
      .bank_write_conflicts(bank_write_conflicts),
      .bank_stall_cycles(bank_stall_cycles),
      .widening_count(widening_count), .narrowing_count(narrowing_count),
      .rename_stall_cycles(rename_stall_cycles),
      .stall_alloc_cycles(stall_alloc_cycles),
      .stall_desc_cycles(stall_desc_cycles),
      .stall_cmtq_cycles(stall_cmtq_cycles),
      .topo_alloc(topo_alloc),
      .dbg_arch(dbg_arch), .dbg_preg(dbg_preg), .dbg_topo(dbg_topo),
      .dbg_slot(dbg_slot), .dbg_idx(dbg_idx), .dbg_vdata(dbg_vdata),
      .dbg_vtype(dbg_vtype), .dbg_vl(dbg_vl), .dbg_vill(dbg_vill),
      .dbg_pc(dbg_pc), .dbg_xreg(dbg_xreg), .dbg_xdata(dbg_xdata)
   );

   always #5 clk = ~clk;

   //=======================================================================
   // Plusargs
   //=======================================================================
   reg [1023:0] arch_file;
   reg [1023:0] place_file;
   reg [1023:0] test_name;
   integer      max_cycles;
   integer      fa, fp;
   integer      a, t;
   integer      errors;

   initial begin
      if (!$value$plusargs("ARCH=%s",  arch_file))  arch_file  = "arch.txt";
      if (!$value$plusargs("PLACE=%s", place_file)) place_file = "place.txt";
      if (!$value$plusargs("NAME=%s",  test_name))  test_name  = "unnamed";
      if (!$value$plusargs("MAXCYC=%d", max_cycles)) max_cycles = 200000;
   end

   //=======================================================================
   // Waveforms
   //=======================================================================
   initial begin
      if ($test$plusargs("WAVE")) begin
`ifdef XCELIUM
         $shm_open("waves.shm");
         $shm_probe(tb_top, "AC");
`else
         $dumpfile("waves.vcd");
         $dumpvars(0, tb_top);
`endif
      end
   end

   //=======================================================================
   // Run
   //=======================================================================
   integer guard;

   initial begin
      errors = 0;
      repeat (5) @(posedge clk);
      rst = 1'b0;

      guard = 0;
      while (!halted && (guard < max_cycles)) begin
         @(posedge clk);
         guard = guard + 1;
      end

      if (!halted) begin
         $display("");
         $display("*** TIMEOUT after %0d cycles -- core never halted ***", guard);
         errors = errors + 1;
      end

      @(posedge clk);
      report;
      dump_state;

      if (errors != 0) $display("RESULT: FAIL (%0d errors)", errors);
      else             $display("RESULT: PASS");
      $finish;
   end

   //=======================================================================
   // Reporting
   //=======================================================================
   task report;
      begin
         $display("");
         $display("==========================================");
         $display(" E-HVGP TEST");
         $display("==========================================");
         $display("");
         $display(" Test:                %0s", test_name);
         $display(" Mode:                %0s", EHVGP_ENABLE ? "E-HVGP" : "BASELINE");
         $display("");
         $display(" Cycles:              %0d", cycle_count);
         $display(" Instructions:        %0d", instr_count);
         $display(" Vector instructions: %0d", vinstr_count);
         $display("   widening:          %0d", widening_count);
         $display("   narrowing:         %0d", narrowing_count);
         $display(" Vector micro-ops:    %0d", vuop_count);
         $display(" VRF read  accesses:  %0d", vrf_read_requests);
         $display(" VRF write accesses:  %0d", vrf_write_requests);
         $display(" VRF accesses (tot):  %0d", vrf_read_requests + vrf_write_requests);
         $display(" Bank conflicts:      %0d", bank_conflict_count);
         $display("   read conflicts:    %0d", bank_read_conflicts);
         $display("   write conflicts:   %0d", bank_write_conflicts);
         $display(" Bank stall cycles:   %0d", bank_stall_cycles);
         $display(" Rename stall cycles: %0d", rename_stall_cycles);
         $display("   free-list fit:     %0d", stall_alloc_cycles);
         $display("   descriptor queue:  %0d", stall_desc_cycles);
         $display("   mini-ROB full:     %0d", stall_cmtq_cycles);
         $display("   (causes overlap; they do not sum to the total)");
         $display("");
         $display(" Topology allocations (start_bank, stride):");
         for (t = 0; t < NUM_TOPO; t = t + 1)
            $display("   topo %0d = (start %0d, stride %0d) : %0d",
                     t, t[BID_W-1:0], (t >= (NUM_TOPO/2)) ? (NUM_BANKS-1) : 1,
                     topo_alloc[t*32 +: 32]);
         $display("");
         $display(" Final vtype = 0x%03x  vl = %0d  vill = %0d",
                  dbg_vtype, dbg_vl, dbg_vill);
         $display("==========================================");
         $display("");
      end
   endtask

   //=======================================================================
   // State dump
   //
   //   *.arch  = ARCHITECTURAL state only.  MUST be byte-identical between
   //             BASELINE and E-HVGP.
   //   *.place = PHYSICAL placement.  Expected to differ; that is the
   //             mechanism under test.
   //=======================================================================
   task dump_state;
      begin
         fa = $fopen(arch_file, "w");
         fp = $fopen(place_file, "w");

         $fdisplay(fa, "# architectural state : %0s", test_name);
         $fdisplay(fa, "vtype %03x", dbg_vtype);
         $fdisplay(fa, "vl    %0d",  dbg_vl);
         $fdisplay(fa, "vill  %0d",  dbg_vill);

         $fdisplay(fp, "# physical placement : %0s  mode=%0s",
                   test_name, EHVGP_ENABLE ? "E-HVGP" : "BASELINE");

         for (a = 0; a < NUM_ARCH; a = a + 1) begin
            dbg_arch = a[4:0];
            #1;
            $fdisplay(fa, "v%0d %032x", a, dbg_vdata);
            $fdisplay(fp, "v%0d preg=%0d bank=%0d slot=%0d topo=%0d idx=%0d",
                      a, dbg_preg, dbg_preg / REGS_PER_BANK,
                      dbg_preg % REGS_PER_BANK, dbg_topo, dbg_idx);
         end
         for (a = 0; a < 32; a = a + 1) begin
            dbg_xreg = a[4:0];
            #1;
            $fdisplay(fa, "x%0d %08x", a, dbg_xdata);
         end

         $fdisplay(fp, "# counters");
         $fdisplay(fp, "cycles              %0d", cycle_count);
         $fdisplay(fp, "instructions        %0d", instr_count);
         $fdisplay(fp, "vector_instructions %0d", vinstr_count);
         $fdisplay(fp, "vector_uops         %0d", vuop_count);
         $fdisplay(fp, "vrf_read_requests   %0d", vrf_read_requests);
         $fdisplay(fp, "vrf_write_requests  %0d", vrf_write_requests);
         $fdisplay(fp, "bank_conflicts      %0d", bank_conflict_count);
         $fdisplay(fp, "bank_read_conflicts %0d", bank_read_conflicts);
         $fdisplay(fp, "bank_write_conflict %0d", bank_write_conflicts);
         $fdisplay(fp, "bank_stall_cycles   %0d", bank_stall_cycles);
         $fdisplay(fp, "rename_stall_cycles %0d", rename_stall_cycles);
         $fdisplay(fp, "stall_alloc_cycles  %0d", stall_alloc_cycles);
         $fdisplay(fp, "stall_desc_cycles   %0d", stall_desc_cycles);
         $fdisplay(fp, "stall_cmtq_cycles   %0d", stall_cmtq_cycles);
         $fdisplay(fp, "widening            %0d", widening_count);
         $fdisplay(fp, "narrowing           %0d", narrowing_count);
         for (t = 0; t < NUM_TOPO; t = t + 1)
            $fdisplay(fp, "topo_%0d_allocations  %0d", t, topo_alloc[t*32 +: 32]);

         $fclose(fa);
         $fclose(fp);
      end
   endtask

endmodule
