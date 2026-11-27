# M31 fish schools: pass checks (written before the build, judged by tests)

Owner: fish school thread ("Build the fish school system"). Source of the rules: the Nov 1 2026 paper "Fish Schools at
Sixty" (project files papers/systems/schooling/), its numpy prototype (research/schooling/school.py) and the Unreal
school lab schoollab v1-v87 (schools/). Run: `tests/run_school.sh` (all) or the single tests below.

| ID | Check | Measure | Bar | Test |
|---|---|---|---|---|
| S1 | Port | GDScript step vs numpy school.py ao step (shared random stream), 60 fish, startle wave through the school | steps 1-40 worst < 0.001 BL; after: <= 10 % of fish on another branch (32-bit vs 64-bit floats), < 0.1 BL | test_golden_school.gd |
| S2 | Same school as the paper | P, mean nearest neighbour, speed, 3 seeds, 300 fish, after 20 s | within 10 % or two seed spreads of schoollab REF (open: P 0.965, NND 0.80, 1.91 BL/s; lagoon: P 0.59, NND 1.02, 0.39 BL/s) | test_school.gd S2 |
| S3 | No fish through rock | fish inside any rock box, every step, trevally through a 9-rock reef and under an overhang, 60 s | 0 | S3 |
| S4 | No explosion | NaN, speed, spread from the centre | no NaN, speed <= burst + 2 BL/s, spread < 60 BL | S3 run, S9, monkeys |
| S5 | No clumping | min nearest neighbour; share of fish closer than 0.3 BL | min >= 0.2 BL; share <= 3 % | S3 run, S9, monkeys |
| S6 | Cohesion | largest group linked by gaps < 3 BL | >= 85 % after the reef | S6 |
| S7 | Frame-rate free | positions after 300 sim steps at 30 / 60 / 120 fps, threaded and main thread | worst < 0.0001 BL | S7 |
| S8 | Calm girl (no-harm tone) | she swims through at 0.6 m/s: startled fish, gap to her body, cohesion 10 s later | <= 5 % startled; gap >= 0.9 x keep-out; >= 85 % one group | S8 |
| S9 | Rush | she darts in at 2.5 m/s: startle share; cohesion 15 s later | >= 30 % startled (the wave), >= 85 % regrouped | S9 |
| S10 | Cost (cloud CPU) | worker step, main-thread ms a frame, 120 fish | step <= 6 ms (a 30 Hz step has 33 ms on its worker); main mean <= 0.8 ms, p95 <= 1.5 ms | S10 |
| Planted fault | swept guard and rock push off | S3 must FAIL | caught | --fault |
| Monkeys | random reefs, species, sizes, actor paths, 30/60/120 fps, threaded or not | S3-S5 every step | all pass | --monkey N |

## Budget on Gary's Mac (M1 Pro, 60 fps = 16.7 ms)
- Main thread: <= 0.3 ms a frame per 120-fish school on the Mac (world queries staggered 1 in 4 fish a step + one swept ray
  per fish near rock + MultiMesh upload); all schools together <= 1.0 ms (FUNDAMENTALS: 16.7 ms frame).
- Worker: the step runs off the main thread; <= 4 ms per 120 fish per 30 Hz step (cloud ~4.5 ms; the M1 P-core is faster).
- GPU: stand-in mesh LOD0 ~700 triangles within 12 m, LOD1 ~250 to 30 m, LOD2 ~60 beyond: 120 fish all at LOD0 = 84 k
  triangles, 3 draw calls a school (FUNDAMENTALS: 1.5 M triangles, 600 draws, 20 k instances).
- Stage 2 (when schools pass a few hundred fish or more than ~4 schools think at once): the GPU step (schoollab's GPU
  school, a compute shader), far schools think at a lower rate.
