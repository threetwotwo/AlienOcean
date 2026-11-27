## M31 school: species behaviour records -> the sim's parameter dictionary.
## Records: core/m31_school/school_species.json, keyed by the creature maker's species id. A record names a base preset
## (the Nov 1 paper's open / lagoon / mill) and overrides any key. Keys ending in _m are metres, _deg degrees; both are
## converted here (metres -> BL with the fish's body length, which comes from the glb, or bl_m_standin until it lands).
extends RefCounted

const PATH := "res://core/m31_school/school_species.json"

## Defaults for keys the paper's presets don't set (the lab's and this port's own; each documented in CHANGELOG).
const DEFAULTS := {
	"k": 7, "n_far": 4, "g_far": 1.0, "breathe": 0.0, "breathe_T": 6.0, "alert_T": 15.0, "alert_far": 1.0, "alert_ali": 0.0,
	"R_home": 0.0, "home": Vector3.ZERO, "init_spread": 0.5, "vmin": 0.15, "vspread": 0.04,
	"grid_cell": 2.0,        # BL: neighbour grid cell (D2)
	"search_R": 8.0,         # BL: neighbours farther than this are seen through the far glimpses only (D2)
	"d0_scared_k": 0.6,      # scared personal space / calm (behaviour v3: 0.48 / 0.8 BL)
	"calm_T": 8.0,           # s: a startled fish's personal space eases back to calm over this
	"surface_clear": 3.0,    # BL under the water surface
	"env_period": 4,         # world queries per fish every Nth step, staggered (floor, rock ahead)
	"look_ahead": 2.0, "look_R": 1.5,   # BL: where and how far a fish looks for rock ahead of it
	"rock_clear": 0.4, "rock_fade": 0.8, "rock_push": 5.0,   # BL, BL, gain: push off rock, fading over rock_fade
	"rock_steer": 6.0,       # gain: a fish heading into rock turns along the face (fades over look_R)
	"hit_margin": 0.15,      # BL: a fish the swept guard stops sits this far off the face
	"fid": 10.0,             # BL: flight initiation distance to the girl (records give fid_m)
	"calm_push": 2.0,        # make-way gain inside fid (the paper's predator used 6)
	"rush_speed": 6.0,       # BL/s closing speed that counts as a rush (startle)
	"rush_ttc": 0.8,         # s: a rush startles when she would reach the fish within this (time to contact)
	"touch_R": 0.5,          # BL beyond her radius: a touch startles
	"keep_out": 0.4,         # BL beyond her radius: no fish ends a step inside
	"flee_v": 4.0,           # BL/s: the escape-swim speed a fish reaches at full urgency (fast-start sustained swim)
	"flee_tau": 0.25,        # s: how fast it gets there
	"pred_R": 10.0,          # BL: predator detection radius (school.py experiments)
	"burst_v": 8.0, "burst_turn_deg": 900.0, "startle_k": 1.0,
	"pitch_max_deg": 50.0,   # schoollab v46
	"curious": 0.0, "calm_diver_v_m": 1.85, "curious_r0_m": 2.6, "curious_r1_m": 12.5, "curious_ring_m": 5.0,   # Thalassa calm-diver circling
	"no_overlap": true, "overlap": 0.36,   # BL; above the 0.3 BL clump line of PASS S5 so a pressed crowd sits outside it
	"school_size": 120, "bl_m_standin": 0.2,
}

static var _cache: Dictionary = {}

static func records() -> Dictionary:
	if _cache.is_empty():
		_cache = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	return _cache

static func species_ids() -> Array:
	return records().species.keys()

## Parameters for a species, or for a bare preset name ("open", "lagoon", "mill"). body_m <= 0 = use the stand-in.
static func params(id: String, body_m: float = -1.0, over: Dictionary = {}) -> Dictionary:
	var R := records()
	var rec: Dictionary = R.species.get(id, {"base": id})
	var out := DEFAULTS.duplicate()
	out.merge(R.presets[rec.get("base", "open")], true)
	out.merge(rec, true)
	out.merge(over, true)
	var bl: float = body_m if body_m > 0.0 else float(out.bl_m_standin)
	out["bl_m"] = bl
	for key in out.keys():
		var ks: String = key
		if ks.ends_with("_m") and ks != "bl_m" and ks != "bl_m_standin":
			out[ks.trim_suffix("_m")] = float(out[ks]) / bl
		elif ks.ends_with("_deg") and ks != "pitch_max_deg" and ks != "burst_turn_deg":
			out[ks.trim_suffix("_deg")] = deg_to_rad(float(out[ks]))
	if out.home is Array: out.home = Vector3(out.home[0], out.home[1], out.home[2])
	for key in ["k", "n_far", "env_period", "school_size"]: out[key] = int(out[key])
	return out
