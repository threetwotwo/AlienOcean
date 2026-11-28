## Sea floor map 0.1.4 (adapters/godot; water surface thread, 27 Nov 2026): what lies under the sea round the eye, seen
## straight down: its light (radiance, nits, as the world's own shaders light it at its depth: sun, net, sky, sand
## bounce) and its top height, for the mirror in the underside of the surface (where a reflected ray really lands:
## sand, grass, rock; lagoonwater v73/v87 read a baked floor map of the slice the same way, with stand-in colours).
## Godot version: two orthographic captures from above of everything except the sea (visual layer 2), the eye's quads
## (layer 4) and this map's own height pass (layer 3): radiance at exposure x 1, height from the depth buffer. Re-centred on the eye
## (snapped) whenever it moves far enough, so it follows the eye through an open world with nothing baked or streamed.
## Shader globals: water_floor_albedo (sampler2D: the floor's radiance in nits, linear; alpha 0 = nothing there),
## water_floor_height (sampler2D: world y = r / g, alpha 0 = nothing there),
## water_floor_org (vec4: centre x, centre z, size m, 1 = valid), water_floor_mean (vec4: the mean radiance, nits; 1 = valid).
class_name SeaFloorMap
extends Node3D

const SEA_LAYER := 2           # visual layer the sea mesh sits on (never captured)
const PASS_LAYER := 3          # the height pass quad (only the height capture sees it)
const EYE_LAYER := 4           # the eye's own full-screen quads (WorldRoot.attach_camera: the underwater view)
const ALTITUDE := 60.0       # m: the captures look down from here (world y), to 100 m below sea level
@export var size_m := 96.0
@export var res := 512
@export var recentre_m := 12.0
@export var snap_m := 8.0
var centre := Vector2(INF, INF)
var _vp_alb: SubViewport
var _vp_h: SubViewport
var _cams := []
var _pending := 0
var _env: Environment
var frozen := false            # no more captures (tools/perf_runner/teleport_stress.gd isolates the hang with it)
var _dirty := false            # the light changed (WorldRoot.apply): capture again where we are

func _init() -> void:
	name = "SeaFloorMap"
	declare_globals()
	var env := Environment.new(); _env = env
	env.background_mode = Environment.BG_COLOR; env.background_color = Color(0, 0, 0, 0)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	# exposure x 1 (Godot scales lit and debug-drawn materials by 1 / (1.2 x 2^EV100)): EV100 = log2(N^2 x shutter) =
	# log2(1 / 1.2) with f/22 (deep focus) at ISO 100 (as WorldRoot sets it: shutter = 2^EV / 22^2)
	var attr := CameraAttributesPhysical.new(); attr.auto_exposure_enabled = false
	attr.exposure_aperture = 22.0; attr.exposure_shutter_speed = 1.0 / (1.2 * 22.0 * 22.0); attr.exposure_sensitivity = 100.0
	attr.exposure_multiplier = 1.0
	for k in 2:
		var vp := SubViewport.new()
		vp.size = Vector2i(res, res); vp.use_hdr_2d = true; vp.transparent_bg = true
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		vp.msaa_3d = Viewport.MSAA_DISABLED; vp.positional_shadow_atlas_size = 0
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL; cam.size = size_m
		cam.near = 0.05; cam.far = ALTITUDE + 100.0
		cam.environment = env; cam.attributes = attr; cam.compositor = Compositor.new()
		cam.cull_mask = 0xFFFFF & ~(1 << (SEA_LAYER - 1)) & ~(1 << (PASS_LAYER - 1)) & ~(1 << (EYE_LAYER - 1))
		if k == 1: cam.cull_mask |= 1 << (PASS_LAYER - 1)
		vp.add_child(cam); add_child(vp); _cams.append(cam)
		if k == 0: _vp_alb = vp
		else: _vp_h = vp
	var q := MeshInstance3D.new(); q.name = "FloorHeightPass"
	var qm := QuadMesh.new(); qm.size = Vector2(2, 2); q.mesh = qm
	var mat := ShaderMaterial.new(); mat.shader = load("res://look/sea_floor_height.gdshader"); q.material_override = mat
	q.layers = 1 << (PASS_LAYER - 1); q.extra_cull_margin = 16384.0
	q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	q.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_cams[1].add_child(q)

static func declare_globals() -> void:
	if Engine.has_meta("floor_map_globals"): return
	var rs := RenderingServer
	rs.global_shader_parameter_add("water_floor_albedo", rs.GLOBAL_VAR_TYPE_SAMPLER2D, null)
	rs.global_shader_parameter_add("water_floor_height", rs.GLOBAL_VAR_TYPE_SAMPLER2D, null)
	rs.global_shader_parameter_add("water_floor_org", rs.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 96, 0))
	rs.global_shader_parameter_add("water_floor_mean", rs.GLOBAL_VAR_TYPE_VEC4, Vector4.ZERO)
	Engine.set_meta("floor_map_globals", true)

func _ready() -> void:
	RenderingServer.global_shader_parameter_set("water_floor_albedo", _vp_alb.get_texture())
	RenderingServer.global_shader_parameter_set("water_floor_height", _vp_h.get_texture())

func set_ambient(nits: Vector3) -> void:
	## the ambient the floor's shaders expect (WorldRoot.apply: the water's fill reference, nits): the captures run at
	## exposure x 1, so nits go in as they are. Without it the floor here was lit by the sun alone (no fill), and the
	## mirror under the surface read navy where it should show the bright sand (0.1.2, 28 Nov)
	var mx := maxf(nits.x, maxf(nits.y, nits.z))
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(nits.x / mx, nits.y / mx, nits.z / mx) if mx > 0.0 else Color.BLACK
	_env.ambient_light_energy = mx

func refresh() -> void:
	## the light changed (the hour, the eye going under or out): the radiance captured under the old light is stale,
	## so capture again on the next follow (28 Nov: at night the mirror still showed the day's floor, bright cyan)
	_dirty = true

func follow(eye: Vector3) -> void:
	## call each frame (or when the eye moves) with the eye
	if frozen: return
	var c := Vector2(eye.x, eye.z)
	if c.distance_to(centre) < recentre_m and _pending == 0 and not _dirty: return
	if _pending == 0:
		_dirty = false
		centre = (c / snap_m).round() * snap_m
		for cam in _cams:
			cam.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(centre.x, ALTITUDE, centre.y))
		_vp_alb.render_target_update_mode = SubViewport.UPDATE_ONCE
		_vp_h.render_target_update_mode = SubViewport.UPDATE_ONCE
		_pending = 2
		return
	_pending -= 1
	if _pending == 0:
		RenderingServer.global_shader_parameter_set("water_floor_org", Vector4(centre.x, centre.y, size_m, 1.0))
		_floor_mean()

var _mean_pending := false

func _floor_mean() -> void:
	## the floor's mean radiance in the map (nits; 32 x 32 samples, where something is drawn): the floor beyond the drawn
	## floor (look/sea_bathy.gdshaderinc) takes its brightness from it, so the drawn floor and the floor beyond meet without
	## a seam (0.1.3, 28 Nov). One read back per capture (the eye moving 12 m, or the light changing).
	## 0.1.4 (test level thread, 28 Nov): read back WITHOUT a stall (texture_get_data_async, one in flight; as fft_sea). The old
	## get_image() made the CPU wait for the GPU on every teleport and every light change, right where the Mac's Metal
	## "timeout waiting for fence" hangs came (4 of 11 bench runs, each just after a camera teleport).
	if _mean_pending: return
	var tex := RenderingServer.texture_get_rd_texture(_vp_alb.get_texture().get_rid())
	if not tex.is_valid(): return
	_mean_pending = true
	var w := _vp_alb.size.x; var h := _vp_alb.size.y
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		if rd == null: _mean_pending = false; return
		var fmt: RDTextureFormat = rd.texture_get_format(tex)
		rd.texture_get_data_async(tex, 0, func(data: PackedByteArray): _got_mean.call_deferred(data, w, h, fmt.format)))

func _got_mean(data: PackedByteArray, w: int, h: int, f: int) -> void:
	_mean_pending = false
	var half := f == RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var bpp := 8 if half else 16 if f == RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT else 4
	if data.size() < w * h * bpp: return
	var sum := Vector3.ZERO; var n := 0
	for y in range(w / 64, h, maxi(h / 32, 1)):
		for x in range(w / 64, w, maxi(w / 32, 1)):
			var i := (y * w + x) * bpp
			var c: Color
			if half: c = Color(data.decode_half(i), data.decode_half(i + 2), data.decode_half(i + 4), data.decode_half(i + 6))
			elif bpp == 16: c = Color(data.decode_float(i), data.decode_float(i + 4), data.decode_float(i + 8), data.decode_float(i + 12))
			else: c = Color(data[i] / 255.0, data[i + 1] / 255.0, data[i + 2] / 255.0, data[i + 3] / 255.0)
			if c.a > 0.5: sum += Vector3(c.r, c.g, c.b); n += 1
	var m := sum / maxf(float(n), 1.0)
	RenderingServer.global_shader_parameter_set("water_floor_mean", Vector4(m.x, m.y, m.z, 1.0 if n > 64 else 0.0))
