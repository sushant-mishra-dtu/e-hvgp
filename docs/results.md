# Measured Results

**All numbers on this page are produced by simulation. Nothing is estimated,
extrapolated or invented.** Reproduce with `.\sim\run_iverilog.ps1` then
`python sim/compare.py`, or `./sim/run_xcelium.sh` on an Xcelium host.

* Date: 2026-08-14
* Simulator: Icarus Verilog 12.0 (Xcelium not installed on this machine; the
  RTL is plain Verilog-2001 and the Xcelium flow is in `sim/run_xcelium.sh`)
* Configuration: `VLEN=128`, `NUM_VRF_BANKS=4`, `NUM_PHYS_VREGS=64`,
  `REGS_PER_BANK=16`, `ISSUE_W=2`, 1 read + 1 write per bank per cycle

---

## 1. Correctness gate

| Test | architectural state identical | physical placement lines differing (of 32) |
|---|---|---|
| `same` | **YES** | 14 |
| `widening` | **YES** | 24 |
| `narrowing` | **YES** | 28 |
| `mixed` | **YES** | 26 |
| `stress` | **YES** | 32 |

Both configurations produce byte-identical architectural results (32 vector
registers + 32 scalar registers + `vtype`/`vl`/`vill`) while placing groups
differently. In-RTL legality/freeness/distinctness assertions passed on
every allocation in every run.

---

## 2. Table 1 — structural fairness counters

These must be identical for the comparison to be meaningful. They are.

| Test | instr | vector instr | vector uops | VRF reads | VRF writes |
|---|---|---|---|---|---|
| `same` | 13 / 13 | 12 / 12 | 24 / 24 | 46 / 46 | 24 / 24 |
| `widening` | 13 / 13 | 12 / 12 | 48 / 48 | 96 / 96 | 48 / 48 |
| `narrowing` | 13 / 13 | 12 / 12 | 32 / 32 | 80 / 80 | 32 / 32 |
| `mixed` | 19 / 19 | 18 / 18 | 48 / 48 | 102 / 102 | 48 / 48 |
| `stress` | 209 / 209 | 160 / 160 | 448 / 448 | 960 / 960 | 448 / 448 |

(baseline / E-HVGP)

---

## 3. Table 2 — performance

| Test | cycles B | cycles E | Δ | conflicts B | conflicts E | Δ | stall cyc B | stall cyc E | Δ |
|---|---|---|---|---|---|---|---|---|---|
| `same` | 33 | 33 | 0.0% | 0 | 0 | — | 0 | 0 | — |
| `widening` | 43 | 43 | 0.0% | 26 | 27 | +3.8% | 17 | 18 | +5.9% |
| `narrowing` | 30 | 33 | **+10.0%** | 16 | 22 | +37.5% | 11 | 14 | +27.3% |
| `mixed` | 45 | 47 | **+4.4%** | 17 | 26 | +52.9% | 11 | 18 | +63.6% |
| `stress` | 465 | 475 | **+2.2%** | 368 | 321 | **−12.8%** | 230 | 262 | +13.9% |

Positive Δ = E-HVGP worse.

Read/write conflict split:

| Test | read conf B/E | write conf B/E | rename stall B/E |
|---|---|---|---|
| `same` | 0 / 0 | 0 / 0 | 0 / 0 |
| `widening` | 26 / 26 | 0 / 1 | 6 / 6 |
| `narrowing` | 16 / 20 | 0 / 2 | 4 / 4 |
| `mixed` | 17 / 24 | 0 / 2 | 7 / 10 |
| `stress` | 368 / 313 | 0 / 8 | 231 / 250 |

---

## 4. Table 3 — topology usage

Allocations per topology id `[t0 … t7]`, where `t0..t3` are stride 1 with
start bank 0..3 and `t4..t7` are stride 3 with start bank 0..3.

| Test | baseline | E-HVGP |
|---|---|---|
| `same` | `[6,0,6,0, 0,0,0,0]` | `[6,0,6,0, 0,0,0,0]` |
| `widening` | `[12,0,0,0, 0,0,0,0]` | `[0,0,0,0, 2,10,0,0]` |
| `narrowing` | `[8,0,4,0, 0,0,0,0]` | `[0,0,8,0, 0,4,0,0]` |
| `mixed` | `[6,0,12,0, 0,0,0,0]` | `[5,0,7,0, 0,6,0,0]` |
| `stress` | `[88,8,56,8, 0,0,0,0]` | `[25,28,19,40, 14,9,20,5]` |

---

## 5. Honest verdict on the v1 hypothesis

**E-HVGP v1 as specified does not improve on the baseline. On four of five
tests it is neutral or worse. This is a negative result and it is reported
as such.**

The measurements do, however, isolate *why*, and the reason is architectural
rather than a coding defect.

### 5.1 The predicted baseline degeneracy is real

`tests/widening` (Table 3): the baseline issues topology 0 for **12 of 12**
allocations. This is exactly the failure the architecture notes predict —
`rr_base += EMUL_dst` with `EMUL_dst = 4` and `B = 4` is a no-op modulo `B`,
so every widening result lands on the identical bank sequence. The problem
E-HVGP set out to solve exists and is measurable.

### 5.2 E-HVGP v1 replaces one constant with a different constant

Same test, E-HVGP: **10 of 12** allocations get topology 5. Instead of
"always `(0, stride 1)`" the machine now does "always `(1, stride 3)`".
Successive widening results still receive identical bank sequences, so they
still collide with each other on every co-read. Cycles: 43 vs 43.

Trace evidence (`vvp sim/out/ehvgp.vvp +HEX=tests/widening/prog.hex +TRACE`)
shows `cost=8` for the winning candidate on every single allocation — and
hand-evaluation confirms **all eight candidates tie at 8**. The predictive
term carries no information for this shape, because a destination group of
4 registers has period 4 while the reference source group of 2 registers has
period 2; every relative alignment yields the same total. The winner is
therefore decided entirely by the tie-breakers (stride class + start
penalty), which are constant for a homogeneous instruction stream.

### 5.3 Root cause — the constraint, not the code

A function of the form

```
topology = f(EMUL_dst, EMUL_s1, EMUL_s2, SEW, topo(vs1), topo(vs2))
```

is **constant across instructions that have the same shape and the same
source topologies**. In any homogeneous kernel or loop body — precisely the
workloads that matter — successive destination groups therefore receive
*identical* placements, and two such groups read together self-conflict on
every micro-op.

The baseline avoids this only because its rotation counter is *stateful*
(allocation-order dependent). Its weakness is not statelessness but that its
rotation increment (`EMUL_dst`) degenerates whenever `EMUL_dst ≡ 0 (mod B)`.

So the two designs fail in complementary ways:

| | distinguishes successive same-shape groups? | handles `EMUL_dst ≡ 0 mod B`? |
|---|---|---|
| Baseline (stateful rotation by `EMUL_dst`) | yes, except when the increment ≡ 0 | **no** |
| E-HVGP v1 (pure structural function) | **no, never** | n/a — it never rotates |

Architecture notes Section 11.4 explicitly recommends the pure-function form
for v1, so this constraint was a deliberate research-design choice. The
measurement shows that choice makes the mechanism unable to address its own
target case. **This is flagged as an open architectural issue; no silent
change to the mechanism has been made.** See Section 6.

### 5.4 `stress` — fewer conflicts but more cycles

`stress` is the one workload where shapes vary enough for the structural
function to discriminate (E-HVGP uses all 8 topologies, baseline only 4).
It reduces total conflicts by 12.8% (368 → 321) yet *increases* cycles by
2.2% and stall cycles by 13.9%.

The explanation is a metric mismatch. `bank_conflict_count` counts denied
*requests*; `bank_stall_cycles` counts *cycles containing at least one
denial*, and it is the latter that maps onto lost time. E-HVGP spread the
same contention over more cycles — fewer denials per cycle, but more cycles
with a denial. **The v1 cost function optimises the wrong objective.**

The mismatch is not an accident of this workload; it is algebraic.
`coread_cost` is defined as `n_requests - n_distinct_banks` per window, which
*is* a denial count for the window — the same reduction `bank_conflict_count`
applies. The selector therefore minimises Σ denials while the machine pays
Σ windows-containing-a-denial. See `docs/ehvgp.md` Section 5, "Known defect in
v1", for the derivation. `stress` is where the function has enough shape
variety to discriminate, so it is where the wrong target shows up as time.

A second observation on `stress`: 231 of 465 baseline cycles (~50%) are
`rename_stall_cycles`. These are **not** an independent population insensitive
to bank behaviour. Two of the three stall sources in
`v_can_go = alloc_ok & desc_ready & ~cq_full` are downstream backpressure
(`desc_ready`, `cq_full`), and that queue chain drains through operand
collect — exactly where the arbiter denies reads. Bank conflicts stall operand
collection, the queues fill, and the backpressure surfaces upstream as rename
stall. The published deltas are consistent with the coupling: rename stall
only moves where bank stall moves substantially.

| Test | Δ bank stall | Δ rename stall |
|---|---|---|
| `same` | 0 | 0 |
| `widening` | +1 | 0 |
| `narrowing` | +3 | 0 |
| `mixed` | +7 | +3 |
| `stress` | +32 | +19 |

Coupling of that kind makes `stress` **understate** the mechanism's effect on
time rather than manufacture one, so the `+2.2%` cycle figure should be read as
directional, not as a calibrated cost. (An earlier revision of this section
argued the opposite — that the rename-stall population dilutes sensitivity and
makes `stress` the least discriminating benchmark. That was backwards.)

The sign disagreement itself is unaffected either way: conflicts down 12.8%
while stall cycles rise 13.9% on the same run. A dilution or coupling argument
is about magnitude; it cannot flip the relative direction of two counters
measured simultaneously.

**Caveat on the attribution.** Rename stall has a second channel into
`EHVGP_ENABLE` that has nothing to do with bank backpressure: `alloc_ok` is
evaluated at the *selected* topology, so a different `sel_topo` can fail the
free-list fit where the baseline's choice would have succeeded
(`docs/architecture.md` Section 6). The correlation table above favours the
backpressure channel — a free-list-fit channel has no obvious reason to track
bank-stall magnitude — but that is inference, not measurement. The
`stall_alloc_cycles` / `stall_desc_cycles` / `stall_cmtq_cycles` counters
(`docs/architecture.md` Section 9) were added to settle it; **they are not yet
populated in the numbers above**, which predate the split.

### 5.5 `same` — the control behaves as expected

Zero bank conflicts in both configurations, identical topology histograms,
identical cycles. When there is no EMUL mismatch, the structural function
has no information to act on and reproduces the baseline exactly. This is
the correct behaviour for a control and is evidence that the difference seen
elsewhere is attributable to the EMUL relationship.

---

## 6. Open architectural issue

See the `[ARCHITECTURAL ISSUE]` section returned with this checkpoint. In
short: **v1's "no state, pure structural function" constraint (architecture
notes Section 11.4) is incompatible with v1's own goal.** The proposed
smallest correction is to give the selector one piece of *allocation-order*
state — an EMUL-indexed rotation whose increment is chosen structurally so
it is never `≡ 0 (mod NUM_BANKS)` — while still never reading runtime bank
occupancy. That keeps the mechanism structurally EMUL-driven and separable
from prior-art dynamic conflict-aware allocation, and it is the smallest
change that lets successive same-shape groups differ.

**This change has not been implemented.** It modifies the research mechanism
and requires explicit sign-off first.

### Two failure modes, one remedy

The measurements show two distinct failures, and the correction above addresses
only the first:

* **Failure A — no information.** On homogeneous streams all 8 candidates tie
  (`cost=8` on every `widening` allocation), tie-breakers decide, and placement
  is constant. Root-caused in Section 5.3 to the pure-structural-function
  constraint. This is what the EMUL-indexed rotation fixes.
* **Failure B — wrong target.** Where the function *does* discriminate, it
  discriminates toward conflicts rather than stall cycles (Section 5.4,
  `docs/ehvgp.md` Section 5). The rotation does not change what the selector
  minimises.

A v2 that fixes A and keeps the current `coread_cost` would still optimise the
wrong objective, and `stress` is the existing evidence for that. The direct
test for B is a `coread_cost` variant counting *windows containing a denial*
rather than *denials*. **Also not implemented**, and requiring sign-off on the
same grounds.

---

## 7. Vivado synthesis

**Not yet run.** Vivado is not installed on this machine. The flow is in
`vivado/synth.tcl` (out-of-context, `-generic EHVGP_ENABLE=0|1`, same part
and same constraints for both configurations) and
`vivado/constraints.xdc` (100 MHz starting target).

LUT / FF / BRAM / DSP utilisation and Fmax will be recorded here once the
script has actually been executed. **No synthesis numbers are stated until
then.**

Expected critical path, for when it is run: `topology_selector.v` is a fully
combinational exhaustive search over 8 candidates × 8 group indices sitting
inside the rename stage.
