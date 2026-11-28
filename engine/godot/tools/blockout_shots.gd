## Blockout shots 0.1.0 (blockout kit): pictures of the blockout gym and of grey mode on a real level piece, for the
## picture page. Plain daylight, no water drawn, so the shapes read. Marker frames (saddle, hands, feet, seats, lie)
## are drawn as small red/green/blue axes (x/y/z; -Z blue tip = facing).
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/blockout_shots.gd -- <out_dir> [w h]
extends SceneTree

const Gym := preload("res://blockout/blockout_gym.gd")
const Grey := preload("res://blockout/grey_mode.gd")

var out := "/tmp/blk_shots"
var cam: Camera3D
var gym: Dictionary

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(int(a[1]) if a.size() > 1 else 1280, int(a[2]) if a.size() > 2 else 720)
	_run.call_deferred()

func _env() -> void:
	var we := WorldEnvironment.new(); var e := Environment.new()
	var sky := Sky.new(); var ps := ProceduralSkyMaterial.new(); sky.sky_material = ps
	e.background_mode = Environment.BG_SKY; e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY; e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC; e.ssao_enabled = true
	we.environment = e; root.add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-52, -35, 0); sun.light_intensity_lux = 100000.0
	sun.shadow_enabled = true; sun.directional_shadow_max_distance = 120.0
	root.add_child(sun)
	cam = Camera3D.new(); cam.fov = 55; cam.far = 2000; root.add_child(cam); cam.current = true
	# the project uses physical light units: a sunny-16 exposure (f/16, 1/125 s, ISO 100) for 100 klx sun
	var ca := CameraAttributesPhysical.new(); ca.exposure_aperture = 16.0; ca.exposure_shutter_speed = 125.0
	ca.exposure_sensitivity = 100.0; ca.auto_exposure_enabled = false
	cam.attributes = ca

func _axes(parent: Node3D, xf: Transform3D, size := 0.25) -> void:
	for i in 3:
		var mi := MeshInstance3D.new(); var bm := BoxMesh.new()
		var s := Vector3(0.02, 0.02, 0.02); s[i] = size; bm.size = s; mi.mesh = bm
		var m := StandardMaterial3D.new(); m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = [Color(1, 0.1, 0.1), Color(0.1, 0.9, 0.1), Color(0.15, 0.3, 1)][i]
		m.no_depth_test = true; mi.material_override = m
		var off := Vector3.ZERO; off[i] = size * 0.5 * (-1.0 if i == 2 else 1.0)   # z drawn toward -Z (facing)
		mi.transform = Transform3D(Basis.IDENTITY, off)
		var holder := Node3D.new(); holder.transform = xf; holder.add_child(mi)
		parent.add_child(holder)

func _shot(name: String, from: Vector3, at: Vector3, fov := 55.0) -> void:
	cam.fov = fov
	cam.look_at_from_position(from, at, Vector3.UP)
	for i in 6: await process_frame
	var img := root.get_texture().get_image()
	img.save_png("%s/%s.png" % [out, name])
	print("SHOT ", name)

func _st(label: String) -> Dictionary:
	return gym.stations.filter(func(x): return x.label == label)[0]

func _run() -> void:
	_env()
	var w := Node3D.new(); root.add_child(w)
	gym = Gym.build(w, 0.0)
	await physics_frame
	for st in gym.stations:
		for mn in st.result.marker_nodes:
			if mn != "start" and mn != "approach": _axes(w, st.result.markers[mn])
	# the rider: pause it mid-turn and draw its markers on it
	var ride := _st("ride")
	var rd = ride.result.rider
	rd.t = 8.6; rd.paused = true
	for i in 3: await physics_frame
	for mn in rd.MARKERS:
		var h := Node3D.new(); rd.add_child(h); _axes(h, Transform3D(Basis.IDENTITY, rd.MARKERS[mn][0]), 0.2)
	var o := func(label: String) -> Vector3: return _st(label).start.origin
	var dry_end: Vector3 = o.call("senses")
	await _shot("01_gym_overview", Vector3(dry_end.x * 0.5, 70, 75), Vector3(dry_end.x * 0.5, 0, -30), 60)
	await _shot("02_steps_stairs", o.call("step 20 cm") + Vector3(-6, 7, 14), o.call("step 50 cm") + Vector3(4, 0, -6), 55)
	await _shot("03_ramps_slope", o.call("ramp 30") + Vector3(-8, 9, 18), o.call("ramp 60") + Vector3(0, 2, -6), 55)
	await _shot("04_ledge_gaps_beams", o.call("gap 0.8") + Vector3(-10, 9, 14), o.call("beam 10 cm") + Vector3(-6, -1, -5), 60)
	await _shot("05_rough", o.call("rough 5-15 cm") + Vector3(5, 4, 5), o.call("rough 5-15 cm") + Vector3(0, 0, -6), 50)
	await _shot("06_walls_ceiling_mantle", o.call("wall corner") + Vector3(-9, 6, 10), o.call("wall corner") + Vector3(0.4, 0.5, -12), 60)
	await _shot("07_stool", o.call("stool 45") + Vector3(1.6, 1.4, 0.6), o.call("stool 45") + Vector3(0, 0.3, -1.5), 45)
	await _shot("08_bench", o.call("bench") + Vector3(1.8, 1.5, 0.8), o.call("bench") + Vector3(0, 0.45, -2), 45)
	await _shot("09_bunk", o.call("bunk") + Vector3(-1.4, 1.3, 1.6), o.call("bunk") + Vector3(0, 0.6, -2), 50)
	var rp: Vector3 = rd.global_position
	await _shot("10_rider", rp + rd.global_transform.basis * Vector3(2.4, 1.6, 2.2), rp, 45)
	await _shot("11_senses", o.call("senses") + Vector3(-3, 6, 9), o.call("senses") + Vector3(0, 0, -3), 60)
	await _shot("12_water_row", o.call("tube 1.0") + Vector3(-30, 30, 40), o.call("tube 1.0") + Vector3(0, -10, -10), 60)
	# grey mode on a real level piece: the reef stress world's terrain (water surface thread), before / after
	root.remove_child(w); w.free()
	WorldRoot.declare_globals()
	var lvl := Node3D.new(); root.add_child(lvl)
	var b := Bathymetry.new(); b.radius = 60.0; b.lagoon_d = 2.4; b.ocean_depth = 300.0
	var reef := ReefTerrain.new(); lvl.add_child(reef); reef.keep_under = Rect2(0, 0, 0, 0); reef.r_in = 20.0; reef.r_out = 260.0
	reef.build(b, 2.4)
	await physics_frame
	var from := Vector3(40, 14, 52); var at := Vector3(58, -6, 8)
	# (its painted look needs the game's world light and water globals, so only the grey side is shot here)
	var rep := Grey.apply([lvl], true)
	print("GREY ", rep)
	await _shot("14_reef_grey", from, at, 60)
	quit(0)
