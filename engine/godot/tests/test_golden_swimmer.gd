## Port check: the GDScript swimmer (core/m02_motor/swimmer_locomotion.gd) must reproduce Gary's Thalassa v20.19
## swimmer-physics.js tick for tick. Golden file recorded by tests/golden/swimmer_trace.mjs (same input, same env).
## Run: godot --headless --path . --script res://tests/test_golden_swimmer.gd   (exit 0 = match within 1 mm)
extends SceneTree

const Swimmer := preload("res://core/m02_motor/swimmer_locomotion.gd")

static func floor_h(_x: float, z: float) -> float:
	return 1.0 if z > 0.0 else maxf(-6.0, 1.0 + z * tan(deg_to_rad(12.0)))

static func normal(x: float, z: float) -> Vector3:
	if z > 0.0 or floor_h(x, z) <= -6.0: return Vector3.UP
	return Vector3(0, cos(deg_to_rad(12.0)), sin(deg_to_rad(12.0)))

func _input_for(name: String, t: float) -> Dictionary:
	if name == "shore":
		return {"forward": 1.0 if t < 12 else (0.0 if t < 14 else -1.0), "right": 0.0, "up": 0.0, "boost": t > 3 and t < 6,
			"boost_just_pressed": false, "jump_held": t > 1.5 and t < 1.6, "yaw_delta": 0.0, "pitch_delta": 0.0, "smoothing": 0.35}
	return {"forward": 1.0, "right": 0.5 if t > 4 else 0.0, "up": -1.0 if t < 3 else (1.0 if t > 6 else 0.0), "boost": t > 2 and t < 5,
		"boost_just_pressed": absf(t - 2.0167) < 0.009, "jump_held": false, "yaw_delta": 0.02 if t > 5 else 0.0,
		"pitch_delta": -0.01 if t < 1 else 0.0, "smoothing": 0.35}

func _initialize() -> void:
	var gold: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/golden/swimmer_v20_19.json"))
	var env := {"floor_height": floor_h, "terrain_normal": normal}
	var starts := {"shore": [Vector3(0, 2.24, 4), 0.0, 0.0], "dive": [Vector3(0, -3, -40), 0.0, 0.0]}
	var worst := 0.0
	var ok := true
	for name in ["shore", "dive"]:
		var s = Swimmer.new()
		s.config.thalassa_exact = true
		s.set_pose(starts[name][0], starts[name][1], starts[name][2])
		var tr: Array = gold[name]
		var k := 0
		var case_worst := 0.0
		var modes_ok := true
		for i in 1200:
			var t := i / 60.0
			s.update(1.0 / 60.0, _input_for(name, t), env)
			if i % 10 == 9:
				var g: Array = tr[k]; k += 1
				var d: float = s.pos.distance_to(Vector3(g[1], g[2], g[3]))
				case_worst = maxf(case_worst, d)
				if int(g[4]) != (1 if s.shore_grounded else 0): modes_ok = false
		worst = maxf(worst, case_worst)
		var pass_: bool = case_worst < 0.001 and modes_ok
		ok = ok and pass_
		print("%s  golden %s: worst %.6f m over 20 s, grounded/swimming states %s" % ["PASS" if pass_ else "FAIL", name, case_worst, "match" if modes_ok else "DIFFER"])
	print("M02 port vs Thalassa v20.19: %s (worst %.6f m)" % ["MATCH" if ok else "MISMATCH", worst])
	quit(0 if ok else 1)
