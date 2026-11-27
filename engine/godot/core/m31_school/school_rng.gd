## M31 school: the school's random numbers. One PCG hash stream (the same hash the Unreal school lab used on the GPU,
## AOS_HASH in schoollab v1-v87), so the GDScript school, the numpy reference (tests/golden/school_trace.py) and a later
## GPU step can draw the very same numbers in the same order. Plain integer maths in 32 bits (GDScript ints are 64-bit).
extends RefCounted

var h := 0

func _init(seed_: int = 1) -> void:
	h = (seed_ * 2654435761 + 12345) & 0xFFFFFFFF

func next_u32() -> int:
	h = (h * 747796405 + 2891336453) & 0xFFFFFFFF
	var w := (((h >> ((h >> 28) + 4)) ^ h) * 277803737) & 0xFFFFFFFF
	return (w >> 22) ^ w

## Uniform in [0, 1).
func uniform() -> float:
	return float(next_u32() >> 8) * 5.9604644775390625e-8

## Whole number in [0, n).
func integer(n: int) -> int:
	return mini(int(uniform() * n), n - 1)

## Standard normal (Box-Muller, cosine branch; two uniforms per number).
func normal() -> float:
	var u1 := uniform()
	var u2 := uniform()
	return sqrt(-2.0 * log(1.0 - u1)) * cos(TAU * u2)
