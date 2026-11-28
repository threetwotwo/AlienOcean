## IssueReport 0.1.0 (test level thread, 28 Nov 2026): what F8 saves. One folder per report under playtest_reports/ at the
## repository root (beside engine/), so on Gary's Mac it sits inside his approved folder and threads read it without him
## sending anything. Folder: <UTC stamp>/ with report.json and screenshot.png. AO_REPORTS overrides the root folder.
## Fields (REQUIRED, checked by verify() and by tests/test_test_level.gd): note, utc, version, where, state, stats,
## frame_ms (last 600 frame times), monitors, log_tail (last 200 lines of Godot's log), screenshot.
class_name IssueReport
extends RefCounted

const REQUIRED := ["note", "utc", "version", "machine", "where", "state", "stats", "frame_ms", "log_tail", "screenshot"]

static func root_dir() -> String:
	if OS.get_environment("AO_REPORTS") != "": return OS.get_environment("AO_REPORTS")
	return ProjectSettings.globalize_path("res://").path_join("../../playtest_reports").simplify_path()

## Write one report. shot: the frame as an Image (null when there is none, e.g. headless). Returns the folder.
static func write(level, note: String, shot: Image, root := "") -> String:
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-")
	var dir := (root if root != "" else root_dir()).path_join(stamp)
	var n := 1
	while DirAccess.dir_exists_absolute(dir):
		n += 1; dir = (root if root != "" else root_dir()).path_join("%s_%d" % [stamp, n])
	DirAccess.make_dir_recursive_absolute(dir)
	var shot_name := ""
	if shot != null and shot.save_png(dir.path_join("screenshot.png")) == OK: shot_name = "screenshot.png"
	var rep := {
		"note": note,
		"utc": Time.get_datetime_string_from_system(true),
		"version": _version(),
		"machine": {"os": OS.get_name(), "cpu": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(),
			"driver": RenderingServer.get_video_adapter_api_version(), "godot": Engine.get_version_info().string},
		"where": level.where(),
		"state": level.get_state(),
		"stats": level.stats(),
		"frame_ms": Array(level.frame_ms),
		"missing_assets": level.missing_assets,
		"log_tail": _log_tail(200),
		"screenshot": shot_name,
	}
	var f := FileAccess.open(dir.path_join("report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rep, "  "))
	f.close()
	return dir

## The fields a report is missing or left empty (empty list = complete).
static func verify(dir: String) -> Array:
	var bad := []
	var f := FileAccess.open(dir.path_join("report.json"), FileAccess.READ)
	if f == null: return ["report.json"]
	var rep = JSON.parse_string(f.get_as_text())
	if typeof(rep) != TYPE_DICTIONARY: return ["report.json unreadable"]
	for k in REQUIRED:
		if not rep.has(k): bad.append(k)
	if rep.get("screenshot", "") == "" or not FileAccess.file_exists(dir.path_join(str(rep.get("screenshot", "")))):
		if not "screenshot" in bad: bad.append("screenshot")
	if rep.has("frame_ms") and (rep.frame_ms as Array).is_empty(): bad.append("frame_ms empty")
	if rep.has("where") and not (rep.where as Dictionary).has("feet"): bad.append("where.feet")
	if rep.has("state") and not (rep.state as Dictionary).has("toggles"): bad.append("state.toggles")
	return bad

static func _version() -> String:
	var f := FileAccess.open("res://VERSION", FileAccess.READ)
	var v := f.get_as_text().strip_edges() if f != null else "?"
	var head := FileAccess.open("res://../../.git/HEAD", FileAccess.READ)
	if head != null:
		var r := head.get_as_text().strip_edges()
		if r.begins_with("ref: "):
			var rf := FileAccess.open("res://../../.git/" + r.substr(5), FileAccess.READ)
			if rf != null: v += " @" + rf.get_as_text().strip_edges().substr(0, 9) + " (" + r.get_file() + ")"
	return v

static func _log_tail(lines: int) -> Array:
	var p := String(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null: return ["(no log file at %s)" % p]
	var all := f.get_as_text().split("\n")
	return Array(all.slice(maxi(0, all.size() - lines)))
