## Bathymetry 0.2.0 (core/world; water surface thread, 28 Nov 2026): the lagoon's seabed by depth, out over the reef
## and down the drop-off to the open ocean. Gary: "for lagoon, sculpt dropoffs to the deep open water, stress test the
## looks in the transitions." One description, read by the drop-off's seabed (adapters/godot/reef_terrain.gd) and by
## the water (look/sea_bathy.gdshaderinc mirrors depth() line for line), so seabed and water colour always agree.
## Engine-agnostic (no Node): metres, Godot x z, depth = metres under the still surface (positive down).
##
## The shape, from an atoll's lagoon outward (a coral reef's usual zones; numbers are a stand-in to tune by eye):
##   lagoon sand at the lagoon's depth (the drawn floor's: WorldRoot.floor_y under the surface, 4 m)
##   back reef: the sand rises over BACK_M to the reef flat, REEF_FLAT_D deep (bright turquoise in the light)
##   reef flat: FLAT_M across, then the crest
##   the wall: down to WALL_D over the sector's run (SECTOR_WALL_M: 86 deg to 10 deg), the drop-off proper
##   fore-reef slope: down to SLOPE_D over SLOPE_M (about 30 deg)
##   the deep: on to ocean_depth over DEEP_M, in log depth (the colour changes over the whole fall, not its first metres)
## The reef edge wanders (two slow waves round the lagoon, so it is not a circle), and the crest and upper wall are cut
## into spurs and grooves (ridges running down the slope every SPUR_M, as real fore reefs are).
## 0.2.0 (Gary: "a simple world is sufficient, but with rigourous cases for stress testing"): the ring is cut into
## SECTORS, each one drop-off kind, so every transition has a clean, known case: round from sector_deg (the angle
## atan2(z, x) of sector 0), a vertical wall (86 deg), a 60 deg wall, a 30 deg slope, a gentle ramp (10 deg) and a
## 45 deg wall with a sand pass cut through the reef (PASS_W wide, PASS_D deep). Each sector holds its shape over
## its middle 30 % of arc either side and blends into the next (the blends are cases too).
class_name Bathymetry
extends RefCounted

const BACK_M := 30.0
const REEF_FLAT_D := 1.2
const FLAT_M := 25.0
const WALL_D := 30.0
const SLOPE_D := 150.0
const SLOPE_M := 220.0       # + 2 x the sector's wall run (a gentle ramp keeps its fore-reef slope gentle too)
const DEEP_M := 900.0
const SPUR_M := 14.0          # spur and groove spacing along the reef, m
const SPUR_OUT := 4.0         # m: how far the spurs push the crest and wall outward
const SPUR_D := 2.5           # m: how much deeper the grooves are than the spurs, on the upper wall
# the sectors' walls: horizontal run (m) of the drop from the reef flat to WALL_D; the steepest slope of the smoothstep
# is 1.5 (WALL_D - REEF_FLAT_D) / run, so 3 m = 86 deg, 25 m = 60 deg, 75 m = 30 deg, 43 m = 45 deg, 245 m = 10 deg
const SECTOR_WALL_M := [3.0, 25.0, 75.0, 245.0, 43.0]
const SECTOR_NAMES := ["vertical wall", "60 deg wall", "30 deg slope", "gentle ramp", "45 deg wall + pass"]
const PASS_SECTOR := 4
const PASS_W := 25.0          # m: the pass's floor width (its sides take ~8 m more)
const PASS_D := 6.0           # m: the pass's floor depth across the reef flat

var centre := Vector2.ZERO    # the lagoon's centre (Godot x, z)
var radius := 150.0           # m to the reef flat's inner edge (0 = no reef: the lagoon goes on for ever)
var lagoon_d := 4.0           # m: the lagoon's sand depth
var ocean_depth := 1000.0
var sector_deg := 0.0         # the angle (deg, atan2(z, x)) of sector 0's middle (WorldRoot: the view out from the test level)

func sector_mid(k: int) -> float:
	## the angle (rad, atan2(z, x)) at the middle of sector k
	return deg_to_rad(sector_deg) + TAU * k / SECTOR_WALL_M.size()

func wall_m(th: float) -> float:
	## the wall's run (m) at angle th: sector k's own from 30 % before to 30 % after its middle, blended (in log) between
	var ns := SECTOR_WALL_M.size()
	var a := fposmod((th - deg_to_rad(sector_deg)) / TAU * ns, float(ns))
	var k := int(floorf(a)) % ns
	var w := _ss(0.3, 0.7, a - floorf(a))
	return exp(lerpf(log(SECTOR_WALL_M[k]), log(SECTOR_WALL_M[(k + 1) % ns]), w))

func pass_w(th: float) -> float:
	## 1 on the pass's floor, 0 away from it (its sides take 8 m)
	var dth := absf(wrapf(th - sector_mid(PASS_SECTOR), -PI, PI))
	return 1.0 - _ss(PASS_W * 0.5, PASS_W * 0.5 + 8.0, dth * radius)

static func _ss(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func depth(x: float, z: float) -> float:
	## metres under the still surface at (x, z)
	if radius <= 0.0: return lagoon_d
	var d := Vector2(x, z) - centre
	var r := d.length()
	var th := atan2(d.y, d.x)
	var rr := radius * (1.0 + 0.06 * sin(3.0 * th + 0.7) + 0.03 * sin(8.0 * th + 2.1))
	# spurs and grooves: phase along the reef's length (arc length / spacing), wobbled so the ridges are not ruled lines
	var n := roundf(TAU * radius / SPUR_M)                  # a whole number of spurs round the reef (no seam)
	var g := 0.5 + 0.5 * sin(n * th + 1.8 * sin(5.0 * th) + 0.9 * sin(13.0 * th))
	var s := r - rr                                       # m past the reef flat's inner edge
	var wm := wall_m(th)
	var pw := pass_w(th)
	var fd := lerpf(REEF_FLAT_D, PASS_D, pw)                # the reef flat's depth (the pass's floor in the pass)
	g *= 1.0 - pw                                           # no spurs in the pass
	var crest := FLAT_M + SPUR_OUT * g                     # the spurs reach further out
	var h := lagoon_d + (fd - lagoon_d) * _ss(-BACK_M, 0.0, s)
	if s > crest:
		var u := s - crest
		h = fd + (WALL_D - fd) * _ss(0.0, wm, u)
		var sm := SLOPE_M + 2.0 * wm                            # a gentler wall, a gentler fore-reef slope below it
		h += (SLOPE_D - WALL_D) * _ss(wm * 0.6, wm + sm, u)
		var w := clampf((u - wm - sm) / DEEP_M, 0.0, 1.0)
		if w > 0.0: h = SLOPE_D * pow(maxf(ocean_depth, SLOPE_D) / SLOPE_D, w * w * (3.0 - 2.0 * w))
		h += SPUR_D * (1.0 - g) * _ss(0.0, 4.0, u) * (1.0 - _ss(wm, wm + 60.0, u)) * (1.0 - pw)   # the grooves cut the upper wall
	return h

func edge_r(th: float) -> float:
	## m from the centre to the reef flat's inner edge at angle th (atan2(z, x))
	return radius * (1.0 + 0.06 * sin(3.0 * th + 0.7) + 0.03 * sin(8.0 * th + 2.1))

func at(th: float, s: float) -> Vector2:
	## the point s m past the reef flat's inner edge at angle th (Godot x, z)
	return centre + Vector2(cos(th), sin(th)) * (edge_r(th) + s)

func zone(x: float, z: float) -> float:
	## 0 lagoon sand, 1 reef flat, 2 wall and slope (rock), for the seabed's paint
	var h := depth(x, z)
	var r := (Vector2(x, z) - centre).length()
	if radius <= 0.0 or r < radius * 0.8: return 0.0
	return 0.0 if h > lagoon_d - 0.3 and r < radius else (1.0 if h < REEF_FLAT_D + 1.0 else 2.0)
