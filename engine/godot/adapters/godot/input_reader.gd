## M01 Input, Godot adapter 0.2.0. Installs the action table into InputMap, fills one InputPacket per physics tick,
## tracks the last used device family (glyph swap), pauses on controller loss, saves/loads remaps and options, and plays
## rumble (0.2.0: core/m01_input/haptics.gd events through Input.start_joy_vibration on the last used pad).
## Pads reach Godot 4.7 through SDL3 with its controller database (Xbox, PlayStation, Switch Pro and Apple MFi pads all
## arrive in the same standard layout), so one table serves every family; only the glyphs differ.
## Add as a child Node (or autoload). Camera yaw/pitch come from the camera module through set_camera().
extends Node

const Packet := preload("res://core/m01_input/input_packet.gd")
const Table := preload("res://core/m01_input/action_table.gd")
const LookFilter := preload("res://core/m01_input/look_filter.gd")
const Haptics := preload("res://core/m01_input/haptics.gd")

signal device_family_changed(family: String)
signal controller_lost(device: int)
signal controller_returned(device: int)

var bindings: Dictionary = Table.ACTIONS.duplicate(true)
var family := "keyboard"
var paused_by_disconnect := false
var cam_yaw := 0.0
var cam_pitch := 0.0
var look_sensitivity := 1.0        # multiplier on Thalassa's 2.4 rad/s (options menu)
var look_filter = LookFilter.new()
var sprint_latch := false
var invert_y := false
var remap_path := "user://input_remap.cfg"
var haptics = Haptics.new()
var last_pad := -1                 # device id of the pad used last (rumble goes there)
var rumbles: Array = []            # [event, pulse] played (tests and the issue report read it), last 32

func _ready() -> void:
	install()
	Input.joy_connection_changed.connect(_on_joy_connection)

## (Re)build every action in InputMap from the bindings table.
func install() -> void:
	var errs := Table.validate(bindings)
	assert(errs.is_empty(), "input table invalid: %s" % [errs])
	for a in bindings:
		if InputMap.has_action(a):
			InputMap.erase_action(a)
		var b: Dictionary = bindings[a]
		# sticks reach the core raw (deadzone 0): the core applies one radial deadzone + curve (shape_stick).
		# A per-action deadzone here would stack with it and halve small stick input.
		var stick: bool = b.has("pad_axis")   # sticks and triggers reach the core raw: it applies Thalassa's curves
		InputMap.add_action(a, 0.0 if stick else 0.5)
		for key in ["pad_button", "pad_button_alt"]:
			if b.has(key):
				var e := InputEventJoypadButton.new(); e.button_index = b[key]; e.device = -1
				InputMap.action_add_event(a, e)
		if b.has("pad_axis"):
			var m := InputEventJoypadMotion.new(); m.axis = b.pad_axis[0]; m.axis_value = float(b.pad_axis[1]); m.device = -1
			InputMap.action_add_event(a, m)
		if b.has("key"):
			var k := InputEventKey.new(); k.physical_keycode = OS.find_keycode_from_string(b.key)
			InputMap.action_add_event(a, k)
		if b.has("mouse"):
			var mb := InputEventMouseButton.new(); mb.button_index = b.mouse
			InputMap.action_add_event(a, mb)
	# menus: Godot's ui_accept / ui_cancel ship with keys only. Cross / A confirms and Circle / B backs out on every pad
	# (fixed, not remappable, so a bad remap can never lock the player out of the menu)
	for pair in [["ui_accept", JOY_BUTTON_A], ["ui_cancel", JOY_BUTTON_B]]:
		var j := InputEventJoypadButton.new(); j.button_index = pair[1]; j.device = -1
		if not InputMap.action_has_event(pair[0], j): InputMap.action_add_event(pair[0], j)

## Remap one action's pad button (refused if it is a system button or already taken: the caller shows why).
func rebind_pad_button(action: String, button: int) -> String:
	var trial := bindings.duplicate(true)
	trial[action].erase("pad_axis")
	trial[action]["pad_button"] = button
	var errs := Table.validate(trial)
	if not errs.is_empty():
		return errs[0]
	bindings = trial
	install()
	return ""

func save_remap() -> void:
	var cf := ConfigFile.new()
	for a in bindings:
		cf.set_value("bindings", a, bindings[a])
	cf.set_value("options", "look_sensitivity", look_sensitivity)
	cf.set_value("options", "invert_y", invert_y)
	cf.set_value("options", "vibration", haptics.enabled)
	cf.set_value("options", "vibration_strength", haptics.strength)
	cf.save(remap_path)

## Back to the shipped table (options menu "Reset controls").
func reset_bindings() -> void:
	bindings = Table.ACTIONS.duplicate(true)
	install()

func load_remap() -> void:
	var cf := ConfigFile.new()
	if cf.load(remap_path) != OK:
		return
	for a in bindings:
		bindings[a] = cf.get_value("bindings", a, bindings[a])
	look_sensitivity = cf.get_value("options", "look_sensitivity", look_sensitivity)
	invert_y = cf.get_value("options", "invert_y", invert_y)
	haptics.enabled = cf.get_value("options", "vibration", haptics.enabled)
	haptics.strength = cf.get_value("options", "vibration_strength", haptics.strength)
	if not Table.validate(bindings).is_empty(): bindings = Table.ACTIONS.duplicate(true)   # a broken file never locks the pad
	install()

## Play one rumble event on the last used pad. Returns the pulse played ({} = skipped: keyboard, switched off, too soon).
func rumble(event: String, scale := 1.0) -> Dictionary:
	var p: Dictionary = haptics.pulse(event, Time.get_ticks_msec(), family != "keyboard" and last_pad >= 0, scale)
	if p.is_empty(): return p
	Input.start_joy_vibration(last_pad, p.weak, p.strong, p.sec)
	rumbles.append([event, p])
	if rumbles.size() > 32: rumbles.pop_front()
	return p

func set_camera(yaw: float, pitch: float) -> void:
	cam_yaw = yaw; cam_pitch = pitch

func _input(event: InputEvent) -> void:
	note_event(event)

func note_event(event: InputEvent) -> void:
	var f := family
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.3):
		f = Table.family_from_name(Input.get_joy_name(event.device))
		last_pad = event.device
	elif event is InputEventKey or event is InputEventMouseButton or (event is InputEventMouseMotion and event.relative.length() > 2.0):
		f = "keyboard"
	if f != family:
		family = f
		device_family_changed.emit(family)

func _on_joy_connection(device: int, connected: bool) -> void:
	if connected:
		controller_returned.emit(device)
		last_pad = device; family = Table.family_from_name(Input.get_joy_name(device)); device_family_changed.emit(family)
		rumble("controller_connected")
	elif family != "keyboard":
		paused_by_disconnect = true   # the game pauses and shows the reconnect prompt; only an explicit confirm unpauses
		controller_lost.emit(device)

func resume_after_reconnect() -> void:
	paused_by_disconnect = false

func glyph(action: String) -> String:
	return Table.glyph(action, family, bindings)

## One packet for this physics tick. While paused for a lost controller the packet is neutral (no stuck input).
func read(dt: float = 1.0 / 60.0) -> Object:
	var p = Packet.new()
	p.cam_yaw = cam_yaw; p.cam_pitch = cam_pitch
	if paused_by_disconnect:
		look_filter.reset(); sprint_latch = false
		return p
	p.move = Packet.shape_stick(Vector2(Input.get_axis("move_left", "move_right"), Input.get_axis("move_back", "move_forward")))
	look_filter.sensitivity = look_sensitivity; look_filter.invert_y = invert_y
	p.look = look_filter.step(Vector2(Input.get_axis("look_left", "look_right"), Input.get_axis("look_down", "look_up")), dt)
	# Thalassa: L3 latches sprint until the stick returns to rest; R2 boosts past 0.28 raw
	if Input.is_action_just_pressed("sprint_toggle"): sprint_latch = not sprint_latch
	if p.move.length() < 0.08: sprint_latch = false
	var r2 := Input.get_action_strength("thrust")
	p.thrust = 1.0 if sprint_latch else (maxf(r2, 0.29) if r2 > 0.28 else Packet.shape_trigger(r2))
	p.ascend = Input.is_action_pressed("ascend")
	p.descend_amount = Packet.shape_trigger(Input.get_action_strength("descend"))
	p.descend = p.descend_amount > 0.5
	p.jump_pressed = Input.is_action_just_pressed("ascend")
	p.interact_pressed = Input.is_action_just_pressed("interact")
	return p
