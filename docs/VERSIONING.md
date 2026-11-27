# Versioning (Gary tapped "Proceed in stages" 27 Nov 2026 14:26Z; audit https://claude.ai/artifact/VNzJLK7rmc94YR6iGZK9NB)

Semantic Versioning, MAJOR.MINOR.PATCH, for the whole game (root `VERSION`, `CHANGELOG.md`) and separately for each reusable tool.

## The game
- MAJOR is 0 until the vertical slice ships. 1.0.0 = first playable slice: the girl, the camera, one hero creature in the
  calm lagoon, 60 fps on Gary's M1 Pro.
- MINOR goes up only when a milestone in `MILESTONES.md` passes its written checks (render Gary has seen, gate green).
  A milestone gets its number before work on it starts.
- PATCH = a round or fix inside the current milestone.
- A candidate waiting on Gary's look is `X.Y.Z-rc.N`. His approved merge drops the suffix.
- Numbering continues across engines and restarts; no two releases share a number. History before the git repo is
  filed as 0.1.0 to 0.5.0 in CHANGELOG.md.

## Each tool
- Version lives in the first lines of the tool's README (`Version: 1.4.2`) and in its own CHANGELOG section, not in file names.
- MAJOR = inputs or outputs change shape (record field renamed, file contract changed). MINOR = new capability old
  callers don't notice. PATCH = fix.
- Old `<part>_<step>_vN.py` names stay as they are on disk (renaming would break paths); new work in git keeps one
  stable file name. Files outside git (Firebase builds, renders) are named `<tool>-<version>.<ext>`.

## Writing it down
- Every release adds one CHANGELOG entry, newest first: version, date (from `date -u`), milestone, what changed in
  plain words, what it supersedes, links.
- Once the git repo exists: Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`), tags `vX.Y.Z`, and
  release-please writes the changelog and the version bump; threads don't type them by hand.

## How a new thread learns the past
README.md (one page) -> top entry of CHANGELOG.md -> FUNDAMENTALS.md -> STATE.md -> its own plans/handover/<name>.md.
