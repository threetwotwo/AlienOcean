## God rays check 0.1.0 (engine thread): renders the god-ray sum (underwater view god_k 2, AgX identity) from a fixed
## camera in empty water, and dumps it and the light net map as raw float32 RGBA for tools/god_rays_check.py.
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/god_rays_check.gd -- <out_dir>   (AO_HOUR, default 12)
extends SceneTree
var wr: WorldRoot; var cam: Camera3D; var n := 0; var out := ""
func _init():
	out = OS.get_cmdline_user_args()[0]
	root.size = Vector2i(960, 540); root.use_hdr_2d = true
	process_frame.connect(_setup, CONNECT_ONE_SHOT)
func _setup():
	WorldRoot.declare_globals()
	wr = WorldRoot.new(); wr.hours = float(OS.get_environment("AO_HOUR")) if OS.get_environment("AO_HOUR") != "" else 12.0
	root.add_child(wr); wr.caustics.frozen_time = 5.0; wr.agx_fx.mode = 1
	cam = Camera3D.new(); root.add_child(cam); cam.current = true; wr.attach_camera(cam); wr.set_fov(70.0)
	cam.look_at_from_position(Vector3(0.2, 0.5, -8.6), Vector3(1.2, 4.9, -11.6), Vector3.UP)
	wr.apply(0.5); wr.under_mat.set_shader_parameter("god_k", 2.0)
	print("CAM ", cam.global_transform, " proj ", cam.get_camera_projection())
func _process(_d):
	n += 1
	if n == 12:
		var im := root.get_texture().get_image(); print("FMT ", im.get_format()); im.convert(Image.FORMAT_RGBAF)
		var f := FileAccess.open(out + "/acc.raw", FileAccess.WRITE); f.store_buffer(im.get_data()); f.close()
		var cm: Image = wr.caustics.map_vp.get_texture().get_image(); cm.convert(Image.FORMAT_RGBAF)
		f = FileAccess.open(out + "/map.raw", FileAccess.WRITE); f.store_buffer(cm.get_data()); f.close()
		quit(0)
	return false
