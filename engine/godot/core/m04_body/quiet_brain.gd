## M04 Body, core 0.1.0: stand-in for Thalassa core/character-brain.js until that port lands (next step).
## Returns the brain's outputs with nothing noticed: gaze = the look direction, no glances, no hand touch, no
## breath shift. The golden recorder (tests/golden/body_trace.mjs) swaps the same stand-in into the JS rig so the
## rig port can be checked on its own.
extends RefCounted

func update(_dt: float, ctx: Dictionary) -> Dictionary:
	return {"gazeDirWorld": ctx.get("desiredLookDir", Vector3.FORWARD), "headTiltRad": 0.0, "objectiveFocusActive": false,
		"touchL": null, "touchR": null, "idleHipShift": 0.0, "torsoCuriosityYaw": 0.0, "anticipationLean": 0.0,
		"breathCentered": 0.0, "breathAmp": 1.0}

func register_sound_event(_kind: String, _pos: Vector3, _intensity := 0.65, _max_age := 1.8) -> void:
	pass
