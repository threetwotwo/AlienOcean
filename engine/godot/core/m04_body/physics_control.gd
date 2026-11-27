## M04 Body, core 0.1.0: GDScript port of Thalassa v20.19 core/physics-control.js (PhysicsControlRig).
## Named body-part control sets (Spine, Head, LeftArm, RightArm, LeftLeg, RightLeg) with per-mode profiles,
## hit-reaction compliance and recovery. Only the profiles the free-swim / shore rig uses are carried over yet
## (underwater_active_ragdoll, deck_balanced_walk); the cockpit / helm / ride profiles come with those modules.
extends RefCounted

const SETS := ["Spine", "Head", "LeftArm", "RightArm", "LeftLeg", "RightLeg"]
const KEYS := ["angularStrength", "dampingRatio", "equilibriumWeight", "worldSpaceWeight", "inertiaScale", "softLimitMargin"]

static func _p(a: float, d: float, e: float, w: float, i: float, m: float) -> Dictionary:
	return {"angularStrength": a, "dampingRatio": d, "equilibriumWeight": e, "worldSpaceWeight": w, "inertiaScale": i, "softLimitMargin": m}

static var PROFILES := {
	"underwater_active_ragdoll": {"recoveryRate": 3.2, "sets": {
		"Spine": _p(21.0, 1.05, 5.2, 0.45, 1.00, 0.10), "Head": _p(32.0, 1.00, 2.5, 0.70, 0.55, 0.08),
		"LeftArm": _p(42.0, 1.08, 9.0, 0.25, 1.05, 0.10), "RightArm": _p(42.0, 1.08, 9.0, 0.25, 1.05, 0.10),
		"LeftLeg": _p(38.0, 1.06, 8.5, 0.20, 1.15, 0.09), "RightLeg": _p(38.0, 1.06, 8.5, 0.20, 1.15, 0.09)}},
	"deck_balanced_walk": {"recoveryRate": 4.5, "sets": {
		"Spine": _p(34.0, 1.00, 3.0, 0.78, 0.90, 0.07), "Head": _p(44.0, 1.02, 2.0, 0.85, 0.40, 0.06),
		"LeftArm": _p(36.0, 0.96, 4.0, 0.15, 1.05, 0.08), "RightArm": _p(36.0, 0.96, 4.0, 0.15, 1.05, 0.08),
		"LeftLeg": _p(68.0, 1.10, 1.5, 0.92, 0.35, 0.075), "RightLeg": _p(68.0, 1.10, 1.5, 0.92, 0.35, 0.075)}},
}

var profile_name := "underwater_active_ragdoll"
var user_compliance_scale := 1.0
var user_strength_scale := 1.0
var sets := {}
var hit_softness := {}
var total_ragdoll_energy := 0.0

func _init(initial := "underwater_active_ragdoll") -> void:
	profile_name = initial if PROFILES.has(initial) else "underwater_active_ragdoll"
	for s in SETS:
		sets[s] = PROFILES[profile_name].sets[s].duplicate()
		hit_softness[s] = 0.0

func set_profile(n: String) -> bool:
	if not PROFILES.has(n) or profile_name == n: return false
	profile_name = n
	return true

func trigger_hit_reaction(set_name := "All", magnitude := 0.75) -> void:
	var mag := clampf(magnitude, 0.1, 1.0)
	total_ragdoll_energy = clampf(total_ragdoll_energy + mag, 0.0, 1.5)
	if set_name == "All" or not hit_softness.has(set_name):
		for k in SETS:
			var w := 0.90 if k == "Spine" else (0.55 if k == "Head" else 1.0)
			hit_softness[k] = clampf(maxf(hit_softness[k], mag * w), 0.0, 1.0)
	else:
		hit_softness[set_name] = clampf(maxf(hit_softness[set_name], mag), 0.0, 1.0)
		hit_softness.Spine = clampf(maxf(hit_softness.Spine, mag * 0.52), 0.0, 1.0)

func update(dt: float) -> void:
	var sdt := clampf(dt, 0.0001, 0.05)
	var prof: Dictionary = PROFILES[profile_name]
	var bk := 1.0 - exp(-7.5 * sdt)
	var rec := exp(-prof.recoveryRate * sdt)
	total_ragdoll_energy *= exp(-2.6 * sdt)
	for k in SETS:
		var tg: Dictionary = prof.sets[k]
		var cur: Dictionary = sets[k]
		for f in KEYS:
			cur[f] = lerpf(cur[f], tg[f], bk)
		hit_softness[k] *= rec
		if hit_softness[k] < 0.002: hit_softness[k] = 0.0

func get_control(set_name: String) -> Dictionary:
	var cur: Dictionary = sets.get(set_name, sets.Spine)
	var hit: float = hit_softness.get(set_name, 0.0)
	var comp := clampf(user_compliance_scale, 0.25, 2.0)
	var ss := clampf(user_strength_scale, 0.4, 1.8)
	var es: float = cur.angularStrength * ss * (1.0 - hit * 0.62) / pow(comp, 0.55)
	return {
		"angularStrength": es,
		"damping": 2.0 * cur.dampingRatio * sqrt(maxf(4.0, es)) * lerpf(1.0, 0.78, hit),
		"dampingRatio": cur.dampingRatio,
		"equilibriumWeight": cur.equilibriumWeight * (1.0 + hit * 0.45) * comp,
		"worldSpaceWeight": cur.worldSpaceWeight,
		"inertiaScale": cur.inertiaScale * comp * (1.0 + hit * 0.85),
		"softLimitMargin": clampf(cur.softLimitMargin * lerpf(0.8, 1.35, comp * 0.5), 0.0, 0.16),
		"hitSoftness": hit,
	}
