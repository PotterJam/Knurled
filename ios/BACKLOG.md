# Knurled iOS — backlog

Deferred items from the code review. These are real but post-MVP — captured here so they
aren't lost. Nothing here blocks the core loop (next workout → log → submit → commit → sync).

## RFC-0001 Tranche 1 — iOS surfaces (engine + models ready, UI pending)

The engine work landed on `claude/rfc-review-refinement-gw3t2v` (see the refined
[RFC-0001](../docs/rfc/0001-cockpit-jtbd.md) §5/§6 and ADRs 0011/0012). The Swift models,
FFI functions, and `PlanEdit` cases already exist; each item below is a thin SwiftUI surface
over a typed engine call:

- **Workout header date + description.** Show `nextWorkout.suggestedDate` ("Thu 2 Jul") and
  `displayDescription` in `WorkoutHomeView`; the engine derives both (RFC-0001 D4/D3).
- **Reschedule row.** "Can't make it? Reschedule" → date sheet → `PlanEdit.reschedule(toDate:note:)`.
- **Deload card + form.** Show a dismissible card when `suggestProgramAdjustments` returns
  `kind == "deload_week"` (`displayText` carries the copy); Plan Overview gets "Plan a deload
  week" (percent slider, lane scope, preview) → `PlanEdit.deload(...)`.
- **Swap + temporary-change sheets.** "Swap exercise" (catalog picker) →
  `PlanEdit.swapExercise`; "Temporary change" (Load / Swap tabs, optional until-date) →
  `PlanEdit.temporaryLoadAdjust` / `.temporarySwap`. Active managed patches
  (`patches/swap-*`, `tmp-*`) should list as removable rows via `deletePatch`.
- **Labels everywhere.** Replace remaining raw `progressionLane`/tier text with
  `display.label` + `display.group`; add the "About this program" screen backed by
  `knurled_explain` (FFI binding exists; add the Swift protocol method when building this).
- **Invalid-plan banner + retry affordance.** Surface `BuildOutputs.staleReason` as the yellow
  "showing the previous workout" banner; use `EngineError.isRetryable` for a retry affordance
  on I/O failures.
- **Onboarding picker + wizard (D1/D2).** Searchable template picker first;
  "Not sure? Help me choose" → 3 questions → `knurled_recommend_template`. iCloud
  default-repo per RFC-0001 Risk 1 resolution (A): git repo stays local, iCloud carries a
  serialized snapshot; needs its own ADR when built.
- **History rendering of new markers.** Log months now contain `reschedule` and `deload`
  records (ADR 0011); History should render them like program markers (the `note` is the copy).

## Feature surface

- **Broader corrections.** `HistoryDetailView` edits reps only. The spec also wants: correct a
  wrong *weight*, add a *forgotten final set*, add an exercise/accessory after the fact, attach
  *notes*, and correct *already-completed* workouts. The `session_corrected` change-path model
  (`results[slot].actual[i].reps`) would need to grow to cover load and added results.
- **Add ad-hoc accessory mid-workout** (slice 7's optional half). An accessory with
  `progression_lane: null`, plus an explicit optional `state_adjusted` event. Needs an
  "add exercise" entry point in the active workout and engine support for runtime-added items.
- **Adjust-today notes.** The Adjust sheet used to collect a free-text reason that had nowhere
  to go — the engine `ItemInput` / `ExerciseResult` has no per-item adjust-note field, so the
  input was removed. Re-add once the engine carries an adjustment reason.
- **`repeat_next_time` skip policy.** The engine currently advances the cursor on every
  `session_skipped` event, so only push-forward is meaningful. Differentiated repeat-next-time
  handling needs an engine change; the UI offers push-forward only for now.

## Sync / status UX

- **Richer sync status.** Surface last commit sha + time, generated-file freshness, and a
  plan-change summary ("Squat T1 80→82.5kg since last sync"). Today the daily screen shows
  plan valid/invalid and keeps the last valid snapshot, but not the detail.
- **Explicit "kept last valid snapshot" banner.** The fallback already works
  (`ActiveRepo.displayOutputs` prefers the last valid build); a visible banner explaining *why*
  the shown workout differs from the invalid remote would help.
- **Conflict UX.** A remote that moved ahead should refuse the push with a clear "open in
  GitHub" path (spec §29.3). The push currently marks the repo pending on any failure; a typed
  conflict case would be friendlier.

## Live Activity

- **Set + load/reps in the rest activity.** `RestActivityAttributes.ContentState` currently
  carries the exercise title + end date. Add the upcoming set number and its target load×reps
  so the lock screen / Dynamic Island shows "next: set 2 · 80kg × 5".

## Done in this pass (for reference)

Snapshot-honored reduce, partial-save data preservation, continue-from-History
(`session_continued`), persisted repo selection + pending-push across launches, and a single
`record(...)` committer that all training actions funnel through.
