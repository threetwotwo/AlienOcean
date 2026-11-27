#!/bin/bash
# Gameplay modules: every headless test, at 30/60/120 fps where it applies, planted faults must fail, rates must agree.
# Usage: GODOT=/path/to/godot-4.7 tests/run_all.sh [monkey_runs] [monkey_secs]     exit 0 = all green
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
OUT=${OUT:-/tmp}
rc=0
echo "== M01 input"
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_input.gd 2>&1 | grep -E "FAIL|M01" || true
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_input.gd >/dev/null 2>&1 || rc=1
echo "== Thalassa port checks (golden traces from the v20.19 JS)"
"$G" --headless --path . --script res://tests/test_golden_input.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_golden_input.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_golden_swimmer.gd 2>&1 | grep -E "PASS|FAIL|M02"; "$G" --headless --path . --script res://tests/test_golden_swimmer.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_golden_camera.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_golden_camera.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_golden_body.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_golden_body.gd >/dev/null 2>&1 || rc=1
echo "== M29 buoyancy"
for r in 30 60 120; do
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_buoyancy.gd -- --rate $r --out "$OUT/m29_$r.json" 2>&1 | grep -E "FAIL|M29" || true
  python3 -c "import json,sys; d=json.load(open('$OUT/m29_$r.json')); sys.exit(0 if all(x['ok'] for x in d['results']) else 1)" || rc=1
done
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_buoyancy.gd -- --rate 60 --fault --out "$OUT/m29_fault.json" >/dev/null 2>&1
python3 -c "import json,sys; d=json.load(open('$OUT/m29_fault.json')); sys.exit(0 if not all(x['ok'] for x in d['results']) else 1)" && echo "M29 planted fault caught" || { echo "M29 PLANTED FAULT NOT CAUGHT"; rc=1; }
python3 tests/compare_rates.py "$OUT" m29 || rc=1
echo "== M02 motor + M23 harness"
OUT="$OUT" bash tests/run_motor.sh "${1:-4}" "${2:-300}" | grep -vE "^PASS" || rc=1
[ "${PIPESTATUS[0]}" = "0" ] || rc=1
echo "== M03 camera"
for r in 30 60 120; do
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_camera.gd -- --rate $r --monkey "${1:-4}" --monkey-secs "${2:-300}" --out "$OUT/m03_$r.json" 2>&1 | grep -E "FAIL|M03" || true
  python3 -c "import json,sys; d=json.load(open('$OUT/m03_$r.json')); sys.exit(0 if all(x['ok'] for x in d['results']) else 1)" || rc=1
done
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_camera.gd -- --rate 60 --fault --only C2 --out "$OUT/m03_fault.json" >/dev/null 2>&1
python3 -c "import json,sys; d=json.load(open('$OUT/m03_fault.json')); sys.exit(0 if not all(x['ok'] for x in d['results']) else 1)" && echo "M03 planted fault caught" || { echo "M03 PLANTED FAULT NOT CAUGHT"; rc=1; }
python3 tests/compare_rates.py "$OUT" m03 || rc=1
echo "== result: $([ $rc = 0 ] && echo ALL GREEN || echo FAILURES)"
exit $rc
