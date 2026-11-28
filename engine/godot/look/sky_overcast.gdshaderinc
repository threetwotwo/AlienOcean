// Overcast sky 0.1.0 (look thread, 28 Nov 2026): cloud cover blends the clear dome's radiance toward a cloud deck.
// sky_overcast (0..1, WorldRoot.sky_overcast) is the cloud cover N. The deck is the CIE standard overcast sky (CIE S 011/2003,
// type 1; Moon & Spencer 1942): grey, brightest at the zenith, L(z) = Lz (1 + 2 cos z) / 3, whose light on level ground is
// Lz x 7 pi / 9. sky_oc_zenith = Lz in nits, set by WorldRoot so the deck alone gives the clock's (overcast) sky light: a blend
// of two fields with the same ground light keeps that light, so the dome's brightness stays the clock's at any cover.
// Used by look/sky.gdshader and by any shader that shows the sky (sea reflections, Snell's window): call sky_overcast_air()
// on the clear dome's nits so every view of the sky sees the same clouds.
global uniform float sky_overcast;
global uniform float sky_oc_zenith;
vec3 sky_overcast_air(vec3 clear_air, vec3 v) {
	float n = clamp(sky_overcast, 0.0, 1.0);
	if (n <= 0.0) return clear_air;
	float deck = sky_oc_zenith * (1.0 + 2.0 * max(v.y, 0.0)) / 3.0;
	return mix(clear_air, vec3(deck), n);
}
