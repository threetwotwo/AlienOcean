## Waterline film 0.1.0 (water surface thread, 28 Nov 2026): runs look/waterline_film.glsl (the Unreal tank's
## WATERLINE_HLSL lens film) as a CompositorEffect after the transparent pass, ahead of the AgX tonemapper, so it lies
## over the finished picture in scene light. WorldRoot owns one and keeps its inputs current each frame (the waves'
## texture, the cascades, the still level, the significant height). Nothing runs when the eye is far from the waves
## (more than 2 Hs + 1 m off the still level, as the lens test's far gate) or before the sea has a texture.
class_name WaterlineFilm
extends CompositorEffect

const BAND := 0.015            # the film's half width, share of the screen's height (tank: 0.015)
var strength := 1.0            # 1 = the tank's film, 0 = a knife cut
# fed by WorldRoot
var disp := RID()              # the sea's displacement array (FftSea.disp_tex)
var patch := Vector4(250.0, 21.4, 2.56, 0.32)
var surf := 0.0                # the still level, Godot y
var hs := 0.0                  # significant wave height, m (sea_mom_r.w)

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var copy_shader: RID
var copy_pipeline: RID
var lin: RID
var rep: RID
var ubo: RID
const SRC := &"film_src"

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_init_compute)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd:
		for r in [ubo, lin, rep, pipeline, shader, copy_pipeline, copy_shader]:
			if r.is_valid(): rd.free_rid(r)

func _compile(code: String, what: String) -> RID:
	var src := RDShaderSource.new(); src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = code
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error(what + ": " + spirv.compile_error_compute); return RID()
	return rd.shader_create_from_spirv(spirv)

func _init_compute() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null: return
	shader = _compile(FileAccess.get_file_as_string("res://look/waterline_film.glsl"), "waterline_film.glsl")
	if not shader.is_valid(): return
	pipeline = rd.compute_pipeline_create(shader)
	copy_shader = _compile(AgxEffect.COPY_GLSL, "film copy")   # the colour buffer can't be a copy source
	if not copy_shader.is_valid(): return
	copy_pipeline = rd.compute_pipeline_create(copy_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lin = rd.sampler_create(ss)
	var sr := RDSamplerState.new()
	sr.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; sr.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sr.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; sr.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	rep = rd.sampler_create(sr)
	ubo = rd.uniform_buffer_create(12 * 16)

func _render_callback(_type: int, render_data: RenderData) -> void:
	if rd == null or not pipeline.is_valid() or not copy_pipeline.is_valid() or not disp.is_valid() or strength <= 0.0: return
	var rsb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var rsd := render_data.get_render_scene_data()
	if rsb == null: return
	var ct := rsd.get_cam_transform()
	if absf(ct.origin.y - surf) > 2.0 * hs + 1.0: return     # far from every wave: the lens is all one side
	var size := rsb.get_internal_size()
	if size.x == 0 or size.y == 0: return
	if not rsb.has_texture(SRC, SRC):
		rsb.create_texture(SRC, SRC, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
	var groups := Vector2i((size.x + 7) / 8, (size.y + 7) / 8)
	for view in rsb.get_view_count():
		var color := rsb.get_color_layer(view)
		var copy := rsb.get_texture_slice(SRC, SRC, view, 0, 1, 1)
		var c0 := RDUniform.new(); c0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; c0.binding = 0; c0.add_id(color)
		var c1 := RDUniform.new(); c1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; c1.binding = 1; c1.add_id(copy)
		var cl0 := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl0, copy_pipeline)
		rd.compute_list_bind_uniform_set(cl0, UniformSetCacheRD.get_cache(copy_shader, 0, [c0, c1]), 0)
		rd.compute_list_dispatch(cl0, groups.x, groups.y, 1)
		rd.compute_list_end()
		var f := PackedFloat32Array()
		AgxEffect._pack_mat(rsd.get_view_projection(view).inverse(), f)
		AgxEffect._pack_mat(Projection(ct), f)
		f.append_array([patch.x, patch.y, patch.z, patch.w,
			surf, Time.get_ticks_msec() * 0.001, BAND, clampf(strength, 0.0, 1.0),
			float(size.x), float(size.y), 0.0, 0.0])
		rd.buffer_update(ubo, 0, f.size() * 4, f.to_byte_array())
		var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u0.binding = 0; u0.add_id(color)
		var u1 := RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u1.binding = 1; u1.add_id(lin); u1.add_id(copy)
		var u2 := RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u2.binding = 2; u2.add_id(rep); u2.add_id(disp)
		var u3 := RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; u3.binding = 3; u3.add_id(ubo)
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(shader, 0, [u0, u1, u2, u3]), 0)
		rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
		rd.compute_list_end()
