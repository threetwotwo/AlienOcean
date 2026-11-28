## Grey mode 0.1.0 (blockout kit): swap any level to flat blockout grey (with the metre grid) and back, keeping every
## collision shape exactly as it was. Only drawing changes: each GeometryInstance3D under the given roots gets the
## blockout grey as material_override (its own override is kept in meta and restored); particles are hidden.
## Collision, physics, scripts, lights and the water are untouched, so a motion test in grey mode is the same test.
## Pass the LEVEL roots (ground, dress, streamed cells), not the whole scene: the sea surface and the girl stay as they are.
## Anything in the group "grey_keep" (and everything under it) is skipped.
## Caveat: a mesh whose own shader moves its vertices (wind-swayed grass, a displaced terrain) shows its undisplaced
## shape in grey; apply() counts those in "moved_vertices" so the caller can say so.
class_name GreyMode
extends RefCounted

const META := "_grey_mode_orig"
const META_VIS := "_grey_mode_vis"
const KEEP_GROUP := "grey_keep"

## Planted fault for tests/test_blockout.gd: grey mode also switches collision off (the test must catch it).
static var fault_drop_collision := false

static func apply(roots: Array, on: bool, hide_fx: bool = true) -> Dictionary:
	var rep := {"greyed": 0, "restored": 0, "hidden": 0, "moved_vertices": 0}
	var grey: Material = preload("res://blockout/blockout_kit.gd").grey_material()
	for root in roots:
		if root != null: _walk(root, on, hide_fx, grey, rep)
	return rep

static func _walk(n: Node, on: bool, hide_fx: bool, grey: Material, rep: Dictionary) -> void:
	if n.is_in_group(KEEP_GROUP): return
	if n is GPUParticles3D or n is CPUParticles3D:
		if on and hide_fx and not n.has_meta(META_VIS):
			n.set_meta(META_VIS, n.visible); n.visible = false; rep.hidden += 1
		elif not on and n.has_meta(META_VIS):
			n.visible = n.get_meta(META_VIS); n.remove_meta(META_VIS)
	elif n is GeometryInstance3D:
		var g := n as GeometryInstance3D
		if on and not g.has_meta(META):
			g.set_meta(META, g.material_override if g.material_override != null else false)
			if _moves_vertices(g): rep.moved_vertices += 1
			g.material_override = grey
			rep.greyed += 1
		elif not on and g.has_meta(META):
			var o = g.get_meta(META)
			g.material_override = o if o is Material else null
			g.remove_meta(META)
			rep.restored += 1
	if fault_drop_collision and n is CollisionShape3D:
		(n as CollisionShape3D).disabled = on
	for c in n.get_children():
		_walk(c, on, hide_fx, grey, rep)

static func _moves_vertices(g: GeometryInstance3D) -> bool:
	var mats: Array = [g.material_override]
	if g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
		var mi := g as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			mats.append(mi.get_active_material(i))
	for m in mats:
		if m is ShaderMaterial and m.shader != null and m.shader.code.contains("VERTEX +="):
			return true
	return false

## True when any root is currently grey.
static func is_on(roots: Array) -> bool:
	for root in roots:
		if root != null and _any(root): return true
	return false

static func _any(n: Node) -> bool:
	if n.has_meta(META): return true
	for c in n.get_children():
		if _any(c): return true
	return false
