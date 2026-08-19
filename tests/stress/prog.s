# TEST 5 -- stress workload
#
# Multiple vector groups with varying LMUL/EMUL relationships, driven in a
# loop so the steady-state placement behaviour dominates the measurement
# rather than start-up transients.
#
#   phase A : SEW=32 LMUL=1  (group size 1)  + widening (group size 2)
#   phase B : SEW=16 LMUL=2  (group size 2)  + widening (group size 4)
#   phase C : SEW=8  LMUL=4  (group size 4)  + widening (group size 8)
#   phase D : narrowing at LMUL=2
#
# Loop count is held in x5.

        li      x5, 8

loop:
        # ---- phase A : LMUL 1, widen to 2 --------------------------
        vsetvli x1, x0, e32, m1
        vadd.vv    v8,  v0, v1
        vsub.vv    v9,  v1, v2
        vwadd.vv   v10, v8, v9
        vwmul.vv   v12, v0, v1
        vadd.vv    v14, v10, v12
        vadd.vv    v15, v11, v13

        # ---- phase B : LMUL 2, widen to 4 --------------------------
        vsetvli x1, x0, e16, m2
        vadd.vv    v16, v8,  v10
        vwadd.vv   v20, v16, v12
        vsub.vv    v18, v14, v16
        vwmul.vv   v24, v18, v16
        vadd.vv    v28, v20, v24
        vsub.vv    v30, v24, v20

        # ---- phase C : LMUL 4, widen to 8 --------------------------
        vsetvli x1, x0, e8, m4
        vadd.vv    v0,  v16, v20
        vwadd.vv   v8,  v0,  v4
        vsub.vv    v4,  v24, v28
        vwmulu.vv  v16, v0,  v4

        # ---- phase D : narrowing at LMUL 2 -------------------------
        vsetvli x1, x0, e16, m2
        vnsra.wv   v26, v8,  v0
        vnsrl.wv   v24, v12, v2
        vnsra.wv   v22, v16, v4
        vnsrl.wv   v30, v20, v6

        addi    x5, x5, -1
        bne     x5, x0, loop

        ecall
