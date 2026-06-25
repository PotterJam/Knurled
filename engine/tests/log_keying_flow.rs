//! End-to-end coverage of the iOS submit flow (knurled_submit): it uses
//! submit_session + write_state + append_day_record against a passed rendered
//! session snapshot, NOT submit_repo. These guard the log-keying contract the
//! iOS history/partial features depend on: a day is keyed by (date, session),
//! so two sessions on one date stay separate and a continued partial replaces
//! the session it resumes in place.

use std::time::{SystemTime, UNIX_EPOCH};

use knurled_core::session::SubmitMode;
use knurled_core::{
    ExecutionInput, RenderedSession, append_day_record, init_training_repo, read_records,
    read_state, read_training_repo, render_next, render_session, submit_session,
    synthetic_execution_input, write_state,
};

fn temp_repo(name: &str) -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("knurled-{name}-{nanos}"))
}

/// Mirror the FFI `knurled_submit`: submit against a passed rendered snapshot,
/// then persist state and append the record.
fn ffi_submit(
    root: &std::path::Path,
    rendered: &RenderedSession,
    input: &ExecutionInput,
    date: &str,
) {
    let repo = read_training_repo(root).unwrap();
    let state = read_state(root).unwrap();
    let outcome = submit_session(
        &repo.compiled,
        &state,
        rendered,
        input,
        SubmitMode::Advance,
        date,
    )
    .unwrap();
    assert!(
        outcome.validation.status == knurled_core::ValidationStatus::Valid,
        "validation failed: {:?}",
        outcome.validation.errors
    );
    write_state(root, &outcome.new_state).unwrap();
    append_day_record(root, outcome.record_day.clone()).unwrap();
}

fn partial_input(rendered: &RenderedSession, started_at: &str, saved_at: &str) -> ExecutionInput {
    let mut input = synthetic_execution_input(rendered, "pass", 0);
    input.status = "partial".into();
    input.started_at = Some(started_at.into());
    input.saved_at = Some(saved_at.into());
    input.completed_at = None;
    input.inputs.truncate(1); // a partial logs only some items
    input
}

#[test]
fn continuing_a_partial_replaces_it_in_place_and_advances() {
    let root = temp_repo("ios-partial");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    // Complete a1 on 06-01.
    let repo = read_training_repo(&root).unwrap();
    let state = read_state(&root).unwrap();
    let a1 = render_next(&repo.compiled, &state).unwrap();
    let mut a1_input = synthetic_execution_input(&a1, "pass", 0);
    a1_input.started_at = Some("2026-06-01T10:00:00Z".into());
    a1_input.completed_at = Some("2026-06-01T11:00:00Z".into());
    ffi_submit(&root, &a1, &a1_input, "2026-06-01");

    // Save a partial of the now-current session (b1) on 06-03.
    let after_a1 = read_state(&root).unwrap();
    let b1 = render_next(&repo.compiled, &after_a1).unwrap();
    let p_input = partial_input(&b1, "2026-06-03T10:00:00Z", "2026-06-03T10:30:00Z");
    ffi_submit(&root, &b1, &p_input, "2026-06-03");

    let after_partial = read_state(&root).unwrap();
    assert_eq!(
        after_partial.cursor.next_session, b1.session_id,
        "a partial save must not advance the cursor"
    );
    let days = read_records(&root).unwrap();
    assert_eq!(
        days.len(),
        2,
        "the partial is a new record beside the a1 day"
    );

    // Continue from history: re-render that session by id and complete it on the
    // partial's date.
    let continued = render_session(&repo.compiled, &after_partial, &b1.session_id).unwrap();
    let mut complete_input = synthetic_execution_input(&continued, "pass", 0);
    complete_input.status = "complete".into();
    complete_input.started_at = Some("2026-06-03T10:30:00Z".into());
    complete_input.completed_at = Some("2026-06-03T11:30:00Z".into());
    ffi_submit(&root, &continued, &complete_input, "2026-06-03");

    let after_continue = read_state(&root).unwrap();
    let days = read_records(&root).unwrap();

    // Still two records: the partial was replaced in place, not duplicated.
    assert_eq!(
        days.len(),
        2,
        "completing the partial must not add a record"
    );
    let d03 = days.iter().find(|d| d.date == "2026-06-03").unwrap();
    assert_eq!(d03.status, None, "the continued partial is now complete");
    assert_eq!(d03.session_id.as_deref(), Some(b1.session_id.as_str()));
    assert_ne!(
        after_continue.cursor.next_session, b1.session_id,
        "completing the continued partial must advance the cursor"
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn two_sessions_on_one_date_stay_separate() {
    let root = temp_repo("ios-sameday");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    // Complete a1 on 06-10.
    let repo = read_training_repo(&root).unwrap();
    let s0 = read_state(&root).unwrap();
    let a1 = render_next(&repo.compiled, &s0).unwrap();
    let mut a1_in = synthetic_execution_input(&a1, "pass", 0);
    a1_in.started_at = Some("2026-06-10T09:00:00Z".into());
    a1_in.completed_at = Some("2026-06-10T10:00:00Z".into());
    ffi_submit(&root, &a1, &a1_in, "2026-06-10");

    // Complete the next session (b1) on the same date.
    let s1 = read_state(&root).unwrap();
    let b1 = render_next(&repo.compiled, &s1).unwrap();
    let mut b1_in = synthetic_execution_input(&b1, "pass", 0);
    b1_in.started_at = Some("2026-06-10T17:00:00Z".into());
    b1_in.completed_at = Some("2026-06-10T18:00:00Z".into());
    ffi_submit(&root, &b1, &b1_in, "2026-06-10");

    let days = read_records(&root).unwrap();
    assert_eq!(days.len(), 2, "two sessions on one date must both be kept");
    let sessions: std::collections::BTreeSet<_> =
        days.iter().filter_map(|d| d.session_id.clone()).collect();
    assert_eq!(
        sessions,
        [a1.session_id.clone(), b1.session_id.clone()]
            .into_iter()
            .collect()
    );

    let _ = std::fs::remove_dir_all(&root);
}
