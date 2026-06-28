//! C ABI bridge over `knurled-core` for the iOS app.
//!
//! Every function operates on a working-copy repo directory and/or JSON, and
//! returns a freshly allocated C string holding a JSON envelope:
//!
//! ```json
//! { "ok": true,  "data": <result> }
//! { "ok": false, "error": "<message>" }
//! ```
//!
//! Swift copies the string, decodes the envelope, and must call
//! `knurled_string_free` on the returned pointer. No training logic lives here;
//! this is pure marshaling around the engine's public API.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::panic::{AssertUnwindSafe, catch_unwind};

use knurled_core::{
    AddProgramRequest, AmendRecordRequest, ENGINE_VERSION, ExecutionInput, PlanEdit, RenderedSession, SubmitMode,
    Units, amend_training_record, apply_plan_edit, build_outputs, build_repo, builtin_templates,
    exercise_catalog, init_training_repo, merge_record_repos, preview_plan_edit, read_records,
    read_state, read_training_repo, reduce_input, render_session, submit_rendered_repo,
    suggest_initial_numbers, suggest_load, validate_execution_input, validate_repo,
    add_program, delete_program, list_programs, set_active_program,
    suggest_program_adjustments,
};
use serde::Serialize;
use serde_json::json;

fn into_raw(text: String) -> *mut c_char {
    CString::new(text)
        .unwrap_or_else(|_| CString::new("").expect("empty CString"))
        .into_raw()
}

fn ok<T: Serialize>(data: T) -> *mut c_char {
    let envelope = match serde_json::to_value(&data) {
        Ok(value) => json!({ "ok": true, "data": value }),
        Err(error) => json!({ "ok": false, "error": format!("serialize error: {error}") }),
    };
    into_raw(envelope.to_string())
}

fn fail(message: impl std::fmt::Display) -> *mut c_char {
    into_raw(json!({ "ok": false, "error": message.to_string() }).to_string())
}

/// # Safety
/// `ptr` must be null or a valid NUL-terminated C string.
unsafe fn borrow<'a>(ptr: *const c_char) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err("null pointer argument".into());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|error| format!("invalid utf-8 argument: {error}"))
}

fn guard<F: FnOnce() -> *mut c_char>(name: &str, body: F) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(pointer) => pointer,
        Err(_) => fail(format!("panic in {name}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_validate_repo(dir: *const c_char) -> *mut c_char {
    guard("knurled_validate_repo", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match validate_repo(dir) {
            Ok(report) => ok(report),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_build_repo(dir: *const c_char, write: c_int) -> *mut c_char {
    guard("knurled_build_repo", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match build_repo(dir, write != 0) {
            Ok(outputs) => ok(outputs),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_init_repo(
    dir: *const c_char,
    template_ref: *const c_char,
) -> *mut c_char {
    guard("knurled_init_repo", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let template_ref = match unsafe { borrow(template_ref) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match init_training_repo(dir, template_ref) {
            Ok(result) => ok(json!({
                "root": result.root,
                "validation": result.validation,
                "next_workout": result.next_workout,
            })),
            Err(error) => fail(error),
        }
    })
}

/// Reduces an execution input against the **rendered session snapshot** the workout was
/// started from (spec §16/§31), not whatever the repo currently renders. The caller passes
/// the snapshot JSON it captured at start, so a sync/repo change between start and submit
/// cannot silently re-target the reduction.
#[unsafe(no_mangle)]
pub extern "C" fn knurled_reduce_input(
    dir: *const c_char,
    rendered_session_json: *const c_char,
    execution_input_json: *const c_char,
) -> *mut c_char {
    guard("knurled_reduce_input", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let rendered_json = match unsafe { borrow(rendered_session_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let input_json = match unsafe { borrow(execution_input_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let rendered: RenderedSession = match serde_json::from_str(rendered_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid rendered session: {error}")),
        };
        let input: ExecutionInput = match serde_json::from_str(input_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid execution input: {error}")),
        };
        let repo = match read_training_repo(dir) {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let state = match read_state(dir) {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match reduce_input(&repo.compiled, &state, &rendered, &input) {
            Ok(result) => ok(result),
            Err(error) => fail(error),
        }
    })
}

/// Submits a finished session against the rendered-session snapshot it was started from
/// (ADR 0007): advances `state` per `mode` (`advance` | `off_day` | `reset`), persists
/// `state/current.json`, and appends the day to `logs/<yyyy>/<mm>.json`. Returns the
/// `SubmitOutcome` (`validation`, `record`, `new_state`, `effects`, `changed_files`). On invalid input
/// nothing is written.
#[unsafe(no_mangle)]
pub extern "C" fn knurled_submit(
    dir: *const c_char,
    rendered_session_json: *const c_char,
    execution_input_json: *const c_char,
    mode: *const c_char,
    date: *const c_char,
) -> *mut c_char {
    guard("knurled_submit", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let rendered_json = match unsafe { borrow(rendered_session_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let input_json = match unsafe { borrow(execution_input_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let mode_str = match unsafe { borrow(mode) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let date = match unsafe { borrow(date) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let rendered: RenderedSession = match serde_json::from_str(rendered_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid rendered session: {error}")),
        };
        let input: ExecutionInput = match serde_json::from_str(input_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid execution input: {error}")),
        };
        let mode = match mode_str {
            "off_day" => SubmitMode::OffDay,
            "reset" => SubmitMode::Reset,
            "advance" | "" => SubmitMode::Advance,
            other => return fail(format!("unknown submit mode: {other:?}")),
        };
        let outcome = match submit_rendered_repo(dir, &rendered, &input, mode, date) {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        ok(outcome)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_read_records(dir: *const c_char) -> *mut c_char {
    guard("knurled_read_records", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match read_records(dir) {
            Ok(records) => ok(records),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_amend_record(
    dir: *const c_char,
    request_json: *const c_char,
) -> *mut c_char {
    guard("knurled_amend_record", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let request_json = match unsafe { borrow(request_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let request: AmendRecordRequest = match serde_json::from_str(request_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid record amendment: {error}")),
        };
        match amend_training_record(dir, request) {
            Ok(outcome) => ok(outcome),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_merge_record_repos(
    source_dir: *const c_char,
    target_dir: *const c_char,
) -> *mut c_char {
    guard("knurled_merge_record_repos", || {
        let source = match unsafe { borrow(source_dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let target = match unsafe { borrow(target_dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match merge_record_repos(source, target) {
            Ok(paths) => ok(paths),
            Err(error) => fail(error),
        }
    })
}

/// Re-renders a specific session by id against the repo's current state, ignoring the cursor.
/// Saved partials store a session id in the record, so resuming one from history needs that
/// session re-rendered explicitly.
#[unsafe(no_mangle)]
pub extern "C" fn knurled_render_session(
    dir: *const c_char,
    session_id: *const c_char,
) -> *mut c_char {
    guard("knurled_render_session", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let session_id = match unsafe { borrow(session_id) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let repo = match read_training_repo(dir) {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let state = match read_state(dir) {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match render_session(&repo.compiled, &state, session_id) {
            Ok(rendered) => ok(rendered),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_validate_execution_input(
    dir: *const c_char,
    execution_input_json: *const c_char,
) -> *mut c_char {
    guard("knurled_validate_execution_input", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let input_json = match unsafe { borrow(execution_input_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let input: ExecutionInput = match serde_json::from_str(input_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid execution input: {error}")),
        };
        let repo = match read_training_repo(dir) {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let state = match read_state(dir) {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let outputs = match build_outputs(&repo.compiled, &state) {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let rendered = match outputs.next_workout {
            Some(value) => value,
            None => return fail("repo has no next workout to validate against"),
        };
        ok(validate_execution_input(&rendered, &input))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_preview_plan_edit(
    dir: *const c_char,
    plan_edit_json: *const c_char,
) -> *mut c_char {
    guard("knurled_preview_plan_edit", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let edit_json = match unsafe { borrow(plan_edit_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let edit: PlanEdit = match serde_json::from_str(edit_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid plan edit: {error}")),
        };
        match preview_plan_edit(dir, edit) {
            Ok(outcome) => ok(outcome),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_apply_plan_edit(
    dir: *const c_char,
    plan_edit_json: *const c_char,
) -> *mut c_char {
    guard("knurled_apply_plan_edit", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let edit_json = match unsafe { borrow(plan_edit_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let edit: PlanEdit = match serde_json::from_str(edit_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid plan edit: {error}")),
        };
        match apply_plan_edit(dir, edit) {
            Ok(outcome) => ok(outcome),
            Err(error) => fail(error),
        }
    })
}

#[derive(serde::Deserialize)]
struct InitialNumberSuggestionRequest {
    template: String,
    units: Units,
}

#[derive(serde::Deserialize)]
struct LoadSuggestionRequest {
    exercise: String,
    units: Units,
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_suggest_initial_numbers(
    dir: *const c_char,
    request_json: *const c_char,
) -> *mut c_char {
    guard("knurled_suggest_initial_numbers", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let request_json = match unsafe { borrow(request_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let request: InitialNumberSuggestionRequest = match serde_json::from_str(request_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid suggestion request: {error}")),
        };
        match suggest_initial_numbers(dir, &request.template, request.units) {
            Ok(suggestions) => ok(suggestions),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_suggest_load(
    dir: *const c_char,
    request_json: *const c_char,
) -> *mut c_char {
    guard("knurled_suggest_load", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let request_json = match unsafe { borrow(request_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let request: LoadSuggestionRequest = match serde_json::from_str(request_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid load suggestion request: {error}")),
        };
        match suggest_load(dir, &request.exercise, request.units) {
            Ok(suggestion) => ok(suggestion),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_list_programs(dir: *const c_char) -> *mut c_char {
    guard("knurled_list_programs", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match list_programs(dir) {
            Ok(programs) => ok(programs),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_add_program(
    dir: *const c_char,
    request_json: *const c_char,
) -> *mut c_char {
    guard("knurled_add_program", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let request_json = match unsafe { borrow(request_json) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let request: AddProgramRequest = match serde_json::from_str(request_json) {
            Ok(value) => value,
            Err(error) => return fail(format!("invalid add program request: {error}")),
        };
        match add_program(dir, request) {
            Ok(outcome) => ok(outcome),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_set_active_program(
    dir: *const c_char,
    slug: *const c_char,
) -> *mut c_char {
    guard("knurled_set_active_program", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let slug = match unsafe { borrow(slug) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match set_active_program(dir, slug) {
            Ok(outcome) => ok(outcome),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_delete_program(
    dir: *const c_char,
    slug: *const c_char,
) -> *mut c_char {
    guard("knurled_delete_program", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let slug = match unsafe { borrow(slug) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match delete_program(dir, slug) {
            Ok(outcome) => ok(outcome),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_suggest_program_adjustments(dir: *const c_char) -> *mut c_char {
    guard("knurled_suggest_program_adjustments", || {
        let dir = match unsafe { borrow(dir) } {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        match suggest_program_adjustments(dir) {
            Ok(suggestions) => ok(suggestions),
            Err(error) => fail(error),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_engine_version() -> *mut c_char {
    guard("knurled_engine_version", || ok(ENGINE_VERSION))
}

/// Lists the engine's built-in starter templates so the app never hardcodes template
/// identifiers or names. Each entry carries the `@`-versioned reference to pass back to
/// `knurled_init_repo`, plus the display name and description the engine owns.
#[unsafe(no_mangle)]
pub extern "C" fn knurled_builtin_templates() -> *mut c_char {
    guard("knurled_builtin_templates", || {
        let templates: Vec<_> = builtin_templates()
            .iter()
            .map(|info| {
                json!({
                    "reference": format!("{}@{}", info.id, info.version),
                    "display_name": info.display_name,
                    "description": info.description,
                })
            })
            .collect();
        ok(templates)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn knurled_exercise_catalog() -> *mut c_char {
    guard("knurled_exercise_catalog", || ok(exercise_catalog()))
}

/// Frees a string previously returned by any `knurled_*` function.
///
/// # Safety
/// `ptr` must be null or a pointer returned by this library and not yet freed.
#[unsafe(no_mangle)]
pub extern "C" fn knurled_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}
