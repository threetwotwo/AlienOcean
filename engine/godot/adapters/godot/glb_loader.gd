## GLB loader 0.1.0 (test level thread): loads a GLB at runtime (GLTFDocument, works for folders outside the project too) and
## gives every drawn mesh Godot's automatic LODs (meshoptimizer, as the editor import does) so far rocks,
## coral and grass draw a fraction of their triangles. Collision meshes (_COL_ hulls, _TRI concave) are left alone.
## Not through the editor importer on purpose: its name suffixes turn our _COL_ hulls into drawn trimesh bodies.
class_name GlbLoader
extends RefCounted

static var lods := OS.get_environment("AO_GLB_LODS") != "0"    # AO_GLB_LODS=0: the old full-detail path (A/B tests)
static var stats := {"meshes": 0, "lod_meshes": 0, "ms": 0.0}

static func load_scene(path: String) -> Node3D:
	if not FileAccess.file_exists(path): return null
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK: return null
	if lods:
		var t0 := Time.get_ticks_usec()
		for gm in st.get_meshes():
			var im: ImporterMesh = gm.mesh
			stats.meshes += 1
			if im == null or "_COL_" in String(im.get_name()) or String(im.get_name()).ends_with("_TRI"): continue
			if _faces(im) < 600: continue      # tiny meshes: nothing to gain
			im.generate_lods(25.0, 60.0, [])
			stats.lod_meshes += 1
		stats.ms += (Time.get_ticks_usec() - t0) / 1000.0
	return doc.generate_scene(st) as Node3D

static func _faces(im: ImporterMesh) -> int:
	var n := 0
	for s in im.get_surface_count():
		var a: Array = im.get_surface_arrays(s)
		var idx = a[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx != null else a[Mesh.ARRAY_VERTEX].size()) / 3
	return n
