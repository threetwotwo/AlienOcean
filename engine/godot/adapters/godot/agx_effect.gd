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
var sky_blue := 0.4             # Unreal 1.2; 0.4 since the dome's air is truly blue (28 Nov): 1.2 made a cyan step at 10-20 deg
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
## Bloom 0.1.0 (bloom thread, 28 Nov): the key frame's veiling glare (look/bloom.glsl). bloom 1 = the key frame, 0 = off.
var bloom := 1.0
var bloom_thr := 4.5           # exposed units (0.18 = middle grey): key frame threshold 3.0 before its exposure +0.6 stop
var bloom_max := 2048.0        # excess cap per pixel (exposed units): high enough for the sun's halo, stops a stray hot pixel ruling the frame
var bloom_iso_floor := 16.0    # a lone hot texel gives at most this much glare (exposed units), or bloom_iso_k x its brightest neighbour
var bloom_iso_k := 2.0
var bloom_keep := 1.0          # 1 = energy kept (the key frame's glare: light leaves its pixel), 0 = the glow is added on top (round 6 look)
var bloom_w := PackedFloat32Array([0.45, 0.25, 0.17, 0.09, 0.04])   # PSF weights for sigma BLOOM_SIG (key frame develop_v7.py)
const BLOOM_SIG := [1.5, 4.0, 12.0, 36.0, 90.0]                     # px at 960 wide; scaled to the internal width
## Vignette: light lost at the corners as a share (0.15 = corners keep 85 %), natural cos^4-like falloff, in scene light
var vignette := 0.0
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
var bloom_shader: RID
var bloom_pipeline: RID
var lin_sampler: RID
var dump := false               # checks (tools/bloom_check.gd): read the source and the five glare parts back once
var dumped := {}
const BL := &"ao_bloom"
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
		for r in [ubo, sampler, lin_sampler, pipeline, shader, copy_pipeline, copy_shader, bloom_pipeline, bloom_shader]:
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
	var ls := RDSamplerState.new()
	ls.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; ls.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ls.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE; ls.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	lin_sampler = rd.sampler_create(ls)
	var bs := RDShaderSource.new(); bs.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	bs.source_compute = FileAccess.get_file_as_string("res://look/bloom.glsl")
	var bv := rd.shader_compile_spirv_from_source(bs)
	if bv.compile_error_compute != "":
		push_error("bloom.glsl: " + bv.compile_error_compute); return
	bloom_shader = rd.shader_create_from_spirv(bv)
	bloom_pipeline = rd.compute_pipeline_create(bloom_shader)
	ubo = rd.uniform_buffer_create(21 * 16)

static func bloom_plan(width: int) -> Array:
	## [level, sigma in that level's px] per PSF part. Each level halves; the 13-tap chain already blurs ~0.7 px at a level,
	## so the gaussian adds the rest. Level 1 at least (half size), 5 at most.
	var out := []
	for s0 in BLOOM_SIG:
		var s: float = s0 * width / 960.0
		var lv := clampi(int(floor(log(maxf(s / 2.0, 1.0)) / log(2.0))), 1, 5)
		var sl := s / float(1 << lv)
		out.append([lv, sqrt(maxf(sl * sl - 0.48, 0.09))])
	return out

static func _lvl(size: Vector2i, lv: int) -> Vector2i:
	var k := 1 << lv
	return Vector2i(maxi((size.x + k - 1) / k, 1), maxi((size.y + k - 1) / k, 1))

func _img(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u.binding = binding; u.add_id(rid); return u

func _tex(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u.binding = binding
	u.add_id(lin_sampler); u.add_id(rid); return u

func _bloom_pass(cl: int, dst: RID, src: RID, dsz: Vector2i, ssz: Vector2i, a: Vector4, b: Vector4, dir: Vector2, cap: float) -> void:
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(bloom_shader, 0, [_img(0, dst), _tex(1, src)]), 0)
	var pcf := PackedFloat32Array([a.x, a.y, a.z, a.w, b.x, b.y, b.z, b.w, dir.x, dir.y, float(dsz.x), float(dsz.y),
		float(ssz.x), float(ssz.y), cap, bloom_iso_floor])
	rd.compute_list_set_push_constant(cl, pcf.to_byte_array(), 64)
	rd.compute_list_dispatch(cl, (dsz.x + 7) / 8, (dsz.y + 7) / 8, 1)
	rd.compute_list_add_barrier(cl)

func _bloom(rsb: RenderSceneBuffersRD, view: int, src: RID, size: Vector2i) -> Array:
	## builds the five glare parts for this view; returns their textures (AgX samples and adds them)
	var plan := bloom_plan(size.x)
	var flags := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var F := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	for lv in range(1, 6):
		for nm in ["d%d" % lv, "t%d" % lv]:
			if not rsb.has_texture(BL, nm): rsb.create_texture(BL, nm, F, flags, RenderingDevice.TEXTURE_SAMPLES_1, _lvl(size, lv), 1, 1, true, false)
	for k in plan.size():
		var nm := "b%d" % k
		if not rsb.has_texture(BL, nm): rsb.create_texture(BL, nm, F, flags, RenderingDevice.TEXTURE_SAMPLES_1, _lvl(size, plan[k][0]), 1, 1, true, false)
	var tx := func(nm: String) -> RID: return rsb.get_texture_slice(BL, nm, view, 0, 1, 1)
	var outs := []
	for k in plan.size(): outs.append(tx.call("b%d" % k))
	if bloom <= 0.0: return outs
	var top := 1
	for pk in plan: top = maxi(top, pk[0])
	var dg := depth_gain
	var bvec := Vector4(exposure * pow(2.0, bias) / maxf(buf_scale, 1e-30), dg.x, dg.y, dg.z)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, bloom_pipeline)
	_bloom_pass(cl, tx.call("d1"), src, _lvl(size, 1), size, Vector4(0, 0, 0, bloom_thr), bvec, Vector2(bloom_iso_k, 0), bloom_max)
	for lv in range(1, top):
		_bloom_pass(cl, tx.call("d%d" % (lv + 1)), tx.call("d%d" % lv), _lvl(size, lv + 1), _lvl(size, lv), Vector4(1, 0, 0, 0), Vector4.ZERO, Vector2.ZERO, 0.0)
	for k in plan.size():
		var lv: int = plan[k][0]; var sg: float = plan[k][1]; var r := float(ceili(3.0 * sg))
		var ls := _lvl(size, lv)
		_bloom_pass(cl, tx.call("t%d" % lv), tx.call("d%d" % lv), ls, ls, Vector4(2, sg, r, 0), Vector4.ZERO, Vector2(1, 0), 0.0)
		_bloom_pass(cl, outs[k], tx.call("t%d" % lv), ls, ls, Vector4(2, sg, r, 0), Vector4.ZERO, Vector2(0, 1), 0.0)
	rd.compute_list_end()
	return outs

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
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)
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
		var glare := _bloom(rsb, view, copy, size) if bloom_pipeline.is_valid() else []
		if dump and glare.size() == 5:
			dump = false
			var d := {"src": [rd.texture_get_data(copy, 0), size], "parts": []}
			for g in glare:
				var fmt := rd.texture_get_format(g)
				d.parts.append([rd.texture_get_data(g, 0), Vector2i(fmt.width, fmt.height)])
			dumped = d
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
			float(size.x), float(size.y), 0.0, 0.0,
			bloom if glare.size() == 5 else 0.0, bloom_thr, vignette, bloom_max,
			bloom_w[0], bloom_w[1], bloom_w[2], bloom_w[3], bloom_w[4], bloom_keep, bloom_iso_floor, bloom_iso_k])
		rd.buffer_update(ubo, 0, f.size() * 4, f.to_byte_array())
		var u0 := RDUniform.new(); u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u0.binding = 0; u0.add_id(color)
		var u1 := RDUniform.new(); u1.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u1.binding = 1; u1.add_id(sampler); u1.add_id(copy)
		var u2 := RDUniform.new(); u2.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u2.binding = 2; u2.add_id(sampler); u2.add_id(depth)
		var u3 := RDUniform.new(); u3.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; u3.binding = 3; u3.add_id(ubo)
		var us := [u0, u1, u2, u3]
		for k in 5: us.append(_tex(4 + k, glare[k] if glare.size() == 5 else copy))
		var set := UniformSetCacheRD.get_cache(shader, 0, us)
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, set, 0)
		rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
		rd.compute_list_end()
