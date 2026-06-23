# Knurled iOS — backlog

Deferred items from the code review. These are real but post-MVP — captured here so they
aren't lost. Nothing here blocks the core loop (next workout → log → submit → commit → sync).

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
