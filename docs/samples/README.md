# ADR 0007 sample shapes

Concrete examples of the [ADR 0007](../adr/0007-logs-as-record-state-as-truth.md)
model. These are illustrations rather than live fixtures.

- [`logs-2026-06.json`](logs-2026-06.json) — one month of session-grain workout
  records plus a program-boundary marker at `logs/<yyyy>/<mm>.json`.
- [`state-current.json`](state-current.json) — `state/current.json` as the
  authored-forward source of truth: the active program plus the program-shaped
  progression cursor per lane.
