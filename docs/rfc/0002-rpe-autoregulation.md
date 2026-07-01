# RFC-0002 — RPE / e1RM autoregulation

**Status:** Proposed
**Date:** 2026-07-01
**Promotes:** [ADR 0004](../adr/0004-rpe-autoregulation.md) from *Proposed* → *Accepted*
**Split from:** [RFC-0001 §3 D7](0001-cockpit-jtbd.md) (deferred there because this is a determinism-model + DSL-grammar change, not a rendering change)
**Boundary:** the engine owns e1RM math, the RPE→%1RM table, and all progression decisions; iOS only surfaces suggestions and records the logged load. (AGENTS.md)

---

## 1. Problem statement

Per-set RPE is captured today — the iOS set-detail editor writes it into `LiftRecord.actual[].metrics`, and the lean monthly logs preserve it losslessly (ADR 0004 §Consequences, ADR 0001 Tier 0). But the engine never reads it: it computes no e1RM and makes no progression decision from RPE. The result is **dead data that confuses users** — the app asks for a number it then ignores.

RPE/RIR-targeted training is mainstream-intermediate (RTS, Juggernaut, GZCL, most modern hypertrophy). Leaving it unconsumed is the single largest gap between what Knurled records and what it does with the record.

## 2. Why this is its own RFC (the determinism question)

ADR 0003 originally excluded RPE-as-load-selection on the grounds that it "breaks determinism." ADR 0004 shows that guarantee is really **two**:

- **Replay determinism** — `events + plan → state` is pure. RPE autoregulation *preserves* this: the load used is a **logged input**, exactly like AMRAP reps already are. `records + plan → state` stays exact.
- **Forward computability** — `plan + history → future sessions` with no new input. RPE autoregulation *complicates only this*: the engine cannot render an exact future load that depends on a judgment (the RPE) it does not have yet.

The whole bet rests on separating these two, and on fixing + versioning two tables for reproducibility. That reasoning is why it earns a dedicated RFC rather than a bullet in the cockpit UX RFC.

## 3. Decisions

### D1 — e1RM is the progression currency

Each working set's `(load, reps, rpe)` estimates a 1RM through a fixed RPE→%1RM table (Epley for the reps component; the RTS chart for the RPE component). Progression is expressed against e1RM. The table is an implementation detail but **must be fixed and versioned**, tied to `engine_version`, so replay stays reproducible.

- **Table location:** `engine/data/rpe_table.v1.toml` — committed and versioned, preferred over an embedded Rust const so the table can be revised (a `v2`) without an engine rebuild and its provenance is auditable. (Resolves RFC-0001 §7 Q6.)

### D2 — DSL primitive additions (extend the five axes, per ADR 0004 §2)

The engine today has `DslBasis::{WorkingWeight, TrainingMax, Bodyweight}` (`engine/src/dsl.rs`). This adds:

- **Basis:** `DslBasis::E1rm`. Loads prescribable as `% of e1rm`; e1RM updated from logged `(load, reps, rpe)`.
- **Scheme flag:** `rpe(target)` on a set ("top set 3 @ rpe 8"); backoffs as `@ -X%` or `@ rpe<=cap`.
- **Triggers:** `DslTrigger::OnRpe { op, threshold }` (`on rpe <= target` → progress; `on rpe >= cap` → hold/deload) and `DslTrigger::OnE1rmPR`, banded like the existing AMRAP thresholds.
- **Effect:** `DslEffect::SetLoadPctOfE1rm { percent }`, plus a `recompute_e1rm` step, alongside the existing `increase_load` / `deload`.

### D3 — Real training: load is a logged input

The engine prescribes reps + target RPE; the lifter supplies the load (Role A autoregulation). Load and RPE are recorded; e1RM is computed from those actuals; **replay is exact**. No change to the replay contract.

### D4 — Simulation: a linear virtual lifter

For forward `simulate` / `backtest`, model the lifter as **linear e1RM growth** — a configurable per-lane gain rate (`+X kg/week` or `+Y%/week`) with versioned defaults, optionally keyed to template/experience. Given starting e1RM + assumed rate + program rules, the projection is fully deterministic. Rules:

- Simulated loads are **projections under an assumed rate**, labelled as such, never promises.
- Backtest/replay of *recorded* sessions uses the real e1RM from the logs; only forward projection uses the linear model.
- Default growth rates are fixed and versioned, like the RPE table.

### D5 — `next_session_loads` API

New engine API `next_session_loads(repo) -> Vec<NextLoadReport { lane, prescribed_load, suggested_load, autoreg_recommendation: Option<AutoregProposal> }>`. The engine computes the AutoReg proposal from the most recent `(load, reps, rpe)` on that lane. iOS shows it as an opt-in per-set chip.

## 4. Engine API additions

| API / type | Where | Notes |
|---|---|---|
| `DslBasis::E1rm` | `dsl.rs` | new basis word `e1rm` in parser + serializer (`basis_word`) |
| `DslTrigger::OnRpe { op, threshold }` | `dsl.rs`, `core.rs` | banded like AMRAP thresholds |
| `DslTrigger::OnE1rmPR` | `dsl.rs`, `core.rs` | |
| `DslEffect::SetLoadPctOfE1rm { percent }` | `dsl.rs`, `core.rs` | |
| e1RM calculator + `rpe_table.v1.toml` loader | `core.rs` (+ `engine/data/`) | fixed, versioned |
| `next_session_loads` | `plan_edit.rs` | `Vec<NextLoadReport>` |
| linear simulation model + versioned default rates | `backtest.rs` | forward projection only |

## 5. iOS UX

- **AutoReg chips (live workout):** when `autoreg_recommendation` is present, a subtle per-set chip — "Based on RPE 9 → try 97.5kg". Tapping applies it to that set's load. No UI on `FinishWorkoutView`, which stays a confirmation screen.
- **`explain` reuse:** `e1RM`, `AMRAP`, and `RPE` get one-line definitions via the RFC-0001 `explain` API rather than inline glossary text.

## 6. Sequencing

Gated on the RFC-0001 display-label + `explain` work only for the chip copy; otherwise independent. Each engine PR ships with `engine/tests/` coverage and its `engine-wasm` binding in the same PR (per RFC-0001 §6).

1. e1RM calculator + versioned `rpe_table.v1.toml`; unit tests against known RTS chart values.
2. `DslBasis::E1rm`, `rpe` scheme flag, `OnRpe` / `OnE1rmPR` triggers, `SetLoadPctOfE1rm` effect; round-trip serializer tests.
3. `next_session_loads`; `engine-wasm` binding.
4. Linear simulation model + versioned default growth rates in `backtest.rs`.
5. iOS AutoReg chips.

## 7. Open questions

1. **Default growth rate(s):** single global default, or keyed to template/experience? Must be fixed + versioned either way.
2. **e1RM smoothing:** raw last-set e1RM vs. a best-of-recent or rolling estimate — which drives the suggestion?
3. **Interaction with percentage programs:** for a lane whose basis is `working_weight`/`training_max`, is AutoReg offered at all, or only for `e1rm`-basis lanes?

---

*End of RFC-0002*
