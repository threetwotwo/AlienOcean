## M29 Water physics, buoyancy core 0.1.0 (engine-agnostic logic). Archimedes + drag on hull sample points.
## A body is described by sample points (local position + the volume each one stands for). Each point is treated as a
## sphere of that volume; its submerged share uses the exact sphere-cap volume, so forces change smoothly at the surface.
## Inputs per tick: body transform (basis + origin), linear/angular velocity, a water query (water_y(x,z,t), current(p,t)).
## Output: total force and torque about the centre of mass (world space). The adapter applies them (Jolt RigidBody3D).
## Not modelled yet: added mass, slamming. Stand-in: heave_damp for wave-radiation damping (see below). Owner: gameplay thread.
extends RefCounted

const G := 9.81
var rho := 1025.0          # sea water kg/m^3
var points: Array = []     # [{p: Vector3 local, v: volume m^3, r: equivalent sphere radius, a: frontal area share m^2}]
var drag_cd := 0.8         # per point, on its frontal disc
var lin_damp := 40.0       # N per (m/s) per m^3 submerged: viscous skin term, all directions
var heave_damp := 1400.0   # N per (m/s) per m^3 submerged, vertical only: stand-in for wave-radiation damping
                           # (a floating body bobbing makes waves that carry energy away; gives heave damping ratio
                           # ~0.15 for a 1 m cube). Root: a radiation model (strip theory). Owner: gameplay; remove when that lands.
var total_volume := 0.0

## Fill a box (size, local centre) with nx*ny*nz sample points.
func add_box(size: Vector3, center: Vector3 = Vector3.ZERO, n: Vector3i = Vector3i(4, 4, 4)) -> void:
	var vol := size.x * size.y * size.z / float(n.x * n.y * n.z)
	var r := pow(3.0 * vol / (4.0 * PI), 1.0 / 3.0)
	# frontal area share: the box's mean frontal area spread over its points (summing each point's own disc would
	# count the same cross-section once per layer and overstate drag by the number of layers)
	var a := pow(size.x * size.y * size.z, 2.0 / 3.0) / float(n.x * n.y * n.z)
	for i in n.x:
		for j in n.y:
			for k in n.z:
				var lp := center + Vector3((i + 0.5) / n.x - 0.5, (j + 0.5) / n.y - 0.5, (k + 0.5) / n.z - 0.5) * size
				points.append({"p": lp, "v": vol, "r": r, "a": a})
	total_volume += size.x * size.y * size.z

## Submerged share of a sphere of radius r whose centre is h below the surface (h < 0 = above).
static func sphere_share(h: float, r: float) -> float:
	var d := clampf(h + r, 0.0, 2.0 * r)            # height of the submerged cap
	return d * d * (3.0 * r - d) / (4.0 * r * r * r)

## Returns {force, torque, submerged} (submerged = displaced volume m^3).
func forces(basis: Basis, origin: Vector3, com_local: Vector3, lin_vel: Vector3, ang_vel: Vector3, water, t: float) -> Dictionary:
	var F := Vector3.ZERO
	var T := Vector3.ZERO
	var sub := 0.0
	var com := origin + basis * com_local
	for pt in points:
		var wp: Vector3 = origin + basis * pt.p
		var share: float = sphere_share(water.water_y(wp.x, wp.z, t) - wp.y, pt.r)
		if share <= 0.0:
			continue
		var vsub: float = pt.v * share
		sub += vsub
		var arm: Vector3 = wp - com
		var v_pt: Vector3 = lin_vel + ang_vel.cross(arm)
		var v_rel: Vector3 = v_pt - water.current(wp, t)
		var f: Vector3 = Vector3(0.0, rho * G * vsub, 0.0)
		var area: float = pt.a * share
		f += -0.5 * rho * drag_cd * area * v_rel.length() * v_rel
		f += -lin_damp * vsub * v_rel
		f.y += -heave_damp * vsub * v_rel.y
		F += f
		T += arm.cross(f)
	return {"force": F, "torque": T, "submerged": sub}
