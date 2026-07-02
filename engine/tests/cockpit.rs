//! RFC-0001 Tranche 1: display labels, suggested dates, reschedule, deload,
//! and guided quick edits, exercised end-to-end against a real repo directory.

use std::fs;

use knurled_core::{
    DeloadScope, PlanEdit, RecordKind, SubmitMode, TrainingRecord, ValidationStatus,
    apply_plan_edit, build_repo, init_training_repo, read_records, read_state, read_training_repo,
    render_next, submit_repo, suggest_program_adjustments, synthetic_execution_input,
    write_training_record,
};

fn temp_dir(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("knurled-cockpit-{name}-{}", std::process::id()))
}

fn fresh_repo(name: &str) -> std::path::PathBuf {
    let dir = temp_dir(name);
    let _ = fs::remove_dir_all(&dir);
    init_training_repo(&dir, "gzcl.gzclp@1.0.0").unwrap();
    dir
}

fn workout(id: &str, date: &str) -> TrainingRecord {
    TrainingRecord::workout(
        id,
        date,
        "a1",
        format!("{date}T10:00:00Z"),
        vec![knurled_core::LiftRecord::new(
            "squat-1",
            "squat",
            "80kg",
            vec![5, 5, 5],
        )],
    )
}

// --- D3: display labels ------------------------------------------------------

#[test]
fn rendered_items_carry_labels_and_template_groups() {
    let dir = fresh_repo("labels");
    let outputs = build_repo(&dir, false).unwrap();
    let next = outputs.next_workout.unwrap();

    let squat = next
        .items
        .iter()
        .find(|item| item.progression_lane == "squat.t1")
        .unwrap();
    assert_eq!(squat.display.label, "Squat");
    assert_eq!(squat.display.group.as_deref(), Some("Main lift"));

    let bench = next
        .items
        .iter()
        .find(|item| item.progression_lane == "bench.t2")
        .unwrap();
    assert_eq!(bench.display.group.as_deref(), Some("Supplemental"));

    let accessory = next
        .items
        .iter()
        .find(|item| item.progression_lane == "lat_pulldown.t3")
        .unwrap();
    assert_eq!(accessory.display.label, "Lat Pulldown");
    assert_eq!(accessory.display.group.as_deref(), Some("Accessory"));

    let description = next.display_description.unwrap();
    assert!(description.contains("Squat"));
    assert!(description.contains("Lat Pulldown"));

    let _ = fs::remove_dir_all(&dir);
}

// --- D9: stale reason + user messages ----------------------------------------

#[test]
fn invalid_plan_reports_stale_reason_with_user_copy() {
    let dir = fresh_repo("stale");
    let plan_path = dir.join("programs/my-gzclp/plan.fitspec");
    let plan = fs::read_to_string(&plan_path).unwrap();
    fs::write(&plan_path, plan.replace("squat \"80kg\"\n", "")).unwrap();

    let outputs = build_repo(&dir, false).unwrap();
    assert_eq!(outputs.validation.status, ValidationStatus::Invalid);
    assert!(outputs.next_workout.is_none());
    let reason = outputs.stale_reason.unwrap();
    assert!(
        reason.contains("Squat"),
        "stale reason should name the lift: {reason}"
    );
    let error = &outputs.validation.errors[0];
    assert_eq!(error.code, "missing_custom_start");
    assert!(error.user_message.contains("starting weight"));

    let _ = fs::remove_dir_all(&dir);
}

// --- D4: suggested dates ------------------------------------------------------

#[test]
fn suggested_date_follows_the_training_days_after_the_last_workout() {
    let dir = fresh_repo("dates");
    let fresh = build_repo(&dir, true).unwrap();
    assert_eq!(
        fresh.next_workout.unwrap().suggested_date,
        None,
        "no records yet — nothing to anchor to"
    );

    // 2026-06-29 is a Monday; mon/wed/fri means Wednesday is next.
    write_training_record(&dir, workout("w1", "2026-06-29")).unwrap();
    let outputs = build_repo(&dir, true).unwrap();
    assert_eq!(
        outputs.next_workout.unwrap().suggested_date.as_deref(),
        Some("2026-07-01")
    );
    let generated = fs::read_to_string(dir.join("build/next-workout.json")).unwrap();
    assert!(generated.contains("\"suggested_date\": \"2026-07-01\""));

    let _ = fs::remove_dir_all(&dir);
}

// --- D5: reschedule -----------------------------------------------------------

#[test]
fn reschedule_pins_the_next_workout_date_and_writes_a_marker() {
    let dir = fresh_repo("reschedule");
    write_training_record(&dir, workout("w1", "2026-06-29")).unwrap();

    let outcome = apply_plan_edit(
        &dir,
        PlanEdit::Reschedule {
            to_date: "2026-07-04".into(),
            note: Some("travelling".into()),
        },
    )
    .unwrap();

    assert!(outcome.applied);
    assert_eq!(
        outcome
            .outputs
            .next_workout
            .unwrap()
            .suggested_date
            .as_deref(),
        Some("2026-07-04")
    );
    let records = read_records(&dir).unwrap();
    let marker = records
        .iter()
        .find(|record| record.kind == RecordKind::Reschedule)
        .unwrap();
    assert_eq!(marker.date, "2026-07-04");
    assert_eq!(marker.note.as_deref(), Some("travelling"));

    // The cursor never moved: rescheduling changes when, not what.
    let state = read_state(&dir).unwrap();
    assert_eq!(state.cursor.next_session, "a1");

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn reschedule_rejects_a_bad_date() {
    let dir = fresh_repo("reschedule-bad");
    let result = apply_plan_edit(
        &dir,
        PlanEdit::Reschedule {
            to_date: "next tuesday".into(),
            note: None,
        },
    );
    assert!(result.is_err());
    let _ = fs::remove_dir_all(&dir);
}

// --- D6: deload ----------------------------------------------------------------

#[test]
fn deload_rewrites_lane_baselines_and_writes_a_marker() {
    let dir = fresh_repo("deload");
    let before = read_state(&dir).unwrap();
    assert_eq!(before.lanes["squat.t1"].load.as_deref(), Some("80kg"));

    let outcome = apply_plan_edit(
        &dir,
        PlanEdit::Deload {
            percent: 10,
            scope: DeloadScope::All,
            date: "2026-07-02".into(),
            note: Some("feeling beat up".into()),
        },
    )
    .unwrap();
    assert!(outcome.applied);

    let state = read_state(&dir).unwrap();
    assert_eq!(state.lanes["squat.t1"].load.as_deref(), Some("72.5kg"));
    assert_eq!(state.lanes["bench.t2"].load.as_deref(), Some("40kg"));

    let marker = read_records(&dir)
        .unwrap()
        .into_iter()
        .find(|record| record.kind == RecordKind::Deload)
        .unwrap();
    assert!(marker.note.as_deref().unwrap().contains("10%"));
    assert!(marker.note.as_deref().unwrap().contains("feeling beat up"));

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn deload_scoped_to_lanes_leaves_others_alone() {
    let dir = fresh_repo("deload-scope");
    apply_plan_edit(
        &dir,
        PlanEdit::Deload {
            percent: 10,
            scope: DeloadScope::Lanes(vec!["squat.t1".into()]),
            date: "2026-07-02".into(),
            note: None,
        },
    )
    .unwrap();
    let state = read_state(&dir).unwrap();
    assert_eq!(state.lanes["squat.t1"].load.as_deref(), Some("72.5kg"));
    assert_eq!(state.lanes["bench.t1"].load.as_deref(), Some("55kg"));

    let unknown = apply_plan_edit(
        &dir,
        PlanEdit::Deload {
            percent: 10,
            scope: DeloadScope::Lanes(vec!["nope.t9".into()]),
            date: "2026-07-02".into(),
            note: None,
        },
    );
    assert!(unknown.is_err());

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn eight_training_weeks_without_a_deload_suggests_one() {
    let dir = fresh_repo("deload-suggest");
    // Two workouts per week for eight distinct weeks starting Monday 2026-01-05.
    let mondays = [
        "2026-01-05",
        "2026-01-12",
        "2026-01-19",
        "2026-01-26",
        "2026-02-02",
        "2026-02-09",
        "2026-02-16",
        "2026-02-23",
    ];
    for (week, monday) in mondays.iter().enumerate() {
        write_training_record(&dir, workout(&format!("w{week}"), monday)).unwrap();
    }
    let suggestions = suggest_program_adjustments(&dir).unwrap();
    let nudge = suggestions
        .iter()
        .find(|suggestion| suggestion.kind == "deload_week")
        .expect("expected a deload_week suggestion");
    assert!(nudge.user_description.contains("8 weeks"));

    // Applying a deload resets the clock.
    apply_plan_edit(
        &dir,
        PlanEdit::Deload {
            percent: 10,
            scope: DeloadScope::All,
            date: "2026-02-24".into(),
            note: None,
        },
    )
    .unwrap();
    let suggestions = suggest_program_adjustments(&dir).unwrap();
    assert!(
        !suggestions
            .iter()
            .any(|suggestion| suggestion.kind == "deload_week")
    );

    let _ = fs::remove_dir_all(&dir);
}

// --- D10: guided quick edits ----------------------------------------------------

#[test]
fn swap_exercise_writes_a_managed_patch_and_swapping_back_removes_it() {
    let dir = fresh_repo("swap");
    let outcome = apply_plan_edit(
        &dir,
        PlanEdit::SwapExercise {
            lane: "squat.t1".into(),
            to_exercise: "front squat".into(),
        },
    )
    .unwrap();
    assert!(outcome.applied);

    let patch_path = dir.join("programs/my-gzclp/patches/swap-squat-t1.fitspec");
    assert!(patch_path.exists());
    let next = outcome.outputs.next_workout.unwrap();
    let item = next
        .items
        .iter()
        .find(|item| item.progression_lane == "squat.t1")
        .unwrap();
    assert_eq!(item.exercise, "front_squat");
    assert_eq!(item.display.label, "Front Squat");

    // The T2 squat lane is untouched — the patch is pinned to one lane.
    let repo = read_training_repo(&dir).unwrap();
    let state = read_state(&dir).unwrap();
    let mut scratch = state.clone();
    scratch.cursor.next_session = "a2".into();
    let a2 = render_next(&repo.compiled, &scratch).unwrap();
    let t2 = a2
        .items
        .iter()
        .find(|item| item.progression_lane == "squat.t2")
        .unwrap();
    assert_eq!(t2.exercise, "squat");

    let back = apply_plan_edit(
        &dir,
        PlanEdit::SwapExercise {
            lane: "squat.t1".into(),
            to_exercise: "squat".into(),
        },
    )
    .unwrap();
    assert!(back.applied);
    assert!(!patch_path.exists());

    let unknown = apply_plan_edit(
        &dir,
        PlanEdit::SwapExercise {
            lane: "nope.t9".into(),
            to_exercise: "front squat".into(),
        },
    );
    assert!(unknown.is_err());

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn temporary_load_adjust_scales_prescriptions_but_not_state() {
    let dir = fresh_repo("tmp-load");
    let outcome = apply_plan_edit(
        &dir,
        PlanEdit::TemporaryLoadAdjust {
            lane: "squat.t1".into(),
            percent: -10,
            until: Some("2026-07-10".into()),
        },
    )
    .unwrap();
    assert!(outcome.applied);

    let next = outcome.outputs.next_workout.unwrap();
    let squat = next
        .items
        .iter()
        .find(|item| item.progression_lane == "squat.t1")
        .unwrap();
    // 80kg −10% snaps to 72.5 on the default 2.5 grid.
    assert_eq!(squat.prescription.sets[0].load.as_deref(), Some("72.5kg"));
    // Progression preview still computes from the untouched baseline.
    let pass = squat
        .effect_preview
        .pass
        .iter()
        .find(|effect| effect.op == "increase_load")
        .unwrap();
    assert_eq!(pass.from.as_deref(), Some("80kg"));
    assert_eq!(
        read_state(&dir).unwrap().lanes["squat.t1"].load.as_deref(),
        Some("80kg")
    );

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn expired_temporary_changes_are_pruned_at_the_next_submit() {
    let dir = fresh_repo("expiry");
    apply_plan_edit(
        &dir,
        PlanEdit::TemporaryLoadAdjust {
            lane: "squat.t1".into(),
            percent: -10,
            until: Some("2026-07-03".into()),
        },
    )
    .unwrap();
    let patch_path = dir.join("programs/my-gzclp/patches/tmp-load-squat-t1.fitspec");
    assert!(patch_path.exists());

    // A submit on the expiry date keeps the patch…
    let repo = read_training_repo(&dir).unwrap();
    let state = read_state(&dir).unwrap();
    let rendered = render_next(&repo.compiled, &state).unwrap();
    let input = synthetic_execution_input(&rendered, "all-pass", 0);
    submit_repo(&dir, &input, SubmitMode::Advance, "2026-07-03").unwrap();
    assert!(patch_path.exists());

    // …and the first submit after it removes it.
    let repo = read_training_repo(&dir).unwrap();
    let state = read_state(&dir).unwrap();
    let rendered = render_next(&repo.compiled, &state).unwrap();
    let input = synthetic_execution_input(&rendered, "all-pass", 1);
    let outcome = submit_repo(&dir, &input, SubmitMode::Advance, "2026-07-06").unwrap();
    assert!(!patch_path.exists());
    assert!(
        outcome
            .changed_files
            .iter()
            .any(|path| path.contains("tmp-load-squat-t1"))
    );

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn deload_removes_the_temporary_load_overlay_on_affected_lanes() {
    let dir = fresh_repo("no-stacking");
    apply_plan_edit(
        &dir,
        PlanEdit::TemporaryLoadAdjust {
            lane: "squat.t1".into(),
            percent: -10,
            until: None,
        },
    )
    .unwrap();
    let patch_path = dir.join("programs/my-gzclp/patches/tmp-load-squat-t1.fitspec");
    assert!(patch_path.exists());

    let outcome = apply_plan_edit(
        &dir,
        PlanEdit::Deload {
            percent: 10,
            scope: DeloadScope::All,
            date: "2026-07-02".into(),
            note: None,
        },
    )
    .unwrap();
    assert!(outcome.applied);
    assert!(
        !patch_path.exists(),
        "deload must remove the overlay so they never chain"
    );
    let next = outcome.outputs.next_workout.unwrap();
    let squat = next
        .items
        .iter()
        .find(|item| item.progression_lane == "squat.t1")
        .unwrap();
    // Deloaded baseline only — not deload × overlay.
    assert_eq!(squat.prescription.sets[0].load.as_deref(), Some("72.5kg"));

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn temporary_swap_expires_like_any_temporary_change() {
    let dir = fresh_repo("tmp-swap");
    let outcome = apply_plan_edit(
        &dir,
        PlanEdit::TemporarySwap {
            lane: "press.t1".into(),
            to_exercise: "landmine press".into(),
            until: Some("2026-07-03".into()),
        },
    )
    .unwrap();
    assert!(outcome.applied);
    let patch_path = dir.join("programs/my-gzclp/patches/tmp-swap-press-t1.fitspec");
    let text = fs::read_to_string(&patch_path).unwrap();
    assert!(text.contains("expires \"2026-07-03\""));
    assert!(text.contains("replace-exercise from=press to=landmine_press"));

    let _ = fs::remove_dir_all(&dir);
}
