# PRD: iOS-Guided Plan Editing

## Problem Statement

Knurled users discover most program-change needs while using the iOS app: their gym has different
plates, an exercise is unavailable, an injury needs a temporary substitution, training days change,
or a novice program has run its course. Requiring the CLI or workbench for these everyday changes
would make the app feel incomplete.

At the same time, iOS must not become a second program engine. Program semantics, FitSpec parsing,
state rewrites, patch validation, generated-file updates, and future modelling must remain in the
engine so every client gets the same answer.

## Solution

Make iOS the primary place for normal lifter-facing plan changes, implemented as guided,
intent-based flows backed by engine-owned edit commands.

iOS should collect user intent such as "change plates", "add a temporary patch", "replace this
exercise", or "switch to 5/3/1". The app sends typed inputs to the engine, then displays returned
validation, changed files, and the next-workout preview. The engine remains the pure input/output
machine and owns all program meaning.

CLI and workbench remain the lab for serious testing, modelling, comparison, raw FitSpec editing,
and future template authoring.

## User Stories

1. As a lifter, I want to change my available plates in the app, so that future workouts use loads I can actually make.
2. As a lifter, I want to change my training days in the app, so that suggested days match my schedule.
3. As a lifter, I want to add a temporary exercise replacement, so that I can train around injury or equipment limits.
4. As a lifter, I want to add conditioning as a temporary patch, so that short training blocks are tracked without rewriting the whole plan.
5. As a lifter, I want to cap a target such as RPE for a block, so that I can manage fatigue.
6. As a lifter, I want patches to have optional start and end dates, so that temporary changes are explicit.
7. As a lifter, I want to switch to a built-in program from iOS, so that graduating from LP does not require a desktop workflow.
8. As a lifter, I want to enter initial numbers during a program switch, so that the new program starts with sensible state.
9. As a lifter, I want to preview whether an edit is valid before it affects my repo, so that I can avoid breaking my next workout.
10. As a lifter, I want the app to show validation errors in plain language, so that I can fix bad edits.
11. As a lifter, I want plan edits to sync through my existing GitHub repo, so that the repo remains the source I own.
12. As a power user, I want CLI/workbench modelling to remain separate, so that deeper experiments do not clutter the mobile app.
13. As a developer, I want iOS to send structured intent rather than edit FitSpec text, so that program semantics do not drift.
14. As a developer, I want the engine to return exact changed files, so that Git commits are predictable.
15. As a developer, I want program switching to create fresh program-shaped state, so that old state does not corrupt the new program.
16. As a developer, I want program switches to write human-facing program markers, so that history remains understandable.

## Implementation Decisions

- iOS owns guided UX, form state, navigation, validation display, and GitHub commit/push orchestration.
- The engine owns FitSpec parsing/serialization, patch file content, generated files, state rewrites, program markers, validation, and next-workout previews.
- The app must communicate with the engine through typed edit inputs, not raw text manipulation.
- The first mobile edit surface is split into three paths:
  - Quick edits: equipment, suggested days, supported simple permanent changes.
  - Patches: guided temporary/contextual changes such as replacement, conditioning, and caps.
  - Program switch: guided replacement of the active plan with a built-in template.
- Program switching is not a patch. It rewrites the active plan, creates fresh program-shaped state, rebuilds generated files, and records a program marker.
- The iOS app should not expose raw FitSpec editing in the MVP.
- CLI/workbench remain the right place for simulation, backtesting, program comparison, raw inspection, and future template authoring.
- Any future iOS expansion should add new typed engine commands rather than making Swift understand more program semantics.

## Testing Decisions

- Engine tests should cover external edit behavior: preview does not mutate, apply writes expected canonical/generated files, invalid edits do not commit, and program switch creates valid state plus a marker.
- FFI tests/builds should verify that typed edit commands round-trip through JSON envelopes.
- iOS tests should verify that forms create the expected typed edit payloads and display engine validation results.
- GitHub tests should verify that app commits use engine-returned file paths, including deleted patch files.
- Avoid tests that assert Swift-side FitSpec formatting, because Swift should not own that formatting.

## Out of Scope

- Raw FitSpec editor in iOS.
- Arbitrary user-authored template/program logic in iOS.
- Full modelling, backtesting, or multi-program comparison in iOS.
- Coach/team workflows.
- Marketplace/template sharing.
- Rebuilding CLI/workbench authoring flows before the app-guided path proves out.

## Further Notes

The product posture is: **iOS is the training cockpit; CLI/workbench is the lab.**

The implementation posture is: **iOS owns intent; the engine owns meaning.**
