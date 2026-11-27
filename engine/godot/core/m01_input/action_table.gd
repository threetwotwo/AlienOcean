## M01 Input, action table 0.1.0 (data, engine-agnostic): every game action and its default bindings.
## Pad entries use SDL/Godot standard indices (buttons: 0 Cross/A, 1 Circle/B, 2 Square/X, 3 Triangle/Y, 4 Create/Back,
## 5 PS/Guide, 6 Options/Start, 7 L3, 8 R3, 9 L1, 10 R1, 11-14 D-pad up/down/left/right, 20 touch pad;
## axes: 0/1 left stick, 2/3 right stick, 4 L2, 5 R2). Create (4) and PS (5) belong to the system and are never bound.
extends RefCounted

const RESERVED_PAD_BUTTONS := [4, 5]

# action: {pad_button | pad_axis [axis, sign], key, mouse}
const ACTIONS := {
	"move_left":    {"pad_axis": [0, -1], "key": "A"},
	"move_right":   {"pad_axis": [0, 1],  "key": "D"},
	"move_forward": {"pad_axis": [1, -1], "key": "W"},
	"move_back":    {"pad_axis": [1, 1],  "key": "S"},
	"look_left":    {"pad_axis": [2, -1]},
	"look_right":   {"pad_axis": [2, 1]},
	"look_up":      {"pad_axis": [3, -1]},
	"look_down":    {"pad_axis": [3, 1]},
	"thrust":       {"pad_axis": [5, 1],  "key": "Shift"},
	"observe":      {"pad_axis": [4, 1],  "mouse": 2},
	"ascend":       {"pad_button": 0,     "key": "Space"},
	"descend":      {"pad_button": 1,     "key": "C"},
	"interact":     {"pad_button": 2,     "key": "E"},
	"atlas":        {"pad_button": 3,     "key": "Tab"},
	"companion":    {"pad_button": 9,     "key": "Q"},
	"capture":      {"pad_button": 10,    "mouse": 1},
	"camera_view":  {"pad_button": 8,     "key": "V"},
	"chart":        {"pad_button": 20,    "key": "M"},
	"pause":        {"pad_button": 6,     "key": "Escape"},
}

# prompt glyph names per device family (UI renders these; text names follow each platform's own wording)
const GLYPHS := {
	"playstation": {0: "Cross", 1: "Circle", 2: "Square", 3: "Triangle", 6: "Options", 8: "R3", 9: "L1", 10: "R1", 20: "touch pad", "axis4": "L2", "axis5": "R2"},
	"xbox":        {0: "A", 1: "B", 2: "X", 3: "Y", 6: "Menu", 8: "RS", 9: "LB", 10: "RB", 20: "View", "axis4": "LT", "axis5": "RT"},
	"nintendo":    {0: "B", 1: "A", 2: "Y", 3: "X", 6: "+", 8: "RS", 9: "L", 10: "R", 20: "Capture", "axis4": "ZL", "axis5": "ZR"},
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
		if b.has("pad_button"):
			if RESERVED_PAD_BUTTONS.has(b.pad_button):
				errs.append("%s bound to reserved system button %d" % [a, b.pad_button])
			if used.has(b.pad_button):
				errs.append("pad button %d bound to %s and %s" % [b.pad_button, used[b.pad_button], a])
			used[b.pad_button] = a
	return errs
