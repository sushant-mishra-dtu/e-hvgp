# E-HVGP — Mechanism Specification (v1, as implemented)

---

## 1. Problem

Mixed-width RVV operations produce register groups of *different effective
sizes* from the same instruction stream: a widening instruction at `LMUL=m`
writes a `2m`-register group while reading `m`-register groups; a narrowing
instruction reads a `2m`-register group while writing an `m`-register group.

Under a single fixed bank-interleave scheme, groups of different shapes tend
to land on the same banks at the same time, because the interleave was
chosen for one canonical group shape and every group is forced through it.
The resulting contention is **structural** — a property of the EMUL/LMUL
relationship — not statistical or history-driven.

The hypothesis (architecture notes Section 2): because `EMUL`, `LMUL` and
`SEW` are all known and computable **at rename time** from the encoding plus
the current `vtype`, the core can *deterministically* choose a bank
placement per group that avoids this structural collision, rather than
*predicting* conflicts from runtime history.

---

## 2. Baseline (`EHVGP_ENABLE = 0`)

Fixed round-robin placement with starting-bank rotation:

```
topology  = (rr_base, stride = 1)
after each allocation:  rr_base <- (rr_base + EMUL_dst) mod NUM_BANKS
```

This is the non-strawman baseline the architecture notes specify
(Section 5: "base rotates per allocation"). It is a real, reasonable
allocator: for group sizes coprime with `NUM_BANKS` it spreads successive
groups evenly over the bank space.

**Its known degeneracy** — and the specific thing E-HVGP was expected to fix:
when `EMUL_dst ≡ 0 (mod NUM_BANKS)` the rotation is a *no-op*. With `B = 4`,
every widening result at `LMUL = 2` (`EMUL_dst = 4`) receives the **same**
bank sequence as the previous one. This is measured, not asserted: in
`tests/widening` the baseline issues topology 0 for **12 of 12** allocations
(`docs/results.md`).

---

## 3. E-HVGP (`EHVGP_ENABLE = 1`)

Decision point: **Rename/Allocate**, for the **destination group only**
(architecture notes Section 6). No new pipeline stage. Downstream stages
consume the resulting physical register numbers and are unaware of the
policy.

Why destination-only: a physical register's bank is fixed when it is
allocated as a destination; source groups were already placed when *they*
were destinations, and E-HVGP cannot retroactively move them.

### Inputs (v1)

Per architecture notes Section 11.4, v1 selection is a **pure function of
structural rename-time state**, with **no runtime bank-occupancy input**,
no bank-busy counters and no allocation history:

```
f( EMUL_dst, EMUL_s1, EMUL_s2, SEW, topo(vs1), topo(vs2) )
```

`topo(vs1)` / `topo(vs2)` are rename-map contents, not runtime occupancy.
They are included because of the producer-awareness reframing in
architecture notes Section 4: since the destination topology cannot affect
the *current* instruction's reads, its only leverage is on the *future*
reads of this group, and the only zero-extra-state structural predictor of
"what will this group be read alongside" is the current instruction's own
source groups.

> **Note on SEW.** Under register-granularity banking, the number of
> physical registers in a group is `EMUL`, independent of `SEW`. `SEW`
> therefore influences placement **only through EMUL**. `sew_log2` is wired
> into the selector for completeness and waveform visibility, but it is
> structurally subsumed. This is a finding, not an omission.

---

## 4. Topology representation

`(start_bank, stride)` pair, as recommended in architecture notes
Section 6.1 (hybrid of options A and B).

```
bank(i) = (start_bank + i · stride) mod NUM_BANKS
```

Encoding (`rtl/e_hvgp/topology_table.v`), `NUM_TOPO = 2·NUM_BANKS`:

```
topo_id[BID_W-1:0] = start_bank
topo_id[TID_W-1]   = 0 -> stride 1
                     1 -> stride NUM_BANKS-1
```

For `NUM_BANKS = 4` (`TID_W = 3`):

| id | start | stride | bank sequence (i = 0..3) |
|---|---|---|---|
| 0 | 0 | 1 | 0 1 2 3 |
| 1 | 1 | 1 | 1 2 3 0 |
| 2 | 2 | 1 | 2 3 0 1 |
| 3 | 3 | 1 | 3 0 1 2 |
| 4 | 0 | 3 | 0 3 2 1 |
| 5 | 1 | 3 | 1 0 3 2 |
| 6 | 2 | 3 | 2 1 0 3 |
| 7 | 3 | 3 | 3 2 1 0 |

Only strides coprime with `NUM_BANKS` are representable. For a power-of-two
`NUM_BANKS`, both `1` and `NUM_BANKS-1` are coprime with it, so the whole
encoded space is legal for `G <= NUM_BANKS`.

Stride is a genuine second degree of freedom: for `G < NUM_BANKS` the two
strides give different bank **sets** (`G=2, start=0`: `{0,1}` vs `{0,3}`);
for `G = NUM_BANKS` they give the same set in a different **order**, which
still matters because accesses are issued in index order in windows of
`ISSUE_W`.

### Legality — never assumed

`f_topo_legal(t, G)` in `rtl/common/ehvgp_funcs.vh` checks **structurally**
that the first `min(G, NUM_BANKS)` registers land in distinct banks, by
pairwise bank comparison. It does not merely trust the `gcd(stride,B) = 1`
rule, so it stays correct for any `NUM_BANKS`. Illegal candidates receive a
prohibitive cost (`ILLEGAL_COST = 1024`) and can never win. A simulation
assertion in `vector_rename.v` re-checks legality, freeness and pairwise
distinctness on **every** allocation and `$fatal`s on violation.

---

## 5. Allocation policy (v1 cost function)

`rtl/e_hvgp/topology_selector.v`, exhaustive combinational search over all
`NUM_TOPO` candidates. For candidate `t`:

1. `D[i] = bank(t, i)` for `i = 0..EMUL_dst-1`.
2. Reference source group `S` = the source with the larger EMUL (`vs1` on a
   tie); `S[j] = bank(topo(S), j)`.
3. **Projected consumer**: a later same-width instruction reading this group
   together with `S`, issuing `ISSUE_W` micro-ops per cycle (the machine's
   real operand-collect width). For each window of `ISSUE_W` consecutive
   micro-ops, gather the read requests `{D[i], S[i mod |S|]}` and add
   `n_requests - n_distinct_banks`.
   This sum is `coread_cost(t)`.
4. `stride_class`: a group whose `EMUL_dst` exceeds its sources' EMUL (a
   widening result) prefers stride `NUM_BANKS-1`; every other group prefers
   stride 1.
5. `start_penalty`: +1 per source group whose `start_bank` equals `t`'s.

```
total(t) = 4·coread_cost(t) + 2·stride_mismatch(t) + start_penalty(t)
         + 1024·(not legal)
```

Selection = `argmin total`, lowest topology id on a tie. Fully
deterministic: identical inputs always produce identical output.

### Known defect in v1: `coread_cost` models the wrong counter

`n_requests - n_distinct_banks` **is a denial count for the window**: a window
with 3 requests landing on 1 bank scores `3 - 1 = 2`, matching the two requests
the arbiter would deny. It is therefore structurally the same reduction as
`bank_conflict_count` (Section 6), not as `bank_stall_cycles`.

Only `bank_stall_cycles` maps onto lost time — the core loses one cycle whether
one request or three were denied in it. A stall-cycle-faithful objective would
score the window above as `1`. Summed over windows, `coread_cost` minimises
Σ denials while the machine pays Σ windows-containing-a-denial, and those are
not monotonically related: spreading the same contention thinner across more
windows lowers the first and raises the second.

This is the algebraic form of the "wrong objective" verdict in
`docs/results.md` Section 5.4, and `stress` is its measured instance — E-HVGP
wins on conflicts (−12.8%) and loses on stall cycles (+13.9%) in the same run.

**Not fixed in v1.** A `coread_cost` variant counting *windows containing a
denial* rather than *denials* is the direct test, but it changes the research
mechanism and requires sign-off on the same grounds as `docs/results.md`
Section 6.

### Recovery

`topology_id` lives in the same rename-map structure as the physical base
pointer, so any future branch-misprediction/exception checkpoint restores it
identically to every other rename field — no new recovery mechanism, only a
wider checkpoint entry (architecture notes Section 6).

---

## 6. Bank model

See `docs/architecture.md` Section 8. Restated here because it is the
measurement instrument: one read and one write per bank per cycle, fixed
priority, denied requests re-present next cycle, **identical in both
configurations**.

---

## 7. Fairness — what is and is not allowed to differ

`EHVGP_ENABLE` is threaded from `rv_core` to exactly one module,
`ehvgp_allocator`, and nowhere else. Verified by inspection and by the
measured counters.

Identical in both configurations:

| | evidence |
|---|---|
| instruction stream | same `prog.hex` |
| initial architectural state | same reset values, same VRF init |
| VRF banks | 4 |
| physical register capacity | 64 |
| VRF read/write bandwidth | 4 reads + 4 writes per cycle, 1 per bank |
| execution units | 2 ALUs |
| micro-op decomposition | same `vector_uop.v` |
| conflict penalty | same `vrf_arbiter.v` |
| free-list search | same lowest-slot-first scan |
| supported ISA | same decoders |

Measured confirmation (all five tests): `instructions`,
`vector_instructions`, `vector_uops`, `vrf_read_requests` and
`vrf_write_requests` are **bit-identical** between configurations. Only
`bank_conflicts`, `bank_stall_cycles` and `cycles` differ. E-HVGP receives
no extra registers, ports, units, bandwidth or reduced penalties.

**Architectural invariant:** the final architectural state dump
(`*.arch`: all 32 vector registers, all 32 scalar registers, `vtype`, `vl`,
`vill`) must be byte-identical between configurations. This is checked
automatically on every run and currently holds on all five tests.

---

## 8. Supported RVV subset

See `docs/architecture.md` Section 3.

---

## 9. Limitations

1. **Selection is combinational and exhaustive** over 8 candidates × 8
   indices. Fine for a prototype; in real silicon it would need pipelining
   or a much smaller candidate set. Expected critical path in synthesis.
2. **`ISSUE_W = 2` is hard-coded** in `vector_unit.v` slot logic even though
   it is a parameter elsewhere.
3. **No vector memory operations.** Loads/stores are the next natural
   extension and would add address-generation interaction with placement.
4. **No masking, no fractional LMUL, no `SEW=64` sources, no floating
   point, no reductions, no gather/scatter.**
5. **Partially-active destination registers are written in full**
   (tail-agnostic with computed values). Never exercised: all shipped tests
   run at `VL = VLMAX`.
6. **In-order issue.** A real OoO scheduler would change the *dynamic*
   co-residency of micro-ops and therefore the absolute conflict counts,
   though not the point at which topology is chosen.
7. **v1 selection cannot distinguish successive same-shape groups.** This is
   a fundamental consequence of the "pure structural function" constraint
   and is the subject of the open architectural issue in
   `docs/results.md` Section 5. **Read that before drawing conclusions from
   the numbers.**
