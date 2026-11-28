## The test level scene's root (scenes/test_level.tscn): a TestLevel plus its debug panel.
extends Node

func _ready() -> void:
	var lvl := TestLevel.new(); add_child(lvl)
	while not lvl.ready_done: await get_tree().process_frame
	if DisplayServer.get_name() == "headless": return
	var panel = preload("res://adapters/godot/test_level/debug_panel.gd").new()
	panel.level = lvl; add_child(panel)
