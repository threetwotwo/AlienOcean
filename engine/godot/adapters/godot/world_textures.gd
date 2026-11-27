## World textures 0.1.0 (engine thread): loads the Textures thread's package (world_textures_v1.zip, unzipped; outside git) into a
## ground_surface material: tiles, island sand field maps, linear tile means, and the locked art bible v1.6 colours.
class_name WorldTextures
extends RefCounted

const BIBLE := {"sand": "cdcac4", "sand_d": "c8c4bb", "rock": "797265", "rock_crev": "5f5a50", "turf": "7b8164", "crust": "a98a8e",
	"rub_a": "9f9583", "rub_b": "c5bfac"}
const SLOTS := {"rBC": "T_Rock_Reef_Base_BC.png", "rN": "T_Rock_Reef_Base_N.png", "rORM": "T_Rock_Reef_Base_ORM.png",
	"tBC": "T_Rock_Reef_Turf_BC.png", "tN": "T_Rock_Reef_Turf_N.png", "tORM": "T_Rock_Reef_Turf_ORM.png",
	"cBC": "T_Rock_Reef_Crust_BC.png", "cN": "T_Rock_Reef_Crust_N.png", "cORM": "T_Rock_Reef_Crust_ORM.png",
	"gBC": "T_Sand_Fine_BC.jpg", "gN": "T_Sand_Fine_N.png", "gM": "T_Sand_Fine_M.png",
	"dBC": "T_Sand_Debris_BCA.png", "dN": "T_Sand_Debris_N.png", "dM": "T_Sand_Debris_M.png",
	"fA": "T_SandField_A.png", "fB": "T_SandField_B.png", "fC": "T_SandField_C.png", "fD": "T_SandField_D.png"}

static func lin(hex: String) -> Vector3:
	var c := Color("#" + hex)
	return Vector3(pow(c.r, 2.2), pow(c.g, 2.2), pow(c.b, 2.2))   # the Textures rule: pow 2.2 on the bible's sRGB

static func mean_lin(img: Image, srgb: bool) -> Vector3:
	var im: Image = img.duplicate(); im.resize(64, 64)
	var s := Vector3.ZERO
	for y in 64:
		for x in 64:
			var c: Color = im.get_pixel(x, y)
			s += Vector3(pow(c.r, 2.2), pow(c.g, 2.2), pow(c.b, 2.2)) if srgb else Vector3(c.r, c.g, c.b)
	return s / 4096.0

static func make_material(dir: String) -> ShaderMaterial:
	var m := ShaderMaterial.new(); m.shader = load("res://look/ground_surface.gdshader")
	var imgs := {}
	for slot in SLOTS:
		var img := Image.load_from_file(dir.path_join(SLOTS[slot]))
		if img == null: push_warning("missing " + SLOTS[slot]); continue
		if not slot.begins_with("f"): img.generate_mipmaps()
		imgs[slot] = img
		m.set_shader_parameter(slot, ImageTexture.create_from_image(img))
	for k in [["cSand", "sand"], ["cSandD", "sand_d"], ["cRock", "rock"], ["cCrev", "rock_crev"], ["cTurf", "turf"], ["cCrust", "crust"],
			["cRubA", "rub_a"], ["cRubB", "rub_b"]]:
		m.set_shader_parameter(k[0], lin(BIBLE[k[1]]))
	# cRubMid: the sRGB midpoint of the two rubble colours, linear
	var a := Color("#" + BIBLE.rub_a); var b := Color("#" + BIBLE.rub_b); var mid := a.lerp(b, 0.5)
	m.set_shader_parameter("cRubMid", Vector3(pow(mid.r, 2.2), pow(mid.g, 2.2), pow(mid.b, 2.2)))
	if imgs.has("rBC"): m.set_shader_parameter("mRock", mean_lin(imgs.rBC, true))
	if imgs.has("tBC"): m.set_shader_parameter("mTurf", mean_lin(imgs.tBC, true))
	if imgs.has("cBC"): m.set_shader_parameter("mCrust", mean_lin(imgs.cBC, true))
	if imgs.has("gBC"): m.set_shader_parameter("mGrain", mean_lin(imgs.gBC, false))
	return m
