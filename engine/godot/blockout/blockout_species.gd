## Blockout creature profiles 0.1.0 (blockout kit): rideable stand-ins of different sizes that swim the way their
## animal swims, with the grab points Gary's Thalassa v20.19 uses (core/wildlife-ecosystem.js getCreatureGripWorld,
## findNearestRidable, the GPU swim modes in style/wildlife-assets.js). Sizes are real adult sizes; where Thalassa's
## numbers differ the Thalassa value is noted. All body coordinates are normalised: u = 0 at the snout, 1 at the tail
## tip; x and y as fractions of the body LENGTH (so a profile scales by one number).
##
## Swim modes (displacement of the body / fins, phase = omega t, k = wave number per body length):
##   vertical  dorso-ventral body wave + horizontal flukes (cetaceans: dolphin, humpback). Thalassa dolphin GPU mode 5:
##             dispY = sin(ph - 1.45 lz) * 0.24 * smoothstep(-0.55, 1.72, lz); omega = 3.2 + 0.65 v.
##   lateral   side-to-side body wave + vertical tail (sharks: whale shark). Thalassa GPU mode 1:
##             dispX = sin(ph - 0.56 lz) * 0.36 * smoothstep(-1.2, 8.8, lz); omega = 1.12 + 0.22 v.
##   flap      wing flapping, wave running out along the span and back along the chord (manta). Thalassa:
##             waveY = sin(ph - 1.15 |x| - 0.58 z) * amp * smoothstep(0.18, 2.7, |x|)^1.45; omega 1.55..2.65.
##   stroke    four flippers rowing, rigid shell (turtle). Thalassa: strokePhase += dt * (2.05..3.05).
##
## Grab slots (Thalassa): a slot is where both hands hold; each slot has hand_l, hand_r and a body point (chest / hips
## rest). dolphin: both flanks of the falcate dorsal fin. whale shark: dorsal fin leading edge, left / right pectoral
## fin leading edge, upper tail lobe. manta: dorsal chevron behind the head. turtle: front rim of the carapace.
## humpback (not in Thalassa; Gary 28 Nov "a dolphin swims differently from a whale"): long pectoral flippers, dorsal hump.
## A 4th number on a hand is the palm's clearance in METRES (not scaled), pushed out along x: Thalassa keeps palms
## 1.3 cm off a dolphin fin's flank at any size (getCreatureGripWorld packSocket clearM 0.013), so a small dolphin's
## fin still fits between two palms.
## Thalassa holds dorsal and PECTORAL fins (not pelvics); pelvic slots can be added per profile the same way.
class_name BlockoutSpecies
extends RefCounted

## name -> profile. length m (span for the manta is 'span'), r = body half-thickness / length at its widest,
## speed m/s, omega(v) = w0 + w1 v rad/s, k rad per length, amp = displacement / length at the tail (or wing tip),
## env = [u0, u1] where the wave grows from 0 to full, path = racetrack {L, R, H, bank_deg} in metres.
const PROFILES := {
	"dolphin": {"length": 2.6, "r": 0.115, "mode": "vertical", "speed": 4.35, "w0": 3.2, "w1": 0.65, "k": 4.35,
		"amp": 0.075, "env": [0.32, 1.0], "path": {"L": 30.0, "R": 8.0, "H": 3.0, "bank": 25.0},
		"fins": {"dorsal": [0.50, 0.11, 0.09], "flukes": [0.97, 0.22], "pecs": [0.33, 0.13]},
		"slots": {"dorsal": {"hand_l": [0.49, -0.006, 0.150, 0.013], "hand_r": [0.49, 0.006, 0.150, 0.013], "body": [0.56, 0.0, 0.115]}},
		"note": "Thalassa base mesh 3.3 m x 0.94-1.14; real adult bottlenose 2.5-3 m"},
	"humpback": {"length": 14.0, "r": 0.12, "mode": "vertical", "speed": 2.0, "w0": 1.2, "w1": 0.15, "k": 4.6,
		"amp": 0.09, "env": [0.40, 1.0], "path": {"L": 60.0, "R": 22.0, "H": 4.0, "bank": 10.0},
		"fins": {"dorsal": [0.66, 0.03, 0.05], "flukes": [0.98, 0.30], "pecs": [0.30, 0.32]},
		"slots": {"pec_left": {"hand_l": [0.33, -0.22, 0.0], "hand_r": [0.31, -0.20, 0.006], "body": [0.34, -0.22, 0.02]},
			"pec_right": {"hand_l": [0.31, 0.20, 0.006], "hand_r": [0.33, 0.22, 0.0], "body": [0.34, 0.22, 0.02]},
			"hump": {"hand_l": [0.655, -0.012, 0.16], "hand_r": [0.655, 0.012, 0.16], "body": [0.69, 0.0, 0.135]}},
		"note": "not in Thalassa; real adult 12-16 m, tail beat ~0.2-0.3 Hz"},
	"whale_shark": {"length": 10.0, "r": 0.10, "mode": "lateral", "speed": 1.85, "w0": 1.12, "w1": 0.22, "k": 7.4,
		"amp": 0.06, "env": [0.42, 1.0], "path": {"L": 50.0, "R": 18.0, "H": 1.5, "bank": 8.0},
		"fins": {"dorsal": [0.50, 0.13, 0.08], "tail": [0.97, 0.20], "pecs": [0.26, 0.20]},
		# dorsal / tail (Thalassa getCreatureGripWorld): both hands on her ride (+x) flank of the fin, the upper one just
		# behind the leading edge, the lower one 7 cm further back; at this stand-in's fin boxes (tilted 0.35 / 0.5 rad)
		"slots": {"dorsal": {"hand_l": [0.4155, 0.006, 0.185, 0.013], "hand_r": [0.427, 0.006, 0.165, 0.013], "body": [0.445, 0.03, 0.12]},
			"pec_left": {"hand_l": [0.245, -0.17, -0.015], "hand_r": [0.25, -0.14, -0.012], "body": [0.27, -0.16, 0.0]},
			"pec_right": {"hand_l": [0.25, 0.14, -0.012], "hand_r": [0.245, 0.17, -0.015], "body": [0.27, 0.16, 0.0]},
			"tail": {"hand_l": [0.907, 0.006, 0.11, 0.013], "hand_r": [0.922, 0.006, 0.09, 0.013], "body": [0.905, 0.025, 0.05]}},
		"note": "Thalassa base mesh 13.2 m x 1.44-1.60 = 19-21 m (oversized); real adult 8-12 m, speed ~1.1 m/s"},
	"manta": {"length": 3.0, "span": 6.0, "r": 0.06, "mode": "flap", "speed": 1.4, "w0": 2.0, "w1": 0.0, "k": 0.58,
		"amp": 0.17, "env": [0.06, 1.0], "path": {"L": 24.0, "R": 7.0, "H": 2.0, "bank": 30.0},
		"fins": {"tail": [1.0, 0.0]},
		# the hands on its broad back at most 0.36 m out (Thalassa: 0.30 m, one size): a bigger manta is held as wide
		"slots": {"dorsal": {"hand_l": [0.36, -0.10, 0.07, 0.0, 0.36], "hand_r": [0.36, 0.10, 0.07, 0.0, 0.36], "body": [0.52, 0.0, 0.06]}},
		"note": "Thalassa base span 5.4 m x 1.25-1.75; real reef manta 3-5 m span, oceanic to 7 m"},
	"turtle": {"length": 1.1, "r": 0.17, "mode": "stroke", "speed": 1.65, "w0": 2.5, "w1": 0.0, "k": 0.0,
		"amp": 0.55, "env": [0.0, 1.0], "path": {"L": 14.0, "R": 4.0, "H": 1.5, "bank": 15.0},
		"fins": {"flippers": [0.28, 0.42, 0.75, 0.18]},
		"slots": {"shell_rim": {"hand_l": [0.20, -0.21, 0.19], "hand_r": [0.20, 0.21, 0.19], "body": [0.55, 0.0, 0.21]}},
		"note": "Thalassa base ~1.6 m x 0.96-1.18; real adult green turtle shell ~1 m, cruise ~0.8 m/s (Thalassa 1.65)"},
}

static func names() -> Array:
	return PROFILES.keys()

## Smooth 0..1 envelope of the swim wave along the body.
static func envelope(p: Dictionary, u: float) -> float:
	var e0: float = p.env[0]; var e1: float = p.env[1]
	var s := clampf((u - e0) / maxf(1e-3, e1 - e0), 0.0, 1.0)
	return s * s * (3.0 - 2.0 * s)

## Body half-thickness profile (fraction of length) at u: blunt head, widest near 0.3, slim peduncle.
static func radius(p: Dictionary, u: float) -> float:
	var r: float = p.r
	if u < 0.3: return r * sqrt(maxf(0.0, sin(u / 0.3 * PI * 0.5))) * 0.98 + r * 0.02
	return r * maxf(0.08, cos((u - 0.3) / 0.7 * PI * 0.5))

## Displacement (m, body frame: x right, y up, z back) of the body midline at u for phase ph.
static func body_disp(p: Dictionary, u: float, ph: float, length: float) -> Vector3:
	var a: float = p.amp * length * envelope(p, u)
	var w := sin(ph - float(p.k) * u)
	match String(p.mode):
		"vertical": return Vector3(0, a * w, 0)
		"lateral": return Vector3(a * w, 0, 0)
	return Vector3.ZERO

## Wing displacement for the manta at span fraction ax (0 centre .. 1 tip) and chord u.
static func wing_disp(p: Dictionary, ax: float, u: float, ph: float, half_span: float) -> float:
	var fw := pow(clampf((ax - 0.067) / (1.0 - 0.067), 0.0, 1.0), 1.45)
	fw = fw * fw * (3.0 - 2.0 * fw)
	return sin(ph - 1.15 * ax * 2.7 - float(p.k) * (u - 0.5) * 2.6) * float(p.amp) * half_span * fw
