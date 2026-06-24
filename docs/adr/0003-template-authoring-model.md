# ADR 0003 — Declarative template-authoring model (progression primitives)

- Status: Proposed
- Date: 2026-06-24

## Context

Templates — the actual progression logic ("GZCLP advances a stage on a failed AMRAP", "5/3/1
recomputes the training max each cycle") — are currently hand-written Rust in
[engine/src/templates.rs](../../engine/src/templates.rs) and
[engine/src/core.rs](../../engine/src/core.rs). The `.fitspec` language only *configures* those
built-ins; users cannot author their own progression. The `fitspec template vendor` escape hatch
(mvp-spec §9) and the `on fail { advance_stage }` snippet (§10) are specced but unimplemented.

We want users to author their own templates. Spec §10 constrains the means: the language must
stay small, declarative, safe, deterministic — **no general-purpose code, conditionals, loops, or
variables**. So "make your own template" must be expressible as a bounded, declarative vocabulary,
not a scripting language.

The goal is to cover ~99% of real strength programs with composable primitives, accepting that a
small slice (real-time autoregulation, bespoke elite individualisation) is deliberately out of
scope.

## Decision

Adopt option **B** from the language discussion: a **small declarative progression DSL**, built
from orthogonal axes that compose so named programs are *compositions*, not special cases.

### The five axes

1. **Basis** — what load is computed from: `working_weight`, `training_max`, `bodyweight`
   (`e1rm` reserved for later).
2. **Scheme** — a session's prescription as set-groups, each `count × reps @ intensity`, where
   `intensity` is `%basis` | absolute | `@ ref` (a backoff group referencing another group's
   load). Per-group flags: `amrap`, `rep_range(min,max)`, `rpe(target)`.
3. **Sequence** — how schemes/loads move over time: `stages` (ordered, advance on a trigger),
   `cycle`/`waves` (repeating week pattern), `rotation` (per-session, for DUP), or `none`.
4. **Triggers** — post-session conditions: `pass`, `fail`, `amrap >= N` (bands), `stall(n)`,
   `cycle_end`, `range_top`.
5. **Effects** — `increase_load by X|X%`, `deload`/`reset_load to %`, `advance_stage`/
   `reset_stage`, `increase_reps`, `recompute_tm`, `advance_cycle`.

Named mechanisms are scheme features, not primitives: **AMRAP** = a flagged set; **FSL/SSL** =
a backoff group `@ set(1)`/`@ set(2)`; **BBB** = `5×10 @ 0.5·tm`; **double progression** =
`rep_range` + `range_top → increase_load`.

### Coverage

| Program | basis | sequence | trigger → effect |
|---|---|---|---|
| Starting Strength / StrongLifts | working_weight | none, `3×5` | `pass → +2.5kg`; `stall(3) → deload 10%` |
| GZCLP | working_weight | stages `5×3+,6×2+,10×1+` | `fail → advance_stage`; last-stage `fail → reset_load +`; `pass → +load` |
| 5/3/1 | training_max | cycle `wk1/2/3 +deload` | `amrap≥thr → recompute_tm +X`; `cycle_end → advance_cycle` |
| DUP / undulating | working_weight / tm | rotation by session | per-session scheme; `pass → +load` |
| Accessories (double progression) | working_weight | none, `rep_range(8,12)` | `range_top → +load,reset_reps`; else `increase_reps` |
| 5/3/1 BBB / FSL | training_max | cycle | top set + backoff `@ %tm` or `@ set(1)` |

### Out of scope (the deliberate ~1%)

The deterministic-engine guarantee (§6) means anything not computable from *prescription +
logged input* cannot live here:

- **RPE/RIR as load selection** — ~~needs lifter judgment, out of scope~~. **Superseded by
  [ADR 0004](0004-rpe-autoregulation.md)**, which brings RPE/e1RM in as Tier 1: load is a logged
  input (replay stays deterministic) and forward simulation uses a linear e1RM model.
- **Velocity-based training** — needs a velocity input stream (possible future `e1rm`/velocity
  basis, separate work).
- **Algorithmic fatigue management** (RTS fatigue percents, Sheiko individualisation) — genuine
  program-as-code, excluded by §10.
- **Macro/block periodisation** — this is *sequencing of blocks*, handled by
  [ADR 0002](0002-plan-lifecycle-events.md) (`plan_changed` / phases) plus multi-phase templates,
  not a single template's concern. (Starting Strength phases are already separate templates.)

### Validation / acceptance test

**Re-express the three existing built-ins (GZCLP, 5/3/1, Starting Strength) as DSL documents and
require byte-identical engine output** to the current Rust templates. If they round-trip, the
vocabulary is proven. The built-ins thus become the first documents written in the language
(dogfooding), and the Rust template functions are retired in favour of the DSL compiler.

## Consequences

- Users author real templates within a safe, diffable, deterministic, LLM-editable vocabulary —
  no "JavaScript in workouts" (§10 honoured).
- Implied work (not done here), in order:
  1. Define the DSL grammar (KDL dialect, consistent with `plan.fitspec`).
  2. Build the template compiler in the engine; express the built-ins in it and assert
     output parity (acceptance test).
  3. Implement the `template vendor` escape hatch (copy a built-in's DSL into `templates/` to
     edit) and `template "./templates/x.fitspec"` resolution.
  4. Keep the lockfile content-hash + engine-version pinning for determinism (mvp-spec §9).
- Common mechanisms (`amrap`, `fsl`, `ssl`, `bbb`) can ship as terse sugar over the primitives.
- The ~1% boundary is a stated non-goal; autoregulation/VBT would be a separate ADR if revisited.
