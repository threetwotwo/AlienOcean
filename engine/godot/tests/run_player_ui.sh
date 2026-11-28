#!/bin/bash
# Player UI checks U0-U8 (tests/test_player_ui.gd): headless, planted faults must fail, no script errors.
# Usage: GODOT=/path/to/godot-4.7 tests/run_player_ui.sh     exit 0 = all green
set -u
cd "$(dirname "$0")/.."
G=${GODOT:?set GODOT to the Godot binary}
OUT=${OUT:-/tmp}
rc=0
"$G" --headless --fixed-fps 60 --path . --script res://tests/test_player_ui.gd > "$OUT/player_ui.log" 2>&1 || rc=1
grep -E "^(PASS|FAIL) |PLAYER UI" "$OUT/player_ui.log" | cut -c1-160
if grep -q "SCRIPT ERROR" "$OUT/player_ui.log"; then echo "PLAYER UI script errors:"; grep -A2 "SCRIPT ERROR" "$OUT/player_ui.log" | head -20; rc=1; fi
for f in flicker nolatch; do
  if "$G" --headless --fixed-fps 60 --path . --script res://tests/test_player_ui.gd -- --fault $f >/dev/null 2>&1; then echo "PLAYER UI PLANTED FAULT $f NOT CAUGHT"; rc=1; else echo "PLAYER UI planted fault $f caught"; fi
done
echo "== player UI result: $([ $rc = 0 ] && echo ALL GREEN || echo FAILURES)"
exit $rc
