## Port check: the GDScript body rig (core/m04_body/body_rig.gd) must reproduce Gary's Thalassa v20.19 ik-rig.js
## (swim pose, shore walk/wade pose and their blend) driven by the same swimmer. Golden file recorded by
## tests/golden/body_trace.mjs. Both sides run the quiet brain stand-in until character-brain.js is ported.
## Run: godot --headless --path . --script res://tests/test_golden_body.gd   (exit 0 = every joint within 1 mm)
extends SceneTree

const Swimmer := preload("res://core/m02_motor/swimmer_locomotion.gd")
const Rig := preload("res://core/m04_body/body_rig.gd")
const G := preload("res://tests/test_golden_swimmer.gd")

const JOINTS := ["chest", "pelvis", "neck", "head", "elbowL", "handL", "handR", "kneeL", "ankleL", "ankleR"]

func _initialize() -> void:
	var gold: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/golden/body_v20_19.json"))
	var env := {"floor_height": G.floor_h, "terrain_normal": G.normal}
	var renv := {"floor_height": G.floor_h, "floor_normal": G.normal}
	var starts := {"shore": Vector3(0, 2.24, 4), "dive": Vector3(0, -3, -40)}
	var gs = G.new()
	var ok := true
	var worst_all := 0.0
	for name in ["shore", "dive"]:
		var s = Swimmer.new()
		s.set_pose(starts[name], 0.0, 0.0)
		var rig = Rig.new()
		var tr: Array = gold[name]
		var k := 0
		var worst := 0.0
		var worst_j := ""
		var worst_t := 0.0
		var modes_ok := true
		for i in 1200:
			var t := i / 60.0
			var inp: Dictionary = gs._input_for(name, t)
			rig.update_timers(1.0 / 60.0)
			s.update(1.0 / 60.0, inp, env)
			var p: Dictionary = rig.update_swim(1.0 / 60.0, s, inp, t, renv)
			if i % 10 == 9:
				var g: Array = tr[k]; k += 1
				if str(g[1]) != str(p.mode): modes_ok = false
				var mine := [p.chestPos, p.pelvisPos, p.neckPos, p.headMat.origin, p.armL.mid, p.armL.eff, p.armR.eff,
					p.legL.ik.mid, p.legL.ik.eff, p.legR.ik.eff]
				for j in mine.size():
					var d: float = mine[j].distance_to(Vector3(g[2 + j * 3], g[3 + j * 3], g[4 + j * 3]))
					if d > worst:
						worst = d; worst_j = JOINTS[j]; worst_t = t
		var pass_: bool = worst < 0.001 and modes_ok
		ok = ok and pass_
		worst_all = maxf(worst_all, worst)
		print("%s  golden body %s: worst %.6f m (%s at t=%.2f) over 20 s, pose modes %s" % ["PASS" if pass_ else "FAIL", name, worst, worst_j, worst_t, "match" if modes_ok else "DIFFER"])
	gs.free()
	print("M04 port vs Thalassa v20.19 ik-rig.js: %s (worst %.6f m)" % ["MATCH" if ok else "MISMATCH", worst_all])
	quit(0 if ok else 1)
