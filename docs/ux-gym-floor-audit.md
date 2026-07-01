# UX audit — does the cockpit fit someone actually on the gym floor?

**Date:** 2026-07-01
**Scope:** the iOS app as it exists on `master` today, read against the lens of its primary
persona: a self-coached lifter, phone in one hand, mid-session, 60–180-second rest windows,
frequently interrupted, zero patience for engine vocabulary.
**Relationship to [RFC-0001](rfc/0001-cockpit-jtbd.md):** the RFC already names the strategic
gaps (onboarding, labels, calendar, deload, errors). This audit verifies those claims against
the code and then lists the *foibles the RFC does not cover* — mostly interaction-level
problems inside flows the RFC considers "done".

---

## 1. What already fits the gym floor well

Worth stating so the gaps below read as gaps, not a rewrite request:

- **Crash-safe logging.** Draft autosave + `persistDraftNow()` on background/leave
  (`ActiveWorkoutView.swift`), resume from `WorkoutHomeView`, and a single-workout-in-progress
  invariant. Nothing a dying battery can lose.
- **One-tap set logging** with auto rest timer, `+15/−15/Skip`, a Live Activity, and a
  rest-complete local notification. This is the correct core loop.
- **Out-of-order training is a first-class pattern**: tap any card to focus it (busy squat
  rack case), jump strip pinned at top, add sets/exercises mid-session, per-exercise rest
  override with an optional "save to program".
- **Guard rails in the right places**: a weighted set with no load routes to the load editor
  instead of silently logging empty; AMRAP final sets force a reps entry; finishing is a
  preview-then-commit two-step.

The skeleton is right. The foibles are at the edges — and the edges are exactly where a tired
user meets the app.

---

## 2. RFC-0001 claims, verified against code

All of these check out and need no re-litigation, only sequencing:

| RFC claim | Verified |
|---|---|
| First-run silently lands on the sample repo, GitHub gated on a dev ClientID | `AppModel.bootstrap()` → `loadSampleRepo()`; no onboarding view exists in the target. `GitHubConnectView` renders literal `Secrets.xcconfig` setup instructions to end users when unconfigured. |
| `suggested_date` is always `None` | Hardcoded at `engine/src/core.rs:1329`; the "Suggested: …" header in `WorkoutHomeView` is dead UI today. |
| Raw engine vocabulary in UI | `ValidationPanel` prints raw codes (`message.code`); `EffectResultRow` prints `WorkoutFormat.effectSummary` monospaced engine-speak; `TierBadge` is parsed client-side from lane strings. |
| `repo.loadError` never shown | Set in `AppModel+*.swift`, rendered nowhere (only `ForkProgramLoader`'s unrelated local `loadError` is). |
| Orphaned views | `PatchPlanEditView`, `SwitchProgramView` (`PlanEditViews.swift:509,635`), and additionally `SwapExerciseSheet`, `AdjustTodaySheet`, `SetDetailSheet` are defined but referenced nowhere. D12's list is incomplete — three more corpses than it names. |
| No reschedule/deload path | Only the silent chevron skip in `WorkoutHomeView.skipButton`. |

**Conclusion on the RFC:** Tranche 1 is aimed at the right things. Nothing found here argues
for reordering it. But it is a *strategy* document; the items below are *interaction* bugs it
never looks at, and several are cheap enough to fix ahead of or alongside Tranche 1.

---

## 3. Foibles RFC-0001 does not cover

> **Status (2026-07-01):** fixed on this branch — 3.1 (discard confirm), 3.2 (Reset behind an
> explicit confirm), 3.3 (finish-failure recovery), 3.4 (44pt hit areas), 3.5 (readable
> non-current cards), 3.6 (permission at first rest), 3.7 (footnote copy), 3.8 (sample notice
> on finish, as the pre-D1 stopgap), 3.9 (undo toast for set/exercise deletes), plus the D12
> orphan deletions (`PatchPlanEditView`, `SwitchProgramView`, `SwapExerciseSheet`,
> `AdjustTodaySheet`, `SetDetailSheet`) and the §3.10 wizard-copy nits. Still open from §3.10:
> raw `localizedDescription` error strings (lands with D9) and the Data-tab body-metrics gate
> (lands with D8).

Ordered by (risk of data loss / trust damage) × (how often a real session hits it).

### 3.1 One tap destroys an in-progress workout — no confirmation

`WorkoutHomeView.startBar`, the "different draft" branch: **"Discard & start …"** calls
`draftStore.clear()` directly. Compare `ActiveWorkoutView`, which protects the *same draft*
behind a confirmation dialog ("This deletes your in-progress workout. This can't be undone.").
The most protected object in the app is one un-confirmed tap from deletion on the home screen —
on a button sitting directly under "Continue", the button the user actually wants. A slightly
misjudged thumb after three days away deletes half a workout.

**Fix:** same confirmation dialog as the live view, or (better) soft-delete with an undo toast.
One-view change.

### 3.2 `Reset` is a peer option next to `Advance` on every finish

`FinishWorkoutView` presents `SubmitMode.allCases` as a segmented control on every single
finish. `Reset` **permanently rewrites every baseline from today's performed loads** — the most
destructive data operation a user can perform — and it sits one accidental segment-tap from
`Advance`, guarded only by a footnote. A user who had a bad day and taps around the finish
screen can silently re-baseline their entire program. RFC-0001 D6 even names `SubmitMode::Reset`
misuse as the current deload workaround, but nothing in any tranche de-fangs this control.

**Fix:** `Advance` / `Off-day` as the visible pair; move `Reset` behind a "More…" affordance
with an explicit confirm that names the lanes it will rewrite ("Squat 100→85kg, …").

### 3.3 A failed finish is a dead end

`FinishWorkoutView.Phase.failed` renders the raw engine/validation message with a single
**Close** button. No retry, no "which exercise", no path back to the offending set. The user is
standing in the gym, done, sweaty, with a workout the app refuses to save and no next step. D9
humanizes the *message text*, but the *dead-end shape* of this screen is untouched by the RFC.

**Fix:** keep the sheet dismissible back into the live workout with the failing items
highlighted; offer "Save as off-day" as an escape hatch when progression validation is what
failed.

### 3.4 The most-tapped control in the app is a 28-pt target

`SetRowView`: the log/undo circle button is `28×28` (`frame(width: 28, height: 28)`); the
load/reps `ValueChip`s are caption-sized with ~7pt padding; the RPE chip is 48pt wide. Apple's
floor is 44pt, and the persona is *worse* than the average case — one-handed, shaking from a
top set, chalk on the screen. Every mis-tap on a chip opens an editor sheet the user then has
to cancel, which is exactly the 10-second annoyance that erodes an otherwise great loop.

**Fix:** keep visual size, expand hit areas (`contentShape` padding) to ≥44pt; consider making
the whole trailing third of the row toggle the set.

### 3.5 Non-current exercises are dimmed to 50 % — but resting users read ahead

`LiveExerciseCard` applies `.opacity(0.5)` to every non-current card. The single most common
rest-window activity is *reading the next exercise's prescription* (what weight do I load
next?). At 0.5 opacity, secondary-styled text inside a non-current card is genuinely hard to
read in a bright gym. Dimming also fights the app's own "do it out of order" pattern — the card
you're deciding whether to jump to is the one you can't read.

**Fix:** dim less (0.75–0.85), or dim only *completed* cards and keep pending ones full-strength
with a lighter "current" emphasis (the accent wash already does this job).

### 3.6 Permission prompt interrupts the first workout's first seconds

`WorkoutLiveController.begin()` calls `RestNotifier.requestAuthorization()` — so the iOS
notification dialog appears at the exact moment the user starts their first-ever workout,
before the app has demonstrated why it wants notifications. Denials here are sticky and kill
the rest-complete buzz forever (Settings-app recovery only).

**Fix:** request on the *first rest start* (the moment the value is obvious), with a one-line
pre-frame in the rest bar.

### 3.7 Engine vocabulary on the home screen *before* the first workout

The idle start bar's footnote: *"Finish a workout as advance, off-day, or reset when you submit
it."* Three engine nouns, zero context, shown to someone who hasn't started a workout yet. D3
fixes labels the *engine* emits; this string is hardcoded in `WorkoutHomeView` and won't be
caught by that sweep.

**Fix:** delete it, or replace with something that earns its pixels ("Your progress saves
automatically").

### 3.8 The sample repo is silently writable

You can run and finish real workouts against `Sample · GZCLP`; the only signal is a small
"Sample" chip. A first-run user's first two real training sessions can land in a bundled demo
repo with no sync and no migration path (RFC Q7 "sample graduation" is unresolved). D1 fixes
who lands there, but until it ships, real data is being invited into a throwaway container.

**Fix (pre-D1 stopgap):** on first *finish* in the sample repo, interject: "This is the demo —
want to make it your program?" → create a real local repo and replay the record into it.

### 3.9 Destructive mid-workout deletes have no undo

Extra sets use a hand-rolled swipe-to-delete (`SetRowView.swipeableRow`) that deletes on tap of
the revealed button with no confirm and no undo; removing an added exercise confirms but is
equally unrecoverable, taking its logged sets with it. Everything else in the live loop is
reversible (toggles toggle back); these two are the only silent data-destroyers inside a flow
that promises "your progress is saved automatically."

**Fix:** an "Undo" toast (5s) after either delete; it composes with the draft autosave model
trivially (restore the item into the draft).

### 3.10 Two-line-item nits, listed for completeness

- `skipError` and most catches surface `error.localizedDescription` raw (D9-adjacent but these
  specific call-sites are Swift-side, not engine strings).
- `RotationIndicator` renders raw session ids (`a1`, `b2`) — D3 will feed it labels, but the
  component should truncate/scroll for 5/3/1-style long rotations (`week1.day1 …`).
- Reps entry is a 0–99 wheel (`RepsWheelEditor`); for the dominant case (±1–3 around target) a
  stepper-with-wheel-fallback is one less precision gesture mid-set.
- `ProgramWizardView` is titled "Program wizard" with a "Source: Built-in/Custom" segment and a
  footer inviting users to "fork the built-in… add lanes" — lab vocabulary on a cockpit screen;
  D2/D3 should consume this screen, not just onboarding.
- Plan access hides behind the plan-name toolbar button (a `Label` in `topBarLeading`) — fine
  for power users, invisible to everyone else; worth a visible row once the deload/reschedule
  cards (D5/D6) give the Plan screen a reason to exist for normal users.
- Body-metrics gate on the Data tab: the whole tab is empty until weight+sex are entered; fine
  today, but D8's per-lane trends must not inherit that gate (trend/tonnage need no body
  weight).

---

## 4. Recommended sequencing

1. **Now, independent of the RFC (small PRs):** 3.1 discard confirmation, 3.2 reset de-fang,
   3.4 hit targets, 3.6 permission timing, 3.7 footnote. All are one-view changes with no
   engine dependency.
2. **Fold into Tranche-1 PRs:** 3.3 (finish-failure recovery belongs with D9's error work),
   3.5 (card emphasis belongs with the D3 label re-render), 3.9 (undo toast alongside D10's
   sheet work), extend D12's deletion list with `SwapExerciseSheet`, `AdjustTodaySheet`,
   `SetDetailSheet`.
3. **Track with D1:** 3.8 sample-graduation stopgap; drop it if D1 ships first.
