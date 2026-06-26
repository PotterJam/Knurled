# Agent Guidance

## Architecture Boundary

Knurled should keep program logic on the engine line. The engine is the pure input/output machine
that owns training semantics, FitSpec parsing/serialization, patch behavior, validation, state
rewrites, generated files, and next-workout rendering.

The iOS app should know as little as practical about program meaning. It should collect user
intent, call typed engine APIs, display returned validation/results/previews, and commit the
engine-reported file changes. Do not add Swift-side FitSpec parsing, program progression rules,
state-shape decisions, patch semantics, or load/rendering logic when an engine API can own it.

## Product Boundary

iOS is the training cockpit:

- Guided quick edits.
- Temporary patches.
- Program switching through built-in templates.
- Next-workout preview and validation display.

CLI/workbench is the lab:

- Simulation and backtesting.
- Program comparison.
- Raw FitSpec inspection/editing.
- Future template authoring.

When adding mobile capability, prefer a small typed engine command plus a guided iOS form over a
larger iOS abstraction. If the app needs to understand a new concept to make an edit, first ask
whether that concept belongs in the engine response or edit input instead.
