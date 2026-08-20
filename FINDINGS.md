# Findings — Graph-Traced Review of the v1 Negative Result

An independent review of the published E-HVGP v1 results, produced by building a
knowledge graph over the repository (code + docs) and tracing the two paths that
connect the VRF banking model to the negative-result conclusion.

Reviewed: 2026-08-19, against the measurements dated 2026-08-14
([`docs/results.md`](docs/results.md)). No RTL was modified. Every claim below is
either quoted from a repository document or derived from the RTL, and the two are
labelled separately throughout.

**Bottom line:** the headline conclusion holds. The claim that "the v1 cost
function optimises the wrong objective" survives review, and this document adds a
structural explanation of *why* that the docs do not state. Two secondary claims
do not survive intact: the `stress` dilution caveat is argued backwards, and the
`+2.2%` cycle figure carries an unnamed confound.

---

## Table of contents

- [What was reviewed](#what-was-reviewed)
- [Finding 1 — the metric mismatch is structural, and visible in the formula](#finding-1--the-metric-mismatch-is-structural-and-visible-in-the-formula)
- [Finding 2 — the `stress` dilution caveat is argued backwards](#finding-2--the-stress-dilution-caveat-is-argued-backwards)
- [Finding 3 — `alloc_ok` is topology-dependent (unnamed confound)](#finding-3--alloc_ok-is-topology-dependent-unnamed-confound)
- [Impact on the published conclusions](#impact-on-the-published-conclusions)
- [Recommended next step](#recommended-next-step)
- [Provenance and limits](#provenance-and-limits)

---

## What was reviewed

A graph was built over all 30 corpus files (23 code, 7 docs) — 134 nodes, 173
edges, 15 communities, in `graphify-out/`. Two nodes turned out to be
cross-community bridges with high betweenness, and both sit on the reasoning path
from the measurement instrument to the conclusion:

| Bridge node | Betweenness | Connects |
|---|---|---|
| `A/B experiment` | 0.322 | six communities |
| `v1 cost function` | 0.163 | selector ↔ micro-op model, topology encoding, VRF banking |
| `Metric mismatch` | 0.131 | VRF banking ↔ negative result |

`Metric mismatch` is the *only* node on the boundary between the VRF-banking
community and the negative-result community. Everything the results chapter
concludes about lost time reaches the mechanism through that one node, which is
what made it worth tracing.

The traced path, 6 hops:

```
Bank conflict model (1 rd + 1 wr per bank, fixed priority)
  --defines-->    denied request = 1 conflict; cycle with a denial = 1 stall cycle
  --exposes-->    Metric mismatch
  <--optimises_wrong_objective--  v1 cost function
  --resolved_by-->  argmin, lowest topo id on ties
  <--reduces_to_tiebreakers--     all eight candidates tie at cost=8
  <--evidenced_by-- Negative result
```

---

## Finding 1 — the metric mismatch is structural, and visible in the formula

[`docs/results.md`](docs/results.md) §5.4 states that the v1 cost function
optimises the wrong objective, and attributes this to a counter-definition
mismatch. That is correct. What the docs do not say is that the mismatch is
*algebraic* — the cost function and the conflict counter apply the same
reduction, and it is the wrong one.

**The two counters are two different reductions of one signal.**
[`rtl/core/rv_core.v:373`](rtl/core/rv_core.v#L373):

```verilog
bank_conflict_count <= bank_conflict_count + {24'd0, rd_denied} + {24'd0, wr_denied};
if ((rd_denied != 8'd0) || (wr_denied != 8'd0))
   bank_stall_cycles <= bank_stall_cycles + 32'd1;
```

`rd_denied` is not a flag. [`rtl/vrf/vrf_arbiter.v:56`](rtl/vrf/vrf_arbiter.v#L56)
increments it once per losing request within the cycle:

```verilog
end else begin
   n_denied = n_denied + 8'd1;
end
```

So a cycle with three denials adds **3** to `bank_conflict_count` and **1** to
`bank_stall_cycles`. Only the second maps onto lost time — the core loses one
cycle whether one request or three were denied. This matches the documented
definitions in [`docs/architecture.md`](docs/architecture.md) §8 exactly.

**The cost function uses the conflict-count reduction.** `coread_cost` is defined
in [`docs/ehvgp.md`](docs/ehvgp.md) §5 as, per window of `ISSUE_W` micro-ops:

```
n_requests - n_distinct_banks
```

That expression *is* a denial count for the window. A window with 3 requests
landing on 1 bank scores `3 - 1 = 2`. A stall-cycle-faithful objective would score
that window `1` — it contains a denial, and costs one cycle.

Summed over windows, `coread_cost` is therefore a model of
`bank_conflict_count`, not of `bank_stall_cycles`. The selector minimises
Σ denials while the machine pays Σ windows-containing-a-denial. These are not
monotonically related: spreading the same contention thinner across more windows
lowers the first and raises the second.

**This is exactly what `stress` shows** ([`docs/results.md`](docs/results.md)
Table 2): conflicts 368 → 321 (**−12.8%**), stall cycles 230 → 262 (**+13.9%**),
cycles 465 → 475 (**+2.2%**). E-HVGP won on the metric it optimises and lost on
the metric that costs time.

> The verdict in §5.4 is the repository's. The step identifying
> `n_requests - n_distinct_banks` as structurally the same reduction as
> `bank_conflict_count` is this review's reading of the formula against the
> arbiter, and is not stated in any project document.

### Why this matters for the proposed correction

The results chapter identifies two distinct failure modes but does not separate
their remedies:

- **Failure A** — *no information.* On homogeneous streams all 8 candidates tie
  (`cost=8` on every `widening` allocation), so tie-breakers decide and placement
  is constant. Root-caused in §5.3 to the pure-structural-function constraint.
- **Failure B** — *wrong target.* Where the function does discriminate, it
  discriminates toward conflicts rather than stall cycles. This is `stress`.

The proposed correction in §6 — one piece of EMUL-indexed allocation-order state —
addresses **A only**. It gives the selector the power to distinguish successive
same-shape groups; it does not change what the selector is minimising. A v2 that
fixes A and keeps the current `coread_cost` would still optimise the wrong
objective, and `stress` is the existing evidence for that.

---

## Finding 2 — the `stress` dilution caveat is argued backwards

[`docs/results.md`](docs/results.md) §5.4 closes with a caveat: 231 of 465
baseline cycles (~50%) are `rename_stall_cycles`, i.e. front-end backpressure,
"which dilutes the sensitivity of this workload to bank behaviour", concluding
that `stress` is the least discriminating benchmark.

The caveat treats rename-stall cycles as a population *insensitive* to bank
behaviour. The RTL shows they are substantially the propagated form of the same
bank contention. [`rtl/core/rv_core.v:307`](rtl/core/rv_core.v#L307):

```verilog
wire v_can_go = alloc_ok & desc_ready & ~cq_full;
assign stall  = v_active & ~v_can_go;
```

Two of the three stall sources are downstream backpressure: `desc_ready`
(descriptor queue full) and `cq_full` (mini-ROB full). That queue chain drains
through the micro-op queue into operand collect — which is precisely where the
arbiter denies reads. Bank conflicts stall operand collection, the queues fill,
and the backpressure surfaces upstream as `rename_stall_cycles`.

Dilution of that kind causes `stress` to **understate** the mechanism's effect on
time, not to manufacture one. The caveat, as written, points the wrong way.

The published numbers are consistent with the coupling — rename stall only moves
where bank stall moves substantially:

| Test | Δ bank stall | Δ rename stall |
|---|---|---|
| `same` | 0 | 0 |
| `widening` | +1 | 0 |
| `narrowing` | +3 | 0 |
| `mixed` | +7 | +3 |
| `stress` | +32 | +19 |

On `stress`, Δ bank stall (+32) alone exceeds Δ cycles (+10), so these cycle
classes overlap heavily rather than summing — consistent with a single cycle
being counted by both counters.

---

## Finding 3 — `alloc_ok` is topology-dependent (unnamed confound)

[`docs/architecture.md`](docs/architecture.md) §6 states the free-list search is
"byte-identical in both configurations, so any behavioural difference comes from
the topology and never from the search." The search **is** identical. Its
*outcome* is not, because the search is evaluated at the selected topology.

[`rtl/rename/vector_rename.v:179`](rtl/rename/vector_rename.v#L179):

```verilog
p = f_preg(sel_topo, s[SLOT_W-1:0], i[3:0]);
if (!free_vec[p]) ok = 1'b0;
...
assign alloc_ok = found;
```

A different `sel_topo` can fail to find a feasible base slot where the baseline's
choice would have succeeded. Since `alloc_ok` feeds `v_can_go` directly,
`EHVGP_ENABLE` has a **second path into `rename_stall_cycles`** that has nothing
to do with bank backpressure.

Consequence: the +19 rename-stall cycles on `stress` are not attributable to a
single channel. The correlation table in Finding 2 favours the backpressure
channel — a free-list-fit channel has no obvious reason to track bank-stall
magnitude — but that is suggestive, not decisive. Neither the documents nor the
counters separate the two.

This does not break the fairness argument in [`docs/ehvgp.md`](docs/ehvgp.md) §7:
E-HVGP still receives no extra registers, ports, bandwidth or reduced penalties,
and the fairness counters remain bit-identical. It does mean the identity of the
search is not sufficient to conclude identity of stall behaviour, which is how §6
currently reads.

---

## Impact on the published conclusions

| Claim | Status |
|---|---|
| Correctness gate passed on all five tests | **Unaffected.** Nothing here touches architectural equivalence. |
| E-HVGP v1 does not beat the baseline | **Holds.** |
| Baseline degeneracy is real (12/12 topology 0 on `widening`) | **Holds.** |
| v1 replaces one constant with another (10/12 topology 5) | **Holds.** |
| Root cause A — pure structural function cannot distinguish same-shape groups | **Holds.** |
| The v1 cost function optimises the wrong objective | **Holds, and strengthened** — Finding 1 supplies the structural reason. |
| `stress` dilution makes it the least discriminating benchmark | **Argued backwards** — see Finding 2. |
| `+2.2%` cycles on `stress` as a measure of the mechanism's cost | **Directional only** — see Finding 3. |

The B evidence is a **sign disagreement**: conflicts down 12.8% while stall
cycles rise 13.9%, on the same run. Dilution is a magnitude argument — it can
shrink an effect toward zero but cannot flip the relative direction of two
counters measured simultaneously. The conclusion survives; the calibration of its
size does not.

---

## Recommended next step

Split `rename_stall_cycles` by cause. This is instrumentation only — it does not
touch the research mechanism and needs no sign-off.

`v_can_go` already carries the three causes as separate signals
([`rtl/core/rv_core.v:307`](rtl/core/rv_core.v#L307)), and the counter is a single
increment at [`rtl/core/rv_core.v:378`](rtl/core/rv_core.v#L378). Three counters —
`stall_alloc` (free-list fit failed), `stall_desc` (descriptor queue full),
`stall_cmtq` (mini-ROB full) — would attribute the +19 directly and settle
Finding 3 with measurement rather than inference.

Separately, and this one *does* change the mechanism: a `coread_cost` variant that
counts *windows containing a denial* rather than *denials* would test Finding 1
directly. Stated here as the experiment Finding 1 implies; not proposed for
implementation without sign-off, on the same grounds as §6.

---

## Provenance and limits

- **Repository-stated**, quoted or cited above: the two counter definitions
  ([`docs/architecture.md`](docs/architecture.md) §8), the `coread_cost` formula
  and cost function ([`docs/ehvgp.md`](docs/ehvgp.md) §5), the "wrong objective"
  verdict and all measured numbers ([`docs/results.md`](docs/results.md) §3–§5).
- **Derived in this review** from the RTL: that `coread_cost` and
  `bank_conflict_count` share a reduction (Finding 1); that rename stall is
  downstream-coupled to bank stall (Finding 2); that `alloc_ok` is
  topology-dependent (Finding 3).
- **Not measured here.** No simulation was run for this review. Every number
  quoted is from the 2026-08-14 Icarus Verilog 12.0 run recorded in
  [`docs/results.md`](docs/results.md). The channel attribution in Finding 3 is
  inference from RTL structure plus the published correlation, not measurement —
  which is exactly what the recommended counter split would resolve.
- **Graph caveats.** The graph carries 7 dangling edges (AST import edges to
  stdlib modules `os`, `sys`, `re`, `subprocess`, which have no node in the
  corpus) and 1 collapsed edge (`vrf.v` instantiates `vrf_arbiter` at both L83 and
  L92, merging into one undirected edge). Neither affects any finding above; both
  are recorded in `graphify-out/GRAPH_REPORT.md`.
