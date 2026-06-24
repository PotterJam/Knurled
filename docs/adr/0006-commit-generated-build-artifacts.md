# ADR 0006 — Keep committing generated `build/` artifacts for now, despite noisy workout diffs

- Status: Accepted (temporary)
- Date: 2026-06-24

## Context

A Knurled training repo separates user-owned source from generated projections
([repo-contract.md](../repo-contract.md), mvp-spec §7). Today every workout commit
(`AppModel+GitHub.swift` → `GitHubChangedFiles.present`) carries both:

- the canonical change — one appended line in `logs/YYYY/MM.jsonl`, plus the small
  projected delta in `state/current.json`; and
- the regenerated cache — `build/current.ir.json`, `build/next-workout.json`,
  `build/validation.json`.

In practice the diff per workout breaks down like this:

| File | Diff per workout | Nature |
| --- | --- | --- |
| `logs/YYYY/MM.jsonl` | +1 line | canonical truth |
| `state/current.json` | small, keys sorted | projected delta (one lane + cursor) |
| `build/current.ir.json` | usually none | compiled plan; only moves when the plan moves |
| `build/validation.json` | usually none | same `valid` report |
| `build/next-workout.json` | **~230 lines, every commit** | forward-looking render cache |

`build/next-workout.json` dominates the diff. It is the fully-rendered execution
contract for the *next* session, and because the next session is a different slot in
the rotation each time (a1 → b1 → a2 → …) with different exercises, loads, and a fresh
`rendered_session_hash`, it is rewritten essentially in full on every commit. This is
inherent to its content, not a formatting problem — no serialization tweak collapses it.

mvp-spec §7 already names this an MVP tradeoff: *"Do not ignore `state/` or `build/` in
the MVP … Later, once iOS can reliably rebuild locally, `build/` can become disposable."*
The spec also reserves a `commit_generated` flag under `[build]` in `fitspec.toml`, which
is written on init (`engine/src/repo.rs`) but is **read by nothing today** — a dormant
hook for exactly this switch.

Options considered for reducing the noise now:

1. Stop committing `build/next-workout.json` (gitignore it, exclude from the commit set).
2. Stop committing all of `build/` and treat it as a disposable cache.
3. Keep committing `build/` as-is.

## Decision

**Keep committing the generated `build/` files for now (option 3). Accept the noisy
per-workout diff as a known, temporary MVP cost.**

The reasons committed generated files still earn their keep at this stage:

- **GitHub inspectability.** The compiled plan (`current.ir.json`), the next prescription
  (`next-workout.json`), and the validation report are browsable on GitHub and readable by
  any client without running the engine. That is valuable while the data model and the
  multi-client story (iOS, workbench, CLI) are still settling.
- **iOS rebuild is not yet fully relied upon.** iOS embeds the engine and rebuilds on
  `sync()`, but `connect()` currently pulls with `engine.build(write: false)` and reads
  the committed `build/` files directly (mvp-spec §28). The committed cache is still load-
  bearing for the connect path.
- **Smaller blast radius.** Dropping `build/` from version control is a repo-contract
  change that touches the contract doc, the iOS connect/sync paths, `check-generated`, and
  fresh-clone behavior. It is worth doing deliberately, not as a reflex to diff noise.

This decision is explicitly **temporary**. We are recording it so the noisy diff is
understood as a chosen tradeoff rather than an oversight, and so the path out is written
down rather than rediscovered.

## Consequences

- Workout commits stay noisy: expect a large `build/next-workout.json` churn on every
  commit. When reviewing what actually happened, read `logs/**/*.jsonl` (what was performed)
  and `state/current.json` (how state moved); treat `build/` hunks as regenerated cache.
- The canonical record is unaffected — `build/` remains a deterministic projection and is
  never truth (`knurled check-generated` reports drift).
- The dormant `commit_generated` flag stays dormant; we have not wired it up yet.

## Exit criteria — when to revisit

Flip to making `build/` disposable (option 1 or 2) once these hold:

1. iOS reliably rebuilds `build/` locally on **connect** as well as sync (change
   `connect()` to build with `write: true`), so a clone without committed `build/` is fully
   usable.
2. Any other reader (workbench, CLI, GitHub-side inspection) either runs the engine or has
   an explicit story for absent `build/`.
3. `commit_generated` in `fitspec.toml [build]` is actually honored — false excludes `build/`
   from the commit set and adds it to `.gitignore`; true preserves today's behavior.

At that point the likely first step is to stop committing `build/next-workout.json` (the
sole large offender) while optionally retaining `current.ir.json`/`validation.json` for
inspectability, then re-evaluate dropping the rest. See mvp-spec §7 and §28.
