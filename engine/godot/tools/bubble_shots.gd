## Bubble shots 0.1.0 (bubbles thread, 28 Nov 2026): pictures of the bubbles (adapters/godot/bubbles.gd, look/bubble.gdshader)
## in the blockout gym, through a fixed camera (not the game rig), for the picture page and the look checks.
## Run: VK_ICD_FILENAMES=/opt/lavapipe/lvp_icd.json xvfb-run -a godot --path . --rendering-driver vulkan \
##        --script res://tools/bubble_shots.gd -- <out_dir> [w h] [set]
## set: exhale (default: the girl 3 m down in the 20 m pool, side / close / from below), ceiling (pooled under the -5 m slab),
##      lab (a fixed burst of 1-10 mm bubbles 0.3-1.2 m in front of the lens: the optics close up), film (60 frames, side view)
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")

var out := "/tmp/bub_shots"
var set_name := "exhale"
var g: GameRoot
var cam: Camera3D
var shots: Array = []          # [time, name, callable(head) -> [from, at, fov]]
var si := 0
var frame := 0

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(int(a[1]) if a.size() > 1 else 1352, int(a[2]) if a.size() > 2 else 848)
	if a.size() > 3: set_name = a[3]
	Engine.physics_ticks_per_second = 60
	Engine.max_physics_steps_per_frame = 8
	g = GameRoot.new()
	g.blockout = true; g.use_sea = true
	g.blockout_station = "ceiling slab -5 m" if set_name == "ceiling" else "pool 20 m"
	g.input_source = _input
	root.add_child.call_deferred(g)
	g.ready.connect(_on_ready)
	var side := func(h: Transform3D): return [h.origin + h.basis.x * 1.3 + Vector3(0, -0.15, 0), h.origin + Vector3(0, 0.25, 0), 50.0]
	var close := func(h: Transform3D): return [h.origin + h.basis.x * 0.45 - h.basis.z * 0.25 + Vector3(0, -0.05, 0), h.origin - h.basis.z * 0.1 + Vector3(0, 0.12, 0), 50.0]
	var below := func(h: Transform3D): return [h.origin + h.basis.x * 0.5 - h.basis.z * 0.6 + Vector3(0, -0.5, 0), h.origin + Vector3(0, 2.5, 0), 60.0]
	match set_name:
		"exhale":
			for k in 6: shots.append([7.0 + k * 0.6, "side_%d" % k, side])
			for k in 4: shots.append([10.8 + k * 0.5, "close_%d" % k, close])
			for k in 4: shots.append([13.0 + k * 0.8, "below_%d" % k, below])
		"ceiling":
			for k in 4: shots.append([8.0 + k * 2.5, "ceiling_%d" % k, func(h: Transform3D): return [h.origin + h.basis.x * 1.4 + Vector3(0, -0.6, 0), h.origin + Vector3(0, 1.2, 0), 60.0]])
		"lab":
			for k in 4: shots.append([8.3 + k * 0.12, "lab_%d" % k, func(h: Transform3D): return [_lab_eye(), _lab_eye() + Vector3(0, -0.05, -1), 30.0]])
		"choice":     # the exhale style choice: same camera, same moments (run once per AO_EXHALE)
			for k in 5: shots.append([7.3 + k * 0.3, "choice_%d" % k, side])
		"film":
			for k in 90: shots.append([7.0 + k / 30.0, "film_%03d" % k, side])

func _lab_eye() -> Vector3:
	return g.girl.eye_point() + Vector3(2.0, -0.5, 2.0)

func _on_ready() -> void:
	cam = Camera3D.new(); cam.far = 400.0; cam.near = 0.03
	g.add_child(cam)
	g.world_root.attach_camera(cam)     # its exposure (shared CameraAttributesPhysical) and its own underwater view quad
	cam.current = true
	g.cam.current = false

func _input(t: float):
	var k = Packet.new()
	if g == null or g.girl == null: return k
	var y: float = g.girl.body.motor.swimmer.pos.y
	var want := LagoonWaterField.SURFACE_Y - (1.2 if set_name == "ceiling" else 3.0)
	k.descend = y > want + 0.3
	k.descend_amount = 0.6 if k.descend else 0.0
	k.ascend = y < want - 0.5
	return k

var _lab_done := false
func _process(_d: float) -> bool:
	if g == null or not g.ready_done or cam == null: return false
	var t: float = g.clock.t
	if set_name == "lab" and not _lab_done and t > 8.0:
		_lab_done = true
		var e := _lab_eye()
		var sizes := [0.6, 1.2, 2.0, 3.0, 5.0, 9.0]
		for i in sizes.size():
			var p := e + Vector3(-0.15 + 0.055 * i, -0.06 + 0.012 * (i % 2), -0.32 - 0.02 * i)
			g.bubbles.emit(p, Vector3.ZERO, sizes[i], t, NAN, -1, "lab")
		g.bubbles.emit_burst(e + Vector3(0, -0.3, -1.4), 0.4, 40, Vector3(0, 0.1, 0), 0.05, 0.5, 4.0, t - 0.3, t, "lab")
	if si < shots.size():
		var h: Transform3D = g.girl.pose.headMat if not g.girl.pose.is_empty() else Transform3D()
		var s: Array = shots[si]
		var v: Array = (s[2] as Callable).call(h)
		g.world_root.set_fov(v[2])      # the physical camera attributes own the field of view
		cam.look_at_from_position(v[0], v[1], Vector3.UP)
		g.world_root.apply(cam.global_position.y)
		if t >= float(s[0]):
			RenderingServer.frame_post_draw.connect(_save.bind(s[1], t), CONNECT_ONE_SHOT)
			si += 1
	else:
		print("BUBBLE SHOTS done ", g.bubbles.births)
		quit(0)
	return false

func _save(nm: String, t: float) -> void:
	root.get_texture().get_image().save_png(out.path_join(nm + ".png"))
	print("SHOT ", nm, " t=", snappedf(t, 0.01), " live births ", g.bubbles.live)
