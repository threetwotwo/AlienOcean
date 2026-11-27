# Changelog (Semantic Versioning; Unreal era filed as 0.1-0.5, Godot work starts at 0.6.0, 1.0.0 = first playable slice)

## 0.6.0-dev (28 Nov 2026, look thread): GI on by default, lit by the water's own light
- Root cause of the black fish under SDFGI: Godot's SDFGI ignores the environment's ambient colour; its escaping rays read the
  sky's radiance cubemap, which was the air above the water. Fix: under water, the sky shader's cubemap passes
  (look/sky.gdshader under_*, AT_CUBEMAP_PASS) draw the water's light field at z_ref: upper hemisphere Ek/pi (the sky's light
  through the water), lower hemisphere Eu/pi (the sand's bounce). Its irradiance on any normal is exactly w_fill(z_ref, up).
  Check (sun off, key frame camera): open sand L* 49.6 with SDFGI against 48.2 from the analytic fill. The fish is lit and shaded.
- SDFGI on by default (WorldRoot); AO_SDFGI=0 turns it off. The sea mesh, the underwater screen quad and the floor height pass
  are kept out of the GI (gi_mode disabled): they are light boundaries and screen passes, not solids.
- With SDFGI on, the seabed's albedo ratio is only the depth's own change (w_fill(z)/w_fill(z_ref), near 1): Godot's sky light
  is one field for the scene, with no water between it and a point off z_ref (stand-in for per-probe water depth; owner look thread).
- Art lever WorldRoot.gi_k (SDFGI energy, AO_GI_K): 1 = physical. Key frame camera, coral shadow / rock face / sunlit sand L*:
  GI off 50.2 / 48.5 / 74.8; gi_k 1.0 54.1 / 51.2 / 75.7 (the sand's real bounce lifts the shadows); 0.5 47.1 / 47.2 / 74.0;
  0.35 44.3 / 45.8 / 73.4 (key frame 43.8 / 41-43 / 78). Gary picks.
- Godot's sky-sourced ambient (no GI) read black in the same check, so without GI the ambient stays one colour as before.
- Test: tests/test_gi_light_field.gd (in run_all.sh) with a planted fault. Shot tool checks: AO_SDFGI_SKY, AO_SDFGI_OCC,
  AO_SDFGI_CELL, AO_SDFGI_BOUNCE, AO_SUN=0, AO_SKY_MODE, AO_GI_DEBUG. Occlusion and 0.1 m cells changed the shadow by <3 L*.
- Mac M1 cost of SDFGI not measured yet (Mac runs paused).

## 0.6.0-dev (28 Nov 2026): the water's fill light can be occluded
- Engine: seabed_surface and ground_surface no longer add the water's fill (sky from above, sand bounce from below, through
  the depth) as unoccluded emission. It now goes through Godot's ambient path, so SSAO, SSIL, the material AO and any GI
  occlude and bounce it. Godot's ambient is one colour, so each pixel's fill colour and depth ride in ALBEDO as a ratio
  (`w_fill_ratio`, water_physics.gdshaderinc) and light() divides it back out. The sun and the light net are unchanged.
  Calibrated with SSAO and SSIL off: the same picture as before (mean 0.65 of 255). Key frame camera, SSAO + SSIL: coral
  shadow L* 52.9 -> 50.2, rock face 50.4 -> 48.5 (key frame 43.8 / 42.9). Switch: WorldRoot.fill_occluded (AO_FILL_AO=0).
- Art levers (real water conditions, defaults unchanged): WorldRoot.cdom (yellow substance, 0.03) and scat_k (particles,
  0.40); shot tool AO_CDOM / AO_SCAT. Far water hue at Cdom 0.03 / 0.01 / 0: -141 / -125 / -117 (key frame -132).
- Shot tool checks: AO_SSAO=0, AO_SSIL=0, AO_SSAO_R + AO_SSAO_I, AO_SDFGI=1. SDFGI on (not default yet) gives coral
  shadow 45.4 and rock face 42.7 (key frame 43.8 / 42.9), but the hero fish goes black and the coral's shadow stripes;
  both to fix before it becomes the default.

## 0.6.0-dev (28 Nov 2026, later): the light net from the FFT sea's own slopes
- Engine: caustics map 0.2.0 (`look/caustics_slope.gdshader`, `adapters/godot/caustics_map.gd`). While the FFT sea
  runs (global sea_on) the map's slope pass reads the sea's slope atlas (sea_deriv.rg), as v98's CAUS_SLOPE_HLSL read
  RT_LW_Deriv, so the net on the sand is drawn from the waves drawn overhead. Cascade 2 (sea_patch.z 2.56 m) is the
  map's tile one to one (same island xy / patch); cascade 3 (sea_patch.w 0.32 m) repeats 8 times over it (v98 Fine 1).
  Each depth takes the wrap-averaged mip whose texel is its own (2 / 4 / 8 cm: cascade 2 mips 1 / 2 / 3, cascade 3
  mips 4 / 5 / 6), read at texel centres: v98's 16-tap mean and halvings, exactly. Focus, sun's disc, reader and tile
  break unchanged. Without the sea, or with `WorldRoot.caustics.from_sea = false` (shot tool AO_CAUS=waves), the 32
  waves as before. The per-pixel check path stays on the 32 waves, so it no longer matches the map while the sea runs.
- Measured on the engine's map (two sea times), std at 0.8 / 2 / 5 m: 0.15 / 0.31 / 0.35-0.37 (v98 emulated
  0.14-0.15 / 0.29-0.31 / 0.34; the 32 waves 0.14 / 0.30 / 0.30); cell 12-14 / 13-14 / 16 cm (v98 12 / 12-14 / 15-16).
  Frame (llvmpipe, 960 x 540, shots 01 / 04): 761 / 1019 ms from the sea, 807 / 1002 ms from the 32 waves: no
  difference beyond the noise. Shot tool: AO_CAUS_T now holds the sea at that second too. test_world_clock 42 / 42.

## 0.6.0-dev (28 Nov 2026): the arch's foot and round 6 of the lagoon dressing
- World: the focal arch head (heads_v18c) now stands on its own fallen rock: `SB_Bommie_0_v18c_apron` = Terrain's gate fall
  (`seabed/tools/gate_fall.py` v3, grown from the head's own `handoff_terrain.json` fall record: 14 slab blocks 0.2-0.75 m at both
  mouths, roof and wear chips; flat seat, local wave bearing 40 as the key frame rig's arch_seat_v18c_r5_w40) plus the
  `rubble_rule.py` v11 apron round its real outline. Blocks carry one convex hull each, chips one concave mesh. Painted with the
  kit's own age ramp (reef_rock_rgb): the rig's KF_Rock put the sand film over whole low blocks.
- World: meadow tiles culled at export by the key frame rig's `habitat.cull_meadow` for this layout (grazing halo round heads and
  corals, upstream scour, open lanes; whole blades). Second head to (9.5, 18) (water gap), staghorn to (0.45, 5.6). Paint: rock
  walls x0.90 value and x0.80 chroma, table rim #f2a99c. Manifest 0.5.0.
- Fable critique r6: FAIL overall, foreground group now matches; next: rounded buttress boulders at the camera-facing foot,
  second head nearer and larger in frame, school + hero fish material (other threads), uniform salmon table.

## 0.6.0-dev (28 Nov 2026): one sky dome
- Engine: look/sky.gdshader takes its dome from look/sky_dome.gdshaderinc (the water surface's copy), so the sky overhead
  and the sky in the water can't drift apart. The old look/water_surface.gdshader is removed (SeaSurface replaced it,
  PR #37). Shot tool: the sea is pinned at its mean level by default (WorldRoot.tide_on false); AO_TIDE=1 follows the moons.

## 0.6.0-dev (28 Nov 2026): the Unreal god rays
- Engine: god rays 0.1.0 (`look/god_rays.gdshaderinc`, drawn by underwater view 0.2.0): the lagoon's light shafts as
  they ran at lagoonwater v98 (GodPhys 1, GodUnits 1, GodPick 1). Source: the god-ray node as built
  (lw/lagoonwater/logs/god_code_v53.txt) plus v98's GOD_FFT (3328-3353), tb_weights_cached (2592-2612), GOD_NEW_ADD
  (3374), GOD_RET_NEW (2013) and PHYS_CODE's shaft lines (2539-2547). Along each view ray: 20 jittered steps over
  min(path, 25 m) (a = 3 / Visibility 15 m); each step reads `water_caus_map` where its sunlight came through the
  surface, in one of the three tile-break copies picked by its weight, mixes the map's three depths by the step's
  depth and adds exp(-a s) x step x (c - 1). The shafts are the sun's in-scatter per metre (b x the sun at the eye's
  depth x the g 0.9 phase) x that sum, gaps never below -0.9 of the sun's haze. Same map, same entry point and same
  copy weights as the sand's net, so a shaft ends on its line on the sand. GlowK does not scale them (as Unreal).
  Switch: `WorldRoot.god_rays`, shot tool AO_GOD=0. Off with the net's per-pixel check path (no map).
- Not ported (dead at v98): the old painted path (GodPhys 0: WaterColour, ShaftStrength, shadow mask), GodLod, the
  three-read path, sub-bands. Not known for sure: ShaftSteps (v98's note says a 20-step ray, v30's says 12; 20 used)
  and Visibility (15 m in the 6 Nov colour check).
- Check (`tools/god_rays_check.gd` + `.py`, a numpy emulation of the Unreal node on the engine's map): the shader's
  sum against it, hour 12 and 17: rms 0.0016 m on a sum of std 0.51 / 0.62 m, correlation 1.0000.
- Open: Unreal moved the jitter each frame and let TSR average it. This project has no TAA, so the start point is
  held (WorldRoot sets `god_frame` only when the viewport uses TAA) and one frame keeps the dither: the sum's noise
  is std 0.47-0.57 m against 0.19-0.23 m for an 8-frame mean. The shot tool's AO_TAA=1 turns Godot's TAA on, which
  averages it (checked on shot 03, hour 17); whether the game runs TAA is still open. On screen the shafts are faint, as the maths gives:
  noon shots 02 / 03 / 04 change by at most 4-5 of 255 (the sun is outside the frame); shot 03 at hour 17, with the
  sun in view, p1-p99 -4..+4 and up to 16 of 255, a fan of shafts round the sun.
- Measured (llvmpipe, 960 x 540, ms a frame, without / with): shot 02 543 / 638, 03 254 / 377, 04 739 / 846, 03 at
  hour 17 287 / 317.

## 0.6.0-dev (28 Nov 2026): the stars turn with the sun
- Engine: the star sphere now turns about north by -2 pi (days - 0.5), so the stars rise and set on the same side as
  the sun and the moons. Unreal's Stars actor turned the other way (sun_v184 apply_fast, though its comment said "with
  the sun"); Gary picked "Turn with the sun (fix)" 27 Nov 17:44Z. The midnight sky is unchanged; only the sense of the
  motion changes.
## 0.6.0-dev (28 Nov 2026): the lagoon dressed like the key frame (world_dress)
- World: an authored place, `world_dress/lagoon_keyframe.json`, built by `world_dress/dress_cell.gd` (DressCell): the approved
  key frame's content ported, not rebuilt. Rock's heads_v18c arch (Gary's pick) as the focal head at 13 m with its gate facing the
  key camera, reef kit v18 heads b2 and b4 with their sand skirts, the five colony corals (table, brain, boulder, staghorn, finger),
  and the colony maker's grown meadow bed. Every piece carries collision from its maker (kit UCX hulls, CoACD hulls for v18c and
  the corals, concave sand skirts, grass as soft Area3D); every item is ray-seated on the floor; a keep-clear volume holds the fish
  school's space and is checked against the real hulls. Pieces: `tools/lagoon_dress/export_pieces.py` with the key frame's
  material family baked per vertex (`kf_paint.py`; rock top chroma x0.5 and walls x0.82 for the Godot water, art direction).
- Tools: `tools/lagoon_shots.gd` takes AO_DRESS / AO_DRESS_PIECES (the place's cameras become shots 09+). Test:
  `tests/test_dress_cell.gd` (collision, seating, school space, axis map; planted fault caught).

## 0.6.0-dev (28 Nov 2026): the camera's field of view
- Engine: WorldRoot.set_fov used an 18 mm half sensor, but Godot's CameraAttributesPhysical takes the vertical FOV from
  a 24 mm sensor height (12 mm half), so asking for 44 deg gave 30.15 deg: every shot was about 1.5x zoomed in. Now
  12 / tan(fov / 2); checked headless, cam.fov reads 44.0 for 44 and 60.0 for 60. Brightness is unchanged (f/22, the
  same shutter); only the framing widens. Found by the lagoon dressing thread.

## 0.6.0-dev (28 Nov 2026): the sky's handedness
- Engine: WorldRoot.to_godot is now Unreal (x, y, z) -> Godot (x, z, y) (was (x, z, -y), the island frame's map), and
  sky_stars s_zup is its inverse. Evidence: the lagoon GLBs are written (x, z, -y) from island metres, and Unreal
  holds them at X = x, Y = -y (slice_common.py write_glb, manifest `axes`, check P4 in Unreal), so Unreal = (g.x, g.z,
  g.y). Before, the sun's path, the moons and the star figures were mirrored along Unreal's Y (Godot z) against the
  reefs: at noon_yaw 0 that is the rise-set line, so the sun now sets toward Godot -z (was +z) and rises at +z; its
  lean toward the noon side (Godot -x) is as before.
  Unchanged on purpose: the stars turn about north by +2 pi (days - 0.5) as Unreal's Stars actor did, which is against
  the sun (in Unreal too; sun_v184 apply_fast). Still Godot's own, not Unreal's: the moon faces' and the corona
  streaks' roll (built on Godot axes in sky.gdshader).

## 0.6.0-dev (28 Nov 2026): the light net from a map, once a frame
- Engine: caustics map 0.1.0 (`adapters/godot/caustics_map.gd`, WorldRoot.caustics; `look/caustics_slope`, `_focus`,
  `_blur.gdshader`): lagoonwater v98's route. Each frame the net is drawn once into a 512 px tile of 2.56 m
  (r g b = 0.8 / 2 / 5 m) in v98's three passes: the slopes in each depth's mip (128 / 64 / 32 px), CAUS_HLSL, the
  sun's disc (8 ring taps and the centre). seabed_surface and ground_surface read it through the global sampler
  `water_caus_map` as v98's light function did: at the sunlight's entry point, three turned copies of the tile (tile
  break, 7 m patches), four taps over the pixel past 1 cm. caustics 0.2.0 (`look/caustics.gdshaderinc`) keeps the
  per-pixel maths as the check path (`WorldRoot.caustics.per_pixel`, shot tool AO_CAUS=pixel; also what a scene
  without the map node gets); `frozen_time` / AO_CAUS_T holds the net still for comparisons.
- The 32 waves now sit on the tile (each moved to the nearest whole wave, its slope kept; 8.8 to 23.3 rad/m) and
  live in `look/caustic_waves.gdshaderinc` (generated; CAUS_K and the new CAUS_A height amplitudes are there for
  the surface). Offline, map / per pixel / v98: std at 0.8, 2, 5 m 0.15 / 0.32 / 0.31, 0.15 / 0.32 / 0.30,
  0.14-0.15 / 0.29-0.31 / 0.34. The engine's map against the tool's numpy map: rms 0.0008.
- Measured (llvmpipe, 960 x 540, ms a frame, shots 01 / 04): no net 443 / 616, map 498 / 741, per pixel as merged
  (one copy) 965 / 1119, per pixel with the tile break 1110 / 1352. Map against per pixel on the sand: mean
  difference under 0.3 of 255.

## 0.6.0-dev (28 Nov 2026): the moons' night face
- Engine: Sky 0.2.1. The rest of MOON_HLSL is ported: at night the face is scaled so that its highlands sit at
  MoonCap 3 (in exposed units, so the maria keep their contrast), it takes the night tint (MoonBlue 0.2, MoonTint
  mixed 0.5), and it keeps MoonSat 0.5 of its colour. NightCut 0 is wired. The moon's day colour is now Unreal's
  (planck(moon) / planck(sun) at luminance 1), replacing a 6500 K-white blackbody fit. Before this, the full Moon B
  clipped to a white disc under the night eye. Now it reads as a pale blue-white face with its maria. Day is unchanged
  (the cap only lowers).

## 0.6.0-dev (28 Nov 2026): the Unreal night eye
- Engine: WorldRoot.apply now has sun_v184's night eye (exposure()): night_weight (0 at 1000 lux, 1 at 1 lux), the
  exposure limits (NIGHT_SHUT -3.25, NIGHT_OPEN -4.75, BRIGHTEN_STOPS 1.5), night_key_stops (Krawczyk key) plus
  NIGHT_LIFT 0.5 on the compensation, dawn_dim, the steady under-water step fading out at night and NIGHT_EYE_UNDER 1.
  Before, a moonless night was exposed about 8.7 stops over Unreal's. Now EV100 -4.75 moonless (hour 22), -3.48 under
  two moons (hour 94), -3.69 at dusk (18.6), noon unchanged (15.5 air / 14.75 under water). Not ported: sunset_shut.
  Moon face cap and the mirrored sky: fixed, see the entries above.

## 0.6.0-dev (28 Nov 2026): Gary's brightness pick
- Engine: under water +1 stop (WorldRoot.under_exposure_art 1.0) and haze GlowK 1.0 (was 2.5) by default: Gary picked
  "Brighter" 17:06Z. Noon near sand L* 72, far water 48, shadow 50 (key frame 79 / 50-52 / 44).

## 0.6.0-dev (27 Nov 2026, late night): the Unreal light net on the sand
- Engine: caustics 0.1.0 (`look/caustics.gdshaderinc`, generated by `tools/make_caustic_waves.py`; read by
  seabed_surface 0.4.0 and ground_surface 0.2.0 in place of the placeholder cell blobs). lagoonwater v98's net maths
  per pixel: the ray bent by 0.24981 x depth x the slope, three steps back to its entry point, light = 1 / the bundle's
  area (CAUS_EPS 0.03, CAUS_CAP 12), the three depths 0.8 / 2 / 5 m with their slope mips and curvature spans, the
  sun's disc, the entry point slid along the refracted sun, the fade-in over 0.8 m, strength S 0.90 and headroom 2.0
  on the sun's beam only. Godot has no FFT sea yet, so the waves are 32 drawn from v98's spectrum (wind 2 m/s over
  3 km, slick 16 rad/m, cascade 2's band), moving with TIME. Offline against v98's map emulated in numpy, std of the
  net at 0.8 / 2 / 5 m: 0.15 / 0.32 / 0.29 (v98 0.14-0.15 / 0.29-0.31 / 0.34), cell 13 / 13 / 17 cm (12 / 12-14 /
  15-16). Not ported: the colour fringe, god rays, the tile break (not needed: the waves never repeat). Wind heading
  on the island is not known (0 = toward +x). Cost: about 1000 sin/cos a lit pixel; the map route (one 512 px
  target a frame, as Unreal) is the next step when the FFT sea comes. `caustic_strength` is now Unreal's NetK.

## 0.6.0-dev (27 Nov 2026, midnight): first art-direction levers
- Gary 16:45Z/16:50Z: art direction trumps realism; physics stays the base. WorldRoot.light_neutral (0..1): sunlight and
  skylight keep their colour on the way down to the floor (the per-band loss pulled to its luminance mean; the haze along
  the view is untouched). Noon near sand saturation 0.65 -> 0.53 (0.5) -> 0.32 (1.0), key frame 0.06; corals regain their
  warm colour. WorldRoot.depth_colour / depth_colour_share: Unreal v168 depth colour give-back (sun_v184 depth_gain,
  matches the Python to 4 decimals); weak at the camera's depth (0.65 -> 0.58 at 4x share). light_neutral defaults to 1.0 (Gary
  picked "Full" 16:53Z); depth colour stays off. Shot tool: AO_LIGHT_NEUTRAL, AO_DEPTH_COLOUR, AO_DEPTH_SHARE.

## 0.6.0-dev (27 Nov 2026, late night): the Unreal night sky
- Engine: Sky 0.2.0. `look/sky_stars.gdshaderinc` is sun_v184 M_Stars (STARS_HLSL, lines 6744-7877) ported line for
  line in the clock's z-up axes: the star field (two random stars per cube cell plus the catalogue of 1914 bright stars
  with the five figures and the clusters), glints, the planet, the Milky Way (dust, star clouds, nebulae), faint-star
  haze and speckle, airglow, zodiacal light, the moons' sky glow (Krisciunas & Schaefer), the eclipse glow and the night
  haze on the horizon. Above water only (Gary's rule, Unreal v32); not drawn in the sky's radiance cubemap.
  `look/star_catalogue.gd` holds the catalogue (CAT[2319], CATS[385], copied value for value) and builds its float
  texture at run time. WorldRoot._push_sky feeds what the Unreal clock wrote: the sky's turn (StarSpin), the moons'
  view radii, exposure, site lux, eclipse glow, the key light's temperature, and AgX's NightSky / NightDeep.
  Left out, no such system here: clouds in front, scene-depth occlusion and the haze over far geometry, the tank's
  wave refraction; dead in Unreal too: the old aureole, airglow ripples.
  The sky now uses TIME and POSITION, so Godot runs it as a realtime sky.

## 0.6.0-dev (27 Nov 2026, night): the Unreal AgX tonemapper
- Engine: AgX post 0.1.0 (`look/agx_post.glsl`, `adapters/godot/agx_effect.gd`): sun_v184 M_PP_AgX ported line for
  line as a CompositorEffect after the transparent pass (Wrensch AgX fit, Punch 0.4, white balance following the light
  (SkyClock.white_now), SkyBlue on the sky, the under-water daylight white point 1.0713/0.9914/0.8748 faded over 0.2 m,
  night look, NightDeep, night sky, StarKeep, EmitKeep, HueKeep). Godot's tonemapper goes LINEAR (sRGB encoding only)
  and its glow is off; Unreal bloom is not ported yet. Measured: Godot's buffer at that point is already exposed
  (1000 nits -> 0.2035 at EV 12) and nothing multiplies after the effect. WorldRoot.set_agx(false) / AO_AGX=0 = before.
  Noon: the sky is blue instead of grey; under water reef far water L* 57.0 -> 54.8, near sand 75.5 -> 70.6 (Unreal's
  numbers were taken under this curve: 58-59 / 74-76, so the scene is about a third of a stop dark; to trace).
  Night and twilight need the stars and the twilight sky dome first (the dome is black with the sun below the horizon).

## 0.6.0-dev (27 Nov 2026, late): one world root
- Engine: architecture cleanup agreed with gameplay. core/world/ holds the engine-free world state: SkyClock (was
  core/m30_world_clock), WaterOptics and LagoonWaterField (were in look/). adapters/godot/world_root.gd (WorldRoot) is
  the one node that owns the key light, environment, sky, camera exposure and the water_* shader globals; it replaces
  sky_clock_driver.gd, look/sky_driver.gd and WaterOptics.push_globals, and caches the sky dome integral. look/ now
  holds shaders only; the shot tool moved to tools/lagoon_shots.gd and builds its world through WorldRoot. Clock test
  42/42, render unchanged (far water L* 57.0 vs 57.2 before).
- Engine: shared ground material (`look/ground_surface.gdshader`): the Unreal WorldSurface.ush GroundBlend (sand
  ripples, grains, rock, turf, crust; art bible v1.6 colours) converted by tools/ws_to_godot.py into
  look/world_surface.gdshaderinc, so one HLSL source keeps feeding both engines. adapters/godot/world_textures.gd
  loads the 19 world textures (AO_WORLDTEX for the shot tool).

## 0.6.0-dev (27 Nov 2026, evening): gameplay now built on Gary's Thalassa v20.19
- M04 body 0.2.0: stress test tests/test_body_stress.gd (Gary 27 Nov: "every case, every limb, every body part
  interaction, constraints, IK"). 45 cases (walk, turn, jump, crouch, walls, low ceiling, steps, ramps, ledges, stairs,
  beach, waves, swimming, caves, sea floor, current, ceilings, hits, frame hitches, teleport) plus random monkey runs,
  checked every tick: bone lengths, elbow/knee direction and limits, joint pops, limbs in rock, soles on and not sunk
  into the ground, planted-foot slide <= 3 cm, legs/arms not through each other or the body. Planted faults (bone
  length, no-clip off, flipped elbow) must fail. --film renders the clips on the proof page. Result: 60 Hz 40/45 + 5
  known open (step down, 30 deg slope walked across x2, stairs), gating in run_all; 30 Hz 40/45, 120 Hz 38/45 and
  monkeys 1/4 reported, not yet gating. FIX lines (all off under thalassa_exact, both goldens still MATCH):
  rig sub-steps dt > 1/55 s; feet keep a 7-point sole plate on the ground (toe/heel pivot, slope-aware tread
  centring, lateral reach limits); a planted foot past the leg's reach or clamp steps at once (foot_placer forced,
  FORCED_HARD 7 cm overrides waiting for the other foot); the pelvis yields to a planted foot it would lift; walls
  push the foot with a lip rule; swim legs stay on the hip's side of rock (hip-to-ankle ray), buried points are pushed
  out, the clearance push grows at up to 9 m/s; non-finite floor fallbacks (chest went NaN off the world edge).
  M02 motor FIXes (config thalassa_exact): walking off a drop > 0.36 m falls under gravity; the mid-air jump offset is
  re-based when the floor under her changes (eye dropped 32 cm in one tick off a step); no 60% crouch cut and no loss
  of the eye's trail at take-off (18 cm camera pop jumping from a crouch). WorldQuery rays ignore back faces.
  Round 2: a planted foot turned past the hip's rotation range asks for a step (the leg solver twisted it about the
  ankle, sliding heel and ball in fast turns); a foot 3 cm out of reach steps even with the other foot in the air
  (FORCED_HARD/HARD_MISS 0.03, was 7 cm); the air floor clamp no longer pops a crouched take-off up 14 cm. Now 60 Hz
  42/45 + 3 known (slope across x2, stairs), 30 Hz 41/45, 120 Hz 38/45, monkeys 2/4 (3.1 and 3.8 cm slides left).
- M04 body 0.1.0 = Thalassa core/ik-rig.js DiverBodyRig (swim pose, shore walk/wade pose, swim-walk blend, head
  look, no-clip arms and legs) + ik-solvers.js (two-bone IK, leg with fin), procedural-locomotion.js
  (BalanceFootPlacer incl. jumps), physics-control.js (PhysicsControlRig profiles, hit reactions), crit springs and
  inertializer. Golden test against the JS: worst 0.051 mm over two 20 s runs (10 joints). Brain is a quiet stand-in
  (gaze = look direction) until character-brain.js is ported; hair bob and the UE5 skeleton export are left out.
  adapters/godot/mannequin.gd builds Thalassa's style/ue5-mannequin.js girl (ceramic segments, slate joints) and is
  posed by the rig; it replaces the capsule in tools/motion_film.gd ("capsule" arg keeps the old stand-in).
  Fix: player_body assigned an untyped array to WorldQuery.exclude (Array[RID]); now appends.
- M02 player motor 0.2.0 = Thalassa core/swimmer-physics.js ported line for line (SwimmerLocomotion: carve turns,
  flipper-kick burst, glide-out braking, dive-to-pullout momentum, slipstream, surface treading with swell, dolphin
  breach, plunge dip, shoreline walk/wade/jog/crouch, anticipation jump, running dive) + mover.js layered moves
  (ocean current, impulses). Golden test against the JS: worst 0.05 mm over two 20 s runs.
  Godot adapter adds what Thalassa's height field never needed: Jolt collisions, 0.35 m step limit (T1), swim sphere
  0.42 m so a child fits a 1.0 m cave (T5), no standing up under low ceilings, steep dry slopes are walls, plus two
  robustness guards found by monkey runs (no floor at a world edge; air-branch speed cap under ledges) and contact
  velocity projection (Jolt's slide redirected a push against an edge sideways and snowballed to 13 m/s).
  19/19 at 30/60/120 fps incl. 4 x 300 s monkey runs; T1 50 deg ramp test moved to 60 deg (Thalassa walks to 56 deg).
- M01 input 0.2.0 = Thalassa core/input.js DualSense map and curves: move deadzone 0.11 / exponent 1.45, look 2.4 rad/s
  with exponent 1.72, outer-zone boost 1.45, asymmetric accel/stop filter 22/34 Hz, L2 analog dive, L1 or Cross ascend,
  R2 boost / L3 sprint latch, Circle observe, Triangle board, R1 sonar, R3 view, D-pad lights / silent / Atlas / TARS.
  Changed from Thalassa for platform rules: TARS leaves the Create button (system capture) for D-pad right; radio off
  Square and the touch pad. Golden test: worst 7.5e-8. 16/16 device tests.
- M03 camera 0.2.0 = Thalassa core/cinematic-camera.js updateForActor (anchor-relative crit springs, rigid 1P lock,
  Living Observer breath / lead room / landing settle, binary-refined spring arm). Golden: worst 0.004 mm over 15 s.
  Adapter: Jolt floor ray and sphere overlap answer the arm's probes; water-line rule kept from 0.1.0 for third person
  (sprung, 3-tick crossings). 11/11 incl. 4 x 300 s camera monkeys; probe-off fault caught. Replaces the 0.1.0 director.

## 0.6.0-dev (27 Nov 2026), slice setup, not yet in a git repo
- Engine: sand step 1: Better sand colour lock (SD2: #cdcac4 bare, #c8c4bb sorted) on the floor pieces, and the sand's
  bounce light in the fish's ambient (Lighting's sand bounce). Near sand L* 70.8 -> 72.4 (Unreal key 74-76), far water
  unchanged at 59. Still to port: the ripple rule, grains and glints (WorldSurface.ush: needs a Godot converter, since
  Godot shaders have no mutable globals) and our AgX extras.
- Engine: sky port 0.1.0 (`look/sky.gdshader`, `look/sky_driver.gd`): the Unreal sun disc and corona (SUN_HLSL) and both
  moons (MOON_HLSL: Lommel-Seeliger face, maria, planetshine, soft edge, phases from the clock) drawn as is, sun x5.29;
  air extinction per band (0.0862, 0.1665, 0.2961) now also colours the key light. Dome: Godot's PhysicalSkyMaterial shape
  (stand-in for Unreal's SkyAtmosphere, an engine feature), scaled so its ground light equals the clock's sky_lux.
  Checked at day 2, 5:30 pm: Moon B 76% lit, Moon A a 9% crescent beside the low sun. Stars (STARS_HLSL) still to port.
- Engine: ported Unreal systems, round 1 (Gary 27 Nov 15:13Z "port working Unreal systems to Godot").
  M30 world clock 0.1.0 (`core/m30_world_clock/sky_clock.gd`): the Unreal sky clock's maths (sun_v184) as is: G2V sun twin,
  128 klx above the air, 78 deg noon, moons A and B (size, albedo, colour, phases, orbits), eclipses, twilight table, key-light
  pick and hand-over fade. `tests/test_world_clock.gd` matches the old Python at 42 points (light 1e-5, angles 1e-4 deg). PASS.
  Clock adapter 0.1.0 (`adapters/godot/sky_clock_driver.gd`): key light lux and colour, EV100 exposure (steady under-water eye
  14.75 at noon, as Unreal's 14.6-14.9), calm lagoon +1.2 compensation. Physical light units on project-wide.
  Lagoon water optics 0.1.0 (`look/water_optics.gd`, `look/water_physics.gdshaderinc`): the Unreal lagoon's water physics
  (under_model / PHYS_CODE / UNDER_PHYS) with Gary's look set Cdom 0.03, ScatK 0.40, GlowK 2.50, as global shader uniforms.
  Seabed 0.2.0 lit through the water; underwater view 0.1.0 (path glow + absorption per band); surface 0.2.0 (window + mirror).
  Lagoon look 0.2.0: surface at 4 m (Unreal's SurfaceZ 400 cm). Measured: far water L* 59 (Unreal model 58-59), near sand
  L* 68-70 (Unreal key 74-76: sand albedo and sand bounce not ported yet).
- Gameplay: M01 input 0.1.0 (16/16): bindings as data, Create and PS buttons never bound, glyph names per platform and live
  swap, remap refused onto system or taken buttons, remap survives save/reload, controller loss pauses with neutral input.
  Root fix found by the test: InputMap's per-action deadzone stacked with the core's radial deadzone (half-speed small stick);
  sticks now reach the core raw.
- Gameplay: M29 water physics 0.1.0 (8/8 at 30/60/120 fps, identical): drafts 0.499 / 0.877 m for 0.5 / 0.878 density,
  drop from 3 m settles, flat box rights from 30 deg, dense box sinks, tall pole lies down, follows Beaufort 4 waves,
  drifts at 0.95 m/s in a 1 m/s current. Root fixes: engine world damping (0.1/s) fought currents (now off for water bodies);
  drag area counted once per layer. Stand-in: heave damping for wave radiation (logged in HARD_PROBLEMS.md).
- Gameplay: M02 player motor 0.1.0 + M23 harness 0.1.0 on Jolt (Godot 4.7). 23/23 cases pass at 30, 60 and 120 fps with
  identical end states (fixed 60 Hz tick): walk, 15/30 deg slopes climb, 50 deg refuses, 10/30 cm steps climb, 50 cm refuses,
  shore walk-wade-swim-wade-walk (still and Beaufort 4 waves), cruise 3.4 / sprint 5.0 m/s, dive and rise to tread, tread holds
  in waves, 1.0 m cave passes, 0.8 m refuses, makes way against 1.5 and 3 m/s currents, 8 x 300 s monkey runs.
  Root fixes found by the monkey runs: airborne-in-water counted as wading (now floating past the chest band); wading
  turned to swimming while bobbing at 1.03 m (now needs 0.5 s afloat); slope/wave floor loss flicker (coyote 0.15 s).
  Planted fault (swim sphere 0.30 m) lets the 0.8 m cave through and is caught.
- Godot 4.5.1 project skeleton (Forward+), proven to render in the cloud on CPU Vulkan.
- M12 world streaming core 0.1.0 (`core/m12_streaming/cell_streamer.gd`): ring of live cells + far stand-ins, travel lookahead,
  hysteresis. Test `tests/test_cell_streamer.gd`: swim 2 m/s and fast sub 25 m/s across 4 x 4 km, zero cells missing inside 32 m,
  live <= 26, far <= 75, <= 2 new cells per update after the start fill; planted fault (no lookahead, 20 m ring) caught. PASS.
- Godot adapter 0.1.0 (`adapters/godot/stream_loader.gd`): threaded ResourceLoader loads, instancing spread across frames. Not yet run on a world.
- Turnaround tool 0.1.0 (`tools/turnaround.gd`): any GLB at runtime, 7 views + sheet + import report. First run: LIVE snapper LOD1
  arrived with 65,458 triangles, 86 joints, COLOR_0 present. Finding: Godot uses COLOR_0 as albedo by default, but ours is data
  (R = fin thickness), so the importer must switch that off (done in the tool; the game importer needs the same rule).
