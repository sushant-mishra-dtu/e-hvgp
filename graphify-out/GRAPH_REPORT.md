# Graph Report - e-hvgp  (2026-08-19)

## Corpus Check
- Corpus is ~21,630 words - fits in a single context window. You may not need a graph.

## Summary
- 134 nodes · 173 edges · 15 communities (10 shown, 5 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 1% AMBIGUOUS · INFERRED: 1 edges (avg confidence: 0.7)
- Token cost: 16,400 input · 7,100 output

## Community Hubs (Navigation)
- A/B Harness and Counters
- Topology Selector and Negative Result
- Micro-op Model and Vector Config
- RVV Assembler and Test Build
- Project Docs and Baseline Policy
- Topology Encoding and Legality
- RVV Decode and Allocator Policy
- VRF Banking and Conflict Metrics
- RAT, Placement Math and Correctness Gate
- Rename, Free List and Commit
- Xcelium Build Flow
- Scalar Decode Shim
- VRF Top and Arbitration Wiring
- Instruction Memory
- Vector ALU

## God Nodes (most connected - your core abstractions)
1. `A/B experiment: same prog.hex, two builds, four independent checks` - 14 edges
2. `assemble()` - 10 edges
3. `v1 cost: total = 4*coread_cost + 2*stride_mismatch + start_penalty` - 8 edges
4. `topology_selector` - 6 edges
5. `vector_rename` - 6 edges
6. `Topology = (start_bank, stride), bank(i) = (start + i*stride) mod NUM_BANKS` - 6 edges
7. `ehvgp_allocator` - 5 edges
8. `README - E-HVGP project overview` - 5 edges
9. `E-HVGP - EMUL-driven heterogeneous vector-group placement` - 5 edges
10. `tests/widening - the mechanism-triggering case` - 5 edges

## Surprising Connections (you probably didn't know these)
- `EHVGP_ENABLE - the single A/B switch` --threaded_only_to--> `ehvgp_allocator`  [EXTRACTED]
  README.md → rtl/e_hvgp/ehvgp_allocator.v
- `topology_selector is instantiated unconditionally; a generate picks its output` --instantiates--> `topology_selector`  [EXTRACTED]
  README.md → rtl/e_hvgp/topology_selector.v
- `Architectural grouping vs physical placement kept strictly separate` --physical_side--> `ehvgp_allocator`  [EXTRACTED]
  docs/architecture.md → rtl/e_hvgp/ehvgp_allocator.v
- `topology_selector is instantiated unconditionally; a generate picks its output` --describes--> `ehvgp_allocator`  [EXTRACTED]
  README.md → rtl/e_hvgp/ehvgp_allocator.v
- `Expected critical path: combinational exhaustive search in topology_selector` --attributed_to--> `topology_selector`  [EXTRACTED]
  docs/results.md → rtl/e_hvgp/topology_selector.v

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **A/B correctness gate binds both builds, both dump kinds and the comparator** — ab_experiment, correctness_gate, dump_arch_txt, dump_place_txt, sim_compare, tb_tb_top [EXTRACTED 0.95]
- **v1 cost function is the weighted sum of its three structural terms plus legality** — cost_function_v1, coread_cost, stride_class, start_penalty, illegal_cost [EXTRACTED 1.00]
- **The negative result rests jointly on degeneracy, constant replacement, the cost tie and the metric mismatch** — negative_result, degeneracy_measured, constant_replacement, all_candidates_tie, metric_mismatch, pure_function_constraint [EXTRACTED 0.95]

## Communities (15 total, 5 thin omitted)

### Community 0 - "A/B Harness and Counters"
Cohesion: 0.13
Nodes (16): A/B experiment: same prog.hex, two builds, four independent checks, Control test reproduces the baseline exactly - zero conflicts in both, place.txt - physical placement dump sample, EHVGP_ENABLE - the single A/B switch, Liveness: +MAXCYC timeout catches free-list and scoreboard deadlock, Performance counters exported from rv_core, Placement difference check: .place dumps must differ, main() (+8 more)

### Community 1 - "Topology Selector and Negative Result"
Cohesion: 0.15
Nodes (17): All eight candidates tie at cost=8 - the predictive term carries no information, argmin selection, lowest topology id wins ties; fully deterministic, E-HVGP v1 replaces one constant with another (topo 5, 10 of 12), v1 cost: total = 4*coread_cost + 2*stride_mismatch + start_penalty, Measured: baseline issues topology 0 for 12 of 12 widening allocations, Expected critical path: combinational exhaustive search in topology_selector, Negative result: E-HVGP v1 does not beat the baseline, Proposed correction: EMUL-indexed allocation-order state - NOT implemented (+9 more)

### Community 2 - "Micro-op Model and Vector Config"
Cohesion: 0.15
Nodes (10): Asymmetric read counts per shape are the consequence of EMUL != LMUL, coread_cost - per ISSUE_W window, requests minus distinct banks, Micro-op model: one uop per destination physical register, Parameters as built: VLEN=128, 4 banks, 16 regs/bank, 64 pregs, ISSUE_W=2, Reference source group S = source with larger EMUL, vs1 on a tie, Hypothesis: EMUL/LMUL/SEW known at rename allow deterministic placement, vector_config, vector_uop (+2 more)

### Community 3 - "RVV Assembler and Test Build"
Cohesion: 0.27
Nodes (11): assemble(), enc_b(), enc_i(), enc_r(), enc_u(), enc_vop(), main(), parse_vtype() (+3 more)

### Community 4 - "Project Docs and Baseline Policy"
Cohesion: 0.25
Nodes (9): Baseline degeneracy: rotation is a no-op when EMUL_dst = 0 mod NUM_BANKS, Baseline policy: (rr_base, stride 1) with rr_base += EMUL_dst, docs/architecture.md - implemented architecture, docs/ehvgp.md - mechanism specification v1, README - E-HVGP project overview, docs/results.md - measured results, docs/verification.md - verification plan, E-HVGP - EMUL-driven heterogeneous vector-group placement (+1 more)

### Community 5 - "Topology Encoding and Legality"
Cohesion: 0.20
Nodes (9): f_topo_legal() - structural pairwise-distinct-bank legality check, ILLEGAL_COST = 1024 prohibitive penalty, NUM_TOPO = 2 * NUM_BANKS = 8 candidate topologies, In-RTL assertions per allocation: legal topology, free registers, distinct, bank_mapper, topology_table, Stride is a genuine second degree of freedom, Topology = (start_bank, stride), bank(i) = (start + i*stride) mod NUM_BANKS (+1 more)

### Community 6 - "RVV Decode and Allocator Policy"
Cohesion: 0.22
Nodes (7): Architectural grouping vs physical placement kept strictly separate, Not implemented: SEW=64, fractional LMUL, masking, FP, reductions, memory ops, rvv_decode, ehvgp_allocator, RVV subset: vsetvli/vsetvl, vadd/vsub, vmv.v.v, vwadd/vwmul, vnsrl/vnsra, topology_selector is instantiated unconditionally; a generate picks its output, topology_selector

### Community 7 - "VRF Banking and Conflict Metrics"
Cohesion: 0.22
Nodes (7): Bank conflict model: 1 read + 1 write per bank per cycle, fixed priority, Definitions: denied request = 1 conflict; cycle with a denial = 1 stall cycle, Metric mismatch: conflicts count denied requests, stall cycles count lost time, vrf_arbiter, vrf_bank, stress is the least discriminating benchmark - ~50% rename stall cycles, tests/stress - 4 phases, many shapes, 8 loop iterations

### Community 8 - "RAT, Placement Math and Correctness Gate"
Cohesion: 0.22
Nodes (9): Correctness gate: .arch dumps must be byte-identical, Decision D-RAT - rat_idx added to survive group re-aliasing, arch.txt - architectural state dump sample, Correctness gate passed on all five tests, Most significant gap: no random testing and no RVV compliance suite, preg = bank*REGS_PER_BANK + slot; slot_i = s + (i div NUM_BANKS), RAT stores rat_slot, rat_topo, rat_idx per architectural vreg (10 bits), topology_id recovers like any other rename field (by construction) (+1 more)

### Community 9 - "Rename, Free List and Commit"
Cohesion: 0.25
Nodes (7): Physical registers released at commit via old_free_mask in the mini-ROB, ehvgp_allocator, Structural fairness counters must match across configurations, Free list: lowest-slot-first scan, byte-identical in both configurations, Pipeline: in-order issue, in-order commit, OoO completion between 2 slots, Placement decided at Rename/Allocate, destination group only, vector_rename

## Ambiguous Edges - Review These
- `Finding: SEW influences placement only through EMUL` → `v1 cost: total = 4*coread_cost + 2*stride_mismatch + start_penalty`  [AMBIGUOUS]
  docs/ehvgp.md · relation: noted_in

## Knowledge Gaps
- **20 isolated node(s):** `imem`, `topology_selector`, `ehvgp_allocator`, `vector_alu`, `vrf_arbiter` (+15 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **5 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `Finding: SEW influences placement only through EMUL` and `v1 cost: total = 4*coread_cost + 2*stride_mismatch + start_penalty`?**
  _Edge tagged AMBIGUOUS (relation: noted_in) - confidence is low._
- **Why does `A/B experiment: same prog.hex, two builds, four independent checks` connect `A/B Harness and Counters` to `Topology Selector and Negative Result`, `Project Docs and Baseline Policy`, `Topology Encoding and Legality`, `VRF Banking and Conflict Metrics`, `RAT, Placement Math and Correctness Gate`, `Rename, Free List and Commit`?**
  _High betweenness centrality (0.322) - this node is a cross-community bridge._
- **Why does `v1 cost: total = 4*coread_cost + 2*stride_mismatch + start_penalty` connect `Topology Selector and Negative Result` to `Micro-op Model and Vector Config`, `Topology Encoding and Legality`, `VRF Banking and Conflict Metrics`?**
  _High betweenness centrality (0.163) - this node is a cross-community bridge._
- **Why does `Metric mismatch: conflicts count denied requests, stall cycles count lost time` connect `VRF Banking and Conflict Metrics` to `Topology Selector and Negative Result`?**
  _High betweenness centrality (0.131) - this node is a cross-community bridge._
- **What connects `imem`, `topology_selector`, `ehvgp_allocator` to the rest of the system?**
  _20 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `A/B Harness and Counters` be split into smaller, more focused modules?**
  _Cohesion score 0.1286549707602339 - nodes in this community are weakly interconnected._