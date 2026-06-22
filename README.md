# Knurled

Knurled is the non-iOS authoring layer for a Git-backed training system.

This repository is split into root-level components so the product can grow without mixing concerns:

- `engine/` - Rust deterministic FitSpec core: parsing, validation, rendering, replay, simulation, backtesting primitives.
- `cli/` - Rust `knurled` command-line wrapper around the engine.
- `workbench/` - static/self-hostable editing workbench.
- `examples/` - sample training repositories and fixtures.
- `docs/` - architecture, repo contract, and MVP spec notes.

The authoritative engine is Rust (`knurled-core`) so the same semantics can be compiled for native CLI/local use, WASM for the static workbench, and a Swift adapter for iOS/macOS integration.

## Engine Boundary

Program semantics live in Rust. The workbench can be TypeScript because it is UI and GitHub/file workflow code, but it must call the Rust engine through WASM instead of reimplementing progression rules. iOS/macOS should call the same core through a Swift adapter.

For simple fixed programs such as Starting Strength, Knurled does not need user-authored template files. They are encoded as versioned built-in program presets inside `knurled-core`, then referenced and locked like templates so replay, simulation, and backtesting remain reproducible.

Built-in program presets currently include:

- `gzclp.standard@1.0.0`
- `gzclp.pzero@1.0.0`
- `531.basic@1.0.0`
- `531.beginners@1.0.0`
- `starting-strength.phase1@1.0.0`
- `starting-strength.phase2@1.0.0`
- `starting-strength.phase3@1.0.0`

```bash
cargo test --workspace
cargo run -p knurled-cli -- init examples/gzclp-repo --template gzclp.standard
cargo run -p knurled-cli -- init examples/ss-phase3-repo --template starting-strength.phase3
cargo run -p knurled-cli -- validate examples/gzclp-repo
cargo run -p knurled-cli -- preview examples/gzclp-repo --weeks 4
cargo run -p knurled-cli -- serve --port 4321
```

The MVP command is named `knurled`. It intentionally keeps the FitSpec file model from the spec: `plan.fitspec`, `fitspec.lock`, `patches/*.fitspec`, `logs/**/*.jsonl`, generated `state/current.json`, and generated `build/*.json`.
