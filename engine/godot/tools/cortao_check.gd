## CORTAO check 0.1.0 (ao thread, 28 Nov 2026): a planted scene with a known answer for adapters/godot/cortao_effect.gd.
## A 1 m box stands on a floor under a flat grey ambient (no sun). Checks:
##   C1 contact: floor 5 cm from the box's foot is occluded (CORTAO r < 0.80)
##   C2 open: floor 3 m from the box is open (r > 0.95)
##   C3 top: the box's top face is open (r > 0.95)
##   C4 lit image: the contact floor is darker than the open floor by >= 10 % with CORTAO on (it reaches the material)
##   C5 grain: high-pass std of the AO in the soft shadow < 0.02 (no speckle: SIMPLICITY, noise is not detail)
##   C6 no screen door: in the same patch, the high-pass's correlation at a 3 px lag (CORTAO's filter tap spacing) < 0.35
## Planted faults: --fault flip renders with flip_y inverted (the AO lands mirrored), which must fail C1 or C3;
## --fault coarse makes the last filter pass use CORTAO's 3 px taps again (the lattice comes back), which must fail C6.
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/cortao_check.gd -- <out dir> [--fault flip]
extends SceneTree

var out := "/tmp"
var fault := ""

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if "--fault" in a: fault = a[a.find("--fault") + 1]
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(960, 540)
	WorldRoot.declare_globals()
	_run.call_deferred()

func _box(pos: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new(); var m := BoxMesh.new(); m.size = size; mi.mesh = m; mi.material_override = mat
	mi.position = pos; root.add_child(mi)

func _run() -> void:
	var sm := ShaderMaterial.new()
	sm.shader = Shader.new()
	sm.shader.code = """shader_type spatial;
#include "res://look/screen_ao.gdshaderinc"
void fragment() { ALBEDO = vec3(0.7); ROUGHNESS = 1.0; AO = min(AO, screen_ao(SCREEN_UV)); }"""
	_box(Vector3(0, -0.05, 0), Vector3(20, 0.1, 20), sm)
	_box(Vector3(0, 0.5, 0), Vector3(1, 1, 1), sm)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR; env.background_color = Color(0.3, 0.4, 0.5)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; env.ambient_light_color = Color(1, 1, 1); env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new(); we.environment = env
	var fx := CortaoEffect.new()
	if fault == "flip": fx.invert_flip = true
	if OS.get_environment("CORTAO_PASSES") != "": fx.filter_passes = int(OS.get_environment("CORTAO_PASSES"))
	var comp := Compositor.new(); comp.compositor_effects = [fx]; we.compositor = comp
	root.add_child(we)
	RenderingServer.global_shader_parameter_set("cortao_on", 1.0)
	var cam := Camera3D.new(); root.add_child(cam)
	cam.position = Vector3(2.2, 1.6, 2.6); cam.look_at(Vector3(0, 0.3, 0)); cam.current = true
	for i in 20: await process_frame
	fx.capture_next = true
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	var lit := root.get_texture().get_image()
	lit.save_png(out.path_join("cortao_check_lit%s.png" % ("_" + fault if fault != "" else "")))
	var ao: Image = fx.captured
	if ao == null: print("FAIL C0 no CORTAO capture"); quit(1); return
	ao.save_png(out.path_join("cortao_check_ao%s.png" % ("_" + fault if fault != "" else "")))
	var sx := float(ao.get_width()) / float(lit.get_width())
	var at := func(img: Image, w: Vector3, s: float) -> float:
		var p := cam.unproject_position(w) * s
		var acc := 0.0
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				acc += img.get_pixel(clampi(int(p.x) + dx, 0, img.get_width() - 1), clampi(int(p.y) + dy, 0, img.get_height() - 1)).r
		return acc / 25.0
	var contact: float = at.call(ao, Vector3(0.55, 0.0, 0.2), sx)
	var open: float = at.call(ao, Vector3(2.5, 0.0, -1.5), sx)
	var top: float = at.call(ao, Vector3(0.0, 1.0, 0.0), sx)
	var lc: float = at.call(lit, Vector3(0.55, 0.0, 0.2), 1.0)
	var lo: float = at.call(lit, Vector3(2.5, 0.0, -1.5), 1.0)
	# C5 grain: high-pass (pixel minus its 7x7 mean) std over a 40 x 40 patch of the box's soft shadow on the floor
	var cpx := cam.unproject_position(Vector3(0.0, 0.0, 0.9)) * sx
	var hp := PackedFloat32Array()
	for y in range(int(cpx.y) - 20, int(cpx.y) + 20):
		for x in range(int(cpx.x) - 20, int(cpx.x) + 20):
			var m := 0.0
			for dy in range(-3, 4):
				for dx in range(-3, 4): m += ao.get_pixel(x + dx, y + dy).r
			hp.append(ao.get_pixel(x, y).r - m / 49.0)
	var v := 0.0
	for h in hp: v += h * h
	var grain := sqrt(v / hp.size())
	# C6: correlation of the high-pass with itself 3 px to the right and 3 px down (40 x 40 patch, row-major)
	var c3 := 0.0
	var n3 := 0
	for y in 40:
		for x in 37:
			c3 += hp[y * 40 + x] * hp[y * 40 + x + 3]; n3 += 1
	for y in 37:
		for x in 40:
			c3 += hp[y * 40 + x] * hp[(y + 3) * 40 + x]; n3 += 1
	var lat := (c3 / n3) / maxf(v / hp.size(), 1e-12)
	var rows := [["C5 grain (high-pass std) < 0.02", grain < 0.02, grain], ["C1 contact r < 0.80", contact < 0.80, contact], ["C2 open floor r > 0.95", open > 0.95, open],
		["C6 no screen door: 3 px lag correlation < 0.35", lat < 0.35, lat], ["C3 box top r > 0.95", top > 0.95, top], ["C4 lit contact/open <= 0.90", lc / maxf(lo, 1e-4) <= 0.90, lc / maxf(lo, 1e-4)]]
	var all := true
	for r in rows:
		print("%s %s  (%.3f)" % ["PASS" if r[1] else "FAIL", r[0], r[2]]); all = all and r[1]
	print("CORTAO gpu ms %.2f at %s" % [fx.gpu_ms, str(lit.get_size())])
	print("CORTAO_CHECK ", "ALL GREEN" if all else "FAILURES", " fault=", fault)
	quit(0 if all else 1)
