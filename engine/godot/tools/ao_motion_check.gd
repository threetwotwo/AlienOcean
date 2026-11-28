## AO motion check 0.1.0 (ao thread, 28 Nov 2026): does the screen AO shimmer while the camera moves? (Gary's no-jitter rule)
## The cortao_check scene (boxes on a floor, flat grey ambient, no sun) filmed by a camera sliding sideways at swim speed
## (0.5 m/s, slight turn), half resolution each way + FSR 1 + Godot TAA (the game's half_res default). Per pixel, the second
## difference over time f(t) - 2 f(t-1) + f(t-2) cancels smooth motion; what is left is flicker. Reported as RMS (8-bit levels)
## over smooth pixels (spatial step under 3 levels: silhouettes are left out) of the frame and of the AO-shadowed areas. Compare a mode against "off" (TAA jitter + geometry edges are in both):
## the AO's own flicker is mode minus off.
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --fixed-fps 30 --script res://tools/ao_motion_check.gd -- <out dir>
## Env: AO_MODE=cortao|gtao|vbao|ssao|off (default cortao), AO_TAA=0 (no TAA, full resolution), AO_FRAMES (default 40).
extends SceneTree

var out := "/tmp"
var mode := "cortao"
var taa := true
var frames := 40
var cam: Camera3D
var fx: CortaoEffect
var env: Environment
var prev: Array = []          # last two luminance frames (PackedFloat32Array)
var top := 0.0               # the open floor's luminance (the brightest surface), from the first frame
var acc_all := 0.0
var acc_sh := 0.0
var n_all := 0
var n_sh := 0

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if OS.get_environment("AO_MODE") != "": mode = OS.get_environment("AO_MODE")
	taa = OS.get_environment("AO_TAA") != "0"
	if OS.get_environment("AO_FRAMES") != "": frames = int(OS.get_environment("AO_FRAMES"))
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(960, 540)
	if taa:
		root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
		root.scaling_3d_scale = 0.5
		root.use_taa = true
	WorldRoot.declare_globals()
	_run.call_deferred()

func _box(pos: Vector3, size: Vector3, mat: Material, rot := 0.0) -> void:
	var mi := MeshInstance3D.new(); var m := BoxMesh.new(); m.size = size; mi.mesh = m; mi.material_override = mat
	mi.position = pos; mi.rotation.y = rot; root.add_child(mi)

func _run() -> void:
	var sm := ShaderMaterial.new()
	sm.shader = Shader.new()
	sm.shader.code = """shader_type spatial;
#include "res://look/screen_ao.gdshaderinc"
void fragment() { ALBEDO = vec3(0.7); ROUGHNESS = 1.0; AO = min(AO, screen_ao(SCREEN_UV)); }"""
	_box(Vector3(0, -0.05, 0), Vector3(30, 0.1, 30), sm)
	# a row of boxes and slabs: contact corners, a gap, an overhang (the shapes AO lives on)
	_box(Vector3(0, 0.5, 0), Vector3(1, 1, 1), sm)
	_box(Vector3(1.6, 0.3, -0.6), Vector3(0.6, 0.6, 0.6), sm, 0.5)
	_box(Vector3(-1.5, 0.25, 0.4), Vector3(1.2, 0.5, 0.5), sm, -0.3)
	_box(Vector3(-0.4, 0.9, -1.4), Vector3(2.0, 0.15, 0.8), sm)
	_box(Vector3(-1.2, 0.45, -1.4), Vector3(0.2, 0.9, 0.2), sm)
	_box(Vector3(0.4, 0.45, -1.4), Vector3(0.2, 0.9, 0.2), sm)
	_box(Vector3(2.8, 0.2, 0.8), Vector3(0.4, 0.4, 2.0), sm, 0.2)
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR; env.background_color = Color(0.3, 0.4, 0.5)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; env.ambient_light_color = Color(1, 1, 1); env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ssao_enabled = mode == "ssao"; env.ssao_radius = 1.2; env.ssao_intensity = 1.6
	var we := WorldEnvironment.new(); we.environment = env
	fx = CortaoEffect.new()
	var screen := mode in ["cortao", "gtao", "vbao"]
	fx.enabled = screen
	if screen: fx.algo = mode
	var comp := Compositor.new(); comp.compositor_effects = [fx]; we.compositor = comp
	root.add_child(we)
	RenderingServer.global_shader_parameter_set("cortao_on", 1.0 if screen else 0.0)
	cam = Camera3D.new(); root.add_child(cam)
	_place(0.0)
	cam.current = true
	for i in 20:   # settle (TAA history, targets) at the start pose
		await process_frame
	for i in frames:
		_place(float(i + 1) / 30.0)
		await RenderingServer.frame_post_draw
		_take(root.get_texture().get_image(), i)
	var r_all := sqrt(acc_all / maxf(n_all, 1)) * 255.0
	var r_sh := sqrt(acc_sh / maxf(n_sh, 1)) * 255.0
	print("AO_MOTION mode=%s taa=%s flicker_rms_all %.3f flicker_rms_shadow %.3f (levels) shadow px/frame %d" % [mode, str(taa), r_all, r_sh, n_sh / maxi(frames - 2, 1)])
	quit(0)

func _place(t: float) -> void:
	## slide sideways at 0.5 m/s with a slow turn, looking at the boxes
	cam.position = Vector3(2.6 - 0.5 * t, 1.5, 3.0)
	cam.look_at(Vector3(0.3 - 0.3 * t, 0.3, -0.3))

func _lum(img: Image) -> PackedFloat32Array:
	var w := img.get_width(); var h := img.get_height()
	var d := img.get_data()   # RGBA8 or RGB8
	var ch := 4 if img.get_format() == Image.FORMAT_RGBA8 else 3
	var l := PackedFloat32Array(); l.resize(w * h)
	for i in w * h:
		l[i] = (0.2126 * d[i * ch] + 0.7152 * d[i * ch + 1] + 0.0722 * d[i * ch + 2]) / 255.0
	return l

func _take(img: Image, i: int) -> void:
	var l := _lum(img)
	if i == 0:
		for v in l: top = maxf(top, v)
	if i == frames / 2: img.save_png(out.path_join("ao_motion_%s%s.png" % [mode, "" if taa else "_notaa"]))
	if OS.get_environment("AO_SAVE_SEQ") != "" and absi(i - frames / 2) <= 1: img.save_png(out.path_join("seq_%s_%d.png" % [mode, i]))
	if prev.size() == 2:
		var a: PackedFloat32Array = prev[0]; var b: PackedFloat32Array = prev[1]
		var w := img.get_width()
		for k in range(w + 1, l.size() - w - 1):
			# smooth surfaces only: silhouettes (TAA re-solving an edge as it moves) would swamp the AO's own flicker
			var g := maxf(absf(b[k + 1] - b[k - 1]), absf(b[k + w] - b[k - w]))
			if g > 3.0 / 255.0: continue
			var s := l[k] - 2.0 * b[k] + a[k]
			acc_all += s * s; n_all += 1
			if b[k] < top * 0.96 and b[k] > top * 0.3: acc_sh += s * s; n_sh += 1   # AO-shadowed (4 %+ darker than open floor), in the middle frame
	prev.append(l)
	if prev.size() > 2: prev.pop_front()
