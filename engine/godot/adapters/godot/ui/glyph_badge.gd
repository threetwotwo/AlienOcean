## UI glyph badge 0.1.0: draws the button badge for an action on the current device family. Port of Thalassa v20.19
## style/hud-overlay.js buildButtonBadgeSVG() (dark cap, coloured ring, PlayStation shapes in their own colours, keycaps for
## keyboard), drawn with CanvasItem primitives so it stays sharp at any screen size and needs no texture files.
## Xbox and Nintendo get letter caps in their own colours. Thalassa's colours kept as is.
extends RefCounted

const Table := preload("res://core/m01_input/action_table.gd")
const CAP := Color("#121c28")
const PS := {0: Color("#8cbeff"), 1: Color("#ff7c78"), 2: Color("#f598dc"), 3: Color("#58f2c8")}   # Cross Circle Square Triangle
const XBOX := {0: Color("#6cc24a"), 1: Color("#e8574f"), 2: Color("#4f8fe8"), 3: Color("#f2c744")} # A B X Y
const RING := Color(0.855, 0.94, 0.99, 0.55)

## Draw the badge for `action` centred at c with diameter s (pixels). a = opacity.
static func draw(ci: CanvasItem, c: Vector2, s: float, action: String, family: String, bindings: Dictionary, a := 1.0) -> void:
	var b: Dictionary = bindings.get(action, {})
	var r := s * 0.45
	var font := ThemeDB.fallback_font
	if family == "keyboard":
		var txt := Table.glyph(action, "keyboard", bindings)
		var fs := int(s * (0.42 if txt.length() <= 2 else 0.30))
		var w := maxf(s * 0.9, font.get_string_size(txt, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x + s * 0.4)
		var rect := Rect2(c - Vector2(w, s * 0.9) * 0.5, Vector2(w, s * 0.9))
		ci.draw_rect(rect, Color(CAP, 0.92 * a))
		ci.draw_rect(rect, Color(RING, RING.a * a), false, maxf(1.0, s * 0.05))
		_text(ci, font, txt, c, fs, Color(0.92, 0.97, 1.0, a))
		return
	var btn: int = b.get("pad_button", -1)
	ci.draw_circle(c, r, Color(CAP, 0.92 * a))
	var ring := RING
	var lw := maxf(1.5, s * 0.075)
	if family == "playstation" and PS.has(btn):
		var col: Color = PS[btn]
		ci.draw_arc(c, r, 0, TAU, 40, Color(col, a), maxf(1.0, s * 0.06), true)
		match btn:
			0:
				var d := s * 0.20
				ci.draw_line(c + Vector2(-d, -d), c + Vector2(d, d), Color(col, a), lw, true)
				ci.draw_line(c + Vector2(d, -d), c + Vector2(-d, d), Color(col, a), lw, true)
			1: ci.draw_arc(c, s * 0.23, 0, TAU, 32, Color(col, a), lw, true)
			2:
				var h := s * 0.21
				ci.draw_rect(Rect2(c - Vector2(h, h), Vector2(h, h) * 2.0), Color(col, a), false, lw)
			3:
				var pts := PackedVector2Array([c + Vector2(0, -s * 0.26), c + Vector2(s * 0.25, s * 0.19), c + Vector2(-s * 0.25, s * 0.19), c + Vector2(0, -s * 0.26)])
				ci.draw_polyline(pts, Color(col, a), lw, true)
		return
	if family == "xbox" and XBOX.has(btn):
		ring = XBOX[btn]
	ci.draw_arc(c, r, 0, TAU, 40, Color(ring, ring.a * a if ring == RING else a), maxf(1.0, s * 0.06), true)
	var label := Table.glyph(action, family, bindings)
	label = _short(label)
	var col2: Color = XBOX.get(btn, Color(0.92, 0.97, 1.0)) if family == "xbox" else Color(0.92, 0.97, 1.0)
	_text(ci, font, label, c, int(s * (0.46 if label.length() <= 1 else 0.30)), Color(col2, a))

static func _short(label: String) -> String:
	match label:
		"D-pad up", "Up": return "↑"
		"D-pad down", "Down": return "↓"
		"D-pad left", "Left": return "←"
		"D-pad right", "Right": return "→"
		"Left stick": return "LS"
		"Right stick": return "RS"
		"touch pad": return "TP"
	return label

static func _text(ci: CanvasItem, font: Font, txt: String, c: Vector2, fs: int, col: Color) -> void:
	var sz := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var asc := font.get_ascent(fs)
	var desc := font.get_descent(fs)
	ci.draw_string(font, Vector2(c.x - sz.x * 0.5, c.y + (asc - desc) * 0.5), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
