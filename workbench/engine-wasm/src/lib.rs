//! wasm-bindgen bridge over `knurled-core` for the static browser workbench.
//!
//! Every export returns a JSON string holding the same envelope the iOS FFI
//! uses (`ios/Engine/knurled-ios-ffi`):
//!
//! ```json
//! { "ok": true,  "data": <result> }
//! { "ok": false, "error": "<message>" }
//! ```
//!
//! No training logic lives here. The browser has no filesystem, so we bind the
//! engine's **in-memory** functions (`compile_plan`, `build_outputs`,
//! `simulate`, `history_import_events_from_str`, …) rather than the `*_repo`
//! helpers that read directories. The JS loader (`workbench/engine/index.js`)
//! unwraps the envelope and throws on `ok:false`.

use knurled_core::{
    CompiledPlan, DayRecord, ENGINE_VERSION, ExecutionInput, PatchFile, StateProjection, SubmitMode,
    backtest, build_outputs, builtin_template, builtin_templates, compile_plan, create_initial_state,
    render_lockfile, render_next, simulate, submit_session, validate_compiled,
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
        Err(error) => json!({ "ok": false, "error": format!("serialize error: {error}") })
            .to_string(),
    }
}

fn fail(message: impl std::fmt::Display) -> String {
    json!({ "ok": false, "error": message.to_string() }).to_string()
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
/// `reset`), and returns a `SubmitOutcome` (`validation`, `record_day` to
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

/// Backtest the plan over recorded days (ADR 0007). `days_json` is a JSON array
/// of day records (`logs/<yyyy>/<mm>.json` `days[]`). Returns a
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
    let days: Vec<DayRecord> = if days_json.trim().is_empty() {
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

/// Generate a correct `fitspec.lock` body for a freshly authored plan's template.
#[wasm_bindgen]
pub fn lock_for(template_ref: &str) -> String {
    match render_lockfile(template_ref) {
        Ok(text) => ok(text),
        Err(error) => fail(error),
    }
}

#[wasm_bindgen]
pub fn engine_version() -> String {
    ok(ENGINE_VERSION)
}
