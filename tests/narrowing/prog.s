# TEST 3 -- narrowing arithmetic (EMUL_s2 = 2 * LMUL)
#
# Purpose: the mirror of TEST 2.  The oversized group is a SOURCE, so
#          each micro-op issues THREE VRF reads (vs1[i], vs2[2i],
#          vs2[2i+1]) instead of two.  This is the highest read-pressure
#          shape in the supported subset.
#
# vtype: SEW = 16, LMUL = 2  ->  VLMAX = 16 elements
#        vd/vs1 EMUL = 2 registers, vs2 EMUL = 4 registers

        vsetvli x1, x0, e16, m2

        # build wide (EMUL = 4) groups first
        vwadd.vv   v8,  v0, v2
        vwmul.vv   v12, v2, v4
        vwadd.vv   v16, v4, v6
        vwmul.vv   v20, v0, v6

        # now narrow them back down
        vnsra.wv   v24, v8,  v0
        vnsrl.wv   v26, v12, v2
        vnsra.wv   v28, v16, v4
        vnsrl.wv   v30, v20, v6
        vnsra.wv   v2,  v8,  v24
        vnsrl.wv   v4,  v12, v26
        vnsra.wv   v6,  v16, v28
        vnsrl.wv   v0,  v20, v30

        ecall
