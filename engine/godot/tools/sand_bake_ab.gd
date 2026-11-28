## Sand bake A/B 0.1.0 (test level thread, 28 Nov 2026): the same frames with the sand's noise fields computed per pixel (A) and read
## from the bake (B, adapters/godot/sand_bake.gd). Prints mean / p99 / max CIE76 delta E per view (target: mean under 1) and saves
## A, B and a x8 difference picture. Also checks the bake's texel placement first.
## Run: xvfb-run -a godot --path . --resolution 960x540 --script res://tools/sand_bake_ab.gd -- <out dir> [half]
extends SceneTree

var out := "/tmp"
var half := false

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	half = a.size() > 1 and a[1] == "half"
	DirAccess.make_dir_recursive_absolute(out)
	var lvl := TestLevel.new(); root.add_child(lvl)
	_run.call_deferred(lvl)

static func _lab(c: Color) -> Vector3:
	var l := c.srgb_to_linear()
	var x := (0.4124 * l.r + 0.3576 * l.g + 0.1805 * l.b) / 0.95047
	var y := 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b
	var z := (0.0193 * l.r + 0.1192 * l.g + 0.9505 * l.b) / 1.08883
	var f := func(t: float) -> float: return pow(t, 1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0
	var fx: float = f.call(x); var fy: float = f.call(y); var fz: float = f.call(z)
	return Vector3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))

func _shot(lvl, pitch: float) -> Image:
	for i in 40:
		if lvl.game.cam: lvl.game.cam.pitch = pitch
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_viewport().get_texture().get_image()

func _run(lvl) -> void:
	while not lvl.ready_done: await process_frame
	var chk := SandBake.new()
	var ci: Image = await chk.render_check(root, Vector2i(4, 3))
	print("BAKECHECK fmt %d  t(0,0)=%s t(3,0)=%s t(0,2)=%s (want (0,0) (1,0) (0,1))" % [ci.get_format(), ci.get_pixel(0, 0), ci.get_pixel(3, 0), ci.get_pixel(0, 2)])
	var g = lvl.game
	while g.sand_bake == null: await process_frame
	print("BAKE px ", g.sand_bake.px, " box ", g.sand_bake.box, " ms ", g.sand_bake.ms)
	lvl.set_toggle("half_res", half)
	for t in [1, 0]:
		for pitch in [-0.25, -1.15]:
			lvl.teleport(t)
			g.set_sand_bake(false)
			var ia: Image = await _shot(lvl, pitch)
			g.set_sand_bake(true)
			var ib: Image = await _shot(lvl, pitch)
			var name := "tp%d_pitch%.2f%s" % [t, pitch, "_half" if half else ""]
			ia.save_png(out.path_join(name + "_A_procedural.png")); ib.save_png(out.path_join(name + "_B_baked.png"))
			var d := Image.create(ia.get_width(), ia.get_height(), false, Image.FORMAT_RGB8)
			var es := PackedFloat32Array()
			for y in range(0, ia.get_height(), 2):
				for x in range(0, ia.get_width(), 2):
					var ca := ia.get_pixel(x, y); var cb := ib.get_pixel(x, y)
					es.append(_lab(ca).distance_to(_lab(cb)))
					var dd := Color(absf(ca.r - cb.r) * 8.0, absf(ca.g - cb.g) * 8.0, absf(ca.b - cb.b) * 8.0)
					d.set_pixel(x, y, dd); d.set_pixel(mini(x + 1, ia.get_width() - 1), y, dd)
			d.save_png(out.path_join(name + "_diff_x8.png"))
			var m := 0.0
			for e in es: m += e
			es.sort()
			print("SANDAB %s dE mean %.3f p99 %.2f max %.2f  share>2 %.2f%%" % [name, m / es.size(), es[int(es.size() * 0.99)], es[es.size() - 1],
				100.0 * (es.size() - es.bsearch(2.0)) / es.size()])
	quit()
