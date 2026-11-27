## M01 Input, action table 0.2.0 (data, engine-agnostic): every game action and its default bindings.
## Pad entries use SDL/Godot standard indices (buttons: 0 Cross/A, 1 Circle/B, 2 Square/X, 3 Triangle/Y, 4 Create/Back,
## 5 PS/Guide, 6 Options/Start, 7 L3, 8 R3, 9 L1, 10 R1, 11-14 D-pad up/down/left/right, 20 touch pad;
## axes: 0/1 left stick, 2/3 right stick, 4 L2, 5 R2). Create (4) and PS (5) belong to the system and are never bound.
extends RefCounted

const RESERVED_PAD_BUTTONS := [4, 5]

# action: {pad_button, pad_button_alt | pad_axis [axis, sign], key, mouse}
# Layout = Thalassa v20.19 core/input.js (Gary's DualSense map), with three changes that platform rules force:
#   Create is the system capture button, so TARS (Create tap/hold in Thalassa) moves to D-pad right;
#   the radio (Square, touch pad) is optional ambience, so Square becomes interact and the touch pad the chart;
#   recall-sub (D-pad right outside a vessel) moves into the companion radial with the other fleet orders.
const ACTIONS := {
	"move_left":    {"pad_axis": [0, -1], "key": "A"},
	"move_right":   {"pad_axis": [0, 1],  "key": "D"},
	"move_forward": {"pad_axis": [1, -1], "key": "W"},
	"move_back":    {"pad_axis": [1, 1],  "key": "S"},
	"look_left":    {"pad_axis": [2, -1]},
	"look_right":   {"pad_axis": [2, 1]},
	"look_up":      {"pad_axis": [3, -1]},
	"look_down":    {"pad_axis": [3, 1]},
	"thrust":       {"pad_axis": [5, 1],  "key": "Shift"},          # R2 analog boost / glide sprint (shutter in photo mode)
	"descend":      {"pad_axis": [4, 1],  "key": "C"},              # L2 analog dive / crouch
	"ascend":       {"pad_button": 0, "pad_button_alt": 9, "key": "Space"},   # Cross or L1 ascend; Cross jumps / breaches
	"observe":      {"pad_button": 1,     "mouse": 2},              # Circle: observation camera (photo mode)
	"interact":     {"pad_button": 2,     "key": "E"},              # Square
	"board":        {"pad_button": 3,     "key": "F"},              # Triangle: enter / exit sub, helm, moonpool, mount
	"sonar":        {"pad_button": 10,    "key": "R"},              # R1
	"sprint_toggle": {"pad_button": 7,    "key": "CapsLock"},       # L3 hands-free sprint latch
	"camera_view":  {"pad_button": 8,     "key": "V"},              # R3: third <-> first person
	"lights":       {"pad_button": 11,    "key": "L"},              # D-pad up
	"silent_mode":  {"pad_button": 12,    "key": "X"},              # D-pad down
	"companion":    {"pad_button": 13,    "key": "Q"},              # D-pad left: tap = Atlas ping, hold = Atlas orders
	"tars":         {"pad_button": 14,    "key": "T"},              # D-pad right: tap = TARS ping, hold = TARS orders
	"chart":        {"pad_button": 20,    "key": "M"},              # touch pad
	"pause":        {"pad_button": 6,     "key": "Escape"},         # Options
}

# Thalassa input.js tuning (PS5 DualSense curves)
const MOVE_DEADZONE := 0.11
const MOVE_EXPONENT := 1.45
const LOOK_SPEED := 2.40          # rad/s at full deflection
const LOOK_EXPONENT := 1.72
const LOOK_BOOST_MAX := 1.45      # outer-zone turn boost when the stick passes 0.82
const LOOK_ACCEL_HZ := 22.0
const LOOK_STOP_HZ := 34.0
const LOOK_PITCH_SCALE := 0.84
const HOLD_SEC := 0.24            # tap vs hold on D-pad left / right

# prompt glyph names per device family (UI renders these; text names follow each platform's own wording)
const GLYPHS := {
	"playstation": {0: "Cross", 1: "Circle", 2: "Square", 3: "Triangle", 6: "Options", 7: "L3", 8: "R3", 9: "L1", 10: "R1", 11: "D-pad up", 12: "D-pad down", 13: "D-pad left", 14: "D-pad right", 20: "touch pad", "axis4": "L2", "axis5": "R2"},
	"xbox":        {0: "A", 1: "B", 2: "X", 3: "Y", 6: "Menu", 7: "LS", 8: "RS", 9: "LB", 10: "RB", 11: "D-pad up", 12: "D-pad down", 13: "D-pad left", 14: "D-pad right", 20: "View", "axis4": "LT", "axis5": "RT"},
	"nintendo":    {0: "B", 1: "A", 2: "Y", 3: "X", 6: "+", 7: "LS", 8: "RS", 9: "L", 10: "R", 11: "Up", 12: "Down", 13: "Left", 14: "Right", 20: "Capture", "axis4": "ZL", "axis5": "ZR"},
}

## Device family from the controller name the platform reports.
static func family_from_name(joy_name: String) -> String:
	var n := joy_name.to_lower()
	if n.contains("dualsense") or n.contains("dualshock") or n.contains("ps4") or n.contains("ps5") or n.contains("playstation") or n.contains("sony"):
		return "playstation"
	if n.contains("nintendo") or n.contains("switch") or n.contains("joy-con"):
		return "nintendo"
	return "xbox"

## Glyph for an action on a family ("keyboard" returns the key or mouse name).
static func glyph(action: String, family: String, bindings: Dictionary = ACTIONS) -> String:
	var b: Dictionary = bindings[action]
	if family == "keyboard":
		if b.has("key"): return b.key
		if b.has("mouse"): return "Mouse %d" % b.mouse
		return ""
	var g: Dictionary = GLYPHS[family]
	if b.has("pad_button"): return g.get(b.pad_button, "?")
	if b.has("pad_axis"):
		var ax: int = b.pad_axis[0]
		if ax >= 4: return g["axis%d" % ax]
		return ["Left stick", "Left stick", "Right stick", "Right stick"][ax]
	return ""

## A binding table must never use a reserved system button and never bind one pad button to two actions.
static func validate(bindings: Dictionary) -> Array:
	var errs := []
	var used := {}
	for a in bindings:
		var b: Dictionary = bindings[a]
		for key in ["pad_button", "pad_button_alt"]:
			if not b.has(key): continue
			var btn: int = b[key]
			if RESERVED_PAD_BUTTONS.has(btn):
				errs.append("%s bound to reserved system button %d" % [a, btn])
			if used.has(btn):
				errs.append("pad button %d bound to %s and %s" % [btn, used[btn], a])
			used[btn] = a
	return errs
