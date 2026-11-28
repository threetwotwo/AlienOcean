## GameRoot 0.1.0 (adapters/godot; game root thread, 27 Nov 2026): the game's one root node. It builds the world and
## its services, plugs in the girl, the fish schools, the lagoon, the sea and the streamed world, and runs ONE explicit
## tick order, so nothing depends on the order Godot happens to call _physics_process in.
## Ported from Thalassa v20.19 style/runtime.js updateSimulation() (the composition root): sample input, step the
## actors, sync live fauna before anything reads them, then camera, then the world; optional systems mounted through
## Thalassa's FeatureMountManager (core/m32_game/feature_mounts.gd). Not ported: the browser frame plumbing
## (requestAnimationFrame, the 50 ms dt clamp): Godot's fixed physics tick replaces it, so every render rate runs the same
## simulation.
## Deviation D1 from Thalassa: fauna read the player AFTER she moves this tick (Thalassa synced fauna with the
## pre-move position). Either way fauna are synced before anything reads them; ours is one tick fresher.
##
## Tick order (TICK_ORDER, checked every tick by tests/test_game_root.gd):
##   clock     SimClock.step(): t and the world hour advance (nothing else owns time)
##   input     one InputPacket (InputReader, or a scripted source for tests and films)
##   player    ActorRig.tick: motor (M02) -> body rig (M04)
##   actors    every owner writes its actor, then ActorRegistry.commit (readers never see half a tick)
##   fauna     each school gets registry.perceived() around its home, then advances (M31)
##   plugs     every registered plug's plug_tick(dt, services), in registration order
##   camera    no-cut camera (M03) after the player moved; the girl is drawn with its head/alpha choice
##   world     WorldRoot.apply (sky, light, exposure, tide, water uniforms) and M12 streaming around the viewers
##
## Plugs: register_plug(node, mount) adds any node with plug_tick(dt, services); optional plug_ready(services) (called on
## registration) and plug_write_actors(services) (called in "actors", before the commit). mount = a FeatureMounts key
## (unknown keys are refused) or "" for always on. While the clock is paused only "clock" and "world" run.
class_name GameRoot
extends Node3D

signal ticked(tick: int)                       # end of each game tick (all phases done); tests and films hook here

const TICK_ORDER := ["clock", "input", "player", "actors", "fauna", "plugs", "camera", "world"]
const Rig := preload("res://adapters/godot/camera_rig.gd")
const InputReaderScript := preload("res://adapters/godot/input_reader.gd")
const StreamLoader := preload("res://adapters/godot/stream_loader.gd")
const WorldQuery := preload("res://adapters/godot/world_query.gd")
const Packet := preload("res://core/m01_input/input_packet.gd")

@export var start_hour := 12.0
@export var hours_per_second := 0.0            # 0 = the time of day holds
@export var tide_on := true
@export var pieces_dir := ""                   # lagoon world pieces (GLB, world coordinates); "" = a flat stand-in floor
@export var worldtex_dir := ""                 # the shared ground material's textures (AO_WORLDTEX)
@export var dress_manifest := ""               # an authored place (world_dress/<name>.json) and its pieces
@export var dress_pieces := ""
@export var reef_on := true                    # with the pieces: the reef drop-off round the lagoon (adapters/godot/reef_terrain.gd)
@export var spawn_feet := Vector3(0, 1.6, 18)  # the girl's feet at start (the lagoon: sand at y 0, surface at 4 m)
@export var spawn_swim := true
@export var blockout := false                  # build the blockout gym (blockout/blockout_gym.gd) instead of the lagoon; F6 = next station
@export var blockout_station := ""             # start at this station (label or kind), "" = the first
@export var schools: Array = []                # [{species, home: Vector3, count, seed, tethered}]
@export var school_sense_radius := 24.0        # how far a school looks for actors around its home (m)
@export var use_camera := true
@export var use_sea := true                    # the drawn FFT sea needs a RenderingDevice (off headless)
@export var with_mannequin := true
@export var cells_dir := "res://test_world/cells"
@export var apply_every_hours := 1.0 / 120.0   # re-light when the clock moved this far (30 game seconds), or the eye crossed the surface

var services := GameServices.new()
var clock: SimClock
var mounts := FeatureMounts.new()
var actors := ActorRegistry.new()
var world_root: WorldRoot
var streamer: Node3D
var girl: ActorRig
var cam: Camera3D = null
var reader = null
var input_source := Callable()                 # (t) -> InputPacket; set by tests/films, else the InputReader
var school_nodes: Array = []
var lagoon: Node3D
var sea: Node3D = null
var trace: Array = []                          # phases run this tick, in order (the stress test checks TICK_ORDER)
var last_inp = null
var ready_done := false
var _applied_hours := -INF
var _applied_under := false
var _plugs: Array = []                         # [[node, mount]] in registration order
var stats := {"tick_ms": 0.0, "max_tick_ms": 0.0, "phase_ms": {}}

func _init() -> void:
	name = "GameRoot"

func _ready() -> void:
	WorldRoot.declare_globals()     # before any water shader compiles
	clock = SimClock.new(start_hour, 1.0 / Engine.physics_ticks_per_second)
	clock.hours_per_second = hours_per_second
	# the world: light, sky, exposure, water (engine thread)
	world_root = WorldRoot.new(); world_root.tide_on = tide_on; world_root.hours = start_hour
	add_child(world_root)
	lagoon = Node3D.new(); lagoon.name = "Lagoon"; add_child(lagoon)
	_build_lagoon()
	if use_sea and RenderingServer.get_rendering_device() != null:
		sea = world_root.make_surface(); add_child(sea)
	streamer = StreamLoader.new(); streamer.name = "Streamer"; streamer.cells_dir = cells_dir; add_child(streamer)
	world_root.streamer = streamer
	# the girl (gameplay + body threads' modules, assembled)
	girl = ActorRig.new(); girl.with_mannequin = with_mannequin; add_child(girl)
	girl.spawn(spawn_feet, spawn_swim)
	actors.add("girl", "player", 0.25, {"label": "Mira", "half_len": 0.44, "axis": Vector3.UP, "priority": 1.0})
	if use_camera:
		cam = Rig.new(); cam.name = "GameCamera"; add_child(cam)
		cam.body = girl.body; cam.exclude.append(girl.body.get_rid()); cam.current = true
		world_root.attach_camera(cam)
	if not input_source.is_valid():
		reader = InputReaderScript.new(); add_child(reader)
	grey_toggle = preload("res://blockout/grey_mode_toggle.gd").new(); grey_toggle.roots = [lagoon, streamer]; add_child(grey_toggle)
	if blockout:
		var play = preload("res://blockout/blockout_play.gd").new(); play.girl = girl; play.stations = blockout_gym.stations
		add_child(play)
	# services
	services.clock = clock; services.water = world_root.water; services.actors = actors; services.mounts = mounts
	services.world_root = world_root; services.streamer = streamer
	services.world = WorldQuery.new(get_world_3d(), 1)
	for s in schools: add_school(s)
	# her senses: registry actors, the schools, the authored place's landmarks, the camera (adapters/godot/brain_senses.gd)
	var bs := ActorRig.BrainSenses.new()
	bs.actors = actors; bs.schools = school_nodes; bs.camera = cam; bs.dress = _dress
	girl.senses = bs
	world_root.apply(spawn_feet.y + 1.0)
	_applied_hours = clock.hours
	ready_done = true

## A fish school (fish school thread's FishSchool, M31) plugged into the registry. Returns the node, or null when the
## module isn't in this build (its branch not merged yet): the game runs without it.
func add_school(cfg: Dictionary) -> Node:
	var scr := _global_script("FishSchool")
	if scr == null:
		push_warning("GameRoot: FishSchool not in this build, school skipped")
		return null
	var s: Node = scr.new()
	s.species_id = String(cfg.get("species", "trevally"))
	s.count = int(cfg.get("count", 0))
	s.seed_ = int(cfg.get("seed", school_nodes.size() + 1))
	s.home = cfg.get("home", Vector3(0, 2, 0))
	s.tethered = bool(cfg.get("tethered", true))
	s.water_y = world_root.water.water_y
	s.current = world_root.water.current
	s.process_mode = Node.PROCESS_MODE_DISABLED      # the game root steps it, in tick order
	add_child(s)
	school_nodes.append(s)
	return s

static func _global_script(cls: String) -> Script:
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == cls: return load(c["path"])
	return null

func _physics_process(_delta: float) -> void:
	if not ready_done: return
	var t0 := Time.get_ticks_usec()
	trace.clear()
	# clock
	var dt := clock.step()
	# the tide moves with the clock here, before anyone reads the water this tick (the light follows in "world")
	# (gameplay water: it follows the clock whatever is mounted; the "world" mount only switches the lighting)
	if dt > 0.0 and world_root.tide_on: world_root.water.set_clock(clock.hours)
	_mark("clock", t0)
	if dt <= 0.0:                                   # paused: nothing simulates; the world keeps drawing and streaming
		_world_phase(Time.get_ticks_usec())
		ticked.emit(clock.tick)
		return
	var t := clock.t
	# input
	var tp := Time.get_ticks_usec()
	var inp
	if input_source.is_valid(): inp = input_source.call(t)
	elif reader != null: inp = reader.read(dt)
	else: inp = Packet.new()
	if cam != null and mounts.is_mounted("camera"):
		cam.integrate_look(dt, inp.look)            # this tick's look reaches the motor this tick (as Thalassa)
	if cam != null:
		inp.cam_yaw = cam.yaw; inp.cam_pitch = cam.pitch
	last_inp = inp
	_mark("input", tp)
	# player
	tp = Time.get_ticks_usec()
	if mounts.is_mounted("girl"): girl.tick(dt, inp, world_root.water, t)
	_mark("player", tp)
	# actors: every owner writes, then one commit
	tp = Time.get_ticks_usec()
	actors.begin()
	actors.move("girl", girl.centre(), girl.velocity() if mounts.is_mounted("girl") else Vector3.ZERO, girl.capsule.axis, girl.capsule.half_len)
	for pm in _plugs:
		if (pm[1] == "" or mounts.is_mounted(pm[1])) and pm[0].has_method("plug_write_actors"): pm[0].plug_write_actors(services)
	actors.commit(clock.tick)
	_mark("actors", tp)
	# fauna
	tp = Time.get_ticks_usec()
	if mounts.is_mounted("fauna"):
		for s in school_nodes:
			s.actors = actors.perceived(s.home, school_sense_radius)
			s.advance(dt, false)                  # step only; drawn once per rendered frame in _process
	_mark("fauna", tp)
	# plugs
	tp = Time.get_ticks_usec()
	for pm in _plugs:
		if pm[1] == "" or mounts.is_mounted(pm[1]): pm[0].plug_tick(dt, services)
	_mark("plugs", tp)
	# camera, then the girl drawn with the camera's head / alpha choice
	tp = Time.get_ticks_usec()
	var wy: float = services.water_y(girl.body.global_position.x, girl.body.global_position.z)
	if cam != null and mounts.is_mounted("camera"):
		cam.request(_shot_for(girl.mode_name()))
		var f: Dictionary = cam.tick(dt, girl.eye_point(), inp.look, wy)
		world_root.set_fov(cam.fov)                 # CameraAttributesPhysical owns the field of view
		girl.head_visible = cam.shot != "first_person"
		girl.draw(f.body_alpha)
	else:
		girl.draw(1.0)
	_mark("camera", tp)
	_world_phase(Time.get_ticks_usec())
	stats.tick_ms = (Time.get_ticks_usec() - t0) / 1000.0
	stats.max_tick_ms = maxf(stats.max_tick_ms, stats.tick_ms)
	ticked.emit(clock.tick)

func _world_phase(tp: int) -> void:
	## sky, light, exposure and water uniforms (WorldRoot), then M12 streaming around the committed viewers
	if mounts.is_mounted("world"):
		var eye: Vector3 = cam.global_position if cam != null else girl.eye_point()
		# the eye is under water when it is under the wave drawn over it, not under the still level (Gary 28 Nov, force 12:
		# standing in a trough the eye was metres under the still level but in air, and got the under-water exposure, sky and
		# haze: the sky blew out to white and a hard line cut the arch). The world's light and the under-water view take the
		# eye's height above that wave as if the sea were still there.
		var dh: float = (sea as SeaSurface).fft.height_at(eye.x, eye.z) if sea is SeaSurface and sea.visible else 0.0
		world_root.set_eye_wave(dh)
		var eye_y: float = eye.y - dh
		var under := eye_y < world_root.water.level
		if absf(clock.hours - _applied_hours) >= apply_every_hours or under != _applied_under:
			world_root.hours = clock.hours
			world_root.apply(eye_y)
			_applied_hours = clock.hours; _applied_under = under
	RenderingServer.global_shader_parameter_set("water_y", world_root.water.level)   # the drawn sea = the gameplay level, every tick
	if mounts.is_mounted("streaming"):
		streamer.step(_viewers())
	if sea != null: sea.visible = mounts.is_mounted("sea")
	lagoon.visible = mounts.is_mounted("lagoon")
	_mark("world", tp)

func _process(delta: float) -> void:
	## the schools' MultiMesh write once per drawn frame, interpolated to render time (school thread PR #49), after the
	## physics ticks of this frame, so the fish are drawn where the camera already is
	if not ready_done or not mounts.is_mounted("fauna"): return
	var since := Engine.get_physics_interpolation_fraction() / Engine.physics_ticks_per_second
	for s in school_nodes: s.draw_now(since, delta)

func _mark(phase: String, since: int) -> void:
	trace.append(phase)
	stats.phase_ms[phase] = (Time.get_ticks_usec() - since) / 1000.0

## Add a plug to the tick (after GameRoot is ready). Returns false when refused (unknown mount, no plug_tick).
func register_plug(node: Node, mount := "") -> bool:
	if not node.has_method("plug_tick"):
		push_error("GameRoot: plug %s has no plug_tick" % node.name); return false
	if mount != "" and not mounts.mounts.has(mount):
		push_error("GameRoot: plug %s names unknown mount '%s'" % [node.name, mount]); return false
	_plugs.append([node, mount])
	if node.has_method("plug_ready"): node.plug_ready(services)
	return true

func unregister_plug(node: Node) -> void:
	_plugs = _plugs.filter(func(pm): return pm[0] != node)

func _shot_for(mode: String) -> String:
	if cam.shot == "first_person" or cam.shot == "observe": return cam.shot   # a chosen first-person view holds
	return "swim" if (mode == "SWIM" or mode == "TREAD") else "explore"

func _viewers() -> Array:
	## M12 viewers: the player (later vessels): {x, z, vx, vz} from the registry, so streaming follows what is committed
	var out := []
	for a in actors.order:
		if a.kind == "player" or a.kind == "vessel":
			out.append({"x": a.pos.x, "z": a.pos.z, "vx": a.vel.x, "vz": a.vel.z})
	return out

# ---- the lagoon: world pieces, the authored place, collision ----

var blockout_gym := {}                         # BlockoutGym.build() result in blockout mode
var grey_toggle: Node = null                   # F7 grey mode (blockout/grey_mode_toggle.gd) over the lagoon and streamed cells

func _build_lagoon() -> void:
	if blockout:
		blockout_gym = preload("res://blockout/blockout_gym.gd").build(lagoon, LagoonWaterField.SURFACE_Y)
		var sts: Array = blockout_gym.stations
		var pick: Dictionary = sts[0]
		for st in sts:
			if blockout_station != "" and (st.label == blockout_station or st.kind == blockout_station): pick = st; break
		spawn_feet = pick.start.origin + Vector3(0, 0.05, 0)
		spawn_swim = pick.water
		return
	if pieces_dir == "" or not DirAccess.dir_exists_absolute(pieces_dir):
		_flat_floor()
	else:
		_load_pieces()
		if reef_on and world_root.lagoon_radius > 0.0:   # the drawn seabed past the tiles: the reef and its drop-off to the deep
			var reef := ReefTerrain.new(); reef.name = "Reef"; lagoon.add_child(reef)
			reef.build(world_root.bathymetry(), LagoonWaterField.SURFACE_Y)   # the mean level (the seabed does not follow the tide)
	if dress_manifest != "":
		var dress := DressCell.new(); dress.setup(dress_manifest, dress_pieces)
		dress.ground_material = _ground
		lagoon.add_child(dress); dress.build()
		_dress = dress

var _ground: Material = null
var _dress: DressCell = null

## Seat the authored place on the floor (needs one physics frame for the floor collision to exist).
func seat_dress() -> Dictionary:
	if _dress == null: return {}
	var space := get_world_3d().direct_space_state
	return {"seat": _dress.seat(space), "keep_clear": _dress.keep_clear_report(space)}

func _flat_floor() -> void:
	## stand-in floor when no pieces are given (headless tests): open sand at y 0 under the 4 m lagoon
	var sb := StaticBody3D.new(); sb.name = "StandInFloor"
	var cs := CollisionShape3D.new(); var bx := BoxShape3D.new(); bx.size = Vector3(400, 1, 400); cs.shape = bx
	cs.position = Vector3(0, -0.5, 0); sb.add_child(cs)
	var mi := MeshInstance3D.new(); var pm := PlaneMesh.new(); pm.size = Vector2(400, 400); mi.mesh = pm
	var m := ShaderMaterial.new(); m.shader = load("res://look/seabed_surface.gdshader"); m.set_shader_parameter("sand_lock", 1.0)
	mi.material_override = m; sb.add_child(mi)
	lagoon.add_child(sb)

func _load_pieces() -> void:
	## the lagoon pieces as tools/lagoon_shots.gd builds them (engine thread): floor tiles in the shared ground material,
	## the rest in the water-lit seabed material; solid pieces get trimesh collision (grass stays swim-through)
	var seabed := ShaderMaterial.new(); seabed.shader = load("res://look/seabed_surface.gdshader")
	if worldtex_dir != "": _ground = WorldTextures.make_material(worldtex_dir)
	for f in DirAccess.get_files_at(pieces_dir):
		if not f.ends_with(".glb"): continue
		var sc := GlbLoader.load_scene(pieces_dir.path_join(f))   # imported GLBs bring their LODs and shadow meshes
		if sc == null: continue
		lagoon.add_child(sc)
		var lf := f.to_lower()
		var mat: Material = seabed
		if "floor" in lf:
			if _ground: mat = _ground
			else:
				mat = seabed.duplicate(); mat.set_shader_parameter("sand_lock", 1.0)
		for mi in sc.find_children("*", "MeshInstance3D", true, false):
			for s in mi.mesh.get_surface_count(): mi.set_surface_override_material(s, mat)
			if not "seagrass" in lf: mi.create_trimesh_collision()
