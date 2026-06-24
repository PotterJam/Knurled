# ADR 0002 — Track plan/program lifecycle as canonical events

- Status: Accepted
- Date: 2026-06-24

## Context

A training repo's plan changes over time (mvp-spec §12):

- **Direct edits** to `plan.fitspec` (weights, rotation, template choice).
- **Patch files** in `patches/` (injury, running block, deload).
- **`state_adjusted` events** in the log (deload a lane, set next load).

How each is tracked today:

- Plan edits and patches are tracked by **git** (committed text files), and every training event
  stamps `plan_hash` / `template_hash`, so each result is anchored to the plan version that
  produced it.
- State adjustments are first-class **events** in the canonical log.

The gap: **plan-level transitions are not first-class in the training history.** "I edited the
plan", "I finished this program", "I switched GZCLP → 5/3/1", "phase 1 → phase 2" exist only as
git diffs plus a silently-changed `plan_hash`. Git knows the text changed and when; it does not
make that a queryable part of the training narrative, and the replayer/backtester has to *infer*
plan boundaries from `plan_hash` deltas across events.

## Decision

Add a single canonical event type, **`plan_changed`**, written to `logs/**/*.jsonl` like any
other event, mirroring `state_adjusted` (§12.3):

```jsonc
{
  "id": "evt_20260624_plan_changed",
  "type": "plan_changed",
  "change_kind": "program_switch",   // direct_edit | patch_applied | phase_advance | program_switch | completed
  "from": { "plan_hash": "…", "template": "gzcl.gzclp@1.0.0" },
  "to":   { "plan_hash": "…", "template": "531.basic@1.0.0" },
  "reason": "finished novice LP, moving to 5/3/1"
}
```

Rules:

- **One event type, discriminated by `change_kind`** — not a sprawl of event types. `completed`
  is the "this program is done" signal; `to` may be absent for a pure completion.
- **The event records fact, intent, and hashes — not plan content.** The plan text stays in
  `plan.fitspec` / `patches/` under git; the event links to it via hashes. This preserves the
  §12.3 rule that no tool treats a projection as truth or duplicates the source.
- **The engine treats `plan_changed` as a marker / replay boundary**, not as an instruction to
  mutate the plan. It does not recompute plan content from the event.
- Emitted whenever the app or CLI commits a plan edit, applies/expires a patch, or the user
  marks a program complete.

## Consequences

- Program history becomes **queryable data**: a phase/program timeline, "time on each program",
  "PRs per block" — and it composes with the discipline/phase direction in [ADR 0001](0001-training-log-format.md).
- Replay and backtest get **explicit plan boundaries** instead of inferring them from hash deltas.
- `completed` gives the app a real signal to prompt "what's next?" at the end of a block.
- Surface stays small (one event type); evolution rides the existing `schema_version` field.
- New work this implies (not done here): emit `plan_changed` from the plan-edit / patch / "mark
  complete" paths in the engine + app; teach replay to recognise the marker; surface program
  history in the UI.
