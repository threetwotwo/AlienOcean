## Grey mode toggle 0.1.0 (blockout kit): F7 flips the level between its look and blockout grey (blockout/grey_mode.gd).
## Add it to any level and fill 'roots' with the level's geometry roots (GameRoot does this for the lagoon and the
## streamed cells). Starts grey when the environment says AO_GREY=1.
extends Node

const Grey := preload("res://blockout/grey_mode.gd")

var roots: Array = []
var key := KEY_F7
var on := false

func _ready() -> void:
	name = "GreyModeToggle"
	if OS.get_environment("AO_GREY") == "1":
		set_grey.call_deferred(true)

func set_grey(v: bool) -> void:
	on = v
	var rep := Grey.apply(roots, on)
	print("GREY MODE %s %s" % ["on" if on else "off", rep])
	var cb := Callable(self, "_on_node_added")
	if on and not get_tree().node_added.is_connected(cb): get_tree().node_added.connect(cb)
	elif not on and get_tree().node_added.is_connected(cb): get_tree().node_added.disconnect(cb)

## Streamed cells and anything else that arrives under a root while grey mode is on come in grey too.
func _on_node_added(n: Node) -> void:
	for r in roots:
		if r != null and r.is_ancestor_of(n) and n.get_parent() != null and not n.get_parent().has_meta(Grey.META):
			Grey.apply.call_deferred([n], true)
			return

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == key:
		set_grey(not on)
