// Golden trace from Gary's Thalassa v20.19 core/character-brain.js (CharacterBrain.update + registerSoundEvent).
// Usage: node brain_trace.mjs <thalassa core dir> <out.json>. Replayed by tests/test_golden_brain.gd.
// Five scripted 25 s sense sequences at 60 Hz. Every input is an analytic function of t (no randomness: the brain itself
// has none), mirrored line for line in the GDScript test (BrainScenes there):
//   swim_pois   swimming slowly past an arch, a moving fish, a companion, a vent behind a rock, a vessel behind her;
//               terrain + collider line of sight; three sounds (one urgent from behind, one companion chirp)
//   walk_idle   standing still on land: breath-synced contrapposto and idle glances, a console, then a gull close in
//               front (a focus switch past the hysteresis), an urgent sound over the gull, two quiet ones
//   walk_move   walking, running (playful breath), a jump (objective focus), a sustained turn, POIs along the way
//   swim_touch  slow swim beside a wall (hand brush), a sprint (touch released), a water-crossing objective, a shake
//   swim_intent hovering with the camera held on a fish (focus intent), the fish relocates (memory refresh), sounds
// Sampled every 3rd tick: gaze, tilt, torso yaw, hip shift, lean, breath (phase, signal, amp, rate), gaze blend,
// focus label, both hands' touch weight and target, mood, state, visible POI count.
import { pathToFileURL } from 'url';
import fs from 'fs';
const dir = process.argv[2], out = process.argv[3];
const { CharacterBrain } = await import(pathToFileURL(dir + '/character-brain.js').href);

const fwd = (yaw, pitch) => [-Math.sin(yaw) * Math.cos(pitch), Math.sin(pitch), -Math.cos(yaw) * Math.cos(pitch)];
const right = (yaw) => [Math.cos(yaw), 0, -Math.sin(yaw)];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const scl = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
const floorH = (x, z) => -9.0 + 1.2 * Math.sin(0.13 * x) + 0.8 * Math.cos(0.11 * z);
const colliders = [{ x: -4, y: -6, z: -22, r: 2.5 }, { x: 2.5, y: -5.4, z: -11, r: 1.6 }];
const WALL_X = 1.0;
const wallQuery = (p, r, filter) => {
  const d = WALL_X - p[0];
  if (d < 0 || d > r) return null;
  const pt = [WALL_X, p[1], p[2]], n = [-1, 0, 0];
  if (filter && !filter(pt[0], pt[1], pt[2], n[0], n[1], n[2])) return null;
  return { dist: d, point: pt, normal: n, id: 'wall' };
};
const win = (t, a, b) => t >= a && t < b;

// each scene: init() -> state, step(st, t, dt) -> { ctx, sounds: [[kind, pos, intensity, maxAge]] }
const scenes = {
  swim_pois: {
    init: () => ({}),
    step: (st, t) => {
      const head = [0.3 * Math.sin(0.2 * t), -5 + 0.4 * Math.sin(0.15 * t), -0.5 * t];
      const yaw = 0.35 * Math.sin(0.25 * t), pitch = -0.1 + 0.08 * Math.sin(0.4 * t);
      const f = fwd(yaw, pitch), r = right(yaw), u = cross(r, f);
      const kora = add(head, [2 * Math.cos(0.3 * t), 1, -6 + 2 * Math.sin(0.3 * t)]);
      const pois = [
        { id: 'arch_0', kind: 'arch', label: 'Coral Arch', pos: [-5, -4, -18], priority: 0.74, selfRadius: 2.2, maxRange: 54 },
        { id: 'fish_3', kind: 'fauna', label: 'Reef Fish', pos: [3 + 4 * Math.cos(0.5 * t), -4.5 + Math.sin(0.7 * t), -14 - 0.3 * t + 4 * Math.sin(0.5 * t)], priority: 0.87, moving: true, selfRadius: 0.65, maxRange: 44 },
        { id: 'vent_0', kind: 'vent', label: 'Thermal Vent', pos: [6, -6, -30], priority: 0.80, selfRadius: 2.2, maxRange: 52 },
        { id: 'boat', kind: 'vessel', label: 'Boat', pos: [0, -5, 12], priority: 0.82, maxRange: 54 },
        { id: 'kora_01', kind: 'kora', label: 'KORA-01', pos: kora, priority: 0.96, moving: true, maxRange: 54 },
      ];
      const sounds = [];
      if (st.k === 360) sounds.push(['ping', add(head, [8, 0, -4]), 0.6, 1.8]);
      if (st.k === 780) sounds.push(['impact', add(head, [-5, 1, 2]), 0.9, 1.8]);
      if (st.k === 1140) sounds.push(['kora_chirp', kora, 0.5, 1.8]);
      return { sounds, ctx: { mode: 'swim', headPos: head, bodyFwd: f, bodyRight: r, bodyUp: u, visionFwd: f, visionRight: r, visionUp: u,
        cameraFwd: fwd(yaw + 0.05 * Math.sin(t), pitch), desiredLookDir: f, speed: 0.5, desSpeed: 0.5,
        yawRate: 0.35 * 0.25 * Math.cos(0.25 * t), getFloorHeight: floorH, colliders, pois } };
    }
  },
  walk_idle: {
    init: () => ({}),
    step: (st, t) => {
      const head = [0, 1.32, 0];
      const f = fwd(0, -0.05), r = right(0), u = cross(r, f);
      const pois = t > 4 ? [{ id: 'console', kind: 'console', label: 'Console', pos: [1.5, 1.0, -4], priority: 0.78, maxRange: 18 }] : [];
      if (t > 11) pois.push({ id: 'gull', kind: 'fauna', label: 'Gull', pos: [-0.6 + 0.3 * Math.sin(t), 1.45, -3.2], priority: 0.9, moving: true, maxRange: 32 });
      const sounds = [];
      if (st.k === 300) sounds.push(['door', [3, 1.3, -1], 0.55, 1.8]);
      if (st.k === 960) sounds.push(['warn', [-4, 1.3, -2], 0.85, 2.2]);
      if (st.k === 1020) sounds.push(['door', [3, 1.3, -1], 0.55, 1.8]);
      return { sounds, ctx: { mode: 'deck_walk', headPos: head, bodyFwd: [0, 0, -1], bodyRight: r, bodyUp: [0, 1, 0],
        visionFwd: f, visionRight: r, visionUp: u, cameraFwd: f, desiredLookDir: f, speed: 0, desSpeed: 0, yawRate: 0,
        getFloorHeight: (x, z) => 0.0, crouchBlend: 0, pois } };
    }
  },
  walk_move: {
    init: () => ({ pos: [0, 0, 0], yaw: 0 }),
    step: (st, t, dt) => {
      const sp = (tt) => tt < 3 ? 0 : (tt < 10 ? 1.2 : (tt < 14 ? 2.4 : (tt < 16 ? 0 : 0.8)));
      const yawRate = win(t, 20, 21) ? 1.5 : 0.09 * Math.cos(0.18 * t);
      st.yaw += yawRate * dt;
      const speed = sp(t);
      const bf = [-Math.sin(st.yaw), 0, -Math.cos(st.yaw)];
      st.pos = add(st.pos, scl(bf, speed * dt));
      const head = [st.pos[0], st.pos[1] + 1.32, st.pos[2]];
      const lf = fwd(st.yaw, -0.08), r = right(st.yaw), u = cross(r, lf);
      const pois = [
        { id: 'console', kind: 'console', label: 'Console', pos: [2, 1, -10], priority: 0.78, maxRange: 18 },
        { id: 'arch_1', kind: 'arch', label: 'Arch', pos: [-3, 2, -25], priority: 0.74, selfRadius: 2.2, maxRange: 19.5 },
        { id: 'gull', kind: 'fauna', label: 'Gull', pos: [4 * Math.sin(0.4 * t), 1.5, -15 - 0.8 * t], priority: 0.9, moving: true, maxRange: 32 },
      ];
      const sounds = [];
      if (st.k === 420) sounds.push(['ping', add(head, [6, 0, -3]), 0.6, 1.8]);
      if (st.k === 1080) sounds.push(['impact', add(head, [-4, 0, 3]), 0.95, 1.8]);
      return { sounds, ctx: { mode: 'deck_walk', headPos: head, bodyFwd: bf, bodyRight: r, bodyUp: [0, 1, 0],
        visionFwd: lf, visionRight: r, visionUp: u, cameraFwd: lf, desiredLookDir: lf, speed, desSpeed: sp(t + 0.5), yawRate,
        isAirborne: win(t, 12.0, 12.6), jumpAnticip: win(t, 11.7, 12.0) ? 0.5 : 0, inCriticalTransition: false,
        getFloorHeight: (x, z) => 0.0, crouchBlend: 0, pois } };
    }
  },
  swim_touch: {
    init: () => ({ z: 0 }),
    step: (st, t, dt) => {
      const sprint = win(t, 10, 13);
      const speed = sprint ? 3.0 : 0.35;
      st.z -= speed * dt;
      const head = [0.55, -6, st.z];
      const yaw = 0.06 * Math.sin(0.5 * t);
      const f = fwd(yaw, 0), r = right(yaw), u = cross(r, f);
      const shL = add(head, add(scl(r, -0.132), [0, -0.14, 0])), shR = add(head, add(scl(r, 0.132), [0, -0.14, 0]));
      const cross16 = win(t, 16, 16.5);
      const pois = [{ id: 'fish_8', kind: 'fauna', label: 'Reef Fish', pos: [-2, -5.5, st.z - 7 + Math.sin(0.4 * t)], priority: 0.87, moving: true, selfRadius: 0.65, maxRange: 44 }];
      const sounds = [];
      if (st.k === 480) sounds.push(['ping', add(head, [-6, 0, -2]), 0.6, 1.8]);
      return { sounds, ctx: { mode: 'swim', headPos: head, bodyFwd: f, bodyRight: r, bodyUp: u, visionFwd: f, visionRight: r, visionUp: u,
        cameraFwd: f, desiredLookDir: f, swimAxisY: u, shoulderL: shL, shoulderR: shR,
        restHandWorldL: add(head, add(scl(r, -0.34), [0, -0.3, -0.2])), restHandWorldR: add(head, add(scl(r, 0.34), [0, -0.3, -0.2])),
        speed, desSpeed: speed, sprinting: sprint, btnPhase: 0, yawRate: 0.06 * 0.5 * Math.cos(0.5 * t),
        impactShake: win(t, 20, 20.3) ? 0.3 : 0, inCriticalTransition: cross16,
        objectiveFocus: cross16 ? { label: 'WATER ENTRY', dir: f, holdSec: 0.45 } : null,
        getFloorHeight: floorH, queryNearestSurface: wallQuery, colliders: [], pois } };
    }
  },
  swim_intent: {
    init: () => ({}),
    step: (st, t) => {
      const head = [0, -4, 0];
      const f = fwd(0, 0), r = right(0), u = cross(r, f);
      const fish = t < 14 ? [1.2, -3.8, -8] : [-1.5, -3.5, -9.5 + 0.5 * Math.sin(t)];
      const camTo = [fish[0] - head[0], fish[1] - head[1], fish[2] - head[2]];
      const cl = Math.hypot(camTo[0], camTo[1], camTo[2]);
      const pois = [
        { id: 'fish_1', kind: 'fauna', label: 'Reef Fish', pos: fish, priority: 0.87, moving: true, selfRadius: 0.65, maxRange: 44 },
        { id: 'cave_0', kind: 'cave', label: 'Sea Cave', pos: [-6, -5, -14], priority: 0.74, selfRadius: 3.0, maxRange: 54 },
      ];
      const sounds = [];
      if (st.k % 180 === 90) sounds.push(['ping', add(head, [(st.k / 180) % 2 < 1 ? 5 : -5, 0, -3]), 0.5, 1.8]);
      if (st.k === 600 || st.k === 1260) sounds.push(['impact', add(head, [3, -1, 4]), 0.9, 1.8]);
      return { sounds, ctx: { mode: 'swim', headPos: head, bodyFwd: f, bodyRight: r, bodyUp: u, visionFwd: f, visionRight: r, visionUp: u,
        cameraFwd: t > 2 ? scl(camTo, 1 / cl) : f, desiredLookDir: f, speed: 0, desSpeed: 0, yawRate: 0,
        getFloorHeight: floorH, colliders, pois } };
    }
  },
};

const res = {};
for (const [name, sc] of Object.entries(scenes)) {
  const brain = new CharacterBrain();
  const st = sc.init();
  const dt = 1 / 60;
  const tr = [];
  for (let k = 0; k < 1500; k++) {
    st.k = k;
    const t = k * dt;
    const { ctx, sounds } = sc.step(st, t, dt);
    for (const s of sounds) brain.registerSoundEvent(s[0], s[1], s[2], s[3]);
    const o = brain.update(dt, ctx);
    if (k % 3 === 2) {
      const tl = o.touchL, trr = o.touchR;
      const tlw = tl.targetWorld || [0, 0, 0], trw = trr.targetWorld || [0, 0, 0];
      tr.push([+t.toFixed(4), ...o.gazeDirWorld, o.headTiltRad, o.torsoCuriosityYaw, o.idleHipShift, o.anticipationLean,
        o.breathPhase, o.breathSignal, o.breathAmp, o.breathRate, o.gazeBlend, o.focusLabel, tl.weight, ...tlw, trr.weight, ...trw,
        o.mood, o.state, o.visiblePoiCount, brain.objectiveFocus ? 1 : 0]);
    }
  }
  res[name] = tr.map(r => r.map(v => (typeof v === 'number' && !Number.isInteger(v)) ? +v.toPrecision(9) : v));
}
fs.writeFileSync(out, JSON.stringify(res));
for (const [n, tr] of Object.entries(res)) {
  console.log(n, tr.length, 'focus', [...new Set(tr.map(r => r[13]))].join(','), 'moods', [...new Set(tr.map(r => r[22]))].join(','),
    'states', [...new Set(tr.map(r => r[23]))].join(','), 'touch max', Math.max(...tr.map(r => Math.max(r[14], r[18]))).toFixed(2),
    'objective ticks', tr.filter(r => r[25]).length);
}
