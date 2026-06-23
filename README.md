# Knurled

Knurled is a Git-backed training system: a deterministic engine, a CLI, a web workbench, and a native iOS workout player — all driven by the same Rust core.

This repository is split into root-level components so the product can grow without mixing concerns:

- `engine/` - Rust deterministic FitSpec core: parsing, validation, rendering, replay, simulation, backtesting primitives.
- `cli/` - Rust `knurled` command-line wrapper around the engine.
- `workbench/` - static/self-hostable editing workbench.
- `ios/` - native SwiftUI workout player; a thin UI over `knurled-core`, which it embeds on-device as `KnurledCore.xcframework`. See [`ios/README.md`](ios/README.md).
- `examples/` - sample training repositories and fixtures.
- `docs/` - architecture, repo contract, and MVP spec notes.

The authoritative engine is Rust (`knurled-core`) so the same semantics can be compiled for native CLI/local use, WASM for the static workbench, and a Swift adapter for iOS/macOS integration.

## Engine Boundary

Program semantics live in Rust. The workbench can be TypeScript because it is UI and GitHub/file workflow code, but it must call the Rust engine through WASM instead of reimplementing progression rules. The iOS app does exactly this: it embeds `knurled-core` through a thin C-ABI FFI crate (`ios/Engine/knurled-ios-ffi`) and renders engine output — progression, effects, rest prescriptions, validation — without reimplementing any training logic in Swift.

For simple fixed programs such as Starting Strength, Knurled does not need user-authored template files. They are encoded as versioned built-in program presets inside `knurled-core`, then referenced and locked like templates so replay, simulation, and backtesting remain reproducible.

Built-in program presets currently include:

- `gzcl.gzclp@1.0.0`
- `gzcl.p-zero@1.0.0`
- `531.basic@1.0.0`
- `531.beginners@1.0.0`
- `starting-strength.phase1@1.0.0`
- `starting-strength.phase2@1.0.0`
- `starting-strength.phase3@1.0.0`

```bash
cargo test --workspace
cargo run -p knurled-cli -- init examples/gzclp-repo --template gzcl.gzclp
cargo run -p knurled-cli -- init examples/ss-phase3-repo --template starting-strength.phase3
cargo run -p knurled-cli -- validate examples/gzclp-repo
cargo run -p knurled-cli -- preview examples/gzclp-repo --weeks 4
cargo run -p knurled-cli -- serve --port 4321
```

The MVP command is named `knurled`. It intentionally keeps the FitSpec file model from the spec: `plan.fitspec`, `fitspec.lock`, `patches/*.fitspec`, `logs/**/*.jsonl`, generated `state/current.json`, and generated `build/*.json`.
