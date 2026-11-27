// Golden trace from Gary's Thalassa v20.19 input.js (stick shaping + right-stick look filter + trigger dive).
// Usage: node input_trace.mjs <thalassa core dir> <out.json>. Checked by tests/test_golden_input.gd.
import { pathToFileURL } from 'url';
import fs from 'fs';
const dir = process.argv[2], out = process.argv[3];
const { UnderwaterInputController } = await import(pathToFileURL(dir + '/input.js').href);
const c = new UnderwaterInputController();
const tr = [];
for (let i = 0; i < 240; i++) {
  const t = i / 60;
  const lx = 0.5 * Math.sin(t * 1.3), ly = -0.7 * Math.cos(t * 0.9);
  const rx = t < 1 ? 0.95 : (t < 2 ? 0.4 * Math.sin(t * 5) : (t < 3 ? 0 : -0.88));
  const ry = t < 2 ? 0.2 * Math.cos(t * 3) : -0.6;
  const l2 = Math.max(0, Math.sin(t * 2));
  const gp = { connected: true, id: 'DualSense Wireless Controller', axes: [lx, ly, rx, ry], buttons: Array.from({ length: 18 }, (_, k) => ({ value: k === 6 ? l2 : 0, pressed: false })) };
  const o = c.applyGamepadState(gp, 1 / 60, false, {});
  tr.push([lx, ly, rx, ry, l2, o.forward, o.right, o.up, o.yawDelta, o.pitchDelta]);
}
fs.writeFileSync(out, JSON.stringify(tr));
console.log('wrote', out);
