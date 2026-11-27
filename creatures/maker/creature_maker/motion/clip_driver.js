// clip_driver.js <model.json> <opts.json> : runs the swim engine (swim.js v18, ported verbatim from project files motion/swim/v18) on one
// creature's motion model and prints JSON frames of every joint's world position (metres) and world rotation (quaternion), swim frame:
// snout +X, up +Y, z lateral. opts: {U (BL/s), seconds, fps, warm (s), breath (0/1), seed}. Steady command, tempo off, personality 1,
// so a cruise run is periodic in the beat and the clip loops.
const fs = require("fs"), S = require(__dirname + "/swim.js"), G = require(__dirname + "/gaits.json");
const model = JSON.parse(fs.readFileSync(process.argv[2])), o = JSON.parse(fs.readFileSync(process.argv[3]));
const sw = new S.Swimmer(model, G, { U0: o.U, seed: o.seed || 1, personality: { amp: 1, rate: 1, glide: 1, fins: 1 } });
const cmd = () => ({ U: o.U, swim: o.U > 0.02, yawRate: 0, tempo: 0 });
const sub = 10, dt = 1 / (o.fps * sub);
for (let i = 0, n = Math.round(o.warm * o.fps * sub); i < n; i++) sw.step(dt, cmd());
const frames = [], n = Math.round(o.seconds * o.fps);
for (let k = 0; k <= n; k++) {
  if (k) for (let s = 0; s < sub; s++) sw.step(dt, cmd());
  const fk = sw.fk(sw.pose());
  frames.push({ t: k / o.fps, pos: sw.pos.slice(), psi: sw.psi, f: sw.f, U: sw.U, phase: sw.phase, W: fk.W, Q: fk.Q });
}
process.stdout.write(JSON.stringify({ gait: sw.g.style, stride: sw.stride, fc: sw.fc, sRigid: sw.sRigid, breathRate: sw.breath.rate, frames }));
