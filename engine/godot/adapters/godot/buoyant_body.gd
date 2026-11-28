## M29 Water physics, Godot adapter 0.1.0: a RigidBody3D (Jolt) that takes its water forces from the buoyancy core.
## Forces are applied in _integrate_forces from the body state, so they stay in step with the solver at any frame rate.
extends RigidBody3D

const Buoy := preload("res://core/m29_water_physics/buoyancy.gd")

var buoy = Buoy.new()
var water          # any object with water_y(x, z, t) and current(p, t)
var sim_time := 0.0
var last := {}

func _init() -> void:
	SeaFloorMap.mark_mover(self)   # moves: never frozen into the sea floor map (the water drew stale copies, Gary 28 Nov)
	custom_integrator = false
	can_sleep = false
	# water drag and damping come from the buoyancy core; the engine's default world damping (0.1/s against the
	# world frame, not the water) would fight currents and double-count drag
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.0

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if water == null:
		return
	sim_time += state.step
	var xf := state.transform
	last = buoy.forces(xf.basis, xf.origin, state.center_of_mass_local, state.linear_velocity, state.angular_velocity, water, sim_time)
	state.apply_central_force(last.force)
	state.apply_torque(last.torque)
