#!/bin/bash
# CORTAO screen AO checks (tools/cortao_check.gd C1-C7) and its planted faults. Needs a GPU (not --headless): on the Mac run as is;
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
if CORTAO_FAULT_COARSE=1 $X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" --fault coarse >/dev/null 2>&1; then echo "CORTAO PLANTED FAULT coarse NOT CAUGHT"; rc=1; else echo "CORTAO planted fault coarse caught"; fi
if CORTAO_FAULT_EDGE=1 $X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" --fault edge >/dev/null 2>&1; then echo "CORTAO PLANTED FAULT edge NOT CAUGHT"; rc=1; else echo "CORTAO planted fault edge caught"; fi
"$G" --headless --path . --script res://tests/test_screen_ao_gate.gd 2>&1 | grep -E "^(PASS|FAIL)|GATE" || true
"$G" --headless --path . --script res://tests/test_screen_ao_gate.gd >/dev/null 2>&1 || rc=1
if "$G" --headless --path . --script res://tests/test_screen_ao_gate.gd -- --fault noinc >/dev/null 2>&1; then echo "SCREEN AO GATE PLANTED FAULT noinc NOT CAUGHT"; rc=1; else echo "screen AO gate planted fault noinc caught"; fi
echo "-- cortao full res (CORTAO_HALF=0)"
CORTAO_HALF=0 $X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" 2>&1 | grep -E "^(PASS|FAIL)|CORTAO_CHECK" || true
CORTAO_HALF=0 $X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" >/dev/null 2>&1 || rc=1
for A in gtao vbao; do   # the head to head's other methods (CORTAO_ALGO): same planted scene, same checks
	echo "-- $A"
	CORTAO_ALGO=$A $X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" 2>&1 | grep -E "^(PASS|FAIL)|CORTAO_CHECK" || true
	CORTAO_ALGO=$A $X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" >/dev/null 2>&1 || rc=1
done
echo "== CORTAO result: $([ $rc = 0 ] && echo ALL GREEN || echo FAILURES)"
exit $rc
