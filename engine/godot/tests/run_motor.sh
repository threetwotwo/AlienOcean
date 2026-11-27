#!/bin/bash
# M02/M23: run the motor harness at 30, 60 and 120 Hz (uncapped via --fixed-fps; without it Godot runs in real time),
# simulation tick fixed at 60 Hz, then the planted-fault run, which must FAIL. Usage: GODOT=/path/to/godot tests/run_motor.sh [monkey_runs] [monkey_secs]
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
M=${1:-4}; MS=${2:-300}; OUT=${OUT:-/tmp}
rc=0
for r in 30 60 120; do
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_motor.gd -- --rate $r --out "$OUT/m02_$r.json" --monkey "$M" --monkey-secs "$MS" 2>&1 | grep -E "PASS|FAIL|first failure|    t=" || true
  python3 -c "import json,sys; d=json.load(open('$OUT/m02_$r.json')); sys.exit(0 if all(x['ok'] for x in d['results']) else 1)" || rc=1
done
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_motor.gd -- --rate 60 --fault --only "T5" --out "$OUT/m02_fault.json" 2>&1 | grep -E "PASS|FAIL" || true
python3 -c "import json,sys; d=json.load(open('$OUT/m02_fault.json')); sys.exit(0 if not all(x['ok'] for x in d['results']) else 1)" && echo "planted fault caught" || { echo "PLANTED FAULT NOT CAUGHT"; rc=1; }
python3 tests/compare_rates.py "$OUT" || rc=1
# information only: how far results move if the simulation tick itself changed to 120 Hz (not a gate)
"$G" --headless --fixed-fps 120 --path . --script res://tests/test_motor.gd -- --rate 120 --tick 120 --out "$OUT/m02_tick120.json" 2>&1 | grep -E "FAIL|harness rate" || true
exit $rc
