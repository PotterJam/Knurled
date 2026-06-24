# Workbench Improvement Plan

A plan to bring `workbench/` in line with the functionality the rest of Knurled
already has. The guiding constraint comes straight from the README and
[`architecture.md`](architecture.md):

> The workbench can be TypeScript because it is UI and GitHub/file workflow
> code, but it **must call the Rust engine through WASM instead of
> reimplementing progression rules**.

The current workbench violates that constraint. Everything below is organised
around fixing it.

---

## 1. Where the workbench is today

`workbench/` is three static files (`index.html`, `styles.css`, `app.js`, ~650
lines total) served by the CLI's `serve` command. It is a **mock**: `app.js`
hand-rolls a regex parser and fabricates progression/validation/simulation
output in JavaScript. It never touches `knurled-core`.

Concrete problems this causes:

- **Engine logic is duplicated and wrong.** `validate()`, `renderNext()`,
  `renderSimulation()`, and `scale()` reimplement training rules in JS. The
  numbers diverge from the engine: the mock renders Bench T2 as `0.8 × 55kg =
  44kg`, but the engine's real `next-workout.json` for the same plan shows
  `45kg`. The simulation is a straight `squatStart + week * 7.5` line, which is
  not how GZCLP stage progression/resets actually behave.
- **The sample plan would not parse.** `app.js` ships
  `template "gzcl.gzclp@1.0.0"`, `rotation A1, B1, A2, B2` (commas), and
  `starts { squat 80kg }` (unquoted). The real parser (see
  `examples/gzclp-repo/plan.fitspec` and [`LANGUAGE.md`](LANGUAGE.md)) expects
  `template "gzcl.gzclp" version="1.0.0"`, space-separated rotation tokens, and
  quoted loads (`squat "80kg"`). The workbench teaches syntax the engine
  rejects.
- **Only GZCLP is modelled.** The validator special-cases `gzcl.` and the four
  main lifts. The other six built-in templates (`gzcl.p-zero`, `531.basic`,
  `531.beginners`, `starting-strength.phase1/2/3`) are effectively unsupported,
  including 5/3/1's `training_maxes` (which the mock ignores entirely).
- **Most of the product surface is missing.** Patches, rest prescriptions,
  exercise options/runtime swaps, execution contracts, effect previews, replay
  and state, backtests, generated-file freshness, and history import all exist
  in the engine/CLI but have no real workbench representation. The nav rail has
  a "Patches" button that renders a fake git blurb.
- **No repo model.** The workbench is a single `<textarea>` backed by
  `localStorage`. There is no concept of a repo (plan + lock + patches + logs +
  generated build files), no file tree, and no GitHub load/commit flow — even
  though `architecture.md` lists "GitHub API write flows in the static
  workbench" as a known next step.
- **Brittle UI wiring.** Nav items map to output tabs through a nested ternary
  (`app.js:78`), and the editor panel is always visible regardless of which
  nav section is active, so "Overview" / "Plan" / "Patches" / "Simulation" /
  "Git" don't correspond to distinct screens.

### What is actually fine and worth keeping

- The visual shell (rail + topbar + status strip + two-panel workspace) and the
  styling in `styles.css`.
- `localStorage` draft persistence and the "reset to sample" affordance.
- The CLI `serve` static file server — it just needs to also serve the WASM
  package (`.wasm` content-type is missing from `content_type()` in
  `cli/src/main.rs`).

---

## 2. Capability gap (engine/CLI → workbench)

| Engine / CLI capability | Surface | Workbench today |
|---|---|---|
| `compile_plan` / `parse_plan` | parser | Regex mock, wrong syntax |
| `validate_repo` / `validate_compiled` | `validate` | JS heuristic, GZCLP-only |
| `render_next` (prescription, rest, execution contract, effect preview) | `preview` | Hardcoded A1 card, fake numbers |
| `simulate` (strategies, per-session effects, final state) | `simulate` | Linear fake projection |
| `replay_events` / state projection | `replay` | None |
| `backtest_repo` | `backtest` | None |
| `check_generated_repo` (freshness) | `check-generated` | Fake "git" text |
| `import_history_repo` (Hevy/CSV/TSV) | `import-history` | None |
| Built-in template registry (7 templates) | `init --template` | GZCLP only |
| `training_maxes` (5/3/1) | parser/model | Ignored |
| `rest` prescription | parser/model | None |
| `exercise_options` / runtime swaps | parser/model | None |
| Patches (`patches/*.fitspec`) | parser | Fake nav button |
| Lockfile (`fitspec.lock`) pinning | parser/templates | None |

---

## 3. Plan of work

Phases are ordered so each one is shippable and the engine boundary is restored
as early as possible.

### Phase 0 — WASM engine package (foundation)

Nothing else is correct until the workbench runs the real engine.

- Add a WASM binding layer. Two options:
  1. **`wasm-bindgen` + `wasm-pack`** in `knurled-core` directly (the crate
     already declares `crate-type = ["rlib", "cdylib"]`), gated behind a
     `wasm` feature so native CLI/iOS builds are unaffected.
  2. A thin `engine/knurled-wasm` wrapper crate (mirrors the existing
     `ios/Engine/knurled-ios-ffi` C-ABI pattern) that re-exports the
     high-level functions as JSON-in/JSON-out.

  Recommended: the wrapper crate, to keep `knurled-core`'s dependency graph
  clean and match the established FFI-adapter convention.
- Export JSON-boundary functions mirroring the CLI verbs: `compile`,
  `validate`, `preview(weeks)`, `simulate(weeks, strategy)`, `replay`,
  `render_next`, `backtest`, `import_history`, plus `list_templates`. Inputs are
  the canonical file contents (plan text, lock text, patch files, logs); outputs
  are the same serde JSON the CLI prints.
- Add a build script (`workbench/scripts/build-wasm.sh`) analogous to
  `ios/scripts/build-xcframework.sh`, emitting the `pkg/` into `workbench/` and
  gitignoring the generated artifact (document the regen step like the iOS
  README does).
- Teach `cli/src/main.rs` `serve` to send `application/wasm` for `.wasm`.
- CI / test: a smoke test that the WASM package loads and that
  `validate(sample)` matches a golden engine result.

### Phase 1 — Replace the mock with real engine calls

- Delete the JS parser/validator/simulator (`parsePlan`, `validate`, `scale`,
  the fake `renderSimulation`, etc.). Route Validate / Preview / Simulate
  through the WASM exports.
- Render real engine output:
  - **Validation** from `validation_report` (status, the `checked` map, errors
    and warnings with their codes).
  - **Next workout** from `rendered_session`: per-item prescription (sets ×
    reps × load, AMRAP flags), rest, the pass/fail/adjusted-today **effect
    preview**, and the execution contract summary.
  - **Simulation** from `simulation_report`: per-session effects and the final
    state projection, honouring the `strategy` argument (`all-pass`, etc.).
- Fix the bundled sample plan to valid FitSpec syntax (quoted loads,
  `version="…"`, space-separated rotation) so the editor teaches correct syntax.
- Surface parser errors with line/column where the engine provides them, so the
  editor becomes a real linter rather than a guess.

### Phase 2 — Repo model instead of a single textarea

- Move from "one plan string" to an in-memory repo: `plan.fitspec`,
  `fitspec.lock`, `patches/*.fitspec`, `logs/**/*.jsonl`, and generated
  `state/` + `build/` files.
- Add a lightweight file tree / file switcher in the rail, and make the nav
  sections (Plan / Patches / Simulation / Git) select genuine views rather than
  driving a single output panel through a ternary.
- A **patches** editor: create/edit `patches/*.fitspec`, see them folded into
  compile/validate/preview via the engine.
- Show the lockfile and the template pin; flag `lock_version_mismatch` from the
  validator.

### Phase 3 — Feature parity with the engine

- **Template picker** backed by `list_templates` (all 7 built-ins), with the
  right input shape per template — `starts` vs `training_maxes` for %-based
  5/3/1.
- **Rest** and **exercise_options** editing + display (runtime swap policies:
  `tracking_only` vs `progression_equivalent`).
- **Replay / state** view from `replay`/state projection, and a **backtest**
  view from `backtest_repo`.
- **History import** UI wrapping `import_history_repo` (paste/upload Hevy CSV,
  choose source/delimiter, dry-run preview of drafted events).
- **Generated-file freshness** indicator from `check_generated`, replacing the
  fabricated "Git" text, with an action to (re)write `state/` and `build/`.

### Phase 4 — GitHub / self-host workflows

The workbench stays a **pure static site** — no backend, no `serve`-side API.
The engine runs in the browser via WASM (Phase 0) and GitHub is reached
directly from the page over the REST API. This keeps hosting trivial (any
static host, GitHub Pages, a `file://` open) and matches the MVP promise of a
"static/self-hostable editing workbench".

- **Auth in the browser.** Use GitHub's OAuth device flow, or accept a
  user-supplied fine-grained PAT, and keep the token only in the page
  (in-memory + optional `localStorage`, never committed). No server ever holds
  a secret because there is no server.
- **Load a repo** from GitHub: read `plan.fitspec`, `fitspec.lock`,
  `patches/*.fitspec`, and `logs/**` via the contents API.
- **Write back** canonical edits plus regenerated `state/`/`build/` files as a
  commit, and optionally open a PR — all through REST from the browser.
- Keep it behind a single `RepoBackend` interface (`list`/`read`/`commit`/
  `open_pr`) so the GitHub REST implementation is swappable later if needed, but
  ship just that one implementation.
- `knurled serve` stays a plain static file server for local preview only (it
  still needs `application/wasm` added — see Phase 0); it is not on the GitHub
  path.

### Cross-cutting

- Replace ad-hoc `innerHTML` string building with a small render helper (or a
  light framework) once the data is real; keep `escapeHtml` discipline.
- Accessibility: the rail buttons are icon-only — add labels/`aria-current`.
- Tests: golden-output tests comparing WASM JSON against the committed
  `examples/*/build/*.json` fixtures so the workbench can never silently drift
  from the engine again.

---

## 4. Sequencing, risks, quick wins

**Critical path:** Phase 0 unblocks everything. Until the WASM package exists,
any UI work is built on fabricated data and will need redoing.

**Risks:**
- WASM toolchain integration (target, bindgen, bundling) is the main unknown —
  spike it first with a single `validate` round-trip before building UI.
- Keeping the JSON boundary stable: pin it to the existing serde schemas
  (`schema_version` is already in every report) so workbench, CLI, and iOS stay
  aligned.

**Quick wins (do regardless, low risk):**
1. Fix the sample plan to valid syntax — it currently can't compile.
2. Add `application/wasm` to the `serve` content-type map.
3. Drop the misleading fake "Git"/patches output until the real thing lands.

---

## 5. Definition of done

The workbench computes **nothing** about training itself. Every prescription,
validation result, effect, simulation, and state projection comes from
`knurled-core` via WASM, byte-for-byte consistent with what the CLI and iOS
player produce from the same canonical files — exactly the boundary the rest of
the repo already honours.
