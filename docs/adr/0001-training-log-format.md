# ADR 0001 — Training log stays an event log; generalise the performed unit for hybrid training

- Status: Superseded by [ADR 0007](0007-logs-as-record-state-as-truth.md)
- Date: 2026-06-24

> Supersession note: the event-log/replay assumptions below are historical. The current canonical
> record is ADR 0007's pretty monthly `TrainingRecord` log plus authored-forward `state/current.json`.
> The measured-effort direction survives only where it maps to lean record details such as
> `LiftRecord.actual[].metrics`.

## Context

`logs/**/*.jsonl` is the canonical training record. Everything else the user sees —
`state/current.json`, `build/*.json` — is a deterministic *projection* replayed from those
logs ([repo-contract.md](../repo-contract.md), mvp-spec §18–19). The log is therefore an
**event log**, not a data table.

Three questions were raised about the format:

1. A completed session is written as one event (one JSONL line) with sets nested under
   `results[].actual[]`. Should it instead be one line per set, for readability?
2. The data looks simple — should we use CSV instead of JSON?
3. We want the shape to eventually support **hybrid training** (strength + conditioning) and
   other activities (run, row, erg, mobility). What schema makes that possible without breaking
   existing logs?

Key facts that constrain the answer:

- Events are heterogeneous: `session_completed`, `session_skipped`, `session_corrected`,
  `session_continued`, `state_adjusted` carry different fields (mvp-spec §18, `model.rs`
  `TrainingEvent`).
- Events are referential: `session_corrected` amends an earlier event via `corrects_event_id`;
  partial saves chain via `continues_event_id`.
- The engine reduces and computes progression at **session grain**, not per set
  (`engine/src/core.rs`). A set is an input captured inside a session event, not an independent
  state transition.
- Each event pins the plan/template it was recorded under (`plan_hash`, `template_hash`,
  `rendered_session_hash`) so replay stays deterministic.
- The performed unit (`ActualSet`: `set`, `load`, `reps`) is strength-shaped.

## Decision

1. **Keep the canonical log as append-only JSONL, event-sourced, at session grain.** One line
   per *event*. Sets stay nested inside the session event. Per-set events are rejected: they
   would explode replay, fracture the correction model (corrections target events), and fight
   the one-signed-commit-per-session design.

2. **Do not use CSV (or any flat/tabular format) for the canonical log.** The data is
   heterogeneous, nested, referential, and will gain fields over time — all of which JSON
   absorbs and CSV does not. Readability and spreadsheet use are *projection* concerns: solve
   them with an export (`knurled export` → per-set CSV / markdown) derived from the events, not
   by changing the source of truth.

3. **Generalise the performed unit into a discipline-tagged, units-explicit measured-effort
   model, additively.** Strength becomes one special case of a general "effort with metrics":

   ```jsonc
   // strength (today's shape, still valid):
   { "set": 1, "metrics": { "reps": 5, "load": "100kg", "rpe": 8 } }

   // run interval:
   { "effort": 1, "kind": "interval",
     "metrics": { "distance": "400m", "duration": "PT1M30S", "avg_hr": 168 } }

   // steady-state cardio:
   { "kind": "steady",
     "metrics": { "distance": "5km", "duration": "PT25M", "avg_hr": 150 } }
   ```

   Principles:
   - A **discipline** tag on the exercise/block (`strength`, `run`, `row`, `erg`, `mobility`, …)
     lets renderers and the engine branch.
   - An **open metrics map with explicit units** (ISO-8601 durations, typed weight/distance)
     instead of hardcoded `reps`/`load` columns — new activities add metric keys, not schema
     breaks.
   - The **log schema may run ahead of the engine.** Hybrid efforts can be recorded today even
     though progression logic only understands strength; non-strength efforts pass through as
     tracking-only (the same posture as a `tracking_only` swap, mvp-spec §12.2A).

## Consequences

- The log stays the durable, replayable, Git-friendly source of truth; readability is delivered
  by export tooling, decoupled from storage.
- Schema evolution rides on the existing `schema_version` field on events: readers tolerate
  unknown/optional keys; old logs remain valid. The strength `ActualSet` keys are retained as a
  recognised subset of `metrics` for a transition period rather than removed.
- Plan/program *lifecycle* tracking (how a `plan.fitspec` change or program completion is
  recorded) is related but separate; see [ADR 0002](0002-plan-lifecycle-events.md).

## Implementation status

- **Tier 0 (done):** `ActualSet` carries an open `metrics: BTreeMap<String,String>` map
  (`engine/src/model.rs`) — the first concrete step of the measured-effort schema. It records
  metrics like `rpe` / `rir` (and later velocity) losslessly: the engine passes them through
  replay without acting on them, the `per_set_reps` path preserves them automatically, and the
  field is `skip_serializing_if` empty so existing logs and hashes are byte-identical. In the
  post-[ADR 0007](0007-logs-as-record-state-as-truth.md) shape, the iOS app can populate per-set
  RPE and the lean monthly log preserves it in `LiftRecord.actual[].metrics`; `rpe` becomes
  meaningful to progression only under [ADR 0004](0004-rpe-autoregulation.md).
- **Still to do:** the `knurled export` projection; promoting the strength keys (`reps`, `load`)
  into the same `metrics` model; a `discipline` tag on the rendered/prescribed shapes; engine
  pass-through for unknown disciplines.
