## Port check: M01 stick shaping, L2 dive and the look filter must reproduce Gary's Thalassa v20.19 input.js.
## Golden file: tests/golden/input_trace.mjs. Run: godot --headless --path . --script res://tests/test_golden_input.gd
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")
const LookFilter := preload("res://core/m01_input/look_filter.gd")

func _initialize() -> void:
	var tr: Array = JSON.parse_string(FileAccess.get_file_as_string("res://tests/golden/input_v20_19.json"))
	var lf = LookFilter.new()
	var worst := 0.0
	for row in tr:
		var mv := Packet.shape_stick(Vector2(row[0], -row[1]))          # W3C stick up is -1
		var up := -Packet.shape_trigger(row[4])
		var look: Vector2 = lf.step(Vector2(row[2], -row[3]), 1.0 / 60.0)
		var yaw_delta := -look.x / 60.0                                   # Thalassa yawDelta = -(turn right)
		var pitch_delta := look.y / 60.0
		for d in [mv.y - row[5], mv.x - row[6], up - row[7], yaw_delta - row[8], pitch_delta - row[9]]:
			worst = maxf(worst, absf(d))
	var ok := worst < 1e-6
	print("%s  M01 port vs Thalassa v20.19 input.js: worst difference %.9f over 240 ticks (move, L2 dive, look)" % ["PASS" if ok else "FAIL", worst])
	quit(0 if ok else 1)
