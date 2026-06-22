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
