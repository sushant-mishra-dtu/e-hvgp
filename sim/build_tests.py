#!/usr/bin/env python3
"""Assemble every tests/<name>/prog.s into tests/<name>/prog.hex."""
import os
import sys
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASM = os.path.join(ROOT, "tests", "asm.py")
TESTS = os.path.join(ROOT, "tests")

rc = 0
for name in sorted(os.listdir(TESTS)):
    d = os.path.join(TESTS, name)
    src = os.path.join(d, "prog.s")
    if not os.path.isfile(src):
        continue
    dst = os.path.join(d, "prog.hex")
    r = subprocess.run([sys.executable, ASM, src, dst])
    rc |= r.returncode
sys.exit(rc)
