# TEST 2 -- widening arithmetic (EMUL_dst = 2 * LMUL)
#
# Purpose: the core mechanism-triggering case.  Destination groups are
#          4 physical registers while source groups are 2, so under the
#          BASELINE round-robin the start-bank rotation advances by 4,
#          which is a NO-OP modulo NUM_BANKS = 4: every widening result
#          gets the SAME bank sequence.
#
# vtype: SEW = 16, LMUL = 2  ->  VLMAX = 128/16 * 2 = 16 elements
#        src EMUL = 2 registers, dst EMUL = 4 registers (4-reg aligned)

        vsetvli x1, x0, e16, m2

        vwadd.vv   v8,  v0, v2
        vwmul.vv   v12, v4, v6
        vwadd.vv   v16, v2, v4
        vwmul.vv   v20, v0, v6
        vwaddu.vv  v24, v2, v6
        vwmulu.vv  v28, v0, v4

        vwsub.vv   v8,  v4, v2
        vwadd.vv   v12, v6, v0
        vwmul.vv   v16, v0, v2
        vwadd.vv   v20, v4, v6
        vwmul.vv   v24, v6, v2
        vwadd.vv   v28, v2, v0

        ecall
