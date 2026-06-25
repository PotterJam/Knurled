# ADR 0007 sample shapes

Concrete examples of the [ADR 0007](../adr/0007-logs-as-record-state-as-truth.md)
model. These are illustrations, not live fixtures — the `examples/*-repo`
directories remain on the current engine shapes until the cutover lands.

- [`logs-2026-06.json`](logs-2026-06.json) — one month of the lean record at
  `logs/<yyyy>/<mm>.json`: a program-boundary marker, normal workout days, and
  an off-day (recorded with a note; the engine leaves the program's targets
  untouched, so the next squat is still computed from `85kg`, not `70kg`).
- [`state-current.json`](state-current.json) — `state/current.json` as the
  authored-forward source of truth: the active program plus the program-shaped
  progression cursor per lane.
