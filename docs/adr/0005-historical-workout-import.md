# ADR 0005 - Historical workout import uses a flat staging format and non-progressive session events

- Status: Accepted
- Date: 2026-06-24

## Context

Users often have years of training history in tools such as Hevy, StrengthLevel, spreadsheets, or
ad hoc notes. That data is usually flat: one row per set, or one row for N identical sets. Knurled's
canonical training record is not flat: [ADR 0001](0001-training-log-format.md) keeps
`logs/**/*.jsonl` as an event log at session grain.

Historical imports also do not necessarily map to the current FitSpec plan. A past workout may come
from a different program, have no rendered session hash, use exercise names that are not in the
current template, or predate the repo entirely. Treating those rows as ordinary
`session_completed` events would silently advance the current program cursor and could rewrite
progression state from data that was never rendered by this engine.

[ADR 0002](0002-plan-lifecycle-events.md) is related but not a substitute. `plan_changed` records
program boundaries such as "switched from Hevy history to this FitSpec plan"; it does not carry
workout sets, loads, reps, or RPE.

## Decision

Add a CLI import boundary:

```bash
knurled import-history <repo> <file.csv> --source hevy
```

The command accepts `history-flat-v1`, a deliberately flat staging format. Rows are grouped into one
canonical event per `(date, session, source_workout_id)` and written to
`logs/imports/<source>.jsonl`.

### `history-flat-v1`

Required columns:

| Canonical column | Meaning |
| --- | --- |
| `date` | Workout date or timestamp. Prefer ISO-like `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS`. |
| `exercise` | Exercise name. Normalized the same way FitSpec normalizes exercise names. |
| `reps` | Whole-number reps for the set. |

Optional columns:

| Canonical column | Meaning |
| --- | --- |
| `session` | Workout/session title. Defaults to `Imported Workout`. |
| `source_workout_id` | Stable source workout id, used to split same-day sessions. |
| `set` | Set number. If absent, set numbers are assigned in row order per exercise. |
| `sets` | Number of identical sets represented by this row. Defaults to `1`. |
| `load` | Load string, either already unit-suffixed (`100kg`) or paired with `unit`. |
| `unit` | `kg` or `lb` when `load` is numeric. |
| `rpe`, `rir`, `set_type`, `notes`, `duration`, `distance`, `rest_seconds` | Stored in `ActualSet.metrics`. |
| `metric_*` | Any custom set metric; the prefix is removed in the stored metric key. |

The importer also accepts common source aliases, including:

- Hevy-like: `title`, `start_time`, `exercise_title`, `set_index`, `weight_kg`, `weight_lb`.
- Spreadsheet/StrengthLevel-like: `workout_title`, `exercise_name`, `weight`, `sets`,
  `repetitions`.

Example:

```csv
date,session,exercise,set,load,unit,reps,rpe
2024-01-02,Push Day,Bench Press,1,80,kg,5,8
2024-01-02,Push Day,Bench Press,2,80,kg,5,8.5
2024-01-02,Push Day,Barbell Row,1,70,kg,8,
```

Aggregate rows are allowed:

```csv
date,session,exercise,sets,load,unit,reps
2024-02-03,Strength Levels,Squat,3,100,kg,5
```

### Canonical event shape

Imported sessions are written as `session_imported`, not `session_completed`:

```jsonc
{
  "id": "evt_import_hevy_20240102_...",
  "type": "session_imported",
  "status": "imported",
  "program": "history_import:hevy",
  "session_id": "push_day",
  "reason": "Push Day",
  "completed_at": "2024-01-02T00:00:00Z",
  "results": [
    {
      "slot_id": "bench_press",
      "performed_exercise": "bench_press",
      "prescribed": { "source": "history_import", "format": "history_flat_v1" },
      "actual": [{ "set": 1, "load": "80kg", "reps": 5, "metrics": { "rpe": "8" } }],
      "outcome": "imported",
      "effects": []
    }
  ],
  "effects": []
}
```

Rules:

- Imported sessions are historical facts. They do not carry `plan_hash`, `template_hash`, or
  `rendered_session_hash`.
- Replay does not apply progression effects or advance the active program cursor for imported
  sessions.
- When an import represents a program boundary, write a separate ADR 0002 `plan_changed` marker.
  The marker explains the lifecycle transition; imported session events carry the workout facts.
- Re-running the same import is idempotent by event id: existing event ids are skipped.

## Consequences

- Users get a simple flat file contract for Hevy, StrengthLevel, spreadsheets, and one-off scripts.
- Knurled keeps JSONL as the only canonical log format; CSV/TSV remains an ingestion boundary.
- Historical data can appear in app history without corrupting the next workout projection.
- Later work can add source-specific adapters or a "promote imported history into current state"
  wizard that emits explicit `state_adjusted` and `plan_changed` events.
