# Phase 6 — what shipped, what's deferred, and the open decisions

Follow-up to `PHASE6_CUSTOM_PROGRAM_AUTHORING.md`. Phase **6A is complete and green**
(`cargo test` + iOS suite pass, xcframework rebuilt, engine owns all DSL text). This
file records what was intentionally left for **6B** and the product decisions still
to make.

## Shipped (6A + the 6B fork/parse path)
- Engine: `render_template_dsl` (canonical serializer, round-trip verified on all 7
  built-ins), `preview_template` (validate + render first workout, no disk writes).
- FFIs: `knurled_render_template`, `knurled_parse_template` (accepts raw `.fitspec`
  **or** a built-in reference, vendoring it), `knurled_preview_template`.
- Swift: Codable `DslTemplate` mirror, 3 engine wrappers, `@Observable`
  `ProgramAuthoringModel` (debounced live preview), the structured editor
  (`Features/Programs/Authoring/*`), fork-a-built-in, and Save via `addProgram`.
  The wizard's string-built `customDocument` was deleted.
- Tests: engine round-trip/preview (`engine/tests/dsl.rs`), iOS authoring
  (`ios/KnurledTests/ProgramAuthoringTests.swift`).

## Deferred (6B)

### 1. Edit an existing custom program's structure — needs engine work
There is **no save-back path today**: `PlanEdit` (`engine/src/plan_edit.rs`) has no
template-rewrite operation, and `add_program` only ever creates a new program.

To implement:
- New engine capability / FFI to rewrite `programs/<slug>/templates/custom.fitspec`
  from re-rendered text, bump the `fitspec.lock` content hash, and regenerate state.
- Read the active program's current template into the editor. The reference path is
  `./templates/custom.fitspec`; `knurled_parse_template` already accepts raw text, so
  the app needs to read that file (FileManager, or a small read FFI).
- An "Edit program structure" entry in `ProgramEditorView` that loads it into
  `ProgramAuthoringView`.

**Decision made:** on a structural edit of an in-progress program, **reset progress** —
re-render initial state from the new structure and have the user re-enter starting
numbers if lanes changed. (Simplest and safe; rejected "preserve compatible state" and
"block mid-program".)

### 2. Multi-session `simulate` projection in the preview pane — clean/additive
`simulate` already exists in the engine but `preview_template` only returns the first
workout. Extend `preview_template` to optionally run N future sessions and surface them
so the editor can show "the next few workouts." No state-migration risk; fully testable.

### 3. Accessory / exercise-swap suggestions in the editor — additive UX
Surface catalog-based accessory and swap suggestions inside the lane editor
(`app.exerciseCatalog` is already loaded).

### 4. Rule-presets library — partially done
Four presets are inline in `LaneEditorView` ("linear + stall deload", "GZCLP stage
ladder", "double progression", "5/3/1 wave"). Could be extracted into a shared,
expandable library if more are wanted.

## Open questions for the product owner (still unanswered)
- **How much DSL surface to expose in the editor** — full power vs. guided-behind-presets.
  (Current editor leans full-power: every basis/sequence/trigger/effect is reachable.)
- **Should custom programs be shareable / exportable?** The `.fitspec` is git-tracked
  already; nothing in-app exports it.
- **Do you want a raw-`.fitspec` "advanced" escape hatch in-app**, or keep raw editing to
  the repo/CLI/workbench?

## Implementation deviations (already made, for the record)
- **Round-trip is semantic, not byte-stable.** `parse ∘ render` is a verified fixed
  point, but rendered output is canonical and does not reproduce hand-authored
  formatting (blank-line grouping, rotation-vs-sorted-map order). The built-in
  `.fitspec` files are untouched, so their content hashes / lockfiles are unaffected.
- **3-FFI budget kept.** Rather than add a vendoring FFI, `knurled_parse_template`
  distinguishes a built-in reference from literal text by the presence of `{`.
