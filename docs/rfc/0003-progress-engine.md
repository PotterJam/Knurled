# RFC-0003 — Progress engine

**Status:** Proposed
**Date:** 2026-07-01
**Split from:** [RFC-0001 §3 D8](0001-cockpit-jtbd.md) (deferred there as an independent analytics surface)
**Boundary:** the engine owns trend/tonnage/plateau computation and the suggested-action copy; iOS renders cards. (AGENTS.md)

---

## 1. Problem statement

The Data tab is a single Epley chart. The engine knows every state transition — `LaneState` carries `load`, `stage`, `training_max`, `week`, `cycle`, `reps`, `stall` (`engine/src/model.rs`), and the logs hold every performed set — yet it offers no trend, no plateau detection, and no volume insight. All analytics are re-derived ad hoc on the client, which the architecture boundary forbids.

`suggest_program_adjustments` (`engine/src/suggest.rs`) today emits only two kinds — `deload` (lane at a final failure stage) and `stall` (three equal-load attempts with zero final-set reps) — computed by scanning recent records inline. There is no reusable progress model underneath it.

## 2. Decisions

### D1 — a `progress` module

New module `engine/src/progress.rs` with:

- `progress_summary(repo, weeks: u32) -> ProgressSummary`
  - `ProgressSummary { per_lane: Vec<LaneProgress> }`
  - `LaneProgress { lane, display_label, e1rm_trend, tonnage, prs, plateau_weeks, suggested_action }`
- `history_feed(repo, since: Option<NaiveDate>) -> Vec<TrainingRecord>` — time-bounded queries so the client stops loading the full log.

`display_label` comes from the RFC-0001 D3 label work; `e1rm_trend` uses the e1RM calculator from RFC-0002 where available and falls back to a reps×load estimate otherwise (tonnage and plateau detection do **not** depend on RFC-0002).

### D2 — `suggest_program_adjustments` is rebuilt on `progress_summary`

The existing inline scan is replaced by consuming `progress_summary` internally, so the `deload` / `stall` heuristics and the new progress-driven suggestions share one source of truth. This is a **superset** of, and lands after, the marker-based `deload_week` suggestion introduced in RFC-0001 D6 (which is intentionally computed from cursor weeks + last `DeloadMarker` only, so it can ship without this module). `ProgramAdjustmentSuggestion` keeps its `{ kind, lane, reason, proposed_value }` shape and gains the `user_description` field from RFC-0001 D3.

## 3. Engine API additions

| API | Input | Output | Module |
|---|---|---|---|
| `progress_summary` | `repo`, `weeks` | `ProgressSummary` | `progress.rs` |
| `history_feed` | `repo`, `since` | `Vec<TrainingRecord>` | `progress.rs` |
| `suggest_program_adjustments` (rebuilt) | `repo` | `Vec<ProgramAdjustmentSuggestion>` on top of `progress_summary` | `suggest.rs` |

## 4. iOS UX

- **Per-lane trend cards** replace the single chart: one card per core lane — e1RM line, tonnage bars for the last 4 weeks, plateau count, and a suggested-action chip ("continue" / "deload" / "switch program").
- **History feed** uses `history_feed` with time bounding instead of loading the full log.
- After an amend-record save, iOS flashes which lanes recomputed ("Squat updated to 102.5kg" / "No progression changes").

## 5. Sequencing

Independent of onboarding and reschedule. Depends on RFC-0001 D3 (`display_label`) for card titles; benefits from RFC-0002 (e1RM) for the trend line but degrades gracefully without it. Each engine PR ships with `engine/tests/` coverage and its `engine-wasm` binding in the same PR.

1. `progress.rs` with `progress_summary` + `history_feed`; unit tests over fixture logs.
2. Rebuild `suggest_program_adjustments` on the module; regression-test the existing `deload`/`stall` kinds are unchanged.
3. `engine-wasm` bindings.
4. Data tab rebuild (per-lane cards + history feed).

## 6. Open questions

1. **Plateau definition:** what counts as a plateau week — no e1RM improvement, no load increase, or no PR? This pins `plateau_weeks`.
2. **Tonnage basis:** working sets only, or working + AMRAP + backoff? Warmups are excluded (they never feed progression), but the rest needs a rule.
3. **Suggested-action vocabulary:** fixed enum (`continue`/`deload`/`switch`) vs. free `String`. An enum keeps iOS from string-matching.

---

*End of RFC-0003*
