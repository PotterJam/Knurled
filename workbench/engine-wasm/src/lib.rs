//! wasm-bindgen bridge over `knurled-core` for the static browser workbench.
//!
//! Every export returns a JSON string holding the same envelope the iOS FFI
//! uses (`ios/Engine/knurled-ios-ffi`):
//!
//! ```json
//! { "ok": true,  "data": <result> }
//! { "ok": false, "error": "<message>", "error_detail": { "kind": "...", "retryable": false } }
//! ```
//!
//! `error_detail` is additive (RFC-0001 D9): callers keep reading `error`, or
//! branch on the stable `kind` instead of message text.
//!
//! No training logic lives here. The browser has no filesystem, so we bind the
//! engine's **in-memory** functions (`compile_plan`, `build_outputs`,
//! `simulate`, `submit_session`, `backtest`, …) rather than the `*_repo`
//! helpers that read directories. The JS loader (`workbench/engine/index.js`)
//! unwraps the envelope and throws on `ok:false`.

use knurled_core::{
    CompiledPlan, ENGINE_VERSION, ExecutionInput, PatchFile, ProfileRequest, StateProjection,
    SubmitMode, TrainingRecord, backtest, build_outputs, builtin_template, builtin_templates,
    compile_plan, create_initial_state, exercise_catalog, explain, merge_training_records,
    recommend_template, render_lockfile, render_next, serialize_record_files, simulate,
    submit_session, suggest_next_date, validate_compiled, validation_code_message,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use wasm_bindgen::prelude::*;

#[derive(Deserialize)]
struct PatchInput {
    filename: String,
    text: String,
}

fn ok<T: Serialize>(data: T) -> String {
    match serde_json::to_value(&data) {
        Ok(value) => json!({ "ok": true, "data": value }).to_string(),
        Err(error) => {
            json!({ "ok": false, "error": format!("serialize error: {error}") }).to_string()
        }
    }
}

/// Stable machine-readable detail for the failure envelope (RFC-0001 D9).
trait ErrorDetail: std::fmt::Display {
    fn detail(&self) -> (&'static str, bool) {
        ("invalid_argument", false)
    }
}

impl ErrorDetail for knurled_core::KnurledError {
    fn detail(&self) -> (&'static str, bool) {
        (self.kind(), self.retryable())
    }
}

impl ErrorDetail for String {}
impl ErrorDetail for &str {}

fn fail(error: impl ErrorDetail) -> String {
    let (kind, retryable) = error.detail();
    json!({
        "ok": false,
        "error": error.to_string(),
        "error_detail": { "kind": kind, "retryable": retryable },
    })
    .to_string()
}

fn parse_patches(patches_json: &str) -> Result<Vec<PatchFile>, String> {
    if patches_json.trim().is_empty() {
        return Ok(Vec::new());
    }
    let inputs: Vec<PatchInput> = serde_json::from_str(patches_json)
        .map_err(|error| format!("invalid patches json: {error}"))?;
    Ok(inputs
        .into_iter()
        .map(|input| PatchFile {
            filename: input.filename,
            text: input.text,
        })
        .collect())
}

/// Resolve `state_json` against a compiled plan: parse it, or fall back to the
/// program's initial state when empty (ADR 0007 — the browser holds `state`).
fn resolve_state(compiled: &CompiledPlan, state_json: &str) -> Result<StateProjection, String> {
    if state_json.trim().is_empty() {
        return Ok(create_initial_state(compiled));
    }
    serde_json::from_str(state_json).map_err(|error| format!("invalid state json: {error}"))
}

/// Compile + validate a plan. Returns a `ValidationReport`.
#[wasm_bindgen]
pub fn validate(plan_text: &str, lock_text: &str, patches_json: &str) -> String {
    let patches = match parse_patches(patches_json) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    match compile_plan(plan_text, lock_text, &patches) {
        Ok(compiled) => ok(validate_compiled(&compiled)),
        Err(error) => fail(error),
    }
}

/// Compile + render the next workout from `state` (ADR 0007). Returns
/// `BuildOutputs` (`state`, `ir`, `next_workout`, `validation`) — the
/// workbench's main call. An empty `state_json` means the program's initial
/// state.
#[wasm_bindgen]
pub fn build(plan_text: &str, lock_text: &str, patches_json: &str, state_json: &str) -> String {
    let patches = match parse_patches(patches_json) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let compiled = match compile_plan(plan_text, lock_text, &patches) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let state = match resolve_state(&compiled, state_json) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    match build_outputs(&compiled, &state) {
        Ok(outputs) => ok(outputs),
        Err(error) => fail(error),
    }
}

/// Project the plan forward from `state`. Returns a `SimulationReport`.
#[wasm_bindgen]
pub fn simulate_plan(
    plan_text: &str,
    lock_text: &str,
    patches_json: &str,
    state_json: &str,
    weeks: u32,
    strategy: &str,
) -> String {
    let patches = match parse_patches(patches_json) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let compiled = match compile_plan(plan_text, lock_text, &patches) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let state = match resolve_state(&compiled, state_json) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    match simulate(&compiled, &state, weeks, strategy) {
        Ok(report) => ok(report),
        Err(error) => fail(error),
    }
}

/// Submit a finished session (ADR 0007). The browser holds `state` and the
/// record, so they are passed in and returned: this renders the next workout
/// from `state_json`, reduces the input per `mode` (`advance` | `off_day` |
/// `reset`), and returns a `SubmitOutcome` (`validation`, `record` to
/// upsert into the month file, `new_state` to persist, `effects`). An empty
/// `state_json` means the program's initial state.
#[wasm_bindgen]
pub fn submit(
    plan_text: &str,
    lock_text: &str,
    patches_json: &str,
    state_json: &str,
    input_json: &str,
    mode: &str,
    date: &str,
) -> String {
    let patches = match parse_patches(patches_json) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let compiled = match compile_plan(plan_text, lock_text, &patches) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let state: StateProjection = if state_json.trim().is_empty() {
        create_initial_state(&compiled)
    } else {
        match serde_json::from_str(state_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid state json: {error}")),
        }
    };
    let input: ExecutionInput = match serde_json::from_str(input_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid input json: {error}")),
    };
    let mode = match mode {
        "off_day" => SubmitMode::OffDay,
        "reset" => SubmitMode::Reset,
        "advance" | "" => SubmitMode::Advance,
        other => return fail(format!("unknown submit mode: {other:?}")),
    };
    let rendered = match render_next(&compiled, &state) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    match submit_session(&compiled, &state, &rendered, &input, mode, date) {
        Ok(outcome) => ok(outcome),
        Err(error) => fail(error),
    }
}

/// Backtest the plan over training records (ADR 0007). `days_json` is a JSON array
/// of records (`logs/<yyyy>/<mm>.json` `records[]`). Returns a
/// `BacktestProjection`.
#[wasm_bindgen]
pub fn backtest_records(
    plan_text: &str,
    lock_text: &str,
    patches_json: &str,
    days_json: &str,
) -> String {
    let patches = match parse_patches(patches_json) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let compiled = match compile_plan(plan_text, lock_text, &patches) {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let days: Vec<TrainingRecord> = if days_json.trim().is_empty() {
        Vec::new()
    } else {
        match serde_json::from_str(days_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid days json: {error}")),
        }
    };
    match backtest(&compiled, &days) {
        Ok(projection) => ok(projection),
        Err(error) => fail(error),
    }
}

#[wasm_bindgen]
pub fn merge_records(existing_json: &str, incoming_json: &str) -> String {
    let existing: Vec<TrainingRecord> = match serde_json::from_str(existing_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid existing records json: {error}")),
    };
    let incoming: Vec<TrainingRecord> = match serde_json::from_str(incoming_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid incoming records json: {error}")),
    };
    match merge_training_records(existing, incoming) {
        Ok(records) => ok(records),
        Err(error) => fail(error),
    }
}

#[wasm_bindgen]
pub fn record_files(records_json: &str) -> String {
    let records: Vec<TrainingRecord> = match serde_json::from_str(records_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid records json: {error}")),
    };
    match serialize_record_files(&records) {
        Ok(files) => ok(files),
        Err(error) => fail(error),
    }
}

/// List built-in templates with their session/slot/tier skeleton so the builder
/// canvas reflects real structure instead of hardcoded assumptions.
#[wasm_bindgen]
pub fn builtin_template_catalog() -> String {
    let mut templates = Vec::new();
    for info in builtin_templates() {
        let reference = format!("{}@{}", info.id, info.version);
        let skeleton = match builtin_template(&reference) {
            Ok(template) => serde_json::to_value(&template).unwrap_or(Value::Null),
            Err(error) => return fail(error),
        };
        templates.push(json!({
            "id": info.id,
            "version": info.version,
            "ref": reference,
            "display_name": info.display_name,
            "description": info.description,
            "skeleton": skeleton,
        }));
    }
    ok(templates)
}

#[wasm_bindgen]
pub fn exercise_catalog_json() -> String {
    ok(exercise_catalog())
}

/// Generate a correct `fitspec.lock` body for a freshly authored plan's template.
#[wasm_bindgen]
pub fn lock_for(template_ref: &str) -> String {
    match render_lockfile(template_ref) {
        Ok(text) => ok(text),
        Err(error) => fail(error),
    }
}

/// Glossary lookup for a template term (RFC-0001 D3). Unknown terms yield
/// `{ "explanation": null }`.
#[wasm_bindgen]
pub fn explain_term(term: &str) -> String {
    ok(json!({ "explanation": explain(term) }))
}

/// Engine-owned human copy for a validation code (RFC-0001 D9).
#[wasm_bindgen]
pub fn validation_message(code: &str) -> String {
    ok(validation_code_message(code))
}

/// "Help me choose" wizard backend (RFC-0001 D2). `profile_json` is a
/// `ProfileRequest { experience, days_per_week, goal }`.
#[wasm_bindgen]
pub fn recommend(profile_json: &str) -> String {
    let profile: ProfileRequest = match serde_json::from_str(profile_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid profile json: {error}")),
    };
    ok(recommend_template(&profile))
}

/// Derived next-workout date (RFC-0001 D4): first weekday in
/// `suggested_days_json` (array of "mon"-style tokens) strictly after the
/// latest dated record in `records_json`, or the date a reschedule marker
/// pins. The browser holds the records, so they are passed in.
#[wasm_bindgen]
pub fn next_workout_date(suggested_days_json: &str, records_json: &str) -> String {
    let days: Vec<String> = match serde_json::from_str(suggested_days_json) {
        Ok(value) => value,
        Err(error) => return fail(format!("invalid suggested days json: {error}")),
    };
    let records: Vec<TrainingRecord> = if records_json.trim().is_empty() {
        Vec::new()
    } else {
        match serde_json::from_str(records_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid records json: {error}")),
        }
    };
    ok(json!({ "suggested_date": suggest_next_date(&days, &records) }))
}

#[wasm_bindgen]
pub fn engine_version() -> String {
    ok(ENGINE_VERSION)
}
