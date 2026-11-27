## M30 world clock: the GDScript port must match the Unreal-era Python sky maths (tests/data/sky_ref.json,
## made by tests/data/sky_ref_sun_v184.py, an unmodified extract of sun_v184.py): light to 1e-5 relative, angles to
## 1e-4 deg (directions are Vector3, single precision in Godot, so ~5e-6 deg of noise is expected and harmless).
## Run: godot --headless --path . --script res://tests/test_world_clock.gd
extends SceneTree

func _close(a: float, b: float, k := "") -> bool:
	if k.ends_with("elev") or k == "dir":
		return absf(a - b) <= 1e-4
	return absf(a - b) <= 1e-5 * maxf(1.0, absf(b))

func _init():
	var rows = JSON.parse_string(FileAccess.get_file_as_string("res://tests/data/sky_ref.json"))
	var bad := 0
	for r in rows:
		var orb := SkyClock.ORBITS.duplicate(true)
		if r.orb == "study": orb["B"] = SkyClock.STUDY_ORBIT_B
		var st := SkyClock.sky_state(r.h, 15.0, 24.0, SkyClock.MONTHS, {}, orb)
		var key := SkyClock.pick_key(st)
		var got := {"sun_elev": st.sun.elev, "total": st.total, "skylux": st.skylux, "A_elev": st.A.elev,
			"A_horiz": st.A.horiz, "B_elev": st.B.elev, "B_horiz": st.B.horiz, "cover": st.eclipse.cover,
			"fade": SkyClock.key_fade(st, key)}
		for k in got:
			if not _close(got[k], r[k], k):
				bad += 1; print("MISMATCH h=", r.h, " ", r.orb, " ", k, " got ", got[k], " want ", r[k])
		if key != r.key:
			bad += 1; print("MISMATCH h=", r.h, " key ", key, " want ", r.key)
		for i in 3:
			if not _close(st.sun.dir[i], r.sun_dir[i], "dir"): bad += 1; print("MISMATCH sun_dir ", r.h)
	# the adapter's axes: Unreal (x, y, z) cm is Godot (x, z, y) m. Anchor: LG_table_5's box corner in the lagoon slice 4
	# manifest (Unreal cm, checked in Unreal by P4) against the same corner of its GLB (Godot m).
	var corner := WorldRoot.to_godot(Vector3(241.46, -1037.43, 4.08) * 0.01)
	if not corner.is_equal_approx(Vector3(2.4146, 0.0408, -10.3743)): bad += 1; print("MISMATCH to_godot ", corner)
	print("world clock: %d rows, %d mismatches -> %s" % [rows.size(), bad, "PASS" if bad == 0 else "FAIL"])
	quit(0 if bad == 0 else 1)
