# Verification

Verilog-2001 only — `initial`, `always`, tasks, functions, `$display`,
`$fdisplay`, `$finish`, `$fatal`. No SystemVerilog assertions.

---

## 1. Tests

| Test | vtype | Shapes exercised | Purpose |
|---|---|---|---|
| `tests/same` | SEW 32, LMUL 2 | `EMUL_d = EMUL_s = 2` | Correctness control. No EMUL mismatch, so the placement problem is absent by construction. |
| `tests/widening` | SEW 16, LMUL 2 | `EMUL_d = 4`, `EMUL_s = 2` | The mechanism-triggering case. 12 back-to-back widening ops. |
| `tests/narrowing` | SEW 16, LMUL 2 | `EMUL_s2 = 4`, `EMUL_d = 2` | Mirror case; 3 reads per micro-op — highest read pressure in the subset. |
| `tests/mixed` | SEW 16, LMUL 2 | same / widen / same / narrow / widen / same × 3 | Groups of EMUL 2 and 4 alive simultaneously and read against each other. |
| `tests/stress` | 4 phases | LMUL 1/2/4, EMUL 1..8, widening and narrowing, × 8 loop iterations | Steady-state behaviour across many group shapes. |

Programs are RVV-1.0-encoded and assembled by `tests/asm.py`.

---

## 2. Checks performed

### 2.1 Differential A/B (the hard invariant)

Both configurations execute the *same* `prog.hex` from the *same* reset
state. After halt, the testbench dumps **architectural state only** —
all 32 architectural vector registers (resolved through the RAT to their
physical location and read back), all 32 scalar registers, `vtype`, `vl`,
`vill` — to `<test>_<mode>.arch`.

`sim/compare.py` (and the equivalent check inside `run_xcelium.sh` /
`run_iverilog.ps1`) requires these files to be **byte-identical**.
E-HVGP must never change correctness, only placement and timing.

### 2.2 Placement difference (must be non-zero to prove the mechanism ran)

`<test>_<mode>.place` records, per architectural register, the resolved
`preg`, `bank`, `slot`, `topology_id` and `index`. A *non-zero* difference
between configurations is what proves the mechanism actually changed
something.

### 2.3 In-RTL simulation assertions (`rtl/rename/vector_rename.v`)

Run on **every** allocation, `$fatal` on violation:

1. The selected topology is legal for the destination group size
   (structural pairwise-distinct-bank check, not a trusted gcd rule).
2. Every physical register being allocated was actually free.
3. The group's physical registers are pairwise distinct.

### 2.4 Structural fairness counters

`instructions`, `vector_instructions`, `vector_uops`,
`vrf_read_requests`, `vrf_write_requests` must match between
configurations. If they diverge, the two builds are not running the same
experiment. Currently identical on all five tests.

### 2.5 Liveness

The testbench times out (`+MAXCYC`, default 200000) and reports `FAIL` if
the core never halts — this catches free-list deadlock and scoreboard
deadlock.

---

## 3. Expected results

| Check | Expectation |
|---|---|
| Architectural dumps identical | **must hold** |
| Fairness counters identical | **must hold** |
| Legality/free/distinct assertions | **must never fire** |
| Placement dumps differ | should differ on every test with EMUL mismatch |
| `tests/same` placement | may be identical (shape carries no information) |
| Cycles / conflicts | free to differ in either direction — this is the measurement |

---

## 4. Actual results (2026-08-14, Icarus Verilog 12.0)

| Test | arch identical | placement lines differing (of 32) | legality assertions |
|---|---|---|---|
| `same` | YES | 14 | pass |
| `widening` | YES | 24 | pass |
| `narrowing` | YES | 28 | pass |
| `mixed` | YES | 26 | pass |
| `stress` | YES | 32 | pass |

Fairness counters identical on all five tests (see `docs/results.md`
Table 1).

Performance numbers: `docs/results.md`.

---

## 5. Known failures and limitations

**No test currently fails.** The following are *untested*, not failing:

1. **`VL < VLMAX`** — no test sets a partial VL, so the documented
   tail-agnostic-with-computed-values deviation is never exercised.
2. **Physical register exhaustion** — no test drives the free list to
   failure. The rename stall path exists (`alloc_ok = 0`) and is taken
   under queue backpressure, but exhaustion-specific behaviour is unproven.
3. **`vsetvl` (register form)** — decoded and implemented but no test uses
   it; all tests use `vsetvli`.
4. **`LMUL=8`** — decoded, and `EMUL=8` groups are exercised (via widening
   at `LMUL=4` in `tests/stress` phase C), but no test uses `LMUL=8`
   directly.
5. **Branch misprediction / exception recovery** — the machine is in-order
   and non-speculative, so no recovery path exists to test. The claim that
   `topology_id` recovers like any other rename field is *by construction*,
   not verified.
6. **No random / constrained-random testing.** The architecture notes
   (Section 9) call for a functional reference model and random
   `vtype`/instruction sequences checked against it. Not built. The current
   correctness argument rests on differential A/B equality plus the
   determinism of the ALU, which proves the two configurations agree but
   does **not** prove either one implements RVV correctly.
7. **No RVV compliance suite** has been run.

Items 6 and 7 are the most significant gaps: differential testing proves
*self-consistency*, not *RVV correctness*.
