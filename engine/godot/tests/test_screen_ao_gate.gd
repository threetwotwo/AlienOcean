## Screen AO gate 0.1.0 (ao thread, 28 Nov 2026). CORTAO is the default AO (Gary, 28 Nov), so Godot's SSAO is off and only
## materials that apply AO = min(AO, screen_ao(SCREEN_UV)) (look/screen_ao.gdshaderinc) get ambient occlusion. A lit shader
## without it silently gets none. Checks:
##   G1 every lit spatial shader (.gdshader, not unshaded) in the game folders calls screen_ao(
##   G2 no game script builds a StandardMaterial3D / ORMMaterial3D unless it is unshaded (those can't read the screen AO)
## Game folders: adapters, blockout, fish, look, world_dress, scenes, core (tools/ and tests/ set up their own environments).
## Planted fault: --fault noinc adds a lit shader without screen_ao to the scan, which must fail G1.
## Run: godot --headless --path . --script res://tests/test_screen_ao_gate.gd [-- --fault noinc]     exit 0 = all green
extends SceneTree

const DIRS := ["res://adapters", "res://blockout", "res://fish", "res://look", "res://world_dress", "res://scenes", "res://core"]
const OWN_ENV := ["res://scenes/probe_shot.gd"]   # standalone probe scene with its own default environment, not the game's
const PLANTED := "shader_type spatial;\nrender_mode cull_back;\nvoid fragment() { ALBEDO = vec3(0.5); }\n"

func _walk(dir: String, ext: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null: return
	for f in d.get_files():
		if f.get_extension() == ext: out.append(dir.path_join(f))
	for sub in d.get_directories():
		_walk(dir.path_join(sub), ext, out)

static func lit_without_ao(src: String) -> bool:
	if not src.contains("shader_type spatial"): return false
	var rm := RegEx.new(); rm.compile("render_mode[^;]*unshaded")
	if rm.search(src) != null: return false
	return not src.contains("screen_ao(")

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var fault := a[a.find("--fault") + 1] if "--fault" in a else ""
	var shaders: Array = []
	var scripts: Array = []
	for d in DIRS:
		_walk(d, "gdshader", shaders)
		_walk(d, "gd", scripts)
	var bad_sh: Array = []
	for p in shaders:
		if lit_without_ao(FileAccess.get_file_as_string(p)): bad_sh.append(p)
	if fault == "noinc" and lit_without_ao(PLANTED): bad_sh.append("<planted>")
	var bad_gd: Array = []
	var re := RegEx.new(); re.compile("(StandardMaterial3D|ORMMaterial3D)\\.new\\(\\)")
	for p in scripts:
		if p in OWN_ENV: continue
		var lines := FileAccess.get_file_as_string(p).split("\n")
		for i in lines.size():
			if re.search(lines[i]) == null: continue
			var near := "\n".join(lines.slice(i, mini(i + 4, lines.size())))
			if not near.contains("SHADING_MODE_UNSHADED"): bad_gd.append("%s:%d" % [p, i + 1])
	print("%s G1 lit shaders call screen_ao (%d scanned)%s" % ["PASS" if bad_sh.is_empty() else "FAIL", shaders.size(), "" if bad_sh.is_empty() else ": " + ", ".join(bad_sh)])
	print("%s G2 no lit StandardMaterial3D in game scripts%s" % ["PASS" if bad_gd.is_empty() else "FAIL", "" if bad_gd.is_empty() else ": " + ", ".join(bad_gd)])
	var ok := bad_sh.is_empty() and bad_gd.is_empty()
	print("SCREEN_AO_GATE ", "ALL GREEN" if ok else "FAILURES", " fault=", fault)
	quit(0 if ok else 1)
