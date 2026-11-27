"""I7 frame-rate independence: with the simulation tick fixed (60 Hz), runs at 30/60/120 fps must end in the same
place (5 cm limit; expected 0). Monkey runs are included, since the input is seeded by sim time. Usage: python3 compare_rates.py <dir> [prefix: m02 | m29] (reads <prefix>_30/60/120.json)"""
import json, sys, math
d = sys.argv[1]
prefix = sys.argv[2] if len(sys.argv) > 2 else "m02"
runs = {r: {x['name']: x for x in json.load(open(f"{d}/{prefix}_{r}.json"))['results']} for r in (30, 60, 120)}
worst, bad = 0.0, []
for name, a in runs[60].items():
    for r in (30, 120):
        b = runs[r].get(name)
        if not b:
            continue
        dist = math.dist(a['end'], b['end'])
        worst = max(worst, dist)
        if dist > 0.05:
            bad.append(f"{name}: 60 vs {r} Hz differ {dist*100:.1f} cm")
print(f"I7 {prefix} rate independence: worst {worst*100:.1f} cm over scripted cases" + ("" if not bad else "\n  " + "\n  ".join(bad)))
sys.exit(1 if bad else 0)
