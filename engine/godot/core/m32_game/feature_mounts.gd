## M32 game root: feature mounts 0.1.0 (core; game root thread, 27 Nov 2026). Port of Thalassa v20.19
## core/feature-mounts.js (FeatureMountManager): live toggling of optional mounted subsystems without breaking core
## locomotion or camera. Thalassa's keys were pelagos / companion / fauna / radio; ours are the game root's plugs.
## Unknown keys are refused (set_mount returns false), as in the JS.
class_name FeatureMounts
extends RefCounted

const DEFAULT_MOUNTS := {"world": true, "sea": true, "lagoon": true, "streaming": true, "girl": true, "camera": true,
	"fauna": true}

var mounts := {}

func _init(initial: Dictionary = {}) -> void:
	mounts = DEFAULT_MOUNTS.duplicate()
	for k in initial: mounts[k] = bool(initial[k])

func is_mounted(key: String) -> bool:
	return bool(mounts.get(key, false))

func set_mount(key: String, enabled: bool) -> bool:
	if not mounts.has(key): return false
	mounts[key] = enabled
	return mounts[key]

func toggle_mount(key: String) -> bool:
	return set_mount(key, not is_mounted(key))

func get_state() -> Dictionary:
	return {"mounts": mounts.duplicate()}
