//==========================================================================
// imem.v -- instruction ROM
//
// Verilog-2001.  Word addressed, combinational read.
// Program image is loaded from a hex file named by the +HEX= plusarg so
// that BASELINE and E-HVGP always execute the SAME instruction stream.
//==========================================================================
module imem #(
   parameter DEPTH = 1024,
   parameter AW    = 10
)(
   input  wire [AW-1:0]  addr,
   output wire [31:0]    data
);

   reg [31:0] mem [0:DEPTH-1];
   assign data = mem[addr];

   integer     i;
   reg [1023:0] hexfile;

   initial begin
      for (i = 0; i < DEPTH; i = i + 1)
         mem[i] = 32'h00000073;              // default: ECALL (halt)
      // synthesis translate_off
      if ($value$plusargs("HEX=%s", hexfile))
         $readmemh(hexfile, mem);
      else
         $display("[imem] WARNING: no +HEX=<file> given, ROM is all-halt");
      // synthesis translate_on
   end

endmodule
