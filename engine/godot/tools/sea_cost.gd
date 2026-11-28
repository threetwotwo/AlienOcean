## Sea cost 0.1.0 (sea speed thread, 28 Nov 2026): what the sea surface costs per view, and its picture, for A/B of
## sea shader changes. Runs tools/surface_shots.gd's shots (same env: AO_SEA=Bn, AO_REEF=1, ...) plus a view straight
## down from 1.7 m over the water (the perf runner's openwater_look_down), and at each one times AO_COST_FRAMES frames
## (default 24) with the sea mesh drawn and then hidden. Prints "SEACOST <shot> on <ms> off <ms> sea <ms>".
## On a real GPU the split is the sea's share; on the cloud's CPU Vulkan it is a proxy (shader work per pixel).
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --fixed-fps 30 --script res://tools/sea_cost.gd -- <pieces_dir> <fish.glb> <out_dir> [w h]
extends "res://tools/surface_shots.gd"

var _seam: Node3D
var _phase := 0
var _t0 := 0
var _on := 0.0
var _nf := 24

func _setup():
	await super._setup()
	_nf = int(OS.get_environment("AO_COST_FRAMES")) if OS.get_environment("AO_COST_FRAMES") != "" else 24
	var hs := 0.0
	var sea := root.find_child("FftSea", true, false)
	if sea and "moments" in sea and sea.moments: hs = float(sea.moments.hs)
	var e := Vector3(0.0, WATER_Y + 1.7 + hs, 0.0)
	shots.append(["o6_above_down", e, e + Vector3(0.02, -10.0, 0.3), 75.0])
	for n in root.find_children("*", "SeaSurface", true, false): _seam = n; break
	if _seam == null:
		for n in root.find_children("*", "Node3D", true, false):
			if n is SeaSurface: _seam = n; break

func _process(_d):
	if cam == null or i < 0 or i >= shots.size(): return false
	wait += 1
	if wait == 24:
		var p: String = args[2].path_join(shots[i][0] + ".png"); root.get_texture().get_image().save_png(p); print("SHOT ", p)
		_t0 = Time.get_ticks_usec()
	elif wait == 24 + _nf:
		_on = (Time.get_ticks_usec() - _t0) / 1000.0 / _nf
		if _seam: _seam.visible = false
	elif wait == 24 + _nf + 4:
		_t0 = Time.get_ticks_usec()
	elif wait == 24 + 2 * _nf + 4:
		var off := (Time.get_ticks_usec() - _t0) / 1000.0 / _nf
		print("SEACOST %s on %.1f off %.1f sea %.1f" % [shots[i][0], _on, off, _on - off])
		if _seam: _seam.visible = true
		_next()
	return false
