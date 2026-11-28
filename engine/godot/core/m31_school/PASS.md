# M31 fish schools: pass checks (written before the build, judged by tests)

Owner: fish school thread ("Build the fish school system"). Source of the rules: the Nov 1 2026 paper "Fish Schools at
Sixty" (project files papers/systems/schooling/), its numpy prototype (research/schooling/school.py) and the Unreal
school lab schoollab v1-v87 (schools/). Run: `tests/run_school.sh` (all) or the single tests below.

| ID | Check | Measure | Bar | Test |
|---|---|---|---|---|
| S1 | Port | GDScript step vs numpy school.py ao step (shared random stream), 60 fish, startle wave through the school | steps 1-40 worst < 0.001 BL; after: <= 10 % of fish on another branch (32-bit vs 64-bit floats), < 0.1 BL | test_golden_school.gd |
| S2 | Same school as the paper | P, mean nearest neighbour, speed, 3 seeds, 300 fish, after 20 s | within 10 % or two seed spreads of the reference (open: numpy school.py in the same setup, P 0.988, NND 0.833, 1.93 BL/s; lagoon: schoollab REF P 0.59, NND 1.02, 0.39 BL/s). Changed 27 Nov: schoollab's open REF (NND 0.80) is a different implementation, 4 % under school.py | test_school.gd S2 |
| S3 | No fish through rock | fish inside any rock box, every step, trevally through a 9-rock reef and under an overhang, 60 s | 0 | S3 |
| S4 | No explosion | NaN, speed, spread from the centre | no NaN, speed <= burst + 2 BL/s, spread < 60 BL | S3 run, S9, monkeys |
| S5 | No clumping | min nearest neighbour; share of fish closer than 0.3 BL | min >= 0.2 BL; share <= 3 % | S3 run, S9, monkeys |
| S6 | Cohesion | largest group linked by gaps < 3 BL | >= 85 % after the reef | S6 |
| S7 | Frame-rate free | positions after 300 sim steps at 30 / 60 / 120 fps, threaded and main thread | worst < 0.0001 BL | S7 |
| S8 | Calm girl (no-harm tone) | she swims through at 0.6 m/s: startled fish, gap to her body, cohesion 10 s later | <= 5 % startled; gap >= 0.9 x keep-out; >= 85 % one group | S8 |
| S9 | Rush | she darts in at 2.5 m/s, 5 seeds: startle share; cohesion 15 s later | median >= 30 % startled (the wave), every seed >= 85 % regrouped | S9 |
| S10 | Cost (cloud CPU) | worker step, main-thread ms a frame, 120 fish | step <= 6 ms (a 30 Hz step has 33 ms on its worker); main mean <= 0.8 ms, p95 <= 1.5 ms | S10 |
| S11 | Calm-diver circling (Thalassa) | girl hovering 6 m from a trevally school, 25 s: mill about her, share in the 2.6-12.5 m band, startles, closest fish | mill >= 0.5; >= 70 % in band; <= 5 % startled; closest >= 0.6 m | S11 |
| S12 | Silent observation ring (Thalassa) | observer kind, ring 4.8 m, 30 s: share of fish within 0.6-1.4 x ring | >= 70 %, S4-S5 hold | S12 |
| S13 | Ride escort (Thalassa) | ridden manta (kind ride, 1.2 m/s) past a trevally school, 20 s: share within 14.5 m, heading along with it, startles, closest | >= 70 % near; heading >= 0.7; <= 5 % startled; closest >= 1.2 m | S13 |
| S14 | Maker export in the school | when assets/creatures/<asset>/ is present: 3 LOD meshes, body length = extras body_length_m, body spans s 0..1 in the school frame, beat at each envelopes_by_speed U = its beat_Hz and at steady.U_rec = record f; below U_min a slow fish (U_min/2) beats then glides (glide 25-60 % of the time), a cruising fish never glides | all hold (SKIP when the gitignored glbs are absent) | S14 |
| S15 | Drawn upright | FishSchool.fish_basis for 24 headings x pitch -50..50 deg: back up (up . world up = cos pitch), heading kept, right-handed, positive bank rolls the back toward the fish's left | all hold (added 28 Nov: schools were drawn upside down) | S15 |
| S16 | No twitching (drawn) | 120 trevally (export when present), 10 s at 60 fps, drawn raw and zero-twitch: per fish per frame turn jerk, bend step, swim-speed rate; steady/phrase mode flips; drawn heading vs sim heading | zero-twitch: turn jerk p95 <= 40 rad/s^2, bend step p95 <= 0.06, <= 6 flips per fish-minute, heading within 20 deg (p95). Raw measured 28 Nov: jerk 510, bend step 2.47, 7.4 flips (fails) | S16 |
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
