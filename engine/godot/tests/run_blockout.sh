#!/bin/bash
# Blockout kit + blockout stress scene (blockout/): measured kit, rider, senses, grey mode and motion cases in the gym,
# at 30/60/120 fps (simulation tick fixed at 60 Hz) and with the tick itself at 30/60/120 Hz; planted faults must FAIL;
# fixed-tick runs must end in the same place (compare_rates.py). Usage: GODOT=/path/to/godot-4.7 tests/run_blockout.sh
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
OUT=${OUT:-/tmp}
rc=0
for r in 30 60 120; do
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_blockout.gd -- --rate $r --out "$OUT/blk_$r.json" 2>&1 | grep -E "^FAIL|BLOCKOUT tick" || true
  python3 -c "import json,sys; d=json.load(open('$OUT/blk_$r.json')); sys.exit(0 if all(x['ok'] for x in d['results']) else 1)" || rc=1
done
python3 tests/compare_rates.py "$OUT" blk || rc=1
for r in 30 120; do   # the simulation tick itself at 30 and 120 Hz (the kit, rider and gym cases must still pass)
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_blockout.gd -- --rate $r --tick $r --out "$OUT/blk_tick$r.json" 2>&1 | grep -E "^FAIL|BLOCKOUT tick" || true
  python3 -c "import json,sys; d=json.load(open('$OUT/blk_tick$r.json')); sys.exit(0 if all(x['ok'] for x in d['results']) else 1)" || rc=1
done
for f in seat grey; do
  if "$G" --headless --fixed-fps 60 --path . --script res://tests/test_blockout.gd -- --fault $f >/dev/null 2>&1; then echo "BLOCKOUT PLANTED FAULT $f NOT CAUGHT"; rc=1; else echo "blockout planted fault $f caught"; fi
done
exit $rc
