# ADR 0010 — Finalized workouts and local drafts

- Status: Accepted
- Date: 2026-06-29
- Amends: [ADR 0007](0007-logs-as-record-state-as-truth.md)

## Context

Committed `partial` workout records mixed two different concepts: crash-safe in-progress state
and the durable training record. History then needed special status labels and a continuation flow,
even though finished records are directly editable.

## Decision

An in-progress workout exists only as a local iOS draft until the user presses Finish. A local
draft may be continued or discarded. It is never written to repository history.

Pressing Finish always creates an ordinary completed workout record. The record contains exactly
the performed work, including a subset of sets or exercises. The schedule cursor advances once.
Under Advance mode, progression remains exercise-grained: only exercises with all required working
sets completed move their lanes. History records have no `partial` status, continuation action, or
resume metadata.

History is presented as a timeline. Program markers provide program context, session IDs identify
the workout within that program, and every workout is editable through the existing amendment API.

## Consequences

- There is one durable workout concept and one local in-progress concept.
- Leaving the live player can preserve or discard its local draft.
- Finishing early is explicit and terminal, but does not falsely progress unfinished exercises.
- History no longer owns workout continuation behavior.
