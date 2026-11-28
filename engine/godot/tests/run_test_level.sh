#!/bin/bash
# Test level T1 checks (plans/test_level/PLAN.md): headless run, planted faults must fail, no script errors.
# Usage: GODOT=/path/to/godot-4.7 tests/run_test_level.sh [ticks]     exit 0 = all green
# Drawn run (cloud, software GPU; add --gate-ms 33 on the Mac):
#   xvfb-run -a godot --path . --rendering-driver vulkan --script res://tests/test_test_level.gd -- --frames 600 --need-assets
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
OUT=${OUT:-/tmp}
rc=0
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_test_level.gd -- --ticks "${1:-3600}" --out "$OUT/test_level.json" > "$OUT/test_level.log" 2>&1 || rc=1
grep -E "^(PASS|FAIL) L|TESTLEVEL" "$OUT/test_level.log" | cut -c1-160
if grep -q "SCRIPT ERROR" "$OUT/test_level.log"; then echo "TESTLEVEL script errors:"; grep -A2 "SCRIPT ERROR" "$OUT/test_level.log" | head -20; rc=1; fi
for f in noshot stuck; do
  if "$G" --headless --fixed-fps 60 --path . --script res://tests/test_test_level.gd -- --ticks 60 --fault $f >/dev/null 2>&1; then echo "TESTLEVEL PLANTED FAULT $f NOT CAUGHT"; rc=1; else echo "TESTLEVEL planted fault $f caught"; fi
done
echo "== test level result: $([ $rc = 0 ] && echo ALL GREEN || echo FAILURES)"
exit $rc
