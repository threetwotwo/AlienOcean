#!/bin/bash
# CORTAO screen AO checks (tools/cortao_check.gd C1-C7) and its planted faults. Needs a GPU (not --headless): on the Mac run as is;
# in the cloud: VK_ICD_FILENAMES=/opt/lavapipe/lvp_icd.json and XVFB="xvfb-run -a".   exit 0 = all green
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
OUT=${OUT:-/tmp}/cortao_check
X=${XVFB:-}
rc=0
mkdir -p "$OUT"
$X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" > "$OUT/check.log" 2>&1 || rc=1
grep -E "^(PASS|FAIL)|CORTAO_CHECK" "$OUT/check.log"
# C8: resizing remakes the targets; no draw may be left without its material uniform set (the AO texture freed under it)
n8=$(grep -c "Uniforms were never supplied" "$OUT/check.log")
if [ "$n8" = "0" ]; then echo "PASS C8 no unbound material uniform sets after resizes"; else echo "FAIL C8 $n8 draws without their material uniform set"; rc=1; fi
n8f=$(CORTAO_FAULT_FREE=1 $X "$G" --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- "$OUT" --fault free 2>&1 | grep -c "Uniforms were never supplied")
if [ "$n8f" = "0" ]; then echo "CORTAO PLANTED FAULT free NOT CAUGHT"; rc=1; else echo "CORTAO planted fault free caught ($n8f errors)"; fi
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
