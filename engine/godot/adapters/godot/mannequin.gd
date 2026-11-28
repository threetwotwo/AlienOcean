## M04 Body, Godot adapter 0.1.0: Gary's Thalassa v20.19 girl mannequin (style/ue5-mannequin.js
## buildUE5MannequinMeshes + renderer.js drawDiverBody), built from the same lofted stations, posed each frame from
## the body rig's pose (core/m04_body/body_rig.gd). 1.38 m, ceramic alabaster body, slate joint beads, a brow band
## so facing reads. No hair, fins, tank or mask (as in Thalassa). Stand-in look until the character art lands.
extends Node3D

const BM := preload("res://core/m04_body/body_math.gd")

const CERAMIC_LIGHT := Color(0.91, 0.90, 0.88)
const CERAMIC_MID := Color(0.83, 0.84, 0.84)
const JOINT_SLATE := Color(0.42, 0.49, 0.54)
const SOLE_SLATE := Color(0.34, 0.41, 0.46)
const FACE_BAND := Color(0.24, 0.30, 0.35)

var mat := StandardMaterial3D.new()
var parts := {}
var joints: Array[MeshInstance3D] = []
var joint_mesh: ArrayMesh
var alpha := 1.0
## one skinned body on the rig's full skeleton (adapters/godot/body_skin.gd) when the pose carries it; the rigid
## pieces stay for poses without a skeleton (thalassa_exact) and for the first-person view (show_head false)
var use_skin := true
var skin_body = null
const BodySkin := preload("res://adapters/godot/body_skin.gd")

class MB:
	var st := SurfaceTool.new()
	var n := 0
	func _init() -> void: st.begin(Mesh.PRIMITIVE_TRIANGLES)
	func vert(p: Vector3, nr: Vector3, c: Color) -> int:
		st.set_normal(nr); st.set_color(c); st.add_vertex(p)
		n += 1
		return n - 1
	func tri(a: int, b: int, c: int) -> void:
		st.add_index(a); st.add_index(b); st.add_index(c)
	func quad(a: int, b: int, c: int, d: int) -> void:
		tri(a, b, c); tri(a, c, d)
	func sphere(c: Vector3, r: Vector3, segs: int, rings: int, col: Color) -> void:
		var base := n
		for ri in rings + 1:
			var phi := float(ri) / rings * PI
			for si in segs + 1:
				var th := float(si) / segs * TAU
				var nn := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
				var shade := 0.88 + 0.16 * (nn.y * 0.5 + 0.5)
				vert(c + nn * r, Vector3(nn.x / r.x, nn.y / r.y, nn.z / r.z).normalized(), col * shade)
		var stride := segs + 1
		for ri in rings:
			for si in segs:
				var a := base + ri * stride + si
				quad(a, a + 1, a + stride + 1, a + stride)
	func box(c: Vector3, s: Vector3, col: Color) -> void:
		var h := s * 0.5
		var faces := [[Vector3(0, 0, 1), [Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]],
			[Vector3(0, 0, -1), [Vector3(1, -1, -1), Vector3(-1, -1, -1), Vector3(-1, 1, -1), Vector3(1, 1, -1)]],
			[Vector3(1, 0, 0), [Vector3(1, -1, 1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1)]],
			[Vector3(-1, 0, 0), [Vector3(-1, -1, -1), Vector3(-1, -1, 1), Vector3(-1, 1, 1), Vector3(-1, 1, -1)]],
			[Vector3(0, 1, 0), [Vector3(-1, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, -1), Vector3(-1, 1, -1)]],
			[Vector3(0, -1, 0), [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, -1, 1), Vector3(-1, -1, 1)]]]
		for f in faces:
			var idx := []
			for p in f[1]:
				idx.append(vert(c + p * h, f[0], col))
			quad(idx[0], idx[1], idx[2], idx[3])
	## addLoft: rings of an ellipse (rx, front/back rz, centre cx/cz) at heights y; profile(u, th) -> [dr, color]
	func loft(stations: Array, segs: int, profile: Callable) -> void:
		var grid := []
		for i in stations.size():
			var stn: Dictionary = stations[i]
			var u := float(i) / (stations.size() - 1) if stations.size() > 1 else 0.0
			var row := []
			for k in segs + 1:
				var th := float(k % segs) / segs * TAU
				var c := cos(th); var s := sin(th)
				var rz: float = stn.get("rzBack", stn.get("rz", 0.0)) if s >= 0.0 else stn.get("rzFront", stn.get("rz", 0.0))
				var pr: Array = profile.call(u, th)
				row.append({"p": Vector3(stn.get("cx", 0.0) + c * stn.rx * pr[0], stn.y, stn.get("cz", 0.0) + s * rz * pr[0]), "col": pr[1], "c": c, "s": s})
			grid.append(row)
		var ids := []
		var ns: int = stations.size()
		for i in ns:
			var r := []
			for k in segs + 1:
				var kp := (k - 1 + segs) % segs
				var kn := (k + 1) % segs
				var dth: Vector3 = grid[i][kn].p - grid[i][kp].p
				var dy: Vector3 = grid[mini(ns - 1, i + 1)][k].p - grid[maxi(0, i - 1)][k].p
				var nr := dy.cross(dth)
				nr = nr.normalized() if nr.length() > 1e-6 else Vector3(grid[i][k].c, 0, grid[i][k].s)
				r.append(vert(grid[i][k].p, nr, grid[i][k].col))
			ids.append(r)
		for i in ns - 1:
			for k in segs:
				quad(ids[i][k], ids[i + 1][k], ids[i + 1][k + 1], ids[i][k + 1])
		var s0: Dictionary = stations[0]
		var c0 := vert(Vector3(s0.get("cx", 0.0), s0.y, s0.get("cz", 0.0)), Vector3.DOWN, CERAMIC_MID)
		for k in segs: tri(c0, ids[0][k], ids[0][k + 1])
		var sn: Dictionary = stations[ns - 1]
		var cn := vert(Vector3(sn.get("cx", 0.0), sn.y, sn.get("cz", 0.0)), Vector3.UP, CERAMIC_LIGHT)
		for k in segs: tri(cn, ids[ns - 1][k + 1], ids[ns - 1][k])
	func mesh() -> ArrayMesh:
		return st.commit()

static func _flat(col: Color) -> Callable:
	return func(_u: float, _th: float) -> Array: return [1.0, col]

static func _limb(r_top: float, r_mid: float, r_bot: float) -> ArrayMesh:
	var m := MB.new()
	m.loft([{"y": 0.00, "rx": r_top * 0.90, "rz": r_top * 0.90}, {"y": 0.16, "rx": r_top, "rz": r_top}, {"y": 0.52, "rx": r_mid, "rz": r_mid},
		{"y": 0.86, "rx": r_bot, "rz": r_bot}, {"y": 1.00, "rx": r_bot * 0.88, "rz": r_bot * 0.88}], 14, _flat(CERAMIC_MID))
	return m.mesh()

func _ready() -> void:
	SeaFloorMap.mark_mover(self)   # moves: never frozen into the sea floor map (the water drew stale copies, Gary 28 Nov)
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.62
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var meshes := {}
	var jm := MB.new(); jm.sphere(Vector3.ZERO, Vector3.ONE * 0.92, 14, 10, JOINT_SLATE); joint_mesh = jm.mesh()
	var head := MB.new()
	head.sphere(Vector3(0, -0.006, 0.004), Vector3(0.046, 0.042, 0.046), 14, 10, CERAMIC_MID)
	head.loft([{"y": -0.024, "rx": 0.042, "rzFront": 0.042, "rzBack": 0.042, "cz": 0.004}, {"y": 0.016, "rx": 0.068, "rzFront": 0.076, "rzBack": 0.066, "cz": -0.004},
		{"y": 0.066, "rx": 0.092, "rzFront": 0.098, "rzBack": 0.094, "cz": -0.002}, {"y": 0.118, "rx": 0.102, "rzFront": 0.104, "rzBack": 0.108, "cz": 0.002},
		{"y": 0.168, "rx": 0.098, "rzFront": 0.096, "rzBack": 0.104, "cz": 0.004}, {"y": 0.208, "rx": 0.074, "rzFront": 0.072, "rzBack": 0.078, "cz": 0.004},
		{"y": 0.230, "rx": 0.026, "rzFront": 0.026, "rzBack": 0.026, "cz": 0.004}], 22,
		func(u: float, th: float) -> Array:
			var band := u >= 0.44 and u <= 0.56 and sin(th) < -0.58
			return [0.985 if band else 1.0, FACE_BAND if band else CERAMIC_LIGHT])
	meshes.head = head.mesh()
	var neck := MB.new()
	neck.loft([{"y": -0.10, "rx": 0.056, "rz": 0.052}, {"y": 0.28, "rx": 0.044, "rz": 0.043}, {"y": 0.72, "rx": 0.041, "rz": 0.041}, {"y": 1.24, "rx": 0.043, "rz": 0.043}], 14,
		func(u: float, _th: float) -> Array: return [1.0, JOINT_SLATE if u < 0.25 else CERAMIC_MID])
	meshes.neck = neck.mesh()
	var chest := MB.new()
	chest.loft([{"y": -0.105, "rx": 0.088, "rzFront": 0.068, "rzBack": 0.068}, {"y": -0.040, "rx": 0.108, "rzFront": 0.078, "rzBack": 0.076},
		{"y": 0.032, "rx": 0.126, "rzFront": 0.080, "rzBack": 0.078}, {"y": 0.082, "rx": 0.112, "rzFront": 0.068, "rzBack": 0.068},
		{"y": 0.110, "rx": 0.058, "rzFront": 0.052, "rzBack": 0.052}], 20,
		func(u: float, _th: float) -> Array: return [1.0, JOINT_SLATE if u > 0.85 else CERAMIC_LIGHT])
	meshes.chest = chest.mesh()
	var waist := MB.new()
	waist.loft([{"y": -0.04, "rx": 0.090, "rz": 0.070}, {"y": 0.46, "rx": 0.078, "rz": 0.062}, {"y": 1.04, "rx": 0.094, "rz": 0.072}], 16,
		func(u: float, _th: float) -> Array: return [1.0, JOINT_SLATE if (u > 0.35 and u < 0.58) else CERAMIC_MID])
	meshes.waist = waist.mesh()
	var pelvis := MB.new()
	pelvis.loft([{"y": -0.085, "rx": 0.088, "rzFront": 0.068, "rzBack": 0.074}, {"y": -0.015, "rx": 0.106, "rzFront": 0.078, "rzBack": 0.084},
		{"y": 0.055, "rx": 0.098, "rzFront": 0.072, "rzBack": 0.076}, {"y": 0.095, "rx": 0.086, "rzFront": 0.066, "rzBack": 0.068}], 18, _flat(CERAMIC_LIGHT))
	meshes.pelvis = pelvis.mesh()
	meshes.upper_arm = _limb(0.036, 0.032, 0.027)
	meshes.forearm = _limb(0.028, 0.025, 0.021)
	meshes.thigh = _limb(0.056, 0.048, 0.038)
	meshes.calf = _limb(0.038, 0.034, 0.024)
	for side in [-1.0, 1.0]:
		var h := MB.new()
		h.sphere(Vector3(0, 0.040, -0.003), Vector3(0.028, 0.046, 0.013), 12, 8, CERAMIC_LIGHT)
		h.sphere(Vector3(0, 0.082, -0.004), Vector3(0.022, 0.028, 0.010), 10, 6, CERAMIC_LIGHT)
		h.sphere(Vector3(side * 0.026, 0.034, -0.010), Vector3(0.010, 0.022, 0.009), 8, 6, CERAMIC_MID)
		meshes["hand_l" if side < 0 else "hand_r"] = h.mesh()
	var foot := MB.new()
	foot.sphere(Vector3(0, 0.008, -0.016), Vector3(0.028, 0.036, 0.030), 12, 8, CERAMIC_LIGHT)
	foot.sphere(Vector3(0, 0.068, -0.028), Vector3(0.031, 0.066, 0.022), 14, 8, CERAMIC_LIGHT)
	foot.sphere(Vector3(0, 0.128, -0.034), Vector3(0.028, 0.030, 0.016), 12, 8, CERAMIC_LIGHT)
	foot.box(Vector3(0, 0.058, -0.046), Vector3(0.056, 0.168, 0.012), SOLE_SLATE)
	meshes.foot = foot.mesh()
	for key in ["chest", "pelvis", "waist", "neck", "head", "upper_arm_l", "forearm_l", "hand_l", "upper_arm_r", "forearm_r", "hand_r",
			"thigh_l", "calf_l", "foot_l", "thigh_r", "calf_r", "foot_r"]:
		var mi := MeshInstance3D.new()
		var base: String = key.trim_suffix("_l").trim_suffix("_r") if not key.begins_with("hand") else key
		mi.mesh = meshes[base]
		mi.material_override = mat
		add_child(mi)
		parts[key] = mi
	for i in 12:
		var j := MeshInstance3D.new(); j.mesh = joint_mesh; j.material_override = mat
		add_child(j); joints.append(j)

func _seg(key: String, a: Vector3, b: Vector3, ref) -> void:
	parts[key].global_transform = BM.segment_xf(a, b, 1.0, 1.0, ref)

func _joint(i: int, p: Vector3, r: float) -> void:
	joints[i].global_transform = Transform3D(Basis().scaled(Vector3.ONE * r), p)

## drawDiverBody: place every part from the pose. show_head false hides neck and head (lens inside the skull).
## In the game world the body takes the water-lit material (look/body_surface.gdshader): WorldRoot registers the water_*
## globals, possibly after this node is ready, so the swap is made on the first apply that finds them. The tests' plain
## worlds have no water globals and keep the standard material.
var water_mat_done := false
func _water_material() -> void:
	water_mat_done = true
	# WorldRoot.declare_globals sets this meta once the water_* globals exist (global_shader_parameter_get_list is an
	# editor-only call that logged a performance warning every frame on the Mac)
	if not Engine.has_meta("water_globals"):
		water_mat_done = false
		return
	var sm := ShaderMaterial.new(); sm.shader = load("res://look/body_surface.gdshader")
	var stack: Array = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D: (n as MeshInstance3D).material_override = sm
		stack.append_array(n.get_children())

func apply(pose: Dictionary, show_head := true) -> void:
	if not water_mat_done and (skin_body == null or skin_body.bound): _water_material()     # (the skin mesh takes it too, once built)
	var skinned: bool = use_skin and show_head and pose.has("skel")
	if skinned:
		if skin_body == null:
			skin_body = BodySkin.new()
			add_child(skin_body)
			water_mat_done = false     # (the skin's mesh takes the water material too)
		skin_body.visible = true
		skin_body.apply(pose.skel)
	elif skin_body != null:
		skin_body.visible = false
	for k in parts: parts[k].visible = not skinned
	for j in joints: j.visible = not skinned
	if skinned: return
	parts.chest.global_transform = pose.chestMat
	parts.pelvis.global_transform = pose.pelvisMat
	_seg("waist", pose.pelvisPos, pose.chestPos, pose.bodyBack)
	parts.neck.visible = show_head
	parts.head.visible = show_head
	if show_head:
		_seg("neck", pose.chestPos, pose.headMat.origin, pose.bodyBack)
		parts.head.global_transform = pose.headMat
	var ji := 0
	for side in ["l", "r"]:
		var arm: Dictionary = pose.armL if side == "l" else pose.armR
		_joint(ji, arm.root, 0.032); ji += 1
		_seg("upper_arm_" + side, arm.root, arm.mid, arm.bendAxis)
		_joint(ji, arm.mid, 0.025); ji += 1
		_seg("forearm_" + side, arm.mid, arm.eff, arm.bendAxis)
		_joint(ji, arm.eff, 0.020); ji += 1
		parts["hand_" + side].global_transform = pose.handLMat if side == "l" else pose.handRMat
	for side in ["l", "r"]:
		var lg: Dictionary = pose.legL if side == "l" else pose.legR
		var ik: Dictionary = lg.ik
		_joint(ji, ik.root, 0.040); ji += 1
		_seg("thigh_" + side, ik.root, ik.mid, ik.bendAxis)
		_joint(ji, ik.mid, 0.031); ji += 1
		_seg("calf_" + side, ik.mid, ik.eff, ik.bendAxis)
		_joint(ji, ik.eff, 0.024); ji += 1
		parts["foot_" + side].global_transform = lg.finMat

func set_alpha(a: float) -> void:
	if a == alpha: return
	alpha = a
	visible = a > 0.01
