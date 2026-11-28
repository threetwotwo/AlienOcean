## Sky derivatives gate 0.1.0 (horizon line thread, 28 Nov 2026). Screen derivatives (fwidth, dFdx, dFdy) are only defined
## when all four pixels of a 2 x 2 quad run them. look/sky.gdshader used to take them inside `if (v.y < 0) ... else` (the
## sun disc's edge) and after moon()'s early return: on the quads that straddle the horizon Metal returned garbage, the
## sun disc's edge test passed, and the full sun radiance drew a 1 px line along the horizon (Gary's 28 Nov playtest,
## pink with the bloom). Checks:
##   S1 in sky(), every derivative and every call that takes them (stars(, moon() comes before the first branch on the
##      view direction (an `if (` whose condition reads v / EYEDIR)
##   S2 no function in sky.gdshader takes a derivative after a `return` inside its body (an early return leaves lanes out)
## Planted faults: --fault branch puts an fwidth inside the v.y branch (S1 must fail); --fault early puts one after an
## early return (S2 must fail).
## --file <path> checks another copy (the pre-fix shader fails S1 and S2).
## Run: godot --headless --path . --script res://tests/test_sky_derivatives.gd [-- --fault branch|early]   exit 0 = all green
extends SceneTree

const SKY := "res://look/sky.gdshader"
const DERIV := "\\b(fwidth|dFdx|dFdy)\\s*\\(|\\bstars\\s*\\(|\\bmoon\\s*\\("

static func _strip_comments(src: String) -> String:
	var re := RegEx.new(); re.compile("//[^\\n]*")
	return re.sub(src, "", true)

static func _body(src: String, head: String) -> String:
	## the text of the function whose header contains `head`, braces balanced
	var i := src.find(head)
	if i < 0: return ""
	var j := src.find("{", i)
	var depth := 0
	for k in range(j, src.length()):
		var ch := src[k]
		if ch == "{": depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0: return src.substr(j, k - j + 1)
	return ""

static func s1_bad(src: String) -> Array:
	var body := _body(_strip_comments(src), "void sky()")
	var br := RegEx.new(); br.compile("if\\s*\\([^)]*\\b(v|EYEDIR)\\.")
	var m := br.search(body)
	if m == null: return []
	var de := RegEx.new(); de.compile(DERIV)
	var out := []
	for d in de.search_all(body):
		if d.get_start() > m.get_start(): out.append("sky(): %s after the branch" % d.get_string().strip_edges())
	return out

static func s2_bad(src: String) -> Array:
	var s := _strip_comments(src)
	var fn := RegEx.new(); fn.compile("\\n(?:vec[234]|float|void|bool|int)\\s+(\\w+)\\s*\\([^)]*\\)\\s*\\{")
	var de := RegEx.new(); de.compile("\\b(fwidth|dFdx|dFdy)\\s*\\(")
	var out := []
	for f in fn.search_all(s):
		var body := _body(s, f.get_string().strip_edges())
		var r := body.find("return")
		if r < 0: continue
		var last := body.rfind("return")
		var tail := body.substr(r, last - r)       # between the first (early) return and the final one
		if de.search(tail) != null: out.append("%s(): derivative after an early return" % f.get_string(1))
	return out

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var fault := a[a.find("--fault") + 1] if "--fault" in a else ""
	var src := FileAccess.get_file_as_string(a[a.find("--file") + 1] if "--file" in a else SKY)   # --file: check another copy (e.g. the old shader)
	if fault == "branch": src = src.replace("else COLOR = col;", "else COLOR = col * max(fwidth(v.y), 1.0);")
	if fault == "early": src += "\nfloat planted(vec3 v) {\n\tif (v.y > 0.5) return 0.0;\n\tfloat w = fwidth(v.x);\n\treturn w;\n}\n"
	var b1 := s1_bad(src)
	var b2 := s2_bad(src)
	print("%s S1 sky(): derivatives before the branch on the view%s" % ["PASS" if b1.is_empty() else "FAIL", "" if b1.is_empty() else ": " + ", ".join(b1)])
	print("%s S2 no derivative after an early return%s" % ["PASS" if b2.is_empty() else "FAIL", "" if b2.is_empty() else ": " + ", ".join(b2)])
	var ok := b1.is_empty() and b2.is_empty()
	print("SKY_DERIVATIVES ", "ALL GREEN" if ok else "FAILURES", " fault=", fault)
	quit(0 if ok else 1)
