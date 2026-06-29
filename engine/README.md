# Knurled Engine

`engine/` contains the Rust deterministic FitSpec core used by the CLI, tests, and eventually the static workbench/iOS bridge.

Package:

```text
crate: knurled-core
lib: knurled_core
crate-type: rlib, cdylib
```

The `cdylib` target is intentional: the core should be able to grow WASM and Swift adapter surfaces without moving semantics into clients.

Implemented in this first pass:

- Minimal FitSpec parser for MVP plan and patch files.
- Built-in locked templates for `gzcl.gzclp`, `gzcl.p-zero`, `531.basic`, and `531.beginners`.
- Canonical JSON IR, rendered session, execution contracts, state projection, validation, simulation, and generated-file checks.
- GZCLP T1/T2/T3 rendering and reducer coverage.
- 5/3/1 week rendering and week advancement.
- Starting Strength phases 1-3 as versioned built-in program presets.
- Runtime swap metadata, adjusted-today semantics, patch exercise replacement, state adjustment events, finalized shorter workouts, and generated-file backtest checks.

The core rule is that generated `state/` and `build/` files are reproducible from canonical files.

## Rest Policy

Rest is engine output, not player logic. Clients should render the resolved `RenderedItem.rest` value rather than inferring rest from exercise names, tiers, or display text.

Built-in programs provide default rest policies, and plans can override them with a generic `rest` block:

```kdl
rest {
  default 120
  tier t1 180
  exercise bench "210s"
  lane squat.t1 "4:00"
  slot a1.t2 5 min
}
```

Durations accept whole seconds (`180`, `"180s"`, `180 sec`), whole minutes (`"3m"`, `3 min`), and `mm:ss` (`"4:30"`). Bare numbers are unquoted; any form that starts with a digit and carries a suffix (`"180s"`, `"3m"`, `"4:30"`) must be quoted because KDL reads a bare digit-leading token as a number.

Resolution order is:

```text
plan slot
plan lane
plan exercise
plan tier
plan default
template slot
template lane
template exercise
template tier
template default
engine fallback
```

This keeps rest configurable for built-in templates, future user-built programs, and contextual plan changes without pushing hidden assumptions into iOS, the workbench, or the CLI.

## FitSpec Parser

FitSpec is a [KDL](https://kdl.dev) dialect: every construct is a KDL node with arguments, properties, and an optional `{ … }` block. Parsing in `engine/src/parser.rs` is two-phase:

1. The `kdl` crate owns tokenizing, brace matching, strings, numbers, comments, and line-numbered syntax errors, producing a `KdlDocument`.
2. A single walk over that document (`parse_plan`, `parse_patch`) interprets known nodes into the typed model and rejects the rest.

Lockfiles are TOML and decode straight through `serde` (`toml` crate). The parser stays intentionally strict while the language is pre-production: malformed syntax, unknown plan directives, unsupported patch operations, and missing required `template`/`units` fail through the engine `Result` path instead of becoming defaults.

The current surface covers `plan`, `template`, `units`, `schedule`, `starts`, `training_maxes`, `accessories`, exercise options, rest overrides, lockfile template entries, and the MVP patch operations (`replace-exercise`, `add-conditioning`, `cap`). The checked-in 5/3/1 `assistance` block is accepted as a known no-op until the model stores it.

A few authoring notes that fall out of KDL: list items are whitespace-separated (`rotation A1 B1 A2 B2`, no commas); values that start with a digit must be quoted (`squat "80kg"`); and multiple child nodes on one line need a `;` separator (`label "DB Bench"; policy tracking_only`). The template version may be written either inline (`template "gzclp.standard@1.0.0"`) or as a property (`template "gzclp.standard" version="1.0.0"`); both normalize to the same `id@version` identity.

Future agents: extend FitSpec by adding a match arm to the phase-two walk, not a bespoke sub-parser, and keep the model shapes stable — they feed the identity hashes and every client. The patch surface is deliberately narrow; richer contextual operations are a natural expansion area, expressed as new nodes/properties rather than prose.
