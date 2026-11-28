## M01 Input, haptics 0.1.0 (core, engine-agnostic): the rumble events of Thalassa v20.19 as data, plus its rules from
## core/input.js playHaptic(): pad only (never while keyboard is the last device), a 42 ms minimum gap, 20-420 ms length,
## and a player switch (options menu). The adapter turns a returned pulse into Input.start_joy_vibration().
## Values are Thalassa's own (strong, weak, ms), with the runtime.js call site each came from.
extends RefCounted

const MIN_GAP_MS := 42.0
const EVENTS := {
	"controller_connected": [0.18, 0.24, 90],   # runtime.js 1071 onGamepadChange
	"menu_move":            [0.06, 0.10, 35],   # 2951 crew menu tab step
	"menu_confirm":         [0.10, 0.16, 55],   # 2900 radio station step (a light confirm)
	"interact":             [0.16, 0.24, 75],   # 2871 chart waypoint plotted
	"hold_tick":            [0.05, 0.08, 30],   # new: soft ticks while a hold fills (each quarter)
	"sample_done":          [0.40, 0.22, 160],  # 1979 dock clamp (the strongest "it's done" pulse)
	"boost":                [0.32, 0.24, 140],  # 2639 onBoostIgnite (flipper-kick burst)
	"breach":               [0.22, 0.14, 120],  # 2270 sonar ping strength, used for leaving the water
	"splash":               [0.25, 0.25, 110],  # 2532 onSplash (impact / 6 clamped 0.12-0.45; mid value)
	"photo":                [0.08, 0.28, 55],   # 946 camera shutter
}

var enabled := true
var strength := 1.0               # options: 0..1 multiplier
var _last_ms := -1e9

## Pulse for an event at clock time now_ms, or {} when it must not play. {weak, strong, sec}
func pulse(event: String, now_ms: float, on_pad: bool, scale := 1.0) -> Dictionary:
	if not enabled or not on_pad or not EVENTS.has(event) or strength <= 0.0: return {}
	if now_ms - _last_ms < MIN_GAP_MS: return {}
	_last_ms = now_ms
	var e: Array = EVENTS[event]
	var k := clampf(strength * scale, 0.0, 1.0)
	return {"strong": clampf(e[0] * k, 0.0, 1.0), "weak": clampf(e[1] * k, 0.0, 1.0), "sec": clampf(e[2], 20.0, 420.0) / 1000.0}
