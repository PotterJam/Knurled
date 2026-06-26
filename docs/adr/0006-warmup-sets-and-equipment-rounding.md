# ADR 0006 — Warmup sets and equipment-aware load rounding

- Status: Accepted
- Date: 2026-06-24

## Context

Two long-standing gaps in the rendered prescription:

1. **Warmup sets.** Real programs ramp up to the work weight, and the right amount of ramping is
   not fixed: it varies by lift (an overhead press needs fewer warmups than a squat), by working
   weight (heavier work needs more ramp sets, often a near-max single), and by program phase
   (periodised blocks warm up differently week to week). The spec listed `add warmup` (mvp-spec
   §11) as aspirational and the engine modelled none of it. The reference scheme we calibrated
   against is the Bay Strength method: two empty-bar sets then `45% ×5 / 65% ×3 / 85% ×2` of the
   work weight for novices, ramping further (and adding a heavy single) as the bar gets heavier.

2. **Equipment-aware rounding.** Loads were rounded with a single hardcoded `round_to_increment(_,
   2.5)` in three places. A lifter whose gym only has, say, 20/10/5 kg plates, or who trains a lift
   with fixed dumbbells, gets prescribed numbers they cannot actually load.

Both must respect the determinism guarantee (mvp-spec §6, §9): everything feeds `plan_hash`,
`template_hash`, and `rendered_session_hash`, and replay must stay reproducible.

## Decision

### Warmups are scoped, template-defaulted configuration

A plan-level `warmup { … }` block configures warmup schemes scoped exactly like `rest`
(`default` / `tier` / `slot` / `lane` / `exercise`, resolved most-specific-first). A scheme is a
count of empty-bar sets plus a percentage `ramp` of a `basis` load (`top_set`, `working_weight`,
or `training_max`), with per-step reps. Because the count of sets and their reps are configurable
per scope, different lifts/tiers/phases naturally carry different warmup volume — the requirement,
expressed as data rather than code.

Built-in programs ship sensible defaults (GZCLP / Starting Strength → the Bay Strength novice
ramp; 5/3/1 → canonical 40/50/60% of the training max). A plan's own `warmup` overrides the
template default per scope.

Warmups are rendered into a **separate `prescription.warmups` field**, not mixed into the working
`sets`. This was deliberate: it leaves working-set indexing, AMRAP-final-set detection, outcome
evaluation, and the execution contract completely untouched. Warmups are guidance only — never
required for completion, never an input to progression. A lift's pass/fail is unchanged by them.

### Equipment rounding is a cross-cutting layer, not a template concern

An optional plan-level `equipment { … }` block lists the gym's bars, plate denominations, and
dumbbells. When present, the engine snaps every **computed** load — working sets, 5/3/1
percentages, progression increments, and warmups — to the nearest achievable weight (barbell =
`bar + 2 × multiset of plate pairs`; dumbbell = nearest listed size), with a `nearest` (default,
ties resolve down) or `down` rounding mode. The reachable-sum search runs on an integer centi-unit
grid so floating-point error never hides an achievable load.

Equipment is **plan-level only and never part of a template**: a template describes the program,
not the user's plates. It is applied as a post-computation rounding layer over whatever a template
produces, which keeps the (future) authoring vocabulary free of gym-inventory concerns.

The exercise catalogue introduced later is deliberately advisory here. Catalogue/custom-exercise
metadata may say an exercise is `barbell`, `dumbbell`, `machine`, etc. so clients can present and
create exercises cleanly, but equipment rounding still resolves from the `equipment { … }` block
and the engine's implement inference/overrides. In other words, a repo-owned custom exercise can
be displayable without forcing rounding semantics, and a lifter can still override implement
handling per exercise in `equipment`.

### Determinism and backward compatibility

- New fields (`Plan.warmup`, `Plan.equipment`, `Prescription.warmups`) are
  `skip_serializing_if`-empty, so a plan without them serialises — and therefore hashes —
  byte-identically to before this change. The full pre-existing test suite and example
  `current.ir.json` / `validation.json` / `state` outputs are unchanged; only the example
  `next-workout.json` files gain a warmups block from the new template defaults.
- Template warmup defaults live in engine code keyed by program kind, **not** in the hashed
  `BuiltinTemplate`. They are pinned by `ENGINE_VERSION` like every other rendering rule, so
  existing template hashes and lockfiles are untouched, and defaults can evolve through an engine
  version bump rather than silently mutating a locked template (mvp-spec §9).
- With no `equipment` block, rounding is the historical fixed 2.5-unit behaviour; progression
  increments are still applied without re-rounding, so off-grid starting loads behave as before.
- Warmup loads and snapped working loads are pure functions of (scheme, basis, equipment), so
  replay and simulation remain deterministic.

## Consequences

- Programs render usable warmups out of the box, and lifters can fully reconfigure them per
  lift/tier/phase without touching the engine.
- Prescribed numbers match what a lifter can actually load once they declare their equipment.
- The split between warmups (guidance) and working sets (progression) keeps the reducer and
  current workout submission semantics intact.
- Players (iOS/CLI/workbench) consume the additive JSON without engine-logic changes; warmups are
  shown as non-logged guidance.
- Follow-on work, not done here: a patch-level `add-warmup` op (date-bounded warmup changes), and
  modelling limited plate **counts** (the current search assumes unlimited plates per
  denomination).
- The built-in/custom exercise catalogue can improve defaults and picker UX, but it does not
  replace explicit equipment configuration for precise load rounding.
- See [ADR 0003](0003-template-authoring-model.md) for how warmups slot into the template-authoring
  vocabulary if/when that lands, and why equipment rounding stays orthogonal to it.
