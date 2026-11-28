## DebugPanel 0.1.0 (test level thread, 28 Nov 2026): the on-screen view of a TestLevel. Always shows a small read-out
## (fps, frame ms, worst frame); F1 (or Options on the pad) opens the full panel: frame timings, switches, sea state, hour,
## day speed, teleports, and the issue report (type a note, then F8 or the Report button). Plain Godot controls, no theme.
## Everything it changes goes through TestLevel's setters (the same ones the test checks).
extends CanvasLayer

var level: TestLevel
var hud: Label
var panel: PanelContainer
var stats_label: Label
var checks := {}
var sea_opt: OptionButton
var day_opt: OptionButton
var hour_slider: HSlider
var hour_label: Label
var note_edit: LineEdit
var status: Label
var _t := 0.0

func _ready() -> void:
	layer = 50
	hud = Label.new(); hud.position = Vector2(12, 8); _shadow(hud); add_child(hud)
	panel = PanelContainer.new(); panel.position = Vector2(12, 40); panel.visible = false; add_child(panel)
	var sc := ScrollContainer.new(); sc.custom_minimum_size = Vector2(430, 640); panel.add_child(sc)
	var v := VBoxContainer.new(); v.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(v)
	_title(v, "Test level  (F1 hide, F8 report, click to look with the mouse, Esc frees it)")
	stats_label = Label.new(); stats_label.add_theme_font_size_override("font_size", 13); v.add_child(stats_label)
	_title(v, "Switches")
	var grid := GridContainer.new(); grid.columns = 3; v.add_child(grid)
	for n in level.toggle_names():
		var c := CheckBox.new(); c.text = n.replace("_", " "); c.button_pressed = level.get_toggle(n)
		c.toggled.connect(func(on): level.set_toggle(n, on)); grid.add_child(c); checks[n] = c
	_title(v, "Sea state (force 8+ over the 4 m lagoon is a stress test)")
	sea_opt = OptionButton.new()
	for s in TestLevel.SEA_STATES: sea_opt.add_item(s if s == "lagoon" else "Beaufort " + s.substr(1))
	sea_opt.item_selected.connect(func(i): level.set_sea_state(TestLevel.SEA_STATES[i])); v.add_child(sea_opt)
	_title(v, "Time of day")
	var hr := HBoxContainer.new(); v.add_child(hr)
	hour_slider = HSlider.new(); hour_slider.min_value = 0; hour_slider.max_value = 24; hour_slider.step = 0.05
	hour_slider.custom_minimum_size = Vector2(300, 24); hour_slider.value = level.get_hour()
	hour_slider.value_changed.connect(func(h): level.set_hour(h)); hr.add_child(hour_slider)
	hour_label = Label.new(); hr.add_child(hour_label)
	var hb := HBoxContainer.new(); v.add_child(hb)
	for pr in [["Dawn", 6.0], ["Noon", 12.0], ["Dusk", 18.3], ["Night", 23.0]]:
		var b := Button.new(); b.text = pr[0]; b.pressed.connect(func(): level.set_hour(pr[1]); hour_slider.set_value_no_signal(pr[1])); hb.add_child(b)
	day_opt = OptionButton.new()
	for k in TestLevel.DAY_SPEEDS: day_opt.add_item(k)
	day_opt.item_selected.connect(func(i): level.set_day_speed(TestLevel.DAY_SPEEDS.keys()[i])); v.add_child(day_opt)
	_title(v, "Teleport")
	var tg := GridContainer.new(); tg.columns = 2; v.add_child(tg)
	for i in level.teleports.size():
		var b := Button.new(); b.text = "%d  %s" % [i + 1, level.teleports[i].name]; b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func(): level.teleport(i)); tg.add_child(b)
	_title(v, "Report an issue")
	note_edit = LineEdit.new(); note_edit.placeholder_text = "What looks or feels wrong? (optional)"; v.add_child(note_edit)
	var rb := Button.new(); rb.text = "Save report (F8)"; rb.pressed.connect(report); v.add_child(rb)
	status = Label.new(); status.autowrap_mode = TextServer.AUTOWRAP_WORD; status.custom_minimum_size = Vector2(400, 0); v.add_child(status)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

func _title(v: VBoxContainer, s: String) -> void:
	var l := Label.new(); l.text = s; l.add_theme_font_size_override("font_size", 15); l.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	v.add_child(l)

func _shadow(l: Label) -> void:
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9)); l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1: set_open(not panel.visible); get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F8: report(); get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and level.mouse_captured: level.set_mouse_captured(false); get_viewport().set_input_as_handled()
		elif panel.visible and not note_edit.has_focus() and event.keycode >= KEY_1 and event.keycode <= KEY_9:
			var i: int = event.keycode - KEY_1
			if i < level.teleports.size(): level.teleport(i)
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START:
		set_open(not panel.visible)

func set_open(on: bool) -> void:
	panel.visible = on
	if on: level.set_mouse_captured(false); _sync()

func _sync() -> void:
	for n in checks: checks[n].set_pressed_no_signal(level.get_toggle(n))
	sea_opt.select(TestLevel.SEA_STATES.find(level.sea_state))
	day_opt.select(TestLevel.DAY_SPEEDS.keys().find(level.day_speed))
	hour_slider.set_value_no_signal(level.get_hour())

func report() -> void:
	var shot: Image = null
	var was := panel.visible
	panel.visible = false; hud.visible = false
	await RenderingServer.frame_post_draw
	shot = get_viewport().get_texture().get_image()
	panel.visible = was; hud.visible = true
	var dir := IssueReport.write(level, note_edit.text, shot)
	var bad := IssueReport.verify(dir)
	status.text = ("Saved: " + dir) if bad.is_empty() else ("Saved with gaps %s: %s" % [bad, dir])
	hud.text = "Report saved"
	note_edit.text = ""
	print("REPORT ", dir, " ", bad)

func _process(delta: float) -> void:
	if level == null or not level.ready_done: return
	_t += delta
	if _t < 0.25: return
	_t = 0.0
	var s := level.stats()
	hud.text = "%.0f fps  %.1f ms  worst %.1f ms   F1 panel  F8 report" % [s.fps, s.frame_ms, s.worst_10s_ms]
	if not panel.visible: return
	hour_label.text = "%05.2f h" % level.get_hour()
	if not hour_slider.has_focus(): hour_slider.set_value_no_signal(level.get_hour())
	var ph := ""
	for k in s.phase_ms: ph += "%s %.2f  " % [k, s.phase_ms[k]]
	var w := level.where()
	stats_label.text = "\n".join([
		"frame %.2f ms (%.0f fps), worst in 10 s %.1f ms" % [s.frame_ms, s.fps, s.worst_10s_ms],
		"GPU %.2f ms   CPU render %.2f ms   process %.2f   physics %.2f" % [s.gpu_ms, s.cpu_render_ms, s.process_ms, s.physics_ms],
		"game tick %.2f ms: %s" % [s.tick_ms, ph],
		"fish %d   school main %.2f ms   worker step %.2f ms" % [s.fish, s.school_main_ms, s.school_step_ms],
		"draw calls %d   triangles %d   objects %d" % [s.draw_calls, s.triangles, s.objects],
		"video memory %.0f MB   static memory %.0f MB" % [s.video_mem_mb, s.static_mem_mb],
		"girl %s at %s, surface %.2f m" % [w.mode, str(w.feet), w.water_level],
		("MISSING ASSETS: " + ", ".join(level.missing_assets)) if not level.missing_assets.is_empty() else "assets: all found"])
