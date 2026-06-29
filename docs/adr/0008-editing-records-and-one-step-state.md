# ADR 0008 — Editing records with one-step lane state

- Status: Accepted
- Date: 2026-06-28

## Context

Training records are user-editable, but ADR 0007 makes `state/current.json` authored truth rather
than a projection replayed from logs. Replaying all history after an edit would violate that
boundary and could reinterpret old workouts under a newer plan.

## Decision

State retains one predecessor checkpoint for each progression lane. A checkpoint identifies the
record that most recently moved the lane, stores the lane state immediately before that move, and
stores the rendered item needed to evaluate the same transition again.

Replacing a workout's lifts recomputes a lane only when that workout still owns the lane's current
checkpoint. The engine restores the predecessor and applies the edited result. If a later workout
has replaced the checkpoint, the edit changes history only. Lanes are judged independently, so an
intervening workout on unrelated lanes does not suppress recomputation.

## Consequences

- Latest-lane edits update the next workout without full log replay.
- Older superseded edits remain faithful history changes and cannot rewrite current progression.
- Only one transition can be revised; this is an intentional product rule, not an incomplete
  event-sourcing mechanism.
- Checkpoints live in authored state and are replaced when a later record moves the same lane.
