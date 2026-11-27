#version 450
// Sea spectrum pass 0.1.0 (water surface thread): lagoonwater v98 SPECTRUM_HLSL (the tank's spectrum pass) as a Godot
// compute shader, same maths: h~(k, t) per cascade for the four fields the FFT turns into the sea. Elfouhaily 1997 +
// Donelan-Banner + JONSWAP swell, the slick (Depth.y), shallow-water speed (Depth.x), PCG hash -> Box-Muller.
// One invocation per texel and cascade (array layer); it writes all four fields: A = (F0, F1), B = (F2, F3) as complex.
// Run by adapters/godot/fft_sea.gd; constants from core/world/sea_spectrum.gd.
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict writeonly image2DArray outA;
layout(rgba32f, set = 0, binding = 1) uniform restrict writeonly image2DArray outB;
layout(set = 0, binding = 2, std140) uniform Params {
	vec4 SpecA; vec4 SpecB; vec4 SpecC; vec4 SpecD; vec4 Depth; vec4 Patch; vec4 RingHi; vec4 Tm;
};
const float PI = 3.14159265;
const float G = 9.81;
const float KM = 370.0;
const float CM = 0.23;

uint pcg(uint x) {
	uint hx = x * 747796405u + 2891336453u;
	uint hw = ((hx >> ((hx >> 28u) + 4u)) ^ hx) * 277803737u;
	return (hw >> 22u) ^ hw;
}

void main() {
	ivec2 ij = ivec2(gl_GlobalInvocationID.xy);
	int c = int(gl_GlobalInvocationID.z);
	if (ij.x >= 256 || ij.y >= 256) return;
	ivec3 at3 = ivec3(ij, c);
	if (Tm.w > 0.5) {
		// self test: a single wave (3, 5) in cascade 0, in every field; the FFT must turn it into exp(2 pi i (3x + 5y)/256)
		float on = (c == 0 && ij.x == 3 && ij.y == 5) ? 1.0 : 0.0;
		imageStore(outA, at3, vec4(on, 0.0, on, 0.0));
		imageStore(outB, at3, vec4(on, 0.0, on, 0.0));
		return;
	}
	vec4 sel = vec4(c == 0, c == 1, c == 2, c == 3);
	float L = dot(Patch, sel);
	vec4 hiv = 2.0 * PI * RingHi / Patch;
	float khi = dot(hiv, sel);
	float klo = dot(hiv, vec4(c == 1, c == 2, c == 3, 0.0));
	ivec2 n = ivec2(ij.x >= 128 ? ij.x - 256 : ij.x, ij.y >= 128 ? ij.y - 256 : ij.y);
	float dk = 2.0 * PI / L;
	vec2 kv = vec2(n) * dk;
	float k = length(kv);
	if (!(k > klo && k <= khi)) {
		imageStore(outA, at3, vec4(0.0));
		imageStore(outB, at3, vec4(0.0));
		return;
	}
	ivec2 ijm = (ivec2(256) - ij) & 255;
	vec2 h0 = vec2(0.0), h0m = vec2(0.0);
	for (int s = 0; s < 2; s++) {
		// s = 0: this wave; s = 1: its mirror -k (with the mirror texel's random numbers)
		vec2 q = s == 0 ? kv : -kv;
		ivec2 at = s == 0 ? ij : ijm;
		float th = atan(q.y, q.x);
		float kk = k / KM;
		float cph = sqrt(G / k * (1.0 + kk * kk));
		float lpm = exp(-1.25 * (SpecA.x / k) * (SpecA.x / k));
		float sq = sqrt(k / SpecA.x);
		float jp = pow(SpecA.w, exp(-(sq - 1.0) * (sq - 1.0) / (2.0 * SpecB.x * SpecB.x)));
		float fp = lpm * jp * exp(-SpecB.z / sqrt(10.0) * (sq - 1.0));
		float bl = 0.5 * SpecA.z * (SpecA.y / cph) * fp;
		float fm = lpm * jp * exp(-0.25 * (kk - 1.0) * (kk - 1.0));
		float bh = 0.5 * SpecB.y * (CM / cph) * fm;
		float S = (bl + bh) / (k * k * k);
		float w = sqrt(G * k * (1.0 + kk * kk));
		float r = max(w / SpecB.w, 0.56);
		float beta = r < 0.95 ? 2.61 * pow(r, 1.3) : (r < 1.6 ? 2.28 * pow(r, -1.3) : pow(10.0, -0.4 + 0.8393 * exp(-0.567 * log(r * r))));
		float da = th - SpecC.x;
		da = atan(sin(da), cos(da));
		float chb = cosh(beta * da);
		float psi = S * beta / (2.0 * tanh(beta * PI)) / (chb * chb) / k;
		if (SpecC.y > 0.0) {
			float ws = SpecC.z;
			float sg = w <= ws ? 0.07 : 0.09;
			float rr = exp(-(w - ws) * (w - ws) / (2.0 * sg * sg * ws * ws));
			float wr = ws / w;
			float sw = SpecC.y * G * G * pow(w, -5.0) * exp(-1.25 * wr * wr * wr * wr) * pow(SpecD.z, rr);
			float dwdk = G * (1.0 + 3.0 * kk * kk) / (2.0 * w);
			float db = th - SpecC.w;
			db = atan(sin(db), cos(db));
			psi += sw * dwdk * SpecD.y * pow(abs(cos(0.5 * db)), 2.0 * SpecD.x) / k;
		}
		// lagoonwater v5: the slick; v89: Depth.z of the finest cascade passes it
		if (Depth.y > 0.0) psi *= mix(1.0 / (1.0 + pow(k / Depth.y, 4.0)), 1.0, (c == 3) ? clamp(Depth.z, 0.0, 1.0) : 0.0);
		float amp = sqrt(max(psi, 0.0)) * dk * 0.5;
		uint key = uint(at.x) + 256u * (uint(at.y) + 256u * uint(c)) + uint(SpecD.w + 0.5) * 1000003u;
		uint ha = pcg(key);
		uint hb = pcg(ha ^ 0x9E3779B9u);
		float u1 = (float(ha) + 1.0) / 4294967296.0;
		float u2 = float(hb) / 4294967296.0;
		float rad = sqrt(-2.0 * log(u1)) * amp;
		vec2 g = rad * vec2(cos(2.0 * PI * u2), sin(2.0 * PI * u2));
		if (s == 0) h0 = g; else h0m = g;
	}
	// h~(k, t) = h0(k) exp(-i w t) + conj(h0(-k)) exp(i w t), w a whole multiple of 2 pi / Tm.y; lagoonwater: shallow water
	float kq = k / KM;
	float m = floor(sqrt(G * k * (1.0 + kq * kq) * tanh(min(k * max(Depth.x, 0.2), 10.0))) / (2.0 * PI / Tm.y));
	float ph = 2.0 * PI * fract(m * (Tm.x / Tm.y));
	float cs = cos(ph), sn = sin(ph);
	vec2 ht = vec2(h0.x * cs + h0.y * sn, h0.y * cs - h0.x * sn) + vec2(h0m.x * cs + h0m.y * sn, h0m.x * sn - h0m.y * cs);
	vec2 kn = kv / k;
	vec2 iht = vec2(-ht.y, ht.x);
	vec2 F0 = kn.x * vec2(ht.y, -ht.x) + kn.y * ht;            // -> (Dx, Dy) / -chop
	vec2 F1 = ht + (kv.x * kv.y / k) * iht;                      // -> (Dz, dDx/dy / -chop)
	vec2 F2 = kv.x * iht - kv.y * ht;                            // -> (dDz/dx, dDz/dy)
	vec2 F3 = (kv.x * kv.x / k) * ht + (kv.y * kv.y / k) * iht;  // -> (dDx/dx, dDy/dy) / -chop
	imageStore(outA, at3, vec4(F0, F1));
	imageStore(outB, at3, vec4(F2, F3));
}
