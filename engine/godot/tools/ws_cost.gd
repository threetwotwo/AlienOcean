## WS cost 0.1.0 (test level thread, 28 Nov 2026): where the ground shader (look/ground_surface.gdshader + the generated
## look/world_surface.gdshaderinc) spends its work. Swaps every ground material in the test level for a copy whose
## WS_COUNT_* hooks count texture reads and hashes per pixel, drawn unshaded as R = reads / 64, G = hashes / 256, B = 1 (floor).
## Prints per view the mean and 95th percentile reads and hashes over floor pixels, and saves the pictures.
## Run: xvfb-run -a godot --path . --resolution 960x540 --script res://tools/ws_cost.gd -- <out dir>
extends SceneTree

var out := "/tmp"

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	DirAccess.make_dir_recursive_absolute(out)
	var lvl := TestLevel.new(); root.add_child(lvl)
	_run.call_deferred(lvl)

func _cost_shader() -> Shader:
	var ws := FileAccess.get_file_as_string("res://look/world_surface.gdshaderinc")
	ws = ws.replace("#define WS_COUNT_HASH\n", "#define WS_COUNT_HASH Wg_.cH += 1.;\n")
	ws = ws.replace("#define WS_COUNT_READ\n", "#define WS_COUNT_READ Wg_.cR += 1.;\n")
	ws = ws.replace("#define WS_COUNT_READ4\n", "#define WS_COUNT_READ4 Wg_.cR += 4.;\n")
	var g := FileAccess.get_file_as_string("res://look/ground_surface.gdshader")
	g = g.replace('#include "res://look/world_surface.gdshaderinc"', ws)
	g = g.replace("render_mode blend_mix, cull_back, diffuse_lambert, specular_disabled;", "render_mode unshaded, cull_back;")
	var li := g.find("void light()")
	g = g.substr(0, li)
	var end := g.rfind("}")
	g = g.substr(0, end) + "\tALBEDO = vec3(Wg.cR / 64.0, Wg.cH / 256.0, 1.0); EMISSION = vec3(0.0); AO = 1.0;\n}\n"
	var sh := Shader.new(); sh.code = g
	return sh

func _run(lvl) -> void:
	while not lvl.ready_done: await process_frame
	var sh := _cost_shader()
	# a separate world (no tonemapper, water view or fog to bend the counts): the ground surfaces only, drawn with the counter
	var vp := SubViewport.new(); vp.own_world_3d = true; vp.size = Vector2i(960, 540); vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var cam := Camera3D.new(); vp.add_child(cam)
	var n := 0
	for mi in lvl.game.lagoon.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m = mi.get_surface_override_material(s)
			if m is ShaderMaterial and m.shader != null and m.shader.resource_path == "res://look/ground_surface.gdshader":
				var c: ShaderMaterial = m.duplicate(); c.shader = sh
				var d := MeshInstance3D.new(); d.mesh = mi.mesh; vp.add_child(d); d.global_transform = mi.global_transform
				for k in mi.mesh.get_surface_count(): d.set_surface_override_material(k, c)
				n += 1
				break
	print("WSCOST copied ", n, " ground meshes")
	for t in [1, 0]:
		for pitch in [-0.25, -1.15]:
			lvl.teleport(t)
			for i in 30:
				if lvl.game.cam: lvl.game.cam.pitch = pitch
				await process_frame
			var mc := root.get_viewport().get_camera_3d()
			cam.global_transform = mc.global_transform; cam.fov = mc.fov; cam.near = mc.near; cam.far = mc.far
			for i in 3: await process_frame
			await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			var name := "tp%d_pitch%.2f" % [t, pitch]
			img.save_png(out.path_join(name + ".png"))
			var rs := PackedFloat32Array(); var hs := PackedFloat32Array()
			for y in range(0, img.get_height(), 3):
				for x in range(0, img.get_width(), 3):
					var c := img.get_pixel(x, y)
					if c.a < 0.5: continue
					var l := c.srgb_to_linear()
					rs.append(l.r * 64.0); hs.append(l.g * 256.0)
			rs.sort(); hs.sort()
			var k := rs.size()
			var mr := 0.0; var mh := 0.0
			for i in k: mr += rs[i]; mh += hs[i]
			print("WSCOST %s floor_px %.0f%% reads mean %.1f p95 %.1f max %.1f | hashes mean %.1f p95 %.1f max %.1f" % [name,
				100.0 * k / (img.get_width() * img.get_height() / 9.0), mr / maxf(k, 1), rs[int(k * 0.95)] if k > 0 else 0.0,
				rs[k - 1] if k > 0 else 0.0, mh / maxf(k, 1), hs[int(k * 0.95)] if k > 0 else 0.0, hs[k - 1] if k > 0 else 0.0])
	quit()
