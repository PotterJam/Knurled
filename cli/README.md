# Knurled CLI

The CLI is a Rust binary that wraps `knurled-core` and operates on a user-owned FitSpec repo.

```bash
cargo run -p knurled-cli -- init my-training --template gzcl.gzclp
cargo run -p knurled-cli -- validate my-training
cargo run -p knurled-cli -- build my-training
cargo run -p knurled-cli -- preview my-training --weeks 4
cargo run -p knurled-cli -- simulate my-training --weeks 8 --strategy all-pass
cargo run -p knurled-cli -- check-generated my-training
cargo run -p knurled-cli -- submit my-training input.json --date 2026-06-25
cargo run -p knurled-cli -- backtest-records my-training
cargo run -p knurled-cli -- serve --port 4321
```

The spec calls the early command `fitspec`; this implementation uses the product-facing `knurled` name while preserving the FitSpec file model.

## Records

Completed sessions are submitted as `ExecutionInput` JSON built against the current rendered workout.
The engine writes lean monthly records under `logs/YYYY/MM.json` and advances `state/current.json`
according to the selected mode.

```bash
cargo run -p knurled-cli -- submit my-training input.json --date 2026-06-25 --mode advance
cargo run -p knurled-cli -- submit my-training input.json --date 2026-06-25 --mode off-day
cargo run -p knurled-cli -- backtest-records my-training
```
