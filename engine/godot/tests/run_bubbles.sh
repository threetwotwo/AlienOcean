#!/bin/bash
# M34 bubbles (bubbles thread): the motion maths, no-jitter sampling, and the bubble sources in the blockout gym, at
# 30/60/120 fps and with the simulation tick itself at 30/120 Hz; the planted 1 cm hop must FAIL.
# Usage: GODOT=/path/to/godot-4.7 tests/run_bubbles.sh
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
rc=0
for r in 30 60 120; do
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_bubbles.gd 2>&1 | grep -E "^(FAIL|PASS|B[0-9])" || rc=1
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_bubbles.gd >/dev/null 2>&1 || rc=1
done
for t in 30 120; do
  "$G" --headless --fixed-fps 60 --path . --script res://tests/test_bubbles.gd -- --tick $t 2>&1 | grep -E "^(FAIL|PASS)" ; "$G" --headless --fixed-fps 60 --path . --script res://tests/test_bubbles.gd -- --tick $t >/dev/null 2>&1 || rc=1
done
if "$G" --headless --fixed-fps 60 --path . --script res://tests/test_bubbles.gd -- --fault jump >/dev/null 2>&1; then echo "BUBBLES PLANTED FAULT jump NOT CAUGHT"; rc=1; else echo "bubbles planted fault jump caught"; fi
exit $rc
