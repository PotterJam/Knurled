//! End-to-end on-disk flow for the ADR 0007 logs-as-record model: submit a
//! session, then read state + record + backtest back off disk.

use std::time::{SystemTime, UNIX_EPOCH};

use knurled_core::session::SubmitMode;
use knurled_core::{
    ActualSet, AmendRecordRequest, ExecutionInput, ItemInput, RecordAmendment, SCHEMA_VERSION,
    ValidationStatus, active_program_dir, amend_training_record, backtest_records_repo,
    init_training_repo, merge_training_records, read_records, read_state, read_training_repo,
    render_next, render_session, submit_rendered_repo, submit_repo, synthetic_execution_input,
};
use std::collections::BTreeMap;

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
fn two_workouts_on_the_same_date_are_both_recorded() {
    let root = temp_repo("same-day-records");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    for index in 0..2 {
        let repo = read_training_repo(&root).unwrap();
        let state = read_state(&root).unwrap();
        let rendered = render_next(&repo.compiled, &state).unwrap();
        let input = synthetic_execution_input(&rendered, "pass", index);
        let outcome = submit_repo(&root, &input, SubmitMode::Advance, "2026-06-24").unwrap();
        assert_eq!(outcome.validation.status, ValidationStatus::Valid);
    }

    let records = read_records(&root).unwrap();
    assert_eq!(records.len(), 2);
    assert!(records.iter().all(|record| record.date == "2026-06-24"));

    let projection = backtest_records_repo(&root).unwrap();
    assert_eq!(projection.sessions_replayed, 2);

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn retrying_a_completed_attempt_is_idempotent() {
    let root = temp_repo("idempotent-submit");
    init_training_repo(&root, "gzcl.gzclp").unwrap();
    let repo = read_training_repo(&root).unwrap();
    let state = read_state(&root).unwrap();
    let rendered = render_next(&repo.compiled, &state).unwrap();
    let input = synthetic_execution_input(&rendered, "pass", 0);

    submit_rendered_repo(&root, &rendered, &input, SubmitMode::Advance, "2026-06-24").unwrap();
    let state_after_first = read_state(&root).unwrap();
    let retry =
        submit_rendered_repo(&root, &rendered, &input, SubmitMode::Advance, "2026-06-24").unwrap();

    assert_eq!(read_records(&root).unwrap().len(), 1);
    assert_eq!(read_state(&root).unwrap(), state_after_first);
    assert!(retry.changed_files.is_empty());

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn record_merge_unions_same_day_ids_and_rejects_equal_revision_conflicts() {
    let root = temp_repo("merge-records");
    init_training_repo(&root, "gzcl.gzclp").unwrap();
    for index in 0..2 {
        let repo = read_training_repo(&root).unwrap();
        let state = read_state(&root).unwrap();
        let rendered = render_next(&repo.compiled, &state).unwrap();
        let input = synthetic_execution_input(&rendered, "pass", index);
        submit_repo(&root, &input, SubmitMode::Advance, "2026-06-24").unwrap();
    }
    let records = read_records(&root).unwrap();
    assert_eq!(
        merge_training_records(vec![records[0].clone()], vec![records[1].clone()])
            .unwrap()
            .len(),
        2
    );

    let mut conflicting = records[0].clone();
    conflicting.note = Some("different edit".into());
    assert!(merge_training_records(vec![records[0].clone()], vec![conflicting]).is_err());

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn completed_workout_amendments_recompute_latest_lanes() {
    let root = temp_repo("amend-record");
    init_training_repo(&root, "gzcl.gzclp").unwrap();
    let repo = read_training_repo(&root).unwrap();
    let state = read_state(&root).unwrap();
    let rendered = render_next(&repo.compiled, &state).unwrap();
    let input = synthetic_execution_input(&rendered, "pass", 0);
    submit_repo(&root, &input, SubmitMode::Advance, "2026-06-24").unwrap();

    let state_path = active_program_dir(&root)
        .unwrap()
        .join("state/current.json");
    let state_before = std::fs::read(&state_path).unwrap();
    let records = read_records(&root).unwrap();
    let record = &records[0];
    let lift = &record.lifts[0];

    let added_set = amend_training_record(
        &root,
        AmendRecordRequest {
            record_id: record.id.clone(),
            expected_revision: 1,
            updated_at: "2026-06-24T18:00:00Z".into(),
            amendment: RecordAmendment::AddSet {
                lift_id: lift.lift_id.clone(),
                load: lift.weight.clone(),
                reps: 8,
                metrics: BTreeMap::from([("rpe".into(), "9".into())]),
            },
        },
    )
    .unwrap();
    assert_eq!(added_set.record.revision, 2);
    assert_eq!(
        added_set.changed_files,
        vec![
            "logs/2026/06.json".to_owned(),
            active_program_dir(&root)
                .unwrap()
                .strip_prefix(&root)
                .unwrap()
                .join("state/current.json")
                .to_string_lossy()
                .into_owned(),
        ]
    );
    assert!(!added_set.recomputed_lanes.is_empty());

    let added_exercise = amend_training_record(
        &root,
        AmendRecordRequest {
            record_id: record.id.clone(),
            expected_revision: 2,
            updated_at: "2026-06-24T18:05:00Z".into(),
            amendment: RecordAmendment::AddExercise {
                exercise: "curl".into(),
                weight: Some("20kg".into()),
                note: Some("forgotten finisher".into()),
                sets: vec![
                    ActualSet {
                        set: 1,
                        load: Some("20kg".into()),
                        reps: 12,
                        metrics: BTreeMap::new(),
                    },
                    ActualSet {
                        set: 2,
                        load: Some("20kg".into()),
                        reps: 12,
                        metrics: BTreeMap::new(),
                    },
                ],
            },
        },
    )
    .unwrap();

    assert_eq!(added_exercise.record.revision, 3);
    assert_eq!(added_exercise.record.lifts.last().unwrap().exercise, "curl");
    assert_eq!(std::fs::read(&state_path).unwrap(), state_before);

    let log_before_conflict = std::fs::read(root.join("logs/2026/06.json")).unwrap();
    let conflict = amend_training_record(
        &root,
        AmendRecordRequest {
            record_id: record.id.clone(),
            expected_revision: 1,
            updated_at: "2026-06-24T18:10:00Z".into(),
            amendment: RecordAmendment::AddSet {
                lift_id: lift.lift_id.clone(),
                load: lift.weight.clone(),
                reps: 5,
                metrics: BTreeMap::new(),
            },
        },
    );
    assert!(conflict.is_err());
    assert_eq!(
        std::fs::read(root.join("logs/2026/06.json")).unwrap(),
        log_before_conflict
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn replacing_latest_record_recomputes_each_owned_lane() {
    let root = temp_repo("edit-latest-record");
    init_training_repo(&root, "gzcl.gzclp").unwrap();
    let repo = read_training_repo(&root).unwrap();
    let rendered = render_next(&repo.compiled, &read_state(&root).unwrap()).unwrap();
    let input = synthetic_execution_input(&rendered, "pass", 0);
    submit_repo(&root, &input, SubmitMode::Advance, "2026-06-24").unwrap();

    let record = read_records(&root).unwrap().remove(0);
    let mut lifts = record.lifts.clone();
    let squat = lifts
        .iter_mut()
        .find(|lift| lift.item_id.as_deref() == Some("a1.t1"))
        .unwrap();
    *squat.sets.last_mut().unwrap() = 0;
    let outcome = amend_training_record(
        &root,
        AmendRecordRequest {
            record_id: record.id,
            expected_revision: record.revision,
            updated_at: "2026-06-24T18:00:00Z".into(),
            amendment: RecordAmendment::ReplaceLifts { lifts },
        },
    )
    .unwrap();

    assert!(outcome.recomputed_lanes.contains(&"squat.t1".into()));
    let lane = &read_state(&root).unwrap().lanes["squat.t1"];
    assert_eq!(lane.load.as_deref(), Some("80kg"));
    assert_eq!(lane.stage.as_deref(), Some("6x2+"));
    assert_eq!(read_records(&root).unwrap()[0].revision, 2);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn replacing_superseded_record_is_history_only_per_lane() {
    let root = temp_repo("edit-superseded-record");
    init_training_repo(&root, "gzcl.gzclp").unwrap();

    let repo = read_training_repo(&root).unwrap();
    let first_rendered = render_next(&repo.compiled, &read_state(&root).unwrap()).unwrap();
    let first_input = synthetic_execution_input(&first_rendered, "pass", 0);
    submit_repo(&root, &first_input, SubmitMode::Advance, "2026-06-20").unwrap();
    let first = read_records(&root).unwrap().remove(0);

    // Continue until a later A1 owns squat.t1's one-step checkpoint.
    for index in 1..=4 {
        let repo = read_training_repo(&root).unwrap();
        let rendered = render_next(&repo.compiled, &read_state(&root).unwrap()).unwrap();
        let input = synthetic_execution_input(&rendered, "pass", index);
        submit_repo(&root, &input, SubmitMode::Advance, "2026-06-21").unwrap();
    }
    let state_before = read_state(&root).unwrap();
    assert_ne!(state_before.previous_lanes["squat.t1"].record_id, first.id);

    let mut lifts = first.lifts.clone();
    let squat = lifts
        .iter_mut()
        .find(|lift| lift.item_id.as_deref() == Some("a1.t1"))
        .unwrap();
    *squat.sets.last_mut().unwrap() = 0;
    let outcome = amend_training_record(
        &root,
        AmendRecordRequest {
            record_id: first.id,
            expected_revision: first.revision,
            updated_at: "2026-06-28T18:00:00Z".into(),
            amendment: RecordAmendment::ReplaceLifts { lifts },
        },
    )
    .unwrap();

    assert!(!outcome.recomputed_lanes.contains(&"squat.t1".into()));
    assert_eq!(read_state(&root).unwrap(), state_before);
    let _ = std::fs::remove_dir_all(&root);
}

/// Saving a partial then finishing the session fresh on a later date (rather
/// rather than resuming the same attempt must not leave the
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
    submit_rendered_repo(
        &root,
        &rendered,
        &complete,
        SubmitMode::Advance,
        "2026-06-26",
    )
    .unwrap();

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
