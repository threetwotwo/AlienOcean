## M30 world clock adapter 0.1.0: puts SkyClock's state on Godot's lights, ambient and exposure.
## Ports the Unreal clock's write_light() / exposure steps (sun_v184): the key light carries the brightest body
## (pick_key + key_fade), exposure EV100 slides with the light (noon cap 15.5), under water the steady eye sits
## 0.75 stop below the cap, and each place has its compensation (calm lagoon +1.2).
## Under water the key light points along the refracted sun and is pre-attenuated to the reference depth z_ref;
## water-aware shaders correct for their own depth (look/water_optics.gd globals).
## Godot axes: SkyClock is z-up (x, y, z); Godot is y-up: (x, z, -y).
class_name SkyClockDriver
extends Node

@export var hours := 12.0
@export var place := "calm_lagoon"
@export var noon_yaw := 0.0
@export var water_y := 5.0
@export var floor_y := 0.0            # the lagoon's sand (floor tiles sit at y -0.3..0.1 under a 4 m surface)
@export var z_ref := 2.0              # depth the key light is pre-attenuated to (eye / fish depth)
var light: DirectionalLight3D
var env: Environment
var cam_attr: CameraAttributesPhysical
var key := ""
var last := {}

static func to_godot(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)

static func ev100(lux: float) -> float:
	return log(maxf(0.18 * lux / PI * 100.0 / 12.5, 1e-12)) / log(2.0)

static func air_tint(elev: float) -> Color:
	## beam colour after the air, per band (Rayleigh ~ lambda^-4 + sea salt), normalised to green.
	## Stand-in for Unreal's SkyAtmosphere reddening, which the old clock relied on.
	if elev <= 0.0: return Color(1, 1, 1)
	var m := SkyClock.airmass(elev)
	var tau := Vector3(0.10 * pow(550.0 / 610.0, 4) + 0.06, 0.16, 0.10 * pow(550.0 / 465.0, 4) + 0.06)
	var g := exp(-tau.y * m)
	return Color(exp(-tau.x * m) / g, 1.0, exp(-tau.z * m) / g)

func apply(cam_y: float) -> Dictionary:
	var st := SkyClock.sky_state(hours, noon_yaw)
	key = SkyClock.pick_key(st, key)
	var body: Dictionary = st[key]
	var fade := SkyClock.key_fade(st, key)
	var under := cam_y < water_y
	var up_air := to_godot(body.dir)
	var beam_h: float = SkyClock.beam_lux(body.elev) * (body.toa / SkyClock.STAR.toa_lux if key != "sun" else 1.0) * fade
	var tint: Color = SkyClock.kelvin_rgb(body.kelvin) * air_tint(body.elev)
	if key != "sun": tint = tint * SkyClock.MOON_TINTS[key].lerp(Color(1, 1, 1), 0.5)
	# exposure: the eye's dark end slid with the light; steady under water; place compensation
	var noon_total: float = SkyClock.sky_state(12.0)["total"]
	var ev := ev100(st.total) - (ev100(noon_total) - SkyClock.EV_MAX)
	if under: ev -= SkyClock.STEADY_UNDER_AT
	var bias: float = SkyClock.EXPOSURE_BIAS.get(place, 0.0)
	# EV100 = log2(N^2 / t) at ISO 100. f/22 keeps Godot's physical depth of field out of the way (deep focus).
	cam_attr.exposure_sensitivity = 100.0; cam_attr.exposure_aperture = 22.0
	cam_attr.exposure_shutter_speed = pow(2.0, ev) / (22.0 * 22.0)
	cam_attr.exposure_multiplier = pow(2.0, bias)
	var exposure := pow(2.0, bias) / (1.2 * pow(2.0, ev))  # buffer units per nit (Godot's normalisation)
	WaterOptics.push_globals(water_y, floor_y, up_air, beam_h, st.skylux, exposure)
	RenderingServer.global_shader_parameter_set("water_zref", z_ref)
	if under:
		var tr := WaterOptics.refract_sun(up_air)
		var kd: Vector3 = (WaterOptics.absorb() + WaterOptics.BB * WaterOptics.scatter()) / tr.y
		var att := Color(exp(-kd.x * z_ref), exp(-kd.y * z_ref), exp(-kd.z * z_ref))
		light.look_at_from_position(Vector3.ZERO, -tr, Vector3.FORWARD if absf(tr.y) > 0.99 else Vector3.UP)
		light.light_intensity_lux = beam_h * WaterOptics.FRESNEL_SUN / tr.y
		light.light_color = (tint * att)
		# ambient for standard materials (fish): the water's diffuse light at z_ref, sky from above + sand from below
		var ku: Vector3 = (WaterOptics.absorb() + WaterOptics.BB * WaterOptics.scatter()) / 0.75
		var ek: Vector3 = Vector3(exp(-ku.x * z_ref), exp(-ku.y * z_ref), exp(-ku.z * z_ref)) * st.skylux * WaterOptics.FRESNEL_SKY
		var amb: Vector3 = ek / PI * exposure                         # ambient is in buffer units (measured 27 Nov)
		var mx := maxf(amb.x, maxf(amb.y, amb.z))
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(amb.x / mx, amb.y / mx, amb.z / mx) if mx > 0.0 else Color.BLACK
		env.ambient_light_energy = mx
	else:
		light.look_at_from_position(Vector3.ZERO, -up_air, Vector3.FORWARD if absf(up_air.y) > 0.99 else Vector3.UP)
		light.light_intensity_lux = beam_h / maxf(up_air.y, 0.02)
		light.light_color = tint
	last = {"key": key, "elev": body.elev, "total_lux": st.total, "sky_lux": st.skylux, "beam_h": beam_h,
		"ev100": ev, "bias": bias, "under": under}
	return last
