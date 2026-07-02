# Knurled iOS

The Knurled workout **player** for iOS — a thin SwiftUI front-end over the Rust
`knurled-core` engine. It shows the next prescribed workout, captures what actually
happened with low friction, and validates/reduces through the real engine. The training
repo lives in **iCloud Drive** (falling back to on-device storage when iCloud is off),
and can optionally be mirrored to a user-owned **GitHub repository as a backup**.

> **Design rule:** the app is a thin UI over engine output. No training logic — progression,
> effects, rest prescriptions, validation — is reimplemented in Swift. Everything comes from
> `knurled-core` and the app renders it.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  SwiftUI app (Knurled)                                    │
│  @MainActor @Observable stores · NavigationStack · @Entry │
└───────────────┬───────────────────────────┬──────────────┘
                │ WorkoutEngine protocol     │ GitHubClient / DeviceFlow
                ▼ (RustWorkoutEngine actor)  ▼ (off-main, URLSession)
┌──────────────────────────────┐   ┌──────────────────────────┐
│  KnurledCore.xcframework      │   │  GitHub Git Data API      │
│  C ABI · JSON in / JSON out   │   │  blobs→tree→commit→ref    │
│  (Engine/knurled-ios-ffi)     │   └──────────────────────────┘
│        └─► knurled-core (Rust, ../engine)                    │
└──────────────────────────────┘
```

- **SwiftUI**, **iOS 18** min deployment, **Swift 6** language mode with **complete strict
  concurrency**, and **zero third-party dependencies** (URLSession, Foundation, SwiftUI,
  Observation, Security/Keychain, ActivityKit, Swift Testing — all Apple frameworks).
- **Concurrency:** stores are `@MainActor @Observable`; the Codable contract models are value
  types and therefore `Sendable` DTOs that cross actor boundaries freely; the engine FFI and
  GitHub I/O run off-main behind `actor`s with `async` entry points.

## On-device engine (FFI)

`Engine/knurled-ios-ffi` is a small Rust `staticlib` crate that wraps `knurled-core` behind a
thin C ABI. Marshaling is just JSON strings — Swift decodes them into Codable models, so there
is no per-struct C mapping.

```c
char* knurled_validate_repo(const char* dir);
char* knurled_build_repo(const char* dir, int write);          // {state, ir, next_workout, validation}
char* knurled_reduce_input(const char* dir, const char* exec_input_json);
char* knurled_validate_execution_input(const char* dir, const char* exec_input_json);
char* knurled_engine_version(void);
void  knurled_string_free(char* ptr);
```

Every call returns a JSON envelope `{"ok":true,"data":…}` or `{"ok":false,"error":"…"}`.
The crate has its own `[workspace]` table and depends on `knurled-core = { path = "../../engine" }`,
so it is not pulled into the root Cargo workspace. `scripts/build-xcframework.sh` compiles it
for device + simulator and assembles `Engine/KnurledCore.xcframework` (a build artifact, gitignored).

Swift talks to it through the `WorkoutEngine` protocol:

- `RustWorkoutEngine` — an `actor` that calls the FFI off the main thread (`validate`, `build`,
  `reduce`, `validateInput`, `engineVersion`).
- `GeneratedFilesReader` — reads committed `build/*.json` / `state/current.json` directly for
  fast display without an engine call.

## Data + write flow

- Codable types in `Models/` mirror the engine's `model.rs` verbatim — including per-item
  `rest: RestPrescription`, `execution_contract.input_schema`, and
  `effect_preview.{pass,fail,adjusted_today}`.
- The training repo is a plain working directory and it is the **source of truth**. It
  lives in the app's iCloud Drive container (`Documents/repos/<slug>/`, browsable in the
  Files app) when iCloud is available, or under Application Support
  (`Knurled/repos/<slug>/`) otherwise. `RepoManager` resolves the roots, unique-ifies new
  slugs, and moves local repos into iCloud the first time it becomes available.
- **Onboarding:** first launch runs a wizard (`Features/Onboarding/`): pick a built-in
  starter program → enter first-workout numbers → optionally attach a GitHub backup — or
  restore an existing backup from GitHub. There is no bundled sample plan anymore; the
  fixture repo is kept for tests only.
- **GitHub is a backup, not the primary store.** Linking a backup creates (or seeds) a
  repository and pushes the whole working copy; from then on each training change is
  mirrored as one commit. Unlinking stops pushing without touching data.
- **Submit:** the live session builds an `ExecutionInput` → `knurled_reduce_input` for the
  **consequence-first effect preview** → on confirm, `knurled_submit` writes
  `state/current.json` and writes a session-grain `TrainingRecord` into
  `logs/<yyyy>/<mm>.json`, then commits the engine-reported changed files.
- **Record edits:** Swift sends typed amendment intent to the engine. The engine owns parsing,
  identity, revision checks, merging, and serialization; amendments never rerun progression.

## ADR 0007 migration — Swift port checklist

The Rust core moved to the logs-as-record model ([ADR 0007](../docs/adr/0007-logs-as-record-state-as-truth.md)):
the training log is a human-facing record the engine never replays, `state/current.json` is the
authored-forward source of truth, and the event/replay/correction/continuation machinery is gone.
The FFI and Swift app are ported:

- **Models:** `Models/Events.swift` mirrors engine-returned `TrainingRecord` / `LiftRecord` values,
  `SubmitMode`, `SubmitOutcome`, and preview `ReductionResult`.
- **Record I/O:** `WorkoutEngine` reads and amends monthly records through the Rust FFI.
- **`Engine/RustWorkoutEngine.swift` + `WorkoutEngine.swift`:** expose preview-only `reduce` and
  persistent `submit(dir, renderedSnapshot, input, mode, date)`.
- **Submit flow:** `AppModel+Commit` calls `knurled_submit`, refreshes generated outputs, then
  pushes one GitHub commit.
- **History/Data:** both drive from engine-returned `TrainingRecord[]`.
- **Tests:** removed correction/continue/skip event suites; added advance/off-day/reset submit
  coverage and record-shape round trips.

## Features

| Slice | Status | Notes |
|------|--------|-------|
| Foundation (project, xcframework, models, 4-tab shell) | ✅ | decodes the bundled GZCLP fixtures |
| Next Workout + plan/validation status | ✅ | keeps last-valid snapshot on invalid remote |
| Read-only player + History (All/Workouts/Programs) | ✅ | History reads monthly records |
| Active logging | ✅ | per-set target always shown; straight-set Done/Missed; AMRAP wheel on the final set; set-detail edit; tap ✓ to undo a set |
| Adjust-today | ✅ | per set / remaining / whole exercise; `adjusted_today`, no auto-progress |
| Finish → effect preview → submit | ✅ | engine `reduce` then commit |
| Exercise swaps | ✅ | approved alternatives from rendered `exercise_options`, tracking-only by default |
| Rest timer + Live Activity | ✅ | engine-prescribed rest auto-starts after each **non-final** set; ActivityKit lock-screen + Dynamic Island via `KnurledRestActivity`; local notification + haptic when rest ends, and the screen is kept awake while the activity is live |
| Off-day + reset submit modes | ✅ | record-only off-day; reset performed loads as baselines |
| Offline push | ✅ | pending-push flag when a commit can't reach GitHub |
| iCloud-first storage + onboarding wizard | ✅ | repo lives in iCloud Drive (local fallback); first launch = program → numbers → optional backup, or restore |
| GitHub backup | ✅* | device-flow sign-in, create/link backup repo, restore, one-commit push, sync, unlink |

`*` GitHub auth and push compile and present, but need a registered OAuth App **client ID** to
run end-to-end (see below). Without one, the app is fully usable on iCloud/local storage —
only the backup is unavailable.

## Build & run

> **The Rust adapter and the Xcode project are both gitignored build artifacts — a fresh
> checkout will not compile until you generate them.** Run `build-xcframework.sh` and
> `xcodegen generate` (in that order) before the first build, or you'll hit
> `cannot find 'KnurledCore'` / missing-source errors.

Prerequisites: Xcode 16.4+, `xcodegen` (`brew install xcodegen`), Rust with the iOS targets:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

```bash
cd ios
./scripts/build-xcframework.sh                                   # 1. compile Rust core → Engine/KnurledCore.xcframework
xcodegen generate                                                # 2. generate Knurled.xcodeproj (gitignored)
xcodebuild -scheme Knurled -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme Knurled -destination 'platform=iOS Simulator,name=iPhone 16' test
```

**Re-run when things change:**

- Changed anything in `../engine` or `Engine/knurled-ios-ffi`? Re-run
  `./scripts/build-xcframework.sh`. The xcframework is a *compiled snapshot* of the Rust core —
  Swift will silently keep using the old engine until you rebuild it (e.g. a stale framework
  will reject template syntax the current parser accepts).
- Added, removed, or renamed a Swift source / resource? Re-run `xcodegen generate` so the new
  file lands in `Knurled.xcodeproj`. The project globs `Knurled/`, but the generated `.pbxproj`
  is gitignored, so the file is invisible to the build until you regenerate.

The app boots into the onboarding wizard on first launch; creating a program there needs no
GitHub account, so read/log/submit flows are usable in the simulator end-to-end. (The simulator
generally has no iCloud, so repos land in local Application Support — the same code path a
device without iCloud uses.)

### Xcode Cloud

Xcode Cloud builds from a clean checkout, so `ios/ci_scripts/ci_post_clone.sh` prepares the
ignored iOS build artifacts before dependency resolution/archive. Xcode Cloud resolves this path
relative to the selected project directory, so the script lives beside `Knurled.xcodeproj`.

1. installs Rust if `rustup` is unavailable,
2. installs XcodeGen via Homebrew if needed,
3. runs `ios/scripts/build-xcframework.sh`, and
4. runs `xcodegen generate` in `ios/`.

Keep `Knurled.xcodeproj` and `Engine/KnurledCore.xcframework` gitignored; the cloud workflow
should continue to point at `ios/Knurled.xcodeproj` after the post-clone script generates it.

## iCloud setup

The app uses the default ubiquity container `iCloud.com.knurled.app` (CloudDocuments), declared
in `project.yml` → `Knurled.entitlements` and exposed in the Files app via
`NSUbiquitousContainers`. Signing with a team that has the iCloud capability is enough; when the
user is signed out of iCloud (or disables it for Knurled), storage silently falls back to local
Application Support and Settings shows "This device".

## GitHub backup setup (optional)

1. Register a GitHub OAuth App at <https://github.com/settings/developers> with **Device Flow**
   enabled.
2. `cp Config/Secrets.sample.xcconfig Config/Secrets.xcconfig` and paste the **Client ID** into
   `GITHUB_CLIENT_ID` (gitignored; injected into Info.plist as `GitHubClientID`).
3. Onboarding (or Settings → Storage & Backup) → Connect GitHub → enter the device code →
   create a backup repository, or restore an existing one. Scope: `repo` (or fine-grained
   contents read/write).

## Project layout

```
ios/
  project.yml                      xcodegen spec (generates Knurled.xcodeproj)
  Config/*.xcconfig                build settings + GITHUB_CLIENT_ID
  scripts/build-xcframework.sh     builds KnurledCore.xcframework
  Engine/
    knurled-ios-ffi/               Rust C-ABI crate over knurled-core
    KnurledCore.xcframework        build artifact (gitignored)
  Knurled/
    App/                           AppModel (+Commit/+Skip/+Correct/+GitHub), ActiveRepo, RootView
    DesignSystem/                  theme, components, formatting
    Models/                        Codable contract types mirroring model.rs
    Engine/                        WorkoutEngine protocol, RustWorkoutEngine (FFI), readers
    Repo/                          RepoManager (iCloud/local storage roots, migration)
    GitHub/                        DeviceFlow, GitHubClient (Git Data API), TokenStore (Keychain)
    Stores/                        GitHubStore (@Observable)
    Live/                          RestTimer + shared ActivityKit attributes
    Features/                      Onboarding · Workout · History · Plan · Settings
    Resources/Fixtures/gzclp-repo  bundled fixture repo (tests only)
  KnurledRestActivity/             Live Activity widget extension (ActivityKit)
  KnurledTests/                    Swift Testing — decoding, FFI round-trip, §40 acceptance, submit/swap/github
```

## Tests

`xcodebuild test` runs the Swift Testing suite against the real engine via the xcframework:

- **Model decoding** against the bundled `gzclp-repo` fixtures.
- **FFI round-trip** — validate/build/reduce a synthetic input.
- **§40 acceptance** — AMRAP numeric input, straight-set miss, adjust-today, completed-session
  cursor advance.
- **Record round-trips** — submit writes `logs/<yyyy>/<mm>.json`; swap records
  performed/prescribed/policy in preview results.
- **GitHub** — commit-message templates and changed-file discovery.
- **Onboarding** — local repo creation from a template with applied starting numbers, slug
  unique-ification, backup link/unlink, and legacy sample-selection skip on restore.
