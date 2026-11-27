## M01 input: headless test with injected device events.
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/test_input.gd
## Planted fault: a table binding "companion" to the Create button must be refused by validate().
extends SceneTree

const Reader := preload("res://adapters/godot/input_reader.gd")
const Table := preload("res://core/m01_input/action_table.gd")
const Packet := preload("res://core/m01_input/input_packet.gd")

var r
var step := 0
var fails := []
var passes := 0
var family_signals := []
var held_ticks := 0
var jump_ticks := 0

func ok(cond: bool, name: String) -> void:
	if cond: passes += 1; print("PASS  ", name)
	else: fails.append(name); print("FAIL  ", name)

func _initialize() -> void:
	r = Reader.new()
	r.remap_path = "user://test_input_remap.cfg"
	root.add_child(r)
	r.device_family_changed.connect(func(f): family_signals.append(f))

func joy_axis(axis: int, v: float) -> void:
	var e := InputEventJoypadMotion.new(); e.device = 0; e.axis = axis; e.axis_value = v
	Input.parse_input_event(e); r.note_event(e)

func joy_button(b: int, down: bool) -> void:
	var e := InputEventJoypadButton.new(); e.device = 0; e.button_index = b; e.pressed = down
	Input.parse_input_event(e); r.note_event(e)

func key(code: Key, down: bool) -> void:
	var e := InputEventKey.new(); e.physical_keycode = code; e.keycode = code; e.pressed = down
	Input.parse_input_event(e); r.note_event(e)

func _physics_process(_d: float) -> bool:
	step += 1
	match step:
		2:
			ok(Table.validate(Table.ACTIONS).is_empty(), "default table valid, no system button bound")
			var bad := Table.ACTIONS.duplicate(true); bad["companion"] = {"pad_button": 4}
			ok(not Table.validate(bad).is_empty(), "planted fault: Create button binding refused")
			joy_axis(0, 0.5)
		4:
			var p = r.read()
			ok(absf(p.move.x - Packet.shape_stick(Vector2(0.5, 0)).x) < 0.02 and p.move.x > 0.0, "left stick 0.5 -> shaped move x %.3f" % p.move.x)
			ok(r.family != "keyboard", "pad input switches glyph family to pad (%s)" % r.family)
			joy_axis(0, 0.1)
		6:
			ok(r.read().move == Vector2.ZERO, "stick 0.1 inside deadzone -> zero")
			joy_axis(0, 0.0)
			joy_button(0, true)
		7, 8, 9:
			var p = r.read()
			if p.ascend: held_ticks += 1
			if p.jump_pressed: jump_ticks += 1
		10:
			ok(held_ticks == 3 and jump_ticks == 1, "Cross held 3 ticks = ascend 3, jump_pressed exactly once (%d/%d)" % [held_ticks, jump_ticks])
			joy_button(0, false)
			key(KEY_W, true)
		12:
			ok(r.family == "keyboard" and family_signals.has("keyboard"), "keyboard input swaps glyphs back to keyboard")
			ok(r.read().move.y > 0.9, "W moves forward")
			key(KEY_W, false)
			ok(Table.glyph("ascend", "playstation") == "Cross" and Table.glyph("ascend", "xbox") == "A" and Table.glyph("thrust", "playstation") == "R2" and Table.glyph("descend", "playstation") == "L2" and Table.glyph("tars", "playstation") == "D-pad right", "glyph names per platform")
			ok(r.rebind_pad_button("interact", 4) != "", "remap to Create refused")
			ok(r.rebind_pad_button("interact", 3) != "", "remap onto a taken button refused")
			ok(r.rebind_pad_button("interact", 15) == "", "remap interact to a free button (15) accepted")
			r.save_remap()
			r.bindings = Table.ACTIONS.duplicate(true); r.install()
			r.load_remap()
			ok(r.bindings["interact"].get("pad_button", -1) == 15, "remap survives save and reload")
			joy_button(15, true)
		14:
			ok(r.read().interact_pressed or Input.is_action_pressed("interact"), "remapped button drives interact")
			joy_button(15, false)
			# controller loss mid-input: stick held, then the pad disconnects
			joy_axis(1, -1.0)
			r._on_joy_connection(0, false)
		16:
			var p = r.read()
			ok(r.paused_by_disconnect and p.move == Vector2.ZERO, "controller lost: paused, neutral packet (no stuck input)")
			r.resume_after_reconnect()
			joy_axis(1, 0.0)
		18:
			ok(not r.paused_by_disconnect and r.read().move == Vector2.ZERO, "resume after reconnect, stick released")
			DirAccess.remove_absolute(ProjectSettings.globalize_path(r.remap_path))
			print("M01 input: %d/%d PASS" % [passes, passes + fails.size()])
			quit(0 if fails.is_empty() else 1)
	return false
