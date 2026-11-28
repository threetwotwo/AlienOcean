# Changelog

Newest first. Format: version, date, milestone, what changed, what it supersedes. Rules: VERSIONING.md.
Entries 0.1.0 to 0.5.0 were filed on 27 Nov 2026 from the audit log, memory index and handovers; dates are the
day the milestone was reached.

## [Unreleased]
- Fish schools in Godot (engine/godot/core/m31_school, adapters/godot/school_node.gd): the Nov 1 paper's numpy rules
  ("Fish Schools at Sixty", school.py "ao") ported step for step and golden-checked; per-species behaviour records
  keyed by the maker's species id; FishSchool node thinks at 30 Hz on a worker thread and draws with MultiMesh LODs;
  rock guard, calm reaction to the girl, startle wave on a rush. Pass checks S1-S10 in PASS.md, stress harness with
  random monkey runs and a planted fault (tests/run_school.sh). Stand-in fish mesh and swim law until the maker's
  trevally lands. Supersedes the parked Unreal school lab (schools/, schoollab v1-v87) as the live school system.
  Thalassa v20.19's social behaviours ported on top (calm-diver circling, silent-observation ring, ride escort,
  roll law); checks S11-S12.
  Schools draw the maker's export (trevally caranx_melampygus: LOD meshes, materials, swim wave from glTF extras,
  check S14). Export r2 adopted: three swim envelopes (1.45, 2.175, 2.9 BL/s) blended by each fish's speed in the
  shader, beat from the envelopes' measured rates, and burst-and-coast (2 beats then a glide) below steady.U_min.
- Creature maker moves into the repo as stage modules (creatures/maker/, tool version 0.3.0-dev): record, form, chart,
  cage features (template, eye, mouth, gill, finish), UV, maps, fins, Blender export, checks, board. Output is
  byte-identical to the last fish-restart proof script. Real openings: mouth, throat and both gill passages are topology
  (check OP1), stay inside the body (OP2), and folds outside designed creases are counted (OP3).
- Workspace cleanup (Gary tapped "Proceed in stages" 27 Nov 14:26Z): VERSION, VERSIONING.md, MILESTONES.md, this
  changelog and a one-page README added; old runner README moved to archive/root_2026-11-27/. Old Unreal-era folders
  move to Firebase bundles next (list: storage/move_out_2026-11-27.md).
- Friday reset decisions in progress: engine move (Godot evaluation), fresh-start fish modeling, gameplay modules.

## 0.5.0 - 2026-11-21 - Universal head milestone and whole-creature audit (Unreal era, last)
- Universal head milestone in the shared fish builder (trevally first test fish); eye orbit tissue work.
- Whole-creature audit (plans/creature_audit/whole_creature_nov21/), builder audit and lever-off merge plan.
- FUNDAMENTALS.md, STATE.md (generated), flow checks FL1-FL4, Tools review and storage offload (7.9 GiB).
- All threads parked 21 Nov ~16:10Z for the weekly usage reset; handovers in plans/handover/.

## 0.4.0 - 2026-11-16 - Eyes in the shared builder; text-to-species set as the end goal
- Eye merge into the shared builder; grown-not-placed and body-area rules; pattern recipe (reaction-diffusion).
- Long goal written: a universal creature maker that makes new species from text.

## 0.3.0 - 2026-11-13 - Foundation systems: storage, art bible, shared creature builder, snapper slice
- Firebase offload for assets (9 Nov), standing storage rule; Art bible v1.3 locked (11 Nov); environment palette locked.
- Shared cage creature builder; first slice narrowed to the hero snapper in L_CalmLagoon (12 to 13 Nov); hands-free plan.

## 0.2.0 - 2026-11-01 - Calm lagoon is the only level
- Old lagoons and the tuskfish retired (plans/tidy_2026-11-01.md); two-slice plan (lagoon + open-water tank) set 23 Oct.

## 0.1.0 - 2026-10-18 - Unreal foundation
- Ocean, sun and seabed scripts in UE 5.8 with one versioned file per step (renamed 17 Oct), one-click runner menu
  (run_next), Gary's to-do list system.
