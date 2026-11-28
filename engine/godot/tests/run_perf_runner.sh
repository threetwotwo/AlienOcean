#!/bin/bash
# Perf runner check (tools/perf_runner/): a short real-GPU run with the planted fault "slow" (40 ms burned per frame at
# keyframe_view). Pass = results.json written for both stations, keyframe_view is the slowest and over 40 ms, summary written,
# no script errors. Needs a GPU and a window (Mac, or xvfb + vulkan in the cloud).
# Usage: GODOT=/path/to/godot tests/run_perf_runner.sh     exit 0 = pass
set -u
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
PROFILES=window OUT="$OUT" tools/perf_runner/run_perf.sh --only keyframe_view,arch_gate --no-toggles --measure 1.5 --settle 1.0 --fault slow > "$OUT/run.txt" 2>&1
python3 - "$OUT" <<'EOF'
import json, sys, os
d = sys.argv[1]
r = json.load(open(os.path.join(d, "window", "results.json")))
s = {x["name"]: x for x in r["stations"]}
ok = set(s) == {"keyframe_view", "arch_gate"} and s["keyframe_view"]["mean_ms"] > 40 and s["keyframe_view"]["mean_ms"] > s["arch_gate"]["mean_ms"]
ok = ok and os.path.exists(os.path.join(d, "summary.md")) and os.path.exists(os.path.join(d, "window", "keyframe_view.png"))
log = open(os.path.join(d, "window", "godot.log")).read()
ok = ok and "SCRIPT ERROR" not in log
print("PERF RUNNER planted slow fault %s (keyframe_view %.1f ms, arch_gate %.1f ms)" % ("caught" if ok else "NOT CAUGHT", s.get("keyframe_view", {}).get("mean_ms", -1), s.get("arch_gate", {}).get("mean_ms", -1)))
sys.exit(0 if ok else 1)
EOF
