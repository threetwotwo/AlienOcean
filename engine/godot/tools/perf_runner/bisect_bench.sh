#!/bin/bash
# Bisect bench 0.1.0 (test level thread, 28 Nov 2026): runs the full-screen bench (run_benchmark.command's run) at each commit
# given, in this checkout, and prints each commit's BENCH rows side by side, to find which merge added frame time.
# Usage (repo root, clean tree): engine/godot/tools/perf_runner/bisect_bench.sh 133ea90 221182a 018278c c454dcb eb9b775 adb7c58
# Each commit: checkout (detached), import, bench x2 (the second run is kept: the first warms the shader cache). Ends back on
# the branch it started on. Output: playtest_reports/bisect_<utc>/<commit>.log and summary.txt.
set -u
# run from a copy: checking out an older commit removes or changes this file under a running bash
if [ -z "${BISECT_COPY:-}" ]; then cp "$0" /tmp/ao_bisect_bench.sh; BISECT_COPY=1 exec bash /tmp/ao_bisect_bench.sh "$@"; fi
cd "$(git rev-parse --show-toplevel)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then echo "tree not clean: commit or stash first"; exit 1; fi
GODOT="../Godot_4.7/Godot.app/Contents/MacOS/Godot"
[ -x "$GODOT" ] || GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
START=$(git rev-parse --abbrev-ref HEAD); [ "$START" = "HEAD" ] && START=$(git rev-parse HEAD)
OUT="playtest_reports/bisect_$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
for c in "$@"; do
  git checkout -q --detach "$c" || { echo "$c: checkout failed" | tee -a "$OUT/summary.txt"; continue; }
  "$GODOT" --headless --path engine/godot --import > "$OUT/$c.import.log" 2>&1
  for run in 1 2; do AO_BENCH=1 "$GODOT" --path engine/godot res://scenes/test_level.tscn > "$OUT/$c.log" 2>&1; done
  { echo "== $c $(git log -1 --format=%s "$c" | cut -c1-70)"; grep "^BENCH" "$OUT/$c.log"; } | tee -a "$OUT/summary.txt"
done
git checkout -q "$START"
echo "summary: $OUT/summary.txt"
