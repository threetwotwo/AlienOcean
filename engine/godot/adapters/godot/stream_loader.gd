## M12 World streaming, Godot adapter 0.1.0: turns a CellStreamer plan into threaded loads.
## Cells live at res://test_world/cells/<x>_<z>.tscn (full) and <x>_<z>_far.tscn (stand-in).
## A missing cell file is treated as open water (nothing to load), never an error.
extends Node3D

@export var cells_dir := "res://test_world/cells"
@export var max_instances_per_frame := 2   # spreads instancing cost across frames
var streamer := CellStreamer.new()
var pending := {}    # path -> kind
var nodes := {}      # key|kind -> Node3D
var queue := []      # [key, kind, path] ready to instance
var last := {}       # diagnostics of the last step: ms per phase, counts

func step(viewers: Array) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var plan := streamer.update(viewers)
	var t1 := Time.get_ticks_usec()
	for k in plan.load_live: _request(k, "live")
	for k in plan.load_far: _request(k, "far")
	var t2 := Time.get_ticks_usec()
	for k in plan.unload_live: _free(k, "live")
	for k in plan.unload_far: _free(k, "far")
	var t3 := Time.get_ticks_usec()
	var made := _poll()
	var t4 := Time.get_ticks_usec()
	last = {"plan_ms": (t1 - t0) / 1000.0, "request_ms": (t2 - t1) / 1000.0, "free_ms": (t3 - t2) / 1000.0, "poll_ms": (t4 - t3) / 1000.0,
		"requested": plan.load_live.size() + plan.load_far.size(), "freed": plan.unload_live.size() + plan.unload_far.size(), "instanced": made}
	return plan

func _path(k: String, kind: String) -> String:
	var p := k.replace(",", "_")
	return "%s/%s%s.tscn" % [cells_dir, p, "" if kind == "live" else "_far"]

func _request(k: String, kind: String) -> void:
	var path := _path(k, kind)
	if not ResourceLoader.exists(path):
		return
	if ResourceLoader.load_threaded_request(path) == OK:
		pending[path] = [k, kind]

func _poll() -> int:
	for path in pending.keys():
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			queue.append([pending[path][0], pending[path][1], path])
			pending.erase(path)
		elif st == ResourceLoader.THREAD_LOAD_FAILED or st == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_warning("cell load failed: " + path)
			pending.erase(path)
	var n := 0
	while queue.size() > 0 and n < max_instances_per_frame:
		var item = queue.pop_front()
		var id: String = item[0] + "|" + item[1]
		var still_wanted: bool = (item[1] == "live" and streamer.live.has(item[0])) or (item[1] == "far" and streamer.far.has(item[0]))
		if still_wanted and not nodes.has(id):
			var node: Node3D = (ResourceLoader.load_threaded_get(item[2]) as PackedScene).instantiate()
			add_child(node)
			nodes[id] = node
			if item[1] == "live":
				_free(item[0], "far")   # the full cell replaces its stand-in
		n += 1
	return n

func _free(k: String, kind: String) -> void:
	var id := k + "|" + kind
	if nodes.has(id):
		nodes[id].queue_free()
		nodes.erase(id)
