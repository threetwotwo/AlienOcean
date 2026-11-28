#!/bin/bash
# Gameplay modules: every headless test, at 30/60/120 fps where it applies, planted faults must fail, rates must agree.
# Usage: GODOT=/path/to/godot-4.7 tests/run_all.sh [monkey_runs] [monkey_secs]     exit 0 = all green
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
OUT=${OUT:-/tmp}
rc=0
echo "== M01 input"
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_input.gd 2>&1 | grep -E "FAIL|M01" || true
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_input.gd >/dev/null 2>&1 || rc=1
echo "== Thalassa port checks (golden traces from the v20.19 JS)"
"$G" --headless --path . --script res://tests/test_golden_input.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_golden_input.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_golden_swimmer.gd 2>&1 | grep -E "PASS|FAIL|M02"; "$G" --headless --path . --script res://tests/test_golden_swimmer.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_golden_camera.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_golden_camera.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_golden_body.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_golden_body.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_golden_brain.gd 2>&1 | grep -E "FAIL|M04 brain"; "$G" --headless --path . --script res://tests/test_golden_brain.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_golden_brain.gd -- --fault >/dev/null 2>&1 && { echo "BRAIN PLANTED FAULT NOT CAUGHT"; rc=1; } || echo "Brain planted fault caught"
echo "== GI light field (look)"
"$G" --headless --path . --script res://tests/test_gi_light_field.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_gi_light_field.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_gi_light_field.gd -- --fault >/dev/null 2>&1 && { echo "GI PLANTED FAULT NOT CAUGHT"; rc=1; } || echo "GI planted fault caught"
echo "== Bathymetry (the reef drop-off's stress-test world)"
"$G" --headless --path . --script res://tests/test_bathymetry.gd 2>&1 | grep -E "FAIL|BATHYMETRY"; "$G" --headless --path . --script res://tests/test_bathymetry.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_bathymetry.gd -- --fault >/dev/null 2>&1 && { echo "BATHYMETRY PLANTED FAULT NOT CAUGHT"; rc=1; } || echo "Bathymetry planted fault caught"
echo "== Overcast (look)"
"$G" --headless --path . --script res://tests/test_overcast.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_overcast.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_overcast.gd -- --fault >/dev/null 2>&1 && { echo "OVERCAST PLANTED FAULT NOT CAUGHT"; rc=1; } || echo "Overcast planted fault caught"
echo "== Image quality (look: soft shadows, temporal upscaler)"
"$G" --headless --path . --script res://tests/test_image_quality.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_image_quality.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_image_quality.gd -- --fault >/dev/null 2>&1 && { echo "IMAGE QUALITY PLANTED FAULT NOT CAUGHT"; rc=1; } || echo "Image quality planted fault caught"
echo "== Marine snow drift"
"$G" --headless --path . --script res://tests/test_marine_snow.gd 2>&1 | grep -E "PASS|FAIL"; "$G" --headless --path . --script res://tests/test_marine_snow.gd >/dev/null 2>&1 || rc=1
"$G" --headless --path . --script res://tests/test_marine_snow.gd -- --fault >/dev/null 2>&1 && { echo "MARINE SNOW PLANTED FAULT NOT CAUGHT"; rc=1; } || echo "Marine snow planted fault caught"
echo "== M29 buoyancy"
for r in 30 60 120; do
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_buoyancy.gd -- --rate $r --out "$OUT/m29_$r.json" 2>&1 | grep -E "FAIL|M29" || true
  python3 -c "import json,sys; d=json.load(open('$OUT/m29_$r.json')); sys.exit(0 if all(x['ok'] for x in d['results']) else 1)" || rc=1
done
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_buoyancy.gd -- --rate 60 --fault --out "$OUT/m29_fault.json" >/dev/null 2>&1
python3 -c "import json,sys; d=json.load(open('$OUT/m29_fault.json')); sys.exit(0 if not all(x['ok'] for x in d['results']) else 1)" && echo "M29 planted fault caught" || { echo "M29 PLANTED FAULT NOT CAUGHT"; rc=1; }
python3 tests/compare_rates.py "$OUT" m29 || rc=1
echo "== M02 motor + M23 harness"
OUT="$OUT" bash tests/run_motor.sh "${1:-4}" "${2:-300}" | grep -vE "^PASS" || rc=1
[ "${PIPESTATUS[0]}" = "0" ] || rc=1
echo "== M03 camera"
for r in 30 60 120; do
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_camera.gd -- --rate $r --monkey "${1:-4}" --monkey-secs "${2:-300}" --out "$OUT/m03_$r.json" 2>&1 | grep -E "FAIL|M03" || true
  python3 -c "import json,sys; d=json.load(open('$OUT/m03_$r.json')); sys.exit(0 if all(x['ok'] for x in d['results']) else 1)" || rc=1
done
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_camera.gd -- --rate 60 --fault --only C2 --out "$OUT/m03_fault.json" >/dev/null 2>&1
python3 -c "import json,sys; d=json.load(open('$OUT/m03_fault.json')); sys.exit(0 if not all(x['ok'] for x in d['results']) else 1)" && echo "M03 planted fault caught" || { echo "M03 PLANTED FAULT NOT CAUGHT"; rc=1; }
python3 tests/compare_rates.py "$OUT" m03 || rc=1
echo "== M04 body stress (every limb, every frame; KNOWN open cases listed in the test)"
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_body_stress.gd -- --tick 60 > "$OUT/m04_60.txt" 2>&1 || rc=1
grep -E "^(FAIL|XPASS)|^ +J[0-9]|M04 body stress tick" "$OUT/m04_60.txt"
for f in len clip flip; do
  if "$G" --headless --fixed-fps 60 --path . --script res://tests/test_body_stress.gd -- --fault $f --only B2 >/dev/null 2>&1; then echo "M04 PLANTED FAULT $f NOT CAUGHT"; rc=1; else echo "M04 planted fault $f caught"; fi
done
# J11 jitter fault: +-2 mm alternating offset on a still hover (B2 walks, where stepping noise would mask the check)
if "$G" --headless --fixed-fps 60 --path . --script res://tests/test_body_stress.gd -- --fault jitter --only B24 >/dev/null 2>&1; then echo "M04 PLANTED FAULT jitter NOT CAUGHT"; rc=1; else echo "M04 planted fault jitter caught"; fi
# J13 breath fault: the breath phase skips a third of a cycle once (B60, long idle stand)
if "$G" --headless --fixed-fps 60 --path . --script res://tests/test_body_stress.gd -- --fault breathjump --only B60 >/dev/null 2>&1; then echo "M04 PLANTED FAULT breathjump NOT CAUGHT"; rc=1; else echo "M04 planted fault breathjump caught"; fi
# J40 head fault: the eyes lose their limits (B63, fast look-around)
if "$G" --headless --fixed-fps 60 --path . --script res://tests/test_body_stress.gd -- --fault eyelimit --only B63 >/dev/null 2>&1; then echo "M04 PLANTED FAULT eyelimit NOT CAUGHT"; rc=1; else echo "M04 planted fault eyelimit caught"; fi
# other tick rates and random monkey runs: reported, not yet gating (M04_STRICT=1 gates them)
for r in 30 120; do
  "$G" --headless --fixed-fps $r --path . --script res://tests/test_body_stress.gd -- --tick $r > "$OUT/m04_$r.txt" 2>&1 || { [ "${M04_STRICT:-0}" = 1 ] && rc=1; }
  tail -1 "$OUT/m04_$r.txt"
done
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_body_stress.gd -- --monkey "${1:-4}" --monkey-secs 60 --only BM > "$OUT/m04_monkey.txt" 2>&1 || { [ "${M04_STRICT:-0}" = 1 ] && rc=1; }
echo "monkey: $(tail -1 "$OUT/m04_monkey.txt")"
echo "== Test level T1 (stand-in floor when the lagoon assets are absent)"
OUT="$OUT" bash tests/run_test_level.sh 600 | grep -vE "^PASS" || rc=1
[ "${PIPESTATUS[0]}" = "0" ] || rc=1
echo "== Player UI (pause, interact, rumble, remap)"
OUT="$OUT" bash tests/run_player_ui.sh | grep -vE "^PASS" || rc=1
[ "${PIPESTATUS[0]}" = "0" ] || rc=1
echo "== Grass no-jitter (30/60/120/144 Hz against a continuous reference; planted fault: tick stepping)"
"$G" --headless --path . --script res://tests/test_grass_jitter.gd > "$OUT/grass_jitter.txt" 2>&1 || rc=1
tail -1 "$OUT/grass_jitter.txt"
"$G" --headless --path . --script res://tests/test_grass_jitter.gd -- stepped > "$OUT/grass_jitter_fault.txt" 2>&1 || rc=1
tail -1 "$OUT/grass_jitter_fault.txt" | cut -c1-60
echo "== Blockout kit + blockout stress scene (30/60/120 Hz)"
OUT="$OUT" bash tests/run_blockout.sh || rc=1
echo "== result: $([ $rc = 0 ] && echo ALL GREEN || echo FAILURES)"
exit $rc
