# E-HVGP — EMUL-Driven Heterogeneous Vector-Group Placement

Research prototype of a RISC-V Vector (RVV) core used to test whether
choosing different physical VRF-bank placement topologies per vector
register group, driven by the EMUL/LMUL/SEW structure of the instruction,
reduces VRF bank conflicts on mixed-width operations.

Plain **Verilog-2001** only. Xcelium is the primary simulator; Vivado is the
synthesis target.

---

## Quick start

```bash
# Xcelium (primary)
./sim/run_xcelium.sh

# Icarus (local proof-of-correctness harness)
powershell -File sim/run_iverilog.ps1
python sim/compare.py
```

Single test with waves + allocation trace:

```bash
./sim/run_xcelium.sh mixed gui
```

```bash
vvp sim/out/ehvgp.vvp +HEX=tests/mixed/prog.hex +TRACE +WAVE
```

Vivado out-of-context synthesis:

```bash
vivado -mode batch -source vivado/synth.tcl -tclargs 0   # BASELINE
vivado -mode batch -source vivado/synth.tcl -tclargs 1   # E-HVGP
```

---

## Layout

```
rtl/common/      ehvgp_defs.vh, ehvgp_funcs.vh   (placement functions)
rtl/core/        rv_core.v, imem.v
rtl/decode/      rv_decode.v, rvv_decode.v
rtl/rename/      vector_rename.v                 (RAT + free list + allocator)
rtl/vector/      vector_config.v, vector_uop.v, vector_alu.v, vector_unit.v
rtl/vrf/         vrf.v, vrf_bank.v, vrf_arbiter.v
rtl/e_hvgp/      topology_table.v, bank_mapper.v,
                 topology_selector.v, ehvgp_allocator.v
tb/              tb_top.v
tests/           asm.py + same/ widening/ narrowing/ mixed/ stress/
sim/             filelist.f, run_xcelium.sh, run_iverilog.ps1, compare.py
vivado/          synth.tcl, constraints.xdc
docs/            architecture.md, ehvgp.md, verification.md, results.md
```

`rtl/e_hvgp/` is structurally separable from `rtl/vrf/`: the baseline VRF is
complete and verifiable standalone, and E-HVGP is layered on as an addition
rather than a rewrite.

---

## The two configurations

`EHVGP_ENABLE` reaches exactly one module, `ehvgp_allocator.v`.

* `0` — **BASELINE**: fixed round-robin, `topology = (rr_base, stride 1)`,
  `rr_base += EMUL_dst` per allocation.
* `1` — **E-HVGP**: topology chosen as a pure structural function of
  `(EMUL_dst, EMUL_s1, EMUL_s2, SEW, topo(vs1), topo(vs2))`.

Everything else — ISA, micro-op model, VRF, bank count, bandwidth,
arbitration, execution units, free-list search — is identical.

---

## Current status

Working end to end: RTL → compile → simulate → baseline → E-HVGP →
**identical architectural results** → different physical placement →
measured bank conflicts and cycles.

**The v1 mechanism does not currently beat the baseline.** That is a real
measured result, reported honestly, and the cause is isolated in
[`docs/results.md`](docs/results.md) Section 5. There is an open
architectural issue requiring sign-off before the mechanism is changed.

Vivado synthesis has **not** been run — no area or timing numbers are
claimed.
