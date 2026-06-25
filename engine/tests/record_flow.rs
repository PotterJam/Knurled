//! End-to-end on-disk flow for the ADR 0007 logs-as-record model: submit a
//! session, then read state + record + backtest back off disk.

use std::time::{SystemTime, UNIX_EPOCH};

use knurled_core::session::SubmitMode;
use knurled_core::{
    ValidationStatus, backtest_records_repo, init_training_repo, read_records, read_state,
    read_training_repo, render_next, submit_repo, synthetic_execution_input,
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
