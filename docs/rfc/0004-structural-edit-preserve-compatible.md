# RFC-0004 — Program structural edit with PreserveCompatible

**Status:** Proposed
**Date:** 2026-07-01
**Split from:** [RFC-0001 §3 D11](0001-cockpit-jtbd.md) (deferred there because it reverses a locked decision and its core semantics are unsettled)
**Supersedes:** the "structural edit resets progress" decision in `PHASE6B_REMAINING.md §1`
**Boundary:** the engine owns the lane diff, state preservation, and lock rewrite; iOS renders the preview and collects confirmation. (AGENTS.md)

---

## 1. Problem statement

Phase 6B item #1 is blocked two ways (`PHASE6B_REMAINING.md §1`):

- `PlanEdit` (`engine/src/plan_edit.rs`) has **no template-rewrite operation**; `add_program` only ever *creates* a new program.
- The Phase 6B decision was **"on a structural edit of an in-progress program, reset progress"** — re-render initial state and make the user re-enter numbers if lanes changed. That was chosen as "simplest and safe," explicitly rejecting "preserve compatible state."

Reset-progress is safe but punishing: changing one accessory's rep scheme should not wipe a lifter's squat progress. This RFC reverses that decision and adds the missing operation.

## 2. Why this is its own RFC

It **reverses an already-recorded decision**, and the preservation rule — *which* lanes carry their `LaneState` across a structural edit — is a genuine open question (RFC-0001 §7 Q4) with real correctness stakes (carrying stale state into an incompatible lane silently corrupts progression). That is too much to fold into a UX RFC as one bullet.

## 3. Decisions

### D1 — `ProgramStructuralEdit` operation

New engine operation `ProgramStructuralEdit { slug, new_template_text, behavior: ResetProgress | PreserveCompatible }`. It rewrites `programs/<slug>/templates/custom.fitspec` from re-rendered text, bumps the `fitspec.lock` `content_hash` (the existing `add_program` lock-write path, `engine/src/programs.rs`), and regenerates state per `behavior`.

- `knurled_parse_template` already accepts raw `.fitspec` text, so the editor's re-rendered document feeds straight in.

### D2 — `PreserveCompatible` diff rule

When `PreserveCompatible`, the engine diffs new vs. old lanes:

- A lane keeps its `LaneState` (`load`, `stage`, `training_max`, `week`, `cycle`, `reps`, `stall`) iff it has the **same `basis`** *and* the **same normalized exercise** in both templates.
- New lanes, removed lanes, and lanes whose basis changed **reset**.

`ResetProgress` remains available as an explicit override and is the old Phase 6B behaviour.

**This is the crux open question (see §6).** Same-basis + same-exercise is the *conservative* line: it never carries a `training_max` into a `working_weight` lane, and never carries a squat's state onto a bench lane. Whether it is *too* conservative (e.g. should a stage change on the same lane preserve `load` but reset `stage`?) is what this RFC must settle before implementation.

### D3 — `structural_edit_preview` (no writes)

New FFI `knurled_structural_edit_preview(slug, new_template_text) -> StructuralEditPreview { preserved: Vec<String>, reset: Vec<String>, validation }`. The user sees exactly which lanes keep progress and which reset **before** saving.

## 4. Engine API additions

| API | Input | Output | Module |
|---|---|---|---|
| `ProgramStructuralEdit` | `slug`, `new_template_text`, `behavior` | `ProgramMutationOutcome` | `programs.rs` |
| `knurled_structural_edit_preview` | `slug`, `new_template_text` | `StructuralEditPreview` | `programs.rs` (FFI) |

## 5. iOS UX

- **Path:** Program Bank → Edit (custom program) → structural editor (loads the active template via the existing `render_template_dsl` / read path from Phase 6A).
- **Save flow:** call `structural_edit_preview`; show preserved/reset lanes ("These keep their progress: Squat, Bench… These reset: New backoff, Removed accessory"); user confirms. `PreserveCompatible` is the default; `ResetProgress` is an explicit override toggle.

## 6. Open questions

1. **Is same-basis + same-exercise the right preservation line?** (The reason this RFC exists.) Alternatives: preserve on same-exercise regardless of basis (with a basis-coercion step); preserve `load` but reset cursor fields (`week`/`cycle`/`stage`) when the progression rule changes; block the edit when any in-progress lane would reset.
2. **Normalization of "same exercise":** case-fold only, or map through the exercise catalog's aliases/patterns so `Barbell Bench` == `bench`?
3. **Lock/version semantics:** does a structural edit that preserves all lanes still bump `content_hash` (template text changed) while leaving state untouched? (Assumed yes — hash tracks template, not state.)
4. **Interaction with active patches:** if a preserved lane has a temporary patch (RFC-0001 D10) active, does it survive the structural edit or get dropped?

---

*End of RFC-0004*
