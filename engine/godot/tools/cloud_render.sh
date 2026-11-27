#!/bin/bash
# cloud_render.sh: run Godot with a real Forward+ renderer in a cloud container (CPU Vulkan, about 3 fps).
# One-time setup per container: apt-get update && apt-get install -y mesa-vulkan-drivers xvfb ; Godot binary in $GODOT.
# Usage: tools/cloud_render.sh turnaround <in.glb> <out_dir> [size]     7-view turnaround + contact sheet
#        tools/cloud_render.sh test                                       headless logic tests (no renderer)
set -e
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
case "$1" in
  turnaround) shift; xvfb-run -a -s "-screen 0 1024x1024x24" "$G" --path . --rendering-driver vulkan --script res://tools/turnaround.gd -- "$@" ;;
  test) for t in tests/test_*.gd; do "$G" --headless --path . --script "res://$t"; done ;;
  *) echo "usage: $0 turnaround <in.glb> <out_dir> [size] | test"; exit 2 ;;
esac
