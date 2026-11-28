#!/bin/bash
# Alien Ocean: open the Godot project in the editor (press F5 / Play to run the test level).
cd "$(dirname "$0")"
GODOT="../Godot_4.7/Godot.app/Contents/MacOS/Godot"
[ -x "$GODOT" ] || GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
"$GODOT" -e --path engine/godot
