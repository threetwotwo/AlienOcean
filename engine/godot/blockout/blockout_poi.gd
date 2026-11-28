## Blockout point of interest 0.1.0 (blockout kit): something the girl's senses can notice. kind: object | creature |
## sound. A creature may circle its home; a sound is 'alive' only while it sounds (sound_len every sound_period s).
## State is a function of the physics time it has seen, so every render rate agrees at the fixed tick.
extends Node3D

const GROUP := "blockout_poi"

var poi_name := ""
var kind := "object"
var alive := true
var home := Vector3.ZERO
var circle_radius := 0.0
var circle_speed := 0.0        # m/s along the circle
var sound_period := 0.0
var sound_len := 0.0
var t := 0.0
var velocity := Vector3.ZERO

func _ready() -> void:
	add_to_group(GROUP)
	var mi := MeshInstance3D.new()
	if kind == "sound":
		var m := CylinderMesh.new(); m.top_radius = 0.15; m.bottom_radius = 0.25; m.height = 0.3; mi.mesh = m
	elif kind == "creature":
		var m := CapsuleMesh.new(); m.radius = 0.2; m.height = 0.9; mi.mesh = m
		mi.rotation = Vector3(PI * 0.5, 0, 0)
	else:
		var m := SphereMesh.new(); m.radius = 0.25; m.height = 0.5; mi.mesh = m
	mi.material_override = preload("res://blockout/blockout_kit.gd").grey_material()
	add_child(mi)
	_apply()

func _physics_process(delta: float) -> void:
	t += delta
	_apply()

func _apply() -> void:
	if circle_radius > 0.0:
		var w := circle_speed / circle_radius
		var a := w * t
		var p := home + Vector3(cos(a), 0, sin(a)) * circle_radius - Vector3(circle_radius, 0, 0)
		velocity = Vector3(-sin(a), 0, cos(a)) * circle_speed
		position = p
		if is_inside_tree(): look_at(global_position + velocity, Vector3.UP)
	if sound_period > 0.0:
		alive = fmod(t, sound_period) < sound_len

func as_dict() -> Dictionary:
	return {"pos": global_position, "kind": kind, "name": poi_name, "alive": alive, "velocity": velocity}
