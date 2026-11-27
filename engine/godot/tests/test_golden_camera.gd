## Port check: core/m03_camera/nocut_camera.gd must reproduce Gary's Thalassa v20.19 cinematic-camera.js updateForActor
## (springs, Living Observer, spring arm against floor + colliders, 3P <-> 1P morph). Golden: tests/golden/camera_trace.mjs.
## Run: godot --headless --path . --script res://tests/test_golden_camera.gd
extends SceneTree

const Cam := preload("res://core/m03_camera/nocut_camera.gd")

static func floor_h(x: float, _z: float) -> float:
	return -3.0 + 0.2 * sin(x * 0.3)

func _initialize() -> void:
	var gold: Array = JSON.parse_string(FileAccess.get_file_as_string("res://tests/golden/camera_v20_19.json"))
	var cam = Cam.new()
	var env := {"floor_height": floor_h, "colliders": [{"x": 2.0, "y": -1.0, "z": -6.0, "r": 1.2}, {"x": -3.0, "y": -0.5, "z": -12.0, "r": 0.8}]}
	var prof := {"dist": 1.38, "dist_speed_add": 0.24, "dist_boost_add": 0.14, "shoulder_x": 0.24, "shoulder_y": 0.11, "look_ahead": 6.2,
		"ots_fov": 74.0, "ots_fov_speed_add": 3.5, "fp_fov_cap": 82.0, "ots_roll_scale": 0.32, "ots_level_up": 0.85, "carve_lead_scale": 0.16, "head_hide_dist": 0.34}
	var k := 0
	var worst := 0.0
	var worst_fov := 0.0
	for i in 900:
		var t := i / 60.0
		var p := Vector3(3 * sin(t * 0.4), -1.0 - 1.6 * pow(sin(t * 0.25), 2), -2 - 2.2 * t)
		var frame := {"id": "swimmer", "kind": "swimmer", "pos": p, "fp_pos": Vector3(p.x, p.y + 0.03 * sin(t * 6), p.z), "head_pos": p,
			"vel": Vector3(1.2 * cos(t * 0.4), -0.4 * sin(t * 0.5), -2.2), "yaw": 0.3 * sin(t * 0.7), "pitch": -0.2 + 0.5 * sin(t * 0.33),
			"roll": 0.05 * sin(t), "fov": 74 + 2 * sin(t), "max_speed": 5.0, "is_boosting": t > 6 and t < 9, "radius": 0.55,
			"keep_under_surface": p.y < -0.35, "surface_ceiling_y": -0.30, "floor_margin": 0.44, "camera_profile": prof}
		var o: Dictionary = cam.update_for_actor(1.0 / 60.0, frame, {"third_person": int(floor(t / 2.5)) % 2 == 0,
			"landing_impact": 0.8 if (t > 10 and t < 10.2) else 0.0, "braking_impulse": 0.0}, env)
		if i % 5 == 4:
			var g: Array = gold[k]; k += 1
			var dd := maxf(o.pos.distance_to(Vector3(g[0], g[1], g[2])), o.look_target.distance_to(Vector3(g[3], g[4], g[5])))
			if OS.get_environment("CAMDBG") != "" and dd > 1e-4 and worst <= 1e-4: print("diverge t=%.3f pos %s gold %s look %s gold %s blend %.4f/%.4f arm %.4f/%.4f" % [t, o.pos, Vector3(g[0], g[1], g[2]), o.look_target, Vector3(g[3], g[4], g[5]), o.third_person_blend, g[8], o.arm_pull, g[9]])
			worst = maxf(worst, dd)
			worst_fov = maxf(worst_fov, absf(o.fov - g[6]))
	var ok := worst < 0.001 and worst_fov < 0.01
	print("%s  M03 port vs Thalassa v20.19 cinematic-camera.js: worst %.6f m (lens and look target), fov %.5f deg over 15 s" % ["PASS" if ok else "FAIL", worst, worst_fov])
	quit(0 if ok else 1)
