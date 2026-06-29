# FitSpec language reference

FitSpec is a small, declarative [KDL](https://kdl.dev) dialect. Plans configure built-ins or refer
to repository-owned templates. Template documents use the bounded progression primitives from
[ADR 0003](adr/0003-template-authoring-model.md); evaluation remains engine-owned.

This file is the maintained reference. The source of truth is the parser
([engine/src/parser.rs](../engine/src/parser.rs)); anything below marked **Implemented** is what
the parser actually accepts. Items under [Planned](#planned-not-yet-implemented) are specced
(mvp-spec §11) but not yet parsed.

## At a glance

```kdl
plan "My GZCLP" {
  template "gzcl.gzclp" version="1.0.0"
  units kg

  schedule next_workout {
    rotation A1 B1 A2 B2
    suggested_days mon wed fri
  }

  starts {
    squat "80kg"
    bench "55kg"
    press "37.5kg"
    deadlift "100kg"
  }

  accessories {
    A1.T3 lat_pulldown
    B1.T3 barbell_row
  }

  rest {
    default 3m
    tier T1 5m
  }

  exercise_options {
    slot "A1.T3" {
      primary lat_pulldown
      chin_up   { label "Chin-up";  policy tracking_only }
      cable_row { label "Cable Row"; policy tracking_only }
    }
  }
}
```

---

## Plan directives (`plan.fitspec`) — Implemented

A plan is a single `plan "name" { … }` node. Inside it:

| Directive | Required | Form | Notes |
|---|---|---|---|
| `template` | ✅ | `template "id@version"`, `template "id" version="x"`, or `template "./templates/x.fitspec"` | Resolves to a built-in or repo-owned template. |
| `units` | ✅ | `units kg` / `units lb` | Unrecognised values fall back to `kg`. |
| `schedule` | | `schedule [mode] { rotation …; suggested_days … }` | `mode` defaults to `next_workout`. `rotation` and `suggested_days` are lowercased token lists. |
| `starts` | | `starts { squat "80kg" … }` | Per-lift starting working weights. |
| `training_maxes` | | `training_maxes { squat "140kg" … }` | Per-lift training maxes (for %-based templates). |
| `accessories` | | `accessories { A1.T3 lat_pulldown … }` | Maps a `slot.tier` to an accessory exercise. |
| `exercises` | | `exercises { landmine_press { … } }` | Repo-owned custom exercise metadata for app pickers/logging. |
| `rest` | | `rest { … }` | Rest prescription, see below. |
| `warmup` | | `warmup { … }` | Warmup (ramp-up) sets, see below. |
| `equipment` | | `equipment { … }` | Available plates/dumbbells/bars for load rounding, see below. |
| `exercise_options` | | `exercise_options { slot "…" { … } }` | Runtime swap options, see below. |
| `assistance` | | `assistance …` | **Accepted but ignored** — reserved placeholder (mvp-spec §11). |

Any other directive is a parse error.

### `exercises`

Optional repo-owned exercise metadata. This powers search/create UI and display labels; it is not
a restrictive registry. Existing plans, logs, swaps, and patches may still use any exercise string.

```kdl
exercises {
  landmine_press { label "Landmine Press"; pattern vertical_push; implement barbell }
  belt_squat     { label "Belt Squat";     pattern squat;         implement machine }
}
```

IDs are normalized like every other exercise name. `implement bodyweight` is semantic: the engine
omits prescription loads and warmup plate math. Other implement strings remain catalogue metadata.

### `rest`

Resolved by the engine by scope; rest is never computed in the app.

```kdl
rest {
  default 3m              // fallback for everything
  tier T1 5m              // by tier
  slot a1.t1 4m           // by slot
  lane squat.t1 4m        // by progression lane
  exercise deadlift 5m    // by exercise
}
```

Scopes: `default`, `tier`, `slot`, `lane`, `exercise`. Durations accept bare seconds (`180`),
a value + unit (`3 m`, `90 s`), or `mm:ss` (`2:30`).

### `warmup`

Warmup (ramp-up) sets, computed by the engine and attached to each rendered item as a separate
`prescription.warmups` list. They are **guidance only**: never required for completion and never
fed into progression — a missed or modified warmup can't pass or fail a lift.

```kdl
warmup {
  default {
    empty_bar 1 5            // 1 set of 5 with just the bar
    ramp {
      step 65 3              // 65% of the basis load x3
      step 80 2
    }
    basis top_set           // top_set (default) | working_weight | training_max
  }
  tier T1   { empty_bar 1 5; ramp { step 40 5; step 60 3; step 80 2; step 90 1 } }
  lane "press.t1" { ramp { step 50 5; step 70 3; step 85 2 } }   // upper body, fewer
  exercise deadlift { ramp { step 45 5; step 65 3; step 85 3; step 95 1 } }
}
```

Scopes resolve by precedence `slot` > `lane` > `exercise` > `tier` > `default`, mirroring `rest`,
and a plan's `warmup` overrides the template's built-in default. Each scheme is:

| Key | Form | Notes |
|---|---|---|
| `empty_bar` | `empty_bar <sets> <reps>` | Empty-bar sets at the bar weight. Skipped for dumbbell lifts. |
| `ramp` | `ramp { step <pct> <reps> … }` | A step is `step 65 3` (65% × 3). `pct=`/`reps=` properties also accepted. |
| `basis` | `basis top_set` | What the percentages are taken from. |

The number of warmup sets (empty-bar sets plus ramp steps) and their reps are fully configurable,
so different lifts, tiers, and program phases carry different warmup volume. Built-in defaults:
GZCLP and Starting Strength ship a compact novice ramp (1×5 empty bar, then 65/80% of the work
weight, skipping a step when rounding would repeat the previous warmup load); 5/3/1 ships the
canonical 40/50/60% of the training max. Warmup loads are rounded by the same equipment-aware
logic as working loads and, for barbells, use prefixes of the work-set plate stack so a ramp never
requires removing a small plate before the work set.

## Template documents (`templates/*.fitspec`) — Implemented

```kdl
template "Wave + AMRAP" version="1.0.0" {
  rotation day
  rest 150
  warmup basis="top_set" empty_bar_sets=1 empty_bar_reps=5 {
    step intensity=50 reps=5
  }
  session day display="Training Day" { item "squat.main" slot="day.squat" }
  lane "squat.main" exercise="squat" tier="main" basis="working_weight" sequence="cycle" rest=180 {
    warmup intensity=50 reps=5
    stage "wave" {
      set count=1 reps=5 intensity=80
      set count=1 reps=3 intensity=90
      set count=1 reps=1 intensity=100 amrap=#true
    }
    stage "deload" { set count=3 reps=5 intensity=60 }
    on pass { increase_load by=2.5; advance_stage }
    on amrap_gte reps=8 { increase_load by="5%" }
    on cycle_end { reset_stage; advance_cycle }
  }
}
```

- Basis: `working_weight`, `training_max`, `bodyweight`.
- Initial value: `initial="basis"` (default), a percentage such as `initial="80%"`, or
  `initial="performed"` to capture the first logged load.
- Sequence: `none`, `stages`, `cycle`, `waves`, `rotation`.
- Set facets: `count`, `reps`, percentage `intensity`, `amrap`, `rep_min`/`rep_max`, `rpe`.
- Triggers: `pass`, `fail`, `amrap_gte`, `stall`, `cycle_end`, `range_top`.
- Effects: `increase_load`, `deload`, `reset_load`, `advance_stage`, `reset_stage`,
  `increase_reps`, `reset_reps`, `recompute_tm`, `advance_cycle`.
- Rules may be stage-scoped, for example `on fail stage="10x1+" { … }`.
- Sessions accept `display=`, and items may bind a plan accessory with `accessory=` plus
  `default_exercise=`. Lanes accept `tier=` and `rest=`; rendered lane identity is always
  `<resolved exercise>.<tier>`.
- Warmups may use the full template-level scheme shown above. The repeated lane shorthand
  `warmup intensity=<percent> reps=<count>` remains accepted.

There are no variables, loops, functions, or arbitrary conditionals. Every built-in is an embedded
DSL document, and `template vendor` copies that real document into the repository for editing.

### `equipment`

Optional, user-owned description of the gym's equipment. When present, the engine snaps every
**computed** load (working sets, 5/3/1 percentages, progression increments, and warmups) to the
nearest weight the lifter can actually load. With no `equipment` block, loads use the historical
fixed 2.5-unit rounding, so existing plans are unaffected. Starting loads you type in `starts`
are taken as-entered.

```kdl
equipment {
  bar default 20            // bar weight (plan units); per-exercise: `bar press 20`
  plates 25 20 15 10 5 2.5 1.25   // available plate denominations (per side, unlimited count)
  dumbbells 5 7.5 10 12.5 15 17.5 20 22.5 25 30
  rounding nearest          // nearest (default, ties resolve down) | down
  implement dumbbell_bench_press dumbbell   // override; otherwise inferred from the name
}
```

A barbell total is `bar + 2 × (multiset of plate pairs)`; a dumbbell lift snaps to the nearest
listed size. Lifts are treated as barbell unless their name contains `dumbbell`/`db` or an
`implement` override says otherwise. If the relevant inventory is empty, that lift falls back to
2.5-unit rounding.

### `exercise_options`

Per-slot runtime swaps. A swap changes *what happened today*, not the plan (mvp-spec §12.2A).

```kdl
exercise_options {
  slot "A1.T2" {
    primary bench_press
    alternatives {                         // the `alternatives { }` wrapper is optional
      dumbbell_bench_press { label "DB Bench"; policy tracking_only }
      machine_chest_press  { label "Machine Press"; policy progression_equivalent }
    }
  }
}
```

`policy` is `tracking_only` (default) or `progression_equivalent`. A bare alternative node (no
`alternatives { }` wrapper) is also accepted.

**Built-in swaps.** Every template ships default, `tracking_only` swaps for the main barbell
lifts, so they always carry approved alternatives even when you don't author `exercise_options`:

| Lift | Built-in alternatives |
| --- | --- |
| `squat` | Hack Squat, Goblet Squat |
| `bench` | Dumbbell Bench, Dumbbell Incline, Incline Bench |
| `deadlift` | Romanian Deadlift, Dumbbell Romanian Deadlift |
| `press` | Dumbbell Press, Landmine Press |

An `exercise_options` entry for a slot replaces the built-in list for that slot — author it when you
want to curate, extend, or suppress the defaults.

---

## Patch files (`patches/*.fitspec`) — Implemented

Contextual, often time-bounded changes layered on top of the plan (injury, travel, deload).

```kdl
patch "shoulder-friendly-press" {
  description "Swap overhead press while the shoulder settles"
  active-from "2026-06-24"
  expires "2026-07-15"

  replace-exercise from=overhead_press to=incline_db_press lane="press\\.t1"
  add-conditioning day=sat activity="zone2 run 30m"
  cap target=rpe value="8" lane="squat\\..*"
}
```

| Construct | Form | Notes |
|---|---|---|
| `patch "name" { … }` | wrapper | |
| `description` | `description "…"` | free text |
| `active-from` | `active-from "date"` | when the patch starts applying |
| `expires` | `expires "date"` | when it stops |
| `replace-exercise` | `from=… to=… lane=…` | all three properties required; `lane` is a regex |
| `add-conditioning` | `day=… activity=…` | both required |
| `cap` | `target=… value=… [lane=…]` | cap a target (e.g. volume/RPE); `lane` optional regex |

Any other operation is a parse error.

---

## Lockfile (`fitspec.lock`) — Implemented

TOML, not FitSpec. Freezes template semantics for reproducibility (mvp-spec §9): per template id,
a `version`, `source`, `content_hash`, and `engine_version`. Generated/managed by the engine —
not hand-authored.

---

## Planned (not yet implemented)

Specced in mvp-spec §11 but **not** currently accepted by the parser:

- **Plan-level:** `substitutions`, `overrides`, plan-level `active patches`.
- **Patch ops:** `add cooldown`, a distinct `cap rpe`, `change suggested days`,
  `temporary load adjustment`, `enable` / `disable`. (Plan-level `warmup` and `equipment` are now
  implemented — see above; a patch-level `add-warmup` op that layers a warmup change for a
  date-bounded period is still future work.)

## Out of scope (by design)

The language deliberately excludes general-purpose programming (mvp-spec §10): no variables,
conditionals, loops, functions, or user-authored arbitrary progression code. Progression is
expressed through templates, not scripts.

## Related decisions

- [ADR 0001](adr/0001-training-log-format.md) — training log format and the measured-effort
  schema for hybrid training.
- [ADR 0002](adr/0002-plan-lifecycle-events.md) — tracking plan/program changes as
  `plan_changed` events.
- [ADR 0003](adr/0003-template-authoring-model.md) — proposed declarative template-authoring DSL
  (the progression primitives that would make this an authoring language).
- [ADR 0006](adr/0006-warmup-sets-and-equipment-rounding.md) — warmup sets as scoped, template-
  defaulted configuration, and equipment-aware load rounding as a cross-cutting deterministic layer.
