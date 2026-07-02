# ADR 0012 — Engine-owned user messages and typed error detail

- Status: Accepted
- Date: 2026-07-02
- Implements: [RFC-0001](../rfc/0001-cockpit-jtbd.md) D3, D9

## Context

The engine owned meaning but not the human rendering of its own concepts: iOS showed raw
validation codes and `lane`/`tier` ids, kept ad-hoc per-code strings, and the FFI error envelope
was a single opaque string, so a malformed plan and an I/O failure looked identical.

## Decision

**The engine ships the human copy for its own primitives.**

- `ValidationMessage` gains `user_message`, stamped at construction from an engine-owned table;
  `validation_code_message(code)` returns the full `{ code, title, body, hint }` explanation.
  Unknown codes get honest generic copy, never an error.
- `RenderedItem.display` gains `label` (clean exercise name from the catalog/plan metadata) and
  `group` (the lift's role in the template's own vocabulary: GZCL T1 → "Main lift", 5/3/1 main →
  "5/3/1 sets"). `RenderedSession` gains `display_description` (the day's lifts at a glance).
  `ProgramAdjustmentSuggestion` gains `user_description`.
- `explain(term)` provides a deliberately short glossary for terms the UI cannot translate away
  (AMRAP, RPE, e1RM, T1/T2/T3, training max, …).
- `BuildOutputs` gains `stale_reason` when validation blocks the next workout, so clients can
  explain the fallback instead of a silent "plan invalid" chip.

**Error detail is additive, not a new envelope.** Every `KnurledError` reports a stable `kind()`
and `retryable()`; the FFI/wasm failure envelope becomes
`{ ok: false, error, error_detail: { kind, retryable } }`. Existing clients that read `error`
keep working. The engine does **not** grow `Transient`/`Permanent` wrapper variants: it has no
network path, so only I/O is marked retryable, and transport errors remain a client concern.

All new fields are `#[serde(default)]` so snapshots and generated files written before this ADR
still decode.

## Consequences

- Clients render `user_message` / `label` / `group` and delete their per-code strings and
  id-formatting heuristics; copy changes ship as engine releases and reach iOS, CLI, and the
  workbench together.
- The envelope change required no lockstep client update (RFC-0001 Risk 3 closed).
- The glossary and message tables live in `engine/src/messages.rs` — one place to review tone.
