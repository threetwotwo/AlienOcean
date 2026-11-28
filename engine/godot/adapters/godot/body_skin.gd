## M04 Body, Godot adapter: the girl as ONE skinned body (Skeleton3D + a single skinned mesh) driven by the rig's full
## skeleton (core/m04_body/body_rig.gd _skeleton: pelvis, spine_01..03, neck_lower, neck_upper, head, eyes, upper lids,
## jaw, clavicles, arms, hands, legs, feet, toes: 28 bones). Same proportions and ceramic stand-in look as the rigid mannequin (adapters/godot/mannequin.gd), but the torso
## is one loft along the spine and every limb blends into its neighbours at the joint, so bends are smooth instead of
## pieces meeting at beads. The mesh is built around the first pose it is given and bound to it.
extends Node3D

const CERAMIC_LIGHT := Color(0.91, 0.90, 0.88)
const CERAMIC_MID := Color(0.86, 0.865, 0.865)
const SOLE_SLATE := Color(0.34, 0.41, 0.46)
const FACE_BAND := Color(0.24, 0.30, 0.35)

const BONES := ["pelvis", "spine_01", "spine_02", "spine_03", "neck_lower", "neck_upper", "head", "eye_l", "eye_r", "lid_l", "lid_r", "jaw",
	"clavicle_l", "upperarm_l", "lowerarm_l", "hand_l", "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r",
	"thigh_l", "calf_l", "foot_l", "ball_l", "thigh_r", "calf_r", "foot_r", "ball_r"]

var skel := Skeleton3D.new()
var mi := MeshInstance3D.new()
var mat := ShaderMaterial.new()   # look/standin_lit*.gdshader: vertex colour + roughness + the screen AO (CORTAO)
var bound := false
var idx := {}

func _ready() -> void:
	add_child(skel)
	skel.add_child(mi)
	for b in BONES:
		idx[b] = skel.add_bone(b)
	mat.shader = load("res://look/standin_lit.gdshader"); mat.set_shader_parameter("roughness_v", 0.58)
	mi.material_override = mat

func apply(bones: Dictionary) -> void:
	if not bound:
		_bind(bones)
	var inv := skel.global_transform.affine_inverse()
	for b in BONES:
		if not bones.has(b): continue
		var x: Transform3D = inv * bones[b]
		skel.set_bone_pose_position(idx[b], x.origin)
		skel.set_bone_pose_rotation(idx[b], x.basis.orthonormalized().get_rotation_quaternion())
	# breath (body_rig _breath_body): the chest, ribs and belly fill by a small scale in their own axes
	var bsc: Dictionary = bones.get("breath_scale", {})
	for b in ["spine_01", "spine_02", "spine_03"]:
		skel.set_bone_pose_scale(idx[b], bsc.get(b, Vector3.ONE))

# ------------------------------------------------------------------ mesh
var st := SurfaceTool.new()
var nv := 0
var B := {}     # bind transforms (skeleton space)

func _v(p: Vector3, c: Color, w: Dictionary) -> int:
	var bi := PackedInt32Array([0, 0, 0, 0])
	var bw := PackedFloat32Array([0, 0, 0, 0])
	var keys := w.keys()
	var tot := 0.0
	for k in keys: tot += w[k]
	for i in mini(4, keys.size()):
		bi[i] = idx[keys[i]]
		bw[i] = w[keys[i]] / tot
	st.set_color(c)
	st.set_bones(bi)
	st.set_weights(bw)
	st.add_vertex(p)
	nv += 1
	return nv - 1

func _quad(a: int, b: int, c: int, d: int) -> void:
	st.add_index(a); st.add_index(b); st.add_index(c)
	st.add_index(a); st.add_index(c); st.add_index(d)

static func _wlerp(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var o := {}
	for k in a: o[k] = o.get(k, 0.0) + a[k] * (1.0 - t)
	for k in b: o[k] = o.get(k, 0.0) + b[k] * t
	return o

## rings: [{c: centre, x: right axis, z: back axis, rx, rzf, rzb, w: weights, col}], sub: rows between rings
func _tube(rings: Array, segs: int, sub: int, cap0 := true, cap1 := true) -> void:
	var rows := []
	for i in rings.size() - 1:
		var a: Dictionary = rings[i]
		var b: Dictionary = rings[i + 1]
		for j in sub:
			var t := float(j) / sub
			var tt := t * t * (3.0 - 2.0 * t) if sub > 1 else t
			rows.append({"c": a.c.lerp(b.c, t), "x": a.x.slerp(b.x, t).normalized() if a.x.dot(b.x) > -0.9 else a.x,
				"z": a.z.slerp(b.z, t).normalized() if a.z.dot(b.z) > -0.9 else a.z,
				"rx": lerpf(a.rx, b.rx, tt), "rzf": lerpf(a.rzf, b.rzf, tt), "rzb": lerpf(a.rzb, b.rzb, tt),
				"w": _wlerp(a.w, b.w, t), "col": a.col.lerp(b.col, t)})
	rows.append(rings[rings.size() - 1])
	var ids := []
	for r in rows:
		var row := []
		for k in segs:
			var th := float(k) / segs * TAU
			var c := cos(th); var s := sin(th)
			var rz: float = r.rzb if s >= 0.0 else r.rzf
			row.append(_v(r.c + r.x * (c * r.rx) + r.z * (s * rz), r.col, r.w))
		ids.append(row)
	for i in ids.size() - 1:
		for k in segs:
			var k2 := (k + 1) % segs
			_quad(ids[i][k], ids[i][k2], ids[i + 1][k2], ids[i + 1][k])
	if cap0:
		var r0: Dictionary = rows[0]
		var c0 := _v(r0.c - r0.x.cross(r0.z).normalized() * 0.0, r0.col, r0.w)
		for k in segs: st.add_index(c0); st.add_index(ids[0][(k + 1) % segs]); st.add_index(ids[0][k])
	if cap1:
		var rn: Dictionary = rows[rows.size() - 1]
		var cn := _v(rn.c, rn.col, rn.w)
		var last: Array = ids[ids.size() - 1]
		for k in segs: st.add_index(cn); st.add_index(last[k]); st.add_index(last[(k + 1) % segs])

func _ring(bone: String, y: float, rx: float, rzf: float, rzb: float, w: Dictionary, col := CERAMIC_LIGHT) -> Dictionary:
	var x: Transform3D = B[bone]
	return {"c": x * Vector3(0, y, 0), "x": x.basis.x.normalized(), "z": x.basis.z.normalized(), "rx": rx, "rzf": rzf, "rzb": rzb, "w": w, "col": col}

## an ellipsoid rigidly on a bone (local centre and radii in that bone's frame)
func _blob(bone: String, c: Vector3, r: Vector3, col: Color, segs := 12, rings := 8, frame = null) -> void:
	var x: Transform3D = frame if frame != null else B[bone]
	var base := nv
	for ri in rings + 1:
		var phi := float(ri) / rings * PI
		for si in segs:
			var th := float(si) / segs * TAU
			var nn := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			_v(x * (c + nn * r), col, {bone: 1.0})
	for ri in rings:
		for si in segs:
			var a := base + ri * segs + si
			var b := base + ri * segs + (si + 1) % segs
			_quad(a, a + segs, b + segs, b)

## a limb from bone a (start) to its child: blended 50/50 with the parent at the start and the child at the end
func _limb(bone: String, parent: String, child: String, length: float, r0: float, r1: float, r2: float) -> void:
	var rings := []
	var spec := [[-0.35 * r0 / length, r0 * 0.92, {parent: 0.5, bone: 0.5}], [0.0, r0, {parent: 0.35, bone: 0.65}], [0.16, r0, {bone: 1.0}],
		[0.52, r1, {bone: 1.0}], [0.86, r2, {bone: 1.0}], [1.0, r2 * 0.96, {bone: 0.55, child: 0.45}], [1.0 + 0.5 * r2 / length, r2 * 0.80, {bone: 0.35, child: 0.65}]]
	for sp in spec:
		rings.append(_ring(bone, sp[0] * length, sp[1], sp[1], sp[1], sp[2], CERAMIC_MID))
	_tube(rings, 14, 3)

func _bind(bones: Dictionary) -> void:
	var inv := skel.global_transform.affine_inverse()
	for b in BONES:
		B[b] = inv * (bones[b] as Transform3D) if bones.has(b) else Transform3D()
		B[b] = Transform3D(B[b].basis.orthonormalized(), B[b].origin)
	st.set_skin_weight_count(SurfaceTool.SKIN_4_WEIGHTS)
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	nv = 0
	# torso: one loft from the pelvis floor to the base of the neck, along the spine bones
	var torso := [
		_ring("pelvis", -0.085, 0.088, 0.068, 0.074, {"pelvis": 1.0}),
		_ring("pelvis", -0.015, 0.106, 0.078, 0.084, {"pelvis": 1.0}),
		_ring("pelvis", 0.055, 0.098, 0.072, 0.076, {"pelvis": 0.7, "spine_01": 0.3}),
		_ring("spine_01", 0.0, 0.088, 0.066, 0.068, {"pelvis": 0.25, "spine_01": 0.55, "spine_02": 0.2}),
		_ring("spine_02", 0.0, 0.094, 0.068, 0.070, {"spine_01": 0.3, "spine_02": 0.5, "spine_03": 0.2}),
		_ring("spine_03", -0.040, 0.108, 0.078, 0.076, {"spine_02": 0.3, "spine_03": 0.7}),
		_ring("spine_03", 0.032, 0.126, 0.080, 0.078, {"spine_03": 1.0}),
		_ring("spine_03", 0.082, 0.112, 0.068, 0.068, {"spine_03": 1.0}),
		_ring("spine_03", 0.110, 0.058, 0.052, 0.052, {"spine_03": 0.8, "neck_lower": 0.2})]
	_tube(torso, 20, 3)
	# neck into the head
	# (head upgrade) two neck bones: the lower carries the tilt, the upper the nod and turn
	var n0 := _ring("spine_03", 0.095, 0.050, 0.047, 0.047, {"spine_03": 0.8, "neck_lower": 0.2})
	var hd: Transform3D = B["head"]
	var n1 := {"c": hd * Vector3(0, -0.02, 0.004), "x": hd.basis.x, "z": hd.basis.z, "rx": 0.042, "rzf": 0.042, "rzb": 0.042, "w": {"neck_upper": 0.3, "head": 0.7}, "col": CERAMIC_MID}
	var na := {"c": n0.c.lerp(n1.c, 0.33), "x": n0.x.slerp(n1.x, 0.33), "z": n0.z.slerp(n1.z, 0.33), "rx": 0.044, "rzf": 0.042, "rzb": 0.042, "w": {"spine_03": 0.15, "neck_lower": 0.7, "neck_upper": 0.15}, "col": CERAMIC_MID}
	var nb := {"c": n0.c.lerp(n1.c, 0.67), "x": n0.x.slerp(n1.x, 0.67), "z": n0.z.slerp(n1.z, 0.67), "rx": 0.042, "rzf": 0.041, "rzb": 0.041, "w": {"neck_lower": 0.2, "neck_upper": 0.65, "head": 0.15}, "col": CERAMIC_MID}
	_tube([n0, na, nb, n1], 14, 2)
	# head (the rigid mannequin's head loft, on the head bone)
	var head_st := [[-0.024, 0.042, 0.042, 0.042, 0.004], [0.016, 0.068, 0.076, 0.066, -0.004], [0.066, 0.092, 0.098, 0.094, -0.002],
		[0.118, 0.102, 0.104, 0.108, 0.002], [0.168, 0.098, 0.096, 0.104, 0.004], [0.208, 0.074, 0.072, 0.078, 0.004], [0.230, 0.020, 0.020, 0.020, 0.004]]
	var hr := []
	for i in head_st.size():
		var h: Array = head_st[i]
		var band := i == 3
		hr.append({"c": hd * Vector3(0, h[0], h[4]), "x": hd.basis.x, "z": hd.basis.z, "rx": h[1], "rzf": h[2], "rzb": h[3], "w": {"head": 1.0},
			"col": CERAMIC_LIGHT})
	_tube(hr, 22, 2)
	_blob("head", Vector3(0, 0.136, -0.097), Vector3(0.062, 0.007, 0.010), FACE_BAND, 14, 4)     # brow band (above the eyes now)
	_face()     # (head upgrade) eyes, lids, mouth and chin
	# arms and legs
	for sd in ["l", "r"]:
		var ua: Transform3D = B["upperarm_" + sd]
		var la: Transform3D = B["lowerarm_" + sd]
		var hn: Transform3D = B["hand_" + sd]
		_limb("upperarm_" + sd, "spine_03", "lowerarm_" + sd, ua.origin.distance_to(la.origin), 0.041, 0.035, 0.029)
		_limb("lowerarm_" + sd, "upperarm_" + sd, "hand_" + sd, la.origin.distance_to(hn.origin), 0.030, 0.027, 0.022)
		_blob("upperarm_" + sd, Vector3(0, 0.0, 0), Vector3(0.042, 0.040, 0.042), CERAMIC_LIGHT)     # shoulder cap
		var side := -1.0 if sd == "l" else 1.0
		_blob("hand_" + sd, Vector3(0, 0.040, -0.003), Vector3(0.028, 0.046, 0.013), CERAMIC_LIGHT)
		_blob("hand_" + sd, Vector3(0, 0.082, -0.004), Vector3(0.022, 0.028, 0.010), CERAMIC_LIGHT)
		_blob("hand_" + sd, Vector3(side * 0.026, 0.034, -0.010), Vector3(0.010, 0.022, 0.009), CERAMIC_MID, 8, 6)
		var th: Transform3D = B["thigh_" + sd]
		var cf: Transform3D = B["calf_" + sd]
		var ft: Transform3D = B["foot_" + sd]
		_limb("thigh_" + sd, "pelvis", "calf_" + sd, th.origin.distance_to(cf.origin), 0.064, 0.054, 0.041)
		_limb("calf_" + sd, "thigh_" + sd, "foot_" + sd, cf.origin.distance_to(ft.origin), 0.043, 0.038, 0.026)
		_hip(sd, th)
		# foot (the rigid mannequin's foot, in the foot frame): heel and arch on the foot, the front on the toe bone
		_blob("foot_" + sd, Vector3(0, 0.008, -0.016), Vector3(0.028, 0.036, 0.030), CERAMIC_LIGHT, 12, 8, ft)
		_blob("foot_" + sd, Vector3(0, 0.060, -0.028), Vector3(0.031, 0.058, 0.022), CERAMIC_LIGHT, 14, 8, ft)
		_blob("ball_" + sd, Vector3(0, 0.124, -0.034), Vector3(0.029, 0.032, 0.016), CERAMIC_LIGHT, 12, 8, ft)
		_box("foot_" + sd, ft, Vector3(0, 0.042, -0.046), Vector3(0.056, 0.136, 0.012), SOLE_SLATE)
		_box("ball_" + sd, ft, Vector3(0, 0.126, -0.046), Vector3(0.054, 0.034, 0.012), SOLE_SLATE)
	st.generate_normals()
	var m := st.commit()
	mi.mesh = m
	var skin := Skin.new()
	for b in BONES:
		skin.add_bind(idx[b], B[b].affine_inverse())
	mi.skin = skin
	mi.skeleton = mi.get_path_to(skel)
	bound = true

# ------------------------------------------------------------------ head upgrade BEGIN: the face (stand-in)
const SCLERA := Color(0.95, 0.95, 0.93)
const IRIS := Color(0.20, 0.33, 0.42)
const PUPIL := Color(0.03, 0.03, 0.04)
const LASH := Color(0.16, 0.18, 0.21)
const MOUTH := Color(0.30, 0.13, 0.13)
const RIG := preload("res://core/m04_body/body_rig.gd")

## eyes (spheres with the pole at the pupil, so the iris and pupil are clean circles), upper lids (shells round each
## eye on the lid bones, a lash line on the edge), lower lids (fixed shells on the head), the mouth (its lower half on
## the jaw, so it opens) and the chin (on the jaw)
func _face() -> void:
	for sd in ["l", "r"]:
		var e: Transform3D = B["eye_" + sd]
		var rings := [[0.0, PUPIL], [0.17, PUPIL], [0.21, IRIS], [0.38, IRIS], [0.43, SCLERA], [0.75, SCLERA], [1.1, SCLERA], [1.6, SCLERA], [2.2, SCLERA], [PI, SCLERA]]
		var segs := 20
		var base := nv
		for rg in rings:
			for k in segs:
				var th := TAU * k / segs
				var ph: float = rg[0]
				_v(e * (Vector3(sin(ph) * cos(th), sin(ph) * sin(th), -cos(ph)) * RIG.EYE_RADIUS), rg[1], {"eye_" + sd: 1.0})
		for i in rings.size() - 1:
			for k in segs:
				var a := base + i * segs + k
				var b := base + i * segs + (k + 1) % segs
				_quad(a, a + segs, b + segs, b)
		# upper lid: edge (elevation 0 in the lid frame) up over the top; lower lid: from the closed edge down, on the head
		_shell("lid_" + sd, B["lid_" + sd], 0.0, 2.2, {"lid_" + sd: 1.0}, true)
		var ec: Vector3 = (B["head"] as Transform3D) * (RIG.EYE_L if sd == "l" else RIG.EYE_R)
		_shell("head", Transform3D((B["head"] as Transform3D).basis, ec), RIG.LID_CLOSED, -1.9, {"head": 1.0}, true)
	var hd: Transform3D = B["head"]
	var jw: Transform3D = B["jaw"]
	_blob("jaw", jw.affine_inverse() * (hd * Vector3(0, 0.016, -0.056)), Vector3(0.036, 0.017, 0.024), CERAMIC_LIGHT, 14, 8)
	# mouth: a dark lens on the face, upper half on the head, lower half on the jaw
	var base2 := nv
	var mc := Vector3(0, 0.041, -0.084)
	var mr := Vector3(0.019, 0.0045, 0.007)
	for ri in 7:
		var phi := float(ri) / 6.0 * PI
		for si in 12:
			var th := float(si) / 12.0 * TAU
			var nn := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			var wj := clampf(0.5 - nn.y * 0.9, 0.0, 1.0)
			_v(hd * (mc + nn * mr), MOUTH, {"head": 1.0 - wj + 1e-4, "jaw": wj + 1e-4})
	for ri in 6:
		for si in 12:
			var a := base2 + ri * 12 + si
			var b := base2 + ri * 12 + (si + 1) % 12
			_quad(a, a + 12, b + 12, b)

## a spherical shell of LID_RADIUS round the frame's origin, from elevation e0 to e1 (frame's front = -z), the front
## +-100 deg; the e0 row is the lash line. Both faces (it is thin).
func _shell(bone: String, fr: Transform3D, e0: float, e1: float, w: Dictionary, lash: bool) -> void:
	var rows := 9
	var segs := 16
	for face in [0, 1]:
		var r: float = RIG.LID_RADIUS if face == 0 else RIG.LID_RADIUS - 0.0004
		var base := nv
		for i in rows + 1:
			var el := lerpf(e0, e1, float(i) / rows)
			var col: Color = LASH if (lash and i == 0) else CERAMIC_MID
			for k in segs + 1:
				var az := lerpf(-1.75, 1.75, float(k) / segs)
				_v(fr * (Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el)) * r), col, w)
		for i in rows:
			for k in segs:
				var a := base + i * (segs + 1) + k
				var b := a + 1
				var c := a + segs + 1
				var d := c + 1
				if (face == 0) == (e1 > e0): _quad(a, c, d, b)
				else: _quad(a, b, d, c)
# ------------------------------------------------------------------ head upgrade END

## the hip: a pelvis-coloured cuff that wraps the top of the thigh into the pelvis floor (weights shared, so it stretches, no seam)
func _hip(sd: String, th: Transform3D) -> void:
	var base := nv
	var segs := 14
	var rings := 8
	for ri in rings + 1:
		var phi := float(ri) / rings * PI
		for si in segs:
			var a := float(si) / segs * TAU
			var nn := Vector3(sin(phi) * cos(a), cos(phi), sin(phi) * sin(a))
			var lp := Vector3(0, 0.010, 0) + nn * Vector3(0.070, 0.060, 0.070)
			var t := clampf((0.05 - lp.y) / 0.11, 0.0, 1.0)     # +y runs down the thigh: the knee side follows the thigh, the top the pelvis
			_v(th * lp, CERAMIC_LIGHT, {"thigh_" + sd: 1.0 - 0.6 * t, "pelvis": 0.6 * t})
	for ri in rings:
		for si in segs:
			var i0 := base + ri * segs + si
			var i1 := base + ri * segs + (si + 1) % segs
			_quad(i0, i0 + segs, i1 + segs, i1)

func _box(bone: String, frame: Transform3D, c: Vector3, s: Vector3, col: Color) -> void:
	var h := s * 0.5
	var cs := [Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1),
		Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]
	var faces := [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
	for f in faces:
		var ids := []
		for k in f: ids.append(_v(frame * (c + cs[k] * h), col, {bone: 1.0}))
		_quad(ids[0], ids[1], ids[2], ids[3])
