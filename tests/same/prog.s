# TEST 1 -- same-width vector arithmetic
#
# Purpose: correctness baseline.  EMUL_dst = EMUL_s1 = EMUL_s2 = LMUL,
#          so every group has the same shape and the placement problem
#          E-HVGP targets is NOT present.  Any A/B difference here is
#          incidental, which is exactly what makes it a useful control.
#
# vtype: SEW = 32, LMUL = 2  ->  VLMAX = 128/32 * 2 = 8 elements
#                                group size = 2 physical registers

        vsetvli x1, x0, e32, m2

        vadd.vv  v8,  v0,  v2
        vadd.vv  v10, v2,  v4
        vadd.vv  v12, v4,  v6
        vsub.vv  v14, v6,  v0
        vadd.vv  v16, v8,  v10
        vsub.vv  v18, v12, v14
        vadd.vv  v20, v16, v18
        vmv.v.v  v22, v20
        vadd.vv  v24, v22, v8
        vsub.vv  v26, v24, v12
        vadd.vv  v28, v26, v16
        vadd.vv  v30, v28, v20

        ecall
