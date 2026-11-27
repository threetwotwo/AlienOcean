// Golden trace from Gary's Thalassa v20.19 swimmer-physics.js. Usage: node swimmer_trace.mjs <thalassa core dir> <out.json>
// Same scripted input and env as tests/test_golden_swimmer.gd; the GDScript port must reproduce it.
import { pathToFileURL } from 'url';
const dir = process.argv[2], out = process.argv[3];
const { SwimmerLocomotion } = await import(pathToFileURL(dir + '/swimmer-physics.js').href);
import fs from 'fs';
const floor = (x, z) => (z > 0 ? 1.0 : Math.max(-6.0, 1.0 + z * Math.tan(12 * Math.PI / 180)));
const normal = (x, z) => (z > 0 || floor(x, z) <= -6.0) ? [0, 1, 0] : [0, Math.cos(12 * Math.PI / 180), Math.sin(12 * Math.PI / 180)];
const env = { getFloorHeight: floor, getTerrainNormal: normal };
const cases = {
  shore: { start: [0, 2.24, 4], yaw: 0, pitch: 0, input: (t) => ({ forward: t < 12 ? 1 : (t < 14 ? 0 : -1), right: 0, up: 0, boost: t > 3 && t < 6, boostJustPressed: false, jumpHeld: t > 1.5 && t < 1.6, yawDelta: 0, pitchDelta: 0, smoothing: 0.35 }) },
  dive: { start: [0, -3, -40], yaw: 0, pitch: 0, input: (t) => ({ forward: 1, right: t > 4 ? 0.5 : 0, up: t < 3 ? -1 : (t > 6 ? 1 : 0), boost: t > 2 && t < 5, boostJustPressed: Math.abs(t - 2.0167) < 0.009, jumpHeld: false, yawDelta: t > 5 ? 0.02 : 0, pitchDelta: t < 1 ? -0.01 : 0, smoothing: 0.35 }) },
};
const res = {};
for (const [name, c] of Object.entries(cases)) {
  const s = new SwimmerLocomotion({ startPos: c.start, startYaw: c.yaw, startPitch: c.pitch });
  const tr = [];
  for (let i = 0; i < 1200; i++) {
    const t = i / 60;
    s.update(1 / 60, c.input(t), env);
    if (i % 10 === 9) tr.push([+t.toFixed(4), ...s.pos, s.shoreGrounded ? 1 : 0, s.yaw, s.pitch]);
  }
  res[name] = tr;
}
fs.writeFileSync(out, JSON.stringify(res));
console.log('wrote', out);
