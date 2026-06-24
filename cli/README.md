# Knurled CLI

The CLI is a Rust binary that wraps `knurled-core` and operates on a user-owned FitSpec repo.

```bash
cargo run -p knurled-cli -- init my-training --template gzcl.gzclp
cargo run -p knurled-cli -- validate my-training
cargo run -p knurled-cli -- build my-training
cargo run -p knurled-cli -- preview my-training --weeks 4
cargo run -p knurled-cli -- simulate my-training --weeks 8 --strategy all-pass
cargo run -p knurled-cli -- replay my-training --write-state
cargo run -p knurled-cli -- check-generated my-training
cargo run -p knurled-cli -- backtest my-training
cargo run -p knurled-cli -- import-history my-training hevy.csv --source hevy
cargo run -p knurled-cli -- serve --port 4321
```

The spec calls the early command `fitspec`; this implementation uses the product-facing `knurled` name while preserving the FitSpec file model.

## Historical Import

`import-history` ingests the `history-flat-v1` CSV/TSV staging format documented in
`docs/adr/0005-historical-workout-import.md`. It writes non-progressive `session_imported` events to
`logs/imports/<source>.jsonl`, so past workouts are retained without advancing today's plan cursor.

```bash
cargo run -p knurled-cli -- import-history my-training hevy.csv --source hevy
cargo run -p knurled-cli -- import-history my-training strengthlevels.tsv --source strengthlevels --delimiter tsv
cargo run -p knurled-cli -- import-history my-training history.csv --dry-run
```
