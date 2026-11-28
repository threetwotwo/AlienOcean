## Waterline effect 0.1.0 (water surface thread, 28 Nov 2026): runs look/waterline_post.glsl (the Unreal tank's per-pixel
## waterline at the lens, M_PP_OO_Waterline) as a CompositorEffect after the transparent pass, before the AgX tonemapper.
## WorldRoot owns one and feeds it the still level; SeaSurface feeds it the FFT sea (static: one sea is drawn at a time).
## It only runs while the eye is within 2 Hs + 1 m of the still level (as the tank's early-out).
class_name WaterlineEffect
extends CompositorEffect

static var disp_rid := RID()            # FftSea.disp_tex.texture_rd_rid (SeaSurface)
static var patch := Vector4(250.0, 21.4, 2.56, 0.32)
static var hs := 0.0                    # significant wave height, m (SeaSpectrum moments mom_r.w)
static var sea_on := false
var water_y := 0.0                      # the still level (WorldRoot)
var enabled_line := true

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var copy_shader: RID
var copy_pipeline: RID
var sampler: RID
var disp_sampler: RID
var ubo: RID
const SRC := &"waterline_src"
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
		for r in [ubo, sampler, disp_sampler, pipeline, shader, copy_pipeline, copy_shader]:
			if r.is_valid(): rd.free_rid(r)

func _compile(code: String) -> RID:
	var src := RDShaderSource.new(); src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = code
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("waterline: " + spirv.compile_error_compute); return RID()
	return rd.shader_create_from_spirv(spirv)

func _init_compute() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null: return
	shader = _compile(FileAccess.get_file_as_string("res://look/waterline_post.glsl"))
	if not shader.is_valid(): return
	pipeline = rd.compute_pipeline_create(shader)
	copy_shader = _compile(COPY_GLSL)
	if not copy_shader.is_valid(): return
	copy_pipeline = rd.compute_pipeline_create(copy_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler = rd.sampler_create(ss)
	var sd := RDSamplerState.new()
	sd.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; sd.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sd.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; sd.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	disp_sampler = rd.sampler_create(sd)
	ubo = rd.uniform_buffer_create(10 * 16)

static func _pack_mat(m: Projection, out: PackedFloat32Array) -> void:
	for c in 4:
		var col: Vector4 = m[c]
		out.append_array([col.x, col.y, col.z, col.w])

func _render_callback(_type: int, render_data: RenderData) -> void:
	if rd == null or not pipeline.is_valid() or not copy_pipeline.is_valid(): return
	if not enabled_line or not sea_on or not disp_rid.is_valid() or not rd.texture_is_valid(disp_rid): return
	var rsb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var rsd := render_data.get_render_scene_data()
	if rsb == null: return
	var ct := rsd.get_cam_transform()
	if absf(ct.origin.y - water_y) > 2.0 * hs + 1.0: return
	var size := rsb.get_internal_size()
	if size.x == 0 or size.y == 0: return
	if not rsb.has_texture(SRC, SRC):
		rsb.create_texture(SRC, SRC, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
	for view in rsb.get_view_count():
		var color := rsb.get_color_layer(view)
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
		_pack_mat(Projection(ct), f)
		f.append_array([patch.x, patch.y, patch.z, patch.w, water_y, float(Time.get_ticks_msec()) * 0.001, float(size.x), float(size.y)])
		rd.buffer_update(ubo, 0, f.size() * 4, f.to_byte_array())
		var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u0.binding = 0; u0.add_id(color)
		var u1 := RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u1.binding = 1; u1.add_id(sampler); u1.add_id(copy)
		var u2 := RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u2.binding = 2; u2.add_id(disp_sampler); u2.add_id(disp_rid)
		var u3 := RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; u3.binding = 3; u3.add_id(ubo)
		var set := UniformSetCacheRD.get_cache(shader, 0, [u0, u1, u2, u3])
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, set, 0)
		rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
		rd.compute_list_end()
