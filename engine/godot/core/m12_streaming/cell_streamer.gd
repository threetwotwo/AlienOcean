## M12 World streaming, core (engine-agnostic logic: no Node, no scene, no loading).
## Decides which world cells must be live, in what order, and which to drop.
## Inputs: viewer positions (player, subs) with speeds. Output: a plan of loads/unloads.
## The Godot adapter (adapters/godot/stream_loader.gd) does the actual loading.
## Version 0.6.0 (module 0.1.0). Units: metres. Cells are square in x/z; y (depth) is ignored.
class_name CellStreamer
extends RefCounted

var cell_size: float = 64.0        # metres per cell side
var live_radius: float = 96.0      # cells touching this radius are kept fully live
var far_radius: float = 256.0      # cells inside this radius get their low-detail stand-in
var lookahead_s: float = 4.0       # how far ahead (seconds of travel) to prefetch
var hysteresis: float = 16.0       # metres past a radius before a cell is dropped (no flicker)

var live := {}   # key "x,z" -> true
var far := {}

static func key(cx: int, cz: int) -> String:
	return "%d,%d" % [cx, cz]

func _cells_in(px: float, pz: float, radius: float) -> Array:
	var out := []
	var c0x := floori((px - radius) / cell_size)
	var c1x := floori((px + radius) / cell_size)
	var c0z := floori((pz - radius) / cell_size)
	var c1z := floori((pz + radius) / cell_size)
	for cx in range(c0x, c1x + 1):
		for cz in range(c0z, c1z + 1):
			var d := _dist_to_cell(px, pz, cx, cz)
			if d <= radius:
				out.append([cx, cz, d])
	return out

func _dist_to_cell(px: float, pz: float, cx: int, cz: int) -> float:
	var x0 := cx * cell_size
	var z0 := cz * cell_size
	var dx := maxf(maxf(x0 - px, 0.0), px - (x0 + cell_size))
	var dz := maxf(maxf(z0 - pz, 0.0), pz - (z0 + cell_size))
	return sqrt(dx * dx + dz * dz)

## viewers: Array of Dictionaries {x, z, vx, vz}. Returns {load_live, load_far, unload_live, unload_far},
## each an Array of keys; load lists are sorted nearest first (by distance to any viewer's predicted point).
func update(viewers: Array) -> Dictionary:
	var want_live := {}
	var want_far := {}
	for v in viewers:
		for p in [[v.x, v.z], [v.x + v.vx * lookahead_s, v.z + v.vz * lookahead_s]]:
			for c in _cells_in(p[0], p[1], live_radius):
				var k := key(c[0], c[1])
				want_live[k] = minf(want_live.get(k, INF), c[2])
			for c in _cells_in(p[0], p[1], far_radius):
				var k := key(c[0], c[1])
				if not want_live.has(k):
					want_far[k] = minf(want_far.get(k, INF), c[2])
	var plan := {"load_live": [], "load_far": [], "unload_live": [], "unload_far": []}
	for k in want_live:
		if not live.has(k):
			plan.load_live.append(k)
	for k in want_far:
		if not far.has(k) and not live.has(k):
			plan.load_far.append(k)
	# drop only past the radius + hysteresis
	for k in live.keys():
		if not want_live.has(k) and _min_dist(k, viewers) > live_radius + hysteresis:
			plan.unload_live.append(k)
	for k in far.keys():
		if not want_far.has(k) and not want_live.has(k) and _min_dist(k, viewers) > far_radius + hysteresis:
			plan.unload_far.append(k)
	plan.load_live.sort_custom(func(a, b): return want_live[a] < want_live[b])
	plan.load_far.sort_custom(func(a, b): return want_far[a] < want_far[b])
	for k in plan.load_live: live[k] = true; far.erase(k)
	for k in plan.load_far: far[k] = true
	for k in plan.unload_live: live.erase(k)
	for k in plan.unload_far: far.erase(k)
	return plan

func _min_dist(k: String, viewers: Array) -> float:
	var parts := k.split(",")
	var best := INF
	for v in viewers:
		best = minf(best, _dist_to_cell(v.x, v.z, int(parts[0]), int(parts[1])))
	return best
