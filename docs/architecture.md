# Knurled Architecture

Knurled is split by ownership boundary, not by UI route.

## Components

- `engine/` owns deterministic semantics as Rust crate `knurled-core`. It turns canonical files into IR, rendered workouts, execution contracts, state projections, simulations, and backtest reports.
- `cli/` owns local filesystem and Git-adjacent workflows as Rust binary `knurled`. It should stay a wrapper around the engine rather than accumulating progression logic.
- `workbench/` owns the static authoring UI. The MVP workbench is self-hostable and should call the Rust engine through a WASM package.
- `examples/` contains complete training repos used for fixtures, demos, and regression checks.
- `docs/` records product and repo contracts.

## Truth Boundary

Canonical:

- `plan.fitspec`
- `fitspec.lock`
- `patches/*.fitspec`
- `logs/**/*.jsonl`

Derived but committed for MVP:

- `state/current.json`
- `build/current.ir.json`
- `build/next-workout.json`
- `build/validation.json`

The engine may write derived files, but it must always be able to regenerate them from canonical files.

## Current Implementation Scope

This Rust implementation covers the executable MVP spine:

- Built-in template registry and lock hashes.
- Minimal FitSpec plan and patch parser.
- GZCLP T1/T2/T3 rendering and reduction.
- 5/3/1 week rendering.
- Execution contracts and execution-input reduction.
- Adjusted-today behavior that does not silently change future state.
- Runtime swap metadata with tracking-only policy support.
- Exercise replacement patches.
- Replay, partial/continuation handling, state adjustment events, simulation, generated-file freshness, and backtest report plumbing.
- Static workbench shell using the supplied Knurled logo.

The next risky areas are richer patch semantics, full correction-event folding, GitHub API write flows in the static workbench, and generated WASM/Swift adapter packages.
