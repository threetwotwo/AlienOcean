## CORTAO effect 0.1.0 (ao thread, 28 Nov 2026): Circular Occluder Ray-Traced Ambient Occlusion (third_party/cortao, MIT,
## github.com/theagentd/CORTAO v1.0.3) as a CompositorEffect. It runs after Godot's depth prepass (PRE_OPAQUE) on the depth and
## view-space normal_roughness buffers: prepass (packed depth + normal, 8 mips) -> main pass (16 samples x 16 rays, occluder
## lookup table) -> filter pass. The result (r = occlusion, 1 = open; gba = view-space bent normal) is a Texture2DRD in the global
## sampler `cortao_ao`; the lit materials read it through look/screen_ao.gdshaderinc as AO = min(AO, cortao), which is exactly how
## Godot applies its own SSAO (scene_forward_clustered.glsl: ao = min(ao, ssao)), so only the AO source changes: the water's fill
## (Godot ambient / SDFGI) is occluded, the sun and the light net are not.
## WorldRoot owns one and switches between it and Godot's SSAO (WorldRoot.set_ao); the test level has the "cortao" switch.
class_name CortaoEffect
extends CompositorEffect

var radius := 1.2                 # world metres (Godot's SSAO used 1.2)
var screen_radius := 0.2          # max sample radius as a fraction of the screen height (CORTAO default 0.2)
var mip_bias := -4.0
var max_slope_comp := 4.0
var backface_threshold := 0.5
var backface_boost := 0.0
var filter_depth := 512.0
var filter_normal := 16.0           # CORTAO default 128; 16 with shape normals: key frame grain 3.70 -> 3.35 (SSAO 3.05)
var animate := false              # force a new seed every frame; otherwise it follows the viewport (TAA / FSR 2 / MetalFX temporal); constant without one: no flicker
var invert_flip := false          # checks only: the planted fault (AO lands mirrored)
var depth_normals := true         # the shape's normal from depth, not the materials' detail normal (see cortao_prepass.glsl)
var light_weighted := true        # each open ray counts by the water's light from its direction (above: light_down, below: light_up).
                                  # Key frame 28 Nov: darkens only what sits under an overhang (table coral's stalk and the corals beneath, up to
                                  # ~10/255), leaves open sand alone; toward v7c's darker under-coral shadow. Off: AO_CORTAO_LIGHT=0
var light_down := 1.0             # luminance of the upper half of the field (WorldRoot: Ek), any unit
var light_up := 1.0               # luminance of the lower half (WorldRoot: Eu, the sand's bounce)
var rays := int(OS.get_environment("CORTAO_RAYS")) if OS.get_environment("CORTAO_RAYS") != "" else 16   # 16 or 32 (lookup table per count)
var samples := int(OS.get_environment("CORTAO_SAMPLES")) if OS.get_environment("CORTAO_SAMPLES") != "" else 16
# CORTAO's filter taps sit 3 pixels apart, so one pass only blends pixels 3 apart: 9 interleaved noise lattices, the dotted
# "screen door" (cortao_check: residual correlation at a 3 px lag 0.66, and 0.93 after 3 such passes). CORTAO leaves the rest to TAA.
# The last pass here is the same filter with 1-pixel taps (fine), which blends the lattices into each other.
var filter_passes_temporal := 2   # with TAA / FSR 2 / MetalFX temporal: CORTAO's pass + the fine pass; the upscaler averages frames
var filter_passes := 2            # without one (TAA off, FSR 1 is spatial) the same: cortao_check C5 grain 0.009 (3 coarse) -> 0.003, C6 0.84 -> 0.25
                                  # (2 coarse + fine: C6 0.39, two coarse passes deepen the lattice more than one fine pass undoes)
var fine_last := OS.get_environment("CORTAO_FAULT_COARSE") == ""   # checks only: env CORTAO_FAULT_COARSE=1 plants the old lattice (cortao_check --fault coarse)
# The occlusion pass itself (head to head, Gary 28 Nov "keep the head-to-head"): CORTAO, or a horizon method on the same depth /
# normal inputs, denoised by the same filter and read by the materials the same way (look/cortao/gtao_main.glsl):
# "gtao" = XeGTAO (Intel), "vbao" = visibility bitmask (Therrien et al. 2023). WorldRoot.set_ao("gtao" | "vbao") sets it.
var algo := OS.get_environment("CORTAO_ALGO") if OS.get_environment("CORTAO_ALGO") != "" else "cortao"
var gtao_slices := 4.0            # XeGTAO "high" is 3 slices x 3 steps; budget allows more
var gtao_steps := 6.0
var gtao_power := 2.2             # XeGTAO FinalValuePower default
var vbao_thickness := 0.4         # m: how deep an occluder is assumed to be (bitmask)
var capture_next := false         # checks: copy the next result into `captured` (stalls the GPU; tests only)
var captured: Image
var gpu_ms := 0.0                 # the three passes' GPU time, last frame read back (RD timestamps; 0 until measured)

var rd: RenderingDevice
var sh_pre: RID
var sh_main: RID
var sh_filt: RID
var sh_filt2: RID
var pl_pre: RID
var pl_main: RID
var pl_filt: RID
var pl_filt2: RID
var sh_gtao: RID
var sh_vbao: RID
var pl_gtao: RID
var pl_vbao: RID
var smp_border: RID
var smp_clamp: RID
var lut: RID
var size := Vector2i.ZERO
var mips := 1
var packed: RID
var packed_mips: Array[RID] = []
var raw: RID
var raw2: RID
var shape_n: RID
var ubo: RID
var ubo_main: RID
var out: RID
var tex := Texture2DRD.new()      # main thread side of `out`
var frame := 0
var ok := false

const DIR := "res://third_party/cortao/"

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	needs_normal_roughness = true
	RenderingServer.call_on_render_thread(_init_compute)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd:
		for r in packed_mips + [packed, raw, raw2, shape_n, out, ubo, ubo_main, lut, smp_border, smp_clamp, pl_pre, pl_main, pl_filt, pl_filt2, pl_gtao, pl_vbao, sh_pre, sh_main, sh_filt, sh_filt2, sh_gtao, sh_vbao]:
			if r.is_valid(): rd.free_rid(r)

## CORTAO's shaders #include its headers; Godot's GLSL compiler has no include path, so the headers are inlined here
static func load_glsl(path: String, defines := "", fine := false) -> String:
	var s := FileAccess.get_file_as_string(path)
	var re := RegEx.new(); re.compile("#include\\s*[<\"](CORTAO\\w+\\.h)[>\"]")
	var guard := 0
	var seen := {}
	while guard < 8:
		var m := re.search(s)
		if m == null: break
		var h := m.get_string(1)
		var body := "" if seen.has(h) else FileAccess.get_file_as_string(DIR + h).replace("#pragma once", "")
		if fine and h == "CORTAOFilterPass.h":
			body = _fine_taps(body)
		seen[h] = true
		s = s.substr(0, m.get_start()) + body + s.substr(m.get_end())
		guard += 1
	if defines != "":
		var nl := s.find("\n")
		s = s.substr(0, nl + 1) + defines + s.substr(nl + 1)
	return s

## the fine filter: CORTAO's tap offsets (multiples of 3) divided by 3. Edits the header text at load, so the vendored file stays
## unchanged; an update that renames the offsets fails loudly here (and cortao_check C6 catches a lattice that comes back)
static func _fine_taps(body: String) -> String:
	var re := RegEx.new(); re.compile("offsets\\[(\\d)\\] = cortao_int2\\((-?\\d+), (-?\\d+)\\);")
	var hits := re.search_all(body)
	if hits.size() != 8: push_error("CORTAO fine filter: expected 8 tap offsets in CORTAOFilterPass.h, found %d" % hits.size())
	for i in range(hits.size() - 1, -1, -1):
		var m: RegExMatch = hits[i]
		body = body.substr(0, m.get_start()) + "offsets[%s] = cortao_int2(%d, %d);" % [m.get_string(1), int(m.get_string(2)) / 3, int(m.get_string(3)) / 3] + body.substr(m.get_end())
	return body

func _compile(path: String, defines := "", fine := false) -> RID:
	var src := RDShaderSource.new(); src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = load_glsl(path, defines, fine)
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("CORTAO %s: %s" % [path, spirv.compile_error_compute]); return RID()
	return rd.shader_create_from_spirv(spirv)

func _init_compute() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null: return
	sh_pre = _compile("res://look/cortao/cortao_prepass.glsl")
	sh_main = _compile("res://look/cortao/cortao_main.glsl", "#define CORTAO_SAMPLES %d\n#define CORTAO_RAYS %d\n" % [samples, rays])
	sh_filt = _compile("res://look/cortao/cortao_filter.glsl", "", fine_last)   # the last pass: fine taps
	sh_filt2 = _compile("res://look/cortao/cortao_filter.glsl", "#define CORTAO_OUT_PACKED 1\n")
	sh_gtao = _compile("res://look/cortao/gtao_main.glsl")
	sh_vbao = _compile("res://look/cortao/gtao_main.glsl", "#define GTAO_BITMASK 1\n")
	if not (sh_pre.is_valid() and sh_main.is_valid() and sh_filt.is_valid() and sh_filt2.is_valid() and sh_gtao.is_valid() and sh_vbao.is_valid()): return
	pl_gtao = rd.compute_pipeline_create(sh_gtao)
	pl_vbao = rd.compute_pipeline_create(sh_vbao)
	pl_pre = rd.compute_pipeline_create(sh_pre)
	pl_main = rd.compute_pipeline_create(sh_main)
	pl_filt = rd.compute_pipeline_create(sh_filt)
	pl_filt2 = rd.compute_pipeline_create(sh_filt2)
	var sb := RDSamplerState.new()
	sb.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST; sb.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sb.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sb.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_BORDER; sb.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_BORDER
	sb.border_color = RenderingDevice.SAMPLER_BORDER_COLOR_INT_TRANSPARENT_BLACK
	smp_border = rd.sampler_create(sb)
	var sc := RDSamplerState.new()
	sc.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST; sc.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sc.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE; sc.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sc.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	smp_clamp = rd.sampler_create(sc)
	# occluder lookup table: 24 x 24 x 16 texels, one bit per ray (R16_UINT for 16 rays, R32_UINT for 32), from CORTAO's tables/occluder
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	tf.format = RenderingDevice.DATA_FORMAT_R32_UINT if rays == 32 else RenderingDevice.DATA_FORMAT_R16_UINT
	tf.width = 24; tf.height = 24; tf.depth = 16
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	lut = rd.texture_create(tf, RDTextureView.new(), [FileAccess.get_file_as_bytes(DIR + ("occluder_24x24x16_r32ui.bin" if rays == 32 else "occluder_24x24x16_r16ui.bin"))])
	ubo = rd.uniform_buffer_create(48)
	ubo_main = rd.uniform_buffer_create(32)
	ok = lut.is_valid()

func _free_targets() -> void:
	for r in packed_mips:
		if r.is_valid(): rd.free_rid(r)
	packed_mips.clear()
	for r in [packed, raw, raw2, shape_n, out]:
		if r.is_valid(): rd.free_rid(r)
	packed = RID(); raw = RID(); raw2 = RID(); shape_n = RID(); out = RID()

func _make_targets(sz: Vector2i) -> void:
	_free_targets()
	size = sz
	mips = clampi(int(floor(log(float(maxi(sz.x, sz.y))) / log(2.0))) + 1, 1, 8)
	var f := RDTextureFormat.new()
	f.width = sz.x; f.height = sz.y; f.format = RenderingDevice.DATA_FORMAT_R32_UINT; f.mipmaps = mips
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	packed = rd.texture_create(f, RDTextureView.new())
	for m in 8:
		packed_mips.append(rd.texture_create_shared_from_slice(RDTextureView.new(), packed, 0, mini(m, mips - 1), 1))
	f.mipmaps = 1
	raw = rd.texture_create(f, RDTextureView.new())
	raw2 = rd.texture_create(f, RDTextureView.new())
	f.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	shape_n = rd.texture_create(f, RDTextureView.new())
	f.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	f.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	out = rd.texture_create(f, RDTextureView.new())
	_publish.call_deferred(out)

func _publish(r: RID) -> void:
	tex.texture_rd_rid = r
	RenderingServer.global_shader_parameter_set("cortao_ao", tex)

func _read_time() -> void:
	## timestamps come back a frame or more later: take the newest begin/end pair Godot reports
	var t0 := -1; var t1 := -1
	for i in rd.get_captured_timestamps_count():
		var n := rd.get_captured_timestamp_name(i)
		if n == "CORTAO begin": t0 = rd.get_captured_timestamp_gpu_time(i)
		elif n == "CORTAO end": t1 = rd.get_captured_timestamp_gpu_time(i)
	if t0 >= 0 and t1 > t0: gpu_ms = float(t1 - t0) / 1.0e6   # Godot reports these in nanoseconds (cloud check 28 Nov: 63.7 ms on llvmpipe at 960x540)

## a temporal filter follows (TAA, FSR 2 or MetalFX temporal): a new seed each frame, which it averages away
static func _temporal(rsb: RenderSceneBuffersRD) -> bool:
	var m := rsb.get_scaling_3d_mode()
	return rsb.get_use_taa() or m == RenderingServer.VIEWPORT_SCALING_3D_MODE_FSR2 or m == RenderingServer.VIEWPORT_SCALING_3D_MODE_METALFX_TEMPORAL

static func _u(type: int, binding: int, ids: Array) -> RDUniform:
	var u := RDUniform.new(); u.uniform_type = type; u.binding = binding
	for i in ids: u.add_id(i)
	return u

func _render_callback(_type: int, render_data: RenderData) -> void:
	if not ok: return
	var rsb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var rsd := render_data.get_render_scene_data()
	if rsb == null or rsd == null: return
	var sz := rsb.get_internal_size()
	if sz.x == 0 or sz.y == 0: return
	if sz != size: _make_targets(sz)
	if rsb.get_view_count() != 1: return   # mono only (no XR)
	if not rsb.has_texture(&"forward_clustered", &"normal_roughness"): return
	var depth := rsb.get_depth_layer(0)
	var normal := rsb.get_texture_slice(&"forward_clustered", &"normal_roughness", 0, 0, 1, 1)
	if not rd.texture_is_valid(depth) or not rd.texture_is_valid(normal): return   # teardown: buffers already freed
	var P := rsd.get_view_projection(0)
	var I := P.inverse()
	if frame == 5 and OS.get_environment("CORTAO_DEBUG") != "": print("CORTAO P ", P, " size ", sz, " mips ", mips)
	var seed := (frame * 2654435761) & 0xFFFFFFFF if (animate or _temporal(rsb)) else 0x9E3779B9
	frame += 1
	var res := sz.x | (sz.y << 16)
	# Godot hands over the projection already corrected for Vulkan (measured 28 Nov: Y flipped, reverse-Z remapped to 0..1:
	# d = P[3][2] / zlin - P[2][2]). So linear depth 1 / zlin = d / P[3][2] + P[2][2] / P[3][2], read from the matrix itself, and
	# CORTAO's flipY is needed only if a projection ever arrives unflipped (P[1][1] > 0).
	var flip_y: bool = (P[1][1] > 0.0) != invert_flip
	var pre := PackedByteArray(); pre.resize(32)
	pre.encode_u32(0, res); pre.encode_float(4, 1.0 / P[3][2]); pre.encode_float(8, P[2][2] / P[3][2])   # linearDepth = 1 / (d * scale + offset)
	pre.encode_u32(12, seed); pre.encode_u32(16, mips)
	# main pass parameters (populateMainPassParameters); Projection columns are [col][row] as in CORTAO's matrix[4][4]
	var projX: float = P[0][0]; var projY: float = P[1][1]; var pox: float = P[2][0]; var poy: float = P[2][1]
	var invX: float = I[0][0]; var invY: float = I[1][1]; var iox: float = I[3][0]; var ioy: float = I[3][1]
	var mp := PackedByteArray(); mp.resize(80)
	mp.encode_u32(0, res); mp.encode_u32(4, seed)
	mp.encode_float(8, invX / float(sz.x) * sqrt(2.0)); mp.encode_float(12, radius)
	var ys := -1.0 if flip_y else 1.0
	mp.encode_float(16, 2.0 * invX); mp.encode_float(20, ys * 2.0 * invY)
	mp.encode_float(24, -invX + iox); mp.encode_float(28, -ys * invY + ioy)
	mp.encode_float(32, 0.5 * projX); mp.encode_float(36, ys * 0.5 * projY)
	mp.encode_float(40, -0.5 + 0.5 * pox); mp.encode_float(44, -0.5 + ys * 0.5 * poy)
	var mac := absf(invY) * screen_radius * 2.0
	mp.encode_float(48, mac / sqrt(mac * mac + 1.0))
	mp.encode_float(52, log(absf(projY) * float(sz.y) * 0.5) / log(2.0) + mip_bias)
	mp.encode_float(56, 1.0 / max_slope_comp); mp.encode_float(60, backface_threshold); mp.encode_float(64, backface_boost)
	var fp := PackedByteArray(); fp.resize(16)
	fp.encode_u32(0, res); fp.encode_float(4, filter_depth); fp.encode_float(8, filter_normal)

	var ub := PackedFloat32Array([mp.decode_float(16), mp.decode_float(20), mp.decode_float(24), mp.decode_float(28),
		1.0 / sz.x, 1.0 / sz.y, 0.0, 0.0, 1.0 if depth_normals else 0.0, 0.0, 0.0, 0.0]).to_byte_array()
	rd.buffer_update(ubo, 0, ub.size(), ub)
	# world up in view space, for the light weighting
	var upv: Vector3 = rsd.get_cam_transform().basis.inverse() * Vector3.UP
	var um := PackedFloat32Array([upv.x, upv.y, upv.z, 1.0 if light_weighted else 0.0, maxf(light_down, 0.0), maxf(light_up, 0.0), 0.0, 0.0]).to_byte_array()
	rd.buffer_update(ubo_main, 0, um.size(), um)
	_read_time()
	rd.capture_timestamp("CORTAO begin")
	var U := RenderingDevice
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pl_pre)
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(sh_pre, 0, [
		_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [smp_clamp, depth]),
		_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [smp_clamp, normal]),
		_u(U.UNIFORM_TYPE_IMAGE, 2, packed_mips),
		_u(U.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [ubo]),
		_u(U.UNIFORM_TYPE_IMAGE, 4, [shape_n])]), 0)
	rd.compute_list_set_push_constant(cl, pre, pre.size())
	rd.compute_list_dispatch(cl, (sz.x + 7) / 8, (sz.y + 7) / 8, 1)
	rd.compute_list_add_barrier(cl)
	if algo == "gtao" or algo == "vbao":
		var shg := sh_gtao if algo == "gtao" else sh_vbao
		rd.compute_list_bind_compute_pipeline(cl, pl_gtao if algo == "gtao" else pl_vbao)
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(shg, 0, [
			_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [smp_border, packed]),
			_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [smp_clamp, shape_n]),
			_u(U.UNIFORM_TYPE_IMAGE, 3, [raw])]), 0)
		var gp := PackedByteArray(); gp.resize(64)
		for i in 4: gp.encode_float(i * 4, mp.decode_float(16 + i * 4))   # CORTAO's unprojectParams
		gp.encode_float(16, 1.0 / sz.x); gp.encode_float(20, 1.0 / sz.y); gp.encode_u32(24, res); gp.encode_u32(28, seed)
		gp.encode_float(32, radius); gp.encode_float(36, screen_radius * sz.y); gp.encode_float(40, vbao_thickness)
		gp.encode_float(44, gtao_slices); gp.encode_float(48, gtao_steps); gp.encode_float(52, gtao_power)
		rd.compute_list_set_push_constant(cl, gp, gp.size())
		rd.compute_list_dispatch(cl, (sz.x + 7) / 8, (sz.y + 7) / 8, 1)
	else:
		rd.compute_list_bind_compute_pipeline(cl, pl_main)
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(sh_main, 0, [
			_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [smp_border, packed]),
			_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [smp_clamp, shape_n]),
			_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [smp_clamp, lut]),
			_u(U.UNIFORM_TYPE_IMAGE, 3, [raw]),
			_u(U.UNIFORM_TYPE_UNIFORM_BUFFER, 4, [ubo_main])]), 0)
		rd.compute_list_set_push_constant(cl, mp, mp.size())
		rd.compute_list_dispatch(cl, (sz.x + 15) / 16, (sz.y + 15) / 16, 1)
	rd.compute_list_add_barrier(cl)
	var src := raw
	var tmp := _temporal(rsb)
	for k in (filter_passes_temporal if tmp else filter_passes) - 1:   # extra passes ping-pong raw <-> raw2
		var dst := raw2 if src == raw else raw
		rd.compute_list_bind_compute_pipeline(cl, pl_filt2)
		rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(sh_filt2, 0, [
			_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [smp_border, packed]),
			_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [smp_border, src]),
			_u(U.UNIFORM_TYPE_IMAGE, 2, [dst])]), 0)
		rd.compute_list_set_push_constant(cl, fp, fp.size())
		rd.compute_list_dispatch(cl, (sz.x / 2 + 8) / 8, (sz.y / 2 + 8) / 8, 1)
		rd.compute_list_add_barrier(cl)
		src = dst
	rd.compute_list_bind_compute_pipeline(cl, pl_filt)
	rd.compute_list_bind_uniform_set(cl, UniformSetCacheRD.get_cache(sh_filt, 0, [
		_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [smp_border, packed]),
		_u(U.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [smp_border, src]),
		_u(U.UNIFORM_TYPE_IMAGE, 2, [out])]), 0)
	rd.compute_list_set_push_constant(cl, fp, fp.size())
	rd.compute_list_dispatch(cl, (sz.x / 2 + 8) / 8, (sz.y / 2 + 8) / 8, 1)
	rd.compute_list_end()
	rd.capture_timestamp("CORTAO end")
	if capture_next:
		capture_next = false
		var bytes := rd.texture_get_data(out, 0)
		captured = Image.create_from_data(sz.x, sz.y, false, Image.FORMAT_RGBA8, bytes)
