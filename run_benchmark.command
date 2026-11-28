#!/bin/bash
# Alien Ocean: measure what each system costs on this Mac (about 1 minute, then it closes by itself).
# The result is saved as playtest_reports/bench_<time>.json. Don't touch the mouse or pad while it runs.
cd "$(dirname "$0")"
GODOT="../Godot_4.7/Godot.app/Contents/MacOS/Godot"
[ -x "$GODOT" ] || GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
if [ ! -d engine/godot/.godot/imported ]; then "$GODOT" --headless --path engine/godot --import; fi
mkdir -p playtest_reports
AO_BENCH=1 "$GODOT" --path engine/godot res://scenes/test_level.tscn 2>&1 | tee playtest_reports/last_bench.log | grep BENCH
echo "Done. You can close this window."
