# RFC-0001 — Knurled Cockpit: user jobs, engine UX, and human-readable training

**Status:** Accepted (pending implementation)
**Date:** 2026-07-01
**Scope:** onboarding + local repo, reschedule/deload/AutoReg, progress/trust/errors, program editing + Phase 6B
**Boundary:** Every concept the app needs to *display to a user* becomes an engine response. iOS only collects intent, renders, commits. (AGENTS.md)

---

## 1. Problem statement

Knurled is architecturally excellent — a deterministic Rust engine, a disciplined SwiftUI client, and a crash-safe workout logging flow that rivals commercial apps. But from a lifter's point of view, the app speaks engine, not human:

- A first-run user lands on a sample GZCLP "Day A" with no explanation of T1/T2/T3, and cannot use their own program without a GitHub developer account.
- The schedule is a dumb rotation pointer with no calendar. Miss Tuesday and the only recovery is "skip" twice, losing your place silently.
- There is no "I'm tired, deload 10%" action. Intermediate lifters must become program authors to do basic periodization.
- RPE is captured per set and then ignored (ADR 0004, *Proposed* since 2022).
- Progress is a single vanity chart. The engine knows every state transition but offers no trend, plateau, or volume insight.
- Validation surfaces raw `E2043` codes. Adjustment suggestions show `lane: "squat.t1"`. The UI is a vocabulary test.
- Raw patch editing is orphaned and unusable on mobile, yet common user needs (temporary exercise swap, temporary load drop) have no guided path.

The meta problem: **the engine owns semantics but does not own human rendering.** iOS shows machine IDs because the engine has never produced user-facing labels for its own primitives.

This RFC fixes that by adding a *human layer* to the engine — display labels, calendar, deload, AutoReg, progress analytics, and structured error messages — while keeping the architecture boundary intact.

---

## 2. Principles

P1. **The engine owns meaning *and* the human-readable rendering of its own concepts.**
P2. **iOS is the training cockpit, not the lab.** Raw FitSpec, raw patches, and raw state editing stay in the workbench/CLI.
P3. **Local-first, iCloud-backed.** The default repo lives in the app's iCloud container. GitHub is an opt-in power-user backup.
P4. **User intent is structured, never raw text.** Every edit flows through a typed engine command.
P5. **The common case is one tap; the advanced case is a short form.**

---

## 3. Decisions

### D1 — iCloud as the default repo container; GitHub is opt-in backup

The current first-run path creates a local repo in `Application Support` and pushes the user toward GitHub OAuth (which requires a developer ClientID). This gates 95% of potential users.

- **Decision:** On first launch, the app creates `my-knurled` in the iCloud container (`NSUbiquitousContainerIdentifier`). The user gets cross-device sync for free via iCloud Drive, with no account setup.
- **GitHub** moves to **Settings → Backup & Sync** and is presented as an optional secondary backup with full Git history.
- The bundled `sample-gzclp` remains available as a "Try a sample workout" entry inside onboarding, but it is a separate read-only repo. "Start my program" always creates a fresh local repo.
- Engine: no behavioural change; `init_training_repo` already works locally. A new FFI `knurled_repo_summary` exposes path, iCloud availability, and last-sync timestamp for the sync-status dot.

### D2 — Program picker first; recommendation wizard secondary

The target user is self-coached and often knows they want "GZCLP" or "5/3/1 beginners" by name. A mandatory 3-question wizard (experience / days / goal) is friction for the common case.

- **Decision:** Onboarding shows a **searchable program picker** first. Built-ins are listed with one-line descriptions. A secondary "Not sure? Help me choose" branch invokes a 3-question wizard backed by `recommend_template`.
- **Engine:** new API `recommend_template(profile: ProfileRequest) -> TemplateRecommendation { primary_ref, rationale, alternates }`.
  - `ProfileRequest { experience: Beginner|Intermediate|Advanced, days_per_week: u8, goal: Strength|Hypertrophy|Mixed }`
  - `TemplateRecommendation { primary_ref, rationale: String, alternates: Vec<Alternate> }`
  - The engine owns the matching logic and the rationale copy. iOS only renders.

### D3 — Engine owns display labels

The root cause of the "engine vocabulary everywhere" problem is that `RenderedItem` and `RenderedSession` carry only machine IDs.

- **Decision:** `RenderedItem` gains `display_label: String` and `display_group: Option<String>`. `RenderedSession` gains `display_name: String` and `display_description: Option<String>`. `ValidationMessage` gains `user_message: String`. `ProgramAdjustmentSuggestion` gains `user_description: String`.
- The engine computes these per template. For GZCLP: `progression_lane: "squat.t1"` → `display_label: "Squat"`, `display_group: Some("Main lift")`. For 5/3/1: `session_id: "week1.day1"` → `display_name: "Week 1, Day 1 — Press"`, `display_description: Some("3×5 at 65% TM")`.
- iOS drops all raw `lane` / `tier` / `sessionId` display and uses engine-provided labels. One "About this program" screen (linked from Plan Overview) explains template-specific vocabulary once; no scattered glossary chips.
- **Engine:** new API `explain(term: &str) -> Explanation { title, body, examples }` for truly untranslatable terms (AMRAP, e1RM, deload). Used sparingly.

### D4 — Calendar model lives in the engine

`Schedule.rotation` is a `Vec<String>` with no anchor date. `RenderedSession.suggested_date` is always `None`. A missed day breaks the rotation silently.

- **Decision:** `Schedule` gains `calendar: Option<Calendar>`, where `Calendar { anchor_date: NaiveDate, day_map: Map<u8, String> }` maps weekday index → session_id. `anchor_date` is set to the first Monday of the current week at repo creation.
- `render_next` computes `suggested_date` from `anchor_date + week_offset + weekday_offset` using `state.cursor.week`.
- Legacy repos without `calendar` keep current behaviour (date `None`). No migration.
- **Engine:** `create_initial_state` writes `calendar` for new repos. `render_next` and `render_session` populate `suggested_date`.

### D5 — Reschedule is a PlanEdit

There is no "move Tuesday's workout to Thursday" operation.

- **Decision:** New `PlanEdit::Reschedule { from_date: NaiveDate, to_date: NaiveDate, write_skip_marker: bool }`.
- The engine re-points the cursor. When `write_skip_marker = true`, a `RecordKind::SkipMarker` is written to logs with the original date (ADR 0010-compatible — no in-progress record, just history).
- iOS surfaces it from the Workout tab via a "Can't make it? Reschedule" row that opens a date sheet. No persistent calendar strip on the primary screen.

### D6 — Deload API exists

Deloading currently requires hand-typing lighter loads for every exercise, or authoring a patch, or using `SubmitMode::Reset` (which permanently changes the baseline).

- **Decision:** New `PlanEdit::Deload { percent: f32, scope: DeloadScope::{AllLanes, NamedLanes(Vec<String>)}, until: Option<NaiveDate> }`.
- The engine rewrites each affected lane's `load` (or `training_max` when `basis = training_max`) by `percent`, snapping to plate pairs via the existing equipment rounder. A `RecordKind::DeloadMarker` is written.
- `suggest_program_adjustments` is extended to return `kind: "deload_week"` when 8+ consecutive training weeks have elapsed without a deload marker.
- iOS surfaces a proactive card on the Workout tab when the engine suggests a deload: "Time for a deload week? → Plan a lighter week". Manual entry lives in Plan Overview.

### D7 — ADR 0004 accepted: RPE autoregulation

RPE is captured per set and ignored. This is dead data that confuses users.

- **Decision:** ADR 0004 status changes from **Proposed** to **Accepted**.
- Engine additions per the ADR: e1RM calculator (Epley), versioned `rpe_to_percent` table (`engine/data/rpe_table.v1.toml`), `DslBasis::E1rm`, `DslTrigger::OnRpe { op, threshold }`, `DslTrigger::OnE1rmPR`, `DslEffect::SetLoadPctOfE1rm { percent }`.
- New API `next_session_loads(repo) -> Vec<NextLoadReport { lane, prescribed_load, suggested_load, autoreg_recommendation: Option<AutoregProposal> }>`.
- iOS shows AutoReg as per-set suggested-load chips on the live workout screen ("Last RPE 9 @ 95kg → try 97.5kg"), opt-in by tapping. FinishWorkoutView remains a confirmation screen, not a decision screen.

### D8 — Progress engine API

The Data tab is a single Epley chart. The engine knows every state transition but offers no analytics.

- **Decision:** New module `engine/src/progress.rs` with API `progress_summary(repo, weeks: u32) -> ProgressSummary`.
  - `ProgressSummary { per_lane: Vec<LaneProgress { lane, display_label, e1rm_trend, tonnage, prs, plateau_weeks, suggested_action }> }`
  - `history_feed(repo, since: Option<NaiveDate>) -> Vec<TrainingRecord>` for time-bounded queries.
- `suggest_program_adjustments` reuses `progress_summary` internally.
- iOS replaces the single chart with per-lane trend cards: 1RM line, tonnage bars, plateau count, and an action suggestion ("continue", "deload", "switch program").
- After an amend-record save, iOS flashes which lanes recomputed: "Squat updated to 102.5kg" or "No progression changes — this was not the latest set."

### D9 — Error taxonomy and engine-owned messages

`EngineError.engine(String)` is the only granularity. Network failures and malformed plans look identical. `repo.loadError` is never shown.

- **Decision:** `KnurledError` gains typed variants: `Transient { kind, retryable, source }` and `Permanent { kind, context }`.
- The FFI error envelope becomes a JSON object: `{ kind, transient, retryable, message }`. Swift decodes into a typed `EngineError` enum.
- New API `validation_code_message(code: &str) -> ValidationExplanation { title, body, hint }`. iOS drops all ad-hoc per-code strings.
- `BuildOutputs` gains `stale_reason: Option<String>` when `next_workout` falls back to last-valid due to invalid build. iOS renders a yellow banner instead of the silent "Plan invalid" chip.
- iOS adds a transient sync toast + status dot in the header. No persistent banner on the Workout tab (the default user has no GitHub).

### D10 — Guided quick edits: swap and temporary changes

Raw patch editing is orphaned and unusable. Common needs (temporary exercise swap, temporary load drop) have no mobile path.

- **Decision:** Extend `PlanEdit::Quick` with:
  - `SwapExercise { from_lane, to_exercise, swap_policy }` — engine rewrites `exercise_options`.
  - `TemporaryLoadAdjust { lane, percent, until }` — the deferred patch op from `docs/LANGUAGE.md:283-291`.
  - `TemporarySwap { from_lane, to_exercise, until }` — temporary exercise swap for injury recovery.
- iOS adds a "Swap exercise" sheet (catalog picker) and a "Temporary change" sheet with two tabs: Load / Swap. Both submit through `PlanEdit::Quick`.
- `PatchPlanEditView` is **deleted from iOS** (confirmed by ProgramEditorView footer and AGENTS.md boundary). Raw patches remain a workbench concern.

### D11 — Program structural edit with PreserveCompatible

Phase 6B #1 is deferred because `PlanEdit` has no template-rewrite operation, and the locked decision is "structural edit resets progress."

- **Decision:** New engine operation `ProgramStructuralEdit { slug, new_template_text, behavior: ResetProgress | PreserveCompatible }`.
- When `PreserveCompatible`, the engine diffs new vs old lanes. Lanes that keep the same `basis` + same normalized exercise carry over their `LaneState`; only new/removed lanes reset.
- New FFI `knurled_structural_edit_preview` returns `StructuralEditPreview { preserved: Vec<String>, reset: Vec<String>, validation }`.
- iOS shows the diff before saving: "These lanes keep their progress: Squat, Bench… These reset: New backoff, Removed accessory." User confirms.

### D12 — Orphaned code removal

- `SwitchProgramView` (`PlanEditViews.swift:635`) is deleted. The bank path (add program → activate) is canonical. `PlanEdit::SwitchProgram` stays in the engine for the workbench but is not surfaced in iOS.
- `PatchPlanEditView` is deleted from iOS per D10.

### D13 — Workbench parity

New engine APIs (`recommend_template`, `next_session_loads`, `progress_summary`, `history_feed`, `validation_code_message`, `explain`, `structural_edit_preview`) are exposed via `engine-wasm` so the lab gets the same analytics and human-readable output as the cockpit.

---

## 4. Engine API additions

| API | Input | Output | Module |
|---|---|---|---|
| `recommend_template` | `ProfileRequest` | `TemplateRecommendation` | `suggest.rs` |
| `repo_summary` | `repo_path` | `RepoSummary { path, icloud_available, last_sync }` | `repo.rs` |
| `render_next` (updated) | — | `RenderedSession` with `suggested_date`, `display_name`, `display_description` | `core.rs` |
| `render_session` (updated) | — | `RenderedSession` with display fields | `core.rs` |
| `create_initial_state` (updated) | — | `StateProjection` with `calendar` | `core.rs` |
| `PlanEdit::Reschedule` | `from_date`, `to_date`, `write_skip_marker` | `PlanEditOutcome` | `plan_edit.rs` |
| `PlanEdit::Deload` | `percent`, `scope`, `until` | `PlanEditOutcome` | `plan_edit.rs` |
| `PlanEdit::Quick::SwapExercise` | `from_lane`, `to_exercise`, `swap_policy` | `PlanEditOutcome` | `plan_edit.rs` |
| `PlanEdit::Quick::TemporaryLoadAdjust` | `lane`, `percent`, `until` | `PlanEditOutcome` | `plan_edit.rs` |
| `PlanEdit::Quick::TemporarySwap` | `from_lane`, `to_exercise`, `until` | `PlanEditOutcome` | `plan_edit.rs` |
| `next_session_loads` | `repo_path` | `Vec<NextLoadReport>` | `plan_edit.rs` |
| `progress_summary` | `repo_path`, `weeks` | `ProgressSummary` | `progress.rs` |
| `history_feed` | `repo_path`, `since` | `Vec<TrainingRecord>` | `progress.rs` |
| `validation_code_message` | `code` | `ValidationExplanation` | `messages.rs` |
| `explain` | `term` | `Explanation` | `messages.rs` |
| `ProgramStructuralEdit` | `slug`, `new_template_text`, `behavior` | `ProgramMutationOutcome` | `programs.rs` |
| `structural_edit_preview` | `slug`, `new_template_text` | `StructuralEditPreview` | `programs.rs` |
| `suggest_program_adjustments` (updated) | `repo_path` | `Vec<ProgramAdjustmentSuggestion>` with `user_description` | `suggest.rs` |
| `BuildOutputs` (updated) | — | adds `stale_reason: Option<String>` | `model.rs` |
| `RenderedItem` (updated) | — | adds `display_label`, `display_group` | `model.rs` |
| `RenderedSession` (updated) | — | adds `display_name`, `display_description` | `model.rs` |
| `ValidationMessage` (updated) | — | adds `user_message` | `model.rs` |
| `KnurledError` (updated) | — | adds `Transient`, `Permanent` | `error.rs` |
| ADR 0004 types | — | `DslBasis::E1rm`, `OnRpe`, `OnE1rmPR`, `SetLoadPctOfE1rm` | `dsl.rs`, `core.rs` |

---

## 5. iOS UX specification

### 5.1 Onboarding

**Screen:** `OnboardingSheet` (replaces silent sample fallback)
- **Primary:** Searchable list of built-in templates (name + description). Tapping a template opens `InitialTrainingNumbersEditor` + units + days, then "Start my program".
- **Secondary:** "Not sure? Help me choose" → 3-question wizard (experience / days / goal) → `recommend_template` → single result with rationale + alternates.
- **Tertiary:** "Try a sample workout" → loads sample-gzclp as read-only preview (no repo creation).
- On "Start my program", the app creates `my-knurled` in the iCloud container via `init_training_repo`, applies initial numbers, and sets `phase = .ready`.

### 5.2 Workout tab

- **Header:** `display_name` and `suggested_date` from engine (e.g. "Day 1 — Press · Thu 2 Jul"). Prev/next chevrons for rotation.
- **Deload card:** When `suggest_program_adjustments` returns `deload_week`, show a dismissible card: "Time for a deload week? → Plan a lighter week". Tapping opens Plan Overview → deload preview.
- **Reschedule row:** Below the start button, a secondary "Can't make it? Reschedule" row opens a date picker sheet. Submit → `PlanEdit::Reschedule`.
- **Invalid-plan banner:** When `BuildOutputs.stale_reason` is present, show a yellow banner: "Your last edit stopped us from building the next workout. We're showing the previous one." Tapping opens Plan Overview → validation panel.
- **Sync status:** A small dot in the toolbar (green = synced, amber = pending push, red = error). Tapping opens Settings → Backup & Sync. No persistent banner.

### 5.3 Live workout

- **AutoReg chips:** Per set, when `autoreg_recommendation` is present, show a subtle chip: "Based on RPE 9 → try 97.5kg". Tapping applies the suggestion to that set's load. No UI on FinishWorkoutView.
- **Swap exercise:** Mid-workout, "Swap" on an exercise card opens the catalog picker → `PlanEdit::Quick::SwapExercise` (or `TemporarySwap` if "Just for today" is toggled).

### 5.4 Plan Overview

- **About this program:** Linked row explaining the active template's vocabulary (T1/T2/T3, rotation names, AMRAP) via `explain` and engine-provided labels.
- **Deload row:** "Plan a deload week" → percent slider (default 10%), scope (all / specific lanes), preview → `PlanEdit::Deload`.
- **Temporary change row:** "Temporary changes" → Load / Swap tabs.

### 5.5 Data tab

- **Per-lane trend cards:** One card per core lane. Line chart of e1RM over time. Tonnage bar for the last 4 weeks. Plateau count. Suggested action chip.
- **History feed:** Uses `history_feed` with time bounding instead of loading the full log.

### 5.6 Program structural edit

- **Path:** Program Bank → Edit (custom program) → structural editor.
- **Save flow:** After editing, call `structural_edit_preview`. Show preserved/reset lanes. User confirms. `PreserveCompatible` is default; `ResetProgress` is an explicit override toggle.

---

## 6. Sequenced implementation

Each step is one PR-sized cluster. The RFC itself lands first as `docs/rfc/0001-cockpit-jtbd.md`.

1. **RFC + ADR updates** — land this RFC; update ADR 0004 to Accepted; add ADRs 0011 (calendar), 0012 (error taxonomy), 0013 (progress module), 0014 (program structural edit), 0015 (iCloud local-first).
2. **Display labels + glossary (D3)** — add `display_label`, `display_group`, `display_name`, `display_description`, `user_message`, `user_description` to engine models; implement `explain`; update iOS to use them; remove raw code display.
3. **Trust cluster (D9)** — error taxonomy + FFI JSON envelope; `validation_code_message`; `BuildOutputs.stale_reason`; iOS sync toast + status dot + invalid-plan banner.
4. **iCloud onboarding (D1, D2)** — `recommend_template`; iCloud container repo creation; onboarding sheet; move GitHub to Backup & Sync.
5. **Calendar + reschedule (D4, D5)** — `Schedule.calendar`; `PlanEdit::Reschedule`; `SkipMarker`; iOS reschedule sheet.
6. **Deload (D6)** — `PlanEdit::Deload`; `DeloadMarker`; extended `suggest_program_adjustments`; iOS deload card + form.
7. **AutoReg (D7)** — ADR 0004 engine implementation; `next_session_loads`; iOS AutoReg chips.
8. **Progress (D8)** — `progress` module; `progress_summary`; `history_feed`; Data tab rebuild.
9. **Guided quick edits (D10)** — `Quick::SwapExercise`, `::TemporaryLoadAdjust`, `::TemporarySwap`; iOS sheets; delete `PatchPlanEditView` from iOS.
10. **Structural edit (D11)** — `ProgramStructuralEdit`, `structural_edit_preview`; iOS diff preview.
11. **Orphan cleanup (D12)** — delete `SwitchProgramView`, retire destructive `SwitchProgram` from iOS.
12. **Workbench parity (D13)** — port new APIs to `engine-wasm`.

---

## 7. Risks and open questions

1. **iCloud container availability:** If the user has iCloud Drive disabled, the app falls back to `Application Support` with a one-time notice: "iCloud Drive is off. Your data is only on this device. Turn on iCloud Drive in Settings to sync."
2. **Backward compatibility of `Schedule.calendar`:** Kept `Option<Calendar>`; legacy repos without it continue with `suggested_date = None`. No migration required.
3. **`KnurledError` taxonomy breaks the FFI string contract:** The `error` field becomes a JSON object. This is a breaking change for the iOS FFI and workbench. Mitigation: bump the engine minor version; update both clients in the same PR.
4. **Phase 6B `PreserveCompatible` semantics:** Only same `basis` + same normalized exercise preserves state. Adding a lane with a different basis always resets. Is this the right line?
5. **Calendar anchor_date:** Set to the Monday of the current week at repo creation. If a user starts on Tuesday, Tuesday becomes week 1 day 2. Acceptable, or should we always anchor to Monday regardless of creation day?
6. **ADR 0004 RPE table location:** `engine/data/rpe_table.v1.toml` (committed, versioned) vs. embedded Rust const. Preference?
7. **Sample repo graduation:** The sample repo is read-only in onboarding. Should it be deletable after the user creates their own repo, or kept as a permanent demo?

---

## 8. Appendix: engine vocabulary → human labels (examples)

These are illustrative. The engine computes them per template, so iOS never hardcodes them.

| Engine primitive | GZCLP label | 5/3/1 label | Starting Strength label |
|---|---|---|---|
| `lane: "squat.t1"` | "Squat — Main lift" | "Squat — 5/3/1 set" | "Squat — Work set" |
| `lane: "bench.t2"` | "Bench — Supplemental" | "Bench — BBB set" | — |
| `session_id: "a1"` | "Day A1" | "Week 1, Day 1" | "Workout A" |
| `stage: "5x5"` | "5 sets of 5" | "3 sets of 5" | "3 sets of 5" |
| `progression_rule: "stages"` | "Progress through stages" | "Wave progression" | "Linear progression" |
| `E2043` | "Your rest policy has an invalid number. Check the rest stepper in Quick Edit." | (same, template-agnostic) | (same) |

---

*End of RFC-0001*
