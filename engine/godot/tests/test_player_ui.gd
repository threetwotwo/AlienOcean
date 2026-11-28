## Player UI 0.1.0 checks (headless; "Port player UI and gamepad controls" thread). Builds the real test level, then drives the
## pad with injected events. Pass checks written before the build:
##   U1 picker: a target is offered only in range and in view; it never flickers when two targets score within the margin
##      (0 switches over 600 ticks of an oscillating eye) and is kept until it leaves 1.25x its range
##   U2 hold: a 0.8 s hold completes once (not again while still held), releasing early completes nothing
##   U3 haptics: pad only, 42 ms minimum gap, switch and strength respected, every event inside 20-420 ms
##   U4 pause: Options pauses (clock stops: the girl does not move), the menu takes focus, D-pad down moves focus,
##      Circle/B backs out of a page, Resume waits for the confirm button's release (no jump on resume)
##   U5 remap from the menu: Controls page refuses the Create button, accepts a free button, the new button drives interact
##   U6 controller loss pauses with the reconnect line; resume clears the disconnect hold
##   U7 in the level: swimming into a school offers "Sample DNA", holding Square takes a sample (toast + rumble event logged)
##   U8 glyphs: every remappable action has a non-empty glyph on playstation, xbox, nintendo and keyboard
## Planted faults (--fault): "flicker" (no switch margin) must fail U1; "nolatch" (hold repeats) must fail U2.
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/test_player_ui.gd [-- --fault flicker|nolatch]
extends SceneTree

const Picker := preload("res://core/m33_interact/interact_picker.gd")
const Haptics := preload("res://core/m01_input/haptics.gd")
const Badge := preload("res://adapters/godot/ui/glyph_badge.gd")
const Table := preload("res://core/m01_input/action_table.gd")

var fails := []
var passes := 0
var fault := ""
var lvl

func ok(cond: bool, name: String, detail = "") -> void:
	if cond: passes += 1; print("PASS  ", name, "  ", detail)
	else: fails.append(name); print("FAIL  ", name, "  ", detail)

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--fault")
	if i >= 0 and i + 1 < args.size(): fault = args[i + 1]
	_run.call_deferred()

func pad_button(b: int, down: bool) -> void:
	var e := InputEventJoypadButton.new(); e.device = 0; e.button_index = b; e.pressed = down
	Input.parse_input_event(e)

func ticks(n: int) -> void:
	for k in n: await physics_frame

func _run() -> void:
	_unit_picker()
	_unit_hold()
	_unit_haptics()
	_unit_glyphs()
	lvl = TestLevel.new(); root.add_child(lvl)
	while not lvl.ready_done: await process_frame
	await ticks(30)
	var ui: PlayerUI = lvl.ui
	ok(ui != null and ui.reader != null, "U0 player UI mounted in the test level")
	await _pause_checks(ui)
	await _remap_checks(ui)
	await _loss_checks(ui)
	await _sample_checks(ui)
	print("PLAYER UI: %d/%d PASS%s" % [passes, passes + fails.size(), "" if fails.is_empty() else "  FAILED: " + ", ".join(fails)])
	quit(0 if fails.is_empty() else 1)

func _unit_picker() -> void:
	var p = Picker.new()
	var a := {"id": "a", "pos": Vector3(-0.3, 0, -2.0), "verb": "A", "range": 3.0}
	var b := {"id": "b", "pos": Vector3(0.3, 0, -2.0), "verb": "B", "range": 3.0}
	var far := {"id": "far", "pos": Vector3(0, 0, -9.0), "verb": "F", "range": 3.0}
	var behind := {"id": "behind", "pos": Vector3(0, 0, 1.0), "verb": "H", "range": 3.0}
	ok(p.step(1.0 / 60, [far, behind], Vector3.ZERO, Vector3.FORWARD, false).is_empty(), "U1a nothing offered out of range or behind")
	var switches := 0
	var last := ""
	for k in 600:
		var x := sin(k * 0.21) * 0.05                    # the eye sways across the midline between a and b
		var cur: Dictionary
		if fault == "flicker":
			# planted fault: no hysteresis, pick the best every tick
			var bs := -1.0
			for t in [a, b]:
				var s := Picker.score(t, Vector3(x, 0, 0), Vector3.FORWARD)
				if s > bs: bs = s; cur = t
		else:
			cur = p.step(1.0 / 60, [a, b], Vector3(x, 0, 0), Vector3.FORWARD, false)
		if not cur.is_empty() and cur.id != last and last != "": switches += 1
		if not cur.is_empty(): last = cur.id
	ok(switches == 0, "U1b no flicker between two near-equal targets", "switches %d" % switches)
	p.reset()
	p.step(1.0 / 60, [a], Vector3.ZERO, Vector3.FORWARD, false)
	var kept := not p.step(1.0 / 60, [a], Vector3(0, 0, 1.2), Vector3.FORWARD, false).is_empty()   # 3.2 m: past 1.0x, inside 1.25x
	var dropped := p.step(1.0 / 60, [a], Vector3(0, 0, 2.0), Vector3.FORWARD, false).is_empty()   # 4.0 m: past 1.25x
	ok(kept and dropped, "U1c kept to 1.25x its range, dropped beyond", "kept %s dropped %s" % [kept, dropped])

func _unit_hold() -> void:
	var p = Picker.new()
	var t := {"id": "fish", "pos": Vector3(0, 0, -1.5), "verb": "Sample", "range": 3.0, "hold": 0.8}
	var done := 0
	for k in 120:                                     # 2 s held
		p.step(1.0 / 60, [t], Vector3.ZERO, Vector3.FORWARD, true)
		if p.completed_id != "": done += 1
		if fault == "nolatch" and p.completed_id != "": p._latched = false
	ok(done == 1, "U2a a 0.8 s hold completes once while held 2 s", "completions %d" % done)
	p.reset(); done = 0
	for k in 30: p.step(1.0 / 60, [t], Vector3.ZERO, Vector3.FORWARD, true); done += int(p.completed_id != "")
	for k in 60: p.step(1.0 / 60, [t], Vector3.ZERO, Vector3.FORWARD, false); done += int(p.completed_id != "")
	ok(done == 0 and p.progress == 0.0, "U2b releasing at 0.5 s completes nothing and drains", "completions %d progress %.2f" % [done, p.progress])

func _unit_haptics() -> void:
	var h = Haptics.new()
	ok(h.pulse("interact", 0.0, false).is_empty(), "U3a no rumble while keyboard is the device")
	var a: Dictionary = h.pulse("interact", 1000.0, true)
	var b: Dictionary = h.pulse("interact", 1020.0, true)
	var c: Dictionary = h.pulse("interact", 1050.0, true)
	ok(not a.is_empty() and b.is_empty() and not c.is_empty(), "U3b 42 ms minimum gap")
	h.enabled = false
	var off: Dictionary = h.pulse("interact", 5000.0, true)
	h.enabled = true; h.strength = 0.5
	var half: Dictionary = h.pulse("sample_done", 9000.0, true)
	ok(off.is_empty() and absf(half.strong - 0.20) < 1e-6, "U3c switch and strength respected", str(half))
	var bad := []
	for e in Haptics.EVENTS:
		var v: Array = Haptics.EVENTS[e]
		if v[2] < 20 or v[2] > 420 or v[0] > 1.0 or v[1] > 1.0: bad.append(e)
	ok(bad.is_empty(), "U3d every event inside 20-420 ms and 0..1", str(bad))

func _unit_glyphs() -> void:
	var missing := []
	for fam in ["playstation", "xbox", "nintendo", "keyboard"]:
		for a in PlayerUI.REMAPPABLE + ["interact", "pause"]:
			if Table.glyph(a, fam).is_empty() or Table.glyph(a, fam) == "?": missing.append("%s/%s" % [fam, a])
	ok(missing.is_empty(), "U8 every action has a glyph on every family", str(missing))

func _pause_checks(ui: PlayerUI) -> void:
	var feet0: Vector3 = lvl.game.girl.body.global_position
	pad_button(JOY_BUTTON_START, true); await ticks(2); pad_button(JOY_BUTTON_START, false); await ticks(2)
	ok(ui.paused and lvl.game.clock.paused and ui.page == "main", "U4a Options pauses and opens the menu")
	var f0 = root.get_viewport().gui_get_focus_owner()
	pad_button(JOY_BUTTON_DPAD_DOWN, true); await ticks(2); pad_button(JOY_BUTTON_DPAD_DOWN, false); await ticks(2)
	var f1 = root.get_viewport().gui_get_focus_owner()
	ok(f0 != null and f1 != null and f0 != f1, "U4b menu has focus and D-pad down moves it", "%s -> %s" % [f0.text if f0 else "none", f1.text if f1 else "none"])
	# Options page, then Circle backs out
	ui.show_page("options"); await ticks(2)
	pad_button(JOY_BUTTON_B, true); await ticks(2); pad_button(JOY_BUTTON_B, false); await ticks(2)
	ok(ui.page == "main", "U4c Circle / B backs out of a page", ui.page)
	await ticks(60)
	var moved: float = lvl.game.girl.body.global_position.distance_to(feet0)
	ok(moved < 0.05, "U4d the world holds while paused (girl moved %.3f m)" % moved)
	# Resume: press Cross on "Resume" (focus back to the first button), keep it held: the game stays paused until release
	ui.show_page("main"); await ticks(2)
	pad_button(JOY_BUTTON_A, true); await ticks(6)
	var still: bool = ui.paused
	pad_button(JOY_BUTTON_A, false); await ticks(4)
	ok(still and not ui.paused and not lvl.game.clock.paused, "U4e Resume waits for Cross to be let go", "held-paused %s now-paused %s" % [still, ui.paused])

func _remap_checks(ui: PlayerUI) -> void:
	ui.set_paused(true); ui.show_page("controls"); await ticks(2)
	ui.waiting_rebind = "interact"
	pad_button(JOY_BUTTON_BACK, true); await ticks(2); pad_button(JOY_BUTTON_BACK, false); await ticks(2)
	var refused: bool = ui.status_text.begins_with("Refused") and ui.reader.bindings.interact.pad_button == 2
	ui.waiting_rebind = "interact"
	pad_button(15, true); await ticks(2); pad_button(15, false); await ticks(2)
	var took: bool = ui.reader.bindings.interact.pad_button == 15
	ok(refused and took, "U5a Controls page refuses Create, accepts a free button", ui.status_text)
	ui.set_paused(false); await ticks(2)
	pad_button(15, true); await ticks(2)
	var drives := Input.is_action_pressed("interact")
	pad_button(15, false); await ticks(2)
	ok(drives, "U5b the new button drives interact")
	ui.reader.reset_bindings(); ui.reader.save_remap()

func _loss_checks(ui: PlayerUI) -> void:
	ui.reader.family = "xbox"
	ui.reader._on_joy_connection(0, false); await ticks(2)
	ok(ui.paused and ui.status_text.begins_with("Controller disconnected") and ui.reader.paused_by_disconnect, "U6a controller loss pauses with the reconnect line")
	ui.set_paused(false); await ticks(2)
	ok(not ui.reader.paused_by_disconnect and not ui.paused, "U6b Resume clears the disconnect hold")

func _sample_checks(ui: PlayerUI) -> void:
	# put the girl beside school 0's nearest fish, camera looking at it
	var tg: Array = lvl.interact_targets()
	ok(not tg.is_empty(), "U7a the level lists the schools as targets", str(tg.size()))
	if tg.is_empty(): return
	var fish: Vector3 = tg[0].pos
	var g = lvl.game.girl
	var cam: Camera3D = lvl.game.cam
	var offered := false
	for k in 90:
		tg = lvl.interact_targets(); fish = tg[0].pos
		var eye: Vector3 = g.eye_point()
		var to := fish - eye
		if to.length() > 1.2:
			g.body.global_position += to.normalized() * minf(to.length() - 1.2, 0.08)
			g.body.motor.swimmer.pos = g.body.global_position
		var dir := (fish - cam.global_position).normalized()
		cam.yaw = atan2(-dir.x, -dir.z); cam.pitch = asin(clampf(dir.y, -1, 1))
		await physics_frame
		if not ui.picker.current.is_empty(): offered = true; break
	ok(offered and ui.picker.current.get("verb", "") == "Sample DNA", "U7b swimming to a school offers Sample DNA", str(ui.picker.current.get("id", "none")))
	ui.reader.family = "playstation"; ui.reader.last_pad = 0; ui.reader.haptics._last_ms = -1e9
	var n0 := ui.events.size()
	pad_button(JOY_BUTTON_X, true)                       # Square
	var done := false
	for k in 90:
		tg = lvl.interact_targets()
		var dir: Vector3 = (tg[0].pos - cam.global_position).normalized()
		cam.yaw = atan2(-dir.x, -dir.z); cam.pitch = asin(clampf(dir.y, -1, 1))
		await physics_frame
		if lvl.samples.size() > 0: done = true; break
	pad_button(JOY_BUTTON_X, false); await ticks(2)
	var rumbled: bool = ui.reader.rumbles.any(func(r): return r[0] == "sample_done")
	ok(done and ui.toast_text.begins_with("Trevally sample") and rumbled, "U7c holding Square takes a sample (toast + rumble)", "%s | %s" % [ui.toast_text, ui.events.slice(n0)])
