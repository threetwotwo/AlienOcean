## Creature school mesh 0.2.0 (r2 export: swim envelopes at three speeds): turns a creature maker export (res://assets/creatures/<species>/fish.glb, fish_LOD1.glb,
## fish_LOD2.glb; editor-imported) into one static ArrayMesh per LOD for a MultiMesh school, plus its swim extras.
## The maker's frame (extras.alien_ocean.swim.frame): metres, snout at the origin, facing glTF -X, y up, s = x / body_length.
## The school frame (same as the stand-in, fish/school_fish*.gdshader): one body length long, head toward +x, centred
## (x = 0.5 - s), y up; that is a turn of 180 deg about y (x -> -x, z -> -z) and a scale of 1 / body_length.
## Every MeshInstance3D surface is merged by material name (body, interior, cornea, eye, fins): at most five surfaces, so
## a school is a handful of draw calls a LOD. The skin is dropped (the swim wave runs in the vertex shader instead).
extends RefCounted

const LOD_FILES := ["fish.glb", "fish_LOD1.glb", "fish_LOD2.glb"]
const SHADER := preload("res://fish/creature_school.gdshader")

static func dir_of(species: String) -> String:
	return "res://assets/creatures/%s/" % species

static func available(species: String) -> bool:
	return species != "" and ResourceLoader.exists(dir_of(species) + LOD_FILES[0])

static func _all(n: Node) -> Array:
	var a := [n]
	for c in n.get_children(): a += _all(c)
	return a

## {meshes: [ArrayMesh x3], swim: Dictionary, bl_m: float} or {} when the species has no export.
static func load_species(species: String, look := {}) -> Dictionary:
	if not available(species): return {}
	var out := {"meshes": [], "swim": {}, "bl_m": 0.0}
	var mats := {}          # material name -> ShaderMaterial (shared by the three LODs)
	for li in 3:
		var path: String = dir_of(species) + LOD_FILES[li]
		if not ResourceLoader.exists(path): path = dir_of(species) + LOD_FILES[0]
		var sc: Node = (load(path) as PackedScene).instantiate()
		if li == 0:
			var rig := sc.get_node_or_null("rig")
			if rig and rig.has_meta("extras"):
				var ex = rig.get_meta("extras")
				if ex is Dictionary and ex.has("alien_ocean"): out.swim = ex.alien_ocean.get("swim", {})
		var bl: float = float(out.swim.get("body_length_m", 0.0))
		var groups := {}    # material name -> {v, n, t, uv, idx, src}
		for nd in _all(sc):
			if not nd is MeshInstance3D: continue
			var m: Mesh = nd.mesh
			if bl <= 0.0 and String(nd.name).begins_with("body"): bl = m.get_aabb().size.x
			for si in m.get_surface_count():
				var mat: Material = m.surface_get_material(si)
				var key: String = String(mat.resource_name) if mat and mat.resource_name != "" else "surf"
				if not groups.has(key):
					groups[key] = {"v": PackedVector3Array(), "n": PackedVector3Array(), "t": PackedFloat32Array(),
						"uv": PackedVector2Array(), "idx": PackedInt32Array(), "src": mat}
				var g: Dictionary = groups[key]
				var arr := m.surface_get_arrays(si)
				var base: int = g.v.size()
				var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var ns = arr[Mesh.ARRAY_NORMAL]
				var ts = arr[Mesh.ARRAY_TANGENT]
				var uvs = arr[Mesh.ARRAY_TEX_UV]
				var xf: Transform3D = nd.transform
				for k in vs.size():
					var p: Vector3 = xf * vs[k]
					g.v.append(p)
					g.n.append((xf.basis * ns[k]).normalized() if ns != null else Vector3.UP)
					g.uv.append(uvs[k] if uvs != null else Vector2.ZERO)
					if ts != null and ts.size() >= 4 * (k + 1):
						g.t.append_array(PackedFloat32Array([ts[4 * k], ts[4 * k + 1], ts[4 * k + 2], ts[4 * k + 3]]))
					else:
						g.t.append_array(PackedFloat32Array([1, 0, 0, 1]))
				var ids = arr[Mesh.ARRAY_INDEX]
				if ids == null:
					for k in vs.size(): g.idx.append(base + k)
				else:
					for q in ids: g.idx.append(base + q)
		sc.free()
		if bl <= 0.0: return {}
		out.bl_m = bl
		var am := ArrayMesh.new()
		for key in groups:
			var g: Dictionary = groups[key]
			var v2 := PackedVector3Array(); v2.resize(g.v.size())
			var n2 := PackedVector3Array(); n2.resize(g.n.size())
			var t2: PackedFloat32Array = g.t.duplicate()
			for k in g.v.size():
				var p: Vector3 = g.v[k]
				v2[k] = Vector3(0.5 - p.x / bl, p.y / bl, -p.z / bl)       # 180 deg about y, one body length, centred
				var nn: Vector3 = g.n[k]
				n2[k] = Vector3(-nn.x, nn.y, -nn.z)
				t2[4 * k] = -t2[4 * k]; t2[4 * k + 2] = -t2[4 * k + 2]       # a proper turn keeps the bitangent sign
			var arr2 := []; arr2.resize(Mesh.ARRAY_MAX)
			arr2[Mesh.ARRAY_VERTEX] = v2; arr2[Mesh.ARRAY_NORMAL] = n2; arr2[Mesh.ARRAY_TANGENT] = t2
			arr2[Mesh.ARRAY_TEX_UV] = g.uv; arr2[Mesh.ARRAY_INDEX] = g.idx
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr2)
			if not mats.has(key): mats[key] = _material(g.src, out.swim, look)
			am.surface_set_material(am.get_surface_count() - 1, mats[key])
		out.meshes.append(am)
	return out

## The maker's PBR material, with the swim wave from its extras.
static func _material(src: Material, swim: Dictionary, look: Dictionary) -> ShaderMaterial:
	var sm := ShaderMaterial.new(); sm.shader = SHADER
	if src is StandardMaterial3D:
		var s3: StandardMaterial3D = src
		sm.set_shader_parameter("albedo", s3.albedo_color)
		if s3.albedo_texture: sm.set_shader_parameter("albedo_tex", s3.albedo_texture); sm.set_shader_parameter("use_albedo_tex", 1.0)
		if s3.normal_enabled and s3.normal_texture:
			sm.set_shader_parameter("normal_tex", s3.normal_texture); sm.set_shader_parameter("use_normal_tex", 1.0)
			sm.set_shader_parameter("normal_scale", s3.normal_scale)
		sm.set_shader_parameter("metallic", s3.metallic)
		sm.set_shader_parameter("roughness", s3.roughness)
		if s3.metallic_texture: sm.set_shader_parameter("metallic_tex", s3.metallic_texture); sm.set_shader_parameter("use_mr_tex", 1.0)
		if s3.roughness_texture: sm.set_shader_parameter("roughness_tex", s3.roughness_texture); sm.set_shader_parameter("use_mr_tex", 1.0)
	# three envelope tables at env_u (wave.envelopes_by_speed, r2); an older export has one table, used at every speed
	var w: Dictionary = swim.get("wave", {})
	var sets: Array = []
	var us := PackedFloat32Array()
	for e in w.get("envelopes_by_speed", []):
		sets.append(e.rows); us.append(float(e.U_BLps))
	if sets.is_empty():
		var one: Array = w.get("amplitude_envelope_BL", [])
		sets = [one, one, one]; us = PackedFloat32Array([1.0, 2.0, 3.0])
	while sets.size() < 3: sets.append(sets[sets.size() - 1]); us.append(us[us.size() - 1] + 1.0)
	var es := PackedFloat32Array()
	for j in 3:
		var rows: Array = sets[j]
		var ea := PackedFloat32Array(); var el := PackedFloat32Array()
		for r in rows:
			if j == 0: es.append(r[0])
			ea.append(r[1]); el.append(r[2] if r.size() > 2 else float(r[0]) / float(w.get("lam_BL", 1.0)))
		while ea.size() < 16:       # pad (the shader reads env_n rows)
			ea.append(ea[ea.size() - 1] if ea.size() > 0 else 0.0); el.append(el[el.size() - 1] if el.size() > 0 else 0.0)
		sm.set_shader_parameter("env_a%d" % j, ea); sm.set_shader_parameter("env_lag%d" % j, el)
	var n_rows: int = es.size()
	while es.size() < 16: es.append(1.0)
	sm.set_shader_parameter("env_s", es)
	sm.set_shader_parameter("env_u", Vector3(us[0], us[1], us[2]))
	sm.set_shader_parameter("env_n", n_rows)
	for k in look: sm.set_shader_parameter(k, look[k])
	return sm

## Swim playback from the extras. Speeds in BL/s.
static func has_speed_envelopes(swim: Dictionary) -> bool:
	return swim.get("wave", {}).get("envelopes_by_speed", []).size() > 0

## Below this speed the maker's engine swims burst-and-coast phrases, not a steady wave (steady.U_min_BLps); 0 = none.
static func u_min(swim: Dictionary) -> float:
	return float(swim.get("steady", {}).get("U_min_BLps", 0.0))

## Beat frequency (Hz) at U. With r2 envelopes: through their measured (U, beat_Hz) points, the end slopes carried on
## (the beat law is linear in U, so this is the law itself); otherwise the beat_law record.
static func beat_hz(swim: Dictionary, U: float) -> float:
	var es: Array = swim.get("wave", {}).get("envelopes_by_speed", [])
	if es.size() >= 2:
		var j := 1
		while j < es.size() - 1 and U > float(es[j].U_BLps): j += 1
		var u0 := float(es[j - 1].U_BLps); var u1 := float(es[j].U_BLps)
		var f0 := float(es[j - 1].beat_Hz); var f1 := float(es[j].beat_Hz)
		return maxf(0.3, f0 + (f1 - f0) * (U - u0) / maxf(u1 - u0, 1e-5))
	var b: Dictionary = swim.get("beat_law", {})
	if b.is_empty(): return (4.0 * U + 4.0) / 3.0
	return float(b.f_rec_Hz) * (float(b.c_BLps) + U) / (float(b.c_BLps) + float(b.U_rec_BLps))

## Amplitude scale A_U / A. r2 envelopes already carry amp_law per speed, so 1 there.
static func amp_scale(swim: Dictionary, U: float) -> float:
	if has_speed_envelopes(swim): return 1.0
	var a: Dictionary = swim.get("amp_law", {})
	if a.is_empty(): return 1.0
	return clampf(float(a.ampMin) + (1.0 - float(a.ampMin)) * U / float(a.ampU1), 0.0, 1.0)
