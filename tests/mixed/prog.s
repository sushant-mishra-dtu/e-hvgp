# TEST 4 -- mixed workload
#
# Sequence pattern requested in the project brief:
#   same-width, widening, same-width, narrowing, widening, same-width
# repeated, so groups of EMUL 2 and EMUL 4 are alive at the same time
# and are read against each other.
#
# vtype: SEW = 16, LMUL = 2  ->  VLMAX = 16 elements

        vsetvli x1, x0, e16, m2

        vadd.vv    v8,  v0,  v2
        vwadd.vv   v12, v0,  v2
        vsub.vv    v10, v2,  v4
        vnsra.wv   v16, v12, v8
        vwmul.vv   v20, v8,  v10
        vadd.vv    v18, v16, v10

        vadd.vv    v24, v18, v8
        vwadd.vv   v28, v18, v16
        vsub.vv    v26, v24, v10
        vnsra.wv   v6,  v28, v24
        vwmul.vv   v12, v24, v26
        vadd.vv    v22, v6,  v26

        vadd.vv    v8,  v22, v24
        vwsub.vv   v28, v22, v26
        vsub.vv    v10, v8,  v6
        vnsra.wv   v2,  v12, v8
        vwmulu.vv  v16, v8,  v10
        vadd.vv    v4,  v2,  v10

        ecall
