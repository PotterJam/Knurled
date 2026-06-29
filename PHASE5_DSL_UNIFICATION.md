# Phase 5 — Collapse to one progression engine (DSL-only)

Goal: delete the legacy Rust template renderers and run **everything** through the DSL evaluator.
Built-ins (GZCLP / 5-3-1 / Starting Strength) are re-authored as shipped DSL documents.

Decisions (locked with the user):
- Re-author all three built-ins as **shipped DSL templates**; keep them selectable in the wizard.
- **No legacy parity** required — validate the new built-ins with fresh behavioral tests.
- **Existing repo data may reset** — no backward-compat / migration constraints.

## Current reality (verified in code — start here)
- `TemplateKind` (`engine/src/model.rs:20`) = `Gzclp | FiveThreeOne | StartingStrength | Custom`.
  `render_next` / `create_initial_state` / warmup defaults dispatch on it (`core.rs:331-345`, `:1095`).
- Built-in progression actually lives in the **legacy renderers'** `effect_preview` (per-item pass/fail
  effects computed inside `render_gzclp_next`/`render_531_next`/`render_starting_strength_next`,
  `core.rs:1498`/`1657`/`1748`). `builtin_template()` returns `dsl: None` — built-ins are NOT DSL today.
- `vendor_template` (`dsl.rs:279`) is a **stub bridge** (`template { builtin "..." }`) that
  `parse_template_dsl` short-circuits back to `builtin_template` (`dsl.rs:24-30`). Not a real expansion.
- The DSL evaluator (`render_custom_next` `core.rs:1214`, `dsl_trigger_matches` `core.rs:2405`) is
  **partial**:
  - `DslTrigger::Stall {..} => false` (inert — no stall counting).
  - `DslTrigger::RangeTop => false` (inert — no double progression).
  - No stage-conditional effects (GZCLP needs "last stage fail ≠ other stage fail").
  - Lanes carry no **tier** label; evaluator emits `tier: "dsl"` (`core.rs:1317`) and
    `display_name` from the template name (`core.rs:1369`). The iOS app derives tier badges from
    `progression_lane` (`WorkoutFormat.tier(fromLane:)`), so DSL lanes must produce lane keys like
    `squat.t1` for badges to keep working.
- Effect ops live in `apply_effects` (`core.rs:2441+`): `increase_load`, `set_load`,
  `advance_stage`, `advance_531_week`, `recompute_tm`, `advance_cycle`, etc.

## Built-in mechanics to encode (read the legacy renderers to confirm exact numbers)
Source of truth: `engine/src/templates.rs` (`builtin_template`, `TemplateLaneRules`, `weeks`,
`increments`) + the three legacy renderers in `core.rs`.
- **Starting Strength** (simplest — do first): linear `3×5` (deadlift `1×5`), per-lift increments
  (upper +2.5, lower +5 — see `TemplateIncrements`), `stall(3) → deload` (e.g. −10%). Needs the
  **stall counter**.
- **GZCLP**: T1 stages `5×3+, 6×2+, 10×1+` (AMRAP last set); `fail → advance_stage`; **last-stage
  fail → reset_load to a fresh T1 weight** (needs stage-conditional or cycle_end-on-last-stage);
  `pass → +load`. T2 analogous (`3×10,3×8,3×6`). T3 accessory `3×15+` double-progression
  (`range_top → +load`). Needs **stage-conditional effects** + **range_top**. Tiers t1/t2/t3.
- **5/3/1 (beginners)**: `training_max` basis; weekly wave (wk1 5s, wk2 3s, wk3 1s + AMRAP), wk4
  deload; `cycle_end → recompute_tm` (+2.5 upper / +5 lower; the beginners variant bumps per cycle).
  Needs **waves/cycle sequence + recompute_tm + week/deload modelling** through the evaluator.

## Work plan

### 1. Extend the DSL evaluator (prerequisite — the hard part)
In `engine/src/model.rs` + `dsl.rs` + `core.rs`:
- **Stall counting:** add `stall: Option<u32>` (or per-lane counter) to `LaneState`
  (`StateProjection`). In the reduce/apply path increment on `fail`, reset on `pass`; make
  `dsl_trigger_matches(Stall{count})` fire when the counter reaches `count` (and zero it on deload).
- **Double progression:** implement `RangeTop` — when a `rep_range(min,max)` group's top is hit,
  fire `range_top` effects (`increase_load` + reset reps); otherwise `increase_reps`. Requires
  carrying rep_min/rep_max into the rendered set and reading achieved reps.
- **Stage-conditional effects:** allow rules scoped to a stage (e.g. `on fail stage="10x1+" {...}`)
  or a `last_stage` trigger, so GZCLP's last-stage reset differs from mid-stage advance. Extend
  `DslRule`/`parse_rule` + `dsl_trigger_matches` (needs the current stage in scope).
- **Tier label:** add `tier: Option<String>` to `DslLane` (+ parse `tier="t1"`); use it for the
  rendered item's `progression_lane` (`<exercise>.<tier>`) and tier badge, replacing `"dsl"`.
- **5/3/1 waves:** confirm `DslSequence::Waves/Cycle` + `recompute_tm`/`advance_cycle` advance week
  and recompute TM correctly through `render_custom_next`/`apply_effects`; add a deload week.
  Generalise/retire the `advance_531_week` op into the generic week/cycle advance.
- Unit tests for each new primitive in `engine/tests/dsl.rs`.

### 2. Author the three built-ins as DSL documents
Ship as embedded `.fitspec` DSL (e.g. `engine/src/templates/{gzclp,531-beginners,ss-phase3}.fitspec`
included via `include_str!`, or build the `DslTemplate` directly). `builtin_template(ref)` returns a
`BuiltinTemplate { kind: Custom, dsl: Some(parse_template_dsl(doc)), .. }`. Drop the `builtin` stub
path in `parse_template_dsl`.

### 3. Delete the legacy engine
- Remove `render_gzclp_next`, `render_531_next`, `render_starting_strength_next` and their `_item`
  helpers; `create_initial_gzclp_state`/`531`/`starting_strength`; the legacy `effect_preview`
  computation and `initial_t3_load_effect` once the evaluator covers it.
- Collapse `TemplateKind` to a single DSL path (remove `Gzclp/FiveThreeOne/StartingStrength`
  variants, or remove the enum). Remove now-unused `BuiltinTemplate` legacy fields
  (`sessions/lanes/increments/weeks` → fold into the DSL model) and `TemplateLaneRules`,
  `FiveThreeOneWeek`, `TemplateIncrements` if dead.
- `render_next`/`create_initial_state`/warmup-defaults become single-path (no match).

### 4. Update tests (expect churn)
`engine/tests/{warmup_equipment,record_flow,mvp,parser,programs,dsl}.rs` assert built-in outputs;
update them to the re-authored DSL behavior. Add per-built-in behavioral tests: initial load/TM,
`pass → +increment`, `stall(3) → deload`, GZCLP stage advance + last-stage reset, 5/3/1 AMRAP →
TM bump + deload week. Replace the now-meaningless `vendored_builtins_are_byte_identical...` test.
Update the bundled example repos (`examples/*`) + iOS fixtures (`ios/Knurled/Resources/Fixtures/`).

### 5. iOS
- `./scripts/build-xcframework.sh`; `xcodegen generate`; build + test the app.
- Verify the app still shows tier badges (lane keys `*.t1/.t2/.t3`), correct display names, warmups,
  and that the wizard's template picker lists the three DSL built-ins and can author a custom one.

## Verification (definition of done)
- `cd engine && cargo test` green with the new behavioral tests; no `render_*_next`/`TemplateKind`
  built-in variants remain (`grep -n "render_gzclp_next\|TemplateKind::Gzclp" engine/src` is empty).
- App builds + iOS suite green; GZCLP renders with T1/T2/T3 badges and progresses correctly in a
  manual run; 5/3/1 cycles through weeks + deload; SS deloads after 3 stalls.

## Risk / sequencing
Do **Starting Strength first** (only needs the stall counter) end-to-end — extend → author → delete
SS legacy → tests → confirm — as the proven pattern, then GZCLP (stage-conditional + range_top),
then 5/3/1 (waves + TM recompute). Keep each built-in's legacy path until its DSL replacement passes
behavioral tests, so the engine is never broken between steps.
