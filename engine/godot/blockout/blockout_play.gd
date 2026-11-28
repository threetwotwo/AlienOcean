## Blockout play 0.1.0 (blockout kit): playing the gym by hand in the game. F6 = next station, Shift+F6 = previous;
## the girl is put on the station's start (swimming at water stations). Prints the station name.
extends Node

var girl            # ActorRig
var stations: Array = []
var i := 0

func _ready() -> void:
	name = "BlockoutPlay"

func go(k: int) -> void:
	if stations.is_empty() or girl == null: return
	i = posmod(k, stations.size())
	var st: Dictionary = stations[i]
	var p: Vector3 = st.start.origin + Vector3(0, 0.05, 0)
	girl.body.started = false              # re-seat the motor on its next tick (player_body.gd tick: set_pose)
	girl.body.motor.swimmer.vel = Vector3.ZERO
	girl.body.velocity = Vector3.ZERO
	girl.spawn(p, st.water)
	print("BLOCKOUT station %d/%d: %s" % [i + 1, stations.size(), st.label])

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_F6:
		go(i + (-1 if e.shift_pressed else 1))
