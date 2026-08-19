#!/bin/bash
#==========================================================================
# run_xcelium.sh -- PRIMARY simulation flow (Cadence Xcelium)
#
#   ./sim/run_xcelium.sh                 all tests, both configurations
#   ./sim/run_xcelium.sh mixed           one test
#   ./sim/run_xcelium.sh mixed wave      one test with SimVision database
#   ./sim/run_xcelium.sh mixed gui       one test, launch SimVision
#
# Must be run from the repository root (paths in filelist.f are relative
# to it).  Produces sim/out/res/<test>_<mode>.{log,arch,place}.
#==========================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

OUT="$ROOT/sim/out"
RES="$OUT/res"
mkdir -p "$OUT" "$RES"

ONLY="${1:-}"
MODE="${2:-}"

XRUN_COMMON="-64bit -access +rwc -sv_lib_off -f sim/filelist.f -top tb_top"
XRUN_COMMON="-64bit -access +rwc -f sim/filelist.f -top tb_top"

# ---- assemble the test programs -----------------------------------------
python3 sim/build_tests.py || { echo "assembler failed"; exit 1; }

if [ -n "$ONLY" ]; then
   TESTS="$ONLY"
else
   TESTS=$(ls -d tests/*/ | xargs -n1 basename)
fi

FAIL=0

for T in $TESTS; do
   HEX="tests/$T/prog.hex"
   [ -f "$HEX" ] || continue

   for CFG in base ehvgp; do
      if [ "$CFG" = "ehvgp" ]; then DEF="+define+EHVGP"; else DEF=""; fi

      EXTRA=""
      if [ "$MODE" = "wave" ] || [ "$MODE" = "gui" ]; then
         EXTRA="+WAVE +define+XCELIUM"
         DEF="$DEF +define+XCELIUM"
      fi
      if [ "$MODE" = "gui" ]; then EXTRA="$EXTRA -gui"; fi

      echo "=============================================================="
      echo " xrun  test=$T  config=$CFG"
      echo "=============================================================="

      # shellcheck disable=SC2086
      xrun $XRUN_COMMON $DEF \
           -xmlibdirname "$OUT/xcelium.d.$CFG" \
           -l "$RES/${T}_${CFG}.xrun.log" \
           +HEX="$HEX" \
           +NAME="$T" \
           +ARCH="$RES/${T}_${CFG}.arch" \
           +PLACE="$RES/${T}_${CFG}.place" \
           +MAXCYC=200000 \
           $EXTRA | tee "$RES/${T}_${CFG}.log"

      grep -q "RESULT: PASS" "$RES/${T}_${CFG}.log" || { echo "SIM FAIL $T/$CFG"; FAIL=1; }
   done

   # ---- hard invariant: architectural results must be identical ---------
   if diff -q "$RES/${T}_base.arch" "$RES/${T}_ehvgp.arch" >/dev/null 2>&1; then
      echo ">>> $T : ARCHITECTURAL RESULTS IDENTICAL  (invariant holds)"
   else
      echo ">>> $T : *** ARCHITECTURAL MISMATCH -- E-HVGP CHANGED RESULTS ***"
      diff "$RES/${T}_base.arch" "$RES/${T}_ehvgp.arch" | head -40
      FAIL=1
   fi
done

echo ""
python3 sim/compare.py || FAIL=1

exit $FAIL
