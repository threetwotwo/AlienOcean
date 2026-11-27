// Golden trace from Gary's Thalassa v20.19 core/ik-rig.js (DiverBodyRig.updateSwim incl. shore walk/wade + blend).
// Usage: node body_trace.mjs <thalassa core dir> <out.json>. Same swimmer cases as swimmer_trace.mjs.
// The brain and hair are swapped for the stand-ins the Godot port uses until character-brain.js is ported
// (core/m04_body/quiet_brain.gd): gaze = look direction, nothing noticed.
import { pathToFileURL } from 'url';
import fs from 'fs';
const dir = process.argv[2], out = process.argv[3];
const { SwimmerLocomotion } = await import(pathToFileURL(dir + '/swimmer-physics.js').href);
const { DiverBodyRig } = await import(pathToFileURL(dir + '/ik-rig.js').href);
const floor = (x, z) => (z > 0 ? 1.0 : Math.max(-6.0, 1.0 + z * Math.tan(12 * Math.PI / 180)));
const normal = (x, z) => (z > 0 || floor(x, z) <= -6.0) ? [0, 1, 0] : [0, Math.cos(12 * Math.PI / 180), Math.sin(12 * Math.PI / 180)];
const env = { getFloorHeight: floor, getTerrainNormal: normal };
const cases = {
  shore: { start: [0, 2.24, 4], input: (t) => ({ forward: t < 12 ? 1 : (t < 14 ? 0 : -1), right: 0, up: 0, boost: t > 3 && t < 6, boostJustPressed: false, jumpHeld: t > 1.5 && t < 1.6, yawDelta: 0, pitchDelta: 0, smoothing: 0.35 }) },
  dive: { start: [0, -3, -40], input: (t) => ({ forward: 1, right: t > 4 ? 0.5 : 0, up: t < 3 ? -1 : (t > 6 ? 1 : 0), boost: t > 2 && t < 5, boostJustPressed: Math.abs(t - 2.0167) < 0.009, jumpHeld: false, yawDelta: t > 5 ? 0.02 : 0, pitchDelta: t < 1 ? -0.01 : 0, smoothing: 0.35 }) },
};
const quietBrain = { update: (dt, ctx) => ({ gazeDirWorld: ctx.desiredLookDir, headTiltRad: 0, objectiveFocusActive: false, touchL: null, touchR: null, idleHipShift: 0, torsoCuriosityYaw: 0, anticipationLean: 0, breathCentered: 0, breathAmp: 1 }), getState: () => ({}), registerSoundEvent() {} };
const res = {};
for (const [name, c] of Object.entries(cases)) {
  const s = new SwimmerLocomotion({ startPos: c.start, startYaw: 0, startPitch: 0 });
  const rig = new DiverBodyRig();
  rig.brain = quietBrain;
  rig.hairBob = { update: () => null };
  const tr = [];
  for (let i = 0; i < 1200; i++) {
    const t = i / 60;
    const inp = c.input(t);
    rig.updateTimers(1 / 60);
    s.update(1 / 60, inp, env);
    const p = rig.updateSwim(1 / 60, s, inp, t, floor, null, null, null, null, normal);
    if (i % 10 === 9) {
      const h = p.headMat;
      tr.push([+t.toFixed(4), p.mode || 'swim', ...p.chestPos, ...p.pelvisPos, ...p.neckPos, h[12], h[13], h[14],
        ...p.armL.mid, ...p.armL.eff, ...p.armR.eff, ...p.legL.ik.mid, ...p.legL.ik.eff, ...p.legR.ik.eff]);
    }
  }
  res[name] = tr;
}
fs.writeFileSync(out, JSON.stringify(res));
console.log('wrote', out, res.shore.length, res.dive.length, 'modes', [...new Set(res.shore.map(r => r[1]))].join(','));
