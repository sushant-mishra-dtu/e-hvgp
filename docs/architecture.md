# E-HVGP Research Prototype — Implemented Architecture

This document describes **what is actually implemented**, not what is planned.
Everything here is traceable to RTL in `rtl/`.

---

## 1. Parameters (as built)

| Parameter | Value | Where |
|---|---|---|
| `VLEN` | 128 | `rv_core.v` |
| `ELEN` (source elements) | 32 | implicit, `vector_alu.v` |
| Supported `SEW` | 8, 16, 32 | `vector_config.v` |
| Supported `LMUL` | 1, 2, 4, 8 (no fractional) | `vector_config.v` |
| `NUM_VRF_BANKS` | 4 | `rv_core.v` |
| `REGS_PER_BANK` | 16 | `rv_core.v` |
| `NUM_PHYS_VREGS` | 64 | `rv_core.v` |
| `NUM_ARCH` vregs | 32 (fixed by RVV) | — |
| `MAX_GROUP` | 8 physical registers | — |
| `NUM_TOPO` | 8 (= 2 × `NUM_VRF_BANKS`) | `topology_table.v` |
| `ISSUE_W` (operand-collect width) | 2 micro-ops | `vector_unit.v` |
| `CMTQ_DEPTH` (mini-ROB) | 8 | `rv_core.v` |
| VRF read ports | 1 per bank (4 total) | `vrf_bank.v` |
| VRF write ports | 1 per bank (4 total) | `vrf_bank.v` |
| `EHVGP_ENABLE` | 0 = baseline, 1 = E-HVGP | `rv_core.v` |

`NUM_PHYS_VREGS = 64` gives a 2× rename ratio over the 32 architectural
vector registers. Architectural `v0..v31` are mapped at reset to slots
`0..7` of every bank (balanced), leaving slots `8..15` of every bank free.
Both configurations start from **bit-identical** state.

---

## 2. Pipeline

```
  Fetch ─ Decode ─ ScalarExec / Rename+Allocate      (1 instr/cycle, in order)
        │
        └─► vector descriptor queue (depth 4)
              └─► micro-op expander (up to 2 uops/cycle)
                    └─► micro-op queue (depth 16)
                          └─► 2 operand-collect slots  ── VRF read arbitration
                                └─► 2 execute pipes    (1 cycle)
                                      └─► 2 writeback pipes ── VRF write arbitration
                                            └─► in-order commit (mini-ROB, depth 8)
```

The machine is **in-order issue, in-order commit, out-of-order completion
between the two slots**. This is a deliberate simplification (project brief
Section 6): a full OoO scheduler would not change what the experiment
measures, because the destination topology is chosen at Rename in a real OoO
core too (architecture notes Section 6, "Why not Issue or Execute").

The structure is modular enough to be extended: the descriptor queue is
already a decoupling point where a reservation station / wakeup-select
scheduler would drop in without touching `e_hvgp/` or `vrf/`.

### Scalar shim

`LUI, ADDI, ADD, SUB, BNE, ECALL(=halt)` only. Present so `vsetvli`
has an AVL source and so the stress workload can loop. No caches, no MMU,
no privileged architecture, no data memory (project brief Section 7:
"initially defer").

---

## 3. RVV subset implemented

| Instruction | EMUL relationship | Notes |
|---|---|---|
| `vsetvli`, `vsetvl` | — | `SEW` 8/16/32, `LMUL` 1/2/4/8 |
| `vadd.vv`, `vsub.vv` | `EMUL_d = EMUL_s1 = EMUL_s2 = LMUL` | |
| `vmv.v.v` | `EMUL_d = EMUL_s1 = LMUL` | single source |
| `vwadd.vv`, `vwaddu.vv`, `vwsub.vv` | `EMUL_d = 2·LMUL` | |
| `vwmul.vv`, `vwmulu.vv` | `EMUL_d = 2·LMUL` | |
| `vnsrl.wv`, `vnsra.wv` | `EMUL_s2 = 2·LMUL` | 3 source reads per uop |

Real RVV 1.0 encodings are used (see `tests/asm.py`). `SEW=64`,
fractional `LMUL`, masking, floating point, reductions, gather/scatter and
all memory operations are **not** implemented.

`vill` is raised for `SEW=64` and fractional `LMUL`. Widening or narrowing
at `LMUL=8` is rejected (`EMUL=16` exceeds `MAX_GROUP`).

### VL handling

`VLMAX = (VLEN/SEW)·LMUL`, `VL = min(AVL, VLMAX)`. The micro-op count is
clipped by VL: micro-ops whose entire element range lies beyond VL are never
issued. A *partially* active destination register is still written in full
(tail-agnostic-with-computed-values). All shipped tests run at `VL = VLMAX`
so this deviation is never exercised — see `docs/verification.md`.

---

## 4. Architectural grouping vs physical placement

These are kept strictly separate, which is the whole point of the project.

* **Architectural grouping** (`rtl/decode/rvv_decode.v`) computes `EMUL_dst`,
  `EMUL_s1`, `EMUL_s2` from the opcode and current `vtype`. This is pure RVV
  semantics.
* **Physical placement** (`rtl/e_hvgp/`) decides which VRF banks the group's
  physical registers live in. RVV says nothing about this; it is entirely a
  microarchitectural choice.

Nothing downstream of Rename knows which placement policy is in effect. The
vector unit and the VRF only ever see physical register numbers.

---

## 5. Physical register numbering and the RAT

Register-granularity banking (architecture notes Section 1 and Section 11.1
resolved in favour of register granularity):

```
preg = bank · REGS_PER_BANK + slot
```

A group of `G` registers with topology `t = (start, stride)` and base slot
`s` occupies, for `i = 0..G-1`:

```
bank_i = (start + i·stride) mod NUM_BANKS
slot_i = s + (i div NUM_BANKS)
```

The `slot_i` term handles `G > NUM_BANKS`: `bank(i)` has period `NUM_BANKS`,
so registers `i` and `i+NUM_BANKS` share a bank and must sit in different
slots. This is what makes `LMUL=8` / `EMUL=8` groups representable.

### RAT contents — deviation from the notes, and why

The architecture notes (Section 6) recommend storing `physical_base_id +
topology_id` per architectural register. This implementation stores three
fields per architectural vector register:

```
rat_slot[a]   physical base slot of the group that last wrote a   (4 bits)
rat_topo[a]   topology id of that group                           (3 bits)
rat_idx [a]   a's index within that group                         (3 bits)
```

`preg(a)` is **derived**, never stored: `f_preg(rat_topo[a], rat_slot[a],
rat_idx[a])`. Total = 10 bits/register, versus 6 bits for a raw physical
register list — the notes' saving over a full list is preserved.

The extra `rat_idx` field over the notes' pure `(base, topology)` pair costs
3 bits and buys correctness under **group re-aliasing**: writing a size-2
group on top of registers already covered by a live size-4 group. With a
pure base+topology RAT read only at the group base, that case silently
returns stale physical registers. `rat_idx` makes every architectural
register self-describing. Documented as decision **D-RAT**.

---

## 6. Free list and allocation

One free bit per physical register (`free_vec[64]`). Allocating a group of
`G` registers with topology `t` requires a base slot `s` such that all `G`
derived physical registers are free and `s + ceil(G/B) - 1 < REGS_PER_BANK`.
The search is a **lowest-slot-first scan** and is byte-identical in both
configurations, so any behavioural difference comes from the topology and
never from the search.

Physical registers are released **at commit**: the mini-ROB entry carries
the displaced mapping's register mask (`old_free_mask`), captured at rename.
In-order commit makes this safe without any additional interlock.

---

## 7. Micro-op model

Register-granularity decomposition — one micro-op per **destination**
physical register (architecture notes Section 5.1, recommended option).
**Identical in both configurations** (project brief Section 16).

| shape | uops | reads per uop | writes per uop |
|---|---|---|---|
| same-width | `EMUL_d` | 2 (`vs1[i]`, `vs2[i]`) | 1 |
| `vmv.v.v` | `EMUL_d` | 1 (`vs1[i]`) | 1 |
| widening | `EMUL_d = 2·LMUL` | 2 (`vs1[i>>1]`, `vs2[i>>1]`) | 1 |
| narrowing | `EMUL_d = LMUL` | 3 (`vs1[i]`, `vs2[2i]`, `vs2[2i+1]`) | 1 |

`half_sel = i[0]` selects which half of a widening source register's
elements the micro-op consumes.

The asymmetric read counts are the direct structural consequence of
`EMUL != LMUL` — they are the thing the experiment measures.

---

## 8. Bank conflict model

Documented arbitration policy (`rtl/vrf/vrf_arbiter.v`), **identical in both
configurations**:

* Each bank accepts **at most one read and at most one write per cycle**.
* Read request priority order is fixed: `slot0.src0, slot0.src1, slot0.src2,
  slot1.src0, slot1.src1, slot1.src2`. Write priority: `slot0, slot1`.
* Losers are not granted and re-present the identical request next cycle.
  No reordering, no bypass, no replay penalty beyond the lost cycle.
* A request is only *presented* once its source physical register is ready
  (scoreboard). A presented-but-not-granted request is **one bank conflict**.
  RAW waiting is never counted as a conflict.
* A cycle containing at least one denial is **one bank stall cycle**.

VRF reads are asynchronous (LUTRAM-style); writes are synchronous. A
physical register becomes readable the cycle after its write is granted.

---

## 9. Performance counters

All are in `rv_core.v` and exported as ports (no hierarchical references
needed in the testbench):

`cycle_count`, `instr_count`, `vinstr_count`, `vuop_count`,
`vrf_read_requests`, `vrf_write_requests`, `bank_conflict_count`,
`bank_read_conflicts`, `bank_write_conflicts`, `bank_stall_cycles`,
`rename_stall_cycles`, `widening_count`, `narrowing_count`,
`topo_alloc[0..7]`.

---

## 10. Language and tool compliance

* Plain **Verilog-2001** throughout (`.v` / `.vh`). No `logic`, `always_ff`,
  `always_comb`, `typedef`, `enum`, `struct`, `interface`, packages, or SVA.
* Simulation-only code (`$readmemh` from a plusarg, assertions, trace
  `$display`) is wrapped in `// synthesis translate_off` / `translate_on`.
* Xcelium is the primary simulator (`sim/run_xcelium.sh`). Icarus Verilog
  is used as a local proof-of-correctness harness (`sim/run_iverilog.ps1`);
  no construct in the RTL is tailored to either tool.
* Vivado out-of-context synthesis script in `vivado/synth.tcl`.

### Signals worth probing in SimVision

`clk`, `rst`, `dut.pc`, `dut.instr`, `dut.sew_log2`, `dut.lmul_log2`,
`dut.dbg_vl`, `dut.g_dst`, `dut.nuop_eff`, `dut.u_rename.sel_topo`,
`dut.u_rename.sel_slot`, `dut.u_rename.u_alloc_policy.dbg_rr_base`,
`dut.u_rename.u_alloc_policy.u_sel.sel_cost`, `dut.u_vrf.rd_req`,
`dut.u_vrf.rd_grant`, `dut.u_vrf.rd_denied`, `dut.u_vrf.wr_denied`,
`dut.bank_conflict_count`, `dut.bank_stall_cycles`.
Run with `+TRACE` for a per-allocation textual log.
