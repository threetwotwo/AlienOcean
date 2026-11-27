// swim.js v18 (swim skill: the record's swim.skill against the style's own; a poorer swimmer labours and its fins compensate, Gary 14 Nov 2026 03:23Z, gaits skillLaw); v17 (effortless slow swim, Gary 14 Nov 2026 03:14Z "looks like it's struggling a bit. Should be more effortless": phrase floor + glideF, the wave swells and eases and never stops; numbers in gaits phrase); v16 (slow-swim phrases: at slow speed a body-and-tail swimmer beats in short uneven phrases with a glide between, Style FE2 14 Nov 2026, gaits styles.<style>.phrase; cmd.phrase = 0 switches it off); v15 (fin life: no fin is ever still, Gary 14 Nov 2026 02:05Z; ported from the tuskfish's hero_motion fins + tail idle + alive layers); v14 (cowfish fin gaits: anal + dorsal sway with body rocking, Hove 2001; v13 fish_v3_2 with soft zones; v12 breathing + soft body; v11 reads blueprint swim block via make_model; v10 finFlow for edge flutter; v9 fish_v3 stand-ins; v8 turn wind-up, gaits windDeg; v7 species tempo + surge; v6 turn bend capped by gaits bendCurvMax, from the skin probe; v5 goby hops: burst sized to the hop length, glide, brake on landing; cmd.hold, cmd.hopBL; v4 idle wave: gaits idleHz keeps a slow body wave when stopped; v3 beat law with a speed offset, Bainbridge 1958; v2 recoil factor): one data-driven swim engine for every creature (node + browser). Reads a motion model (make_model.js) and gaits.json.
// Layers: (1) the record's body wave z = A L e^(alpha(s-1)) sin(2 pi (s/lam - phase)), behind the rigid front; phase is integrated
// (d phase/dt = f), so speed changes never pop. (2) turn bend: the body lies along its path curve (bendK). (3) Lighthill recoil: the
// sideways shape is shifted and turned so it carries no sideways momentum or turning moment (mass = body + added mass per station), which
// is what makes the head sway and the sway's smallest point. (4) the chain keeps its bone lengths. (5) pectorals row (labriform drive at
// low speed, folded at speed), each with its second joint lagging. Output: local joint rotations (glTF frame: snout +X, up +Y).
(function (root, f) { if (typeof module === "object") module.exports = f(); else root.SWIM = f(); })(this, function () {
  const D2R = Math.PI / 180, clamp = (x, a, b) => Math.max(a, Math.min(b, x));
  const sstep = (a, b, x) => { if (b <= a) return x >= b ? 1 : 0; const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
  function rng(seed) { let s = seed >>> 0 || 1; return () => { s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; }; }

  function resolveGait(model, gaits) {
    const m = model.motion || {};
    let style = m.gait || gaits.byPlan[model.plan];
    if (!style) style = (m.rigid || 0) >= 0.4 ? "ostraciiform" : (m.lam || 1) < 0.75 ? "anguilliform" : "subcarangiform";
    let g = Object.assign({}, gaits.styles[style]); if (g.base) g = Object.assign({}, gaits.styles[g.base], g);
    Object.assign(g, m.gaitOverrides || {}); g.style = style;
    if (gaits.finLife && !g.finLife) g.finLife = Object.assign({}, gaits.finLife);   // v15: every style has fin life unless it brings its own
    // v18 skill: the style's numbers are tuned for a swimmer of the style's own skill (g.skill); the record's swim.skill (model.motion.skill) moves a
    // species off it. Both and the law's numbers travel in the resolved gait.
    if (gaits.skillLaw && !g.skillLaw) g.skillLaw = Object.assign({}, gaits.skillLaw); if (g.skill != null) g.skillNow = m.skill != null ? m.skill : g.skill;
    if (gaits.personality && !g.personality) g.personality = Object.assign({}, gaits.personality);   // v17: the personality ranges travel in the resolved gait, as fin life does
    return g;
  }

  function Swimmer(model, gaits, opt) {
    opt = opt || {}; const M = model.motion, L = model.L; this.model = model; this.g = resolveGait(model, gaits); const g = this.g;
    this.M = M; this.L = L; this.rand = rng(opt.seed || 1);
    // v17 personality (Gary 14 Nov 2026 03:16Z "For variance/personality, it's a root fix for the universal builder"): every fish draws its own
    // temperament from its seed (own stream, seed ^ 0x2545f491), inside the ranges of gaits.personality: amp = how wide it swings, rate = how
    // quick its beat and paired fins, glide = how long it rests between phrases, fins = how lively its fins. opt.personality {amp, rate,
    // glide, fins} sets any of them by hand (art direction). No block in the gaits = all 1 (v16 to the bit).
    // v18 swim skill (Gary 14 Nov 2026 03:23Z: a species that is not a good swimmer may look laboured, "and other parts like pectorals to fill in
    // the imbalance/compensate. Like in juvenile cow fish, pectorals are fluttering much more"). d = style skill - this fish's skill (+ = a poorer
    // swimmer than the style's norm). A poorer swimmer: sharper, bigger beats with a deeper speed dip and more head sway (the body labours), and
    // faster, wider paired fins that keep rowing through the beats, livelier fins and more rocking (the fins compensate). d = 0 is v17 to the bit.
    { const SL = g.skillLaw, d = SL && g.skill != null ? clamp(g.skill - (opt.skill != null ? opt.skill : g.skillNow), SL.dMin, SL.dMax) : 0, k = (x, lo, hi) => SL ? clamp(1 + (x || 0) * d, lo, hi) : 1;
      this.sk = { d, dip: k(SL && SL.dip, 0.3, 4), soft: k(SL && -SL.sharp, 0.3, 1.3), amp: k(SL && SL.amp, 0.6, 1.6), recoil: k(SL && SL.recoil, 0.5, 3), pecHz: k(SL && SL.pecHz, 0.7, 2.2), pecSweep: k(SL && SL.pecSweep, 0.8, SL ? SL.pecSweepMax : 1), tuck: k(SL && -SL.tuck, 0, 1.5), rock: k(SL && SL.rock, 0.5, 3), fins: k(SL && SL.fins, 0.6, 1.6) }; }
    { const PR = g.personality, r = rng(((opt.seed || 1) ^ 0x2545f491) >>> 0), o = opt.personality || {}; for (let i = 0; i < 8; i++) r();   /* eight warm-up draws: the first xorshift outputs of neighbouring seeds lie close together */ const d = k => { const u = r(); return o[k] != null ? o[k] : PR && PR[k] ? PR[k][0] + (PR[k][1] - PR[k][0]) * u : 1; };
      this.pers = { amp: d("amp"), rate: d("rate"), glide: d("glide"), fins: d("fins") }; }
    // joints: names, parents, rest (metres), arc s of each joint
    const J = model.joints; this.J = J; const idx = {}; J.forEach((j, i) => idx[j.name] = i); this.idx = idx;
    this.chain = ["root", "head"].concat(J.filter(j => /^spine_\d+$/.test(j.name)).map(j => j.name).sort()).map(n => idx[n]);
    this.sJ = this.chain.map(i => -J[i].rest[0] / L);
    this.bone = this.chain.slice(1).map((ci, k) => { const a = J[this.chain[k]].rest, b = J[ci].rest; return Math.hypot(b[0] - a[0], b[2] - a[2]); });
    this.sRigid = Math.max(M.rigid || 0, this.sJ[2]);           // skull + first bone (the skull's points ride on 'head', so head's own bone must stay on the skull's line) or the record's rigid front
    // stations: mass for recoil
    const st = model.stations; this.st = st; let mt = 0, ms = 0; st.forEach(q => { q.m = q.body + q.added; mt += q.m; ms += q.m * q.s; });
    this.sc = ms / mt; this.mt = mt; let I = 0; st.forEach(q => I += q.m * (q.s - this.sc) ** 2); this.I = I;
    // v6: the turn bend may not stretch the skin past gaits skinStrain on the widest bending station (strain = curvature x half width)
    let wMax = 0; st.forEach(q => { if (q.s >= this.sRigid) wMax = Math.max(wMax, q.w / 2); }); this.kSkin = (g.skinStrain || 1e9) / Math.max(wMax, 1e-3);
    this.pecs = ["pectoralR_01", "pectoralL_01"].filter(n => n in idx).map(n => ({ j1: idx[n], j2: idx[n.replace("_01", "_02")], side: Math.sign(J[idx[n]].rest[2]) || 1, alt: n.includes("L") ? g.pecAlt : 0 }));
    // speed law: stride (L per beat) from the record's own cruise point; amplitude grows to full by ampU1
    this.stride = M.U / M.f;
    // v3 beat law: f(U) = f_rec (c + U) / (c + U_rec), c = gait fOffsetU (Bainbridge 1958 U = 0.75 f - 1 gives c = 1 L/s; Tytell 2004 eel f = 1.3 + 1.3 U)
    this.fc = this.g.fOffsetU == null ? 0 : this.g.fOffsetU;
    // state
    this.t = 0; this.U = opt.U0 || 0; this.f = this.U > 0.02 ? this.fOf(this.U) : 0; this.phase = 0; this.pecPhase = 0; this.psi = 0; this.yawRate = 0; this.yawAcc = 0;
    this.pos = [0, 0, 0];   // world position of the mass centre on the swim line (metres)
    this.y = 0; this.pitch = 0; this.bendCurv = 0;
    this.beh = { state: "free", t: 0, beats: 0, next: 0 };
    // v7 tempo: species speed wander (log-normal, OU), heading wander, and (cmd.auto) self-paced pauses and bursts
    let rs = opt.seed || 12345; this.rn = () => { rs = (rs * 16807) % 2147483647; return rs / 2147483647; };
    this.tempo = { w: 0, yw: 0, mode: "go", tEnd: 0 };
    this.wind = { quiet: 1, t0: -1, side: 0, peak: 0, w: 0 };
    // v14 median-fin gaits (gaits finGait; Hove 2001 boxfish: pectorals + anal at 0-1 L/s, dorsal + anal 1-5, caudal above): the dorsal
    // and anal twins sway sideways about their fin bases (rig.fins pivots) in a wave running front to back, tips to the same side, and
    // the rigid body rocks against them (snout excursion 0.7-3.8 % of length, Hove). Rig room per fin (fins.<fin>.sway) caps the angle.
    this.rockW = 1; this.finPhase = 0; this.median = [];
    if (g.finGait && model.finsRig) for (const [fin, R] of Object.entries(model.finsRig)) { const sign = /anal/.test(fin) ? -1 : 1; const n = R.joints.length;
      R.joints.forEach((nm, k) => { if (!(nm in idx)) return; const po = (R.pivot_offset_L || [])[k] || [0, 0, 0]; const room = Array.isArray(R.sway) ? R.sway[k] : (R.sway || 35);
        this.median.push({ fin, j: idx[nm], k, n, sign, piv: po.map(x => x * L), room: Math.abs(room) }); }); }
    // v15 fin life (Gary 14 Nov 2026 02:05Z "fins and tail ... at least rippling delicately when there's not much motion ... nothing
    // should stay perfectly still"): the tuskfish's hero_motion layers, by fin role for every fish. Median fins (rig.fins pivots): a
    // ripple running tailward along the fin (each ray leans sideways and lifts a little, a phase lag by its place along x, the front
    // rays least), each fin on its own frequency, size and wavelength, frequency and size wandering on slow OU (Ornstein-Uhlenbeck)
    // per fish. Caudal twins: an idle scull about the fin base (the tip lagging) and the lobes opening and closing. Pectorals: each on
    // its own clock and size (no two strokes alike). Pelvics: a slow OU lean. All strongest holding station, 0.3 of it at cruise, none
    // at burst. Its own random stream (seed ^ 0x5f1e3a7), so the tempo and hop draws are unchanged.
    const FL = g.finLife; this.life = null;
    if (FL) { const r = rng(((opt.seed || 1) ^ 0x5f1e3a7) >>> 0), lf = { r, fins: [], tail: null, pecs: [], pelv: [] };
      lf.gs = () => { const u = Math.max(1e-9, r()), v = r(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); };
      if (model.finsRig) for (const [fin, R] of Object.entries(model.finsRig)) { const ks = []; R.joints.forEach((nm, k) => { if (nm in idx) ks.push(k); }); if (ks.length < 2) continue;
        const x0 = J[idx[R.joints[ks[0]]]].rest[0], span = Math.max(1e-9, Math.abs(J[idx[R.joints[ks[ks.length - 1]]]].rest[0] - x0));
        const F = { fin, sign: /anal/.test(fin) ? -1 : 1, hz: FL.hz * (0.85 + 0.3 * r()), gain: 0.8 + 0.4 * r(), lam: FL.lam * (0.85 + 0.3 * r()) * L, ph: 2 * Math.PI * r(), xf: 0, xs: 0, rays: [] };
        for (const k of ks) { const j = idx[R.joints[k]], dx = Math.abs(J[j].rest[0] - x0), u = dx / span, po = (R.pivot_offset_L || [])[k] || [0, 0, 0], room = Array.isArray(R.sway) ? R.sway[k] : (R.sway || 35);
          F.rays.push({ j, dx, piv: po.map(x => x * L), room: Math.abs(room), tap: (0.5 + 0.5 * sstep(0, 0.6, u)) * (1 - 0.05 * sstep(0.8, 1, u)) }); }
        lf.fins.push(F); }
      const tw = nm => J.map((j, i) => [j.name, i]).filter(([n]) => new RegExp("^caudal" + nm + "_\\d+$").test(n)).sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0).map(([, i]) => i);
      const tU = tw("U"), tD = tw("D");
      if (tU.length || tD.length) { const b = J[(tU.length ? tU : tD)[0]].rest, piv = i => [b[0] - J[i].rest[0], b[1] - J[i].rest[1], b[2] - J[i].rest[2]];
        lf.tail = { U: tU.map(i => ({ j: i, piv: piv(i) })), D: tD.map(i => ({ j: i, piv: piv(i) })), hz: FL.tailHz * (0.8 + 0.4 * r()), ph: 2 * Math.PI * r(), ph2: 2 * Math.PI * r(), xf: 0, xs: 0 }; }
      for (const p of this.pecs) lf.pecs.push({ dph: 0, xf: 0, xs: 0 });
      J.forEach((j, i) => { const m2 = /^pelvic([RL]?)_01$/.exec(j.name); if (m2) lf.pelv.push({ j: i, side: Math.sign(j.rest[2]) || 1, x: 0 }); });
      this.life = lf; }
    // v16 slow-swim phrases (gaits styles.<style>.phrase; Style FE2 ruling 14 Nov 2026 on run sa183: below the gait's body-wave band the
    // snapper slid rigid). A body-and-tail swimmer asked to go slowly does not swim with a weak steady wave: it beats two or three times,
    // then glides with the tail trailing and the pectorals steering (burst-and-coast, Videler & Weihs 1982). Each phrase draws its beat
    // count, glide time and size from its own random stream (seed ^ 0x3c6ef372), never the same period twice running, and the speed
    // rises through the beats and falls through the glide about the asked speed (the mean is kept). Styles without a phrase block
    // (pectoral swimmers, the boxfish) keep the pectoral-only band.
    this.phr = null;
    if (g.phrase) this.phr = { r: rng(((opt.seed || 1) ^ 0x3c6ef372) >>> 0), a: 0, fk: 1, mode: 0, q: 0, n: 0, tg: 0, tl: 0, env: 0, k: 1, mUp: 0, mDn: 0, per: 0, hn: [0, 0, 0, 0, 0], ht: [0, 0, 0, 0, 0], hi: 0, count: 0 };
    // v12 breathing + soft body. Breathing: record.breathing {rate Hz, amp 0-1} (copied into the model by make_model), else
    // the M^-1/4 law (1 Hz at 0.2 kg); the throat drops (buccal pump) and the opercles flare a quarter cycle later.
    // Soft zones: joints soft_<id>_<k>; each a damped spring (f, zeta, peak from the zone's build, as cage/rig.js) driven by
    // the sideways acceleration of its station, so belly and throat lag each tail beat and settle after a stop.
    const Mkg = st.reduce((a2, q) => a2 + q.body, 0) * L * L * L / st.length * 1025, B = model.breathing || {};
    this.breath = { ph: 0, rate: B.rate || Math.pow(Math.max(Mkg, 1e-4) / 0.2, -0.25), amp: B.amp == null ? 0.7 : B.amp, mass: Mkg };
    this.throatJ = idx.throat; if (idx.throat != null) { const qs = st[Math.min(st.length - 1, Math.floor(clamp(-J[idx.throat].rest[0] / L, 0, 1) * st.length))]; this.throatDepth = Math.min(qs.d * L, 0.2 * L); }   /* deep-headed box: capped at 0.2 L of depth (fins sit close under the throat) */ this.opercles = ["opercleL", "opercleR"].filter(n => n in idx).map(n => ({ j: idx[n], side: Math.sign(J[idx[n]].rest[2]) || (n.endsWith("L") ? -1 : 1) }));
    const BUILD = { firm: [5, 0.55, 0.15], normal: [3.5, 0.45, 0.3], fatty: [2.5, 0.35, 0.5] }, zones = {}; (model.soft || []).forEach(z => zones[z.id] = z);
    this.soft = J.map((j, i) => { const m = /^soft_(.+)_(\d+)$/.exec(j.name); if (!m) return null; const z = zones[m[1]] || {}; const b = BUILD[z.build] || BUILD.normal, th = Math.min(0.5, Math.max(0.02, z.thickness == null ? 0.15 : z.thickness));
      const sj = clamp(-j.rest[0] / L, 0, 1), q = st[Math.min(st.length - 1, Math.floor(sj * st.length))]; const rad = (q.d + q.w) / 4 * L;
      return { j: i, s: sj, f: b[0] * Math.pow(0.15 / th, 0.25), zeta: b[1], peak: th * rad * b[2], x: 0, v: 0, hPrev: null, vPrev: 0 }; }).filter(Boolean);   // v8 turn wind-up (tuskfish hero_motion law)
  }
  const P = Swimmer.prototype;
  P.fOf = function (U) { const M = this.M; return M.f * (this.fc + U) / (this.fc + M.U); };
P.UOf = function (f) { const M = this.M; return Math.max(0, f * (this.fc + M.U) / M.f - this.fc); };
P.alpha = function (U) { const M = this.M; return clamp(M.alpha - (M.alphaSlope || 0) * (U - M.U), M.alphaMin || M.alpha, M.alphaMax || M.alpha); };
  P.finShare = function () { const FG = this.g.finGait, U = this.U; const an = Math.max(FG.hoverShare, sstep(FG.analU[0], FG.analU[1], U)), dor = sstep(FG.dorsalU[0], FG.dorsalU[1], U); return { anal: an, dorsal: dor, rk: Math.max(an * 0.6, dor) }; };
  // v16: the share of the record's body wave that plays now: the gait's own band, plus the phrase's beats inside the slow band
  P.waveW = function () { const bw = this.bodyWeight(this.U), z = this.phr; const fl = z ? Math.min(0.6, (this.g.phrase.floor || 0) * this.sk.soft) : 0; return z && z.a > 0 ? bw + (1 - bw) * z.a * (fl > 0 ? fl + (1 - fl) * z.env * z.k : z.env * z.k) * this.g.phrase.ampK * this.sk.amp : bw; };   /* v17: the wave never falls under the floor share in a glide */
  P.bodyWeight = function (U) { const g = this.g; return g.UlabBand > 0 ? sstep(g.Ulab - g.UlabBand, g.Ulab + g.UlabBand, U) : (U >= g.Ulab ? 1 : 0); };
  P.amp = function (U) { const g = this.g; return this.M.A * clamp(g.ampMin + (1 - g.ampMin) * U / g.ampU1, 0, 1) * this.pers.amp; };
  // cmd: {U: L/s wanted, yawRate: deg/s wanted (+ = left, toward -Z)}
  P.step = function (dt, cmd) {
    const g = this.g; cmd = cmd || {}; let Uc = clamp(cmd.U || 0, 0, g.Umax); let yawCmd = cmd.yawRate || 0;
    const tp = g.tempo; if (tp && cmd.tempo !== 0 && !(g.style === "perch-hop" && !cmd.swim)) { const T = this.tempo, gs = () => { const u = Math.max(1e-9, this.rn()), v = this.rn(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); };
      // OU wander: stationary sd = cv (speed, log) and yawSD (deg/s), correlation time T
      const a = Math.exp(-dt / tp.T), b = Math.sqrt(1 - a * a); T.w = a * T.w + b * tp.cv * gs(); T.yw = a * T.yw + b * tp.yawSD * gs();
      if (cmd.auto) { if (this.t >= T.tEnd) { const r = this.rn(), pr = tp.pauseRate * (T.mode === "go" ? 1 : 0), br = tp.burstRate * (T.mode === "go" ? 1 : 0);
          if (T.mode !== "go") { T.mode = "go"; T.tEnd = this.t + 0.5; } else if (r < pr * 0.5) { T.mode = "pause"; T.tEnd = this.t + tp.pause[0] + (tp.pause[1] - tp.pause[0]) * this.rn(); } else if (r < (pr + br) * 0.5) { T.mode = "burst"; T.tEnd = this.t + tp.burst[0] + (tp.burst[1] - tp.burst[0]) * this.rn(); } else T.tEnd = this.t + 0.5; }
        if (T.mode === "pause") Uc = 0; if (T.mode === "burst") Uc = Math.min(g.Umax, Uc * tp.burstK); }
      else T.mode = "go";
      if (Uc > 0.02) Uc = clamp(Uc * Math.exp(T.w - tp.cv * tp.cv / 2), 0, g.Umax); yawCmd += T.yw * (Uc > 0.02 ? 1 : 0.3); }
    if (g.style === "perch-hop" && !cmd.swim) Uc = this.hop(dt, cmd); else if (this.beh.state !== "free") { this.beh.state = "free"; }
    // beat frequency leads (thrust first), speed follows the thrust
    const fT = this.beh.state === "glide" || this.beh.state === "brake" ? 0 : (Uc > 0.02 ? Math.max(this.fOf(Uc), g.fMin) : (g.idleHz || 0)) * (this.beh.fK || 1);   // v4: an idle wave instead of a frozen pose
    this.f += (fT - this.f) * (1 - Math.exp(-dt / (this.beh.tauF || g.tauF)));
    const st = this.beh.state, coast = st === "glide" || st === "brake" || st === "perch"; const Uthrust = coast ? 0 : Math.min(this.UOf(this.f), st === "burst" ? 1e9 : g.Umax * 1.5);
    // v16 phrases: act = how far the asked speed sits inside the slow band (0 above the body-wave band, 0 at rest), eased so a stepped
    // command never pops the wave; while it is 0 and has died away this is v15 to the bit.
    const Pz = this.phr, PH = g.phrase; let act = 0, mSp = 0, beat = false;
    if (Pz) { if (cmd.phrase !== 0 && st === "free") act = (1 - this.bodyWeight(Uc)) * sstep(PH.U[0], PH.U[1], Uc);
      if (act > 0 || Pz.a > 0) { Pz.a += (act - Pz.a) * (1 - Math.exp(-dt / PH.tauA)); if (act === 0 && Pz.a < 1e-4) { Pz.a = 0; Pz.env = 0; Pz.mode = 0; Pz.tl = 0; } }
      if (Pz.a > 0) { const fb = Math.max(this.f * PH.fK * Pz.fk * this.pers.rate, g.fMin);
        if (Pz.mode === 0) { Pz.tl -= dt; if (Pz.tl <= 0) {   // a new phrase: beats, glide and size, redrawn while it would repeat a recent one
            const r = Pz.r; let n = 0, tg = 0, per = 0, fb2 = fb;
            for (let tr = 0; tr < 8; tr++) { Pz.fk = PH.fVar[0] + (PH.fVar[1] - PH.fVar[0]) * r(); fb2 = Math.max(this.f * PH.fK * Pz.fk * this.pers.rate, g.fMin); n = PH.beats[Math.min(PH.beats.length - 1, Math.floor(r() * PH.beats.length))]; tg = (PH.glide[0] + (PH.glide[1] - PH.glide[0]) * r()) * this.pers.glide; per = n / fb2 + tg;
              let rpt = Pz.count > 0 && Math.abs(per - Pz.per) < PH.differ * Pz.per; for (let i = 0; i < 5 && !rpt; i++) if (Pz.hn[i] === n && Math.abs(Pz.ht[i] - tg) < 0.12) rpt = true; if (!rpt) break; }
            Pz.n = n; Pz.tg = tg; Pz.per = per; Pz.hn[Pz.hi] = n; Pz.ht[Pz.hi] = tg; Pz.hi = (Pz.hi + 1) % 5; Pz.count++;
            Pz.k = PH.ampVar[0] + (PH.ampVar[1] - PH.ampVar[0]) * r(); Pz.q = 0; Pz.mode = 1;
            const tb = n / fb2; Pz.mDn = Math.min(PH.speedDn * this.sk.dip, PH.speedK * this.sk.dip * tb / tg); Pz.mUp = Pz.mDn * tg / tb; } }
        if (Pz.mode === 1) { beat = true; mSp = Pz.mUp; Pz.q += fb * dt; Pz.env = sstep(0, PH.rise * this.sk.soft, Pz.q) * (1 - sstep(Pz.n - PH.fall * this.sk.soft, Pz.n, Pz.q)); if (Pz.q >= Pz.n) { Pz.mode = 0; Pz.tl = Pz.tg; Pz.env = 0; } }
        else mSp = -Pz.mDn;
        this.U += (Uthrust * (1 + Pz.a * mSp) - this.U) * (1 - Math.exp(-dt / (this.beh.tauU || g.tauU)));
        const bw = this.bodyWeight(this.U), gF = PH.glideF || 0;   /* v17: with glideF the beat rate eases with the envelope and the wave keeps trailing slowly through the glide */
        this.phase += beat ? fb * dt * (gF > 0 ? gF + (1 - gF) * Pz.env : 1) * (bw + (1 - bw) * Pz.a) : this.f * dt * bw + fb * gF * dt * (1 - bw) * Pz.a; } }
    if (!Pz || !(Pz.a > 0)) {
    this.U += (Uthrust - this.U) * (1 - Math.exp(-dt / (this.beh.tauU || g.tauU)));
    this.phase += this.f * dt * this.bodyWeight(this.U); }
    // the body-wave phase only runs while the body drives; pectorals run their own clock
    const fp = (g.pecHz0 + g.pecHzK * this.U) * this.pers.rate * this.sk.pecHz; this.pecPhase += fp * dt;
    if (this.life) this.lifeStep(dt, fp);
    if (this.median.length) { const FG = g.finGait; this.finHz = this.U > 0.05 ? Math.max(this.fOf(this.U), FG.hoverHz) : FG.hoverHz; this.finPhase += this.finHz * dt; const ayc = Math.abs((cmd.yawRate || 0) * D2R); this.rockW += ((1 - sstep(0.06, 0.15, ayc)) - this.rockW) * Math.min(1, dt / 0.08); }   /* v14: the rocking fades while a turn is wanted (it would hide the wind-up) */
    // turning: wanted yaw rate limited by the gait's tightest radius, eased (2nd order)
    let yc = yawCmd * D2R; const lim = Math.min(g.yawRateMax * D2R, Math.max(g.rMin > 0 ? this.U / g.rMin : 1e9, g.yawRateHover * D2R));
    yc = clamp(yc, -lim, lim);
    // v8 wind-up: a turn asked from straight (a quarter second under 0.06 rad/s, then past 0.15) first swings the head the
    // other way, most at 90 ms, and the turn waits until it has peaked; small turns get a small wind-up (full from 0.6 rad/s)
    const Wd = this.wind; if ((g.windDeg > 0 || g.windYaw > 0) && cmd.wind !== 0) { const ay = Math.min(Math.abs((cmd.yawRate || 0) * D2R), lim);   /* intent, not the tempo wander */
      if (Wd.t0 < 0) { if (ay < 0.06) Wd.quiet += dt; else if (ay > 0.15 && Wd.quiet >= 0.25) { Wd.t0 = this.t; Wd.side = -Math.sign(cmd.yawRate); Wd.peak = 0; } if (ay >= 0.06) Wd.quiet = 0; }
      if (Wd.t0 >= 0) { const u = this.t - Wd.t0; if (u > 0.2) { Wd.t0 = -1; Wd.w = 0; Wd.quiet = 0; } else { Wd.peak = Math.max(Wd.peak, ay); Wd.w = sstep(0, 0.09, u) * (1 - sstep(0.09, 0.2, u)) * sstep(0.15, 0.6, Wd.peak); yc = yc * sstep(0.06, 0.15, u) + Wd.side * Wd.w * (g.windYaw || 0) * D2R; }   /* rigid bodies wind up by a small counter-yaw */ } }
    else Wd.w = 0;
    const w = 1 / g.tauYaw;
    this.yawAcc += (w * w * (yc - this.yawRate) - 2 * w * this.yawAcc) * dt; this.yawRate += this.yawAcc * dt;
    this.psi += this.yawRate * dt;
    const v = this.U * this.L * (1 + (this.g.surge || 0) * this.bodyWeight(this.U) * Math.cos(4 * Math.PI * this.phase)); /* v7: speed surges twice a beat (one push per tail stroke) */ this.pos[0] += Math.cos(this.psi) * v * dt; this.pos[2] -= Math.sin(this.psi) * v * dt;
    { const Bt = this.breath; this.breathRate = Bt.rate * (1 + 0.3 * sstep(0.5, 2, this.U)); Bt.ph += this.breathRate * dt; }   // v12: breathe faster when working
    this.t += dt;
  };
  // v15 fin life clocks: OU wander (exact discretisation, stationary sd = the gait's CV) and phases; called from step()
  P.lifeStep = function (dt, fp) {
    const FL = this.g.finLife, lf = this.life, gs = lf.gs;
    const af = Math.exp(-dt / FL.tauF), bf = Math.sqrt(1 - af * af), as = Math.exp(-dt / FL.tauS), bs = Math.sqrt(1 - as * as), ap = Math.exp(-dt / FL.tauP), bp = Math.sqrt(1 - ap * ap);
    for (const F of lf.fins) { F.xf = af * F.xf + bf * FL.periodCV * gs(); F.xs = as * F.xs + bs * FL.sizeCV * gs(); F.ph += 2 * Math.PI * F.hz * Math.max(0.55, 1 + F.xf) * dt; }
    const T = lf.tail; if (T) { T.xf = af * T.xf + bf * FL.periodCV * gs(); T.xs = as * T.xs + bs * FL.sizeCV * 1.5 * gs(); T.ph += 2 * Math.PI * T.hz * Math.max(0.5, 1 + T.xf) * dt; T.ph2 += 2 * Math.PI * 0.37 * T.hz * dt; }
    for (const p of lf.pecs) { p.xf = af * p.xf + bf * FL.pecPeriodCV * gs(); p.xs = as * p.xs + bs * FL.pecSizeCV * gs(); p.dph += fp * p.xf * dt; }
    for (const p of lf.pelv) p.x = ap * p.x + bp * FL.pelvicDeg * gs();
  };
  // v15: how much fin life shows at this speed (all of it holding station, 0.3 at cruise, none at burst)
  P.lifeEnv = function () { const FL = this.g.finLife, U = this.U; return (0.3 + 0.7 * (1 - sstep(FL.stillU[0], FL.stillU[1], U))) * (1 - sstep(FL.burstU[0], FL.burstU[1], U)) * this.pers.fins * this.sk.fins; };
  // goby: perch on the bottom, burst a few beats, glide, land. Returns the speed wanted now.
  P.hop = function (dt, cmd) {
    // v5: a hop = burst (fixed time, speed sized so the hop covers hopBL), glide (drag), brake on landing (pectorals spread)
    const g = this.g, b = this.beh, r = this.rand; b.t += dt; const ez = tau => 1 - Math.exp(-dt / tau);
    const rest = () => g.hopRest[0] + r() * (g.hopRest[1] - g.hopRest[0]);
    if (b.state === "free") { b.state = "perch"; b.next = rest(); b.t = 0; }
    if (b.state === "perch") { b.fK = 1; b.tauU = null; b.tauF = null; this.y += (0 - this.y) * ez(0.12);
      if ((!cmd.hold && b.t > b.next) || cmd.go) { const BL = cmd.hopBL || g.hopBL;
        b.Ub = (g.hopCal || 1) * BL * (cmd.hopBL ? 1 : 0.7 + 0.6 * r()) / (g.hopBurst - g.hopTauU + g.glide * (1 - g.glideEnd) + g.glideEnd * g.brakeTau);
        b.beats = Math.max(1, Math.round(this.fOf(b.Ub) * g.hopBurst)); b.state = "burst"; b.t = 0; b.x0 = this.pos.slice(); }
      return 0; }
    if (b.state === "burst") { b.tauU = g.hopTauU; b.tauF = 0.03; this.y += (g.hopLift - this.y) * ez(0.08); if (b.t >= g.hopBurst) { b.state = "glide"; b.t = 0; } return b.Ub; }
    if (b.state === "glide") { b.tauU = g.glide; this.f *= Math.exp(-dt / 0.05); this.y += (0 - this.y) * ez(0.12); if (this.U < g.glideEnd * b.Ub) { b.state = "brake"; b.t = 0; } return 0; }
    if (b.state === "brake") { b.tauU = g.brakeTau; this.f *= Math.exp(-dt / 0.03); this.y += (0 - this.y) * ez(0.05); if (this.U < 0.05) { b.state = "perch"; b.t = 0; b.next = rest(); } return 0; }
    return 0;
  };
  // sideways shape h(s) in L (body frame, + = +Z) before recoil
  P.hRaw = function (s) {
    const U = this.U, M = this.M, sr = this.sRigid; const A = this.amp(U) * this.waveW(), al = this.alpha(U), lam = M.lam;
    const wave = ss => A * Math.exp(al * (ss - 1)) * Math.sin(2 * Math.PI * (ss / lam - this.phase));
    let h;
    if (s >= sr) h = wave(s); else { const e = 1e-3; const h0 = wave(sr), d = (wave(sr + e) - h0) / e; h = h0 + d * (s - sr); }
    // turn bend: lie along the path circle (curvature = yaw rate / speed), only the flexible part bends
    const Ueff = Math.max(this.U, 0.25); let kap = this.yawRate / Ueff; const kmax = Math.min(this.g.bendCurvMax || 1e9, this.kSkin, 1 / Math.max(this.g.rMin, 0.3)); kap = clamp(kap * this.g.bendK, -kmax, kmax); if (this.wind.w) kap = clamp(kap + this.wind.side * this.wind.w * (this.g.windDeg * D2R) / Math.max(this.sc - this.sRigid, 0.1), -kmax, kmax);   // v9: the wind-up counter-bend obeys the skin cap too   // v8: wind-up counter-bend, head angle about windDeg   // v6: the cap is on the drawn bend, set so the skin stays inside its stretch limit
    const d = s - this.sc, dr = this.sRigid - this.sc;   // rigid front: tangent line of the circle
    const hb = s >= this.sRigid ? -0.5 * kap * d * d : -0.5 * kap * dr * dr - kap * dr * (s - this.sRigid);
    return h + hb;
  };
  // full pose: chain points in the body frame (x forward = +X, metres), recoil applied, bone lengths kept
  P.shape = function () {
    const st = this.st, sc = this.sc; let a = 0, b = 0;
    for (const q of st) { const h = this.hRaw(q.s); a += q.m * h; b += q.m * h * (q.s - sc); }
    a /= this.mt; b /= this.I; const kr = this.M.recoil != null ? this.M.recoil : (this.g.recoil == null ? 1 : this.g.recoil);   /* v11: a model may carry its own recoil share, fitted to its blueprint snout sway */ a *= kr * this.sk.recoil; b *= kr * this.sk.recoil;   // v2: the water's sideways resistance holds part of the recoil
    // v14: the rigid body rocks against the median fins' sideways push (a yaw about the mass centre, after recoil)
    let rock = 0; if (this.median.length) { const FG = this.g.finGait; rock = FG.rockDeg * this.sk.rock * D2R * this.finShare().rk * this.rockW * Math.sin(2 * Math.PI * (this.finPhase + 0.5)); } this.rock = rock;
    const hS = s => this.hRaw(s) - a - b * (s - sc) - rock * (s - sc);
    const sJ = this.sJ, L = this.L, pts = [];
    let x = (sc - sJ[0]) * L, z = hS(sJ[0]) * L; pts.push([x, z]); const ang = [];
    for (let k = 1; k < sJ.length; k++) {
      const dx = -(sJ[k] - sJ[k - 1]) * L, dz = (hS(sJ[k]) - hS(sJ[k - 1])) * L, n = Math.hypot(dx, dz);
      x += dx / n * this.bone[k - 1]; z += dz / n * this.bone[k - 1]; pts.push([x, z]); ang.push(Math.atan2(dz, -dx));
    }
    return { pts, ang, hS };
  };
  // joint outputs: world root transform + local rotations (yaw about +Y for the chain, pectoral sweep/flap)
  P.pose = function () {
    const g = this.g, sh = this.shape(), J = this.J, rot = new Array(J.length).fill(null).map(() => [0, 0, 0, 1]);
    const qy = th => [0, Math.sin(th / 2), 0, Math.cos(th / 2)];
    const qmul = (a, b) => [a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1], a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0], a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3], a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]];
    const ch = this.chain; let prev = 0;
    for (let k = 0; k < ch.length - 1; k++) { const th = sh.ang[k]; rot[ch[k]] = qy(th - prev); prev = th; }
    // pectorals: posture (spread at rest, folded at speed) + rowing; second joint lags
    const U = this.U, perched = this.beh.state === "perch";
    const drive = 1 - this.bodyWeight(U) * 0.85; const fold = sstep(g.pecFoldU * 0.6, g.pecFoldU, U) * (this.beh.state === "burst" || this.beh.state === "glide" ? 1 : 1);
    this.pecFoldNow = fold; const post = (g.pecSpread * (1 - fold) - g.pecFold * fold) * D2R; const tuck = this.phr && this.phr.a > 0 ? 1 - g.phrase.pecTuck * this.sk.tuck * this.phr.a * this.phr.env : 1;   /* v16: the pectorals draw in while the tail beats and open again for the glide */
    const amp0 = g.pecSweep * this.sk.pecSweep * D2R * Math.max(drive, perched ? 0.6 : 0.25) * (1 - fold * 0.9) * tuck;
    const lf = this.life;
    for (let pi = 0; pi < this.pecs.length; pi++) { const p = this.pecs[pi], lp = lf ? lf.pecs[pi] : null;
      const ph = 2 * Math.PI * (this.pecPhase + p.alt + (lp ? lp.dph : 0)), amp = amp0 * (lp ? Math.min(1, Math.max(0.4, 1 + lp.xs)) : 1);   /* v15: each pectoral on its own clock and size, never past the gait's sweep (a bigger stroke folded the r22 pectoral, 115 flipped faces) */
      const sw = post * tuck + amp * Math.sin(ph), fl = amp * g.pecFlap * Math.cos(ph);
      const q1 = qmul(qy(p.side * sw), [Math.sin(p.side * fl / 2), 0, 0, Math.cos(p.side * fl / 2)]);
      rot[p.j1] = q1; const sw2 = 0.6 * amp * Math.sin(ph - g.pecLag * D2R); rot[p.j2] = qy(p.side * sw2);
    }
    // root (snout joint) in world: swim-line frame + the chain's first point
    const c = Math.cos(this.psi), s = Math.sin(this.psi), p0 = sh.pts[0];
    const rootPos = [this.pos[0] + c * p0[0] + s * p0[1], this.y * this.L, this.pos[2] - s * p0[0] + c * p0[1]];
    const rootQ = qmul(qy(this.psi), rot[ch[0]]); rot[ch[0]] = rootQ;
    const off = new Array(J.length).fill(null);
    // median fins: the gait's sway (v14, boxfish) and the v15 life ripple add per ray; each ray turns about its fin-base pivot
    const qx = th => [Math.sin(th / 2), 0, 0, Math.cos(th / 2)], qz = th => [0, 0, Math.sin(th / 2), Math.cos(th / 2)];
    const turnAbout = (j, q, p) => { rot[j] = q; const [x, y, z, w] = q; const ix = w * p[0] + y * p[2] - z * p[1], iy = w * p[1] + z * p[0] - x * p[2], iz = w * p[2] + x * p[1] - y * p[0], iw = -x * p[0] - y * p[1] - z * p[2];
      const rp = [ix * w + iw * -x + iy * -z - iz * -y, iy * w + iw * -y + iz * -x - ix * -z, iz * w + iw * -z + ix * -y - iy * -x]; off[j] = [p[0] - rp[0], p[1] - rp[1], p[2] - rp[2]]; };   // A(-p) + p
    const lean = new Map(), lift = new Map(), piv = new Map(), share = {};
    if (this.median.length) { const FG = g.finGait, sh2 = this.finShare();
      for (const q of this.median) { const sv = /anal/.test(q.fin) ? sh2.anal : /dorsal/.test(q.fin) ? sh2.dorsal : 0; share[q.fin] = sv; if (!sv) continue;
        const th = q.sign * Math.min(FG.deg * sv, q.room * 0.9) * D2R * Math.sin(2 * Math.PI * (this.finPhase - FG.lag * q.k / Math.max(1, q.n - 1)));
        lean.set(q.j, th); piv.set(q.j, q.piv); } }
    const env = lf ? this.lifeEnv() : 0, FL = g.finLife;
    if (lf && env > 0) for (const F of lf.fins) { const A = env * (1 - (share[F.fin] || 0)) * F.gain * Math.max(0.2, 1 + F.xs);
      for (const ra of F.rays) { const th = F.ph - 2 * Math.PI * ra.dx / F.lam;
        lean.set(ra.j, (lean.get(ra.j) || 0) + F.sign * Math.min(FL.deg * A * ra.tap, ra.room * 0.9) * D2R * Math.sin(th));
        lift.set(ra.j, F.sign * FL.raiseDeg * A * ra.tap * D2R * Math.cos(th)); piv.set(ra.j, ra.piv); } }
    for (const [j, p] of piv) { const a = lean.get(j) || 0, b = lift.get(j) || 0; turnAbout(j, b ? qmul(qz(b), qx(a)) : qx(a), p); }
    // v15 caudal life: the twins scull about the fin base (the first twin's place), the tip lagging, and the lobes open and close
    if (lf && lf.tail && env > 0) { const T = lf.tail, A = env * Math.max(0.25, 1 + T.xs), sp = FL.spreadDeg * D2R * A * Math.sin(T.ph2);
      for (const [lobe, sg] of [[T.U, 1], [T.D, -1]]) { const n = lobe.length;
        lobe.forEach((tq, k) => { const yaw = FL.tailDeg * D2R * A * ((k + 1) / n) * Math.sin(T.ph - 2 * Math.PI * FL.tailLag * k / Math.max(1, n - 1));
          turnAbout(tq.j, qmul(qz(sg * sp), qy(yaw)), tq.piv); }); } }
    // v15 pelvics: a slow OU lean about their own joint
    if (lf && env > 0) for (const p of lf.pelv) rot[p.j] = qmul(rot[p.j], qy(p.side * p.x * env * D2R));
    { const Bt = this.breath, ram = 1 - 0.5 * sstep(1, 2.5, this.U), c = 0.5 - 0.5 * Math.cos(2 * Math.PI * Bt.ph), c2 = 0.5 - 0.5 * Math.cos(2 * Math.PI * (Bt.ph - 0.25)), a = Bt.amp * ram * (this.beh.breathK || 1);
      if (this.throatJ != null) off[this.throatJ] = [0, -(g.throatDropD == null ? 0.04 : g.throatDropD) * this.throatDepth * a * c, 0];   /* v13: the drop scales with the head's own depth (a slender eel throat overstretched at 1 % of L) */
      for (const o of this.opercles) rot[o.j] = qmul(rot[o.j], qy(o.side * (g.opercleFlare == null ? 6 : g.opercleFlare) * D2R * a * c2)); }
    if (this.soft.length) { const tNow = this.t, dt = this.softT == null ? 0 : Math.min(0.05, tNow - this.softT); this.softT = tNow;
      for (const q of this.soft) { const h = sh.hS(q.s) * this.L; if (dt > 0 && q.hPrev != null) { const vel = (h - q.hPrev) / dt, acc = (vel - q.vPrev) / dt, w0 = 2 * Math.PI * q.f; const sub = 4, h2 = dt / sub;
          for (let k = 0; k < sub; k++) { q.v += (-(g.softDrive == null ? 0.2 : g.softDrive) * acc - 2 * q.zeta * w0 * q.v - w0 * w0 * q.x) * h2; q.x += q.v * h2; } q.vPrev = vel; }
        q.hPrev = h; off[q.j] = [0, 0, q.peak * Math.tanh(q.x / Math.max(q.peak, 1e-9))]; } }   /* soft limit: skin stretches but never past the zone's peak */
    return { rootPos, rot, shape: sh, off };
  };
  // forward kinematics: world positions of every joint (metres) from a pose
  // v10 fin flow (for the Emotion thread's edge flutter): per fin, the water speed past its edge (L/s, from the fin joints'
  // own world motion, so strokes and the tail beat count), the flow direction in the body frame (ripple travels downstream),
  // flutter f = 0.3 U_mps / tip chord (edge Strouhal, floor finFlutterMin Hz, cap 25), amplitude share a and fold 0-1.
  // Call once per frame after step(), with that frame's dt and fk result. Later: subtract flowAt() (ambient current).
  P.finFlow = function (dt, fkr) {
    const J = this.J, L = this.L, W = (fkr || this.fk(this.pose())).W, g = this.g;
    if (!this.finSets) { this.finSets = {}; J.forEach((j, i) => { const m = /^([A-Za-z]+)_(\d+)$/.exec(j.name); if (!m || m[1] === "spine") return;   /* any fin twin set in the rig role map (dorsal, anal, caudalU/D, foldU/D, ...) */ const k = m[1].startsWith("caudal") ? "caudal" : m[1]; (this.finSets[k] = this.finSets[k] || []).push(i); });
      this.finChord = {}; for (const k in this.finSets) { const ix = this.finSets[k]; let span = 0; ix.forEach(a => ix.forEach(b => { span = Math.max(span, Math.hypot(J[a].rest[0] - J[b].rest[0], J[a].rest[1] - J[b].rest[1], J[a].rest[2] - J[b].rest[2])); }));
        this.finChord[k] = /^pect|^pelv/.test(k) ? Math.max(0.02 * L, span) : clamp(0.25 * span, 0.02 * L, 0.06 * L);   /* median fins: edge chord ~ fin height, not fin length */ } this.finPrev = null; }
    const out = {}, prev = this.finPrev, c = Math.cos(this.psi), sn = Math.sin(this.psi), fmin = g.finFlutterMin == null ? 1 : g.finFlutterMin;
    for (const k in this.finSets) { const ix = this.finSets[k]; let vx = 0, vy = 0, vz = 0, sp = 0;
      ix.forEach(i => { if (!prev || !(dt > 0)) return; const a = W[i], b = prev[i]; const dx = (a[0] - b[0]) / dt, dy = (a[1] - b[1]) / dt, dz = (a[2] - b[2]) / dt; vx += dx; vy += dy; vz += dz; sp = Math.max(sp, Math.hypot(dx, dy, dz)); });
      const n = Math.hypot(vx, vy, vz) || 1, U = sp / L;   // world -> body: water flows opposite to the fin's motion
      const dir = prev ? [-(c * vx - sn * vz) / n, -vy / n, -(sn * vx + c * vz) / n] : [-1, 0, 0];
      const fold = /^pectoral/.test(k) ? (this.pecFoldNow || 0) : 0;
      const a = (0.08 + 0.92 * sstep(0.05, 1.5, U)) * (1 - 0.85 * fold);
      out[k] = { U: +U.toFixed(4), dir: dir.map(x => +x.toFixed(3)), f: +clamp(0.3 * sp / this.finChord[k], fmin, 25).toFixed(3), a: +a.toFixed(3), fold: +fold.toFixed(3) }; }
    this.finPrev = W.map(w => w.slice()); return out;
  };
  P.fk = function (pose) {
    const J = this.J, W = new Array(J.length), Q = new Array(J.length);
    const rotv = (q, v) => { const [x, y, z, w] = q; const ix = w * v[0] + y * v[2] - z * v[1], iy = w * v[1] + z * v[0] - x * v[2], iz = w * v[2] + x * v[1] - y * v[0], iw = -x * v[0] - y * v[1] - z * v[2];
      return [ix * w + iw * -x + iy * -z - iz * -y, iy * w + iw * -y + iz * -x - ix * -z, iz * w + iw * -z + ix * -y - iy * -x]; };
    const qmul = (a, b) => [a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1], a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0], a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3], a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]];
    const idx = this.idx;
    for (let i = 0; i < J.length; i++) {
      const j = J[i];
      if (j.parent == null) { W[i] = pose.rootPos.slice(); W[i][1] += j.rest[1]; Q[i] = pose.rot[i]; continue; }
      const pi = idx[j.parent], pr = J[pi].rest, o = pose.off && pose.off[i]; const lt = [j.rest[0] - pr[0] + (o ? o[0] : 0), j.rest[1] - pr[1] + (o ? o[1] : 0), j.rest[2] - pr[2] + (o ? o[2] : 0)];   /* v12: joint offsets (throat, soft) */
      const r = rotv(Q[pi], lt); W[i] = [W[pi][0] + r[0], W[pi][1] + r[1], W[pi][2] + r[2]]; Q[i] = qmul(Q[pi], pose.rot[i]);
    }
    return { W, Q };
  };
  return { Swimmer, resolveGait };
});
