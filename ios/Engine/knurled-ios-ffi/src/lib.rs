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
    ENGINE_VERSION, ExecutionInput, build_outputs, build_repo, read_training_repo, reduce_input,
    validate_execution_input, validate_repo,
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
pub extern "C" fn knurled_reduce_input(
    dir: *const c_char,
    execution_input_json: *const c_char,
) -> *mut c_char {
    guard("knurled_reduce_input", || {
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
        let outputs = match build_outputs(&repo.compiled, &repo.events) {
            Ok(value) => value,
            Err(error) => return fail(error),
        };
        let rendered = match outputs.next_workout {
            Some(value) => value,
            None => return fail("repo has no next workout to reduce against"),
        };
        match reduce_input(&repo.compiled, &outputs.state, &rendered, &input) {
            Ok(result) => ok(result),
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
        let outputs = match build_outputs(&repo.compiled, &repo.events) {
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
pub extern "C" fn knurled_engine_version() -> *mut c_char {
    guard("knurled_engine_version", || ok(ENGINE_VERSION))
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
