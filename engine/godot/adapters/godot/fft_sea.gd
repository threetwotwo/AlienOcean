## FFT sea 0.1.0 (adapters/godot; water surface thread, 27 Nov 2026): the Unreal lagoon's FFT sea (lagoonwater v98:
## M_LW_Spectrum -> M_LW_FFT x4 -> M_LW_Assemble, every frame) as Godot compute passes on the main RenderingDevice.
## Four cascades (250, 21.4, 2.56, 0.32 m patches; v98 CASCADES) of 256 x 256, as the layers of two texture arrays:
##   sea_disp  = (Dx, Dy, Dz, dDx/dy) m      sea_deriv = (dDz/dx, dDz/dy, dDx/dx, dDy/dy)
## with full wrap-averaged mip chains. Both are global shader uniforms (sampler2DArray), so the surface, the caustics
## and anything else read the one sea. Texture uv = island (x, y) / patch = Godot (x, -z) / patch.
## The clock: the waves run on their own time (v91: game time in Play), wrapping exactly every T_REPEAT s.
## Use: var sea := FftSea.new(); add_child(sea)   (it declares the globals and updates in _process).
## Test: tests/test_fft_sea.gd (self test wave, Parseval height variance vs SeaSpectrum.moments()).
class_name FftSea
extends Node

const NS := 256
const LAYERS := 4
const MIPS := 9                  # 256 .. 1
var params := SeaSpectrum.LAGOON.duplicate()
var time_s := 0.0
var time_scale := 1.0
var hold := false                # true: the waves stand still (shots that must match frame to frame)
var self_test := false
var disp_tex: Texture2DArrayRD
var deriv_tex: Texture2DArrayRD
var patch := Vector4(250.0, 21.4, 2.56, 0.32)   # the preset's cascades (m), as the shaders read them (sea_patch)
var ring_hi := Vector4(32, 32, 32, 64)
var moments := {}                # SeaSpectrum.moments() of the current params (the shader's MomX / MomY / MomR)
var ready_ok := false

var rd: RenderingDevice
var _spec := []                  # SpecA..D, Depth
var _shaders := {}
var _pipes := {}
var _rids := []                  # everything to free
var _wa: RID; var _wb: RID; var _wa2: RID; var _wb2: RID
var _disp: RID; var _deriv: RID
var _ubo: RID
var _set_spec: RID; var _set_fft := []; var _set_asm: RID; var _set_mip := []
var _dirty := true
# the height read back to the CPU (height_at): cascades 0 and 1 (250 m, 21.4 m: all but a few mm of the lagoon's
# height), mip 0, fetched without a stall every readback_frames frames; a few frames behind the drawn sea
var readback_frames := 4
# the whitecaps (look/sea_foam.glsl, the Unreal tank's foam step): a 1024 x 1024 map over 400 m that follows the eye in
# the still sea's frame, drifting with the wind; globals sea_foam (the map), sea_foam_org (centre island x, y, size m,
# 1 = valid), sea_foam_k (the Jacobian threshold of cascades 0-1, soft width, deep-fold step, 1), sea_wind (wind dir
# island x, y, U10 m/s, storm ramp)
const FOAM_N := 1024
const FOAM_SIZE := 400.0
var foam_on := true
var foam_tex: Texture2DRD
var foam := {}                   # SeaSpectrum.foam_consts() of the current params
var foam_eye := Vector2.ZERO     # island xy of the eye (set each frame from the camera)
var _fa: RID; var _fb: RID; var _foam_ubo: RID; var _set_foam: RID
var _foam_c := Vector2(INF, INF); var _foam_acc := Vector2.ZERO
var _last_t := -1.0
var _hb := [PackedByteArray(), PackedByteArray()]   # RGBA16F texels, row major (written on the render thread)
var _rb_pending := 0                                # downloads asked for and not yet returned (render thread)
var _hb_t := -1.0                                   # the wave clock the bytes were drawn at
var _hb_mutex := Mutex.new()
var _frame := 0

func _init() -> void:
	name = "FftSea"
	declare_globals()
	set_params(params)
	disp_tex = Texture2DArrayRD.new(); deriv_tex = Texture2DArrayRD.new(); foam_tex = Texture2DRD.new()
	RenderingServer.call_on_render_thread(_init_rd)

static func declare_globals() -> void:
	if Engine.has_meta("sea_globals"): return
	var rs := RenderingServer
	rs.global_shader_parameter_add("sea_disp", rs.GLOBAL_VAR_TYPE_SAMPLER2DARRAY, null)
	rs.global_shader_parameter_add("sea_deriv", rs.GLOBAL_VAR_TYPE_SAMPLER2DARRAY, null)
	rs.global_shader_parameter_add("sea_patch", rs.GLOBAL_VAR_TYPE_VEC4, Vector4(250.0, 21.4, 2.56, 0.32))
	rs.global_shader_parameter_add("sea_ring_hi", rs.GLOBAL_VAR_TYPE_VEC4, Vector4(32, 32, 32, 64))
	rs.global_shader_parameter_add("sea_open_gain", rs.GLOBAL_VAR_TYPE_FLOAT, float(OS.get_environment("AO_OPEN_GAIN")) if OS.get_environment("AO_OPEN_GAIN") != "" else 2.0)   # look/sea_top: open water art levers (1, 0 = the physical deep sea; 2, 0.5 = the lifted Abzu blue, 28 Nov)
	rs.global_shader_parameter_add("sea_open_teal", rs.GLOBAL_VAR_TYPE_FLOAT, float(OS.get_environment("AO_OPEN_TEAL")) if OS.get_environment("AO_OPEN_TEAL") != "" else 0.5)
	rs.global_shader_parameter_add("sea_mom_x", rs.GLOBAL_VAR_TYPE_VEC4, Vector4.ZERO)
	rs.global_shader_parameter_add("sea_mom_y", rs.GLOBAL_VAR_TYPE_VEC4, Vector4.ZERO)
	rs.global_shader_parameter_add("sea_mom_r", rs.GLOBAL_VAR_TYPE_VEC4, Vector4.ZERO)
	rs.global_shader_parameter_add("sea_on", rs.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	rs.global_shader_parameter_add("sea_crest_sd", rs.GLOBAL_VAR_TYPE_FLOAT, 0.35)
	rs.global_shader_parameter_add("sea_sparkle", rs.GLOBAL_VAR_TYPE_FLOAT, float(OS.get_environment("AO_SPARKLE")) if OS.get_environment("AO_SPARKLE") != "" else 1.0)   # look/sea_top 0.5.0
	rs.global_shader_parameter_add("sea_crest_glow", rs.GLOBAL_VAR_TYPE_FLOAT, float(OS.get_environment("AO_CREST_GLOW")) if OS.get_environment("AO_CREST_GLOW") != "" else 1.0)   # art lever, 1 = the tank
	rs.global_shader_parameter_add("sea_foam", rs.GLOBAL_VAR_TYPE_SAMPLER2D, null)
	rs.global_shader_parameter_add("sea_foam_org", rs.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, FOAM_SIZE, 0))
	rs.global_shader_parameter_add("sea_foam_k", rs.GLOBAL_VAR_TYPE_VEC4, Vector4(-10.0, 0.04, 0.0, 1.0))
	rs.global_shader_parameter_add("sea_wind", rs.GLOBAL_VAR_TYPE_VEC4, Vector4(1, 0, 2, 0))
	Engine.set_meta("sea_globals", true)

func set_params(p: Dictionary) -> void:
	params = p.duplicate()
	var d := SeaSpectrum.derive(params)
	_spec = SeaSpectrum.spec_vectors(d)
	moments = SeaSpectrum.moments(d)
	var rs := RenderingServer
	rs.global_shader_parameter_set("sea_mom_x", moments.mom_x)
	rs.global_shader_parameter_set("sea_mom_y", moments.mom_y)
	rs.global_shader_parameter_set("sea_mom_r", moments.mom_r)
	rs.global_shader_parameter_set("sea_crest_sd", sqrt(moments.per[1].x + moments.per[2].x))   # tank SeaK.x: the crests' height spread, cascades 1-2
	var c: Array = d.cascades; var r: Array = d.ring_hi
	patch = Vector4(c[0], c[1], c[2], c[3]); ring_hi = Vector4(r[0], r[1], r[2], r[3])
	rs.global_shader_parameter_set("sea_patch", patch)
	rs.global_shader_parameter_set("sea_ring_hi", ring_hi)
	foam = SeaSpectrum.foam_consts(d)
	if not foam.on: rs.global_shader_parameter_set("sea_foam_org", Vector4(0, 0, FOAM_SIZE, 0))
	rs.global_shader_parameter_set("sea_foam_k", Vector4(foam.jt, foam.soft, foam.da, 1.0))
	rs.global_shader_parameter_set("sea_wind", Vector4(foam.wind.x, foam.wind.y, foam.U, foam.storm))

func _compile(nm: String) -> RID:
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = FileAccess.get_file_as_string("res://look/%s.glsl" % nm)
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_error("%s.glsl: %s" % [nm, spirv.compile_error_compute]); return RID()
	var sh := rd.shader_create_from_spirv(spirv, nm)
	_shaders[nm] = sh; _pipes[nm] = rd.compute_pipeline_create(sh)
	_rids.append(_pipes[nm]); _rids.append(sh)
	return sh

func _img(fmt: int, mips: int, sampled: bool) -> RID:
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	tf.format = fmt; tf.width = NS; tf.height = NS; tf.array_layers = LAYERS; tf.mipmaps = mips
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	if sampled: tf.usage_bits |= RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var t := rd.texture_create(tf, RDTextureView.new())
	_rids.append(t)
	return t

func _uimg(binding: int, tex) -> RDUniform:
	## tex: one RID, or an Array of RIDs (an image array uniform: one slice per cascade)
	var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u.binding = binding
	for t in (tex if tex is Array else [tex]): u.add_id(t)
	return u

func _slices(tex: RID, mip: int) -> Array:
	## one 2D view per cascade of mip level `mip` (Godot slices a 2D array one layer at a time)
	var out := []
	for l in LAYERS:
		var s := rd.texture_create_shared_from_slice(RDTextureView.new(), tex, l, mip, 1, RenderingDevice.TEXTURE_SLICE_2D)
		_rids.push_front(s)   # slices are freed before their owner
		out.append(s)
	return out

func _init_rd() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_warning("FftSea: no RenderingDevice (compatibility renderer or headless): the sea stays flat"); return
	for nm in ["sea_spectrum", "sea_fft", "sea_assemble", "sea_mip", "sea_foam"]:
		if not _compile(nm).is_valid(): return
	var F32 := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	var F16 := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	_wa = _img(F32, 1, false); _wb = _img(F32, 1, false); _wa2 = _img(F32, 1, false); _wb2 = _img(F32, 1, false)
	_disp = _img(F16, MIPS, true); _deriv = _img(F16, MIPS, true)
	_ubo = rd.uniform_buffer_create(128); _rids.append(_ubo)
	var ub := RDUniform.new(); ub.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; ub.binding = 2; ub.add_id(_ubo)
	_set_spec = rd.uniform_set_create([_uimg(0, _wa), _uimg(1, _wb), ub], _shaders.sea_spectrum, 0)
	_set_fft = [rd.uniform_set_create([_uimg(0, _wa), _uimg(1, _wb), _uimg(2, _wa2), _uimg(3, _wb2)], _shaders.sea_fft, 0),
		rd.uniform_set_create([_uimg(0, _wa2), _uimg(1, _wb2), _uimg(2, _wa), _uimg(3, _wb)], _shaders.sea_fft, 0)]
	var d0 := _slices(_disp, 0); var g0 := _slices(_deriv, 0)
	_set_asm = rd.uniform_set_create([_uimg(0, _wa), _uimg(1, _wb), _uimg(2, d0), _uimg(3, g0)], _shaders.sea_assemble, 0)
	var dprev := d0; var gprev := g0
	for m in range(1, MIPS):
		var dm := _slices(_disp, m); var gm := _slices(_deriv, m)
		_set_mip.append(rd.uniform_set_create([_uimg(0, dprev), _uimg(1, dm), _uimg(2, gprev), _uimg(3, gm)], _shaders.sea_mip, 0))
		dprev = dm; gprev = gm
	var tf := RDTextureFormat.new()
	tf.format = F16; tf.width = FOAM_N; tf.height = FOAM_N
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_fa = rd.texture_create(tf, RDTextureView.new()); _fb = rd.texture_create(tf, RDTextureView.new())
	_rids.append(_fa); _rids.append(_fb)
	rd.texture_clear(_fa, Color(0, 0, 6.0, 1.0), 0, 1, 0, 1)   # no foam; the break clock quiet (BRK_CAP)
	_foam_ubo = rd.uniform_buffer_create(80); _rids.append(_foam_ubo)
	var fu := RDUniform.new(); fu.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; fu.binding = 4; fu.add_id(_foam_ubo)
	_set_foam = rd.uniform_set_create([_uimg(0, d0), _uimg(1, g0), _uimg(2, _fa), _uimg(3, _fb), fu], _shaders.sea_foam, 0)
	foam_tex.texture_rd_rid = _fa
	disp_tex.texture_rd_rid = _disp
	deriv_tex.texture_rd_rid = _deriv
	ready_ok = true
	_run.call(time_s)
	_publish.call_deferred()

func _publish() -> void:
	RenderingServer.global_shader_parameter_set("sea_disp", disp_tex)
	RenderingServer.global_shader_parameter_set("sea_deriv", deriv_tex)
	RenderingServer.global_shader_parameter_set("sea_on", 1.0)
	RenderingServer.global_shader_parameter_set("sea_foam", foam_tex)

func _process(dt: float) -> void:
	if not hold: time_s = fmod(time_s + dt * time_scale, SeaSpectrum.T_REPEAT)
	_frame += 1
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam: foam_eye = Vector2(cam.global_position.x, -cam.global_position.z)
	if ready_ok:
		RenderingServer.call_on_render_thread(_run.bind(time_s))
		if _frame % maxi(readback_frames, 1) == 0 or _hb_t < 0.0:
			RenderingServer.call_on_render_thread(_readback.bind(time_s))

func step_now() -> void:
	## run the passes for the current time (for scripts that set time_s and render one frame)
	if ready_ok:
		RenderingServer.call_on_render_thread(_run.bind(time_s))
		RenderingServer.call_on_render_thread(_readback.bind(time_s))

func preroll(seconds: float, step := 1.0 / 30.0) -> void:
	## run the sea (and its foam) for `seconds` at `step` before a shot, so the foam has its history (render thread)
	if not ready_ok: return
	RenderingServer.call_on_render_thread(func():
		var n := int(seconds / step)
		for i in n:
			time_s = fmod(time_s + step, SeaSpectrum.T_REPEAT)
			_run(time_s))

func _foam_prep(t: float) -> void:
	## the foam step's constants for this run (before the compute list: buffers can't change inside one); dt = the wave
	## clock's advance
	var dt := 0.0 if _last_t < 0.0 else clampf(t - _last_t, 0.0, 0.25)
	if t < _last_t: dt = 0.0     # the clock wrapped or was set back
	_last_t = t
	var tx := FOAM_SIZE / FOAM_N
	var drift: Vector2 = foam.get("drift", Vector2.ZERO)
	_foam_acc = Vector2(fposmod(_foam_acc.x + drift.x * dt, tx), fposmod(_foam_acc.y + drift.y * dt, tx))
	var c := ((foam_eye - _foam_acc) / tx).round() * tx + _foam_acc
	var pc := _foam_c if _foam_c.x != INF else c
	_foam_c = c
	var v := PackedFloat32Array([c.x, c.y, FOAM_SIZE, dt, pc.x, pc.y, drift.x, drift.y,
		foam.get("jt2", -10.0), foam.get("soft", 0.04), foam.get("tau", 4.0), 1.0,
		foam.get("da2", 0.0), foam.get("cbreak", 2.0), foam.get("storm", 0.0), foam.get("rows", 0.0),
		patch.x, patch.y, patch.z, patch.w])
	rd.buffer_update(_foam_ubo, 0, v.size() * 4, v.to_byte_array())
	RenderingServer.global_shader_parameter_set.call_deferred("sea_foam_org", Vector4(c.x, c.y, FOAM_SIZE, 1.0))

func _foam_step(cl: int) -> void:
	## one foam step in the compute list, after the cascades are made
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, _pipes.sea_foam)
	rd.compute_list_bind_uniform_set(cl, _set_foam, 0)
	rd.compute_list_dispatch(cl, FOAM_N / 8, FOAM_N / 8, 1)

func _readback(t: float) -> void:
	## FIX (perf runner thread, 28 Nov 2026): one readback in flight at a time. Asking again while earlier downloads were
	## still pending let them pile up behind a slow frame (a 1.1 s hitch, or ~10 fps full screen) and Godot 4.7 on Metal then
	## aborted inside texture_get_data_async ("FATAL: Index p_index = 4610 is out of bounds (count = 27)", twice, perf runner
	## 28 Nov 04:13Z). The CPU heights are a few frames behind by design, so a skipped request costs nothing.
	if _rb_pending > 0: return
	_rb_pending = 2
	for c in 2:
		rd.texture_get_data_async(_disp, c, _got.bind(c, t))

func _got(data: PackedByteArray, c: int, t: float) -> void:
	_hb_mutex.lock()
	_rb_pending = maxi(_rb_pending - 1, 0)
	_hb[c] = data
	if c == 1: _hb_t = t
	_hb_mutex.unlock()

func has_height() -> bool:
	return _hb_t >= 0.0

func _disp_tap(c: int, X: Vector2) -> Vector3:
	## cascade c's (Dx, Dy, Dz) at island point X, bilinear with wrap (the GPU's own sampling of mip 0)
	var L: float = patch.x if c == 0 else patch.y
	var u := X / L * NS - Vector2(0.5, 0.5)
	var i0 := Vector2i(floori(u.x), floori(u.y)); var f := u - Vector2(i0)
	var b: PackedByteArray = _hb[c]
	var out := Vector3.ZERO
	for k in 4:
		var ix := posmod(i0.x + (k & 1), NS); var iy := posmod(i0.y + (k >> 1), NS)
		var w := (f.x if k & 1 else 1.0 - f.x) * (f.y if k >> 1 else 1.0 - f.y)
		var o := (iy * NS + ix) * 8
		out += w * Vector3(b.decode_half(o), b.decode_half(o + 2), b.decode_half(o + 4))
	return out

func height_at(gx: float, gz: float) -> float:
	## the sea's height (m, about the still level) at Godot (x, z): the crest or trough that is drawn there, found by
	## undoing the sideways push (three fixed-point steps: X = x - D(X)), as the vertex shader places it. Cascades 2
	## and 3 (2.56 m, 0.32 m: millimetres in the lagoon) are left out. 0 until the first readback lands.
	_hb_mutex.lock()
	if _hb_t < 0.0 or _hb[0].size() < NS * NS * 8 or _hb[1].size() < NS * NS * 8:
		_hb_mutex.unlock(); return 0.0
	var x := Vector2(gx, -gz)              # island xy
	var X := x
	var D := Vector3.ZERO
	for it in 3:
		D = _disp_tap(0, X) + _disp_tap(1, X)
		X = x - Vector2(D.x, D.y)
	D = _disp_tap(0, X) + _disp_tap(1, X)
	_hb_mutex.unlock()
	return D.z

func _run(t: float) -> void:
	var v := PackedFloat32Array()
	for x in _spec + [patch, ring_hi, Vector4(t, SeaSpectrum.T_REPEAT, 0.0, 1.0 if self_test else 0.0)]:
		v.append_array([x.x, x.y, x.z, x.w])
	rd.buffer_update(_ubo, 0, v.size() * 4, v.to_byte_array())
	var g := NS / 16
	var foam_now: bool = foam_on and foam.get("on", false)   # no whitecaps (calm lagoon): no foam step, nothing spent
	if foam_now: _foam_prep(t)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, _pipes.sea_spectrum)
	rd.compute_list_bind_uniform_set(cl, _set_spec, 0)
	rd.compute_list_dispatch(cl, g, g, LAYERS)
	rd.compute_list_add_barrier(cl)
	var passes := [[1, 0], [16, 0], [1, 1], [16, 1]]
	for i in passes.size():
		rd.compute_list_bind_compute_pipeline(cl, _pipes.sea_fft)
		rd.compute_list_bind_uniform_set(cl, _set_fft[i % 2], 0)
		var pc := PackedInt32Array([passes[i][0], passes[i][1], 0, 0]).to_byte_array()
		rd.compute_list_set_push_constant(cl, pc, pc.size())
		rd.compute_list_dispatch(cl, g, g, LAYERS)
		rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, _pipes.sea_assemble)
	rd.compute_list_bind_uniform_set(cl, _set_asm, 0)
	var ac := PackedFloat32Array([SeaSpectrum.CHOP, 0, 0, 0]).to_byte_array()
	rd.compute_list_set_push_constant(cl, ac, ac.size())
	rd.compute_list_dispatch(cl, g, g, LAYERS)
	for m in range(1, MIPS):
		rd.compute_list_add_barrier(cl)
		var sz := maxi(NS >> m, 1)
		rd.compute_list_bind_compute_pipeline(cl, _pipes.sea_mip)
		rd.compute_list_bind_uniform_set(cl, _set_mip[m - 1], 0)
		var mc := PackedFloat32Array([0.25, 0, 0, 0]).to_byte_array()
		rd.compute_list_set_push_constant(cl, mc, mc.size())
		rd.compute_list_dispatch(cl, maxi(sz / 8, 1), maxi(sz / 8, 1), LAYERS)
	if foam_now: _foam_step(cl)
	rd.compute_list_end()
	if foam_now: rd.texture_copy(_fb, _fa, Vector3.ZERO, Vector3.ZERO, Vector3(FOAM_N, FOAM_N, 1), 0, 0, 0, 0)

func read_foam() -> PackedFloat32Array:
	## test helper (slow, render thread sync): the foam map as floats (r foam, g fresh, b break clock, a)
	var data := rd.texture_get_data(_fa, 0)
	var out := PackedFloat32Array(); out.resize(FOAM_N * FOAM_N * 4)
	for i in out.size(): out[i] = data.decode_half(i * 2)
	return out

func read_layer(which: String, layer: int) -> PackedFloat32Array:
	## test helper (slow, render thread sync): one cascade's mip 0 as floats (rgba per texel)
	var tex: RID = {"disp": _disp, "deriv": _deriv, "a": _wa, "b": _wb}[which]
	var data := rd.texture_get_data(tex, layer)
	if which == "disp" or which == "deriv":
		var out := PackedFloat32Array(); out.resize(NS * NS * 4)
		for i in out.size(): out[i] = data.decode_half(i * 2)
		return out
	return data.slice(0, NS * NS * 16).to_float32_array()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd:
		for r in _rids:
			if r.is_valid(): rd.free_rid(r)
