## Image quality check (look thread, 28 Nov 2026). Gary's fullscreen playtest on the Mac showed banded, stair-stepped shadows,
## a dither stipple in the penumbrae, pixelated grass edges and far shimmer. The roots: Godot's low soft-shadow filter on a 4096
## shadow map (PCSS with few taps: banded, noisy penumbrae), and half resolution upscaled by FSR 1, which is spatial (no
## anti-aliasing). This holds the fix: the soft-shadow filter at high or better on an 8192 map, and anti-aliasing behind the Retina
## half-resolution path (a temporal upscaler, or FSR 1 with Godot TAA: the Mac's best look per ms), with per-frame noise (god rays) moving only where frames are averaged.
## Planted fault --fault: the old settings (filter low, FSR 1 without TAA); it must be caught.
## Run: godot --headless --path . --script res://tests/test_image_quality.gd [-- --fault]
extends SceneTree

func _initialize() -> void:
	var fault := "--fault" in OS.get_cmdline_user_args()
	if fault:
		ProjectSettings.set_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 2)
		OS.set_environment("AO_UPSCALER", "fsr")
	var ok := true
	var q_dir: int = ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 2)
	var q_pos: int = ProjectSettings.get_setting("rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality", 2)
	var size: int = ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size", 4096)
	var iq1 := q_dir >= 4 and q_pos >= 4
	print("IQ1 soft shadow filter high or better (sun %d, local %d): %s" % [q_dir, q_pos, "PASS" if iq1 else "FAIL"]); ok = ok and iq1
	var iq2 := size >= 8192
	print("IQ2 sun shadow map %d >= 8192: %s" % [size, "PASS" if iq2 else "FAIL"]); ok = ok and iq2
	var m := TestLevel.upscaler()
	var temporal_up := m == Viewport.SCALING_3D_MODE_FSR2 or m == Viewport.SCALING_3D_MODE_METALFX_TEMPORAL
	var taa := TestLevel.needs_taa(m) and not fault
	var iq3 := temporal_up or taa
	print("IQ3 half resolution is anti-aliased (mode %d, TAA with it %s): %s" % [m, taa, "PASS" if iq3 else "FAIL"]); ok = ok and iq3
	var vp := SubViewport.new(); root.add_child(vp)
	vp.scaling_3d_mode = m; vp.scaling_3d_scale = 0.5; vp.use_taa = taa
	var t_half := WorldRoot.temporal(vp)
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.use_taa = false
	var t_fsr1 := WorldRoot.temporal(vp)
	var iq4 := t_half and not t_fsr1
	print("IQ4 god rays move per frame only under a temporal filter (%s, FSR 1 %s): %s" % [t_half, t_fsr1, "PASS" if iq4 else "FAIL"]); ok = ok and iq4
	print("image quality: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
