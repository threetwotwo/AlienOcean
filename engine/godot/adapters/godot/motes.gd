## Motes (look thread, 28 Nov 2026): marine snow around the eye under water (look/motes.gdshader). One MultiMesh of tiny
## billboards; their seed positions fill a box that the shader wraps around the camera, so nothing here follows the eye.
## density: particles per cubic metre big enough to see (> 0.5 mm). Real clear tropical lagoon water holds roughly 1-10 such
## aggregates per litre near reefs (Alldredge & Silver 1988; far more in turbid water); we draw far fewer, the ones near
## enough to resolve. AO_MOTES=0 in the shot tool turns them off.
class_name Motes
extends MultiMeshInstance3D

@export var density := 40.0
@export var box_m := 6.0

func _init(dens := 40.0, box := 6.0) -> void:
	name = "Motes"; density = dens; box_m = box
	var qm := QuadMesh.new(); qm.size = Vector2(1, 1)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = qm
	var n := int(density * box_m * box_m * box_m)
	mm.instance_count = n
	var rng := RandomNumberGenerator.new(); rng.seed = 2811
	for i in n:
		mm.set_instance_transform(i, Transform3D.IDENTITY)
		mm.set_instance_custom_data(i, Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()))
	multimesh = mm
	var mat := ShaderMaterial.new(); mat.shader = load("res://look/motes.gdshader")
	mat.set_shader_parameter("box_m", box_m)
	mat.render_priority = 1          # after the underwater view quad (it repaints the whole screen)
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	extra_cull_margin = 16384.0     # positions are made in the shader, around the eye
	layers = 1 << 3                 # the eye's own layer (the sea floor map's captures skip it)
