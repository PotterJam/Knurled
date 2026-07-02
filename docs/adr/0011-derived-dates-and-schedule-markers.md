# ADR 0011 — Derived workout dates and schedule markers in the log

- Status: Accepted
- Date: 2026-07-02
- Implements: [RFC-0001](../rfc/0001-cockpit-jtbd.md) D4, D5, D6, D10
- Extends: [ADR 0007](0007-logs-as-record-state-as-truth.md), [ADR 0010](0010-finalized-workouts-and-local-drafts.md)

## Context

`RenderedSession.suggested_date` was always `None`, and there was no way to say "move Tuesday's
workout to Thursday" or "give me a lighter week". RFC-0001 originally proposed a stored
`Calendar { anchor_date, day_map }`, but a static weekday→session map cannot represent rotation
programs (GZCLP runs four sessions over three training days, so the session landing on Monday
shifts every week), and any date arithmetic keyed on `cursor.week` confuses rotation wraps with
calendar weeks. Separately, generated `build/` outputs are committed (ADR 0006), so rendering
must not depend on "today".

## Decision

**Dates are derived, never stored.** The next workout's `suggested_date` is the first weekday in
the plan's existing `schedule.suggested_days` strictly after the date of the latest dated record;
with no records it stays `None`. The repo layer stamps the date onto rendered output after
session hashing, so a date never changes workout identity.

**Schedule intent is recorded as log markers.** Two new `RecordKind`s join `program_marker`:

- `reschedule` — pins the next workout to the marker's date exactly (`PlanEdit::Reschedule`).
  The cursor and lanes never move; rescheduling changes *when*, not *what* (skip already exists).
- `deload` — records a manual rebaseline (`PlanEdit::Deload`): matching lanes' loads and
  training maxes scale down through the equipment rounder and stall counts reset, exactly like
  the DSL `deload` effect. The engine suggests a deload week after 8 distinct calendar weeks of
  workouts without one.

**Temporary changes are patches; expiry is enforced at the first dated mutation.** Guided quick
edits (`SwapExercise`, `TemporarySwap`, `TemporaryLoadAdjust`) write engine-managed patch files
(one per kind × lane) using the existing `replace-exercise` op and a new `scale-load` op that
overlays prescribed loads at render time without touching progression state. Because rendering is
date-free, a patch's `expires` is enforced when a workout is submitted: the first submit dated
after the expiry deletes the patch file. A deload deletes any active load overlay on the lanes it
rebaselines, so a lane's prescription is always `state × at-most-one overlay`.

## Consequences

- No schema change and no migration: legacy repos simply keep `suggested_date = None` until
  their next record.
- Log files gain marker kinds; clients older than this ADR will fail to parse months containing
  them (accepted pre-1.0, same posture as previous record-format changes).
- A temporary change remains visible (and deletable) as a patch file, keeping the repo the
  single source of truth for "what is currently modifying my program".
- Generated outputs stay deterministic functions of repo files; nothing renders differently on
  a different day of the week.
