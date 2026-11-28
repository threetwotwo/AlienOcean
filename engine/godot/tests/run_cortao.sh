#!/bin/bash
# CORTAO screen AO checks (tools/cortao_check.gd C1-C5) and its planted fault. Needs a GPU (not --headless): on the Mac run as is;
# in the cloud: VK_ICD_FILENAMES=/opt/lavapipe/lvp_icd.json and XVFB="xvfb-run -a".   exit 0 = all green
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
OUT=${OUT:-/tmp}/cortao_check
X=${XVFB:-}
rc=0
$X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" 2>&1 | grep -E "^(PASS|FAIL)|CORTAO_CHECK"
$X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" >/dev/null 2>&1 || rc=1
if $X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" --fault flip >/dev/null 2>&1; then echo "CORTAO PLANTED FAULT flip NOT CAUGHT"; rc=1; else echo "CORTAO planted fault flip caught"; fi
echo "== CORTAO result: $([ $rc = 0 ] && echo ALL GREEN || echo FAILURES)"
exit $rc
