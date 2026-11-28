#!/bin/bash
# Alien Ocean: open the blockout gym (every grey test station in one world). Double-click in Finder.
# F6 next station (Shift+F6 back), F7 grey mode on/off (works in any level). Pick the first station with AO_STATION.
cd "$(dirname "$0")"
GODOT="../Godot_4.7/Godot.app/Contents/MacOS/Godot"
[ -x "$GODOT" ] || GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
if [ ! -x "$GODOT" ]; then echo "Godot 4.7 not found next to this folder (../Godot_4.7) or in /Applications."; read -r -p "Press Enter to close"; exit 1; fi
mkdir -p playtest_reports
"$GODOT" --headless --path engine/godot --import > playtest_reports/last_import.log 2>&1
AO_BLOCKOUT=1 AO_SCHOOLS=0 "$GODOT" --path engine/godot res://scenes/game.tscn 2>&1 | tee playtest_reports/last_blockout_run.log
