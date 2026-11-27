## AgX effect 0.1.0 (engine thread): runs look/agx_post.glsl (the Unreal M_PP_AgX tonemapper, sun_v184 AGX_HLSL) as a
## CompositorEffect after the transparent pass. WorldRoot owns one, keeps its inputs current (exposure, the light's
## white point, the moons, the under-water white point) and sets Godot's tonemapper to LINEAR so only sRGB encoding follows.
## Parameters are the Unreal AGX_PARAMS defaults.
class_name AgxEffect
extends CompositorEffect

var stops_below := 10.0
var stops_above := 6.5
var punch := 0.4
var saturation := 1.0
var white_temp := 0.0          # 0 = follow the light (white_now)
var sky_blue := 1.2
var night_look := 1.0
var hue_keep := 0.6
var star_keep := 1.0
var night_deep := 1.5
var photo_sky := 0.5
var twilight_soft := 1.0
var emit_keep := 1.0
var emit_from := 0.0
var night_sky := 2.75          # MPC_Sky NightSky
var bias := 0.0
var mode := 0                  # 0 AgX, 1 identity (calibration), 2 constant 0.5 (calibration)
# fed by WorldRoot
var exposure := 1.0            # exposed units per nit (Unreal's EyeAdaptation)
var buf_scale := 1.0           # what Godot's buffer holds per nit
var white_now := 5772.0
var moon_a := Vector4.ZERO     # direction xyz, angular radius (rad)
var moon_b := Vector4.ZERO
var depth_gain := Vector3.ONE
var sun_dir := Vector3.UP
var under := false

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var copy_shader: RID
var copy_pipeline: RID
var sampler: RID
var ubo: RID
const SRC := &"agx_src"
const COPY_GLSL := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;
void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(p, imageSize(src)))) return;
	imageStore(dst, p, imageLoad(src, p));
}
"""

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_init_compute)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd:
		for r in [ubo, sampler, pipeline, shader, copy_pipeline, copy_shader]:
			if r.is_valid(): rd.free_rid(r)

func _init_compute() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null: return
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = FileAccess.get_file_as_string("res://look/agx_post.glsl")
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("agx_post.glsl: " + spirv.compile_error_compute); return
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	# Godot's colour buffer can't be a copy source, so a tiny compute pass copies it for the neighbour reads
	var cs := RDShaderSource.new(); cs.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	cs.source_compute = COPY_GLSL
	var cv := rd.shader_compile_spirv_from_source(cs)
	if cv.compile_error_compute != "":
		push_error("agx copy: " + cv.compile_error_compute); return
	copy_shader = rd.shader_create_from_spirv(cv)
	copy_pipeline = rd.compute_pipeline_create(copy_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST; ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler = rd.sampler_create(ss)
	ubo = rd.uniform_buffer_create(18 * 16)

static func _pack_mat(m: Projection, out: PackedFloat32Array) -> void:
	for c in 4:
		var col: Vector4 = m[c]
		out.append_array([col.x, col.y, col.z, col.w])

func _render_callback(_type: int, render_data: RenderData) -> void:
	if rd == null or not pipeline.is_valid(): return
	var rsb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var rsd := render_data.get_render_scene_data()
	if rsb == null: return
	var size := rsb.get_internal_size()
	if size.x == 0 or size.y == 0: return
	if not rsb.has_texture(SRC, SRC):
		rsb.create_texture(SRC, SRC, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
	for view in rsb.get_view_count():
		var color := rsb.get_color_layer(view)
		var depth := rsb.get_depth_layer(view)
		var copy := rsb.get_texture_slice(SRC, SRC, view, 0, 1, 1)
		var groups := Vector2i((size.x + 7) / 8, (size.y + 7) / 8)
		var c0 := RDUniform.new(); c0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; c0.binding = 0; c0.add_id(color)
		var c1 := RDUniform.new(); c1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; c1.binding = 1; c1.add_id(copy)
		var cl0 := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl0, copy_pipeline)
		rd.compute_list_bind_uniform_set(cl0, UniformSetCacheRD.get_cache(copy_shader, 0, [c0, c1]), 0)
		rd.compute_list_dispatch(cl0, groups.x, groups.y, 1)
		rd.compute_list_end()
		var f := PackedFloat32Array()
		_pack_mat(rsd.get_view_projection(view).inverse(), f)
		var b := rsd.get_cam_transform().basis
		_pack_mat(Projection(Transform3D(b, Vector3.ZERO)), f)
		f.append_array([moon_a.x, moon_a.y, moon_a.z, moon_a.w, moon_b.x, moon_b.y, moon_b.z, moon_b.w,
			depth_gain.x, depth_gain.y, depth_gain.z, 0.0, sun_dir.x, sun_dir.y, sun_dir.z, 1.0 if under else 0.0,
			exposure, bias, buf_scale, white_now,
			stops_below, stops_above, punch, saturation,
			white_temp, sky_blue, night_look, hue_keep,
			star_keep, night_deep, photo_sky, twilight_soft,
			emit_keep, emit_from, night_sky, float(mode),
			float(size.x), float(size.y), 0.0, 0.0])
		rd.buffer_update(ubo, 0, f.size() * 4, f.to_byte_array())
		var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u0.binding = 0; u0.add_id(color)
		var u1 := RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u1.binding = 1; u1.add_id(sampler); u1.add_id(copy)
		var u2 := RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u2.binding = 2; u2.add_id(sampler); u2.add_id(depth)
		var u3 := RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; u3.binding = 3; u3.add_id(ubo)
		var set := UniformSetCacheRD.get_cache(shader, 0, [u0, u1, u2, u3])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, set, 0)
		rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
		rd.compute_list_end()
