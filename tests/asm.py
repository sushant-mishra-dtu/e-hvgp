#!/usr/bin/env python3
"""
asm.py -- tiny assembler for the E-HVGP research core.

Emits one 32-bit instruction word per line in $readmemh format.
Supported subset (matches rtl/decode/rv_decode.v + rtl/decode/rvv_decode.v):

  scalar : nop, li, addi, add, sub, bne, ecall
  rvv    : vsetvli, vsetvl,
           vadd.vv, vsub.vv, vmv.v.v,
           vwadd.vv, vwaddu.vv, vwsub.vv, vwmul.vv, vwmulu.vv,
           vnsrl.wv, vnsra.wv

Usage:  python asm.py <in.s> <out.hex>
"""
import sys
import re

# --------------------------------------------------------------------------
XREG = {f"x{i}": i for i in range(32)}
XREG.update({"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
             "t0": 5, "t1": 6, "t2": 7, "s0": 8, "fp": 8, "s1": 9,
             "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14,
             "a5": 15, "a6": 16, "a7": 17})
VREG = {f"v{i}": i for i in range(32)}

OPV = 0x57
OPIVV = 0b000
OPMVV = 0b010
OPCFG = 0b111

VV_FUNCT6 = {          # OPIVV
    "vadd.vv":   0b000000,
    "vsub.vv":   0b000010,
    "vnsrl.wv":  0b101100,
    "vnsra.wv":  0b101101,
}
MV_FUNCT6 = {          # OPMVV
    "vwaddu.vv": 0b110000,
    "vwadd.vv":  0b110001,
    "vwsubu.vv": 0b110010,
    "vwsub.vv":  0b110011,
    "vwmulu.vv": 0b111000,
    "vwmul.vv":  0b111011,
}

SEW_ENC = {8: 0, 16: 1, 32: 2, 64: 3}
LMUL_ENC = {1: 0, 2: 1, 4: 2, 8: 3}


def xr(t):
    t = t.strip()
    if t not in XREG:
        raise ValueError(f"bad scalar register '{t}'")
    return XREG[t]


def vr(t):
    t = t.strip()
    if t not in VREG:
        raise ValueError(f"bad vector register '{t}'")
    return VREG[t]


def enc_r(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_i(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_u(imm, rd, op):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | op


def enc_b(imm, rs2, rs1, f3, op):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | op


def enc_vop(f6, vm, vs2, vs1, f3, vd):
    return (f6 << 26) | (vm << 25) | (vs2 << 20) | (vs1 << 15) | \
           (f3 << 12) | (vd << 7) | OPV


def parse_vtype(args):
    """args like ['e16','m2','ta','ma'] -> 11-bit zimm"""
    sew = lmul = None
    vta = vma = 0
    for a in args:
        a = a.strip()
        if re.fullmatch(r"e\d+", a):
            sew = SEW_ENC[int(a[1:])]
        elif re.fullmatch(r"m\d+", a):
            lmul = LMUL_ENC[int(a[1:])]
        elif a == "ta":
            vta = 1
        elif a == "tu":
            vta = 0
        elif a == "ma":
            vma = 1
        elif a == "mu":
            vma = 0
        else:
            raise ValueError(f"bad vtype field '{a}'")
    if sew is None or lmul is None:
        raise ValueError("vsetvli needs both eNN and mN")
    return (vma << 7) | (vta << 6) | (sew << 3) | lmul


# --------------------------------------------------------------------------
def assemble(lines):
    # pass 1: labels
    labels = {}
    prog = []
    addr = 0
    for raw in lines:
        line = raw.split("#")[0].strip()
        if not line:
            continue
        m = re.match(r"^([A-Za-z_]\w*):\s*(.*)$", line)
        if m:
            labels[m.group(1)] = addr
            line = m.group(2).strip()
            if not line:
                continue
        prog.append((addr, line))
        addr += 4

    # pass 2: encode
    out = []
    for pc, line in prog:
        parts = line.split(None, 1)
        mn = parts[0].lower()
        ops = [o.strip() for o in parts[1].split(",")] if len(parts) > 1 else []

        if mn == "nop":
            out.append(enc_i(0, 0, 0b000, 0, 0x13))
        elif mn == "addi":
            out.append(enc_i(int(ops[2], 0), xr(ops[1]), 0b000, xr(ops[0]), 0x13))
        elif mn == "li":
            # single-instruction form only, so one source line is always one
            # instruction word and label offsets computed in pass 1 stay valid
            v = int(ops[1], 0)
            if not (-2048 <= v < 2048):
                raise ValueError(f"li out of 12-bit range ({v}); use lui + addi")
            out.append(enc_i(v, 0, 0b000, xr(ops[0]), 0x13))
        elif mn == "lui":
            out.append(enc_u(int(ops[1], 0), xr(ops[0]), 0x37))
        elif mn == "add":
            out.append(enc_r(0, xr(ops[2]), xr(ops[1]), 0b000, xr(ops[0]), 0x33))
        elif mn == "sub":
            out.append(enc_r(0b0100000, xr(ops[2]), xr(ops[1]), 0b000, xr(ops[0]), 0x33))
        elif mn == "bne":
            tgt = labels[ops[2]] if ops[2] in labels else int(ops[2], 0)
            out.append(enc_b(tgt - pc, xr(ops[1]), xr(ops[0]), 0b001, 0x63))
        elif mn == "ecall":
            out.append(0x00000073)
        elif mn == "vsetvli":
            z = parse_vtype(ops[2:])
            out.append((0 << 31) | (z << 20) | (xr(ops[1]) << 15) |
                       (OPCFG << 12) | (xr(ops[0]) << 7) | OPV)
        elif mn == "vsetvl":
            out.append(enc_r(0b1000000, xr(ops[2]), xr(ops[1]), OPCFG, xr(ops[0]), OPV))
        elif mn == "vmv.v.v":
            out.append(enc_vop(0b010111, 1, 0, vr(ops[1]), OPIVV, vr(ops[0])))
        elif mn in VV_FUNCT6:
            # vd, vs2, vs1
            out.append(enc_vop(VV_FUNCT6[mn], 1, vr(ops[1]), vr(ops[2]), OPIVV, vr(ops[0])))
        elif mn in MV_FUNCT6:
            out.append(enc_vop(MV_FUNCT6[mn], 1, vr(ops[1]), vr(ops[2]), OPMVV, vr(ops[0])))
        else:
            raise ValueError(f"unknown mnemonic '{mn}' in: {line}")
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    with open(sys.argv[1]) as f:
        words = assemble(f.readlines())
    with open(sys.argv[2], "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")
    print(f"{sys.argv[1]} -> {sys.argv[2]}  ({len(words)} instructions)")


if __name__ == "__main__":
    main()
