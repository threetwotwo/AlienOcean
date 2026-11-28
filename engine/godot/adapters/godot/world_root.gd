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
## God rays (look/god_rays.gdshaderinc, lagoonwater v98's, drawn by the underwater view): .god_rays false = off.
## Godot axes: SkyClock works in Unreal's world axes (z up, left-handed); Godot is y up, right-handed. Unreal (x, y, z)
## is Godot (x, z, y): a swap, so a mirror, as Unreal's own glTF import does. The world pieces fix it: the lagoon GLBs
## (island/tools/slice_common.py write_glb) sit in Unreal at (g.x, g.z, g.y) x 100 cm (lagoon slice check P4, bounding
## boxes). The island frame (x east, y north, z up, right-handed) is a different one: island (x, y, z) = Godot (x, z, -y).
class_name WorldRoot
extends Node3D

@export var hours := 12.0
@export var tide_on := true          # the sea level follows the tide (false pins it at the mean, for reference shots)
@export var place := "calm_lagoon"
@export var noon_yaw := 0.0
@export var floor_y := 0.0            # the lagoon's sand (floor tiles sit at y -0.3..0.1 under a 4 m surface)
@export var z_ref := 2.0              # depth the key light is pre-attenuated to (eye / fish depth)
const UNDER_WHITE := {"calm_lagoon": Vector3(0.969, 0.874, 1.249)}   # the key frame diver's white balance (gain measured from the
## Blender rig, Gary card 28 Nov 01:52Z; was v183 daylight 1.0713/0.9914/0.8748). Stand-in for an auto white balance on the water's cast.
const UNDER_WHITE_FADE_M := 0.20      # v183: faded in over the camera's first 0.2 m of depth
## v168 depth colour (art bible 8.8): the camera gives back a share of the colour the water took at its depth.
## Off by default, as in the Unreal lagoon since v176 (Style 16:58Z); depth_colour = true turns it on.
@export var depth_colour := false
## Art direction (27 Nov, Gary: 'art direction trumps'): how much of its colour sunlight and skylight keep on the way
## down to the floor. 0 = the physics (red lost over 4 m); 1 = the light arrives as white as it entered, with the same
## overall loss. The haze along the view (absorption + scattering between eye and object) is untouched.
## Art direction: stops added under water on top of the place's compensation, and the water haze's strength
## (Unreal GlowK, Gary's clarity pick 2.5). Under water only, so the sky above the sea keeps its exposure.
@export var under_exposure_art := 1.0     # Gary picked "Brighter" 27 Nov 17:06Z
@export var fill_occluded := true          # the water's fill light goes through Godot's ambient, so SSAO / SSIL occlude it (false = as before, unoccluded)
@export var cdom := 0.015                  # art lever (a real condition): yellow substance in the water. 0.015 = clear lagoon water: blue outlasts green,
                                           # so distance fades to blue (Gary card 28 Nov 03:03Z; was 0.05, the old key frame; Unreal 0.03)
@export var scat_k := 0.40                 # art lever (a real condition): particles in the water, Unreal LOOK_SET 0.40; less = clearer
@export var sky_fill_k := 0.8              # art lever: share of the sky's light that enters the water (1 = physical: 11 % of the light on the
                                           # 4 m sand at noon). The key frame (Blender, 28 Nov passes) has 7 %: 0.6 here. Feeds the fill, the GI's
                                           # water light field and the haze alike. Gary picked 0.8, between the two (card, 28 Nov 02:02Z).
## the sea's RMS slope for the sun's spread under water: 0.09 = the approved key frame v7c's waves (lmin 0.15 m, wind 2.5 m/s; its 8
## sun lenses spread p50 1.1 deg, a disc of 3.1 deg diameter has that median; this gives 3.0). Was 0.06 (old key frame A).
@export var sea_rms_slope := 0.09
const SUN_DISC_DEG := 0.53
const SDFGI_RESET_STOPS := 3.0
@export var under_white := Vector3.ZERO      # look check: the under-water camera balance (zero = the place's UNDER_WHITE)
## The lagoon's seabed out over the reef and down the drop-off (core/world/bathymetry.gd; the water reads it in
## look/sea_bathy.gdshaderinc, the drop-off's seabed is adapters/godot/reef_terrain.gd): the reef flat starts
## lagoon_radius m from lagoon_centre (Godot x z). Radius 0 = no reef (the lagoon goes on for ever).
@export var lagoon_centre := Vector2.ZERO
@export var lagoon_radius := 150.0
@export var ocean_depth := 1000.0
## the angle (deg, atan2(z, x)) of the reef's first stress-test sector (the vertical wall; Bathymetry.SECTOR_NAMES)
@export var reef_sector_deg := 0.0
func bathymetry() -> Bathymetry:
	var b := Bathymetry.new()
	b.centre = lagoon_centre; b.radius = lagoon_radius; b.ocean_depth = ocean_depth; b.lagoon_d = LagoonWaterField.SURFACE_Y - floor_y   # the mean level: the seabed does not follow the tide
	b.sector_deg = reef_sector_deg
	return b
@export var water_type := 0.0              # 0 = the lagoon's water, 1 = the open ocean's (WaterOptics.optics); between = a blend (shelf)
# weather (28 Nov, look thread; promised to the water surface thread, which wires foam and haze to it): cloud cover 0 clear ..
# 1 overcast. SkyClock.overcast splits the light (Kasten-Czeplak): the sun's beam fades (shadows, caustics, glitter, the disc and
# the moons go with it), the sky's share grows, and the dome blends to the CIE overcast deck (look/sky_overcast.gdshaderinc).
# Pushed as the global sky_overcast. AO_OVERCAST in the shot tool.
@export_range(0.0, 1.0) var sky_overcast := 0.0
@export var motes := true                 # marine snow under water (blind critique r1 row 6); AO_MOTES=0 in the shot tool
@export var gi_k := 1.0                    # art lever: GI strength (SDFGI energy). 1 = physical (the water's fill + the sand's real bounce)
## Bloom (bloom thread, 28 Nov): the key frame's camera veiling glare, done in the AgX pass (look/bloom.glsl).
## bloom 1 = the key frame's glare (develop_v7.py bloom 1), 0 = off; bloom_thr in exposed units (0.18 = middle grey).
@export var bloom := 1.0
@export var bloom_thr := 4.5
## vignette: light lost at the frame corners (0.15 = corners keep 85 %), natural falloff in scene light; 0 = off
@export var vignette := 0.0
@export var glow_k := 1.0                  # Gary picked "Brighter" (haze 1.0; Unreal GlowK was 2.5)
## the haze keeps its forward-scattered light (similarity relation, 28 Nov): 1 = on, 0 = as ported (AO_GLOW_MS=0)
## the drawn sand's colour (world_textures BIBLE sand f0e1c0 and sand_d e3cca2, linear, their mean): the floor beyond
const FAR_SAND := Vector3(0.82, 0.68, 0.44)
static var glow_ms := float(OS.get_environment("AO_GLOW_MS")) if OS.get_environment("AO_GLOW_MS") != "" else 1.0
@export var light_neutral := 1.0          # Gary picked "Full" 27 Nov 16:53Z
## The god rays under the water (Unreal GodK): the light net's map summed along each view ray. false = off (checks).
@export var god_rays := true:
	set(v):
		god_rays = v
		if under_mat: under_mat.set_shader_parameter("god_k", 1.0 if v else 0.0)
@export var depth_colour_share := DEPTH_WB   # art direction lever (27 Nov: Gary 'art direction trumps'); Unreal 0.25
const DEPTH_WB := 0.25                # the share given back
const DEPTH_WB_PATH := 1.2            # m of water per m of depth (sky light)
const WATER_SUBBANDS := [             # clear_lagoon (contracts/water_optics_v6.json): per channel (weight, absorption /m)
	[[0.45, 0.12], [0.4, 0.26], [0.15, 0.4]], [[0.45, 0.038], [0.55, 0.073]], [[1.0, 0.025]]]

static func depth_gain(depth_m: float, share := DEPTH_WB, path := DEPTH_WB_PATH) -> Vector3:
	## sun_v184 depth_gain(): (1 / T)^share per channel, T = the sky light left at depth, scaled so a white card keeps
	## its luminance. 1, 1, 1 at the surface and above, and with share 0.
	var z := maxf(depth_m, 0.0) * path
	var t := Vector3.ZERO
	for i in 3:
		for wa in WATER_SUBBANDS[i]: t[i] += wa[0] * exp(-wa[1] * z)
	var g := Vector3(pow(1.0 / maxf(t.x, 1e-9), share), pow(1.0 / maxf(t.y, 1e-9), share), pow(1.0 / maxf(t.z, 1e-9), share))
	var L := Vector3(0.2126, 0.7152, 0.0722)
	var n := L.dot(t) / maxf(L.dot(g * t), 1e-12)
	return g * n

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
var _gi_reset := 0   # frames left with SDFGI off to drop its cache after a jump in the light (apply)
var _dome_sun := Vector3.INF
var agx_fx: AgxEffect
var cortao_fx: CortaoEffect      # CORTAO screen AO (adapters/godot/cortao_effect.gd); set_ao picks it or Godot's SSAO
var ao_mode := "ssao"
var _surface: SeaSurface          # make_surface's: its floor map is captured again when the light changes (apply)
var under_mat: ShaderMaterial       # the underwater view quad's material (attach_camera)
var caustics: CausticsMap           # the light net's map, drawn once a frame (adapters/godot/caustics_map.gd)
var _dome_g := 0.0

const NIGHT_FLOOR_EV := 0.0           # MPC_Sky NightFloorEV (saved 0)
const NIGHT_OPEN := -4.75             # v72: at night the eye opens to EV100 floor + this
const NIGHT_SHUT := -3.25             # v72: the dark end stops at EV100 floor + this
const BRIGHTEN_STOPS := 1.5           # how far the eye may brighten from the dark end
const NIGHT_LIFT := 0.5               # v34: floats and water +0.5 stop at night
const NIGHT_EYE_UNDER := 1.0          # v73: stops darker under the water at night

static func night_weight(total: float) -> float:
	## v26: 0 at 1000 lux and above, 1 at 1 lux and below (log in between)
	return clampf((3.0 - log(maxf(total, 1e-6)) / log(10.0)) / 3.0, 0.0, 1.0)

static func _key(lux: float) -> float:
	return 1.03 - 2.0 / (2.0 + log(0.18 * maxf(lux, 1e-6) / PI + 1.0) / log(10.0))

static func night_key_stops(total: float) -> float:
	## v26: compensation of a dark-adapted eye (Krawczyk, Myszkowski & Seidel 2005), never brighter than a camera
	return minf(log(maxf(_key(total), 1e-3) / 0.18) / log(2.0), 0.0)

static func _dawn_dim(total: float, noon_total: float, nw: float) -> float:
	## v93: twilight reads dimmer than noon by the night eye's key, never darker than the night eye at 1 lux
	if nw <= 0.0: return 0.0
	var t := minf(nw / 0.1, 1.0)
	var K := minf(log(maxf(_key(total), 1e-3) / _key(noon_total)) / log(2.0), 0.0) * t * t * (3.0 - 2.0 * t)
	var O := nw * (night_key_stops(total) + NIGHT_LIFT)
	var fl := night_key_stops(1.0) + NIGHT_LIFT
	return minf(minf(O, maxf(K, fl)) - O, 0.0)

static func to_godot(v: Vector3) -> Vector3:
	## an Unreal world direction (the clock's) in Godot's axes. Not (x, z, -y): that is the island frame's map, and it
	## showed the sky mirrored along Unreal's Y against the reefs (at noon_yaw 0 the sun set on the rising side).
	return Vector3(v.x, v.z, v.y)

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
	# shadow levers for benches (project.godot holds the defaults: 8192 map, soft filter high): AO_SHADOW_SIZE, AO_SHADOW_Q 0-5
	if OS.get_environment("AO_SHADOW_SIZE") != "": RenderingServer.directional_shadow_atlas_set_size(int(OS.get_environment("AO_SHADOW_SIZE")), true)
	if OS.get_environment("AO_SHADOW_Q") != "": RenderingServer.directional_soft_shadow_filter_set_quality(int(OS.get_environment("AO_SHADOW_Q")))
	add_child(light)
	caustics = CausticsMap.new(); add_child(caustics)
	env = Environment.new()
	var sky := Sky.new(); sky_mat = ShaderMaterial.new(); sky_mat.shader = load("res://look/sky.gdshader"); sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY; env.sky = sky; env.background_intensity = 1.0   # sky shader outputs nits
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true; env.ssao_radius = 1.2; env.ssao_intensity = 1.6
	env.ssil_enabled = true; env.ssil_radius = 4.0
	# GI (28 Nov, look thread): SDFGI on by default. Its escaping rays read the water's light field under water (look/sky.gdshader
	# under_*), so the fill is occluded by the real shapes (arch, table coral) and the sun's bounce off the sand comes for free.
	env.sdfgi_enabled = true
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.glow_enabled = true; env.glow_intensity = 0.3
	var we := WorldEnvironment.new(); we.environment = env; add_child(we)
	agx_fx = AgxEffect.new(); cortao_fx = CortaoEffect.new(); cortao_fx.enabled = false
	var comp := Compositor.new(); comp.compositor_effects = [cortao_fx, agx_fx]; we.compositor = comp
	set_agx(true)
	# bloom / vignette levers for benches and shots (any runner): AO_BLOOM (1 key frame, 0 off), AO_BLOOM_THR, AO_VIG
	if OS.get_environment("AO_BLOOM") != "": bloom = float(OS.get_environment("AO_BLOOM"))
	if OS.get_environment("AO_BLOOM_THR") != "": bloom_thr = float(OS.get_environment("AO_BLOOM_THR"))
	if OS.get_environment("AO_VIG") != "": vignette = float(OS.get_environment("AO_VIG"))
	cam_attr = CameraAttributesPhysical.new(); cam_attr.auto_exposure_enabled = false
	cam_attr.frustum_near = 0.02; cam_attr.frustum_far = 400.0

func set_ao(mode: String) -> void:
	## "ssao" = Godot's SSAO (the look until now), "cortao" = CORTAO (third_party/cortao) through look/screen_ao.gdshaderinc, "off" = none.
	## Both occlude only the ambient / GI fill (ao = min(ao, x)), never the sun. SSIL is separate and stays as it is.
	ao_mode = mode
	env.ssao_enabled = mode == "ssao"
	cortao_fx.enabled = mode == "cortao"
	RenderingServer.global_shader_parameter_set("cortao_on", 1.0 if mode == "cortao" else 0.0)

func set_agx(on: bool) -> void:
	## on: the Unreal AgX tonemapper (look/agx_post.glsl) replaces Godot's; LINEAR leaves only the sRGB encoding and
	## Godot's glow is off (its glow would land after our tone curve); our bloom (WorldRoot.bloom) runs inside the AgX pass.
	## off: Godot's built-in AgX with its glow, as before 27 Nov.
	agx_fx.enabled = on
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR if on else Environment.TONE_MAPPER_AGX
	env.glow_enabled = not on

func attach_camera(cam: Camera3D) -> void:
	## physical exposure on the camera, plus the water between the eye and every pixel (look/underwater_view)
	cam.attributes = cam_attr
	var q := MeshInstance3D.new(); q.name = "UnderwaterView"
	var qm := QuadMesh.new(); qm.size = Vector2(2, 2); q.mesh = qm
	var qmat := ShaderMaterial.new(); qmat.shader = load("res://look/underwater_view.gdshader"); q.material_override = qmat
	under_mat = qmat; qmat.set_shader_parameter("god_k", 1.0 if god_rays else 0.0)
	q.gi_mode = GeometryInstance3D.GI_MODE_DISABLED   # a screen pass, not a solid: never in SDFGI / VoxelGI
	q.extra_cull_margin = 16384.0; q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; q.layers = 1 << 3   # layer 4: the eye's own quads (the sea floor map's captures skip it)
	cam.add_child(q)
	if motes and get_node_or_null("Motes") == null: add_child(Motes.new())   # marine snow around the eye (adapters/godot/motes.gd)

func _process(_dt: float) -> void:
	## the god rays' start point moves on each frame only where TAA averages it (Unreal: StateFrameIndexMod8 under TSR);
	## without TAA it holds still, or the shafts would boil. A temporal upscaler (FSR 2, MetalFX temporal) averages frames as TAA does.
	if under_mat == null: return
	var vp := get_viewport()
	under_mat.set_shader_parameter("god_frame", float(Engine.get_frames_drawn() % 8) if vp and temporal(vp) else 0.0)

static func temporal(vp: Viewport) -> bool:
	## frames are averaged on this viewport (TAA, FSR 2 or MetalFX temporal), so per-frame noise may move on each frame
	var m := vp.scaling_3d_mode
	return vp.use_taa or (vp.scaling_3d_scale < 0.999 and (m == Viewport.SCALING_3D_MODE_FSR2 or m == Viewport.SCALING_3D_MODE_METALFX_TEMPORAL))

func set_fov(fov_deg: float) -> void:
	## CameraAttributesPhysical owns the field of view: Godot takes the vertical FOV from a 24 mm sensor height (12 mm
	## half), so the focal length for a vertical fov is 12 / tan(fov / 2). (Was 18: every shot was ~1.5x zoomed in.)
	cam_attr.frustum_focal_length = 12.0 / tan(deg_to_rad(fov_deg) * 0.5)

func make_surface(_size_m := 160.0) -> Node3D:
	## the drawn sea (adapters/godot/sea_surface.gd, water surface thread): the Unreal lagoon's FFT sea on camera-centred
	## rings, seen from above and below. Its level is water_y (the tide); nothing to place or stream.
	var s := SeaSurface.new()
	water.waves = s.fft            # water.water_y(x, z) follows the drawn crests
	_surface = s
	return s

func apply(cam_y: float) -> Dictionary:
	if is_instance_valid(_surface) and _surface.floor_map: _surface.floor_map.refresh()   # its radiance was lit by the old light
	if tide_on: water.set_clock(hours)   # the sea level follows the two moons (core/world/tide.gd)
	var water_y := water.level
	var st := SkyClock.overcast(SkyClock.sky_state(hours, noon_yaw), sky_overcast)
	state = st
	key = SkyClock.pick_key(st, key)
	var body: Dictionary = st[key]
	var fade := SkyClock.key_fade(st, key)
	var under := cam_y < water_y
	var up_air := to_godot(body.dir)
	var beam_h: float = SkyClock.beam_lux(body.elev) * (body.toa / SkyClock.STAR.toa_lux if key != "sun" else 1.0) * fade * float(st.oc_beam_k)
	var tint: Color = SkyClock.kelvin_rgb(body.kelvin) * air_tint(body.elev)
	if key != "sun": tint = tint * SkyClock.MOON_TINTS[key].lerp(Color(1, 1, 1), 0.5)
	# exposure: the eye's dark end slid with the light; steady under water; place compensation
	# sun_v184 exposure(): limits slid with the light; at night the eye opens to EV100 NIGHT_OPEN within the night
	# floor (NIGHT_SHUT), with the dark-adapted key (night_key_stops), the night lift and dawn_dim on the compensation.
	# Godot has no auto-exposure meter here, so the eye sits at the dark end clamped into Unreal's limits.
	var noon_total: float = SkyClock.sky_state(12.0)["total"]
	var dark := ev100(st.total) - (ev100(noon_total) - SkyClock.EV_MAX)
	var nw := night_weight(st.total)
	var hi := maxf(dark, NIGHT_FLOOR_EV + NIGHT_SHUT)
	var lo := minf(maxf(dark - BRIGHTEN_STOPS, NIGHT_FLOOR_EV + NIGHT_SHUT - BRIGHTEN_STOPS), hi)
	lo = minf(lo, lo + (NIGHT_FLOOR_EV + NIGHT_OPEN - lo) * nw)
	var ev := clampf(dark, lo, hi)
	if under: ev -= SkyClock.STEADY_UNDER_AT * (1.0 - nw)       # the steady under-water eye is a daytime rule (st_w)
	var bias: float = SkyClock.EXPOSURE_BIAS.get(place, 0.0)
	bias += nw * (night_key_stops(st.total) + NIGHT_LIFT)
	bias += _dawn_dim(st.total, noon_total, nw)
	if under: bias += under_exposure_art - NIGHT_EYE_UNDER * nw
	# EV100 = log2(N^2 / t) at ISO 100. f/22 keeps Godot's physical depth of field out of the way (deep focus).
	cam_attr.exposure_sensitivity = 100.0; cam_attr.exposure_aperture = 22.0
	cam_attr.exposure_shutter_speed = pow(2.0, ev) / (22.0 * 22.0)
	cam_attr.exposure_multiplier = pow(2.0, bias)
	exposure = pow(2.0, bias) / (1.2 * pow(2.0, ev))  # buffer units per nit (Godot's normalisation)
	env.sdfgi_energy = gi_k
	_push_water(water_y, up_air, beam_h, st.skylux)
	_push_sky(st)
	# the sea surface's sky and sun (look/sky_dome.gdshaderinc, look/sea_*.gdshader): the dome the sky draws, the key body
	var rsw := RenderingServer
	rsw.global_shader_parameter_set("water_dome_sun", sky_mat.get_shader_parameter("dome_sun"))
	rsw.global_shader_parameter_set("water_sky_norm", sky_mat.get_shader_parameter("sky_norm"))
	rsw.global_shader_parameter_set("sky_turbidity", turbidity)
	rsw.global_shader_parameter_set("sky_overcast", st.overcast)
	# the deck's zenith nits: its light on level ground (Lz x 7 pi / 9) is the clock's cloudy sky light, as the clear dome's is
	var oc_zenith := (float(st.skylux) - SkyClock.NIGHT_SKY_LUX) * 9.0 / (7.0 * PI)
	rsw.global_shader_parameter_set("sky_oc_zenith", oc_zenith)
	sky_mat.set_shader_parameter("sky_oc_beam", st.oc_beam_k)
	rsw.global_shader_parameter_set("sky_rayleigh", rayleigh)
	rsw.global_shader_parameter_set("sky_horizon_k", horizon_k)
	rsw.global_shader_parameter_set("water_sun_air", up_air)
	rsw.global_shader_parameter_set("water_sun_lux", beam_h / maxf(up_air.y, 0.02) if up_air.y > 0.0 else 0.0)
	if agx_fx.enabled:
		agx_fx.bloom = bloom; agx_fx.bloom_thr = bloom_thr; agx_fx.vignette = vignette
		agx_fx.exposure = exposure; agx_fx.buf_scale = exposure   # Godot's buffer arrives already exposed (measured 27 Nov)
		agx_fx.white_now = SkyClock.white_now(st)
		agx_fx.sun_dir = to_godot(st.sun.dir); agx_fx.under = under
		agx_fx.moon_a = _moon_view(st.A.dir, SkyClock.MOONS[0].drawn_deg)
		agx_fx.moon_b = _moon_view(st.B.dir, SkyClock.MOONS[1].drawn_deg)
		var kw := clampf((water_y - cam_y) / UNDER_WHITE_FADE_M, 0.0, 1.0)
		var dg: Vector3 = depth_gain(water_y - cam_y, depth_colour_share) if depth_colour else Vector3.ONE
		var uw: Vector3 = under_white if under_white != Vector3.ZERO else UNDER_WHITE.get(place, Vector3.ONE)
		agx_fx.depth_gain = dg * Vector3.ONE.lerp(uw, kw)
	var op := WaterOptics.optics(cdom, scat_k, water_type)
	var a: Vector3 = op.a; var b: Vector3 = op.b; var bbv: Vector3 = op.bb
	# the water's light field at z_ref (sky from above, the sand's bounce from below): the lagoon's GI content is under water
	# whatever the eye, so the GI's sky (look/sky.gdshader under_*, cubemap passes only) is this field above water too
	var tr := WaterOptics.refract_sun(up_air)
	var kd: Vector3 = _art_k((a + bbv) / tr.y)
	var att := Color(exp(-kd.x * z_ref), exp(-kd.y * z_ref), exp(-kd.z * z_ref))
	var ku: Vector3 = _art_k((a + bbv) / 0.75)
	var ek: Vector3 = Vector3(exp(-ku.x * z_ref), exp(-ku.y * z_ref), exp(-ku.z * z_ref)) * st.skylux * WaterOptics.FRESNEL_SKY * sky_fill_k
	# + the sand's bounce from below (Lighting's sand bounce: the lower hemisphere lit by the sand), half the sphere each
	var H := water_y - floor_y
	var eh: Vector3 = (Vector3(exp(-kd.x * H), exp(-kd.y * H), exp(-kd.z * H)) * beam_h * WaterOptics.FRESNEL_SUN
		+ Vector3(exp(-ku.x * H), exp(-ku.y * H), exp(-ku.z * H)) * st.skylux * WaterOptics.FRESNEL_SKY * sky_fill_k)
	var sand := Vector3(WaterOptics.SAND.r, WaterOptics.SAND.g, WaterOptics.SAND.b)
	var eu: Vector3 = eh * sand * Vector3(exp(-ku.x * (H - z_ref)), exp(-ku.y * (H - z_ref)), exp(-ku.z * (H - z_ref)))
	sky_mat.set_shader_parameter("under_k", 1.0)
	sky_mat.set_shader_parameter("under_down", ek / PI)
	sky_mat.set_shader_parameter("under_up", eu / PI)
	# CORTAO light-weighted occlusion: each open ray counts by the field's luminance from its direction (the GI's own two halves)
	var lum := func(v: Vector3) -> float: return v.dot(Vector3(0.2126, 0.7152, 0.0722))
	cortao_fx.light_down = lum.call(ek); cortao_fx.light_up = lum.call(eu)
	var amb_sky := env.sdfgi_enabled or _gi_reset > 0
	RenderingServer.global_shader_parameter_set("water_amb_sky", 1.0 if amb_sky else 0.0)
	var floor_amb := ek / PI      # the ambient the floor's shaders divide their fill by (water_physics w_fill_ratio), floor facing up
	if under:
		light.look_at_from_position(Vector3.ZERO, -tr, Vector3.FORWARD if absf(tr.y) > 0.99 else Vector3.UP)
		light.light_intensity_lux = beam_h * WaterOptics.FRESNEL_SUN / tr.y
		light.light_color = (tint * att)
		light.light_indirect_energy = 1.0
		# the sun as seen from under a wavy surface: its disc refracted (0.53 / 1.333 deg) widened by the waves' slope, each
		# facet bending the beam by (1 - 1/1.333) x its slope: so shadows are crisp at contact and soften with height
		light.light_angular_distance = SUN_DISC_DEG / WaterOptics.N_WATER + 2.0 * (1.0 - 1.0 / WaterOptics.N_WATER) * sea_rms_slope * 57.2958
		# Without GI, the ambient stays one colour (the field's mean); Godot's sky-sourced ambient read black in the 28 Nov
		# check (cubemap ambient path, open question), and SDFGI replaces the ambient anyway.
		var amb: Vector3 = (ek + eu) * 0.5 / PI * exposure            # ambient is in buffer units (measured 27 Nov)
		var mx := maxf(amb.x, maxf(amb.y, amb.z))
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(amb.x / mx, amb.y / mx, amb.z / mx) if mx > 0.0 else Color.BLACK
		env.ambient_light_energy = mx
		RenderingServer.global_shader_parameter_set("water_amb_ref", amb / maxf(exposure, 1e-12))
		if not amb_sky: floor_amb = amb / maxf(exposure, 1e-12)
	else:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		var dz := dome(Vector3.UP, _dome_sun)
		dz = (dz / maxf(dz.dot(Vector3(0.2126, 0.7152, 0.0722)), 1e-12)).lerp(Vector3.ONE, float(st.overcast))   # the deck is grey
		var dm := maxf(dz.x, maxf(dz.y, dz.z))
		env.ambient_light_color = Color(dz.x / dm, dz.y / dm, dz.z / dm) if dm > 0.0 else Color.WHITE
		env.ambient_light_energy = st.skylux / PI * exposure
		var ac: Color = env.ambient_light_color * (st.skylux / PI)
		RenderingServer.global_shader_parameter_set("water_amb_ref", Vector3(ac.r, ac.g, ac.b))
		if not amb_sky: floor_amb = Vector3(ac.r, ac.g, ac.b)
		light.look_at_from_position(Vector3.ZERO, -up_air, Vector3.FORWARD if absf(up_air.y) > 0.99 else Vector3.UP)
		light.light_intensity_lux = beam_h / maxf(up_air.y, 0.02)
		light.light_color = tint
		light.light_angular_distance = SUN_DISC_DEG
		# the GI's sand is under water: its bounce sees the sun as it arrives at z_ref (through the surface, refracted, attenuated),
		# not the air's full beam (Godot's indirect energy is one scalar: the luminance of that loss)
		var lum_att := att.r * 0.2126 + att.g * 0.7152 + att.b * 0.0722
		light.light_indirect_energy = WaterOptics.FRESNEL_SUN * maxf(up_air.y, 0.02) / tr.y * lum_att
	# the sea floor map's capture has no sky and no GI, so its floor lost the water's fill (sky through the surface + sand
	# bounce) and the mirror under the surface read navy (Gary's T1 shot, 28 Nov): give its capture the same ambient
	if is_instance_valid(_surface) and _surface.floor_map: _surface.floor_map.set_ambient(floor_amb)
	# SDFGI keeps its probes' light over many frames: after a jump in the light (the hour slider, a teleport across day and night)
	# that cache is the old light, shown at the new exposure (surface thread, 28 Nov: noon-lit sand blown out at 23:00).
	# A jump of more than SDFGI_RESET_STOPS in EV100 drops the cache: GI off until two frames have been drawn without it, then
	# on again, rebuilt from the new light (Godot has no reset call; a toggle inside one frame is never drawn and changes nothing).
	if env.sdfgi_enabled and last.has("ev100") and absf(ev - float(last.ev100)) > SDFGI_RESET_STOPS:
		env.sdfgi_enabled = false; _gi_reset = 2
		if not RenderingServer.frame_post_draw.is_connected(_gi_reset_tick): RenderingServer.frame_post_draw.connect(_gi_reset_tick)
	last = {"key": key, "elev": body.elev, "total_lux": st.total, "sky_lux": st.skylux, "beam_h": beam_h,
		"ev100": ev, "bias": bias, "under": under, "night_w": nw, "overcast": st.overcast, "beam_k": st.oc_beam_k, "oc_zenith": oc_zenith}
	return last

var sdfgi_wanted := true    # the user's SDFGI switch (test level): a GI reset in flight turns it back on only if wanted

func _gi_reset_tick() -> void:
	_gi_reset -= 1
	if _gi_reset <= 0:
		RenderingServer.frame_post_draw.disconnect(_gi_reset_tick); env.sdfgi_enabled = sdfgi_wanted

func _art_k(k: Vector3) -> Vector3:
	## light_neutral: the light's per-band loss pulled toward its luminance-weighted mean (colour only)
	var m := k.dot(Vector3(0.2126, 0.7152, 0.0722))
	return k.lerp(Vector3(m, m, m), clampf(light_neutral, 0.0, 1.0))

static func _moon_view(d: Vector3, drawn_deg: float) -> Vector4:
	var g := to_godot(d)
	return Vector4(g.x, g.y, g.z, deg_to_rad(drawn_deg) * 0.5)

# ---- water uniforms (shared by every water-aware shader: look/water_physics.gdshaderinc) ----

static func declare_globals() -> void:
	## global uniforms must exist before shaders compile (headless scripts can't rely on project.godot entries)
	FftSea.declare_globals()        # sea_open_gain / sea_open_teal (the abyss, water_physics w_deep)
	SeaFloorMap.declare_globals()   # the underwater view reads the floor map (is there a floor under this ray: lagoon or abyss)
	if Engine.has_meta("water_globals"): return
	var F := RenderingServer.GLOBAL_VAR_TYPE_FLOAT; var V := RenderingServer.GLOBAL_VAR_TYPE_VEC3
	var defs := {"water_y": [F, LagoonWaterField.SURFACE_Y], "water_floor_y": [F, 0.0],
		"water_a": [V, Vector3.ZERO], "water_b": [V, Vector3.ZERO], "water_kd": [V, Vector3.ZERO], "water_ku": [V, Vector3.ZERO],
		"water_sun_w": [V, Vector3.UP], "water_es0": [F, 0.0], "water_ek0": [F, 0.0], "water_exposure": [F, 1.0],
		"water_glow_k": [F, 1.0], "water_glow_ms": [F, 1.0], "water_bathy": [RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4.ZERO], "water_ocean_depth": [F, 1000.0], "water_far_sand": [V, Vector3(0.82, 0.68, 0.44)], "water_zref": [F, 2.0], "water_sky_nits": [F, 0.0], "water_rrs": [V, Vector3.ZERO], "water_rrs_deep": [V, Vector3.ZERO],
		"water_sand": [RenderingServer.GLOBAL_VAR_TYPE_COLOR, Color.WHITE],
		# the light net (look/caustics.gdshaderinc): its map, and x 1 = read the map / 0 = per pixel, y the net's time (-1 = TIME)
		"water_caus_map": [RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, RID()],
		"water_caus_k": [RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0.0, -1.0, 0.0, 0.0)],
		# the sea surface (water surface thread): the sky dome's shape sun and scale, the key body in air and its beam lux
		"water_amb_ref": [V, Vector3.ONE], "water_fill_ao": [F, 1.0], "water_amb_sky": [F, 0.0],
		"water_dome_sun": [V, Vector3.UP], "water_sky_norm": [F, 0.0], "sky_turbidity": [F, turbidity], "sky_overcast": [F, 0.0], "sky_oc_zenith": [F, 0.0], "sky_rayleigh": [V, rayleigh], "sky_horizon_k": [F, horizon_k], "water_sun_air": [V, Vector3.UP], "water_sun_lux": [F, 0.0],
		# CORTAO screen AO (look/screen_ao.gdshaderinc): the result texture and 1 = on
		"cortao_ao": [RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, RID()], "cortao_on": [F, 0.0]}
	for k in defs:
		RenderingServer.global_shader_parameter_add(k, defs[k][0], defs[k][1])
	Engine.set_meta("water_globals", true)

func _sea_deep_rrs() -> Vector3:
	## the open ocean's Rrs with look/sea_top's open-water art levers (FftSea's sea_open_gain / sea_open_teal, same env),
	## so the far sea in the sky dome meets the drawn sea at the far plane
	var gain := float(OS.get_environment("AO_OPEN_GAIN")) if OS.get_environment("AO_OPEN_GAIN") != "" else 2.0
	var teal := float(OS.get_environment("AO_OPEN_TEAL")) if OS.get_environment("AO_OPEN_TEAL") != "" else 0.5
	var r: Vector3 = WaterOptics.OCEAN.rrs
	return r.lerp(r.z * Vector3(0.03, 0.55, 1.0), teal) * gain

func _push_water(water_y: float, sun_up_air: Vector3, beam_h_lux: float, sky_lux: float) -> void:
	var op := WaterOptics.optics(cdom, scat_k, water_type)
	var a: Vector3 = op.a; var b: Vector3 = op.b; var bbv: Vector3 = op.bb
	var tr := WaterOptics.refract_sun(sun_up_air)
	var rs := RenderingServer
	rs.global_shader_parameter_set("water_y", water_y)
	rs.global_shader_parameter_set("water_floor_y", floor_y)
	rs.global_shader_parameter_set("water_a", a)
	rs.global_shader_parameter_set("water_b", b)
	rs.global_shader_parameter_set("water_kd", _art_k((a + bbv) / tr.y))
	rs.global_shader_parameter_set("water_ku", _art_k((a + bbv) / 0.75))
	rs.global_shader_parameter_set("water_rrs", op.rrs)   # the deep water's own colour (look/sea_top: Rrs x Ed where the floor fades)
	rs.global_shader_parameter_set("water_sun_w", tr)
	rs.global_shader_parameter_set("water_es0", beam_h_lux * WaterOptics.FRESNEL_SUN)   # horizontal lux of the sun just under
	rs.global_shader_parameter_set("water_ek0", sky_lux * WaterOptics.FRESNEL_SKY * sky_fill_k)      # horizontal lux of the sky just under
	rs.global_shader_parameter_set("water_exposure", exposure)
	rs.global_shader_parameter_set("water_glow_k", glow_k)
	rs.global_shader_parameter_set("water_glow_ms", glow_ms)
	rs.global_shader_parameter_set("water_bathy", Vector4(lagoon_centre.x, lagoon_centre.y, lagoon_radius, deg_to_rad(reef_sector_deg)))
	rs.global_shader_parameter_set("water_rrs_deep", WaterOptics.OCEAN.rrs)   # the open ocean's own colour past the reef (look/sea_top)
	rs.global_shader_parameter_set("water_ocean_depth", ocean_depth)
	rs.global_shader_parameter_set("water_far_sand", FAR_SAND)
	rs.global_shader_parameter_set("water_fill_ao", 1.0 if fill_occluded else 0.0)
	rs.global_shader_parameter_set("water_sand", WaterOptics.SAND)
	rs.global_shader_parameter_set("water_sky_nits", sky_lux / PI)   # clear sky as a uniform dome (stand-in for the surface)
	rs.global_shader_parameter_set("water_zref", z_ref)

# ---- sky (look/sky.gdshader): dome scaled so its light on level ground equals the clock's sky_lux ----

static func _airmass(y: float) -> float:
	var yy := clampf(y, 0.0, 1.0)
	return 1.0 / (yy + 0.50572 * pow(rad_to_deg(asin(yy)) + 6.07995, -1.6364))

# The dome's air (28 Nov, water surface thread, Gary: "horizon seems off, very grey"): Godot's PhysicalSkyMaterial defaults
# drew a grey sky: turbidity 10 is a hazy inland sky, and its Rayleigh colour (0.3, 0.405, 0.6) is far less blue than
# lambda^-4 scattering (680/550/440 nm: 0.105, 0.246, 0.6). Clean tropical sea air (aerosol depth 0.05-0.1) is about
# turbidity 2.5. Pushed as sky_turbidity / sky_rayleigh. AO_TURB, AO_RAY=0 (Godot's colour) for checks.
static var turbidity := float(OS.get_environment("AO_TURB")) if OS.get_environment("AO_TURB") != "" else 2.5
static var horizon_k := float(OS.get_environment("AO_HORIZON_K")) if OS.get_environment("AO_HORIZON_K") != "" else 1.0   # look/sky_dome sky_horizon_ms
static var rayleigh := Vector3(0.3, 0.405, 0.6) if OS.get_environment("AO_RAY") == "0" else Vector3(0.105, 0.246, 0.6)

static func dome(v: Vector3, s: Vector3) -> Vector3:
	## mirror of sky.gdshader dome(): Godot's PhysicalSkyMaterial shape at its defaults (turbidity: sky_turbidity)
	var za := clampf(s.y, -1.0, 1.0)
	var sun_energy := maxf(0.0, 1.0 - exp(-((PI * 0.5) - acos(za))))
	var sun_fade := 1.0 - clampf(1.0 - exp(s.y), 0.0, 1.0)
	var rb := (2.0 - (1.0 - sun_fade)) * rayleigh * 0.0001
	var mb := turbidity * 0.005 * Vector3(0.69, 0.729, 0.812) * 0.000434
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
	# sky_horizon_ms (look/sky_dome.gdshaderinc): the horizon pulled to pale blue at its luminance, lifted x2.5 (HZ_LIFT)
	var Y := 0.2126 * out.x + 0.7152 * out.y + 0.0722 * out.z
	var w := clampf(horizon_k * exp(-maxf(v.y, 0.0) / 0.12), 0.0, 1.0)
	return out.lerp(Y * Vector3(0.785, 1.038, 1.269) * 2.5, w)

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
	mat.set_shader_parameter("moon_a_kelvin", SkyClock.MOONS[0].kelvin)
	mat.set_shader_parameter("moon_b_kelvin", SkyClock.MOONS[1].kelvin)
	for n in ["A", "B"]:   # MI_MoonA/B MoonTint: MOON_TINTS mixed by moon_tint_mix around luminance 1 (v83)
		var mt: Color = SkyClock.MOON_TINTS[n]; var tmix: float = SkyClock.MOON_LOOK.moon_tint_mix
		var ty := 0.2126 * mt.r + 0.7152 * mt.g + 0.0722 * mt.b
		mat.set_shader_parameter("moon_%s_night" % n.to_lower(), Vector3(1.0 + tmix * (mt.r / ty - 1.0),
			1.0 + tmix * (mt.g / ty - 1.0), 1.0 + tmix * (mt.b / ty - 1.0)))
	mat.set_shader_parameter("moon_cap", SkyClock.MOON_LOOK.moon_cap)
	mat.set_shader_parameter("moon_blue", SkyClock.MOON_LOOK.moon_blue)
	mat.set_shader_parameter("moon_sat", SkyClock.MOON_LOOK.moon_sat)
	mat.set_shader_parameter("maria", SkyClock.MOON_LOOK.maria)
	mat.set_shader_parameter("planetshine", SkyClock.MOON_LOOK.planetshine)
	mat.set_shader_parameter("moon_edge", SkyClock.MOON_LOOK.moon_edge)
	# Godot's dome shape is black once the sun is down, while Unreal's SkyAtmosphere kept the twilight glow: until that
	# is ported, the shape uses the sun held at 1 deg up (glow on the sun's side, blue overhead), scaled to the clock's
	# twilight sky_lux (TWILIGHT table), so the brightness stays the clock's.
	var lift := sin(deg_to_rad(1.0))
	var ds := s
	if s.y < lift:
		var hz := Vector3(s.x, 0.0, s.z).normalized() if Vector2(s.x, s.z).length() > 1e-6 else Vector3.FORWARD
		ds = (hz * cos(deg_to_rad(1.0)) + Vector3.UP * lift).normalized()
	mat.set_shader_parameter("dome_sun", ds)
	if not ds.is_equal_approx(_dome_sun):     # the dome integral only changes with the sun
		_dome_sun = ds; _dome_g = ground_lux_of_dome(ds)
	mat.set_shader_parameter("sky_norm", (st.skylux - SkyClock.NIGHT_SKY_LUX) / _dome_g if _dome_g > 1e-12 else 0.0)
	mat.set_shader_parameter("sea_nits", SkyClock.OCEAN_ALBEDO * st.total / PI)
	mat.set_shader_parameter("sea_deep_nits", _sea_deep_rrs() * st.total / 0.98)   # look/sky: the far sea past the far plane
	# night sky (look/sky_stars.gdshaderinc, Unreal M_Stars): what the Unreal clock wrote to MPC_Sky and the Stars actor
	if mat.get_shader_parameter("star_cat") == null:
		mat.set_shader_parameter("star_cat", StarCatalogue.texture())
	var north: Vector3 = st.frame[1]                       # the sky turns about the planet's axis once a day (z-up, as the clock)
	# Gary 27 Nov 17:44Z: the stars turn WITH the sun (Unreal turned the actor by +2 pi (days - 0.5), against the sun,
	# though its comment said "with the sun"); the midnight sky is the same either way, only the motion's sense changes
	var turn: float = -deg_to_rad(fmod(rad_to_deg(TAU * (float(st.days) - 0.5)), 360.0))
	mat.set_shader_parameter("star_spin", Vector4(north.x, north.y, north.z, turn))
	var glow: float = st.eclipse.glow
	mat.set_shader_parameter("stars_on", 1.0 if (float(st.total) < 50.0 or glow > 0.0) else 0.0)   # STARS_BELOW_LUX
	var ra: float = SkyClock.MOONS[0].drawn_deg; var rb: float = SkyClock.MOONS[1].drawn_deg
	mat.set_shader_parameter("moon_a_r", deg_to_rad(ra * 0.5) if float(st.A.elev) > -(ra * 0.5 + 0.5) else 0.0)   # MoonAView.w
	mat.set_shader_parameter("moon_b_r", deg_to_rad(rb * 0.5) if float(st.B.elev) > -(rb * 0.5 + 0.5) else 0.0)
	mat.set_shader_parameter("star_expo", exposure)        # Unreal's EyeAdaptation: exposed units per nit
	mat.set_shader_parameter("site_lux", float(st.total))
	mat.set_shader_parameter("eclipse_glow", glow)
	var key_k: float = st[key].kelvin if key != "" else SkyClock.STAR.kelvin
	mat.set_shader_parameter("key_kelvin", key_k)
	# the stars are aimed through AgX's night darkening (NightSky, NightDeep); without that AgX they keep their own light
	mat.set_shader_parameter("night_sky", agx_fx.night_sky if agx_fx.enabled else 0.0)
	mat.set_shader_parameter("deep_comp", agx_fx.night_deep if agx_fx.enabled else 0.0)
