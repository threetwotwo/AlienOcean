## Sea spray 0.1.0 (adapters/godot; water surface thread, 28 Nov 2026): the open-water tank's spray and spume, the
## sprite kit's mesh and its material (look/sea_spray.gdshader, which says what it ports). The mesh is the tank's
## SM_OO_Sprites (tools/make_sprite_mesh.py), built here instead of imported: 64 x 64 cells x 8 slots of quads
## (32,768 quads), and nothing but where each vertex is says what it is: cell (i, j) at i, j metres (-32..31), slot s
## at s x 10 cm up, each corner 1 cm off its point. Nothing is simulated per frame: the vertex shader works every
## sprite out from its world cell (1.5 m), its slot, the sea's clock and the foam map's break clock (sea_foam .b), and
## folds the quads that are not drawn onto a point. This node only hands the shader the tank's Kit (the sea's clock,
## the frame time) and SeaK (Hs, the breaking speed, the wind) each frame, and keeps the mesh at the eye so it is
## never culled.
## The spume's puffs: assets/sea/T_OO_Spume.png, made by the tank's tools/make_spume_atlas.py unchanged (4 x 4 tiles
## of 256, R = density); its mips are made here on load, so the import settings do not matter.
## Use: a child of SeaSurface (which adds one). amount 0 hides it.
class_name SeaSpray
extends Node3D

const KIT_CELLS := 64
const KIT_SLOTS := 8
const SPUME_PATH := "res://assets/sea/T_OO_Spume.png"
var amount := 1.0                # the tank's Spray.x (SprayAmount): the share of slots in use
var sprite_size := 1.0           # the tank's Spray.z (SpriteSize)
var mesh_instance: MeshInstance3D
var mat: ShaderMaterial

func _init() -> void:
	name = "SeaSpray"
	mesh_instance = MeshInstance3D.new(); mesh_instance.name = "SprayMesh"
	mesh_instance.mesh = sprite_mesh(KIT_CELLS, KIT_SLOTS)
	mat = ShaderMaterial.new(); mat.shader = load("res://look/sea_spray.gdshader")
	mat.render_priority = 2      # after the sea seen from above (1): spray is in front of the water it flies over
	var tex := _spume()
	if tex: mat.set_shader_parameter("spume", tex)
	mesh_instance.material_override = mat
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the vertex shader puts the quads round the camera (96 m square): never cull them
	mesh_instance.custom_aabb = AABB(Vector3(-200, -200, -200), Vector3(400, 400, 400))
	mesh_instance.layers = 1 << (SeaFloorMap.SEA_LAYER - 1)   # never in the floor map's captures
	add_child(mesh_instance)

func _process(dt: float) -> void:
	var fft: FftSea = get_parent().get("fft") if get_parent() else null
	if fft == null: return
	var U: float = fft.foam.get("U", 0.0)
	# drops start at 3 m/s; without whitecaps (sea_foam_k.x = -10) the break clock never starts
	mesh_instance.visible = amount > 0.0 and fft.foam_on and fft.ready_ok and U > 3.0 and fft.foam.get("on", true)
	if not mesh_instance.visible: return
	var cam := get_viewport().get_camera_3d()
	if cam: global_position = cam.global_position
	mat.set_shader_parameter("kit", Vector4(fft.time_s, clampf(dt, 1.0 / 120.0, 1.0 / 20.0), 0.0, 0.0))
	mat.set_shader_parameter("sea_k", Vector4(0.0, fft.moments.get("hs", 0.0), fft.foam.get("cbreak", 2.0), U))
	mat.set_shader_parameter("spray", Vector4(amount, 1.0, sprite_size, 1.0))

static func sprite_mesh(cells: int, slots: int) -> ArrayMesh:
	## make_sprite_mesh.py: island (i + 0.01 cx, j + 0.01 cy, 0.1 s) -> Godot (x, z, -y)
	var n := cells * cells * slots
	var verts := PackedVector3Array(); verts.resize(n * 4)
	var idx := PackedInt32Array(); idx.resize(n * 6)
	var h := cells / 2
	var q := 0
	for s in slots:
		for j in range(-h, h):
			for i in range(-h, h):
				var b := q * 4
				verts[b] = Vector3(i - 0.01, 0.1 * s, -(j - 0.01))
				verts[b + 1] = Vector3(i + 0.01, 0.1 * s, -(j - 0.01))
				verts[b + 2] = Vector3(i + 0.01, 0.1 * s, -(j + 0.01))
				verts[b + 3] = Vector3(i - 0.01, 0.1 * s, -(j + 0.01))
				var k := q * 6
				idx[k] = b; idx[k + 1] = b + 2; idx[k + 2] = b + 1
				idx[k + 3] = b; idx[k + 4] = b + 3; idx[k + 5] = b + 2
				q += 1
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts; arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new(); m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m

static func _spume() -> Texture2D:
	var src := load(SPUME_PATH) as Texture2D
	if src == null:
		push_warning("SeaSpray: %s missing, the spume is not drawn" % SPUME_PATH)
		return null
	var img := src.get_image()
	if img.is_compressed(): img.decompress()
	img.convert(Image.FORMAT_R8)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
