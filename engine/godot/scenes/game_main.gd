## The game's main scene (game root thread, 27 Nov 2026): one GameRoot, configured from the command line / environment
## so the same scene runs on the Mac and in the cloud. Assets live outside git (project files), so their folders are
## passed in; without them the game runs on a stand-in sand floor.
## Env: AO_PIECES (lagoon pieces dir), AO_WORLDTEX, AO_DRESS (world_dress/<name>.json) + AO_DRESS_PIECES, AO_HOUR,
##      AO_DAY_MIN (minutes per game day; unset = the time of day holds), AO_SCHOOLS (count of trevally schools, default 2).
extends Node

func _ready() -> void:
	var g := GameRoot.new()
	var e := func(k: String, d := ""): return OS.get_environment(k) if OS.get_environment(k) != "" else d
	g.pieces_dir = e.call("AO_PIECES"); g.worldtex_dir = e.call("AO_WORLDTEX")
	g.dress_manifest = e.call("AO_DRESS"); g.dress_pieces = e.call("AO_DRESS_PIECES")
	g.start_hour = float(e.call("AO_HOUR", "12"))
	if e.call("AO_DAY_MIN") != "": g.hours_per_second = 24.0 / (float(e.call("AO_DAY_MIN")) * 60.0)
	var homes := [Vector3(4, 2.0, 8), Vector3(-6, 1.6, -4), Vector3(12, 2.4, -12)]
	for i in mini(int(e.call("AO_SCHOOLS", "2")), homes.size()):
		g.schools.append({"species": "trevally", "home": homes[i], "seed": i + 1})
	add_child(g)
	if g.dress_manifest != "":
		await get_tree().physics_frame; await get_tree().physics_frame
		print("DRESS ", g.seat_dress())
