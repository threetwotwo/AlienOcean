## World root 0.1.0 (engine thread): the one Node that puts the shared world state on Godot.
## Owns the key light, the environment, the sky, the camera exposure and the water uniforms, all driven by the world
## clock (core/world/sky_clock.gd, the Unreal sky clock's maths, sun_v184) and the lagoon water
## (core/world/water_optics.gd, core/world/lagoon_water.gd). Merges the old sky_clock_driver.gd, look/sky_driver.gd
## and WaterOptics.push_globals (27 Nov architecture cleanup).
## Shared instances for gameplay: .clock (SkyClock), .state (the clock's last sky_state), .water (LagoonWaterField,
## the WaterQuery contract), .optics (WaterOptics), .exposure (buffer units per nit), .streamer (later).
## Use: add_child(world_root); world_root.attach_camera(cam); world_root.apply(cam.global_position.y) when the clock
## or the eye's side of the surface changes.
## Ports the Unreal clock's write_light() / exposure steps: the key light carries the brightest body (pick_key +
## key_fade), EV100 slides with the light (noon cap 15.5), under water the steady eye sits 0.75 stop below the cap,
## each place has its compensation (calm lagoon +1.2). Under water the key light points along the refracted sun and
## is pre-attenuated to z_ref; water-aware shaders correct for their own depth.
## Godot axes: SkyClock is z-up (x, y, z); Godot is y-up: (x, z, -y).
class_name WorldRoot
extends Node3D

@export var hours := 12.0
@export var place := "calm_lagoon"
@export var noon_yaw := 0.0
@export var floor_y := 0.0            # the lagoon's sand (floor tiles sit at y -0.3..0.1 under a 4 m surface)
@export var z_ref := 2.0              # depth the key light is pre-attenuated to (eye / fish depth)
const UNDER_WHITE := {"calm_lagoon": Vector3(1.0713, 0.9914, 0.8748)}   # v183: under water the white point is daylight (6500 K)
const UNDER_WHITE_FADE_M := 0.20      # v183: faded in over the camera's first 0.2 m of depth

var clock: GDScript = SkyClock
var optics: GDScript = WaterOptics
var water := LagoonWaterField.new()
var streamer = null                   # M12 open-world streamer, later
var state := {}
var exposure := 1.0
var light: DirectionalLight3D
var env: Environment
var cam_attr: CameraAttributesPhysical
var sky_mat: ShaderMaterial
var key := ""
var last := {}
var _dome_sun := Vector3.INF
var agx_fx: AgxEffect
var _dome_g := 0.0

static func to_godot(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)

static func ev100(lux: float) -> float:
	return log(maxf(0.18 * lux / PI * 100.0 / 12.5, 1e-12)) / log(2.0)

static func air_tint(elev: float) -> Color:
	## beam colour after the air, per band, normalised to green: the Unreal sun disc's extinction (SUN_HLSL,
	## float3(0.0862, 0.1665, 0.2961) x air mass), which the old SkyAtmosphere also applied to the light.
	if elev <= 0.0: return Color(1, 1, 1)
	var m := SkyClock.airmass(elev)
	var g := exp(-SkyClock.AIR_EXT.y * m)
	return Color(exp(-SkyClock.AIR_EXT.x * m) / g, 1.0, exp(-SkyClock.AIR_EXT.z * m) / g)

func _init() -> void:
	name = "WorldRoot"
	declare_globals()
	light = DirectionalLight3D.new(); light.name = "KeyLight"
	light.shadow_enabled = true; light.directional_shadow_max_distance = 60.0
	add_child(light)
	env = Environment.new()
	var sky := Sky.new(); sky_mat = ShaderMaterial.new(); sky_mat.shader = load("res://look/sky.gdshader"); sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY; env.sky = sky; env.background_intensity = 1.0   # sky shader outputs nits
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true; env.ssao_radius = 1.2; env.ssao_intensity = 1.6
	env.ssil_enabled = true; env.ssil_radius = 4.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.glow_enabled = true; env.glow_intensity = 0.3
	var we := WorldEnvironment.new(); we.environment = env; add_child(we)
	agx_fx = AgxEffect.new(); var comp := Compositor.new(); comp.compositor_effects = [agx_fx]; we.compositor = comp
	set_agx(true)
	cam_attr = CameraAttributesPhysical.new(); cam_attr.auto_exposure_enabled = false
	cam_attr.frustum_near = 0.02; cam_attr.frustum_far = 400.0

func set_agx(on: bool) -> void:
	## on: the Unreal AgX tonemapper (look/agx_post.glsl) replaces Godot's; LINEAR leaves only the sRGB encoding and
	## Godot's glow is off (Unreal bloom not ported yet). off: Godot's built-in AgX with its glow, as before 27 Nov.
	agx_fx.enabled = on
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR if on else Environment.TONE_MAPPER_AGX
	env.glow_enabled = not on

func attach_camera(cam: Camera3D) -> void:
	## physical exposure on the camera, plus the water between the eye and every pixel (look/underwater_view)
	cam.attributes = cam_attr
	var q := MeshInstance3D.new(); q.name = "UnderwaterView"
	var qm := QuadMesh.new(); qm.size = Vector2(2, 2); q.mesh = qm
	var qmat := ShaderMaterial.new(); qmat.shader = load("res://look/underwater_view.gdshader"); q.material_override = qmat
	q.extra_cull_margin = 16384.0; q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; cam.add_child(q)

func set_fov(fov_deg: float) -> void:
	## CameraAttributesPhysical owns the field of view (18 mm half sensor height)
	cam_attr.frustum_focal_length = 18.0 / tan(deg_to_rad(fov_deg) * 0.5)

func make_surface(size_m := 160.0) -> MeshInstance3D:
	## the drawn water surface overhead (look/water_surface.gdshader), at the water's level
	var surf := MeshInstance3D.new(); surf.name = "WaterSurface"
	var pm := PlaneMesh.new(); pm.size = Vector2(size_m, size_m); surf.mesh = pm
	surf.position.y = water.level
	var wm := ShaderMaterial.new(); wm.shader = load("res://look/water_surface.gdshader"); surf.material_override = wm
	surf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return surf

func apply(cam_y: float) -> Dictionary:
	var water_y := water.level
	var st := SkyClock.sky_state(hours, noon_yaw)
	state = st
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
	exposure = pow(2.0, bias) / (1.2 * pow(2.0, ev))  # buffer units per nit (Godot's normalisation)
	_push_water(water_y, up_air, beam_h, st.skylux)
	_push_sky(st)
	if agx_fx.enabled:
		agx_fx.exposure = exposure; agx_fx.buf_scale = exposure   # Godot's buffer arrives already exposed (measured 27 Nov)
		agx_fx.white_now = SkyClock.white_now(st)
		agx_fx.sun_dir = to_godot(st.sun.dir); agx_fx.under = under
		agx_fx.moon_a = _moon_view(st.A.dir, SkyClock.MOONS[0].drawn_deg)
		agx_fx.moon_b = _moon_view(st.B.dir, SkyClock.MOONS[1].drawn_deg)
		var kw := clampf((water_y - cam_y) / UNDER_WHITE_FADE_M, 0.0, 1.0)
		agx_fx.depth_gain = Vector3.ONE.lerp(UNDER_WHITE.get(place, Vector3.ONE), kw)
	var a := WaterOptics.absorb(); var b := WaterOptics.scatter()
	if under:
		var tr := WaterOptics.refract_sun(up_air)
		var kd: Vector3 = (a + WaterOptics.BB * b) / tr.y
		var att := Color(exp(-kd.x * z_ref), exp(-kd.y * z_ref), exp(-kd.z * z_ref))
		light.look_at_from_position(Vector3.ZERO, -tr, Vector3.FORWARD if absf(tr.y) > 0.99 else Vector3.UP)
		light.light_intensity_lux = beam_h * WaterOptics.FRESNEL_SUN / tr.y
		light.light_color = (tint * att)
		# ambient for standard materials (fish): the water's diffuse light at z_ref, sky from above + sand from below
		var ku: Vector3 = (a + WaterOptics.BB * b) / 0.75
		var ek: Vector3 = Vector3(exp(-ku.x * z_ref), exp(-ku.y * z_ref), exp(-ku.z * z_ref)) * st.skylux * WaterOptics.FRESNEL_SKY
		# + the sand's bounce from below (Lighting's sand bounce: the lower hemisphere lit by the sand), half the sphere each
		var H := water_y - floor_y
		var eh: Vector3 = (Vector3(exp(-kd.x * H), exp(-kd.y * H), exp(-kd.z * H)) * beam_h * WaterOptics.FRESNEL_SUN
			+ Vector3(exp(-ku.x * H), exp(-ku.y * H), exp(-ku.z * H)) * st.skylux * WaterOptics.FRESNEL_SKY)
		var sand := Vector3(WaterOptics.SAND.r, WaterOptics.SAND.g, WaterOptics.SAND.b)
		var eu: Vector3 = eh * sand * Vector3(exp(-ku.x * (H - z_ref)), exp(-ku.y * (H - z_ref)), exp(-ku.z * (H - z_ref)))
		var amb: Vector3 = (ek + eu) * 0.5 / PI * exposure            # ambient is in buffer units (measured 27 Nov)
		var mx := maxf(amb.x, maxf(amb.y, amb.z))
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(amb.x / mx, amb.y / mx, amb.z / mx) if mx > 0.0 else Color.BLACK
		env.ambient_light_energy = mx
	else:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		var dz := dome(Vector3.UP, to_godot(st.sun.dir)); var dm := maxf(dz.x, maxf(dz.y, dz.z))
		env.ambient_light_color = Color(dz.x / dm, dz.y / dm, dz.z / dm) if dm > 0.0 else Color.WHITE
		env.ambient_light_energy = st.skylux / PI * exposure
		light.look_at_from_position(Vector3.ZERO, -up_air, Vector3.FORWARD if absf(up_air.y) > 0.99 else Vector3.UP)
		light.light_intensity_lux = beam_h / maxf(up_air.y, 0.02)
		light.light_color = tint
	last = {"key": key, "elev": body.elev, "total_lux": st.total, "sky_lux": st.skylux, "beam_h": beam_h,
		"ev100": ev, "bias": bias, "under": under}
	return last

static func _moon_view(d: Vector3, drawn_deg: float) -> Vector4:
	var g := to_godot(d)
	return Vector4(g.x, g.y, g.z, deg_to_rad(drawn_deg) * 0.5)

# ---- water uniforms (shared by every water-aware shader: look/water_physics.gdshaderinc) ----

static func declare_globals() -> void:
	## global uniforms must exist before shaders compile (headless scripts can't rely on project.godot entries)
	if Engine.has_meta("water_globals"): return
	var F := RenderingServer.GLOBAL_VAR_TYPE_FLOAT; var V := RenderingServer.GLOBAL_VAR_TYPE_VEC3
	var defs := {"water_y": [F, LagoonWaterField.SURFACE_Y], "water_floor_y": [F, 0.0],
		"water_a": [V, Vector3.ZERO], "water_b": [V, Vector3.ZERO], "water_kd": [V, Vector3.ZERO], "water_ku": [V, Vector3.ZERO],
		"water_sun_w": [V, Vector3.UP], "water_es0": [F, 0.0], "water_ek0": [F, 0.0], "water_exposure": [F, 1.0],
		"water_glow_k": [F, 1.0], "water_zref": [F, 2.0], "water_sky_nits": [F, 0.0],
		"water_sand": [RenderingServer.GLOBAL_VAR_TYPE_COLOR, Color.WHITE]}
	for k in defs:
		RenderingServer.global_shader_parameter_add(k, defs[k][0], defs[k][1])
	Engine.set_meta("water_globals", true)

func _push_water(water_y: float, sun_up_air: Vector3, beam_h_lux: float, sky_lux: float) -> void:
	var a := WaterOptics.absorb(); var b := WaterOptics.scatter()
	var tr := WaterOptics.refract_sun(sun_up_air)
	var rs := RenderingServer
	rs.global_shader_parameter_set("water_y", water_y)
	rs.global_shader_parameter_set("water_floor_y", floor_y)
	rs.global_shader_parameter_set("water_a", a)
	rs.global_shader_parameter_set("water_b", b)
	rs.global_shader_parameter_set("water_kd", (a + WaterOptics.BB * b) / tr.y)
	rs.global_shader_parameter_set("water_ku", (a + WaterOptics.BB * b) / 0.75)
	rs.global_shader_parameter_set("water_sun_w", tr)
	rs.global_shader_parameter_set("water_es0", beam_h_lux * WaterOptics.FRESNEL_SUN)   # horizontal lux of the sun just under
	rs.global_shader_parameter_set("water_ek0", sky_lux * WaterOptics.FRESNEL_SKY)      # horizontal lux of the sky just under
	rs.global_shader_parameter_set("water_exposure", exposure)
	rs.global_shader_parameter_set("water_glow_k", WaterOptics.LOOK_SET.glow_k)
	rs.global_shader_parameter_set("water_sand", WaterOptics.SAND)
	rs.global_shader_parameter_set("water_sky_nits", sky_lux / PI)   # clear sky as a uniform dome (stand-in for the surface)
	rs.global_shader_parameter_set("water_zref", z_ref)

# ---- sky (look/sky.gdshader): dome scaled so its light on level ground equals the clock's sky_lux ----

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

func _push_sky(st: Dictionary) -> void:
	var mat := sky_mat
	var s: Vector3 = to_godot(st.sun.dir)
	mat.set_shader_parameter("sun_dir", s)
	mat.set_shader_parameter("sun_toa", st.sun.toa)
	mat.set_shader_parameter("sun_size", SkyClock.SUN_SIZE_NOW)
	mat.set_shader_parameter("corona", SkyClock.CORONA)
	mat.set_shader_parameter("moon_a_dir", to_godot(st.A.dir))
	mat.set_shader_parameter("moon_b_dir", to_godot(st.B.dir))
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
	if not s.is_equal_approx(_dome_sun):      # the dome integral only changes with the sun
		_dome_sun = s; _dome_g = ground_lux_of_dome(s)
	mat.set_shader_parameter("sky_norm", (st.skylux - SkyClock.NIGHT_SKY_LUX) / _dome_g if _dome_g > 1e-12 else 0.0)
	mat.set_shader_parameter("sea_nits", SkyClock.OCEAN_ALBEDO * st.total / PI)
