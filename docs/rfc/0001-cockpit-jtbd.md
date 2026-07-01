# RFC-0001 — Knurled Cockpit: user jobs, engine UX, and human-readable training

**Status:** Proposed — **Tranche 1 accepted** (D1–D6, D9, D10, D12–D13); **D7, D8, D11 deferred** to [RFC-0002](0002-rpe-autoregulation.md), [RFC-0003](0003-progress-engine.md), [RFC-0004](0004-structural-edit-preserve-compatible.md) respectively (see D0)
**Date:** 2026-07-01
**Scope:** onboarding + local repo, reschedule/deload/AutoReg, progress/trust/errors, program editing + Phase 6B
**Boundary:** Every concept the app needs to *display to a user* becomes an engine response. iOS only collects intent, renders, commits. (AGENTS.md)
**Supersedes:** the "structural edit resets progress" decision recorded in `PHASE6B_REMAINING.md §1` — see D11.

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

### D0 — Scope and tranches

This RFC originally bundled ~15 engine APIs, a breaking FFI change, five ADRs, and 12 PRs as a single "Accepted" unit. That over-commits: three of the decisions are large, independent product bets with their own correctness surface and their own unresolved semantics. They are **split out** so the low-risk, high-leverage core can ship without waiting on them.

**Tranche 1 — accepted, build now.** Decisions whose semantics are settled and whose value is immediate:
- **D3** display labels, **D9** error taxonomy — the load-bearing "speak human" changes; everything else reads better once they land.
- **D1/D2** iCloud-default onboarding — removes the developer-ClientID adoption gate. *(D1 is accepted in principle; the repo-sync mechanism is unresolved — see Risk 1. Do not start D1 implementation until Risk 1 is answered.)*
- **D4/D5** calendar + reschedule, **D6** deload, **D10** guided quick edits, **D12** orphan cleanup, **D13** workbench parity.

**Deferred — split into a dedicated RFC before implementation.** Each is a bet large enough to accept or reject on its own, and each now has its own RFC:
- **D7 (ADR 0004 autoregulation)** → [RFC-0002](0002-rpe-autoregulation.md) — a determinism-model and DSL-grammar change, not a UX tweak.
- **D8 (progress module)** → [RFC-0003](0003-progress-engine.md) — a new analytics surface, independent of the rest.
- **D11 (PreserveCompatible structural edit)** → [RFC-0004](0004-structural-edit-preserve-compatible.md) — reverses an already-recorded decision (`PHASE6B_REMAINING.md §1`) and its core semantics are still an open question (§7 Q4).

The D7/D8/D11 sections below are retained as the seed text for those RFCs but are **not** part of this RFC's accepted scope.

### D1 — iCloud as the default repo container; GitHub is opt-in backup

The current first-run path creates a local repo in `Application Support` and pushes the user toward GitHub OAuth (which requires a developer ClientID). This gates 95% of potential users.

- **Decision:** On first launch, the app creates `my-knurled` in the iCloud container (`NSUbiquitousContainerIdentifier`). The user gets cross-device sync for free via iCloud Drive, with no account setup.
- **GitHub** moves to **Settings → Backup & Sync** and is presented as an optional secondary backup with full Git history.
- The bundled `sample-gzclp` remains available as a "Try a sample workout" entry inside onboarding, but it is a separate read-only repo. "Start my program" always creates a fresh local repo.
- Engine: no behavioural change; `init_training_repo` already works locally. A new FFI `knurled_repo_summary` exposes path, iCloud availability, and last-sync timestamp for the sync-status dot.
- **Unresolved (blocks implementation):** the repo is a live **git working tree**, and iCloud Drive is not a safe transport for one (see Risk 1). "Put `my-knurled` in the iCloud container" is accepted as the *default-location* intent; the *sync mechanism* is not yet chosen. Resolve Risk 1 before building D1.

### D2 — Program picker first; recommendation wizard secondary

The target user is self-coached and often knows they want "GZCLP" or "5/3/1 beginners" by name. A mandatory 3-question wizard (experience / days / goal) is friction for the common case.

- **Decision:** Onboarding shows a **searchable program picker** first. Built-ins are listed with one-line descriptions. A secondary "Not sure? Help me choose" branch invokes a 3-question wizard backed by `recommend_template`.
- **Engine:** new API `recommend_template(profile: ProfileRequest) -> TemplateRecommendation { primary_ref, rationale, alternates }`.
  - `ProfileRequest { experience: Beginner|Intermediate|Advanced, days_per_week: u8, goal: Strength|Hypertrophy|Mixed }`
  - `TemplateRecommendation { primary_ref, rationale: String, alternates: Vec<Alternate> }`
  - The engine owns the matching logic and the rationale copy. iOS only renders.

### D3 — Engine owns display labels

The root cause of the "engine vocabulary everywhere" problem is that the rendered models don't carry human labels for their *own primitives* — even though partial display scaffolding already exists (`RenderedSession.display_name` and `RenderedItem.display: DisplayFields { title, subtitle }` are present in `engine/src/model.rs` today; they are just not populated with template-aware labels, and iOS still renders raw `lane`/`tier`/`sessionId` alongside them).

- **Decision (extend existing fields, don't parallel them):** `RenderedItem.display` (`DisplayFields`) gains `label: String` and `group: Option<String>` so it stops being just `{ title, subtitle }`. `RenderedSession` already has `display_name`; it gains `display_description: Option<String>` and its `display_name` is populated per-template (today it is effectively the session id). `ValidationMessage` gains `user_message: String`. `ProgramAdjustmentSuggestion` gains `user_description: String`.
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
- `suggest_program_adjustments` is extended to return `kind: "deload_week"` when 8+ consecutive training weeks have elapsed without a deload marker. **Tranche-1 constraint:** this trigger is computed from cursor weeks + the last `DeloadMarker` only. It must **not** call `progress_summary` (D8 is deferred); the richer progress-driven suggestions land when D8 does.
- **Interaction with D10 `TemporaryLoadAdjust`:** undefined today — do a `Deload` and a temporary load drop stack, or does the later marker win? See §7 Q8. Resolve before D6/D10 implementation.
- iOS surfaces a proactive card on the Workout tab when the engine suggests a deload: "Time for a deload week? → Plan a lighter week". Manual entry lives in Plan Overview.

### D7 — ADR 0004 accepted: RPE autoregulation  — *Deferred (own RFC)*

> **Deferred per D0 → [RFC-0002](0002-rpe-autoregulation.md).** This is a determinism-model and DSL-grammar change (`DslBasis::E1rm`, new triggers/effects, a versioned RPE table), not a rendering change. It carries its own correctness surface (e1RM math, replay determinism, table versioning) and promotes ADR 0004 on its own merits there. The text below is the seed for that RFC; it is **not** accepted here.

RPE is captured per set and ignored. This is dead data that confuses users.

- **Decision:** ADR 0004 status changes from **Proposed** to **Accepted**.
- Engine additions per the ADR: e1RM calculator (Epley), versioned `rpe_to_percent` table (`engine/data/rpe_table.v1.toml`), `DslBasis::E1rm`, `DslTrigger::OnRpe { op, threshold }`, `DslTrigger::OnE1rmPR`, `DslEffect::SetLoadPctOfE1rm { percent }`.
- New API `next_session_loads(repo) -> Vec<NextLoadReport { lane, prescribed_load, suggested_load, autoreg_recommendation: Option<AutoregProposal> }>`.
- iOS shows AutoReg as per-set suggested-load chips on the live workout screen ("Last RPE 9 @ 95kg → try 97.5kg"), opt-in by tapping. FinishWorkoutView remains a confirmation screen, not a decision screen.

### D8 — Progress engine API  — *Deferred (own RFC)*

> **Deferred per D0 → [RFC-0003](0003-progress-engine.md).** A new analytics module (`progress.rs`, trend/tonnage/plateau computation) is independent of the "speak human" and onboarding work and is designed and accepted on its own there. Retained below as the seed; **not** accepted here. Note: `suggest_program_adjustments`' `deload_week` trigger (D6) must therefore not depend on `progress_summary` in Tranche 1 — see D6.

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

- **Decision:** `PlanEdit::Quick` is a flat struct variant of optional fields (`suggested_days`, `equipment`, `custom_exercise`, `accessory`, `session_exercises`, `rest` — `engine/src/plan_edit.rs`), not an enum with sub-variants. These three are **new top-level `PlanEdit` variants**, consistent with `PlanEdit::Reschedule` (D5) and `PlanEdit::Deload` (D6):
  - `PlanEdit::SwapExercise { from_lane, to_exercise, swap_policy }` — engine rewrites `exercise_options`.
  - `PlanEdit::TemporaryLoadAdjust { lane, percent, until }` — the deferred patch op from `docs/LANGUAGE.md:283-291`; shares the existing equipment rounder with D6 so temporary loads snap to plate pairs identically.
  - `PlanEdit::TemporarySwap { from_lane, to_exercise, until }` — temporary exercise swap for injury recovery.
- iOS adds a "Swap exercise" sheet (catalog picker) and a "Temporary change" sheet with two tabs: Load / Swap. Each submits through the matching top-level `PlanEdit` variant above.
- `PatchPlanEditView` is **deleted from iOS** (confirmed by ProgramEditorView footer and AGENTS.md boundary). Raw patches remain a workbench concern.

### D11 — Program structural edit with PreserveCompatible  — *Deferred (own RFC)*

> **Deferred per D0 → [RFC-0004](0004-structural-edit-preserve-compatible.md).** This **reverses** the decision recorded in `PHASE6B_REMAINING.md §1` ("on a structural edit of an in-progress program, reset progress"). Reversing a locked decision, plus a lane-diffing state-preservation algorithm whose core line is still an open question (§7 Q4), is too much to fold into a UX RFC as one bullet. RFC-0004 explicitly supersedes the Phase 6B decision. Retained below as the seed; **not** accepted here.

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

> **Not all rows are accepted.** Per D0, the following are **deferred** and specified in their own RFCs, listed here only for the full picture: `next_session_loads` and the ADR 0004 types → [RFC-0002](0002-rpe-autoregulation.md); `progress_summary` and `history_feed` → [RFC-0003](0003-progress-engine.md); `ProgramStructuralEdit` and `structural_edit_preview` → [RFC-0004](0004-structural-edit-preserve-compatible.md). Everything else is Tranche 1.

| API | Input | Output | Module |
|---|---|---|---|
| `recommend_template` | `ProfileRequest` | `TemplateRecommendation` | `suggest.rs` |
| `repo_summary` | `repo_path` | `RepoSummary { path, icloud_available, last_sync }` | `repo.rs` |
| `render_next` (updated) | — | `RenderedSession` with `suggested_date`, `display_name`, `display_description` | `core.rs` |
| `render_session` (updated) | — | `RenderedSession` with display fields | `core.rs` |
| `create_initial_state` (updated) | — | `StateProjection` with `calendar` | `core.rs` |
| `PlanEdit::Reschedule` | `from_date`, `to_date`, `write_skip_marker` | `PlanEditOutcome` | `plan_edit.rs` |
| `PlanEdit::Deload` | `percent`, `scope`, `until` | `PlanEditOutcome` | `plan_edit.rs` |
| `PlanEdit::SwapExercise` | `from_lane`, `to_exercise`, `swap_policy` | `PlanEditOutcome` | `plan_edit.rs` |
| `PlanEdit::TemporaryLoadAdjust` | `lane`, `percent`, `until` | `PlanEditOutcome` | `plan_edit.rs` |
| `PlanEdit::TemporarySwap` | `from_lane`, `to_exercise`, `until` | `PlanEditOutcome` | `plan_edit.rs` |
| `next_session_loads` | `repo_path` | `Vec<NextLoadReport>` | `plan_edit.rs` |
| `progress_summary` | `repo_path`, `weeks` | `ProgressSummary` | `progress.rs` |
| `history_feed` | `repo_path`, `since` | `Vec<TrainingRecord>` | `progress.rs` |
| `validation_code_message` | `code` | `ValidationExplanation` | `messages.rs` |
| `explain` | `term` | `Explanation` | `messages.rs` |
| `ProgramStructuralEdit` | `slug`, `new_template_text`, `behavior` | `ProgramMutationOutcome` | `programs.rs` |
| `structural_edit_preview` | `slug`, `new_template_text` | `StructuralEditPreview` | `programs.rs` |
| `suggest_program_adjustments` (updated) | `repo_path` | `Vec<ProgramAdjustmentSuggestion>` with `user_description` | `suggest.rs` |
| `BuildOutputs` (updated) | — | adds `stale_reason: Option<String>` | `model.rs` |
| `RenderedItem.display` (`DisplayFields`, updated) | — | adds `label`, `group` to the existing `{ title, subtitle }` | `model.rs` |
| `RenderedSession` (updated) | — | populates existing `display_name` per-template; adds `display_description` | `model.rs` |
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
- **Swap exercise:** Mid-workout, "Swap" on an exercise card opens the catalog picker → `PlanEdit::SwapExercise` (or `PlanEdit::TemporarySwap` if "Just for today" is toggled).

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

Each step is one PR-sized cluster. The RFC itself lands first as `docs/rfc/0001-cockpit-jtbd.md`. **Workbench parity (D13) is no longer a trailing step** — each new engine API is exposed via `engine-wasm` in the *same* PR that introduces it, so the workbench never sits broken against a new contract (this specifically closes the gap where the D9 error-envelope change would otherwise leave `engine-wasm` broken until the end).

### Tranche 1 — accepted

1. **RFC + ADR updates** — land this RFC; add ADRs 0011 (calendar), 0012 (error taxonomy), 0015 (iCloud local-first). *(ADR 0004 promotion, the progress-module ADR, and the structural-edit ADR move to the deferred RFCs, not here.)*
2. **Display labels + glossary (D3)** — add `display_label`, `display_group`, `display_name`, `display_description`, `user_message`, `user_description` to engine models; implement `explain`; expose via `engine-wasm`; update iOS to use them; remove raw code display.
3. **Trust cluster (D9)** — error taxonomy + FFI JSON envelope; `validation_code_message`; `BuildOutputs.stale_reason`; **update `engine-wasm` to the new error envelope in this same PR**; iOS sync toast + status dot + invalid-plan banner.
4. **iCloud onboarding (D1, D2)** — *gated on Risk 1 being resolved.* `recommend_template`; default-repo creation via the chosen sync mechanism; onboarding sheet; move GitHub to Backup & Sync.
5. **Calendar + reschedule (D4, D5)** — `Schedule.calendar`; `PlanEdit::Reschedule`; `SkipMarker`; iOS reschedule sheet.
6. **Deload (D6)** — `PlanEdit::Deload`; `DeloadMarker`; marker/cursor-based `deload_week` suggestion (no D8 dependency); iOS deload card + form.
7. **Guided quick edits (D10)** — `PlanEdit::SwapExercise`, `::TemporaryLoadAdjust`, `::TemporarySwap` (new top-level variants); iOS sheets; delete `PatchPlanEditView` from iOS.
8. **Orphan cleanup (D12)** — delete `SwitchProgramView`, retire destructive `SwitchProgram` from iOS.

Each Tranche-1 engine PR includes: engine unit tests in `engine/tests/`, the `engine-wasm` binding, and the matching iOS change. Calendar math (D4), deload rounding via the equipment rounder (D6), and reschedule cursor re-pointing (D5) each get explicit test cases.

### Deferred — sequenced inside their own RFCs

- **AutoReg (D7)** → [RFC-0002](0002-rpe-autoregulation.md) — ADR 0004 engine implementation; `next_session_loads`; iOS AutoReg chips.
- **Progress (D8)** → [RFC-0003](0003-progress-engine.md) — `progress` module; `progress_summary`; `history_feed`; Data tab rebuild; progress-driven `suggest_program_adjustments`.
- **Structural edit (D11)** → [RFC-0004](0004-structural-edit-preserve-compatible.md) — `ProgramStructuralEdit`, `structural_edit_preview`; iOS diff preview; supersedes `PHASE6B_REMAINING.md §1`.

---

## 7. Risks and open questions

1. **iCloud Drive is not a safe transport for a live git working tree (blocks D1).**
   The default repo (`my-knurled`) is a git working tree: a `.git` directory whose object store, `index`, `refs`, and `HEAD` must stay mutually consistent. iCloud Drive syncs at the *file* level with last-writer-wins and asynchronous, unordered propagation. Dropping a `.git` tree into the iCloud container invites three concrete failures:
   - **Conflict siblings.** iCloud resolves a two-device edit by keeping both (`index`, `index 2`), which git cannot read — the repo appears corrupt.
   - **Torn multi-file writes.** A commit touches loose objects, `refs`, and `logs` together. iCloud may propagate a new `ref` before the object it points at arrives, yielding a transient (or persistent) "object not found" on the other device.
   - **`.git` exclusion.** iCloud/Time-Machine style sync frequently skips or mangles dot-directories, so the working tree syncs while its history quietly diverges.

   This RFC's original framing ("cross-device sync for free via iCloud Drive") understates this. **D1 is accepted as the default *location/onboarding* intent, not as a sync mechanism.** Before D1 is built, pick one of:
   - **(A) Recommended — iCloud stores state, git is not synced.** Keep the git repo local (`Application Support`), and sync only a *materialized, serialized snapshot* (the state projection + logs, or a single archived bundle) through the iCloud container, re-hydrating a local repo on each device. Git internals never cross iCloud. Loses cross-device *history* but keeps cross-device *state*; full history remains available via the opt-in GitHub backup (D1).
   - **(B) GitHub is the real sync layer; iCloud is local-container only.** iCloud gives on-device durability and Files.app visibility; genuine multi-device sync requires the GitHub opt-in. Simplest, but weakens the "sync for free" pitch.
   - **(C) Sync a single git *bundle* file.** `git bundle` produces one file that iCloud can move atomically; each device unbundles/rebundles. Single-file granularity sidesteps torn writes and conflict siblings, at the cost of bundle merge/rebase logic on the client.

   Until this is decided, the D1 engine work (`repo_summary`, container-path selection) cannot be specified precisely (it must report *which* mechanism is active and its sync state). **Recommendation: (A).** *iCloud-disabled* fallback is unchanged from the original text: fall back to `Application Support` with a one-time "iCloud Drive is off…" notice.
2. **Backward compatibility of `Schedule.calendar`:** Kept `Option<Calendar>`; legacy repos without it continue with `suggested_date = None`. No migration required.
3. **`KnurledError` taxonomy breaks the FFI string contract:** The `error` field becomes a JSON object. This is a breaking change for the iOS FFI and workbench. Mitigation: bump the engine minor version; update both clients in the same PR.
4. **Phase 6B `PreserveCompatible` semantics** *(deferred with D11)* — only same `basis` + same normalized exercise preserves state; a different basis always resets. This is the crux question for the D11 RFC and is **why D11 is deferred rather than accepted** — the "right line" is not yet settled.
5. **Calendar `anchor_date` — RESOLVED (pins D4 API):** anchor to the **Monday of the creation week** regardless of the actual start day. Rationale: `Calendar.day_map` is weekday-indexed, so a Monday anchor keeps `weekday_offset` arithmetic uniform; a Tuesday start simply means week 1's Monday slot is empty. This fixes `Calendar { anchor_date, day_map }` as specified in D4 — no schema change needed, just the documented convention.
6. **ADR 0004 RPE table location** *(deferred with D7)* — `engine/data/rpe_table.v1.toml` (committed, versioned) preferred over an embedded const, so the table can be revised without an engine rebuild and its version is auditable. Confirm in the D7 RFC.
7. **Sample repo graduation:** The sample repo is read-only in onboarding. Should it be deletable after the user creates their own repo, or kept as a permanent demo? *(Tranche 1, non-blocking — default to keeping it as a permanent read-only demo unless it complicates the repo picker.)*
8. **Deload × temporary-load-adjust stacking — RESOLVED (pins D6/D10 behaviour):** operations do **not** stack. A `Deload` and a `TemporaryLoadAdjust` on the same lane are resolved last-marker-wins: applying one supersedes any active adjustment of the other kind on that lane, and its marker records the supersession. This keeps load resolution a pure function of the most recent marker per lane rather than an ordered multiply-chain. Confirm before D6/D10 implementation.

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
