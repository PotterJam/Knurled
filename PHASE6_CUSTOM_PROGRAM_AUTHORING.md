# Phase 6 — In-app authoring of rich custom programs

Goal: let users build (and edit) full multi-exercise, multi-session DSL programs **in the app** —
cycles, stages, AMRAP/failure sets, double-progression, deloads, per-lift increments, tiers — not
just the single-lane "No template" stub the wizard emits today. The engine already supports all of
this (Phase 5 made the built-ins themselves DSL documents); this phase is about the authoring UI and
the small engine plumbing it needs.

## Decisions / principles
- **The engine owns DSL parse + serialization + validation** (per `AGENTS.md`). The app edits a
  *structured* model and calls engine APIs to render/validate it. **Do not generate `.fitspec` text
  in Swift** (the current wizard string-builds a doc — that approach does not scale and must be
  replaced).
- **Edit a structured `DslTemplate`**, not raw text. Forms over a Codable mirror of the engine's
  DSL model, with **live validation + a rendered preview** of the next workout.
- **Fork-a-built-in is the primary path**: "Start from GZCLP / 5-3-1 / SS and customise" — far more
  useful than a blank canvas, and it dogfoods the same documents the engine ships.

## What exists today (verified)
- **Engine DSL model** (`engine/src/model.rs`): `DslTemplate { name, version, rotation, rest_seconds,
  sessions: Map<Vec<DslSessionItem>>, lanes: Map<DslLane> }`; `DslLane { exercise, basis, sequence,
  stages, rules, warmup, tier }`; `DslStage { id, groups }`; `DslSetGroup { count, reps, intensity,
  amrap, rep_min, rep_max, rpe }`; `DslRule { trigger, effects }`; `DslTrigger` (`Pass|Fail|
  AmrapGte|Stall|CycleEnd|RangeTop`, plus the stage-conditional `stage="…"` scoping added in Phase 5);
  `DslEffect` (`IncreaseLoad|Deload|ResetLoad|AdvanceStage|ResetStage|IncreaseReps|RecomputeTm|
  AdvanceCycle`). Built-ins live as `engine/src/templates/*.fitspec` and are parsed via
  `parse_template_dsl` (`engine/src/dsl.rs`).
- **Parser only, no serializer.** `parse_template_dsl(text) -> BuiltinTemplate{ dsl: Some(..) }`
  exists; there is **no** `render_template_dsl(DslTemplate) -> text`. `vendor_template(reference)`
  returns the built-in's `.fitspec` text (usable to seed a fork).
- **Persistence already works.** `AddProgramRequest { …, customTemplate: String }` →
  `knurled_add_program` writes `programs/<slug>/templates/<slug>.fitspec` + a `plan.fitspec`
  referencing it. `AppModel.addProgram` (`ios/.../App/AppModel.swift:71`) is the entry point.
  Program-level edits go through `knurled_preview_plan_edit` / `knurled_apply_plan_edit`
  (`AppModel+PlanEdit.swift`).
- **Wizard** (`ios/.../Features/Programs/ProgramWizardView.swift`) authors a single-lane doc via
  `customDocument` (string interpolation). That custom path is what this phase replaces/expands.
- **No FFIs** for: parse-to-structured, render-from-structured, or validate/preview a candidate
  template before commit.
- **Reusable iOS pieces:** `app.exerciseCatalog` (id/label/pattern/muscles/implement),
  `EquipmentEditor` + `WeekdayPicker` + `InitialTrainingNumbers` (`PlanEditViews.swift`/wizard),
  `compile_plan_with_template` + `validate_compiled` + `render_next` (engine, for preview).

## Engine work (small, enables everything)
Add three FFIs (JSON in/out, mirror in `WorkoutEngine`/`RustWorkoutEngine.swift` +
`include/knurled_core.h`):

1. **`knurled_render_template(dsl_json) -> { text }`** — the inverse of `parse_template_dsl`.
   Implement `render_template_dsl(&DslTemplate) -> String` in `engine/src/dsl.rs` emitting canonical
   `.fitspec`. **Round-trip invariant:** `parse_template_dsl(render_template_dsl(d)).dsl == Some(d)`
   for every built-in and arbitrary valid `d` (property/golden test).
2. **`knurled_parse_template(text) -> { dsl: DslTemplate }`** — expose the parser's `DslTemplate`
   as JSON, so the app can load an existing program (or a forked built-in) into the editor.
3. **`knurled_preview_template(request_json) -> { validation, preview }`** — given a `DslTemplate`
   (or text) + units + initial numbers + rotation/rest, compile via `compile_plan_with_template`,
   return the `ValidationReport` and a `RenderedSession` (first workout) so the editor shows errors
   and a live preview without writing anything. Optionally return a few `simulate`d future sessions.

(Definitions to expose through `pub use model::*` already cover the Dsl* types; just ensure they
serialize cleanly as the FFI contract.)

## Swift work
1. **Codable `DslTemplate` mirror** — new `ios/.../Models/DslTemplate.swift` mirroring the engine
   structs exactly (snake_case coding keys to match the JSON), incl. `DslLane/Stage/SetGroup/Rule/
   Trigger/Effect`, `tier`, `basis`, `sequence`, `warmup`. This is the single editable model.
2. **Authoring view-model** — `@Observable ProgramAuthoringModel` holding the editable `DslTemplate`
   + initial numbers + units + schedule; debounced calls to `knurled_preview_template` to refresh a
   `validation` + `preview` on every edit. Disable Save while invalid.
3. **The editor UI** — new `ios/.../Features/Programs/Authoring/` screens:
   - **Program** — name, units, rotation (ordered session list), default rest, suggested days
     (reuse `WeekdayPicker`).
   - **Sessions** — add/reorder sessions; each lists items, each item pointing at a lane (+ slot id
     auto-derived).
   - **Lanes** — exercise (picker over `app.exerciseCatalog`), tier (t1/t2/t3/none), basis
     (working_weight / training_max / bodyweight), sequence (none/stages/cycle/waves/rotation),
     per-lane rest, `initial` (e.g. 80% / performed / explicit), warmup ramp editor.
   - **Stages** — ordered stages, each a list of set-groups (count × reps @ intensity, AMRAP toggle,
     optional rep-range for double progression, optional RPE).
   - **Rules** — trigger (pass/fail/amrap≥N/stall(n)/cycle_end/range_top, with optional stage scope)
     → effects (increase_load by X|X%, deload %, reset_load %, advance/reset stage, increase_reps,
     recompute_tm, advance_cycle). Offer a few **rule presets** ("linear + stall deload", "GZCLP
     stage ladder", "double progression", "5/3/1 wave").
   - **Preview pane** — the rendered first workout + inline validation errors, live.
4. **Fork-a-built-in** — in the wizard's template step, a "Customise" action calls
   `knurled_parse_template(vendor_template(ref))` → load the `DslTemplate` into the editor.
5. **Save / edit** — Save renders via `knurled_render_template` → `AddProgramRequest.customTemplate`
   → `addProgram` (create) or a `plan.savePatch`/template-rewrite via `applyPlanEdit` (edit existing).
   Replace the wizard's string-built `customDocument` with the rendered output of the model.
6. **Editing an existing custom program** — `ProgramEditorView` gains "Edit program structure" that
   parses the active program's template (`knurled_parse_template`) into the editor.

## UX flow
Wizard → choose **built-in** (configure numbers, done) **or** **custom / customise a built-in** →
the structured editor (with live preview) → Save → program added to the bank. Editing a custom
program later reopens the same editor.

## Guardrails
- Editor only emits valid combinations (e.g. `training_max` basis surfaces TM inputs; `amrap` only
  on a final set; rep-range implies a `range_top` rule). Surface engine validation inline; block Save
  on errors. Provide presets and sensible defaults so a user never faces a blank lane.

## Phasing
- **6A (MVP):** structured multi-lane/multi-session editor over `DslTemplate` + `render_template`
  FFI + live `preview_template` + Save via `addProgram` + fork-a-built-in. Delete the wizard's
  string-built custom doc.
- **6B:** edit existing custom programs (`parse_template` FFI), multi-session projection via
  `simulate`, accessory/swap suggestions over the catalog, rule presets library.

## Files
- Engine: `engine/src/dsl.rs` (+`render_template_dsl`), `engine/src/lib.rs`,
  `ios/Engine/knurled-ios-ffi/src/lib.rs` (+ `include/knurled_core.h`) — 3 new FFIs; tests in
  `engine/tests/dsl.rs` (round-trip + preview).
- Swift: new `Models/DslTemplate.swift`; new `Features/Programs/Authoring/*` (editor screens +
  `ProgramAuthoringModel`); `Engine/RustWorkoutEngine.swift` + `WorkoutEngine.swift` (3 wrappers);
  `Features/Programs/ProgramWizardView.swift` + `ProgramEditorView.swift` (wire fork/edit, drop the
  string builder); reuse `PlanEditViews.swift` editors + `app.exerciseCatalog`.

## Testing
- Engine: `render∘parse` and `parse∘render` round-trip on all 7 built-ins (byte-stable canonical
  form) + arbitrary valid templates; `preview_template` returns valid + a sane first workout;
  invalid templates surface specific errors.
- iOS: `DslTemplate` JSON decode/encode against engine output; a snapshot test that the editor model
  for a forked GZCLP renders back to an equivalent template; authoring → addProgram → it appears in
  the bank and renders.

## Definition of done
- A user can fork GZCLP (or start fresh), add a second lane/session, change a stage scheme, add an
  AMRAP set and a deload rule, see a live preview with validation, and save it as a working program
  in the bank — entirely in-app, with no raw `.fitspec` editing.
- `cargo test` + iOS suite green; xcframework rebuilt; engine still owns all DSL text generation.

## Open questions for the product owner
- How much DSL surface to expose in 6A vs hide behind presets (full power vs guided)?
- Should custom programs be shareable/exportable (the `.fitspec` is git-tracked already)?
- Do you want a raw-`.fitspec` "advanced" escape hatch in-app, or keep that to the repo/CLI?
