# Training Repo Contract

A valid Knurled training repo keeps user-owned source files separate from generated projections.

```text
my-training/
  fitspec.toml
  plan.fitspec
  fitspec.lock
  patches/
  templates/
  logs/
  state/current.json
  build/current.ir.json
  build/next-workout.json
  build/validation.json
  README.md
```

## Canonical Files

`plan.fitspec` defines the plan and template configuration.

`fitspec.lock` freezes template versions, content hashes, and engine compatibility.

`patches/*.fitspec` contains explicit future-plan changes.

`logs/**/*.jsonl` contains canonical training events.

## Generated Files

`state/current.json` is a projection from logs.

`build/current.ir.json` is the compiled plan.

`build/next-workout.json` is the rendered execution contract for the next session.

`build/validation.json` is the validation report.

Generated files are committed for MVP convenience, but they are not truth. `knurled check-generated` reports drift.
