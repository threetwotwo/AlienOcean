## GameServices 0.1.0 (adapters/godot; game root thread, 27 Nov 2026): the shared services the game root hands to every
## plug, in one object instead of globals (architecture review 27 Nov: "WorldRoot owns services only and injects them
## ... No autoloads"). Contracts: core/README.md "Shared service contracts".
##   clock   SimClock (core/world/sim_clock.gd): .t, .tick, .hours, .dt   the only game time
##   water   WaterQuery (core/world/lagoon_water.gd LagoonWaterField): level, water_y(x, z, t), current(p, t)
##   world   WorldQuery (adapters/godot/world_query.gd): floor_height, nearest_surface, point_solid, ray
##   actors  ActorRegistry (core/m32_game/actor_registry.gd): near(), perceived(), pois(), player()
##   mounts  FeatureMounts (core/m32_game/feature_mounts.gd): which optional systems run
##   world_root  WorldRoot (light, sky, exposure, water uniforms), streamer  the M12 stream loader node
class_name GameServices
extends RefCounted

var clock: SimClock
var water                       # LagoonWaterField (WaterQuery contract)
var world                       # WorldQuery
var actors: ActorRegistry
var mounts: FeatureMounts
var world_root: WorldRoot
var streamer: Node3D            # adapters/godot/stream_loader.gd

## True where there is water at p (the single test for "is this wet", replacing the -1000 / -999 sentinels for new code).
func has_water(p: Vector3) -> bool:
	return water != null and water.level > -999.0 and p.y < water.water_y(p.x, p.z, clock.t)

func water_y(x: float, z: float) -> float:
	return water.water_y(x, z, clock.t) if water != null and water.level > -999.0 else -INF
