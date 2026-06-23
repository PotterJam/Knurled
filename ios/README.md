# Knurled iOS

The Knurled workout **player** for iOS — a thin SwiftUI front-end over the Rust
`knurled-core` engine. It shows the next prescribed workout, captures what actually
happened with low friction, validates/reduces through the real engine, and commits
training events back to a user-owned GitHub repository.

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
- Each connected repo is a working directory under Application Support
  (`Knurled/repos/<owner>-<name>/`) mirroring the repo tree.
- **Submit:** the live session builds an `ExecutionInput` → `knurled_reduce_input` → a
  **consequence-first effect preview** → on confirm, append the event JSON line to
  `logs/<yyyy>/<mm>.jsonl`, then `knurled_build_repo(write:true)` regenerates
  `state/current.json` + `build/*.json` deterministically, then one GitHub commit of every
  changed file. The engine is the only source of effects.
- **Skip / correction** events are authored in Swift (user intent), appended, and re-folded by
  the engine on rebuild — the original log is never rewritten.

## Features

| Slice | Status | Notes |
|------|--------|-------|
| Foundation (project, xcframework, models, 4-tab shell) | ✅ | decodes the bundled GZCLP fixtures |
| Next Workout + plan/validation status | ✅ | keeps last-valid snapshot on invalid remote |
| Read-only player + History (All/Workouts/Skips, partial/edited badges) | ✅ | |
| Active logging | ✅ | per-set target always shown; straight-set Done/Missed; AMRAP wheel on the final set; set-detail edit; tap ✓ to undo a set |
| Adjust-today | ✅ | per set / remaining / whole exercise; `adjusted_today`, no auto-progress |
| Finish → effect preview → submit | ✅ | engine `reduce` then commit |
| Partial + continue | ✅ | Pause/Save partial event |
| Corrections | ✅ | edit logged reps from History → `session_corrected` → re-fold |
| Exercise swaps | ✅ | approved alternatives from rendered `exercise_options`, tracking-only by default |
| Rest timer + Live Activity | ✅ | engine-prescribed rest auto-starts after each **non-final** set; ActivityKit lock-screen + Dynamic Island via `KnurledRestActivity` |
| Skips + offline push | ✅ | push-forward skip; pending-push flag when a commit can't reach GitHub |
| GitHub sync | ✅* | device-flow sign-in, repo picker, pull, one-commit push, sync |

`*` GitHub auth and push compile and present, but need a registered OAuth App **client ID** to
run end-to-end (see below). Until one is set, the app runs on the bundled sample repo.

## Build & run

Prerequisites: Xcode 16.4+, `xcodegen`, Rust with the iOS targets:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

```bash
cd ios
./scripts/build-xcframework.sh                                   # → Engine/KnurledCore.xcframework
xcodegen generate                                                # → Knurled.xcodeproj (gitignored)
xcodebuild -scheme Knurled -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme Knurled -destination 'platform=iOS Simulator,name=iPhone 16' test
```

The app boots straight onto the bundled `gzclp-repo` sample, so every read/log/skip/correct
flow is usable in the simulator without GitHub.

## GitHub setup (optional)

1. Register a GitHub OAuth App at <https://github.com/settings/developers> with **Device Flow**
   enabled.
2. `cp Config/Secrets.sample.xcconfig Config/Secrets.xcconfig` and paste the **Client ID** into
   `GITHUB_CLIENT_ID` (gitignored; injected into Info.plist as `GitHubClientID`).
3. Settings → Connect GitHub → enter the device code → pick a repo. Scope: `repo` (or
   fine-grained contents read/write).

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
    Repo/                          LocalRepoStore, LogReader
    GitHub/                        DeviceFlow, GitHubClient (Git Data API), TokenStore (Keychain)
    Stores/                        GitHubStore (@Observable)
    Live/                          RestTimer + shared ActivityKit attributes
    Features/                      Onboarding · Workout · History · Plan · Settings
    Resources/Fixtures/gzclp-repo  bundled sample repo (previews + offline demo)
  KnurledRestActivity/             Live Activity widget extension (ActivityKit)
  KnurledTests/                    Swift Testing — decoding, FFI round-trip, §40 acceptance, skip/correct/swap/github
```

## Tests

`xcodebuild test` runs the Swift Testing suite against the real engine via the xcframework:

- **Model decoding** against the bundled `gzclp-repo` fixtures.
- **FFI round-trip** — validate/build/reduce a synthetic input.
- **§40 acceptance** — AMRAP numeric input, straight-set miss, adjust-today, completed-session
  cursor advance.
- **Event round-trips** — skip advances the cursor; a correction re-folds outcomes without
  rewriting the original log; a swap records performed/prescribed/policy.
- **GitHub** — commit-message templates and changed-file discovery.
