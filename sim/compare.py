#!/usr/bin/env python3
"""
compare.py -- BASELINE vs E-HVGP result comparison.

Reads sim/out/res/<test>_{base,ehvgp}.{arch,place} and prints the A/B table.
Reports architectural equivalence (the hard invariant) separately from the
performance comparison.  It never invents numbers: everything printed comes
from a simulation output file.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "sim", "out", "res")

KEYS = ["cycles", "instructions", "vector_instructions", "vector_uops",
        "vrf_read_requests", "vrf_write_requests",
        "bank_conflicts", "bank_read_conflicts", "bank_write_conflict",
        "bank_stall_cycles", "rename_stall_cycles",
        "stall_alloc_cycles", "stall_desc_cycles", "stall_cmtq_cycles",
        "widening", "narrowing"]

# rename_stall_cycles split by cause.  Present only in results produced after
# the counter split; older result files legitimately lack them.
STALL_CAUSES = [("stall_alloc_cycles", "free-list fit"),
                ("stall_desc_cycles",  "descriptor queue full"),
                ("stall_cmtq_cycles",  "mini-ROB full")]


def read_counters(path):
    d = {}
    if not os.path.isfile(path):
        return d
    for line in open(path):
        p = line.split()
        if len(p) == 2 and p[1].lstrip("-").isdigit():
            d[p[0]] = int(p[1])
    return d


# physical placement lines only: "v<n> preg=... bank=... slot=... topo=... idx=..."
# (not the vector_*/vrf_* counter lines, which also start with "v")
PLACE_LINE = re.compile(r"^v[0-9]+ ")


def read_place(path):
    if not os.path.isfile(path):
        return []
    return [l.strip() for l in open(path) if PLACE_LINE.match(l)]


def pct(b, e):
    if b == 0:
        return "  n/a " if e == 0 else " +inf "
    return f"{100.0*(e-b)/b:+6.1f}%"


def main():
    tests = sorted({f.rsplit("_", 1)[0] for f in os.listdir(RES)
                    if f.endswith(".place")}) if os.path.isdir(RES) else []
    if not tests:
        print("no results in", RES)
        return 1

    bad = 0
    print("=" * 78)
    print(" ARCHITECTURAL EQUIVALENCE  (must be IDENTICAL -- correctness gate)")
    print("=" * 78)
    for t in tests:
        a = os.path.join(RES, f"{t}_base.arch")
        b = os.path.join(RES, f"{t}_ehvgp.arch")
        if not (os.path.isfile(a) and os.path.isfile(b)):
            print(f"  {t:<12} MISSING")
            bad += 1
            continue
        ok = open(a).read() == open(b).read()
        pa, pb = read_place(a.replace(".arch", ".place")), \
                 read_place(b.replace(".arch", ".place"))
        nplace = sum(1 for x, y in zip(pa, pb) if x != y)
        print(f"  {t:<12} {'IDENTICAL' if ok else '*** MISMATCH ***':<18}"
              f" physical placement lines differing: {nplace}")
        if not ok:
            bad += 1

    print()
    print("=" * 78)
    print(" PERFORMANCE  (negative % = E-HVGP better)")
    print("=" * 78)
    hdr = f"  {'test':<12}{'counter':<22}{'baseline':>10}{'e-hvgp':>10}{'delta':>10}"
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for t in tests:
        cb = read_counters(os.path.join(RES, f"{t}_base.place"))
        ce = read_counters(os.path.join(RES, f"{t}_ehvgp.place"))
        if not cb or not ce:
            continue
        for k in ["cycles", "bank_conflicts", "bank_stall_cycles",
                  "vector_uops", "vrf_read_requests"]:
            print(f"  {t:<12}{k:<22}{cb.get(k,0):>10}{ce.get(k,0):>10}"
                  f"{pct(cb.get(k,0), ce.get(k,0)):>10}")
        print()

    print("=" * 78)
    print(" RENAME-STALL ATTRIBUTION  (causes overlap; they do not sum to the total)")
    print("=" * 78)
    shown = False
    for t in tests:
        cb = read_counters(os.path.join(RES, f"{t}_base.place"))
        ce = read_counters(os.path.join(RES, f"{t}_ehvgp.place"))
        if not cb or not ce:
            continue
        if not any(k in cb or k in ce for k, _ in STALL_CAUSES):
            print(f"  {t:<12} not instrumented in this result set -- re-run the "
                  f"simulation to populate")
            continue
        shown = True
        print(f"  {t:<12}{'rename_stall_cycles':<22}"
              f"{cb.get('rename_stall_cycles',0):>10}"
              f"{ce.get('rename_stall_cycles',0):>10}"
              f"{pct(cb.get('rename_stall_cycles',0), ce.get('rename_stall_cycles',0)):>10}")
        for k, label in STALL_CAUSES:
            print(f"  {'':<12}{'  ' + label:<22}{cb.get(k,0):>10}{ce.get(k,0):>10}"
                  f"{pct(cb.get(k,0), ce.get(k,0)):>10}")
        print()
    if not shown:
        print()

    print("=" * 78)
    print(" TOPOLOGY USAGE")
    print("=" * 78)
    for t in tests:
        cb = read_counters(os.path.join(RES, f"{t}_base.place"))
        ce = read_counters(os.path.join(RES, f"{t}_ehvgp.place"))
        if not cb or not ce:
            continue
        hb = [cb.get(f"topo_{i}_allocations", 0) for i in range(8)]
        he = [ce.get(f"topo_{i}_allocations", 0) for i in range(8)]
        print(f"  {t:<12} baseline {hb}")
        print(f"  {'':<12} e-hvgp   {he}")
    print()

    if bad:
        print(f"CORRECTNESS GATE FAILED on {bad} test(s)")
        return 1
    print("CORRECTNESS GATE PASSED: E-HVGP changed placement, not results.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
