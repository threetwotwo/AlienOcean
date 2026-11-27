## M01 Input, Godot adapter 0.1.0. Installs the action table into InputMap, fills one InputPacket per physics tick,
## tracks the last used device family (glyph swap), pauses on controller loss, and saves/loads remaps.
## Add as a child Node (or autoload). Camera yaw/pitch come from the camera module through set_camera().
extends Node

const Packet := preload("res://core/m01_input/input_packet.gd")
const Table := preload("res://core/m01_input/action_table.gd")

signal device_family_changed(family: String)
signal controller_lost(device: int)
signal controller_returned(device: int)

var bindings: Dictionary = Table.ACTIONS.duplicate(true)
var family := "keyboard"
var paused_by_disconnect := false
var cam_yaw := 0.0
var cam_pitch := 0.0
var look_sensitivity := 2.6        # rad/s at full stick
var invert_y := false
var remap_path := "user://input_remap.cfg"

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
		var stick: bool = b.has("pad_axis") and b.pad_axis[0] <= 3
		InputMap.add_action(a, 0.0 if stick else (0.05 if b.has("pad_axis") else 0.5))
		if b.has("pad_button"):
			var e := InputEventJoypadButton.new(); e.button_index = b.pad_button; e.device = -1
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
	cf.save(remap_path)

func load_remap() -> void:
	var cf := ConfigFile.new()
	if cf.load(remap_path) != OK:
		return
	for a in bindings:
		bindings[a] = cf.get_value("bindings", a, bindings[a])
	look_sensitivity = cf.get_value("options", "look_sensitivity", look_sensitivity)
	invert_y = cf.get_value("options", "invert_y", invert_y)
	install()

func set_camera(yaw: float, pitch: float) -> void:
	cam_yaw = yaw; cam_pitch = pitch

func _input(event: InputEvent) -> void:
	note_event(event)

func note_event(event: InputEvent) -> void:
	var f := family
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.3):
		f = Table.family_from_name(Input.get_joy_name(event.device))
	elif event is InputEventKey or event is InputEventMouseButton or (event is InputEventMouseMotion and event.relative.length() > 2.0):
		f = "keyboard"
	if f != family:
		family = f
		device_family_changed.emit(family)

func _on_joy_connection(device: int, connected: bool) -> void:
	if connected:
		controller_returned.emit(device)
	elif family != "keyboard":
		paused_by_disconnect = true   # the game pauses and shows the reconnect prompt; only an explicit confirm unpauses
		controller_lost.emit(device)

func resume_after_reconnect() -> void:
	paused_by_disconnect = false

func glyph(action: String) -> String:
	return Table.glyph(action, family, bindings)

## One packet for this physics tick. While paused for a lost controller the packet is neutral (no stuck input).
func read() -> Object:
	var p = Packet.new()
	p.cam_yaw = cam_yaw; p.cam_pitch = cam_pitch
	if paused_by_disconnect:
		return p
	p.move = Packet.shape_stick(Vector2(Input.get_axis("move_left", "move_right"), Input.get_axis("move_back", "move_forward")))
	var lk := Packet.shape_stick(Vector2(Input.get_axis("look_left", "look_right"), Input.get_axis("look_down", "look_up")))
	p.look = Vector2(lk.x, lk.y * (-1.0 if invert_y else 1.0)) * look_sensitivity
	p.thrust = Input.get_action_strength("thrust")
	p.ascend = Input.is_action_pressed("ascend")
	p.descend = Input.is_action_pressed("descend")
	p.jump_pressed = Input.is_action_just_pressed("ascend")
	p.interact_pressed = Input.is_action_just_pressed("interact")
	return p
