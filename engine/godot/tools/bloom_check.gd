## Bloom check 0.1.0 (bloom thread, 28 Nov 2026): a planted scene with a known answer for the glare in AgxEffect (look/bloom.glsl).
## A small bright square on black; the source buffer and the five glare parts are read back from the GPU and measured.
## B1 energy kept: the glare's total equals the light taken above the threshold (within 3 %).
## B2 shape: the glare's radial profile matches the key frame's PSF (develop_v7.py: gaussians sigma 1.5/4/12/36/90 px at 960
##    wide, weights .45/.25/.17/.09/.04) at 6, 15, 40, 100 and 220 px, within 30 %.
## B3 no positional flicker: the square slides 0.13 px a frame for 8 frames; the wide halo (per unit of excess) varies < 3 %.
## Planted fault --fault: PSF weights skewed to the core ([.9,.1,0,0,0]); B2 must fail.
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/bloom_check.gd [-- --fault]
extends SceneTree

const W := 960
const H := 540
var fx: AgxEffect
var quad: MeshInstance3D
var cam: Camera3D
var frame := 0
var phase := 0
var halo := []
var ok := true
var fault := false

func _initialize() -> void:
	fault = "--fault" in OS.get_cmdline_user_args()
	root.size = Vector2i(W, H)
	var env := Environment.new(); env.background_mode = Environment.BG_COLOR; env.background_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR; env.glow_enabled = false
	var we := WorldEnvironment.new(); we.environment = env; root.add_child(we)
	fx = AgxEffect.new(); fx.exposure = 1.0; fx.buf_scale = 1.0; fx.bloom = 1.0; fx.bloom_thr = 4.5
	if fault: fx.bloom_w = PackedFloat32Array([0.9, 0.1, 0.0, 0.0, 0.0])
	var comp := Compositor.new(); comp.compositor_effects = [fx]; we.compositor = comp
	cam = Camera3D.new(); cam.projection = Camera3D.PROJECTION_ORTHOGONAL; cam.size = float(H)   # 1 m = 1 px
	cam.position = Vector3(0, 0, 10); root.add_child(cam); cam.current = true
	quad = MeshInstance3D.new(); var qm := QuadMesh.new(); qm.size = Vector2(4, 4); quad.mesh = qm
	var sm := ShaderMaterial.new(); sm.shader = Shader.new()
	sm.shader.code = "shader_type spatial; render_mode unshaded; void fragment() { ALBEDO = vec3(40.0); }"
	quad.material_override = sm; root.add_child(quad)

func _half(b: PackedByteArray, i: int) -> float:
	return b.decode_half(i * 8 + 2)   # green channel of RGBA16F

func _sum(b: PackedByteArray, n: int, f: Callable) -> float:
	var s := 0.0
	for i in n: s += f.call(_half(b, i))
	return s

func _at(part: Array, x: float, y: float) -> float:
	## bilinear read of a glare part at internal pixel (x, y), in normalised uv as the AgX pass samples it
	var sz: Vector2i = part[1]; var b: PackedByteArray = part[0]
	var u := x / W * sz.x - 0.5; var v := y / H * sz.y - 0.5
	var x0 := clampi(int(floor(u)), 0, sz.x - 1); var y0 := clampi(int(floor(v)), 0, sz.y - 1)
	var x1 := mini(x0 + 1, sz.x - 1); var y1 := mini(y0 + 1, sz.y - 1)
	var fx_ := clampf(u - floor(u), 0, 1); var fy := clampf(v - floor(v), 0, 1)
	var g := func(xx: int, yy: int) -> float: return _half(b, yy * sz.x + xx)
	return lerpf(lerpf(g.call(x0, y0), g.call(x1, y0), fx_), lerpf(g.call(x0, y1), g.call(x1, y1), fx_), fy)

func _process(_d: float) -> bool:
	frame += 1
	if frame == 6 or (phase == 1 and frame % 3 == 0): fx.dump = true
	if fx.dumped.is_empty(): return false
	var d: Dictionary = fx.dumped; fx.dumped = {}
	var src: PackedByteArray = d.src[0]
	var thr := fx.bloom_thr; var mx := fx.bloom_max
	var e_in := _sum(src, W * H, func(v): return clampf(v - thr, 0.0, mx))
	var e_out := 0.0
	for k in 5:
		var p: Array = d.parts[k]; var sz: Vector2i = p[1]
		e_out += fx.bloom_w[k] * _sum(p[0], sz.x * sz.y, func(v): return v) * float(W * H) / float(sz.x * sz.y)
	if phase == 0:
		var r1 := e_out / maxf(e_in, 1e-9)
		var b1 := absf(r1 - 1.0) < 0.03
		print("B1 energy kept: glare %.1f / excess %.1f = %.3f: %s" % [e_out, e_in, r1, "PASS" if b1 else "FAIL"]); ok = ok and b1
		var b2 := true
		for r in [6.0, 15.0, 40.0, 100.0, 220.0]:
			var got := 0.0
			for k in 5: got += fx.bloom_w[k] * _at(d.parts[k], W * 0.5 + r, H * 0.5)
			var want := 0.0
			for k in 5:
				var s: float = AgxEffect.BLOOM_SIG[k] * W / 960.0
				want += AgxEffect.new().bloom_w[k] / (TAU * s * s) * exp(-r * r / (2.0 * s * s))
			want *= e_in
			var q := got / maxf(want, 1e-12)
			var pass_r := absf(q - 1.0) < 0.3
			print("  r %3d px: glare %.5f, key frame PSF %.5f (x%.2f) %s" % [r, got, want, q, "ok" if pass_r else "off"]); b2 = b2 and pass_r
		print("B2 shape matches the key frame PSF: %s" % ("PASS" if b2 else "FAIL")); ok = ok and b2
		phase = 1; frame = 0
		return false
	var h := 0.0
	for k in [2, 3, 4]: h += fx.bloom_w[k] * _at(d.parts[k], W * 0.5 + quad.position.x + 60.0, H * 0.5)
	halo.append(h / maxf(e_in, 1e-9))
	quad.position.x += 0.13 * 3.0
	if halo.size() < 8: return false
	var m := 0.0
	for v in halo: m += v
	m /= halo.size()
	var dev := 0.0
	for v in halo: dev = maxf(dev, absf(v / m - 1.0))
	var b3 := dev < 0.03
	print("B3 halo steady while the square slides (max deviation %.2f %%): %s" % [dev * 100.0, "PASS" if b3 else "FAIL"]); ok = ok and b3
	print("BLOOM CHECK: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
	return false
