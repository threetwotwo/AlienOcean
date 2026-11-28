## Sea surface 0.2.0 (0.2.0, 28 Nov: the underside in the transparent pass, globals()) (adapters/godot; water surface thread, 27 Nov 2026): the drawn sea. One FFT sea (FftSea, the
## Unreal lagoon's) and one mesh of nested square rings that the vertex shader re-centres on the camera every frame
## (lagoonwater v98 sea_obj / LW_VS_HLSL: ring 0 a 2nq x 2nq grid of 6.25 cm, ring l the annulus between nq/2 and nq
## quads of 6.25 cm x 2^l; 15 rings reach 32 km), so the sea goes wherever the eye goes: open world, no level loads,
## nothing to stream. Materials: look/sea_under.gdshader (opaque, seen from below) with look/sea_top.gdshader as its
## next pass (transparent, seen from above). SeaFloorMap gives the mirror the floor where its rays land.
## Use: var sea := SeaSurface.new(); world.add_child(sea)   (WorldRoot.make_surface() returns one.)
class_name SeaSurface
extends Node3D

const NQ := 32
const LEVELS := 15
const D0 := 0.0625
var fft: FftSea
var mesh_instance: MeshInstance3D
var under_mat: ShaderMaterial
var top_mat: ShaderMaterial
var floor_map: SeaFloorMap
static var _globals_done := false

func _init() -> void:
	name = "SeaSurface"
	globals()
	fft = FftSea.new(); add_child(fft)
	mesh_instance = MeshInstance3D.new(); mesh_instance.name = "SeaMesh"
	mesh_instance.mesh = ring_mesh(NQ, LEVELS, D0)
	under_mat = ShaderMaterial.new(); under_mat.shader = load("res://look/sea_under.gdshader")
	top_mat = ShaderMaterial.new(); top_mat.shader = load("res://look/sea_top.gdshader")
	# after the underwater view's full-screen quad (it copies the opaque screen back when the eye is above the water).
	# The underside too (0.2.0): it reads the scene behind it (a body above the water, seen through Snell's window), so it
	# is drawn in the transparent pass and adds the eye's own water path itself, over the quad's
	top_mat.render_priority = 1
	under_mat.render_priority = 1
	under_mat.next_pass = top_mat
	mesh_instance.material_override = under_mat
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED   # the sea is a light boundary, not a solid: never in SDFGI
	# the vertex shader moves the rings to the camera: never cull them
	mesh_instance.custom_aabb = AABB(Vector3(-1e5, -1e3, -1e5), Vector3(2e5, 2e3, 2e5))
	mesh_instance.layers = 1 << (SeaFloorMap.SEA_LAYER - 1)   # never in the floor map's captures
	add_child(mesh_instance)
	floor_map = SeaFloorMap.new(); add_child(floor_map)
	# the tank's spray and spume off the breaking crests (SeaSpray: the sprite kit; drawn after the sea's top side)
	add_child(SeaSpray.new())

func _exit_tree() -> void:
	WaterlineEffect.sea_on = false        # no sea drawn: no waterline, and the underwater view draws every pixel itself

static func globals() -> void:
	## the eye's values the underside needs for its own water path (WorldRoot sets them, as on the underwater view):
	## sea_eye_wave = the wave over the still level at the eye (m), sea_god = (god rays on 0/1, frame mod 8, frames averaged 0/1, a sea is drawn 0/1)
	if _globals_done: return
	_globals_done = true
	RenderingServer.global_shader_parameter_add(&"sea_eye_wave", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	RenderingServer.global_shader_parameter_add(&"sea_god", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(1.0, 0.0, 0.0, 0.0))

func _process(_dt: float) -> void:
	# the per-pixel waterline at the lens (WaterlineEffect) reads this sea's waves
	WaterlineEffect.sea_on = visible and is_visible_in_tree()
	if fft.disp_tex: WaterlineEffect.disp_rid = fft.disp_tex.texture_rd_rid
	WaterlineEffect.patch = fft.patch
	WaterlineEffect.hs = float(fft.moments.get("mom_r", Vector4.ZERO).w) if fft.moments is Dictionary else 0.0
	var cam := get_viewport().get_camera_3d()
	if cam: floor_map.follow(cam.global_position)

static func ring_mesh(nq: int, levels: int, d0: float) -> ArrayMesh:
	## v98 sea_obj(): ring 0 = 2nq x 2nq quads of d0; ring l = the annulus nq/2 .. nq quads of d0 2^l.
	## Godot (x, 0, z) with island y = -z; triangles alternate their diagonal (v98's (i + j) & 1).
	var verts := PackedVector3Array(); var idx := PackedInt32Array()
	for level in levels:
		var d := d0 * pow(2.0, level)
		var inner := 0 if level == 0 else nq / 2
		var index := {}
		var vid := func(i: int, j: int) -> int:
			var k := Vector2i(i, j)
			if not index.has(k):
				index[k] = verts.size()
				verts.append(Vector3(i * d, 0.0, -j * d))
			return index[k]
		for j in range(-nq, nq):
			for i in range(-nq, nq):
				if inner > 0 and i >= -inner and i < inner and j >= -inner and j < inner: continue
				var a: int = vid.call(i, j); var b: int = vid.call(i + 1, j)
				var c: int = vid.call(i + 1, j + 1); var e: int = vid.call(i, j + 1)
				# wound so the face looks up (+y) in Godot
				if (i + j) & 1: idx.append_array([a, c, b, a, e, c])
				else: idx.append_array([a, e, b, b, e, c])
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts; arr[Mesh.ARRAY_INDEX] = idx
	var nrm := PackedVector3Array(); nrm.resize(verts.size()); nrm.fill(Vector3.UP); arr[Mesh.ARRAY_NORMAL] = nrm
	var m := ArrayMesh.new(); m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m
