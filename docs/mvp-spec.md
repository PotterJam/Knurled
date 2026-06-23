# Knurled Editing, Git, Language and Workbench MVP

![Knurled logo](./Knurled_logo.png)

## Authoring layer for the Knurled Git-backed training system

## 1. Product summary

Knurled needs a small authoring and execution layer for creating, changing, validating, simulating, backtesting, and safely mutating a user-owned training repository.

This document covers the non-iOS side of the product:

```text
FitSpec language
Template system
Shared deterministic engine
CLI
Static/self-hostable HTML workbench
Git/GitHub repo mutation model
Validation, simulation, replay, and backtest tools
```

The iOS app is deliberately treated as a workout player. It consumes rendered sessions, collects training input, and commits validated events. It does not own program design, template authoring, or progression semantics.

Core promise:

```text
Use templates for power.
Use files for ownership.
Use patches for changes.
Use execution contracts for safe clients.
Use simulation and backtesting for confidence.
Use the CLI/workbench for safe edits.
Use iOS only for training.
```

## 1A. Brand and naming

```text
Product name: Knurled
Primary app/workbench/CLI brand: Knurled
Current plan/spec format for MVP: FitSpec-based (`plan.fitspec`, `fitspec.lock`)
Suggested CLI command: knurled
Suggested engine crate/package: knurled-core
```

This keeps the external product name hard-hitting and consumer-friendly while preserving the already-defined FitSpec file model for the MVP. If desired, the file naming can be rebranded later, but the docs below assume the existing `plan.fitspec` and `fitspec.lock` structure so implementation can start immediately.

## 2. Scope

This layer owns:

```text
Create a training repo
Configure plan basics
Install and lock templates
Apply explicit patches
Validate the repo
Compile plan files into IR
Render next workouts
Generate execution contracts
Validate workout inputs
Reduce workout inputs into canonical events
Replay logs into state
Regenerate build artifacts
Simulate future training
Backtest historical logs
Commit safe file changes to Git
Provide a static/self-hostable editing workbench
```

This layer does not own:

```text
iOS workout UI
Live set logging UX
Rest timers and Live Activities
In-workout navigation
Mobile offline queue UX
Visual plan editing inside the iOS app
Social features
Marketplace features
Coach/team workflows
```

## 3. System split

The MVP ecosystem is:

```text
fitspec CLI
  creates, validates, builds, previews, simulates, backtests, and mutates repos

static HTML workbench
  browser-hostable editing UI using the same engine via WASM, with GitHub API/PAT support and optional local mode

fitspec-core
  deterministic shared engine used by CLI, workbench, tests, simulator, and iOS

GitHub repo
  user-owned source of truth and sync substrate

iOS app
  execution-only workout player consuming rendered sessions and execution contracts
```

The boundary is strict:

```text
Authoring side decides what the plan means.
iOS records what happened.
fitspec-core validates and reduces every state transition.
Git records every meaningful change.
```

## 3A. Workbench delivery model

The Knurled workbench should be static-site-first.

Primary model:

```text
Host for free on GitHub Pages, Cloudflare Pages, Netlify, or similar.
Let users self-host easily.
No Knurled backend required for MVP.
Compile knurled-core / fitspec-core to WASM for browser-side validation, build, preview, and simulation.
Use browser-side GitHub API access for repo reads/writes.
```

Authentication model for MVP:

```text
Fine-grained GitHub PAT entered by the user.
Store locally in browser storage only.
Do not send the token to a Knurled server.
Do not require OAuth for MVP.
```

Later, optionally support:

```text
OAuth device flow
GitHub App auth
```

Optional local mode should still exist:

```text
knurled serve
```

That mode is useful for local repo editing, offline use, and development, but the default product story should be: static, free to host, trivial to self-host.

Bad:

```text
iOS sees “T1” and implements GZCLP progression itself.
Workbench guesses state effects from display text.
Simulator has separate progression shortcuts.
```

Good:

```text
All clients call fitspec-core.
fitspec-core validates inputs.
fitspec-core produces events, effects, projections, and rendered sessions.
```

## 4. Source of truth policy

FitSpec uses an event-sourced model.

Canonical files:

```text
plan.fitspec
fitspec.lock
patches/*.fitspec
logs/**/*.jsonl
```

Generated files:

```text
state/current.json
build/current.ir.json
build/next-workout.json
build/validation.json
```

Rule:

```text
Logs are canonical.
State is a projection.
Build files are generated artifacts.
```

For MVP, `state/` and `build/` should be committed because they make iOS simpler, make GitHub inspection easier, and make debugging less painful.

They must always be rebuildable from canonical files.

## 5. Valid repo invariant

A FitSpec repo is valid only if:

```text
replay(plan.fitspec + fitspec.lock + patches/*.fitspec + logs/**/*.jsonl)
  ==
state/current.json
```

And:

```text
build(plan.fitspec + fitspec.lock + patches/*.fitspec + logs/**/*.jsonl)
  ==
build/current.ir.json
  ==
build/next-workout.json
  ==
build/validation.json
```

The repo must survive this test:

```text
Delete state/
Delete build/
Run fitspec build
Get the same current state and next workout back.
```

If that fails, truth has leaked into generated files.

## 6. Deterministic engine guarantee

Given the same:

```text
plan.fitspec
fitspec.lock
template versions
template hashes
patches
logs
engine version
```

FitSpec must always produce the same:

```text
compiled IR
rendered next workout
execution contracts
effect preview
state projection
simulation report
backtest report
validation report
```

This guarantee is non-negotiable because the same repo may be acted on by:

```text
CLI
local HTML workbench
iOS app
simulator
backtester
LLM-generated patch workflow
human Git edits
```

## 7. Canonical repo structure

Recommended MVP repo:

```text
my-training/
  fitspec.toml
  plan.fitspec
  fitspec.lock

  patches/
    running-focus-6w.fitspec
    shoulder-friendly-pressing.fitspec

  templates/
    # empty unless user vendors templates

  logs/
    2026/
      06.jsonl

  state/
    current.json

  build/
    current.ir.json
    next-workout.json
    validation.json

  README.md
```

Recommended MVP `.gitignore`:

```gitignore
.tmp/
```

Do not ignore `state/` or `build/` in the MVP. Later, once iOS can reliably rebuild locally, `build/` can become disposable.

## 8. File types

### 8.1 `fitspec.toml`

Repo metadata and tool config.

Example:

```toml
[repo]
schema_version = "0.1"
units = "kg"

[build]
commit_generated = true

[github]
default_branch = "main"
```

### 8.2 `plan.fitspec`

Primary user-owned plan file. It should be short and template-driven.

Example GZCLP plan:

```kdl
plan "James GZCLP" {
  template "gzclp.standard@1.0.0"
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
    A2.T3 lat_pulldown
    B2.T3 barbell_row
  }
}
```

Example 5/3/1 plan:

```kdl
plan "James 5/3/1" {
  template "531.beginners@1.0.0"
  units kg

  schedule next_workout {
    rotation squat_day bench_day deadlift_day press_day
    suggested_days mon wed fri sat
  }

  training_maxes {
    squat "90kg"
    bench "65kg"
    deadlift "110kg"
    press "42.5kg"
  }

  assistance {
    push "50 reps"
    pull "50 reps"
    single_leg_core "50 reps"
  }
}
```

### 8.3 `patches/*.fitspec`

Patch files describe explicit future-plan changes. They are preferred for contextual, temporary, or LLM-generated changes.

Example shoulder patch:

```kdl
patch "shoulder-friendly-pressing" {
  description "Temporarily replace overhead press work"

  active-from "2026-06-22"
  expires "2026-07-20"

  replace-exercise from=overhead_press to=landmine_press lane="press.*"

  cap target=rpe value=8 lane="press.*"

  // aspirational: warmup blocks are not yet modeled
  add-warmup before=press {
    band_external_rotation "2x15"
    scap_pushup "2x10"
  }
}
```

Example running patch:

```kdl
patch "running-focus-6w" {
  active-from "2026-06-22"
  expires "2026-08-03"

  add-conditioning day=tuesday activity="easy_run 25min zone2"
  add-conditioning day=saturday activity="strides 6x20sec"

  cap target=lower_body_accessory_sets value=2
}
```

### 8.4 `fitspec.lock`

Locks template versions, content hashes, and engine compatibility.

Example:

```toml
[templates."gzclp.standard"]
version = "1.0.0"
source = "builtin"
content_hash = "sha256:abc123"
engine_version = "0.1.0"
```

The lockfile prevents silent behaviour changes when the CLI/app updates.

### 8.5 `logs/YYYY/MM.jsonl`

Append-only canonical training events.

Includes:

```text
completed sessions
partial sessions
continued sessions
corrections
skips
explicit state adjustments
```

### 8.6 `state/current.json`

Committed projection of current progress. It is convenient and inspectable, but not authoritative.

### 8.7 `build/*.json`

Generated output for clients, debugging, validation, and previews:

```text
build/current.ir.json
build/next-workout.json
build/validation.json
```

## 9. Template model

Templates are versioned packages.

Examples:

```text
gzclp.standard@1.0.0
gzclp.pzero@1.0.0
531.basic@1.0.0
531.beginners@1.0.0
```

Default mode:

```text
Small repo
Built-in locked templates
Plan config only
```

Escape hatch:

```bash
fitspec template vendor gzclp.standard
```

This copies the expanded template into:

```text
templates/gzclp.standard.fitspec
```

Then the plan can reference:

```kdl
template "./templates/gzclp.standard.fitspec"
```

Rules:

```text
Template semantics are frozen by lockfile.
Template upgrades are explicit.
Backtests fail if locked templates are unavailable.
Built-in templates must never mutate silently.
```

## 10. MVP language philosophy

The language should be:

```text
small
declarative
inspectable
LLM-editable
Git-diffable
template-driven
safe by default
deterministically compilable
```

It should not be:

```text
general-purpose code
JavaScript inside workouts
a macro language
a hidden app database
a full visual programming system
```

Bad:

```javascript
if (completedReps < target) {
  state.stage += 1
}
```

Good:

```kdl
on fail {
  advance_stage
}
```

For MVP, most progression logic lives inside versioned templates. User-facing FitSpec mostly configures templates and applies patches.

## 11. MVP language scope

Plan-level constructs:

```text
plan
template
units
schedule
starts
training_maxes
accessories
substitutions
overrides
active patches
```

Patch-level constructs:

```text
replace exercise
add warmup
add cooldown
add conditioning
cap volume
cap RPE
set expiry
change suggested days
temporary load adjustment
enable / disable
```

Non-MVP constructs:

```text
arbitrary user-authored progression rules
loops
variables
functions
user-authored conditionals
full periodisation DSL
visual template authoring
coach/team programming
```

## 12. Program mutation model

Every future-plan change is one of three things:

```text
1. Direct edit to plan.fitspec
2. New or changed patch file
3. Explicit state adjustment event
```

### 12.1 Direct plan edits

Used for stable configuration:

```text
starting weights
training maxes
default accessories
rotation
suggested days
template choice
units
```

### 12.2 Patch files

Used for contextual changes:

```text
injury
running block
holiday gym
equipment substitution
short-session block
shoulder-friendly pressing
temporary deload
```

### 12.2A Exercise options and runtime swaps

Knurled should make exercise swapping easy while running a workout, without accidentally changing the plan.

Goals:

```text
bench is busy -> pick an approved alternative in the app
track weights and history for the performed alternative
complete the session cleanly
keep the future plan unchanged by default
```

Default rule:

```text
A runtime swap changes what happened today, not what the program means.
```

That means:

```text
The slot stays the same slot_id and progression lane.
The plan still says the primary exercise is prescribed.
The log records both prescribed_exercise and performed_exercise.
The app can show encoded alternatives directly from the rendered workout.
The future plan is unchanged unless the actual plan/patch is changed.
```

By default, swap options are `tracking_only`:

```text
They preserve history for the alternative exercise.
They let the user finish the session.
They do not silently rewrite the plan.
They do not automatically advance the primary lane unless the plan explicitly says the alternative is progression-equivalent.
```

This is important for cases like:

```text
bench press busy
no rack available
only dumbbells available
machine fallback in a crowded gym
shoulder irritated today, but no permanent plan change intended
```

Recommended plan-level shape:

```kdl
exercise_options {
  slot "A1.T2" {
    primary bench_press

    alternatives {
      dumbbell_bench_press {
        label "DB Bench"
        policy tracking_only
      }

      incline_dumbbell_press {
        label "Incline DB Press"
        policy tracking_only
      }

      machine_chest_press {
        label "Machine Chest Press"
        policy tracking_only
      }
    }
  }
}
```

If a user wants a swap to become the new real plan, that must happen through a normal plan edit or patch.

Bad:

```text
Swap to DB bench once and silently turn the program into DB bench.
```

Good:

```text
Swap to DB bench in the app today for logging/history.
Edit the plan later if DB bench should become the real programmed movement.
```

Rendered sessions should expose swap metadata like:

```json
{
  "exercise_options": {
    "primary": "bench_press",
    "allow_runtime_swap": true,
    "default_policy": "tracking_only",
    "alternatives": [
      {
        "option_id": "db_bench",
        "exercise": "dumbbell_bench_press",
        "label": "DB Bench",
        "policy": "tracking_only"
      },
      {
        "option_id": "machine_press",
        "exercise": "machine_chest_press",
        "label": "Machine Chest Press",
        "policy": "tracking_only"
      }
    ]
  }
}
```

Canonical logs should record the distinction clearly:

```json
{
  "slot_id": "a1.t2",
  "progression_lane": "bench.t2",
  "prescribed_exercise": "bench_press",
  "performed_exercise": "dumbbell_bench_press",
  "swap_reason": "bench_busy",
  "swap_policy": "tracking_only"
}
```

For MVP, `tracking_only` should be the default and should be enough for the common "equipment busy" case.

### 12.3 State adjustment events

Used when changing current progress without changing program definition.

Examples:

```text
set squat.t1 next load to 77.5kg
reset bench.t2 to 3x10
deload deadlift.t1 by 10%
mark A1 as next session
```

These are logged explicitly:

```json
{
  "id": "evt_20260624_state_adjust",
  "type": "state_adjusted",
  "lane": "squat.t1",
  "change": {
    "load": {
      "from": "82.5kg",
      "to": "77.5kg"
    }
  },
  "reason": "manual deload"
}
```

No tool may silently edit `state/current.json` as if it were truth.

## 13. Shared engine responsibilities

`fitspec-core` must support:

```text
load repo
parse plan.fitspec
parse patch files
load built-in templates
check fitspec.lock
apply active patches
compile to canonical IR
validate plan and patch semantics
render next workout
render future previews
produce execution contracts
validate execution inputs
convert execution inputs to training events
append canonical log events
project state from logs
apply state adjustment events
write generated state/build files
check generated file freshness
explain plan changes
simulate future sessions
replay logs
backtest historical events
show diff summary
```

It does not need:

```text
custom user-defined progression functions
arbitrary scripting
advanced periodisation
team programming
hosted web editor
marketplace
AI chat integration
```

## 14. Execution contract

Every rendered session and rendered item must include an execution contract.

The execution contract tells any client:

```text
what should be shown
what input modes are valid
what shortcut inputs are allowed
what event shape should be saved
what counts as complete
what effects will be produced
```

Clients include:

```text
iOS app
CLI
local HTML workbench
simulator
backtester
test runner
LLM-generated scenario runner
```

The execution layer must not infer progression behaviour from exercise name, tier, or display text.

## 15. Rendered session schema

A rendered session contains:

```text
identity
display fields
plan/template hashes
session snapshot hash
items
execution contracts
effect previews
required completion information
```

Example:

```json
{
  "type": "rendered_session",
  "schema_version": "0.1",
  "session_id": "gzclp.a1",
  "display_name": "GZCLP - A1",
  "suggested_date": "2026-06-24",
  "plan_hash": "sha256:abc",
  "template_hash": "sha256:template",
  "rendered_session_hash": "sha256:def",
  "items": [
    {
      "item_id": "a1.t1",
      "slot_id": "a1.t1",
      "progression_lane": "squat.t1",
      "progression_rule": "gzclp.t1",
      "exercise": "squat",
      "display": {
        "title": "Squat T1",
        "subtitle": "82.5kg - 5 / 5 / 5+"
      },
      "prescription": {
        "sets": [
          { "set": 1, "load": "82.5kg", "target_reps": 5 },
          { "set": 2, "load": "82.5kg", "target_reps": 5 },
          { "set": 3, "load": "82.5kg", "target_reps": 5, "amrap": true }
        ]
      },
      "execution_contract": {
        "recommended_input": "amrap_final_set",
        "fallback_inputs": ["per_set_reps", "load_override", "note"],
        "completion_rule": "all_required_sets_meet_target",
        "event_template": "exercise_result_v1",
        "required_for_completion": true
      },
      "effect_preview": {
        "pass": [
          {
            "op": "increase_load",
            "lane": "squat.t1",
            "from": "82.5kg",
            "to": "85kg"
          }
        ],
        "fail": [
          {
            "op": "advance_stage",
            "lane": "squat.t1",
            "from": "5x3+",
            "to": "6x2+"
          }
        ]
      }
    }
  ]
}
```

## 16. Execution contract fields

Each rendered item must include:

```text
stable identity
prescribed work
valid input modes
default input mode
fallback input modes
completion rule
event template
validation constraints
effect preview
```

Identity:

```json
{
  "item_id": "a1.t1",
  "slot_id": "a1.t1",
  "progression_lane": "squat.t1",
  "progression_rule": "gzclp.t1",
  "plan_hash": "sha256:abc",
  "rendered_session_hash": "sha256:def"
}
```

This prevents:

```text
bench.t2 result accidentally progressing bench.t1
squat.t2 being confused with squat.t1
an old workout being replayed against the wrong plan
```

AMRAP input schema:

```json
{
  "input_schema": {
    "mode": "amrap_final_set",
    "fields": [
      {
        "name": "final_set_reps",
        "type": "integer",
        "min": 0,
        "default": 5,
        "required": true
      }
    ],
    "fallback": "per_set_reps"
  }
}
```

Straight-set input schema:

```json
{
  "input_schema": {
    "mode": "done_or_missed_per_set",
    "fields": [
      {
        "name": "sets",
        "type": "set_results",
        "default": "done_as_prescribed"
      }
    ],
    "fallback": "per_set_reps"
  }
}
```

Run input schema:

```json
{
  "input_schema": {
    "mode": "duration_completed",
    "fields": [
      { "name": "completed", "type": "boolean", "required": true },
      { "name": "duration", "type": "duration", "required": false },
      { "name": "rpe", "type": "integer", "min": 1, "max": 10, "required": false }
    ]
  }
}
```

## 17. Execution input schema

The app, CLI, workbench, and simulator should not directly create final training events. They create an `ExecutionInput`.

Example:

```json
{
  "type": "execution_input",
  "schema_version": "0.1",
  "rendered_session_hash": "sha256:def",
  "status": "complete",
  "started_at": "2026-06-24T10:10:00+01:00",
  "completed_at": "2026-06-24T11:02:00+01:00",
  "inputs": [
    {
      "item_id": "a1.t1",
      "mode": "amrap_final_set",
      "final_set_reps": 7
    },
    {
      "item_id": "a1.t2",
      "mode": "per_set_reps",
      "sets": [
        { "set": 1, "load": "45kg", "reps": 10 },
        { "set": 2, "load": "45kg", "reps": 10 },
        { "set": 3, "load": "45kg", "reps": 8 }
      ]
    }
  ]
}
```

The engine validates this against the rendered session contract, then emits canonical training events and effects.

## 18. Canonical training events

Canonical event types:

```text
session_saved
session_continued
session_completed
session_corrected
session_skipped
state_adjusted
```

Completed session event:

```json
{
  "id": "evt_20260624_1010",
  "type": "session_completed",
  "program": "gzclp",
  "session_id": "a1",
  "plan_hash": "sha256:abc",
  "template_hash": "sha256:template",
  "rendered_session_hash": "sha256:def",
  "engine_version": "0.1.0",
  "started_at": "2026-06-24T10:10:00+01:00",
  "completed_at": "2026-06-24T11:02:00+01:00",
  "results": [
    {
      "slot_id": "a1.t1",
      "progression_lane": "squat.t1",
      "exercise": "squat",
      "prescribed": {
        "load": "82.5kg",
        "reps": [5, 5, "5+"]
      },
      "actual": [
        { "set": 1, "load": "82.5kg", "reps": 5 },
        { "set": 2, "load": "82.5kg", "reps": 5 },
        { "set": 3, "load": "82.5kg", "reps": 7 }
      ],
      "outcome": "pass"
    }
  ]
}
```

Partial session event:

```json
{
  "id": "evt_20260624_1045_partial",
  "type": "session_saved",
  "status": "partial",
  "program": "gzclp",
  "session_id": "a1",
  "plan_hash": "sha256:abc",
  "rendered_session_hash": "sha256:def",
  "started_at": "2026-06-24T10:10:00+01:00",
  "saved_at": "2026-06-24T10:45:00+01:00",
  "results": [
    {
      "slot_id": "a1.t1",
      "progression_lane": "squat.t1",
      "exercise": "squat",
      "actual": [
        { "set": 1, "load": "82.5kg", "reps": 5 },
        { "set": 2, "load": "82.5kg", "reps": 5 },
        { "set": 3, "load": "82.5kg", "reps": 7 }
      ],
      "outcome": "pass"
    }
  ]
}
```

Continuation event:

```json
{
  "id": "evt_20260624_1320_continue",
  "type": "session_continued",
  "continues_event_id": "evt_20260624_1045_partial",
  "session_id": "a1",
  "results_added": [
    {
      "slot_id": "a1.t2",
      "progression_lane": "bench.t2",
      "exercise": "bench",
      "actual": [
        { "set": 1, "load": "45kg", "reps": 10 },
        { "set": 2, "load": "45kg", "reps": 10 },
        { "set": 3, "load": "45kg", "reps": 8 }
      ],
      "outcome": "fail"
    }
  ]
}
```

Correction event:

```json
{
  "id": "evt_20260624_1800_correction",
  "type": "session_corrected",
  "corrects_event_id": "evt_20260624_1320_continue",
  "reason": "wrong reps entered",
  "changes": [
    {
      "path": "results[a1.t2].actual[2].reps",
      "before": 8,
      "after": 9
    }
  ]
}
```

Skip event:

```json
{
  "id": "evt_20260624_skip",
  "type": "session_skipped",
  "session_id": "a2",
  "policy": "push_forward",
  "reason": "busy"
}
```

Ad-hoc accessory result:

```json
{
  "slot_id": "ad_hoc.01",
  "source": "added_during_session",
  "exercise": "lat_pulldown",
  "actual": [
    { "load": "45kg", "reps": 12 },
    { "load": "45kg", "reps": 12 },
    { "load": "45kg", "reps": 10 }
  ],
  "progression_lane": null,
  "note": "Added at end"
}
```

## 19. State projection

State derives from logs.

Example:

```json
{
  "program_hash": "sha256:abc",
  "last_event_id": "evt_20260624_1320_continue",
  "cursor": {
    "next_session": "a2",
    "week": 2,
    "cycle": 1
  },
  "lanes": {
    "squat.t1": {
      "load": "85kg",
      "stage": "5x3+"
    },
    "bench.t2": {
      "load": "45kg",
      "stage": "3x8"
    }
  },
  "sessions": {
    "a1_20260624": {
      "status": "complete",
      "source_events": [
        "evt_20260624_1045_partial",
        "evt_20260624_1320_continue"
      ]
    }
  }
}
```

Rules:

```text
Partial sessions do not advance the cursor.
Completed sessions advance the cursor.
Correction events rebuild the projected session result.
State adjustment events update lanes/cursor explicitly.
Generated state must match replayed logs.
```

## 20. Progression rules owned by templates

### 20.1 GZCLP MVP support

Support:

```text
T1
- staged progression
- AMRAP final set
- pass/fail
- increase load
- advance stage on failure

T2
- straight sets
- pass/fail
- rep-stage progression
- increase load
- advance rep stage on failure

T3
- target reps
- final-set AMRAP-style progression
- optional accessory-style logging
```

Minimum templates:

```text
gzclp.standard
gzclp.pzero
```

Do not attempt to support every internet variant in MVP.

### 20.2 5/3/1 MVP support

Support:

```text
training max
percentage-based main sets
AMRAP set
weekly progression
cycle progression
training max increase after cycle
basic supplemental work
simple assistance
```

Minimum templates:

```text
531.basic
531.beginners
```

The renderer must support:

```text
Week 1: 65 / 75 / 85+
Week 2: 70 / 80 / 90+
Week 3: 75 / 85 / 95+
Week 4: deload or next cycle, depending on template
```

## 21. Adjusted-today and ad-hoc accessory semantics

If the user lowers the load today:

```text
Log adjusted_today.
Do not advance the lane automatically.
Repeat planned load next time by default.
```

Reason:

```text
A bad-day adjustment should not silently rewrite the program.
```

Optional explicit action:

```text
Set future lane load to today’s adjusted load.
```

That must create either:

```text
state_adjusted event
or an explicit patch, depending on intent
```

Ad-hoc accessories:

```text
Logged for history only.
No progression lane by default.
No future plan change by default.
```

Adding the accessory to future sessions is a patch/workbench feature, not a default iOS logging effect.

## 22. Engine API shape

Conceptual API:

```text
load_repo(path) -> RepoModel
compile(repo) -> CompiledPlan
validate(repo) -> ValidationReport
render_next(repo) -> RenderedSession
validate_input(rendered_session, execution_input) -> ValidationResult
reduce_input(repo, execution_input) -> {
  event,
  effects,
  new_state,
  next_workout
}
commit_event(repo, event, new_state, build_outputs) -> CommitResult
```

Simulation and history APIs:

```text
simulate(repo, scenario) -> SimulationReport
replay(repo) -> StateProjection
backtest(repo) -> BacktestReport
check_generated(repo) -> GeneratedFileReport
```

The same reducer path must be used for:

```text
real workout submissions
partial saves
continuations
corrections
skips
manual state adjustments
simulated future events
backtested historical events
```

## 23. Build and validation commands

### 23.1 `fitspec validate`

Checks:

```text
plan syntax
template lock
patch validity
progression lanes
missing exercises
invalid substitutions
invalid runtime swap options
renderability of next workout
state/log consistency
execution contracts
event schema compatibility
generated file freshness
```

### 23.2 `fitspec build`

Runs:

```text
parse
lock check
apply patches
compile IR
validate
project state
render next workout
write state/current.json
write build/current.ir.json
write build/next-workout.json
write build/validation.json
```

### 23.3 `fitspec check-generated`

Checks committed generated output against fresh regeneration.

Example failure:

```text
Generated files are stale.

Run:
fitspec build

Changed:
- state/current.json
- build/next-workout.json
```

## 24. Preview, simulation, replay, and backtest

### 24.1 Preview

```bash
fitspec preview next
fitspec preview --weeks 4
fitspec preview --with-patch running-focus-6w
```

Meaning:

```text
Given current state, show upcoming prescriptions.
Do not assume future results.
Do not mutate logs or state.
```

### 24.2 Simulation

```bash
fitspec simulate next --all-pass
fitspec simulate next --result squat.t1=5,5,4
fitspec simulate --weeks 8 --strategy all-pass
fitspec simulate --weeks 8 --strategy conservative
```

Meaning:

```text
Start from current state.
Generate hypothetical workout results.
Apply progression rules through the real reducer.
Show what happens.
Do not write logs unless explicitly requested.
```

Simulation must create synthetic `ExecutionInput` or synthetic canonical events and pass them through the same reducer as real workouts.

### 24.3 Replay

```bash
fitspec replay
fitspec replay --write-state
```

Meaning:

```text
Start from initial state.
Apply logs in order.
Merge partial/continued/corrected sessions.
Rebuild state projection.
Optionally write state/current.json.
```

### 24.4 Backtest

```bash
fitspec backtest
fitspec backtest --strict
fitspec backtest --from 2026-06-01 --to 2026-08-01
fitspec backtest --explain-event evt_20260624_1010
```

Backtest does:

```text
1. Load plan.fitspec.
2. Load fitspec.lock.
3. Load active patches.
4. Replay logs from the beginning.
5. Reconstruct state.
6. Compare reconstructed state to state/current.json.
7. Re-render next workout.
8. Compare rendered output to build/next-workout.json.
9. Report divergences.
```

Success output:

```text
Backtest passed.

Events replayed: 47
Corrections applied: 3
Skips: 2
State projection: matches
Next workout: matches
```

Failure output:

```text
Backtest failed.

state/current.json does not match replayed state.

Lane:
bench.t2

Committed state:
45kg - 3x8

Replayed state:
45kg - 3x10

Run:
fitspec replay --write-state

Or inspect:
fitspec backtest --explain-lane bench.t2
```

## 25. Snapshot and hash requirements

Every submitted workout event must store:

```text
plan_hash
template_hash or lock_hash
rendered_session_hash
engine_version
```

Every rendered session must have a stable hash.

Every committed event must refer to the rendered session it came from.

This allows FitSpec to answer:

```text
What plan was this workout performed against?
Did the template change later?
Can this event still be replayed?
Does current state match replayed state?
```

If a plan changes after a workout, historical events remain valid because they reference their original rendered snapshot.

## 26. Lockfile requirements for backtesting

Backtesting only works if template semantics are frozen.

Therefore:

```text
plan.fitspec + fitspec.lock + logs = reproducible history
```

If the CLI/app cannot find the locked template version, backtest must fail clearly:

```text
Cannot backtest.

Missing template:
gzclp.standard@1.0.0 sha256:abc123

Run:
fitspec template install gzclp.standard@1.0.0
or vendor the template.
```

## 27. Workout submit flow

When the iOS app submits a completed workout, the authoring layer expects this sequence:

```text
1. iOS creates ExecutionInput from user-entered data.
2. Engine validates ExecutionInput against the rendered session’s execution contract.
3. Engine converts ExecutionInput into a canonical TrainingEvent.
4. Append TrainingEvent to logs/YYYY/MM.jsonl.
5. Rebuild or update state/current.json.
6. Regenerate build/current.ir.json, build/next-workout.json, and build/validation.json.
7. Commit all changed files.
8. Push to GitHub.
```

A completed workout commit may change:

```text
logs/2026/06.jsonl
state/current.json
build/current.ir.json
build/next-workout.json
build/validation.json
```

Example commit messages:

```text
Complete GZCLP A1 - 2026-06-24
Save partial GZCLP A1 - 2026-06-24
Continue GZCLP A1 - 2026-06-24
Correct GZCLP A1 - 2026-06-24
Skip GZCLP A2 - push forward
Enable running-focus patch
Set squat.t1 load to 77.5kg
```

## 28. iOS sync contract

On sync, iOS treats files like this:

```text
plan.fitspec       canonical
fitspec.lock       canonical
patches/           canonical
logs/              canonical
state/current.json projected cache
build/             generated cache
```

If `build/next-workout.json` exists and validation says generated files are current, iOS can use it directly.

If generated files are stale and iOS has the engine embedded, it may rebuild locally.

If generated files are stale and iOS cannot rebuild, it shows:

```text
Repo needs rebuild.

Run:
fitspec build

Or sync from a repo with updated generated files.
```

For MVP, prefer making CLI/workbench regenerate and commit build files so iOS can stay thin.

## 29. CLI MVP

Command name:

```bash
fitspec
```

### 29.1 Create repo

```bash
fitspec init my-training --template gzclp.standard
```

Prompts:

```text
units
starting weights or training maxes
suggested days
accessories
bar increment rules
GitHub repo name
private/public
```

Output:

```text
fitspec.toml
plan.fitspec
fitspec.lock
state/current.json
build/current.ir.json
build/next-workout.json
build/validation.json
README.md
```

### 29.2 Common commands

```bash
fitspec validate
fitspec build
fitspec preview next
fitspec preview --weeks 4
fitspec simulate --weeks 8 --strategy all-pass
fitspec replay
fitspec replay --write-state
fitspec check-generated
fitspec backtest
fitspec backtest --strict
```

### 29.3 Configure common values

```bash
fitspec set start squat 80kg
fitspec set tm bench 65kg
fitspec set schedule mon wed fri
fitspec set accessory A1.T3 lat_pulldown
```

These commands edit `plan.fitspec`, then validate and rebuild.

### 29.4 Patch commands

```bash
fitspec patch new shoulder-friendly-pressing
fitspec patch enable shoulder-friendly-pressing
fitspec patch disable shoulder-friendly-pressing
fitspec patch expire shoulder-friendly-pressing 2026-07-20
fitspec patch preview shoulder-friendly-pressing
```

Helpers:

```bash
fitspec patch substitute overhead_press landmine_press --where "press.*"
fitspec patch add-conditioning running-focus-6w --day tue --activity "easy_run 25min zone2"
```

### 29.5 State adjustment commands

```bash
fitspec state show
fitspec state rebuild
fitspec state set-load squat.t1 77.5kg --reason "manual deload"
fitspec state reset-stage bench.t2 3x10
fitspec state set-next-session A1
```

These create explicit log events, not silent state edits.

### 29.6 Template commands

```bash
fitspec template list
fitspec template show gzclp.standard
fitspec template explain gzclp.standard
fitspec template vendor gzclp.standard
fitspec template upgrade gzclp.standard
fitspec template diff gzclp.standard@1.0.0 gzclp.standard@1.1.0
```

### 29.7 Git helpers

```bash
fitspec git status
fitspec git commit -m "Update GZCLP accessories"
fitspec github create --private
fitspec github push
```

Do not reinvent Git. Provide common shortcuts only.

## 30. Local HTML workbench MVP

The workbench launches locally:

```bash
fitspec serve
```

Then opens:

```text
http://localhost:4321
```

It edits local repo files using the same engine as CLI and iOS.

It is not a hosted app initially.

## 31. Workbench screens

### 31.1 Overview

```text
FitSpec Workbench

Repo: my-training
Plan: James GZCLP
Template: gzclp.standard@1.0.0
Status: valid

Next workout:
A1 - Squat T1 / Bench T2 / Row T3

Actions:
[Preview next 4 weeks]
[Simulate 8 weeks]
[Backtest]
[Edit plan basics]
[Manage patches]
[Validate]
[Commit changes]
```

### 31.2 Plan basics

Form over `plan.fitspec`:

```text
units
template
starting weights / training maxes
rotation
suggested days
default accessories
exercise options / approved alternatives
```

On save:

```text
show diff
validate
render next workout
optionally commit
```

### 31.3 Patch manager

```text
Active
[on] running-focus-6w
[on] shoulder-friendly-pressing

Inactive
[off] holiday-gym
[off] short-session
```

Patch detail:

```text
Patch: running-focus-6w

Changes:
+ Tuesday easy run 25min
+ Saturday strides 6x20s
- cap lower accessories at 2 sets

[Preview]
[Simulate]
[Enable/Disable]
[Edit file]
[Commit]
```

### 31.4 Preview

Show:

```text
next workout
next 7 days
next 4 weeks
before/after patch preview
warnings
```

For each rendered workout:

```text
exercise
lane
scheme
load
logging mode
expected effect
```

### 31.5 Simulation

```text
Simulate 8 weeks

Strategy:
[All pass]

Projected:
Squat T1: 80kg -> 120kg
Bench T1: 55kg -> 72.5kg
Press T1: 37.5kg -> 50kg

Warnings:
- Deadlift T1 reaches aggressive load by week 7
```

### 31.6 Backtest

```text
Backtest passed

Events: 47
Corrections: 3
Skips: 2
State: matches current projection
Build files: current
```

Failure view includes:

```text
mismatched lane
committed state
replayed state
source events
suggested fix
```

### 31.7 State tools

Dangerous actions with confirmation:

```text
Set next load
Reset stage
Set next session
Rebuild state from logs
```

Every action creates an explicit event.

### 31.8 Git panel

```text
Changed files:
- plan.fitspec
- fitspec.lock
- state/current.json
- build/next-workout.json

Diff:
...

[Commit]
[Push]
```

Commit message suggestions:

```text
Update GZCLP accessories
Enable running-focus patch
Set squat.t1 load to 77.5kg
```

## 32. Why CLI + thin HTML, not iOS editing

The iOS app should remain focused:

```text
train
log
continue
correct
submit
sync
```

Program editing belongs outside iOS initially because:

```text
text files are easier to review
Git diffs matter
LLMs can edit files directly
patches need preview and validation
phone UI encourages accidental hidden mutation
```

The thin HTML workbench gives convenience without polluting the workout app.

## 33. LLM workflow

Preferred workflow:

```text
User asks LLM:
"Make this GZCLP plan more running-friendly for 6 weeks."

LLM edits:
patches/running-focus-6w.fitspec

User runs:
fitspec validate
fitspec preview --with-patch running-focus-6w
fitspec simulate --weeks 6 --with-patch running-focus-6w
fitspec backtest

Then:
git commit
```

Guardrails:

```text
LLM-generated changes must validate.
LLM-generated changes should be patches by default.
The engine shows rendered consequences.
The user commits the diff.
The LLM should not directly modify logs or state unless explicitly requested.
```

## 34. MVP syntax strategy

Implement the language in two steps.

### Step 1: JSON IR first

Define canonical schemas:

```text
CompiledPlan
RenderedSession
ExecutionContract
ExecutionInput
TrainingEvent
EffectSet
StateProjection
ValidationReport
SimulationReport
BacktestReport
```

Everything compiles into or flows through these.

### Step 2: Simple FitSpec parser

Use a small parser for human-facing syntax.

Do not make the syntax clever.

If parser work slows the project down, use `plan.toml` temporarily and keep `.fitspec` for later.

## 35. Implementation recommendation

Preferred implementation shape:

```text
Core engine in a portable language suitable for iOS reuse.
CLI wraps the core engine.
Workbench calls the CLI or engine directly.
iOS embeds the core engine or consumes committed build outputs.
JSON schemas come before parser polish.
```

Practical route:

```text
1. Build schemas.
2. Hard-code GZCLP and 5/3/1 templates.
3. Implement replay/state projection.
4. Implement render_next with execution contracts.
5. Implement validate_input and reduce_input.
6. Implement CLI init/build/preview/backtest.
7. Only then polish FitSpec syntax and workbench editing.
```

## 36. Build order

### Phase 1: Schema + engine

```text
Define canonical JSON schemas.
Implement deterministic state projection.
Implement GZCLP T1/T2/T3 reducer.
Implement 5/3/1 renderer/reducer.
Implement execution contracts.
```

### Phase 2: CLI init + build + preview

```text
fitspec init
fitspec validate
fitspec build
fitspec preview next
fitspec preview --weeks 4
```

### Phase 3: Simulation + replay + backtest

```text
fitspec replay
fitspec simulate
fitspec backtest
fitspec check-generated
```

### Phase 4: Lockfile + templates

```text
Built-in template registry.
fitspec.lock.
Template hash validation.
Template vendor command.
```

### Phase 5: Plan editing commands

```text
fitspec set start
fitspec set tm
fitspec set schedule
fitspec set accessory
```

### Phase 6: Patch commands

```text
patch new/enable/disable/expire/preview
basic substitutions
conditioning additions
volume caps
```

### Phase 7: State commands

```text
state show
state set-load
state reset-stage
state set-next-session
```

### Phase 8: Local HTML workbench

```text
overview
plan basics
patch manager
preview
simulation
backtest
state tools
Git panel
```

### Phase 9: LLM-friendly docs

```text
repo contract docs
schema docs
patch examples
template explanation docs
safe-editing guide
```

## 37. Acceptance tests

### 37.1 GZCLP T1 pass

```text
Given squat.t1 80kg at 5x3+
When actual is 5,5,7 at 80kg
Then outcome is pass
And next squat.t1 load is 82.5kg or configured increment
And stage remains 5x3+
```

### 37.2 GZCLP T1 fail

```text
Given squat.t1 80kg at 5x3+
When actual is 5,5,4 at 80kg
Then outcome is fail
And next stage is 6x2+
And load follows template rule
```

### 37.3 GZCLP T2 fail

```text
Given bench.t2 45kg at 3x10
When actual is 10,10,8
Then outcome is fail
And next bench.t2 stage is 3x8
```

### 37.4 GZCLP T3 pass

```text
Given row.t3 target 15+
When final set reaches the template pass threshold
Then load increases by configured increment
```

### 37.5 5/3/1 rendering

```text
Given training maxes
When rendering week 1
Then percentages and AMRAP set match template
```

### 37.6 5/3/1 cycle progression

```text
Given completed cycle
When reducer processes final week
Then training maxes increase according to template
```

### 37.7 Partial + continued session

```text
Given A1 saved partial with squat only
When continued later with bench and row
Then projected session is complete
And cursor advances only after completion
```

### 37.8 Correction event

```text
Given completed A1 with bench.t2 reps 10,10,8
When correction changes last set to 10
Then replay updates outcome and lane state
```

### 37.9 Adjusted today

```text
Given squat.t1 prescribed 82.5kg
When user logs final set at 77.5kg
Then outcome is adjusted_today
And lane does not auto-progress
And next prescription repeats planned load unless explicit state_adjusted event exists
```

### 37.10 Backtest

```text
Given committed state and build files
When state/ and build/ are deleted and rebuilt
Then regenerated files match committed files
```

### 37.11 Simulation uses reducer

```text
Given simulate --weeks 8 --strategy all-pass
When synthetic results are generated
Then every synthetic result is processed by the same reduce_input path as real workouts
```

## 38. Success criteria

The authoring layer succeeds when:

```text
A user can create a GZCLP repo from scratch.
A user can create a 5/3/1 repo from scratch.
The repo can render the next workout.
The repo can simulate 8 weeks.
The repo can backtest historical logs.
A plan patch can be previewed before commit.
Generated state can be deleted and rebuilt.
An iOS-submitted workout can be validated and reduced.
A correction event changes projected state correctly.
Template hashes prevent silent semantic drift.
```

The key technical test:

```text
Can the system replay, explain, and reproduce every state transition from files in Git?
```

## 39. Hard constraints

```text
Do not let the authoring layer become a hidden app database.
Do not let built-in templates mutate silently.
Do not make iOS the primary program editor.
Do not allow program changes without validation.
Do not make normal users write full template definitions.
Do not confuse plan edits with log corrections.
Do not auto-change future training because the user adjusted a load on one bad day.
Do not let clients infer progression behaviour from exercise names or display strings.
Do not implement separate simulation logic from real reduction logic.
Do not treat state/current.json as authoritative if it disagrees with logs.
Do not treat build/next-workout.json as authoritative if it disagrees with a fresh render.
Do not mutate state without appending an explicit log event.
Do not allow iOS to create hidden state transitions that cannot be replayed.
Do not allow template upgrades to change historical replay without a lockfile/template hash change.
Do not let generated file drift silently.
Do not ship iOS logging before simulation, replay, and backtest work for GZCLP and 5/3/1 exist.
```

## 40. Final rule

The design is safe only if this remains true:

```text
Canonical:
- plan.fitspec
- fitspec.lock
- patches/*.fitspec
- logs/**/*.jsonl

Derived:
- state/current.json
- build/*.json
```

Generated files are allowed to exist in Git because they make the MVP practical.

Generated files are not allowed to become truth.
