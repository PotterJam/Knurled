# Training Repo Contract

> **Updated by [ADR 0007](adr/0007-logs-as-record-state-as-truth.md) and
> [ADR 0009](adr/0009-program-bank-and-shared-history.md).** Logs are
> a human-facing record the engine never replays; `state/current.json` is the
> authored-forward source of truth, not a projection of logs. The clauses below
> reflect that model. The pre-ADR-0007 event-log/replay description survives in
> [ADR 0001](adr/0001-training-log-format.md) for history.

A valid Knurled training repo keeps user-owned source files separate from generated projections.

```text
my-training/
  fitspec.toml
  programs/
    my-gzclp/
      plan.fitspec
      fitspec.lock
      patches/
      templates/
      state/current.json
    my-531/
      ...
  logs/
  build/current.ir.json
  build/next-workout.json
  build/validation.json
  README.md
```

## Canonical Files

`fitspec.toml` names one active program and lists the program bank. The engine resolves all hot
path operations through that active entry.

`programs/<slug>/plan.fitspec` defines one plan and template configuration.

`programs/<slug>/fitspec.lock` freezes template versions, content hashes, and engine compatibility.

`programs/<slug>/patches/*.fitspec` contains explicit future-plan changes.

`logs/<yyyy>/<mm>.json` contains the training record: a versioned, pretty-printed month of
session-grain `TrainingRecord` entries. Record IDs, not dates, define identity, so any number of
workouts and program markers may share a date. The record is
*what happened*; the engine never replays it to compute state. It is the input to the opt-in
backtest and to the human's history/charts.

## State and Generated Files

`programs/<slug>/state/current.json` is the **source of truth** for where that program is:
the program-shaped progression cursor per lane (working load, stage, fail-count, or training
max/week). It is authored forward — updated when a session is submitted (`advance`/`off day`/
`reset`) — not re-derived from logs. Starting a new program, or restarting lighter after a
layoff, is just re-authoring `state`.

`build/current.ir.json` is the compiled active plan.

`build/next-workout.json` is the rendered execution contract for the next session.

`build/validation.json` is the validation report.

`build/*` files derive from `state` + the compiled plan and are committed for MVP convenience.
They are regenerated on demand; `knurled check-generated` reports drift.

Legacy repositories with root `plan.fitspec`, `fitspec.lock`, `patches/`, and `state/` remain
readable as one implicit program. The first program-bank mutation migrates those files under
`programs/<slug>/`; shared `logs/` and generated `build/` stay at the repository root.
