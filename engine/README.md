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
- Built-in locked templates for `gzclp.standard`, `gzclp.pzero`, `531.basic`, and `531.beginners`.
- Canonical JSON IR, rendered session, execution contracts, state projection, validation, simulation, and generated-file checks.
- GZCLP T1/T2/T3 rendering and reducer coverage.
- 5/3/1 week rendering and week advancement.
- Starting Strength phases 1-3 as versioned built-in program presets.
- Runtime swap metadata, adjusted-today semantics, patch exercise replacement, state adjustment events, partial/continuation replay, and generated-file backtest checks.

The core rule is that generated `state/` and `build/` files are reproducible from canonical files.

## Rest Policy

Rest is engine output, not player logic. Clients should render the resolved `RenderedItem.rest` value rather than inferring rest from exercise names, tiers, or display text.

Built-in programs provide default rest policies, and plans can override them with a generic `rest` block:

```fitspec
rest {
  default 120s
  tier t1 180s
  exercise bench 210s
  lane squat.t1 240s
  slot a1.t2 300s
}
```

Durations currently accept whole seconds (`180`, `180s`, `180 sec`), whole minutes (`3m`, `3 min`), and `mm:ss`.

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

FitSpec is parsed in `engine/src/parser.rs` with `winnow` parser combinators. The parser is intentionally strict while the language is still pre-production: malformed syntax, unknown plan lines, unsupported patch operations, and missing required `template` or `units` directives fail through the engine `Result` path instead of being converted into defaults.

The current surface covers `plan`, `template`, `units`, `schedule`, `starts`, `training_maxes`, `accessories`, simple exercise options, rest overrides, lockfile template entries, and the MVP patch operations. The checked-in 5/3/1 `assistance` block is accepted as a known no-op until the model stores it.

The patch language is still intentionally narrow and line-oriented. Multiline patch operations, richer contextual syntax, stronger diagnostics, and a clearer user-authored patch grammar are expected future FitSpec expansion areas; add those by extending the `winnow` grammar and compatibility tests rather than by special-casing individual examples.

Future agents: add meaningful FitSpec syntax by extending the named `winnow` parsers instead of reintroducing ad hoc regex or block parsing. A grammar generator such as `lalrpop` may be reasonable later if FitSpec becomes expression-heavy, but `winnow` remains the pragmatic path for the current block-oriented language shape.
