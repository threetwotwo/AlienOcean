## Player UI 0.1.0 (adapters/godot/ui; "Port player UI and gamepad controls" thread, 28 Nov 2026): the gamepad-first layer
## over a GameRoot. Ports Thalassa v20.19's presentation layer (style/hud-overlay.js contextual prompt + button badges,
## runtime.js pause modal, toast, playHaptic call sites), upgraded where the port plan says so:
##   - prompts sit in Thalassa's bottom bar (Gary 28 Nov: clean main view, clearer interaction language); "world" places them beside the target
##   - the camera picks the target (core/m33_interact/interact_picker.gd), never a fixed priority list; no flicker (hysteresis)
##   - the pause menu is plain Godot controls with focus navigation, so D-pad / left stick / Cross-A / Circle-B work on every pad
##   - remapping goes through InputReader -> InputMap (system buttons refused, duplicates refused), saved to user://
##   - controller loss pauses the game and waits for an explicit Resume (platform rule; InputReader already holds input neutral)
## No jitter: the prompt anchor follows its target through a critically damped spring at frame rate; opacity only fades.
## Everything runs headless (tests/test_player_ui.gd drives it with injected events).
class_name PlayerUI
extends CanvasLayer

const Picker := preload("res://core/m33_interact/interact_picker.gd")
const Badge := preload("res://adapters/godot/ui/glyph_badge.gd")
const Table := preload("res://core/m01_input/action_table.gd")

signal interacted(id: String)
signal pause_changed(on: bool)

## actions shown on the Controls page (pad buttons only; sticks and triggers stay fixed in this slice)
const REMAPPABLE := ["ascend", "interact", "observe", "board", "sonar", "camera_view", "sprint_toggle", "lights", "silent_mode", "companion", "tars"]
const NAMES := {"ascend": "Rise / jump", "interact": "Interact", "observe": "Observe", "board": "Board / mount", "sonar": "Sonar",
	"camera_view": "First / third person", "sprint_toggle": "Sprint latch", "lights": "Lights", "silent_mode": "Silent mode",
	"companion": "Atlas", "tars": "Tug"}

var game                                  # GameRoot
var reader                                # adapters/godot/input_reader.gd
var targets_fn := Callable()              # () -> Array of picker targets
var test_tools := Callable()              # () -> void: opens the test level's debug panel (pause menu entry when set)
var report_fn := Callable()               # () -> void: saves an issue report (pause menu entry when set)
var on_pause := Callable()                # (on: bool) -> void: the level frees / recaptures the mouse
var prompt_style := "banner"              # Gary 28 Nov 08:04Z: "banner" (bottom bar, clean main view) | "world" (beside the target) | "glyph"
var picker = Picker.new()
var paused := false
var page := ""                            # "", "main", "options", "controls"
var status_text := ""                     # line under the pause title (controller loss, remap refusals)
var toast_text := ""
var toast_t := 9.0
var waiting_rebind := ""                  # action waiting for a pad button on the Controls page
var events: Array = []                    # log of UI events for tests: [kind, detail]

var _overlay: Control
var _menu: PanelContainer
var _pages := {}
var _status: Label
var _shown := {}                          # last target shown (kept while the prompt fades out)
var _anchor := Vector3.ZERO
var _anchor_v := Vector3.ZERO
var _anchor_set := false
var _hold_q := 0
var _last_mode := ""
var _last_cd := 0.0
var _resume_pending := false
var _k := 1.0                             # UI scale (viewport height / 1080)
var _theme: Theme

class Overlay extends Control:
	var ui
	func _draw() -> void: ui.draw_overlay(self)

func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay = Overlay.new(); _overlay.ui = self
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT); _overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	_build_menu()
	if reader != null:
		reader.load_remap()
		reader.controller_lost.connect(_on_controller_lost)
		reader.device_family_changed.connect(func(_f): _refresh_controls(); _overlay.queue_redraw())
	get_viewport().gui_focus_changed.connect(func(_c): if paused and reader != null: reader.rumble("menu_move"))

# ---------------------------------------------------------------- game tick: interact, camera view, rumble events

func _physics_process(dt: float) -> void:
	if game == null or not game.ready_done or paused: return
	var girl = game.girl
	var eye: Vector3 = girl.eye_point()
	var fwd: Vector3 = -game.cam.global_transform.basis.z if game.cam != null else Vector3.FORWARD
	var targets: Array = targets_fn.call() if targets_fn.is_valid() else []
	var held := Input.is_action_pressed("interact")
	var cur: Dictionary = picker.step(dt, targets, eye, fwd, held)
	if not cur.is_empty(): _shown = cur
	_focus_girl(girl, cur)
	var q := int(picker.progress * 4.0)
	if q > _hold_q and q < 4 and reader != null: reader.rumble("hold_tick")
	_hold_q = q
	if picker.completed_id != "":
		var was_hold: bool = _shown.get("hold", 0.0) > 0.0
		if reader != null: reader.rumble("sample_done" if was_hold else "interact")
		events.append(["interact", picker.completed_id])
		interacted.emit(picker.completed_id)
	# R3: first <-> third person (GameRoot keeps a chosen first-person view; any other shot hands back to the mode's own)
	if Input.is_action_just_pressed("camera_view") and game.cam != null:
		game.cam.shot = "swim" if game.cam.shot == "first_person" else "first_person"
		events.append(["camera_view", game.cam.shot])
	# rumble from the body: flipper-kick burst, leaving and entering the water
	var sw = girl.body.motor.swimmer
	if sw.sprint_burst_cd > _last_cd + 0.01 and reader != null: reader.rumble("boost"); events.append(["rumble", "boost"])
	_last_cd = sw.sprint_burst_cd
	var m: String = girl.mode_name()
	if reader != null and _last_mode != "":
		if m == "FALL" and (_last_mode == "SWIM" or _last_mode == "TREAD"): reader.rumble("breach"); events.append(["rumble", "breach"])
		elif (m == "SWIM" or m == "TREAD") and _last_mode == "FALL": reader.rumble("splash"); events.append(["rumble", "splash"])
	_last_mode = m

## Where the girl's attention should go: the offered target, or null.
func focus_point():
	return null if picker.current.is_empty() else picker.current.pos

## Push the offered target into her brain every tick it holds (body thread 28 Nov: core never calls the UI; a repeat call with the
## same label refreshes the target, and the brain releases the hold by itself hold_sec after the calls stop). Her eyes and head
## turn to it ahead of curiosity glances. ActorRig.engage_objective_focus (port of Thalassa CharacterBrain.engageObjectiveFocus).
func _focus_girl(girl, cur: Dictionary) -> void:
	if cur.is_empty(): return
	if girl.has_method("engage_objective_focus"): girl.engage_objective_focus("interact", cur.pos)

func toast(text: String, _sec := 2.6) -> void:
	toast_text = text; toast_t = 0.0

# ---------------------------------------------------------------- drawing (frame rate)

func _process(delta: float) -> void:
	_k = maxf(0.5, get_viewport().get_visible_rect().size.y / 1080.0)
	if _theme != null and absf(_theme.default_font_size - int(26 * _k)) > 1: _theme.default_font_size = int(26 * _k)
	toast_t += delta
	if _resume_pending and not Input.is_action_pressed("ui_accept") and not Input.is_action_pressed("ascend"):
		_resume_pending = false; set_paused(false)
	# anchor spring (critically damped, w = 14 rad/s): follows a target that moves at sim rate without stepping
	if not _shown.is_empty():
		var goal: Vector3 = _shown.pos
		var live: Array = targets_fn.call() if targets_fn.is_valid() and not paused else []
		for t in live:
			if t.id == _shown.id: goal = t.pos; break
		if not _anchor_set or _anchor.distance_to(goal) > 3.0: _anchor = goal; _anchor_v = Vector3.ZERO; _anchor_set = true
		var w := 14.0
		var h := minf(delta, 1.0 / 30.0)
		_anchor_v += ((goal - _anchor) * w * w - _anchor_v * 2.0 * w) * h
		_anchor += _anchor_v * h
	if picker.alpha <= 0.0 and picker.current.is_empty(): _shown = {}; _anchor_set = false
	_overlay.queue_redraw()

func draw_overlay(ci: Control) -> void:
	var vs := ci.get_viewport_rect().size
	var fam: String = reader.family if reader != null else "keyboard"
	var bind: Dictionary = reader.bindings if reader != null else Table.ACTIONS
	var font := ThemeDB.fallback_font
	var fs := int(24 * _k)
	var a: float = picker.alpha * (0.0 if paused else 1.0)
	if a > 0.01 and not _shown.is_empty():
		var s := 46.0 * _k
		var c := Vector2.ZERO
		var on := true
		if prompt_style == "banner":
			c = Vector2(vs.x * 0.5 - _text_w(font, _shown.verb, fs) * 0.5 - s * 0.4, vs.y * 0.86)
		else:
			var cam: Camera3D = game.cam if game != null else null
			var p := _anchor + Vector3(0, 0.22, 0)
			on = cam != null and not cam.is_position_behind(p)
			if on: c = cam.unproject_position(p)
			c += Vector2(0, -6.0 * _k * (1.0 - a))       # drifts up 6 px as it fades in (Thalassa translateY)
		if on:
			if prompt_style == "banner":
				var wbar := _text_w(font, _shown.verb, fs) + s * 2.2
				ci.draw_rect(Rect2(Vector2(vs.x * 0.5 - wbar * 0.5, c.y - s * 0.75), Vector2(wbar, s * 1.5)), Color(0.03, 0.07, 0.11, 0.55 * a))
			Badge.draw(ci, c, s, "interact", fam, bind, a)
			if picker.progress > 0.0:
				ci.draw_arc(c, s * 0.68, 0, TAU, 48, Color(0.0, 0.0, 0.0, 0.35 * a), maxf(3.0, 5.0 * _k), true)
				ci.draw_arc(c, s * 0.68, -PI * 0.5, -PI * 0.5 + TAU * picker.progress, 48, Color(0.9, 0.97, 1.0, 0.95 * a), maxf(3.0, 5.0 * _k), true)
			if prompt_style != "glyph":
				var tp := c + Vector2(s * 0.8, (font.get_ascent(fs) - font.get_descent(fs)) * 0.5)
				ci.draw_string(font, tp + Vector2(1, 1) * _k, _shown.verb, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.6 * a))
				ci.draw_string(font, tp, _shown.verb, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.93, 0.97, 1.0, a))
	# toast: fade in 0.3 s, hold, fade out by 2.6 s (Thalassa showToast)
	var ta := clampf(toast_t / 0.3, 0.0, 1.0) * (1.0 - clampf((toast_t - 2.0) / 0.6, 0.0, 1.0))
	if ta > 0.01 and toast_text != "" and not paused:
		var tw := _text_w(font, toast_text, fs)
		var tp2 := Vector2(vs.x * 0.5 - tw * 0.5, vs.y * 0.93)
		ci.draw_string(font, tp2 + Vector2(1, 1) * _k, toast_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.6 * ta))
		ci.draw_string(font, tp2, toast_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.93, 0.97, 1.0, ta))

static func _text_w(font: Font, t: String, fs: int) -> float:
	return font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x

# ---------------------------------------------------------------- pause menu

func _input(event: InputEvent) -> void:
	if waiting_rebind != "":
		if event is InputEventJoypadButton and event.pressed:
			if event.button_index == JOY_BUTTON_START:
				waiting_rebind = ""; status_text = "Remap cancelled"
			else:
				var err: String = reader.rebind_pad_button(waiting_rebind, event.button_index)
				status_text = ("Refused: " + err) if err != "" else "%s is now %s" % [NAMES[waiting_rebind], reader.glyph(waiting_rebind)]
				events.append(["rebind", waiting_rebind, event.button_index, err])
				waiting_rebind = ""
			_refresh_controls(); get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			waiting_rebind = ""; status_text = "Remap cancelled"; _refresh_controls(); get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause") and not event.is_echo():
		if paused and page != "main" and page != "": show_page("main")
		else: set_paused(not paused)
		get_viewport().set_input_as_handled()
	elif paused and event.is_action_pressed("ui_cancel") and not event.is_echo():
		if page == "main": request_resume()
		else: _leave_sub()
		get_viewport().set_input_as_handled()

func set_paused(on: bool) -> void:
	if on == paused: return
	paused = on
	if game != null and game.clock != null: game.clock.paused = on
	if reader != null:
		reader.look_filter.reset()
		if not on and reader.paused_by_disconnect: reader.resume_after_reconnect()
	if not on: status_text = ""; waiting_rebind = ""
	show_page("main" if on else "")
	if on_pause.is_valid(): on_pause.call(on)
	events.append(["pause", on])
	pause_changed.emit(on)

## Resume once the confirm button is let go, so the press that chose Resume never reaches the game as a jump.
func request_resume() -> void:
	_resume_pending = true
	if reader != null: reader.rumble("menu_confirm")

func show_page(p: String) -> void:
	page = p
	_menu.visible = p != ""
	for k in _pages: _pages[k].visible = k == p
	_status.text = status_text
	if p == "controls": _refresh_controls()
	if p == "options": _sync_options()
	if p != "":
		var first := _first_focus(_pages[p])
		if first != null: first.grab_focus()

func _leave_sub() -> void:
	if reader != null: reader.save_remap()
	show_page("main")

func _on_controller_lost(_device: int) -> void:
	status_text = "Controller disconnected. Reconnect it, then choose Resume."
	set_paused(true); _status.text = status_text

func _first_focus(n: Node) -> Control:
	for ch in n.get_children():
		if ch is Control and ch.focus_mode != Control.FOCUS_NONE and ch.visible: return ch
		var deeper := _first_focus(ch)
		if deeper != null: return deeper
	return null

var _opt := {}
var _ctl_buttons := {}

func _build_menu() -> void:
	_theme = Theme.new()
	_theme.default_font_size = 26
	var panel_sb := StyleBoxFlat.new(); panel_sb.bg_color = Color(0.02, 0.06, 0.10, 0.78)
	panel_sb.set_content_margin_all(28); panel_sb.set_corner_radius_all(6)
	_theme.set_stylebox("panel", "PanelContainer", panel_sb)
	var flat := StyleBoxFlat.new(); flat.bg_color = Color(1, 1, 1, 0.0); flat.set_content_margin_all(8)
	var focus := StyleBoxFlat.new(); focus.bg_color = Color(0.75, 0.9, 1.0, 0.14); focus.set_content_margin_all(8)
	focus.border_color = Color(0.85, 0.95, 1.0, 0.8); focus.set_border_width_all(0); focus.border_width_left = 3
	for st in ["normal", "pressed", "disabled"]: _theme.set_stylebox(st, "Button", flat)
	_theme.set_stylebox("hover", "Button", focus); _theme.set_stylebox("focus", "Button", focus)
	_theme.set_color("font_color", "Button", Color(0.85, 0.92, 0.98))
	_theme.set_color("font_focus_color", "Button", Color(1, 1, 1))
	_theme.set_color("font_hover_color", "Button", Color(1, 1, 1))
	_theme.set_color("font_color", "Label", Color(0.85, 0.92, 0.98))
	_menu = PanelContainer.new(); _menu.theme = _theme
	_menu.set_anchors_preset(Control.PRESET_CENTER)
	_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH; _menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	_menu.custom_minimum_size = Vector2(560, 0)
	_menu.visible = false
	add_child(_menu)
	var outer := VBoxContainer.new(); outer.add_theme_constant_override("separation", 10); _menu.add_child(outer)
	var title := Label.new(); title.text = "Paused"; title.add_theme_font_size_override("font_size", 40); outer.add_child(title)
	_status = Label.new(); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; _status.custom_minimum_size = Vector2(500, 0)
	_status.add_theme_color_override("font_color", Color(1.0, 0.85, 0.6)); outer.add_child(_status)
	# main
	var main := VBoxContainer.new(); outer.add_child(main); _pages["main"] = main
	_button(main, "Resume", request_resume)
	_button(main, "Options", func(): show_page("options"))
	_button(main, "Controls", func(): show_page("controls"))
	var tt := _button(main, "Test tools", func(): set_paused(false); test_tools.call())
	tt.set_meta("needs", "test_tools")
	var rp := _button(main, "Save issue report", func(): report_fn.call(); status_text = "Report saved"; _status.text = status_text)
	rp.set_meta("needs", "report_fn")
	_button(main, "Quit game", func(): get_tree().quit())
	# options
	var opt := VBoxContainer.new(); outer.add_child(opt); _pages["options"] = opt
	_opt.look = _slider(opt, "Look speed", 0.3, 2.0, 0.05, func(v): reader.look_sensitivity = v)
	_opt.invert = _check(opt, "Invert look up / down", func(on): reader.invert_y = on)
	_opt.vib = _check(opt, "Vibration", func(on): reader.haptics.enabled = on; reader.rumble("menu_confirm"))
	_opt.vib_k = _slider(opt, "Vibration strength", 0.0, 1.0, 0.05, func(v): reader.haptics.strength = v)
	_button(opt, "Back", _leave_sub)
	# controls
	var ctl := VBoxContainer.new(); outer.add_child(ctl); _pages["controls"] = ctl
	var hint := Label.new(); hint.text = "Choose an action, then press the pad button you want. Options cancels."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; hint.add_theme_font_size_override("font_size", 18); ctl.add_child(hint)
	var grid := GridContainer.new(); grid.columns = 2; grid.add_theme_constant_override("h_separation", 24); ctl.add_child(grid)
	for a in REMAPPABLE:
		_ctl_buttons[a] = _button(grid, NAMES[a], func(): waiting_rebind = a; status_text = "Press a pad button for %s" % NAMES[a]; _refresh_controls())
	_button(ctl, "Reset to defaults", func(): reader.reset_bindings(); status_text = "Controls reset"; _refresh_controls())
	_button(ctl, "Back", _leave_sub)
	for k in _pages: _pages[k].visible = false

func _button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new(); b.text = text; b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(func(): events.append(["button", text]); cb.call())
	parent.add_child(b)
	return b

func _slider(parent: Node, text: String, lo: float, hi: float, st: float, cb: Callable) -> HSlider:
	var row := HBoxContainer.new(); parent.add_child(row)
	var l := Label.new(); l.text = text; l.custom_minimum_size = Vector2(260, 0); row.add_child(l)
	var s := HSlider.new(); s.min_value = lo; s.max_value = hi; s.step = st; s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.focus_mode = Control.FOCUS_ALL
	s.value_changed.connect(func(v): cb.call(v))
	row.add_child(s)
	return s

func _check(parent: Node, text: String, cb: Callable) -> CheckButton:
	var c := CheckButton.new(); c.text = text
	c.toggled.connect(func(on): cb.call(on))
	parent.add_child(c)
	return c

func _sync_options() -> void:
	if reader == null: return
	_opt.look.set_value_no_signal(reader.look_sensitivity)
	_opt.invert.set_pressed_no_signal(reader.invert_y)
	_opt.vib.set_pressed_no_signal(reader.haptics.enabled)
	_opt.vib_k.set_value_no_signal(reader.haptics.strength)

func _refresh_controls() -> void:
	if reader == null: return
	for a in _ctl_buttons:
		var g: String = "press a button..." if waiting_rebind == a else reader.glyph(a)
		_ctl_buttons[a].text = "%s    %s" % [NAMES[a], g]
	for b in _pages["main"].get_children():
		if b.has_meta("needs"): b.visible = (test_tools if b.get_meta("needs") == "test_tools" else report_fn).is_valid()
	if _status != null: _status.text = status_text
