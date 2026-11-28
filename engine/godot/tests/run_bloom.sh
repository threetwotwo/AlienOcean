#!/bin/bash
# Bloom checks (tools/bloom_check.gd B1-B3: energy kept, key frame PSF shape, no positional flicker) and its planted fault.
# Needs a GPU (not --headless): on the Mac run as is; in the cloud: VK_ICD_FILENAMES=/opt/lavapipe/lvp_icd.json and XVFB="xvfb-run -a".
# exit 0 = all green
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
X=${XVFB:-}
rc=0
$X "$G" --path . --rendering-driver vulkan --script res://tools/bloom_check.gd 2>&1 | grep -E "^(B[0-9]|  r)|BLOOM CHECK"
$X "$G" --path . --rendering-driver vulkan --script res://tools/bloom_check.gd >/dev/null 2>&1 || rc=1
if $X "$G" --path . --rendering-driver vulkan --script res://tools/bloom_check.gd -- --fault >/dev/null 2>&1; then echo "BLOOM PLANTED FAULT NOT CAUGHT"; rc=1; else echo "Bloom planted fault caught"; fi
echo "== Bloom result: $([ $rc = 0 ] && echo ALL GREEN || echo FAILURES)"
exit $rc
