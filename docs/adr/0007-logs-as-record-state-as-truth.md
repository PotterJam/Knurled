# ADR 0007 — Logs are a training record, not a replay ledger; `state` becomes the source of truth

- Status: Accepted
- Date: 2026-06-25
- Supersedes: [ADR 0001](0001-training-log-format.md)
- Amends: [repo-contract.md](../repo-contract.md) (logs/state clauses), mvp-spec §18–19
- Reconciles: [ADR 0002](0002-plan-lifecycle-events.md) (`plan_changed`)

## Context

Until now `logs/**/*.jsonl` was the canonical, event-sourced training record, and everything
the user saw — `state/current.json`, `build/*.json` — was a deterministic **projection replayed**
from those logs ([repo-contract.md](../repo-contract.md), mvp-spec §18–19,
[ADR 0001](0001-training-log-format.md), `core.rs` `replay_events`/`fold_corrections`). The log
was a ledger: the source of truth for *where you are* was rebuilt by folding every past event.

Four problems pushed us to reconsider the whole posture, not just the syntax:

1. **The on-disk log is unreadable.** Events are serialized minified, one squashed JSON line per
   event (`stable_json`, `import.rs`), so a single workout is a wall of brackets.
2. **Most of each line is replay scaffolding, not data.** A session is "a few numbers" — exercise,
   weight, reps — wrapped in `plan_hash` / `template_hash` / `rendered_session_hash` / `program` /
   `prescribed` / `outcome` / `continues_event_id` / `corrects_event_id` / `results_added` /
   `changes`. All of that exists so the past can be *replayed deterministically*.
3. **The format is a contract reimplemented three times.** Rust, Swift, and JS each had to
   hand-roll read/write behavior around the same event log, and client behavior had already
   started to diverge. The engine exposed no log writer over WASM/FFI, so clients invented
   their own.
4. **The one thing replay-from-logs uniquely buys, we don't need.** Re-deriving state from history
   and reinterpreting old sessions under a changed plan only matter if the past must stay
   replayable. For a single-author, Git-backed personal training tool it does not: Git already
   provides the audit trail, and backtesting a *new* program needs the raw performance numbers,
   not pinned replay metadata.

## Decision

1. **Logs are a record, never replayed by the engine.** They are written when a session is
   finished, are human-facing, and the engine does **not** read them back to compute anything.
   Editing or deleting a log entry cannot drift the program, because nothing depends on it.

2. **`state` becomes the source of truth, authored-forward.** It holds the current progression
   cursor per lift/lane (e.g. working weight, stage, fail-count) plus the active program identity.
   The engine renders the next session from `state` + program and updates `state` when a session
   is finished. `state` is no longer a projection of logs.

3. **`state` is program-shaped, not one fixed schema.** GZCLP carries `{weight, stage, fails}`;
   5/3/1 carries `{training_max, week}`. "Start a new program" means writing a fresh `state`
   document in that program's shape.

4. **Progression is a submit-time step against `state`, with three explicit outcomes:**
   - `advance` (default) — run the program's pass/fail rules and update `state`.
   - `off day` — record the session, change nothing in `state`. The program's target is
     unchanged; fail-counts and stages do not move. (Felt-bad / backed-off days.)
   - `reset` — set a new baseline in `state` (e.g. lighter weights after a layoff).

   Intent is chosen by the user **at finish time and applied to `state`** — never inferred from
   the logged numbers, and never stored as instruction metadata in the log.

5. **Lean log schema.** A day is a record of what happened:

   ```jsonc
   {
     "date": "2026-06-24",
     "lifts": [
       { "exercise": "squat", "weight": "82.5kg", "sets": [5, 5, 3] },
       { "exercise": "bench", "weight": "45kg", "sets": [10, 10, 8], "note": "felt strong" }
     ]
   }
   ```

   Dropped from the log: all hashes, `program` per session, `prescribed`, `outcome`,
   per-line `engine_version`, and the `continues`/`corrects`/`results_added`/`changes` plumbing.
   Open, units-explicit per-set metrics (`rpe`, `rir`, later velocity — the one good idea from
   ADR 0001) survive additively as optional keys.

6. **File layout & format: pretty JSON, grouped monthly.** `logs/<yyyy>/<mm>.json`, a top-level
   object with a `days[]` array. Pretty-printed (not minified). Monthly matches the existing iOS
   convention and keeps files small (tens of KB).

7. **A break or new program is just re-authoring `state`.** A layoff needs no representation — it
   is a gap in the dated record, and nothing computes off elapsed time. Restarting lighter, or
   switching programs, overwrites the progression cursor; the logs continue uninterrupted across
   the gap.

8. **Keep a minimal, human-facing program-boundary marker in the record.** Because `program`
   moved out of each session into `state`, the log alone could not say which program a past
   session belonged to. A single dated marker in the record makes history self-describing across
   breaks and switches:

   ```jsonc
   { "date": "2026-06-26", "program": "531.basic", "note": "finished novice LP" }
   ```

   This is **not** the old `plan_changed` replay-event (ADR 0002): the engine ignores it; it
   exists for the human timeline, charts, and backtest segmentation only.

9. **Backtest is a standalone, opt-in pure function.** `(raw log numbers, candidate program) →
   projection`. It reads the same lean logs — no extra pinning — and is the only consumer of the
   logs besides the human. This preserves the genuinely useful capability without taxing every
   line.

10. **Centralize log (de)serialization and the progression step in the engine, exposed over
    WASM/FFI.** Clients hand the engine numbers and receive file contents / the next `state`,
    instead of each hand-rolling the format. This removes the three-implementations divergence and
    honors the repo's Engine Boundary rule (clients render engine output, they don't reimplement
    engine concerns).

## Consequences

- **Simpler engine.** `replay_events`, `fold_corrections`, the correction/continuation event
  types, and the log→state projection retire. `build` shrinks to "render the next session from
  `state` + program."
- **Lost, deliberately:** re-deriving `state` from logs, retroactive program reinterpretation, and
  cascade-corrections. We have accepted that the past need not be replayable.
- **Editing history is safe and is just editing a record.** Git is the audit trail.
- **New risk: `state` is now precious** (primary, not regenerable from logs). Mitigation: it is
  tiny, Git-tracked, human-readable, and can be hand-reconstructed from the last log entries plus
  the program if ever lost.
- **Backtesting stays possible and is cleaner** — it reads the lean record directly.
- **ADR 0002 is reconciled:** `plan_changed` as a replay-boundary event is dropped (no replay, no
  boundaries to infer); a minimal human-facing program marker (decision 8) takes its place.

## Implementation status

- **Greenfield reset.** No real logs exist in the repo (only `.gitkeep`), so there is nothing to
  migrate. Any developer fixtures are regenerated in the new shape.
- **Phased delivery** (each its own change):
  1. This ADR + superseded/amended markers + sample shapes. *(done)*
  2. Engine: program-shaped `state`, the submit-time progression step (`advance`/`off day`/
     `reset`), the lean log serializer/parser, and the standalone backtest — exposed over WASM/FFI.
  3. Clients (CLI, workbench, iOS) call the engine serializer instead of hand-rolling logs.
  4. Delete `replay_events`/`fold_corrections`/the projection-build path.
  5. Amend `repo-contract.md` and mvp-spec §18–19 to match.
