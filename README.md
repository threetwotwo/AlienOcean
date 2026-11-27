# Alien Ocean

An underwater open-world game on an alien planet, inspired by Blue Planet 2, Abzu and Journey. An 11-year-old girl, the only survivor
of her crew, charts and documents the ocean with Atlas, a second AI companion and a fleet of vessels.

Status: **0.6.0-dev**, the Godot slice prototype (chosen 27 Nov 2026 over staying on Unreal 5.8; see docs/decisions/).

## Read in this order
1. This file  2. The top entry of CHANGELOG.md  3. docs/MILESTONES.md  4. docs/decisions/  5. The folder you work in (its README and OWNERS.md)

## Layout
| Folder | What lives there |
|---|---|
| engine/godot/ | Godot project: scenes, scripts, shaders, engine adapters |
| game/ | engine-agnostic gameplay modules (as they are split out of the engine project) |
| creatures/ | the creature maker: builder, gate, viewer, species records |
| tools/ | shared pipeline tools: storage, publish, optimise, collision |
| docs/ | milestones, decisions (one short file each) |
| assets.lock.json | every big file kept outside git: path, version, md5, storage location |

Big binaries (meshes, textures, renders, audio, builds) stay out of git and are listed in assets.lock.json.

## Versions
Semantic Versioning for the game. The Unreal era is filed as 0.1 to 0.5; the Godot work starts at 0.6.0.
MINOR = a milestone whose written checks pass, PATCH = a round of fixes, `-rc.N` = candidates, 1.0.0 = the first playable slice.
Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`).
