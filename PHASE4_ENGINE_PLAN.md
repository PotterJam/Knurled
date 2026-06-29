# Phase 4 — Engine Batch: Execution Plan

This document is a self-contained brief for an engineer/LLM picking up the **engine-heavy batch**
of the Knurled UX revamp. Phases 0–3 (Swift-only) are already done, building, and test-green; this
batch is everything that needs the **Rust engine + a `KnurledCore.xcframework` rebuild**, bundled
so there's a single rebuild and the cross-boundary changes land together.

> **Golden rule (from `AGENTS.md`):** training semantics live in the **engine**, not Swift. The
> iOS app collects intent, calls typed engine APIs, and renders results. Do **not** add Swift-side
> FitSpec parsing, progression rules, or load math when an engine API can own it.

---

## 0. How this repo works (read first)

### Layout
- `engine/` — the Rust `knurled-core` crate. All training logic.
  - `src/model.rs` — data model (`Plan`, `TemplateKind`, `RestPolicy`, `EquipmentProfile`, `Implement`, `CustomExercise`, `ExerciseCatalogEntry`).
  - `src/parser.rs` — `parse_plan(text) -> Plan` (the `.fitspec` configuration parser; ~30KB).
  - `src/core.rs` — `compile_plan`, `create_initial_*_state`, `render_*_next`, `compute_warmups` (~779–844), load snapping (`snap_load` ~2086, `snap_with_equipment` ~2093, `snap_barbell` ~2159, `reachable_per_side_sums` ~2182).
  - `src/templates.rs` — `BUILTIN_TEMPLATES` (~28), `default_exercise_alternatives` (~823), `gzclp_template`/`five_three_one_template`/`starting_strength_template`.
  - `src/plan_edit.rs` — `PlanEdit` handling: `Quick` arm (~242), `starter_plan` (~374), `render_plan` (~570), `render_rest` (~699), `suggest_initial_numbers` (~170), `switch_program` (~303–337).
  - `src/repo.rs` — repo IO: `read_training_repo` (~38), `read_state`/`write_state`, `build_repo`, `read_records`, `init_training_repo`, `simulate_repo` (~130), `backtest_records_repo` (~560).
  - `src/record.rs` — record + amendment logic (`RecordAmendment`, revisioning).
  - `src/backtest.rs`, `src/session.rs`, `src/json.rs`, `src/error.rs`, `src/lib.rs` (public re-exports).
- `ios/Engine/knurled-ios-ffi/` — Rust `staticlib` wrapping `knurled-core` behind a C ABI. **JSON in / JSON out.** Every fn takes a `dir` C-string and returns a JSON envelope `{"ok":true,"data":…}` or `{"ok":false,"error":"…"}`.
  - `src/lib.rs` — the `knurled_*` C functions.
  - `include/knurled_core.h` — C header (must be kept in sync with `lib.rs`).
- `ios/Knurled/` — SwiftUI app. Key spots:
  - `Models/` — Codable mirrors of engine DTOs: `PlanIR.swift`, `StateProjection.swift`, `RenderedSession.swift`, `Events.swift` (`TrainingRecord`, `LiftRecord`, `RecordAmendment`, `SubmitMode`), `PlanEdit.swift`, `Enums.swift` (`SwapPolicy`).
  - `Engine/RustWorkoutEngine.swift` (actor calling the FFI) + `WorkoutEngine.swift` (protocol).
  - `App/AppModel.swift`, `ActiveRepo.swift`, `AppModel+Commit.swift`, `AppModel+PlanEdit.swift`, `AppModel+RecordAmendment.swift`.
  - `Stores/DraftStore.swift` — **already added in Phase 1** (`WorkoutDraft`/`DraftItem`/`DraftSet` + file-backed store).
  - `Features/Workout/` — `LiveWorkout.swift` (`LiveSet`/`LiveItem`/`LiveWorkout`), `ActiveWorkoutView.swift`, `LiveExerciseCard.swift`, `FinishWorkoutView.swift`, `ResumeWorkoutView.swift`.
  - `App/WorkoutLiveController.swift` — live session + Live Activity controller.
  - `Live/RestActivityAttributes.swift`, `Live/WorkoutLiveIntents.swift`; widget in `ios/KnurledRestActivity/RestLiveActivity.swift`.
  - `Features/History/HistoryModels.swift` — history list + detail (currently a read-only `List`).
  - `Features/Plan/PlanEditViews.swift`, `PlanOverviewView.swift`.

### Build / test / verify commands
- **Engine tests:** `cd engine && cargo test`. Add tests under `engine/tests/`. There are existing ones e.g. `engine/tests/warmup_equipment.rs`.
- **Rebuild the xcframework after ANY Rust change** (the `.xcframework` is a gitignored build artifact):
  `cd ios && ./scripts/build-xcframework.sh` (compiles device + simulator, assembles `ios/Engine/KnurledCore.xcframework`). **The app will not see Rust changes until this runs.**
- **Regenerate the Xcode project after adding/removing Swift files** (no synchronized groups): `cd ios && xcodegen generate`. Sources are globbed under `Knurled/`, so new files are picked up.
- **Build the app:**
  ```sh
  cd ios
  SIM=$(xcodebuild -showdestinations -project Knurled.xcodeproj -scheme Knurled 2>/dev/null \
        | grep -i "platform:iOS Simulator" | grep -i iPhone | grep -oE 'id:[0-9A-F-]+' | head -1 | cut -d: -f2)
  xcodebuild build -project Knurled.xcodeproj -scheme Knurled -destination "id=$SIM" -configuration Debug 2>&1 \
        | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED"
  ```
- **Run the app test suite:** same as above but `xcodebuild test … 2>&1 | grep -iE "Suite .* (passed|failed)|TEST (SUCCEEDED|FAILED)|error:"`.
- **Ignore SourceKit "Cannot find type X in scope" / "unavailable in macOS" diagnostics** — the indexer analyzes against macOS; `xcodebuild` against the iOS simulator is the source of truth.

### Swift state already in place (Phases 0–3) that this batch connects to
- `LiveItem.isBodyweight` (in `LiveWorkout.swift`) is **name-based** today (`isBodyweightExercise`). Workstream B replaces it with an engine flag.
- `SetRowView` already supports `showsLoad` / `loadMissing` (bodyweight hides the weight chip; missing weight blocks ticking).
- `WorkoutDraft`/`DraftStore` exist (file at `Application Support/Knurled/workout-draft.json`). Workstream A extends the draft.
- `WorkoutLiveController` already has `adjustLoad`/`adjustRPE`/`skipWarmup`/`needsLoad`/`lastLoggedSet` and persists the draft on every mutation.
- `RecordAmendment` (in `Events.swift` + `engine/src/record.rs`) is **add-only** (`addSet`, `addExercise`). Workstream E extends it.

---

## Workstreams (sequence them in this order)

Dependency order: **A** (Swift-only, independent) → **B, C, D** (small engine + Swift) → **E** (medium engine) → **F** (large engine) → **G** (largest engine, the DSL). Each is independently shippable; do one, rebuild, verify, commit.

---

## A. Terminated-process Live Activity logging (Swift only — no engine)

**Problem:** `LiveActivityIntent.perform()` relaunches the app as a **fresh process** when iOS has
terminated it. `WorkoutLiveController.shared.workout` is then `nil`, so `logCurrentSet()` (and the
other lock-screen actions) silently no-op. This is the "doesn't log the exercise" bug.

**Fix:** make the controller rebuild the live workout from the persisted draft when it's empty.

1. **Persist enough to rebuild.** In `Stores/DraftStore.swift`, add the full rendered session and
   units to `WorkoutDraft`:
   - `var session: RenderedSession` (it's `Codable`).
   - `var unitsRaw: String` (or reuse the plan units) so a `LiveWorkout` can be built without a live `ActiveRepo`.
   Update `WorkoutLiveController.snapshot()` (in `WorkoutLiveController.swift`) to populate them.
2. **Make `LiveWorkout` buildable without a repo.** In `LiveWorkout.swift`, the live-session
   actions only need `units` from `repo` (`repo.plan?.plan.units`) — submit/finish needs `repo.url`,
   but a background intent never finishes. Either:
   - make `repo` optional and thread `units` directly, or
   - add a dedicated `init(session:units:draft:)` for the activity-only rebuild.
   Keep the existing `init(repo:session:draft:)` for the foreground path.
3. **Restore-on-demand in the controller.** Add `ensureWorkoutLoaded()` to
   `WorkoutLiveController`: if `workout == nil`, `DraftStore.shared.load()`, rebuild the
   `LiveWorkout` from `draft.session` + overlay, set `self.workout`, and restore the cursor
   (`restoreCursor(from:in:)` already exists). Call it at the top of every lock-screen action
   (`logCurrentSet`, `skipRest`, `addRest`, `adjustAmrap`, `skipWarmup`, `adjustLoad`, `adjustRPE`).
   After acting, the existing `persistDraft()` writes state back; the foreground `ActiveWorkoutView`
   reconciles via `begin(resumingFrom:)` on next appear.
4. **Edge:** if there's no draft (workout already finished/discarded), the actions stay a no-op.

**Verify:** **device required** (Live Activities don't run meaningfully in the simulator). Start a
workout, force-quit the app, lock the phone, tap Log on the lock screen → the set logs and the
activity advances; reopen the app and confirm the set is logged and consistent.

---

## B. Data-driven bodyweight exercises (engine + Swift)

**Goal:** replace name-based bodyweight detection with an explicit flag so bodyweight movements
carry no load (no weight UI, never blocked by the empty-load gate), and so the engine omits load
from their prescription/warmups.

**Engine (`engine/`):**
1. `model.rs`: extend the `Implement` enum with a `Bodyweight` variant (currently `Barbell`/`Dumbbell`).
2. `parser.rs`: parse `implement bodyweight` in the `exercises { … }` block of `.fitspec`.
3. `core.rs`: where prescription loads and `compute_warmups` are produced, if the resolved
   exercise's implement is `Bodyweight`, **emit `load: None`** and skip `snap_*`. Make sure
   `RenderedSession`/`PrescribedSet` already allow `load: null` (they do — load is optional).
4. `plan_edit.rs`: `render_plan` round-trips the new implement value; `starter_plan` may mark known
   bodyweight movements.
5. Tests: `engine/tests/` — a plan with a bodyweight exercise renders sets with `load: null` and no
   warmup plate math.

**FFI:** no new functions; the implement flows through existing `build_repo`/`render_session` JSON.

**Swift:**
1. `Models/RenderedSession.swift` / `PlanIR.swift`: surface the implement on the rendered item (add
   `implement` to `RenderedItem` or `DisplayFields`, or expose via the exercise catalog) so the app
   can ask "is this bodyweight?" from data.
2. `LiveWorkout.swift`: change `LiveItem.isBodyweight` to read the engine implement instead of
   `isBodyweightExercise(name)`. Keep the name-based check only as a fallback for legacy plans.
3. Delete/retire `LiveItem.isBodyweightExercise` and `LoadControl.isBodyweightExercise` name lists
   once the data path is in.

**Verify:** build + run; a bodyweight exercise (e.g. pull-ups defined with `implement bodyweight`)
shows reps-only, no weight chip, and ticks without a weight; a normal lift still requires a weight.

---

## C. History-seeded initial loads (engine reuse + Swift)

**Goal:** when an exercise appears with no plan/last-session load, prefill it from training history
(satisfies "get weights from history the first time"). Pairs with the empty-load gate.

**Engine:** reuse `suggest_initial_numbers` (`plan_edit.rs:170`) — it already scans global
`logs/**` by normalized exercise name. If a per-exercise lookup is cleaner, add a small
`suggest_load_for(dir, exercise) -> Option<String>` reading the same logs.

**FFI:** add `knurled_suggest_initial_numbers(dir, template_json)` if not already exposed, or a
lighter `knurled_suggest_load(dir, exercise)`. Mirror in `WorkoutEngine`/`RustWorkoutEngine.swift`.

**Swift:** when building a workout (the async render path, e.g. in `AppModel`/`ActiveRepo` before
`LiveWorkout` is constructed), for any item whose rendered load is `nil` **and** which is not
bodyweight, fetch a suggestion and pass it as the `LiveSet` default. Surface it as a *confirmable
prefill* (the empty-load gate still lets the user override) so stale history doesn't silently lock
in a wrong number.

**Decision already made:** source suggestions **globally** (all history), but only **prefill**
(never auto-commit) — the gate handles confirmation.

**Verify:** import/keep history for a lift, start a plan where that lift has no prescribed load →
the set is prefilled from the most recent history and is editable.

---

## D. Rest persistence + warmup plate rounding (engine + Swift)

### D1. Program-level rest editing
The model already supports it — only the write path is missing.
- **Engine:** `RestPolicy` exists (`model.rs:236`), is serialized by `render_rest`
  (`plan_edit.rs:699`), and resolved per item via the `RestSource` precedence chain (~`model.rs:520`).
  Add `rest: Option<RestPolicy>` to `PlanEdit::Quick` and, in the `Quick` match arm
  (`plan_edit.rs:242`), apply `if let Some(rest) = rest { plan.rest = rest; }` before `render_plan`.
- **Swift:** add `rest: RestPolicy?` to `QuickPlanEdit` (`Models/PlanEdit.swift`) with a Codable
  `RestPolicy` mirror; add a "Rest" section to the program editor UI. Do **not** put rest on
  `EquipmentProfile` (ADR 0006 keeps rest = program concern, equipment = gym concern).
- **Inline (during a workout):** tap the rest countdown in `ActiveWorkoutView`/`RestTimerBar` to
  adjust *this exercise's* rest for the session, with an optional "Save to program" that issues the
  `Quick { rest }` edit.

### D2. Warmup plate rounding ("warmups needed small plates I'd have to take off")
- **Engine:** in `compute_warmups` (`core.rs` ~779–844), round warm-up loads with a **coarser**
  step than working sets — e.g. snap to the nearest *larger* plate-pair already implied by the work
  set, so ramp sets never require adding/removing small plates. Honor
  `EquipmentProfile.platePairs`/`rounding`. Keep it behind the existing equipment profile so plates
  the user doesn't own are never prescribed.
- Tests: extend `engine/tests/warmup_equipment.rs` to assert warm-up loads use the coarse step.
- Aligns with ADR 0006 (`docs/adr/0006-warmup-sets-and-equipment-rounding.md`).

**Verify:** a working set of e.g. 100kg renders warm-ups that only use plates you'd keep on; engine
tests pass.

---

## E. Editable history + recompute-if-latest (engine + Swift; needs a short ADR)

**Goal (decided with the user):** history is **not** read-only. Opening any past workout shows the
same live cards, fully editable, with a **"Save changes"** button (not "Finish"). The only
differences from a live session: no rest timer / cursor / Live Activity, and saving writes back to
the record.

**Progression semantic (decided):** editing a record recomputes progression **only if it is still
the most recent record affecting that lane** (judged **per lane**). Example: did `a1`, then `b1`,
then edit `a1` → recompute (b1 didn't touch a1's lanes). Did `a1`, `a1` again, then edit the first
`a1` → history-only (the later `a1` superseded the lane). Otherwise edits are history-only.

**Engine (`engine/src/record.rs` + state):**
1. Extend amendments beyond add-only: add a **replace/edit** operation — simplest is "replace this
   record's lifts with this set of lifts" at a bumped `revision` (`RecordAmendment` is in
   `record.rs` + Swift `Events.swift`).
2. Implement **recompute-if-latest**: for each lane the edited record affects, determine whether any
   *later* record progressed the same lane. If none, recompute that lane's state from the edited
   record; else leave state untouched (history-only).
   - The clean way to recompute "the latest session's effect" without full log replay (ADR 0007
     says state is **authored, not derived**): keep **one step of previous state per lane** in
     `state/current.json`. Editing the latest record = restore the lane's previous state + re-apply
     the edited session's effect. You can only recompute the latest because only one step back is
     retained — which exactly matches the rule. This is a small `StateProjection` schema addition.
3. **Write a short ADR** (`docs/adr/0008-editing-records-and-one-step-state.md`) documenting the
   one-step-back state and the recompute-if-latest rule, since it touches the ADR-0007 boundary.

**FFI:** add `knurled_edit_record(dir, record_id, lifts_json)` (or extend the amendment FFI) that
returns the updated record + changed files (and recomputed state when applicable). Mirror in
`WorkoutEngine`/`RustWorkoutEngine.swift` and `AppModel+RecordAmendment.swift`.

**Swift:**
1. Route `HistoryDetailView` (`Features/History/HistoryModels.swift`) through the live cards instead
   of the read-only `List`. Reuse `ActiveWorkoutView`/`LiveExerciseCard` via a **mode** that
   suppresses rest/cursor/Live-Activity and swaps the bottom bar for **"Save changes"** (enabled
   only when edits were made). `LiveWorkout.init(repo:session:restoring: record)` already rebuilds a
   workout from a `TrainingRecord`, so this is mostly a mode flag + a save action.
2. "Save changes" calls the new engine edit op; show the recompute outcome (if a lane recomputed,
   say so).
3. Retire the old read-only history list + the add-only amendment sheets once the editable path is
   in (keep them until then).

**Verify:** edit the latest `a1` → next workout/current numbers update; edit an older superseded
`a1` → history changes, progression untouched. Engine tests for both cases.

---

## F. Program bank — multiple programs, one active, shared history (engine + Swift)

**Decided model:** multiple programs **inside one repo**, one active, **shared `logs/`** (one
continuous training history). Approach "A1": resolve the active program **inside the engine**, keep
the `dir`-in / JSON-out FFI so the hot path (build/submit/reduce) is unchanged.

**New repo layout:**
```
repo/
  fitspec.toml            # [active] program = "<slug>" + [[programs]] list
  programs/<slug>/{plan.fitspec, fitspec.lock, state/current.json}
  logs/<yyyy>/<mm>.json   # SHARED across programs
  build/                  # regenerated for the active program
```

**Engine:**
1. New `engine/src/programs.rs`: `RepoConfig`/`ProgramMeta`; parse/render `fitspec.toml`
   `[active]` + `[[programs]]`; `active_program_dir(root)`, `list_programs`, `add_program`,
   `set_active_program`, `delete_program`, `rename_program`. **Back-compat shim:** a repo with a
   root `plan.fitspec` and no `programs/` is treated as one implicit program (migrate-on-write).
2. `repo.rs`: thread active-program resolution through `read_training_repo`/`read_state`/
   `write_state`/`build_repo`/submit/reduce/validate — canonical files resolve to
   `active_program_dir(root)`, **logs resolve to `root/logs`**. Rewrite `init_training_repo` to
   seed `programs/<slug>/`.
3. `add_program` reuses `starter_plan`/`render_plan` (`plan_edit.rs:374`/`:570`) but writes into
   `programs/<slug>/` and appends `[[programs]]` **without** clobbering state (unlike today's
   `switch_program` at `plan_edit.rs:303` which wipes state).
4. `set_active_program` flips the pointer and regenerates `build/*` from that program's preserved
   `state/current.json` — **no numbers re-entered, no state lost.**
5. Tests: add/switch preserves each program's state; logs shared; back-compat repo still builds.

**FFI:** `knurled_list_programs`, `knurled_add_program`, `knurled_set_active_program`,
`knurled_delete_program` in `ios/Engine/knurled-ios-ffi/src/lib.rs` + `include/knurled_core.h`.
Rebuild the xcframework.

**Swift:**
1. `Models/Program.swift` (new): `ProgramSummary` (slug, displayName, template, isActive, validity, nextSession).
2. `ActiveRepo.swift`/`AppModel.swift`: load `programs`, add `setActiveProgram`, `addProgram`,
   `deleteProgram` (call engine → `refresh()` → push). Active program now lives in `fitspec.toml`
   (synced), not UserDefaults.
3. `Features/Programs/ProgramBankView.swift` (new): list active + bank, set-active, delete, "Create program".
4. Migrate the bundled sample/fixtures (`ios/Knurled/Resources/Fixtures/`) to the `programs/` layout
   or rely on the back-compat shim + migrate-on-first-write.
5. Update `docs/repo-contract.md`; add an ADR for "multiple programs, one active, shared logs".

**Verify:** create a 2nd program; switch active back and forth, each keeps its own progression;
shared history intact; single clean git diff + push.

---

## G. ADR-0003 progression DSL (engine — the big one)

**Status today (confirmed in code):** the **configuration** DSL exists (`parser.rs` → `Plan`), but
**progression logic is hardcoded**: `TemplateKind` (`model.rs:20`) is exactly
`{ Gzclp, FiveThreeOne, StartingStrength }`, and `compile_plan` switches on it to `render_*_next`.
The `Plan` struct has **no** scheme/sequence/trigger/effect fields. ADR 0003
(`docs/adr/0003-template-authoring-model.md`) is **Proposed/unbuilt**. The user has chosen to build
it (Tier 2), enabling user-authored cycles / AMRAP / failure / deloads.

**Build sequence (per ADR 0003's five axes):**
1. **Grammar** (KDL dialect, consistent with `.fitspec`): set-groups (`count × reps @ intensity`
   with flags `amrap` / `rep_range(min,max)` / `rpe(target)` + a warm-up ramp facet), *sequence*
   (`stages` / `cycle`/`waves` / `rotation` / `none`), *triggers*
   (`pass` / `fail` / `amrap >= N` / `stall(n)` / `cycle_end` / `range_top`), *effects*
   (`increase_load` / `deload`/`reset_load` / `advance_stage`/`reset_stage` / `increase_reps` /
   `recompute_tm` / `advance_cycle`). *Basis:* `working_weight` / `training_max` / `bodyweight`.
2. **Compiler** — new `engine/src/dsl.rs`: a deterministic evaluator producing the same
   `RenderedSession` + state transitions as the hardcoded templates.
3. **Acceptance gate:** re-express GZCLP, 5/3/1, and Starting Strength as DSL documents and assert
   **byte-identical** engine output vs the current Rust templates (golden tests). Only once they
   round-trip do you **retire** `gzclp_template`/`five_three_one_template`/`starting_strength_template`
   and the `TemplateKind` switches in `core.rs`.
4. **Escape hatch:** `template vendor` (copy a built-in's DSL into `programs/<slug>/templates/`) and
   `template "./templates/x.fitspec"` resolution. Keep the lockfile content-hash + engine-version
   pinning (`Lockfile`/`LockEntry` in `model.rs`).
5. **Wizard (Swift):** `Features/Programs/ProgramWizardView.swift` (new) — template select (built-ins
   via `knurled_builtin_templates`) **+ a "no template" path** + the DSL-authored steps (set scheme,
   periodization/cycle, AMRAP/failure/normal, deload sections) → name/units → suggested days →
   initial numbers from history (Workstream C) → equipment (reuse `EquipmentEditor` from
   `PlanEditViews.swift`) → rest (Workstream D) → review. Authors a DSL doc into
   `programs/<slug>/templates/custom.fitspec`.
6. **Editor + suggester (Swift):** `Features/Programs/ProgramEditorView.swift` (new) replacing
   `QuickPlanEditView`/`PatchPlanEditView`/`SwitchProgramView`; authors `plan.fitspec` via the
   `PlanEdit.quick` path; **stop authoring patches from the app** (keep engine patch *parsing* for
   back-compat); exercise swap becomes an inline edit. Suggester:
   - history initial numbers (Workstream C, exists),
   - new `engine/src/suggest.rs` `suggest_program_adjustments(dir)` over `read_records` + lane state
     (stall → deload, outpace → re-author) applied via an `AdjustNumbers` edit,
   - catalog-based accessory/swap suggestions over `default_exercise_alternatives` (`templates.rs:823`).

**Out of scope (ADR-stated non-goals):** RPE/RIR-as-load beyond ADR 0004, velocity-based training,
algorithmic fatigue management, macro/block periodization.

**Verify:** the parity golden tests (G3) are the gate. Then author a novel program (custom wave +
AMRAP top set + deload week) through the wizard and run a simulated cycle via `simulate_repo`/
`backtest_records_repo`.

---

## Suggested commit boundaries
1. A (Live Activity rebuild) — Swift only, no rebuild.
2. B + C + D (bodyweight, history seed, rest + warmup rounding) — one engine rebuild.
3. E (editable history + ADR 0008) — engine rebuild.
4. F (program bank + ADR) — engine rebuild.
5. G (DSL + wizard/editor, multiple commits; parity gate before retiring Rust templates).

## Things to double-check in code before relying on this doc
- Exact line numbers above are approximate — grep for the named functions/types.
- Confirm `RenderedItem`/`PrescribedSet` already serialize `load: null` (needed for B).
- Confirm the `Implement` enum's current variants and where `implement` is resolved per item in `core.rs`.
- Confirm whether an `knurled_render_session` / builtin-templates FFI already exists before adding new ones.
- For A, confirm `RenderedSession` is fully `Codable` round-trip (it's decoded from engine JSON, so it should be).

## Definition of done for the batch
- `cd engine && cargo test` green; new golden/parity tests added.
- `./scripts/build-xcframework.sh` run; app builds for the iOS simulator; app test suite green.
- Live Activity terminated-logging verified **on a physical device**.
- No regressions to the Phase 0–3 behavior (drafts, Continue/discard, load gate, warmups, jump strip, Live Activity surface).
