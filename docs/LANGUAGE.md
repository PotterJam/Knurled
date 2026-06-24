# FitSpec language reference

FitSpec is a small, declarative [KDL](https://kdl.dev) dialect. Today it is a **plan
configuration** language: it configures a built-in, versioned template and applies patches. It is
**not** (yet) a template-*authoring* language — progression logic lives in the engine
([engine/src/templates.rs](../engine/src/templates.rs), [engine/src/core.rs](../engine/src/core.rs)).
A user-authored template DSL is proposed in [ADR 0003](adr/0003-template-authoring-model.md).

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
| `template` | ✅ | `template "id@version"` or `template "id" version="x"` | Resolves to a built-in template; both spellings normalise to the same ref. |
| `units` | ✅ | `units kg` / `units lb` | Unrecognised values fall back to `kg`. |
| `schedule` | | `schedule [mode] { rotation …; suggested_days … }` | `mode` defaults to `next_workout`. `rotation` and `suggested_days` are lowercased token lists. |
| `starts` | | `starts { squat "80kg" … }` | Per-lift starting working weights. |
| `training_maxes` | | `training_maxes { squat "140kg" … }` | Per-lift training maxes (for %-based templates). |
| `accessories` | | `accessories { A1.T3 lat_pulldown … }` | Maps a `slot.tier` to an accessory exercise. |
| `rest` | | `rest { … }` | Rest prescription, see below. |
| `exercise_options` | | `exercise_options { slot "…" { … } }` | Runtime swap options, see below. |
| `assistance` | | `assistance …` | **Accepted but ignored** — reserved placeholder (mvp-spec §11). |

Any other directive is a parse error.

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
- **Patch ops:** `add warmup`, `add cooldown`, a distinct `cap rpe`, `change suggested days`,
  `temporary load adjustment`, `enable` / `disable`.
- **Template authoring:** the `fitspec template vendor` escape hatch and
  `template "./templates/x.fitspec"` file references (mvp-spec §9) are specced but unimplemented.

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
