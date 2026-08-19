//==========================================================================
// ehvgp_funcs.vh -- topology / physical-placement functions (Verilog-2001)
//
// This file is `include`d INSIDE a module body.  The enclosing module must
// declare the following parameters (or localparams) before the include:
//
//     NUM_BANKS       number of VRF banks               (power of two)
//     BID_W           $clog2(NUM_BANKS)
//     TID_W           BID_W + 1        (topology id width)
//     REGS_PER_BANK   physical registers resident in one bank
//     SLOT_W          $clog2(REGS_PER_BANK)
//     PREG_W          $clog2(NUM_BANKS*REGS_PER_BANK)
//
//--------------------------------------------------------------------------
// TOPOLOGY ENCODING
//--------------------------------------------------------------------------
//   topo_id[BID_W-1:0] = start_bank
//   topo_id[TID_W-1]   = stride select :  0 -> stride 1
//                                         1 -> stride NUM_BANKS-1
//
//   Only strides coprime with NUM_BANKS are representable.  For a power-of-
//   two NUM_BANKS both 1 and NUM_BANKS-1 are coprime with NUM_BANKS, so the
//   whole encoded space is legal for group sizes <= NUM_BANKS.  Legality is
//   still checked explicitly by f_topo_legal() rather than assumed.
//
//   bank(i) = (start_bank + i*stride) mod NUM_BANKS
//
//--------------------------------------------------------------------------
// PHYSICAL REGISTER NUMBERING
//--------------------------------------------------------------------------
//   A physical vector register is one bank-resident unit (register-
//   granularity banking, per architecture notes Section 1).
//
//     preg = bank * REGS_PER_BANK + slot
//
//   A vector register group of G registers with topology t and base slot s
//   occupies, for i = 0..G-1:
//
//     bank_i = (start + i*stride) mod NUM_BANKS
//     slot_i = s + (i / NUM_BANKS)
//
//   The slot term handles G > NUM_BANKS: bank(i) has period NUM_BANKS, so
//   registers i and i+NUM_BANKS share a bank and must occupy distinct slots.
//==========================================================================

// bank index of the i-th register of a group placed with topology t
function [BID_W-1:0] f_bank;
   input [TID_W-1:0] t;
   input [3:0]       i;
   reg   [15:0]      sb;
   reg   [15:0]      st;
   reg   [15:0]      p;
   begin
      sb    = {{(16-BID_W){1'b0}}, t[BID_W-1:0]};
      st    = t[TID_W-1] ? (NUM_BANKS-1) : 16'd1;
      p     = (sb + i*st) % NUM_BANKS;
      f_bank = p[BID_W-1:0];
   end
endfunction

// slot index of the i-th register of a group whose base slot is base_slot
function [SLOT_W-1:0] f_slot;
   input [SLOT_W-1:0] base_slot;
   input [3:0]        i;
   reg   [15:0]       q;
   begin
      q      = i / NUM_BANKS;
      f_slot = base_slot + q[SLOT_W-1:0];
   end
endfunction

// physical register id of the i-th register of a group
function [PREG_W-1:0] f_preg;
   input [TID_W-1:0]  t;
   input [SLOT_W-1:0] base_slot;
   input [3:0]        i;
   reg   [15:0]       b;
   reg   [15:0]       s;
   begin
      b      = {{(16-BID_W){1'b0}},  f_bank(t,i)};
      s      = {{(16-SLOT_W){1'b0}}, f_slot(base_slot,i)};
      f_preg = (b*REGS_PER_BANK + s);
   end
endfunction

// bank of a raw physical register id
function [BID_W-1:0] f_preg_bank;
   input [PREG_W-1:0] p;
   reg   [15:0]       q;
   begin
      q           = p / REGS_PER_BANK;
      f_preg_bank = q[BID_W-1:0];
   end
endfunction

// slot of a raw physical register id
function [SLOT_W-1:0] f_preg_slot;
   input [PREG_W-1:0] p;
   reg   [15:0]       q;
   begin
      q           = p % REGS_PER_BANK;
      f_preg_slot = q[SLOT_W-1:0];
   end
endfunction

//--------------------------------------------------------------------------
// TOPOLOGY LEGALITY
//--------------------------------------------------------------------------
// A topology is legal for group size g iff the first min(g,NUM_BANKS)
// registers of the group land in DISTINCT banks.  If they do not, the group
// self-conflicts on every concurrent multi-register access of its own
// registers (architecture notes Section 6, gcd(stride,B) != 1 case).
//
// This is checked structurally (pairwise bank comparison) rather than by
// assuming the gcd rule, so it stays correct for any NUM_BANKS.
//--------------------------------------------------------------------------
function f_topo_legal;
   input [TID_W-1:0] t;
   input [3:0]       g;
   integer           a;
   integer           b;
   integer           n;
   reg               ok;
   begin
      n  = (g > NUM_BANKS) ? NUM_BANKS : g;
      ok = 1'b1;
      for (a = 0; a < NUM_BANKS; a = a + 1)
         for (b = 0; b < NUM_BANKS; b = b + 1)
            if ((a < b) && (a < n) && (b < n))
               if (f_bank(t, a[3:0]) == f_bank(t, b[3:0]))
                  ok = 1'b0;
      f_topo_legal = ok;
   end
endfunction
