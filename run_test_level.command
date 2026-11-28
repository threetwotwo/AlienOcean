#!/bin/bash
# Alien Ocean: open the Godot test level (plans/test_level/PLAN.md, milestone T1). Double-click in Finder.
# F1 debug panel, F8 issue report (saved to playtest_reports/ here), click to look with the mouse, Esc frees it.
cd "$(dirname "$0")"
GODOT="../Godot_4.7/Godot.app/Contents/MacOS/Godot"
[ -x "$GODOT" ] || GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
if [ ! -x "$GODOT" ]; then echo "Godot 4.7 not found next to this folder (../Godot_4.7) or in /Applications."; read -r -p "Press Enter to close"; exit 1; fi
mkdir -p playtest_reports
# import every start: a few minutes the first time, a few seconds after (picks up new scripts and assets after an update)
[ -d engine/godot/.godot/imported ] || echo "First start: importing the project (a few minutes, once)..."
"$GODOT" --headless --path engine/godot --import > playtest_reports/last_import.log 2>&1
"$GODOT" --path engine/godot res://scenes/test_level.tscn 2>&1 | tee playtest_reports/last_run.log
