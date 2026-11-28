## Port check: the GDScript brain (core/m04_body/character_brain.gd, exact = true) must reproduce Gary's Thalassa v20.19
## character-brain.js on five scripted 25 s sense sequences (swim past POIs, stand idle, walk / run / jump, swim along a
## wall, hover with focus intent; sounds in each). Golden file recorded by tests/golden/brain_trace.mjs; the scenes below
## mirror its generators line for line.
## Compared every 3rd tick: gaze direction, head tilt, torso yaw, hip shift, lean, breath phase / signal / amp / rate,
## gaze blend, both hands' touch weight and target (continuous, worst absolute error reported, tolerance TOL), and the
## focus label, mood, state, visible POI count and objective focus (must be identical).
## Run: godot --headless --path . --script res://tests/test_golden_brain.gd [-- --fault]   (exit 0 = match)
## --fault plants a port bug (glance blend 0.62 -> 0.58) and the run must FAIL (run_all.sh checks that).
extends SceneTree

const Brain := preload("res://core/m04_body/character_brain.gd")
const TOL := 1e-3
const NAMES := ["t", "gaze.x", "gaze.y", "gaze.z", "tilt", "torso", "hip", "lean", "breathPhase", "breathSignal", "breathAmp",
	"breathRate", "gazeBlend", "focus", "touchL.w", "touchL.x", "touchL.y", "touchL.z", "touchR.w", "touchR.x", "touchR.y",
	"touchR.z", "mood", "state", "visible", "objective"]
const DISCRETE := [13, 22, 23, 24, 25]

static func fwd(yaw: float, pitch: float) -> Vector3:
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))

static func right(yaw: float) -> Vector3:
	return Vector3(cos(yaw), 0, -sin(yaw))

static func floor_h(x: float, z: float) -> float:
	return -9.0 + 1.2 * sin(0.13 * x) + 0.8 * cos(0.11 * z)

static func flat(_x: float, _z: float) -> float:
	return 0.0

const WALL_X := 1.0
static func wall_query(p: Vector3, r: float, filter) -> Dictionary:
	var d := WALL_X - p.x
	if d < 0.0 or d > r: return {}
	var pt := Vector3(WALL_X, p.y, p.z)
	var n := Vector3(-1, 0, 0)
	if filter != null and not filter.call(pt, n): return {}
	return {"dist": d, "point": pt, "normal": n, "id": "wall"}

static func win(t: float, a: float, b: float) -> bool:
	return t >= a and t < b

var COLLIDERS := [{"x": -4.0, "y": -6.0, "z": -22.0, "r": 2.5}, {"x": 2.5, "y": -5.4, "z": -11.0, "r": 1.6}]

func _scene(name: String, st: Dictionary, t: float, dt: float) -> Dictionary:
	var k: int = st.k
	match name:
		"swim_pois":
			var head := Vector3(0.3 * sin(0.2 * t), -5 + 0.4 * sin(0.15 * t), -0.5 * t)
			var yaw := 0.35 * sin(0.25 * t); var pitch := -0.1 + 0.08 * sin(0.4 * t)
			var f := fwd(yaw, pitch); var r := right(yaw); var u := r.cross(f)
			var kora := head + Vector3(2 * cos(0.3 * t), 1, -6 + 2 * sin(0.3 * t))
			var pois := [
				{"id": "arch_0", "kind": "arch", "label": "Coral Arch", "pos": Vector3(-5, -4, -18), "priority": 0.74, "selfRadius": 2.2, "maxRange": 54.0},
				{"id": "fish_3", "kind": "fauna", "label": "Reef Fish", "pos": Vector3(3 + 4 * cos(0.5 * t), -4.5 + sin(0.7 * t), -14 - 0.3 * t + 4 * sin(0.5 * t)), "priority": 0.87, "moving": true, "selfRadius": 0.65, "maxRange": 44.0},
				{"id": "vent_0", "kind": "vent", "label": "Thermal Vent", "pos": Vector3(6, -6, -30), "priority": 0.80, "selfRadius": 2.2, "maxRange": 52.0},
				{"id": "boat", "kind": "vessel", "label": "Boat", "pos": Vector3(0, -5, 12), "priority": 0.82, "maxRange": 54.0},
				{"id": "kora_01", "kind": "kora", "label": "KORA-01", "pos": kora, "priority": 0.96, "moving": true, "maxRange": 54.0},
			]
			var sounds := []
			if k == 360: sounds.append(["ping", head + Vector3(8, 0, -4), 0.6, 1.8])
			if k == 780: sounds.append(["impact", head + Vector3(-5, 1, 2), 0.9, 1.8])
			if k == 1140: sounds.append(["kora_chirp", kora, 0.5, 1.8])
			return {"sounds": sounds, "ctx": {"mode": "swim", "headPos": head, "bodyFwd": f, "bodyRight": r, "bodyUp": u, "visionFwd": f, "visionRight": r, "visionUp": u,
				"cameraFwd": fwd(yaw + 0.05 * sin(t), pitch), "desiredLookDir": f, "speed": 0.5, "desSpeed": 0.5,
				"yawRate": 0.35 * 0.25 * cos(0.25 * t), "getFloorHeight": floor_h, "colliders": COLLIDERS, "pois": pois}}
		"walk_idle":
			var head := Vector3(0, 1.32, 0)
			var f := fwd(0, -0.05); var r := right(0); var u := r.cross(f)
			var pois := [{"id": "console", "kind": "console", "label": "Console", "pos": Vector3(1.5, 1.0, -4), "priority": 0.78, "maxRange": 18.0}] if t > 4 else []
			if t > 11: pois.append({"id": "gull", "kind": "fauna", "label": "Gull", "pos": Vector3(-0.6 + 0.3 * sin(t), 1.45, -3.2), "priority": 0.9, "moving": true, "maxRange": 32.0})
			var sounds := []
			if k == 300: sounds.append(["door", Vector3(3, 1.3, -1), 0.55, 1.8])
			if k == 960: sounds.append(["warn", Vector3(-4, 1.3, -2), 0.85, 2.2])
			if k == 1020: sounds.append(["door", Vector3(3, 1.3, -1), 0.55, 1.8])
			return {"sounds": sounds, "ctx": {"mode": "deck_walk", "headPos": head, "bodyFwd": Vector3(0, 0, -1), "bodyRight": r, "bodyUp": Vector3(0, 1, 0),
				"visionFwd": f, "visionRight": r, "visionUp": u, "cameraFwd": f, "desiredLookDir": f, "speed": 0.0, "desSpeed": 0.0, "yawRate": 0.0,
				"getFloorHeight": flat, "crouchBlend": 0.0, "pois": pois}}
		"walk_move":
			var yaw_rate := 1.5 if win(t, 20, 21) else 0.09 * cos(0.18 * t)
			st.yaw += yaw_rate * dt
			var speed := _sp(t)
			var bf := Vector3(-sin(st.yaw), 0, -cos(st.yaw))
			st.px += bf.x * speed * dt; st.pz += bf.z * speed * dt
			var head := Vector3(st.px, 1.32, st.pz)
			var lf := fwd(st.yaw, -0.08); var r := right(st.yaw); var u := r.cross(lf)
			var pois := [
				{"id": "console", "kind": "console", "label": "Console", "pos": Vector3(2, 1, -10), "priority": 0.78, "maxRange": 18.0},
				{"id": "arch_1", "kind": "arch", "label": "Arch", "pos": Vector3(-3, 2, -25), "priority": 0.74, "selfRadius": 2.2, "maxRange": 19.5},
				{"id": "gull", "kind": "fauna", "label": "Gull", "pos": Vector3(4 * sin(0.4 * t), 1.5, -15 - 0.8 * t), "priority": 0.9, "moving": true, "maxRange": 32.0},
			]
			var sounds := []
			if k == 420: sounds.append(["ping", head + Vector3(6, 0, -3), 0.6, 1.8])
			if k == 1080: sounds.append(["impact", head + Vector3(-4, 0, 3), 0.95, 1.8])
			return {"sounds": sounds, "ctx": {"mode": "deck_walk", "headPos": head, "bodyFwd": bf, "bodyRight": r, "bodyUp": Vector3(0, 1, 0),
				"visionFwd": lf, "visionRight": r, "visionUp": u, "cameraFwd": lf, "desiredLookDir": lf, "speed": speed, "desSpeed": _sp(t + 0.5), "yawRate": yaw_rate,
				"isAirborne": win(t, 12.0, 12.6), "jumpAnticip": 0.5 if win(t, 11.7, 12.0) else 0.0, "inCriticalTransition": false,
				"getFloorHeight": flat, "crouchBlend": 0.0, "pois": pois}}
		"swim_touch":
			var sprint := win(t, 10, 13)
			var speed := 3.0 if sprint else 0.35
			st.pz -= speed * dt
			var head := Vector3(0.55, -6, st.pz)
			var yaw := 0.06 * sin(0.5 * t)
			var f := fwd(yaw, 0); var r := right(yaw); var u := r.cross(f)
			var sh_l := head + (r * -0.132 + Vector3(0, -0.14, 0)); var sh_r := head + (r * 0.132 + Vector3(0, -0.14, 0))
			var c16 := win(t, 16, 16.5)
			var pois := [{"id": "fish_8", "kind": "fauna", "label": "Reef Fish", "pos": Vector3(-2, -5.5, st.pz - 7 + sin(0.4 * t)), "priority": 0.87, "moving": true, "selfRadius": 0.65, "maxRange": 44.0}]
			var sounds := []
			if k == 480: sounds.append(["ping", head + Vector3(-6, 0, -2), 0.6, 1.8])
			return {"sounds": sounds, "ctx": {"mode": "swim", "headPos": head, "bodyFwd": f, "bodyRight": r, "bodyUp": u, "visionFwd": f, "visionRight": r, "visionUp": u,
				"cameraFwd": f, "desiredLookDir": f, "swimAxisY": u, "shoulderL": sh_l, "shoulderR": sh_r,
				"restHandWorldL": head + (r * -0.34 + Vector3(0, -0.3, -0.2)), "restHandWorldR": head + (r * 0.34 + Vector3(0, -0.3, -0.2)),
				"speed": speed, "desSpeed": speed, "sprinting": sprint, "btnPhase": 0.0, "yawRate": 0.06 * 0.5 * cos(0.5 * t),
				"impactShake": 0.3 if win(t, 20, 20.3) else 0.0, "inCriticalTransition": c16,
				"objectiveFocus": {"label": "WATER ENTRY", "dir": f, "holdSec": 0.45} if c16 else null,
				"getFloorHeight": floor_h, "queryNearestSurface": wall_query, "colliders": [], "pois": pois}}
		"swim_intent":
			var head := Vector3(0, -4, 0)
			var f := fwd(0, 0); var r := right(0); var u := r.cross(f)
			var fish := Vector3(1.2, -3.8, -8) if t < 14 else Vector3(-1.5, -3.5, -9.5 + 0.5 * sin(t))
			var cam_to := fish - head
			var pois := [
				{"id": "fish_1", "kind": "fauna", "label": "Reef Fish", "pos": fish, "priority": 0.87, "moving": true, "selfRadius": 0.65, "maxRange": 44.0},
				{"id": "cave_0", "kind": "cave", "label": "Sea Cave", "pos": Vector3(-6, -5, -14), "priority": 0.74, "selfRadius": 3.0, "maxRange": 54.0},
			]
			var sounds := []
			if k % 180 == 90: sounds.append(["ping", head + Vector3(5 if fmod(k / 180.0, 2.0) < 1.0 else -5, 0, -3), 0.5, 1.8])
			if k == 600 or k == 1260: sounds.append(["impact", head + Vector3(3, -1, 4), 0.9, 1.8])
			return {"sounds": sounds, "ctx": {"mode": "swim", "headPos": head, "bodyFwd": f, "bodyRight": r, "bodyUp": u, "visionFwd": f, "visionRight": r, "visionUp": u,
				"cameraFwd": cam_to / cam_to.length() if t > 2 else f, "desiredLookDir": f, "speed": 0.0, "desSpeed": 0.0, "yawRate": 0.0,
				"getFloorHeight": floor_h, "colliders": COLLIDERS, "pois": pois}}
	return {}

static func _sci(x: float) -> String:
	if x <= 0.0: return "0"
	var e := floori(log(x) / log(10.0))
	return "%.2fe%d" % [x / pow(10.0, e), e]

static func _sp(tt: float) -> float:
	return 0.0 if tt < 3 else (1.2 if tt < 10 else (2.4 if tt < 14 else (0.0 if tt < 16 else 0.8)))

static func _row(t: float, o: Dictionary, b) -> Array:
	var tl: Dictionary = o.touchL; var tr: Dictionary = o.touchR
	var tlw: Vector3 = tl.targetWorld if tl.targetWorld != null else Vector3.ZERO
	var trw: Vector3 = tr.targetWorld if tr.targetWorld != null else Vector3.ZERO
	var g: Vector3 = o.gazeDirWorld
	return [t, g.x, g.y, g.z, o.headTiltRad, o.torsoCuriosityYaw, o.idleHipShift, o.anticipationLean, o.breathPhase, o.breathSignal,
		o.breathAmp, o.breathRate, o.gazeBlend, o.focusLabel, tl.weight, tlw.x, tlw.y, tlw.z, tr.weight, trw.x, trw.y, trw.z,
		o.mood, o.state, o.visiblePoiCount, 1 if b.objective_focus != null else 0]

func _initialize() -> void:
	var gold: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/golden/brain_v20_19.json"))
	var ok := true
	var worst_all := 0.0
	var worst_all_at := ""
	for name in ["swim_pois", "walk_idle", "walk_move", "swim_touch", "swim_intent"]:
		var b = Brain.new()
		b.exact = true
		if "--fault" in OS.get_cmdline_user_args(): b.config.maxGlanceBlend = 0.58
		var st := {"yaw": 0.0, "px": 0.0, "pz": 0.0, "k": 0}
		var dt := 1.0 / 60.0
		var tr: Array = gold[name]
		var worst := 0.0
		var worst_at := ""
		var mismatch := ""
		var n := 0
		for k in 1500:
			st.k = k
			var t := k * dt
			var sc := _scene(name, st, t, dt)
			for s in sc.sounds: b.register_sound_event(s[0], s[1], s[2], s[3])
			var o: Dictionary = b.update(dt, sc.ctx)
			if k % 3 != 2: continue
			var g: Array = tr[n]; n += 1
			var mine := _row(t, o, b)
			for j in range(1, mine.size()):
				if j in DISCRETE:
					var gv = g[j]
					var same: bool = (gv == null and mine[j] == null) or (gv != null and mine[j] != null and str(gv if not (gv is float) else int(gv)) == str(mine[j]))
					if not same and mismatch == "":
						mismatch = "%s at t=%.2f: JS %s, port %s" % [NAMES[j], t, gv, mine[j]]
				else:
					var d := absf(float(mine[j]) - float(g[j]))
					if d > worst:
						worst = d; worst_at = "%s at t=%.2f" % [NAMES[j], t]
		var pass_ := worst < TOL and mismatch == ""
		ok = ok and pass_
		if worst > worst_all: worst_all = worst; worst_all_at = name + " " + worst_at
		print("%s  golden brain %s: worst %s (%s) over 25 s, %d samples%s" % ["PASS" if pass_ else "FAIL", name, _sci(worst), worst_at, n,
			"" if mismatch == "" else ", first discrete mismatch: " + mismatch])
	print("M04 brain port vs Thalassa v20.19 character-brain.js: %s (worst %s, %s)" % ["MATCH" if ok else "MISMATCH", _sci(worst_all), worst_all_at])
	quit(0 if ok else 1)
