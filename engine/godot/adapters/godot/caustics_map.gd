## Caustics map 0.2.0 (engine thread): the light net drawn once a frame into a small tile, as the Unreal lagoon did
## (lagoonwater v98: RT_LW_CausS1..3 -> RT_LW_CausRaw -> RT_LW_Caus, 512 px over the 2.56 m tile, r g b = 0.8, 2, 5 m).
## Three passes, each a SubViewport with one full-size ColorRect: the waves' slope in the mip each depth reads
## (look/caustics_slope.gdshader, 128 / 64 / 32 px), the focus (look/caustics_focus.gdshader) and the sun's disc
## (look/caustics_blur.gdshader). The result is the global sampler water_caus_map, read by look/caustics.gdshaderinc.
## The slopes are the FFT sea's own while it runs (global sea_on, adapters/godot/fft_sea.gd: cascade 2 is this tile,
## cascade 3 repeats 8 times over it), as in v98; otherwise the 32 waves of look/caustic_waves.gdshaderinc. from_sea =
## false keeps the 32 waves even with the sea (checks); the net then no longer matches the drawn surface.
## Owned by WorldRoot (.caustics). per_pixel = true switches every reader back to the per-pixel maths (checks);
## frozen_time >= 0 holds the net at that second (stills, comparisons), -1 = the engine's TIME.
class_name CausticsMap
extends Node

const PX := 512                       # v98 CAUS_PX
const SLOPE_PX := [128, 64, 32]       # v98 CAUS_MIPS[1..3]: 2, 4 and 8 cm texels over the tile
var slope_vps: Array[SubViewport] = []
var focus_vp: SubViewport
var map_vp: SubViewport
var per_pixel := false:
	set(v):
		per_pixel = v; _push()
var from_sea := true:
	set(v):
		from_sea = v
		for vp: SubViewport in slope_vps: _mat(vp).set_shader_parameter("from_sea", 1.0 if v else 0.0)
var frozen_time := -1.0:
	set(v):
		frozen_time = v; _push()

static func _pass(px: int, shader_path: String) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(px, px); vp.disable_3d = true; vp.use_hdr_2d = true      # RGBA16F: slopes are signed, a focus reaches 12
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	var mat := ShaderMaterial.new(); mat.shader = load(shader_path)
	var rect := ColorRect.new(); rect.size = Vector2(px, px); rect.material = mat
	vp.add_child(rect)
	return vp

static func _mat(vp: SubViewport) -> ShaderMaterial:
	return (vp.get_child(0) as ColorRect).material as ShaderMaterial

func _init() -> void:
	name = "CausticsMap"
	FftSea.declare_globals()   # the slope pass reads sea_deriv / sea_patch / sea_on; they must exist before it compiles
	# in the order they feed each other, so one frame's waves reach the map in that frame
	for i in SLOPE_PX.size():
		var vp := _pass(SLOPE_PX[i], "res://look/caustics_slope.gdshader")
		vp.name = "Slope%d" % (i + 1); _mat(vp).set_shader_parameter("level", i)
		slope_vps.append(vp); add_child(vp)
	focus_vp = _pass(PX, "res://look/caustics_focus.gdshader"); focus_vp.name = "Focus"; add_child(focus_vp)
	map_vp = _pass(PX, "res://look/caustics_blur.gdshader"); map_vp.name = "Map"; add_child(map_vp)
	for i in SLOPE_PX.size():
		_mat(focus_vp).set_shader_parameter("s%d" % (i + 1), slope_vps[i].get_texture())
	_mat(map_vp).set_shader_parameter("src", focus_vp.get_texture())

func _enter_tree() -> void:
	RenderingServer.global_shader_parameter_set("water_caus_map", map_vp.get_texture().get_rid())
	_push()

func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set("water_caus_k", Vector4(0.0, frozen_time, 0.0, 0.0))   # no map: per pixel

func _push() -> void:
	if not is_inside_tree(): return
	RenderingServer.global_shader_parameter_set("water_caus_k", Vector4(0.0 if per_pixel else 1.0, frozen_time, 0.0, 0.0))
	var mode := SubViewport.UPDATE_DISABLED if per_pixel else SubViewport.UPDATE_ALWAYS
	for vp: SubViewport in slope_vps: vp.render_target_update_mode = mode
	focus_vp.render_target_update_mode = mode; map_vp.render_target_update_mode = mode
