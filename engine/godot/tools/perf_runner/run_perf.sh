#!/bin/bash
# Perf runner 0.1.0: plays the test level by itself and measures every station, full screen at native resolution by default (Gary 28 Nov: every run full screen).
# Usage: tools/perf_runner/run_perf.sh [extra perf_runner args, e.g. --only floor_look_down --no-toggles]
#   PROFILES="fullscreen" (default) | "window" | "WxH"     GODOT=/path/to/Godot (default: ../Godot_4.7 beside the repo, then /Applications)
# Output: <repo>/playtest_reports/perf/<UTC stamp>/ (results.json per profile, PNGs, summary.md, report.html). Prints the folder.
set -u
cd "$(dirname "$0")/../.."                       # engine/godot
REPO="$(cd ../.. && pwd)"
G=${GODOT:-}
[ -z "$G" ] && [ -x "$REPO/../Godot_4.7/Godot.app/Contents/MacOS/Godot" ] && G="$REPO/../Godot_4.7/Godot.app/Contents/MacOS/Godot"
[ -z "$G" ] && [ -x /Applications/Godot.app/Contents/MacOS/Godot ] && G=/Applications/Godot.app/Contents/MacOS/Godot
[ -z "$G" ] && { echo "Godot not found: set GODOT"; exit 2; }
STAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
OUT=${OUT:-$REPO/playtest_reports/perf/$STAMP}
mkdir -p "$OUT"
dirs=()
for p in ${PROFILES:-fullscreen}; do
  case $p in
    window) flags=(--windowed --resolution 960x540) ;;
    fullscreen) flags=(--fullscreen) ;;
    *) flags=(--windowed --resolution "$p") ;;
  esac
  mkdir -p "$OUT/$p"
  "$G" --path . ${flags[@]+"${flags[@]}"} --script res://tools/perf_runner/perf_runner.gd -- --out "$OUT/$p" --label "$p" "$@" > "$OUT/$p/godot.log" 2>&1
  echo "== $p: exit $?"; grep -E "^(PERF|TOGGLE)" "$OUT/$p/godot.log" | cut -c1-150
  if grep -q "SCRIPT ERROR" "$OUT/$p/godot.log"; then echo "SCRIPT ERRORS in $OUT/$p/godot.log"; grep -A3 "SCRIPT ERROR" "$OUT/$p/godot.log" | head -20; fi
  [ -f "$OUT/$p/results.json" ] && dirs+=("$OUT/$p")
done
python3 "$(dirname "$0")/summarize.py" "${dirs[@]}" --out "$OUT" > /dev/null && echo "summary: $OUT/summary.md  page: $OUT/report.html"
echo "$OUT"
