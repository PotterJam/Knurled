//! End-to-end on-disk flow for the ADR 0007 logs-as-record model: submit a
//! session, then read state + record + backtest back off disk.

use std::time::{SystemTime, UNIX_EPOCH};

use knurled_core::session::{SubmitMode, submit_session};
use knurled_core::{
    ActualSet, ExecutionInput, ItemInput, SCHEMA_VERSION, ValidationStatus, append_day_record,
    backtest_records_repo, clear_partials_for_session, init_training_repo, read_records, read_state,
    read_training_repo, render_next, render_session, submit_repo, synthetic_execution_input,
    write_state,
};

fn temp_repo(name: &str) -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("knurled-{name}-{nanos}"))
}

#[test]
fn submit_writes_state_and_record_then_backtest_reads_them() {
    let root = temp_repo("record-flow");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    // Build a passing input against the current next workout.
    let repo = read_training_repo(&root).unwrap();
    let state_before = read_state(&root).unwrap();
    let rendered = render_next(&repo.compiled, &state_before).unwrap();
    let input = synthetic_execution_input(&rendered, "pass", 0);

    let outcome = submit_repo(&root, &input, SubmitMode::Advance, "2026-06-24").unwrap();
    assert_eq!(outcome.validation.status, ValidationStatus::Valid);

    // state/current.json is the source of truth and advanced.
    let state_after = read_state(&root).unwrap();
    assert_ne!(state_after.lanes, state_before.lanes);
    assert_eq!(state_after, outcome.new_state);

    // The lean record landed at logs/2026/06.json with the day's lifts.
    assert!(root.join("logs/2026/06.json").exists());
    let days = read_records(&root).unwrap();
    assert_eq!(days.len(), 1);
    assert_eq!(days[0].date, "2026-06-24");
    assert!(!days[0].lifts.is_empty());

    // Backtesting the plan over the record reproduces the live lanes.
    let projection = backtest_records_repo(&root).unwrap();
    assert_eq!(projection.sessions_replayed, 1);
    assert_eq!(projection.final_state.lanes, state_after.lanes);

    let _ = std::fs::remove_dir_all(&root);
}

/// Saving a partial then finishing the session fresh on a later date (rather
/// than resuming the partial, which upserts the same date) must not leave the
/// old partial behind as a resumable "Continue" entry.
#[test]
fn completing_a_session_clears_an_outstanding_partial() {
    let root = temp_repo("clear-partial");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    let repo = read_training_repo(&root).unwrap();
    let state = read_state(&root).unwrap();
    let rendered = render_next(&repo.compiled, &state).unwrap();
    let session_id = rendered.session_id.clone();

    // Save a partial: log just the first item's first set.
    let first = &rendered.items[0];
    let partial = ExecutionInput {
        kind: "execution_input".into(),
        schema_version: SCHEMA_VERSION.into(),
        rendered_session_hash: rendered.rendered_session_hash.clone(),
        status: "partial".into(),
        started_at: Some("2026-06-24T10:00:00Z".into()),
        completed_at: None,
        saved_at: Some("2026-06-24T10:30:00Z".into()),
        inputs: vec![ItemInput {
            item_id: first.item_id.clone(),
            mode: "per_set_reps".into(),
            final_set_reps: None,
            sets: vec![ActualSet {
                set: 1,
                load: first.prescription.sets[0].load.clone(),
                reps: first.prescription.sets[0].target_reps,
                metrics: Default::default(),
            }],
            load: None,
            performed_exercise: None,
            swap_reason: None,
            swap_policy: None,
        }],
    };
    submit_repo(&root, &partial, SubmitMode::Advance, "2026-06-24").unwrap();
    let after_partial = read_records(&root).unwrap();
    assert_eq!(after_partial.len(), 1);
    assert_eq!(after_partial[0].status.as_deref(), Some("partial"));
    // The partial moved the cursor on to the next workout, but stays resumable.
    assert_ne!(
        read_state(&root).unwrap().cursor.next_session,
        session_id,
        "a partial save advances the cursor"
    );

    // Resume the saved partial from history — rendered by its session id, not the
    // cursor (the app submits this captured session via the FFI) — and finish it
    // fresh on a later date.
    let state = read_state(&root).unwrap();
    let rendered = render_session(&repo.compiled, &state, &session_id).unwrap();
    assert_eq!(rendered.session_id, session_id);
    let complete = synthetic_execution_input(&rendered, "pass", 0);
    let outcome =
        submit_session(&repo.compiled, &state, &rendered, &complete, SubmitMode::Advance, "2026-06-26")
            .unwrap();
    write_state(&root, &outcome.new_state).unwrap();
    append_day_record(&root, outcome.record_day.clone()).unwrap();
    clear_partials_for_session(&root, &rendered.session_id).unwrap();

    // The zombie partial is gone: only the completed day remains.
    let records = read_records(&root).unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].date, "2026-06-26");
    assert_eq!(records[0].status, None);

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn off_day_records_without_moving_lanes() {
    let root = temp_repo("record-flow-offday");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    let repo = read_training_repo(&root).unwrap();
    let state_before = read_state(&root).unwrap();
    let rendered = render_next(&repo.compiled, &state_before).unwrap();
    let input = synthetic_execution_input(&rendered, "pass", 0);

    submit_repo(&root, &input, SubmitMode::OffDay, "2026-06-24").unwrap();

    let state_after = read_state(&root).unwrap();
    // Lanes (targets/stages/fails) unchanged; the day is still recorded.
    assert_eq!(state_after.lanes, state_before.lanes);
    assert_eq!(read_records(&root).unwrap().len(), 1);

    let _ = std::fs::remove_dir_all(&root);
}
