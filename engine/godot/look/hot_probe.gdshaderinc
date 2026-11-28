// Hot-pixel probe 0.1.0 (horizon line + underwater flashes thread, 28 Nov 2026): a stress-shot switch, off in play.
// AO_HOT_PROBE=<exposed units> (FftSea sets the global hot_probe) paints, in each shader that includes this, every pixel
// whose output is non-finite or brighter than that many exposed units (0.18 = middle grey; the bloom's threshold is
// 4.5) in that shader's own tag colour, so one shot says WHICH shader makes a hot line or flash and whether it is a
// NaN/Inf (Metal compiles with fast math, where isnan() can be folded away: the test reads the float's bits).
//   tags: sea_top green, sea_under red, sky below the horizon cyan, sky above the horizon yellow;
//   non-finite = the tag darkened and mixed with magenta. Read with tools/perf_runner/hot_probe_read.py.
global uniform float hot_probe;
bool hot_probe_bad(vec3 c) {
	uvec3 e = floatBitsToUint(c) & uvec3(0x7f800000u);
	return any(equal(e, uvec3(0x7f800000u)));
}
// c: the pixel in exposed buffer units; returns c, or the tag (exposed units) where it is hot
vec3 hot_probe_paint(vec3 c, vec3 tag) {
	if (hot_probe <= 0.0) return c;
	if (hot_probe_bad(c)) return 0.15 * tag + vec3(0.5, 0.0, 0.5);
	if (max(c.r, max(c.g, c.b)) > hot_probe) return 0.5 * tag;
	return c;
}
