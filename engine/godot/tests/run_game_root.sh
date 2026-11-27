#!/bin/bash
# M32 game root: stress at 30/60/120 fps with monkey runs, planted faults must fail, rates must agree.
# Usage: GODOT=/path/to/godot-4.7 tests/run_game_root.sh [monkey_runs] [monkey_secs]     exit 0 = all green
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
OUT=${OUT:-/tmp}
rc=0
for r in 30 60 120; do
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_game_root.gd -- --rate $r --monkey "${1:-2}" --monkey-secs "${2:-90}" --out "$OUT/m32_$r.json" 2>&1 | grep -E "^(PASS|FAIL|   G|M32)" || true
  python3 -c "import json,sys; d=json.load(open('$OUT/m32_$r.json')); sys.exit(0 if all(x['ok'] for x in d['results']) else 1)" || rc=1
done
for f in late_write clock grid; do
  if "$G" --headless --fixed-fps 60 --path . --script res://tests/test_game_root.gd -- --rate 60 --only R1 --fault $f >/dev/null 2>&1; then echo "M32 PLANTED FAULT $f NOT CAUGHT"; rc=1; else echo "M32 planted fault $f caught"; fi
done
python3 tests/compare_rates.py "$OUT" m32 || rc=1
echo "== M32 result: $([ $rc = 0 ] && echo ALL GREEN || echo FAILURES)"
exit $rc
