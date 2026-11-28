## Blockout rider 0.1.0 (blockout kit): a 2.5 m creature stand-in that swims a scripted loop, for riding tests.
## The loop (a racetrack, all distances in metres, about 2.5 m/s along the ground):
##   A straight 16 m with a dive (down 2.5 m and back)    B left turn, radius 5, banked 20 deg
##   C straight 16 m with a climb (up 2.5 m and back)      D left turn, radius 5, banked 20 deg
## Pose is a pure function of time (frame_at(t)), so 30/60/120 Hz runs at the fixed tick land on the same poses.
## Read each tick: velocity (m/s), marker(name) -> Transform3D for saddle, hand_l, hand_r, foot_l, foot_r
## (saddle: -Z forward, +Y up off the back). Collision: one capsule on layer 2 (not the floor layer).
extends AnimatableBody3D

const L := 16.0
const R := 5.0
const H := 2.5
const BANK := deg_to_rad(20.0)
const LENGTH := 2.5
const RADIUS := 0.35
const MARKERS := {
	"saddle": [Vector3(0, 0.40, 0.10), Vector3.FORWARD],
	"hand_l": [Vector3(-0.16, 0.44, -0.45), Vector3.FORWARD],
	"hand_r": [Vector3(0.16, 0.44, -0.45), Vector3.FORWARD],
	"foot_l": [Vector3(-0.34, 0.12, 0.35), Vector3.FORWARD],
	"foot_r": [Vector3(0.34, 0.12, 0.35), Vector3.FORWARD],
}

var speed := 2.5
var origin := Vector3(0, -4, -6)
var t := 0.0
var velocity := Vector3.ZERO
var paused := false

func _init() -> void:
	sync_to_physics = true
	collision_layer = 2
	collision_mask = 0

func _ready() -> void:
	var mat := ShaderMaterial.new(); mat.shader = preload("res://blockout/blockout_grey.gdshader")
	mat.set_shader_parameter("tint_amount", 0.5)
	var parts := [
		[CapsuleMesh, {"radius": RADIUS, "height": LENGTH}, Vector3.ZERO, Vector3(PI * 0.5, 0, 0)],
		[BoxMesh, {"size": Vector3(1.9, 0.06, 0.7)}, Vector3(0, -0.05, -0.05), Vector3.ZERO],      # pectoral fins
		[BoxMesh, {"size": Vector3(0.06, 0.5, 0.45)}, Vector3(0, 0.05, 1.35), Vector3.ZERO],       # tail fin
		[BoxMesh, {"size": Vector3(0.34, 0.08, 0.5)}, Vector3(0, 0.36, 0.10), Vector3.ZERO],       # saddle pad
		[SphereMesh, {"radius": 0.08, "height": 0.16}, Vector3(-0.2, 0.12, -1.0), Vector3.ZERO],    # eyes (which end is the head)
		[SphereMesh, {"radius": 0.08, "height": 0.16}, Vector3(0.2, 0.12, -1.0), Vector3.ZERO],
	]
	for pt in parts:
		var mi := MeshInstance3D.new(); var m: PrimitiveMesh = pt[0].new()
		for k in pt[1]: m.set(k, pt[1][k])
		mi.mesh = m; mi.position = pt[2]; mi.rotation = pt[3]; mi.material_override = mat
		add_child(mi)
	var cs := CollisionShape3D.new(); var cap := CapsuleShape3D.new(); cap.radius = RADIUS; cap.height = LENGTH
	cs.shape = cap; cs.rotation = Vector3(PI * 0.5, 0, 0)
	add_child(cs)
	for n in MARKERS:
		var mk := Marker3D.new(); mk.name = n; mk.position = MARKERS[n][0]
		add_child(mk)
	_apply()

func _physics_process(delta: float) -> void:
	if not paused: t += delta
	_apply()

func _apply() -> void:
	var f := frame_at(t)
	var par := get_parent() as Node3D
	global_transform = (par.global_transform if par != null and par.is_inside_tree() else Transform3D.IDENTITY) * f.xform
	velocity = f.velocity

func marker(mname: String) -> Transform3D:
	return global_transform * Transform3D(Basis.IDENTITY, MARKERS[mname][0])

static func perimeter() -> float:
	return 2.0 * L + 2.0 * PI * R

## Pose at time tt: {xform, velocity, segment}. Local frame of the loop: starts at origin heading -Z.
func frame_at(tt: float) -> Dictionary:
	var s := fposmod(tt * speed, perimeter())
	var p := Vector3.ZERO
	var d := Vector3.ZERO      # d(position)/ds
	var bank := 0.0
	var seg := ""
	var turn := PI * R
	if s < L:                                  # A: straight toward -z, dive
		var u := s / L
		p = Vector3(0, -H * pow(sin(PI * u), 2), -s)
		d = Vector3(0, -H * PI * sin(TAU * u) / L, -1)
		seg = "A_dive"
	elif s < L + turn:                         # B: left turn round (-R, -L)
		var th := (s - L) / R
		p = Vector3(-R + R * cos(th), 0, -L - R * sin(th))
		d = Vector3(-sin(th), 0, -cos(th))
		bank = BANK * sin(th)
		seg = "B_turn"
	elif s < 2.0 * L + turn:                   # C: straight toward +z at x = -2R, climb
		var u := (s - L - turn) / L
		p = Vector3(-2.0 * R, H * pow(sin(PI * u), 2), -L + (s - L - turn))
		d = Vector3(0, H * PI * sin(TAU * u) / L, 1)
		seg = "C_climb"
	else:                                      # D: left turn round (-R, 0) back to the start
		var ph := (s - 2.0 * L - turn) / R
		p = Vector3(-R - R * cos(ph), 0, R * sin(ph))
		d = Vector3(sin(ph), 0, cos(ph))
		bank = BANK * sin(ph)
		seg = "D_turn"
	var fwd := d.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var up := right.cross(fwd)
	var up2 := up * cos(bank) - right * sin(bank)     # roll into the (left) turn
	var right2 := up2.cross(-fwd)
	return {"xform": Transform3D(Basis(right2, up2, -fwd), origin + p), "velocity": d * speed, "segment": seg}
