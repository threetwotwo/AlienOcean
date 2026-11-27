#!/bin/bash
# M31 fish schools: golden port check, stress harness (S2-S10 + monkey runs), planted fault must fail.
# Usage: GODOT=/path/to/godot-4.7 tests/run_school.sh [monkey_runs] [monkey_secs]     exit 0 = all green
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
OUT=${OUT:-/tmp}
rc=0
echo "== M31 port check (numpy school.py golden trace)"
"$G" --headless --path . --script res://tests/test_golden_school.gd 2>&1 | grep -E "PASS|FAIL" ; "$G" --headless --path . --script res://tests/test_golden_school.gd >/dev/null 2>&1 || rc=1
echo "== M31 stress harness"
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_school.gd -- --monkey "${1:-4}" --monkey-secs "${2:-40}" --out "$OUT/m31.json" 2>&1 | grep -E "PASS|FAIL|M31" || true
python3 -c "import json,sys; d=json.load(open('$OUT/m31.json')); sys.exit(0 if all(x['ok'] for x in d['results']) else 1)" || rc=1
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_school.gd -- --fault --only S3 --out "$OUT/m31_fault.json" >/dev/null 2>&1
python3 -c "import json,sys; d=json.load(open('$OUT/m31_fault.json')); sys.exit(0 if not all(x['ok'] for x in d['results'] if x['id']=='S3') else 1)" && echo "M31 planted fault caught" || { echo "M31 PLANTED FAULT NOT CAUGHT"; rc=1; }
echo "== result: $([ $rc = 0 ] && echo ALL GREEN || echo FAILURES)"
exit $rc
