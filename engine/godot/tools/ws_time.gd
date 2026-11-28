## WS time 0.1.0 (test level thread, 28 Nov 2026): which part of the ground shader the frame time goes to. Swaps every ground
## material in the test level for variants of look/ground_surface.gdshader made by text edits, and times frames at two views.
## A relative proxy on the cloud's CPU renderer (lavapipe): compare variants against each other, not against the Mac.
## Variants: full | no_caustic (sun_under -> 1) | no_ripple (SandRipples skipped) | flat_surface (GroundBlend -> constant)
## | none (both). Run: xvfb-run -a godot --path . --resolution 960x540 --script res://tools/ws_time.gd [-- frames]
extends SceneTree

var frames := 12
const GS := "res://look/ground_surface.gdshader"

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: frames = int(a[0])
	var lvl := TestLevel.new(); root.add_child(lvl)
	_run.call_deferred(lvl)

func _variant(v: String) -> Shader:
	var g := FileAccess.get_file_as_string(GS)
	var call := "WsSurf S = GroundBlend(Wg, P, N, fp, G, rBC, rN, rORM, tBC, tN, tORM, cBC, cN, cORM, gBC, gN, gM, dBC, dN, dM, fA, fB, fC, fD);"
	var flat := "WsSurf S; S.alb = vec3(0.6, 0.55, 0.45) * COLOR.rgb; S.n = N; S.ao = 1.0; S.rough = 0.8; S.pm = 0.0; S.fp = fp;"
	var sun := "vec3 sun_k = sun_under(wpos, sun_under_pixel_m(wpos, INV_VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE), TIME, caustic_strength);"
	assert(g.find(call) >= 0 and g.find(sun) >= 0)
	if v in ["flat_surface", "none"]: g = g.replace(call, flat)
	if v in ["no_caustic", "none"]: g = g.replace(sun, "vec3 sun_k = vec3(1.0);")
	if v == "no_ripple": g = g.replace("G.noRipple = 0.;", "G.noRipple = 1.;")
	var sh := Shader.new(); sh.code = g
	return sh

func _run(lvl) -> void:
	while not lvl.ready_done: await process_frame
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var mats: Array[ShaderMaterial] = []
	for mi in lvl.game.lagoon.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m = mi.get_surface_override_material(s)
			if m is ShaderMaterial and m.shader != null and m.shader.resource_path == GS and not m in mats: mats.append(m)
	print("WSTIME ground materials ", mats.size())
	var variants := ["full", "no_caustic", "no_ripple", "flat_surface", "none", "full"]
	var shaders := {}
	for v in variants: if not shaders.has(v): shaders[v] = _variant(v)
	for t in [1, 0]:
		for pitch in [-0.25, -1.15]:
			lvl.teleport(t)
			for i in 20:
				if lvl.game.cam: lvl.game.cam.pitch = pitch
				await process_frame
			var line := "WSTIME tp%d_pitch%.2f" % [t, pitch]
			for v in variants:
				for m in mats: m.shader = shaders[v]
				for i in 4:
					if lvl.game.cam: lvl.game.cam.pitch = pitch
					await process_frame
				var ts := PackedFloat32Array()
				var last := Time.get_ticks_usec()
				for i in frames:
					if lvl.game.cam: lvl.game.cam.pitch = pitch
					await process_frame
					var now := Time.get_ticks_usec(); ts.append((now - last) / 1000.0); last = now
				ts.sort()
				line += " | %s %.0f" % [v, ts[ts.size() / 2]]
			print(line)
	quit()
