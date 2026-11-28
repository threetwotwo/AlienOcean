## The test level scene's root (scenes/test_level.tscn): a TestLevel plus its debug panel.
extends Node

func _ready() -> void:
	var lvl := TestLevel.new(); add_child(lvl)
	while not lvl.ready_done: await get_tree().process_frame
	if DisplayServer.get_name() == "headless": return
	if OS.get_environment("AO_BENCH") == "1":           # run_benchmark.command: measure, save, quit
		await get_tree().create_timer(3.0).timeout
		await lvl.run_bench()
		get_tree().quit()
		return
	var panel = preload("res://adapters/godot/test_level/debug_panel.gd").new()
	panel.level = lvl; add_child(panel)
