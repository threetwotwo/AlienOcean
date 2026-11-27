## Sky driver 0.1.0 (engine thread): feeds look/sky.gdshader from the world clock (M30).
## The dome is scaled so the sky's light on level ground equals the clock's sky_lux (the Unreal clock's number);
## dome() here mirrors the shader's exactly.
class_name SkyDriver
extends RefCounted

static func _airmass(y: float) -> float:
	var yy := clampf(y, 0.0, 1.0)
	return 1.0 / (yy + 0.50572 * pow(rad_to_deg(asin(yy)) + 6.07995, -1.6364))

static func dome(v: Vector3, s: Vector3) -> Vector3:
	## mirror of sky.gdshader dome(): Godot's PhysicalSkyMaterial shape at its defaults
	var za := clampf(s.y, -1.0, 1.0)
	var sun_energy := maxf(0.0, 1.0 - exp(-((PI * 0.5) - acos(za))))
	var sun_fade := 1.0 - clampf(1.0 - exp(s.y), 0.0, 1.0)
	var rb := (2.0 - (1.0 - sun_fade)) * Vector3(0.3, 0.405, 0.6) * 0.0001
	var mb := 10.0 * 0.005 * Vector3(0.69, 0.729, 0.812) * 0.000434
	var zenith := acos(maxf(0.0, v.y))
	var om := 1.0 / (cos(zenith) + 0.15 * pow(93.885 - rad_to_deg(zenith), -1.253))
	var ct := v.dot(s)
	var rp := (3.0 / (16.0 * PI)) * (1.0 + pow(ct * 0.5 + 0.5, 2.0))
	var g := 0.8
	var mp := (1.0 / (4.0 * PI)) * ((1.0 - g * g) / pow(1.0 - 2.0 * g * ct + g * g, 1.5))
	var out := Vector3.ZERO
	for i in 3:
		var ext := exp(-(rb[i] * 8.4e3 * om + mb[i] * 1.25e3 * om))
		var ratio: float = (rb[i] * rp + mb[i] * mp) / (rb[i] + mb[i])
		var lin := pow(sun_energy * ratio * (1.0 - ext), 1.5)
		lin *= lerpf(1.0, pow(sun_energy * ratio * ext, 0.5), clampf(pow(1.0 - za, 5.0), 0.0, 1.0))
		out[i] = lin
	return out

static func ground_lux_of_dome(s: Vector3) -> float:
	## luminance-weighted horizontal illuminance of the unscaled dome (midpoint rule, 24 x 48)
	var tot := 0.0
	var nt := 24; var np := 48
	for i in nt:
		var th := (i + 0.5) / nt * PI * 0.5          # from zenith
		for j in np:
			var ph := (j + 0.5) / np * TAU
			var v := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			var L := dome(v, s)
			var Y := 0.2126 * L.x + 0.7152 * L.y + 0.0722 * L.z
			tot += Y * cos(th) * sin(th) * (PI * 0.5 / nt) * (TAU / np)
	return tot

static func apply(mat: ShaderMaterial, st: Dictionary, to_godot: Callable, exposure: float) -> void:
	var s: Vector3 = to_godot.call(st.sun.dir)
	mat.set_shader_parameter("sun_dir", s)
	mat.set_shader_parameter("sun_toa", st.sun.toa)
	mat.set_shader_parameter("sun_size", SkyClock.SUN_SIZE_NOW)
	mat.set_shader_parameter("corona", SkyClock.CORONA)
	mat.set_shader_parameter("moon_a_dir", to_godot.call(st.A.dir))
	mat.set_shader_parameter("moon_b_dir", to_godot.call(st.B.dir))
	mat.set_shader_parameter("moon_a_deg", SkyClock.MOONS[0].drawn_deg)
	mat.set_shader_parameter("moon_b_deg", SkyClock.MOONS[1].drawn_deg)
	mat.set_shader_parameter("moon_a_albedo", SkyClock.MOON_LOOK.albedo_A)
	mat.set_shader_parameter("moon_b_albedo", SkyClock.MOON_LOOK.albedo_B)
	var ka := SkyClock.kelvin_rgb(SkyClock.MOONS[0].kelvin); var kb := SkyClock.kelvin_rgb(SkyClock.MOONS[1].kelvin)
	mat.set_shader_parameter("moon_a_tint", Vector3(ka.r, ka.g, ka.b))
	mat.set_shader_parameter("moon_b_tint", Vector3(kb.r, kb.g, kb.b))
	mat.set_shader_parameter("maria", SkyClock.MOON_LOOK.maria)
	mat.set_shader_parameter("planetshine", SkyClock.MOON_LOOK.planetshine)
	mat.set_shader_parameter("moon_edge", SkyClock.MOON_LOOK.moon_edge)
	var g := ground_lux_of_dome(s)
	mat.set_shader_parameter("sky_norm", (st.skylux - SkyClock.NIGHT_SKY_LUX) / g if g > 1e-12 else 0.0)
	mat.set_shader_parameter("sea_nits", SkyClock.OCEAN_ALBEDO * st.total / PI)
