// Golden trace from Gary's Thalassa v20.19 cinematic-camera.js (updateForActor). Usage: node camera_trace.mjs <core dir> <out.json>
import { pathToFileURL } from 'url';
import fs from 'fs';
const dir = process.argv[2], out = process.argv[3];
const { NoCutCinematicCamera } = await import(pathToFileURL(dir + '/cinematic-camera.js').href);
const cam = new NoCutCinematicCamera();
const env = { getFloorHeight: (x, z) => -3.0 + 0.2 * Math.sin(x * 0.3), colliders: [{ x: 2, y: -1, z: -6, r: 1.2 }, { x: -3, y: -0.5, z: -12, r: 0.8 }] };
const tr = [];
for (let i = 0; i < 900; i++) {
  const t = i / 60;
  const pos = [3 * Math.sin(t * 0.4), -1.0 - 1.6 * Math.sin(t * 0.25) ** 2, -2 - 2.2 * t];
  const vel = [1.2 * Math.cos(t * 0.4), -0.4 * Math.sin(t * 0.5), -2.2];
  const frame = { id: 'swimmer', kind: 'swimmer', pos, fpPos: [pos[0], pos[1] + 0.03 * Math.sin(t * 6), pos[2]], headPos: pos, vel,
    yaw: 0.3 * Math.sin(t * 0.7), pitch: -0.2 + 0.5 * Math.sin(t * 0.33), roll: 0.05 * Math.sin(t), fov: 74 + 2 * Math.sin(t),
    maxSpeed: 5.0, isBoosting: t > 6 && t < 9, radius: 0.55, keepUnderSurface: pos[1] < -0.35, surfaceCeilingY: -0.30, floorMargin: 0.44,
    cameraProfile: { dist: 1.38, distSpeedAdd: 0.24, distBoostAdd: 0.14, shoulderX: 0.24, shoulderY: 0.11, lookAhead: 6.2, otsFov: 74, otsFovSpeedAdd: 3.5, fpFovCap: 82, otsRollScale: 0.32, otsLevelUp: 0.85, carveLeadScale: 0.16, headHideDist: 0.34 } };
  const o = cam.updateForActor(1 / 60, frame, { thirdPerson: Math.floor(t / 2.5) % 2 === 0, landingImpact: t > 10 && t < 10.2 ? 0.8 : 0, brakingImpulse: 0 }, env);
  if (i % 5 === 4) tr.push([...o.pos, ...o.lookTarget, o.fov, o.roll, o.thirdPersonBlend, o.armPull]);
}
fs.writeFileSync(out, JSON.stringify(tr));
console.log('wrote', out);
