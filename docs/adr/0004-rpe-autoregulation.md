# ADR 0004 — RPE / e1RM autoregulation, and simulating it with a linear model

- Status: Proposed
- Date: 2026-06-24

## Context

[ADR 0003](0003-template-authoring-model.md) deferred RPE-as-load-selection to a "Tier 1" and
listed it as out of scope, on the grounds that it breaks the determinism guarantee. On closer
inspection that guarantee is really **two** guarantees:

- **Replay determinism** — `events + plan → state` is pure. Same log, same projection.
- **Forward computability / simulation** — `plan + history → future sessions` with no new input.

RPE autoregulation preserves the first (the load used is a *logged input*, like AMRAP reps
already are) and only complicates the second (you can't render an exact future load that depends
on a judgment you don't have yet). [ADR 0001](0001-training-log-format.md) Tier 0 already records
RPE losslessly via `ActualSet.metrics`, so the data is captured today.

RPE/RIR-targeted training is now mainstream-intermediate (RTS, Juggernaut, GZCL, most modern
hypertrophy), so it belongs in scope, not in the excluded tail.

Since this ADR was written, the logs-as-record model ([ADR 0007](0007-logs-as-record-state-as-truth.md))
has replaced replay events. The core idea still holds: RPE is an actual performed input, not
something inferred by the engine. Today the iOS set-detail editor can capture per-set RPE and the
lean record preserves it in `LiftRecord.actual[].metrics`; the engine still does not compute e1RM
or make progression decisions from it.

## Decision

Support RPE/e1RM autoregulation as **Tier 1**, layered on the [ADR 0003](0003-template-authoring-model.md)
primitives.

### 1. e1RM is the progression currency

Each working set's `(load, reps, rpe)` estimates a 1RM via a fixed RPE→%1RM table (e.g. the RTS
chart: 3 reps @ RPE 8 ≈ 81%, so `e1rm = load / 0.81`). Progression is expressed against e1RM.
The exact table is an implementation detail but **must be fixed and versioned** (tied to
`engine_version`) so replay stays reproducible.

### 2. Primitive additions (extend the five axes)

- **Basis:** add `e1rm` alongside `working_weight` / `training_max`. Loads prescribable as
  `% of e1rm`; e1rm updated from logged `(load, reps, rpe)`.
- **Scheme flag:** `rpe(target)` on a set ("top set 3 @ rpe 8"); backoffs as `@ -X%` or
  `@ rpe<=cap`.
- **Triggers:** `on rpe <= target` (easy → progress), `on rpe >= cap` (hold/deload),
  `on e1rm_pr` — banded like the AMRAP thresholds.
- **Effects:** `set_load = pct * e1rm`, `recompute_e1rm`, plus the existing `increase_load` /
  `deload`.

### 3. Real training: load is a logged input

The engine prescribes reps + target RPE; the lifter supplies the load (Role A autoregulation).
The load and RPE are recorded, e1RM is computed from those actuals, and **replay is exact and
deterministic** — no change to the replay contract.

### 4. Simulation: a linear "virtual lifter"

For forward `simulate` / `backtest`, model the lifter as **linear e1RM growth**: a configurable
gain rate per lane (e.g. `+X kg/week` or `+Y%/week`), with sane defaults (optionally keyed to
template/experience level). Given the starting e1RM, the assumed rate, and the program rules, the
projection is **fully deterministic and predictable** — the same way percentage programs are
implicitly simulable. Refinements (diminishing returns, plateaus) can replace "linear" later
without changing the contract, because the rate is just a parameter.

Rules:

- Simulated loads are **projections under an assumed growth rate**, clearly labelled as such, not
  promises.
- Backtest/replay of *recorded* sessions uses the real e1RM from the logs (exact); only forward
  projection uses the linear model.
- The default growth rate(s) are fixed and versioned for reproducibility, like the e1RM table.

## Consequences

- Brings autoregulation to a mainstream audience while keeping **replay deterministic** and
  **forward simulation predictable** (linear model). The previously-feared "determinism" blocker
  dissolves once the two guarantees are separated.
- This **revises [ADR 0003](0003-template-authoring-model.md)'s boundary**: RPE/e1RM moves from
  out-of-scope into Tier 1. Still out: velocity-based training (needs a velocity input stream /
  hardware) and bespoke coach individualisation (served by manual plan edits or explicit
  `state/current.json` edits under [ADR 0007](0007-logs-as-record-state-as-truth.md)).
- Two things must be fixed + versioned for reproducibility: the **RPE→%1RM table** and the
  **default simulation growth rate(s)**.
- Simulation output for autoregulated programs is explicitly model-based (assumption stated),
  distinct from percentage programs (intrinsically prescribed) — but both remain deterministic.
- Implementation status:
  - Done: per-set `metrics.rpe` can be captured by the iOS workout UI and is serialized through
    `ActualSet.metrics` into lean monthly logs when present.
  - Not done: RPE/e1RM progression semantics.
- Implied work, gated on the ADR 0003 DSL landing first:
  1. e1RM calculator + versioned RPE→%1RM table in the engine.
  2. `e1rm` basis, `rpe` scheme flag, `on rpe`/`e1rm_pr` triggers, `set_load = pct*e1rm` effect.
  3. Linear simulation model + versioned default growth rates.
  4. App work to surface RPE-driven consequences once the engine consumes RPE.
