extends Node3D
var f := 0
var t0 := 0
func _ready():
	t0 = Time.get_ticks_msec()
	# a few "rocks" built in code, as a stand-in for imported GLB pieces
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	for i in 24:
		var m := MeshInstance3D.new()
		var s := SphereMesh.new(); s.radius = rng.randf_range(0.4, 1.6); s.height = s.radius * rng.randf_range(1.0, 1.8)
		m.mesh = s
		var mat := StandardMaterial3D.new(); mat.albedo_color = Color.from_hsv(rng.randf_range(0.02, 0.12), 0.45, 0.75); mat.roughness = 0.9
		m.material_override = mat
		m.position = Vector3(rng.randf_range(-12, 12), s.radius * 0.4, rng.randf_range(-20, 2))
		add_child(m)
func _process(_d):
	f += 1
	if f == 90:
		var img := get_viewport().get_texture().get_image()
		img.save_png("user://probe.png")
		print("FRAMES=", f, " MS=", Time.get_ticks_msec() - t0, " RENDERER=", RenderingServer.get_video_adapter_name(), " API=", RenderingServer.get_video_adapter_api_version())
		get_tree().quit()
