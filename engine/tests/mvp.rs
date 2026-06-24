use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use knurled_core::{
    CorrectionChange, Effect, HistoryImportOptions, PatchFile, PlanChangeRef, RestSource,
    StateChange, TrainingEvent, build_outputs, compile_plan, create_initial_state,
    history_import_events_from_str, import_history_repo, init_training_repo, reduce_input,
    render_lockfile, render_next, replay_events, simulate, synthetic_execution_input,
};
use serde_json::json;

fn gzclp_plan() -> String {
    r#"plan "James GZCLP" {
  template "gzcl.gzclp@1.0.0"
  units kg

  schedule next_workout {
    rotation A1 B1 A2 B2
    suggested_days mon wed fri
  }

  starts {
    squat "80kg"
    bench "55kg"
    press "37.5kg"
    deadlift "100kg"
  }

  accessories {
    A1.T3 lat_pulldown
    B1.T3 barbell_row
    A2.T3 lat_pulldown
    B2.T3 barbell_row
  }
}
"#
    .into()
}

fn compiled_gzclp() -> knurled_core::CompiledPlan {
    let lock = render_lockfile("gzcl.gzclp@1.0.0").unwrap();
    compile_plan(&gzclp_plan(), &lock, &[]).unwrap()
}

fn starting_strength_plan(template: &str) -> String {
    format!(
        r#"plan "Starting Strength" {{
  template "{template}"
  units kg

  schedule next_workout {{
    suggested_days mon wed fri
  }}

  starts {{
    squat "60kg"
    press "30kg"
    bench "40kg"
    deadlift "80kg"
    power_clean "40kg"
  }}
}}
"#
    )
}

fn compiled_starting_strength(template: &str) -> knurled_core::CompiledPlan {
    let lock = render_lockfile(template).unwrap();
    compile_plan(&starting_strength_plan(template), &lock, &[]).unwrap()
}

#[test]
fn gzclp_t1_pass_increases_load_and_keeps_stage() {
    let compiled = compiled_gzclp();
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 0);
    input
        .inputs
        .iter_mut()
        .find(|item| item.item_id == "a1.t1")
        .unwrap()
        .final_set_reps = Some(7);

    let result = reduce_input(&compiled, &state, &rendered, &input).unwrap();
    let squat = &result.new_state.lanes["squat.t1"];

    assert_eq!(squat.load.as_deref(), Some("82.5kg"));
    assert_eq!(squat.stage.as_deref(), Some("5x3+"));
    assert_eq!(
        result
            .event
            .unwrap()
            .results
            .iter()
            .find(|item| item.slot_id == "a1.t1")
            .unwrap()
            .outcome,
        "pass"
    );
}

#[test]
fn gzclp_t1_fail_advances_stage_without_increasing_load() {
    let compiled = compiled_gzclp();
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 0);
    input
        .inputs
        .iter_mut()
        .find(|item| item.item_id == "a1.t1")
        .unwrap()
        .final_set_reps = Some(2);

    let result = reduce_input(&compiled, &state, &rendered, &input).unwrap();
    let squat = &result.new_state.lanes["squat.t1"];

    assert_eq!(squat.load.as_deref(), Some("80kg"));
    assert_eq!(squat.stage.as_deref(), Some("6x2+"));
}

#[test]
fn gzclp_t2_fail_advances_rep_stage() {
    let compiled = compiled_gzclp();
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 0);
    let t2 = input
        .inputs
        .iter_mut()
        .find(|item| item.item_id == "a1.t2")
        .unwrap();
    t2.sets = vec![
        actual(1, "45kg", 10),
        actual(2, "45kg", 10),
        actual(3, "45kg", 8),
    ];

    let result = reduce_input(&compiled, &state, &rendered, &input).unwrap();
    assert_eq!(
        result.new_state.lanes["bench.t2"].stage.as_deref(),
        Some("3x8")
    );
}

#[test]
fn adjusted_today_does_not_progress_future_lane() {
    let compiled = compiled_gzclp();
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 0);
    let t1 = input
        .inputs
        .iter_mut()
        .find(|item| item.item_id == "a1.t1")
        .unwrap();
    t1.load = Some("77.5kg".into());
    t1.final_set_reps = Some(7);

    let result = reduce_input(&compiled, &state, &rendered, &input).unwrap();

    assert_eq!(
        result.new_state.lanes["squat.t1"].load.as_deref(),
        Some("80kg")
    );
    assert_eq!(
        result.event.unwrap().results[0].outcome,
        "adjusted_today",
        "bad-day load changes are logged without silently rewriting future state"
    );
}

#[test]
fn gzclp_accessory_start_seeds_t3_lane() {
    let plan = gzclp_plan().replace(
        "    deadlift \"100kg\"\n",
        "    deadlift \"100kg\"\n    lat_pulldown \"40kg\"\n",
    );
    let lock = render_lockfile("gzcl.gzclp@1.0.0").unwrap();
    let compiled = compile_plan(&plan, &lock, &[]).unwrap();
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let t3 = rendered
        .items
        .iter()
        .find(|item| item.item_id == "a1.t3")
        .unwrap();

    assert_eq!(state.lanes["lat_pulldown.t3"].load.as_deref(), Some("40kg"));
    assert_eq!(t3.prescription.sets[0].load.as_deref(), Some("40kg"));
    assert_eq!(t3.effect_preview.pass[0].to.as_deref(), Some("42.5kg"));
}

#[test]
fn gzclp_first_accessory_attempt_sets_or_progresses_lane_load() {
    let compiled = compiled_gzclp();
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 0);
    let t3 = input
        .inputs
        .iter_mut()
        .find(|item| item.item_id == "a1.t3")
        .unwrap();
    t3.load = Some("40kg".into());
    t3.final_set_reps = Some(25);

    let result = reduce_input(&compiled, &state, &rendered, &input).unwrap();
    let event = result.event.unwrap();
    let t3_result = event
        .results
        .iter()
        .find(|item| item.slot_id == "a1.t3")
        .unwrap();

    assert_eq!(t3_result.outcome, "pass");
    assert_eq!(t3_result.effects[0].op, "increase_load");
    assert_eq!(t3_result.effects[0].from.as_deref(), Some("40kg"));
    assert_eq!(t3_result.effects[0].to.as_deref(), Some("42.5kg"));
    assert_eq!(
        result.new_state.lanes["lat_pulldown.t3"].load.as_deref(),
        Some("42.5kg")
    );

    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 0);
    let t3 = input
        .inputs
        .iter_mut()
        .find(|item| item.item_id == "a1.t3")
        .unwrap();
    t3.load = Some("40kg".into());
    t3.final_set_reps = Some(24);

    let result = reduce_input(&compiled, &state, &rendered, &input).unwrap();
    let event = result.event.unwrap();
    let t3_result = event
        .results
        .iter()
        .find(|item| item.slot_id == "a1.t3")
        .unwrap();

    assert_eq!(t3_result.outcome, "fail");
    assert_eq!(t3_result.effects[0].op, "set_load");
    assert_eq!(t3_result.effects[0].to.as_deref(), Some("40kg"));
    assert_eq!(
        result.new_state.lanes["lat_pulldown.t3"].load.as_deref(),
        Some("40kg")
    );
}

#[test]
fn patch_can_replace_exercise_without_changing_lane_identity() {
    let lock = render_lockfile("gzcl.gzclp@1.0.0").unwrap();
    let patch = PatchFile {
        filename: "patches/shoulder.fitspec".into(),
        text: r#"patch "shoulder" {
  replace-exercise from=press to=landmine_press lane="press.*"
}
"#
        .into(),
    };
    let compiled = compile_plan(&gzclp_plan(), &lock, &[patch]).unwrap();
    let mut state = create_initial_state(&compiled);
    state.cursor.next_session = "b1".into();

    let rendered = render_next(&compiled, &state).unwrap();
    let press = rendered
        .items
        .iter()
        .find(|item| item.slot_id == "b1.t1")
        .unwrap();

    assert_eq!(press.exercise, "landmine_press");
    assert_eq!(press.progression_lane, "press.t1");
}

#[test]
fn rest_policy_is_resolved_from_plan_overrides_before_template_defaults() {
    let plan = r#"plan "James GZCLP" {
  template "gzcl.gzclp@1.0.0"
  units kg

  schedule next_workout {
    rotation A1 B1 A2 B2
    suggested_days mon wed fri
  }

  starts {
    squat "80kg"
    bench "55kg"
    press "37.5kg"
    deadlift "100kg"
  }

  accessories {
    A1.T3 lat_pulldown
    B1.T3 barbell_row
    A2.T3 lat_pulldown
    B2.T3 barbell_row
  }

  rest {
    default 1 minute
    Tier T3 75 sec
    exercise bench 210 seconds
    lane squat.t1 "4m"
    slot A1.T2 5 min
  }
}
"#;
    let lock = render_lockfile("gzcl.gzclp@1.0.0").unwrap();
    let compiled = compile_plan(plan, &lock, &[]).unwrap();
    let rendered = render_next(&compiled, &create_initial_state(&compiled)).unwrap();

    assert_eq!(rendered.items[0].rest.seconds, 240);
    assert_eq!(rendered.items[0].rest.source, RestSource::PlanLane);
    assert_eq!(rendered.items[1].rest.seconds, 300);
    assert_eq!(rendered.items[1].rest.source, RestSource::PlanSlot);
    assert_eq!(rendered.items[2].rest.seconds, 75);
    assert_eq!(rendered.items[2].rest.source, RestSource::PlanTier);
}

#[test]
fn five_three_one_renders_week_one_percentages() {
    let plan = r#"plan "James 5/3/1" {
  template "531.beginners@1.0.0"
  units kg

  schedule next_workout {
    rotation squat_day bench_day deadlift_day press_day
    suggested_days mon wed fri sat
  }

  training_maxes {
    squat "90kg"
    bench "65kg"
    deadlift "110kg"
    press "42.5kg"
  }
}
"#;
    let lock = render_lockfile("531.beginners@1.0.0").unwrap();
    let compiled = compile_plan(plan, &lock, &[]).unwrap();
    let rendered = render_next(&compiled, &create_initial_state(&compiled)).unwrap();
    let sets = &rendered.items[0].prescription.sets;

    assert_eq!(
        sets.iter()
            .map(|set| (
                set.percentage.unwrap(),
                set.load.as_deref().unwrap(),
                set.target_reps,
                set.amrap
            ))
            .collect::<Vec<_>>(),
        vec![
            (65, "57.5kg", 5, false),
            (75, "67.5kg", 5, false),
            (85, "77.5kg", 5, true)
        ]
    );
}

#[test]
fn starting_strength_phase1_alternates_press_and_bench_with_deadlift_both_days() {
    let compiled = compiled_starting_strength("starting-strength.phase1@1.0.0");
    let rendered = render_next(&compiled, &create_initial_state(&compiled)).unwrap();

    assert_eq!(rendered.display_name, "Starting Strength Phase1 - Day A");
    assert_eq!(
        exercise_summary(&rendered),
        vec![("squat", 3, 5), ("press", 3, 5), ("deadlift", 1, 5)]
    );

    let state = replay_events(
        &compiled,
        &[TrainingEvent {
            id: "evt_skip_to_b".into(),
            kind: "session_skipped".into(),
            session_id: Some("a".into()),
            ..empty_event()
        }],
    );
    let rendered = render_next(&compiled, &state).unwrap();

    assert_eq!(
        rendered
            .items
            .iter()
            .map(|item| item.exercise.as_str())
            .collect::<Vec<_>>(),
        vec!["squat", "bench", "deadlift"]
    );
}

#[test]
fn starting_strength_phase2_replaces_day_b_deadlift_with_power_clean() {
    let compiled = compiled_starting_strength("starting-strength.phase2@1.0.0");
    let state = replay_events(
        &compiled,
        &[TrainingEvent {
            id: "evt_skip_to_b".into(),
            kind: "session_skipped".into(),
            session_id: Some("a".into()),
            ..empty_event()
        }],
    );
    let rendered = render_next(&compiled, &state).unwrap();

    assert_eq!(
        exercise_summary(&rendered),
        vec![("squat", 3, 5), ("bench", 3, 5), ("power_clean", 5, 3)]
    );
}

#[test]
fn starting_strength_phase3_rotates_deadlift_chins_clean_chins() {
    let compiled = compiled_starting_strength("starting-strength.phase3@1.0.0");
    let mut state = create_initial_state(&compiled);

    let first = render_next(&compiled, &state).unwrap();
    assert_eq!(first.session_id, "a_deadlift");
    assert_eq!(first.items[2].exercise, "deadlift");

    state.cursor.next_session = "b_chins_1".into();
    let second = render_next(&compiled, &state).unwrap();
    assert_eq!(second.items[2].exercise, "chin_up");
    assert_eq!(second.items[2].progression_lane, "chin_up.bodyweight");
    assert_eq!(second.items[2].rest.seconds, 120);
    assert_eq!(second.items[2].rest.source, RestSource::TemplateTier);
    assert!(second.items[2].effect_preview.pass.is_empty());

    state.cursor.next_session = "a_clean".into();
    let third = render_next(&compiled, &state).unwrap();
    assert_eq!(third.items[2].exercise, "power_clean");
    assert_eq!(third.items[2].prescription.sets.len(), 5);
}

#[test]
fn starting_strength_pass_linearly_increases_loaded_lifts_only() {
    let compiled = compiled_starting_strength("starting-strength.phase3@1.0.0");
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let input = synthetic_execution_input(&rendered, "all-pass", 0);

    let reduced = reduce_input(&compiled, &state, &rendered, &input).unwrap();

    assert_eq!(
        reduced.new_state.lanes["squat.linear"].load.as_deref(),
        Some("65kg")
    );
    assert_eq!(
        reduced.new_state.lanes["press.linear"].load.as_deref(),
        Some("32.5kg")
    );
    assert_eq!(
        reduced.new_state.lanes["deadlift.linear"].load.as_deref(),
        Some("85kg")
    );
}

#[test]
fn state_adjustment_events_are_replayed_explicitly() {
    let compiled = compiled_gzclp();
    let state = replay_events(
        &compiled,
        &[TrainingEvent {
            id: "evt_adjust".into(),
            kind: "state_adjusted".into(),
            schema_version: Some("0.1".into()),
            program: None,
            session_id: None,
            plan_hash: None,
            template_hash: None,
            rendered_session_hash: None,
            engine_version: None,
            started_at: None,
            completed_at: None,
            saved_at: None,
            status: None,
            results: Vec::new(),
            results_added: Vec::new(),
            effects: Vec::new(),
            continues_event_id: None,
            corrects_event_id: None,
            reason: Some("manual deload".into()),
            policy: None,
            lane: Some("squat.t1".into()),
            change: Some(StateChange {
                load: Some(knurled_core::LoadChange {
                    from: Some("80kg".into()),
                    to: "77.5kg".into(),
                }),
                stage: None,
            }),
            cursor: None,
            changes: Vec::new(),
            change_kind: None,
            from_plan: None,
            to_plan: None,
        }],
    );

    assert_eq!(state.lanes["squat.t1"].load.as_deref(), Some("77.5kg"));
}

#[test]
fn flat_history_import_groups_hevy_like_rows_into_imported_sessions() {
    let csv = "\
title,start_time,exercise_title,set_index,weight_kg,reps,rpe,set_type
Push Day,2024-01-02 18:30:00,Bench Press,1,80,5,8,normal
Push Day,2024-01-02 18:30:00,Bench Press,2,80,5,8.5,normal
Push Day,2024-01-02 18:30:00,Barbell Row,1,70,8,,warmup
";

    let draft = history_import_events_from_str(
        csv,
        &HistoryImportOptions {
            source: "hevy".into(),
            ..Default::default()
        },
    )
    .unwrap();

    assert_eq!(draft.input_rows, 3);
    assert_eq!(draft.imported_sets, 3);
    assert_eq!(draft.events.len(), 1);

    let event = &draft.events[0];
    assert_eq!(event.kind, "session_imported");
    assert_eq!(event.program.as_deref(), Some("history_import:hevy"));
    assert_eq!(event.reason.as_deref(), Some("Push Day"));
    assert_eq!(event.completed_at.as_deref(), Some("2024-01-02T18:30:00Z"));
    assert!(event.effects.is_empty());

    let bench = event
        .results
        .iter()
        .find(|result| result.performed_exercise.as_deref() == Some("bench_press"))
        .unwrap();
    assert_eq!(bench.actual.len(), 2);
    assert_eq!(bench.actual[0].load.as_deref(), Some("80kg"));
    assert_eq!(bench.actual[0].metrics["rpe"], "8");
    assert_eq!(bench.actual[1].metrics["rpe"], "8.5");

    let row = event
        .results
        .iter()
        .find(|result| result.performed_exercise.as_deref() == Some("barbell_row"))
        .unwrap();
    assert_eq!(row.actual[0].metrics["set_type"], "warmup");
}

#[test]
fn flat_history_import_expands_aggregate_set_rows() {
    let csv = "\
date,session,exercise,set,sets,load,unit,reps,metric_source
2024-02-03,Strength Levels,Squat,1,3,100,kg,5,strengthlevels
";

    let draft = history_import_events_from_str(csv, &HistoryImportOptions::default()).unwrap();
    let squat = &draft.events[0].results[0];

    assert_eq!(draft.imported_sets, 3);
    assert_eq!(
        squat.actual.iter().map(|set| set.set).collect::<Vec<_>>(),
        vec![1, 2, 3]
    );
    assert_eq!(
        squat
            .actual
            .iter()
            .map(|set| (
                set.load.as_deref(),
                set.reps,
                set.metrics["source"].as_str()
            ))
            .collect::<Vec<_>>(),
        vec![
            (Some("100kg"), 5, "strengthlevels"),
            (Some("100kg"), 5, "strengthlevels"),
            (Some("100kg"), 5, "strengthlevels")
        ]
    );
}

#[test]
fn imported_sessions_do_not_advance_program_replay_but_plan_markers_are_visible() {
    let compiled = compiled_gzclp();
    let draft = history_import_events_from_str(
        "date,session,exercise,set,load,unit,reps\n2024-02-03,Old Program,Squat,1,100,kg,5\n",
        &HistoryImportOptions::default(),
    )
    .unwrap();
    let marker = TrainingEvent {
        id: "evt_plan_changed".into(),
        kind: "plan_changed".into(),
        change_kind: Some("program_switch".into()),
        from_plan: Some(PlanChangeRef {
            plan_hash: None,
            template: Some("hevy-history".into()),
        }),
        to_plan: Some(PlanChangeRef {
            plan_hash: Some(compiled.plan_hash.clone()),
            template: Some(compiled.plan.template.clone()),
        }),
        reason: Some("imported prior Hevy history and started Knurled plan".into()),
        ..empty_event()
    };

    let state = replay_events(&compiled, &[draft.events[0].clone(), marker]);

    assert_eq!(state.cursor.next_session, "a1");
    assert_eq!(state.lanes["squat.t1"].load.as_deref(), Some("80kg"));
    assert_eq!(state.last_event_id.as_deref(), Some("evt_plan_changed"));
}

#[test]
fn history_import_repo_writes_import_file_idempotently() {
    let repo = temp_repo("history-import");
    init_training_repo(&repo, "gzcl.gzclp@1.0.0").unwrap();
    let input = repo.join("history.csv");
    fs::write(
        &input,
        "date,session,exercise,set,load,unit,reps\n2024-02-03,Old Program,Squat,1,100,kg,5\n",
    )
    .unwrap();

    let first = import_history_repo(
        &repo,
        &input,
        HistoryImportOptions {
            source: "hevy".into(),
            ..Default::default()
        },
    )
    .unwrap();
    let second = import_history_repo(
        &repo,
        &input,
        HistoryImportOptions {
            source: "hevy".into(),
            ..Default::default()
        },
    )
    .unwrap();

    assert_eq!(first.events_written, 1);
    assert_eq!(first.output_files, vec!["logs/imports/hevy.jsonl"]);
    assert_eq!(second.events_written, 0);
    assert_eq!(second.duplicates_skipped, 1);
    let log = fs::read_to_string(repo.join("logs/imports/hevy.jsonl")).unwrap();
    assert_eq!(log.lines().count(), 1);

    let _ = fs::remove_dir_all(repo);
}

#[test]
fn continuation_event_advances_cursor_after_partial_save() {
    let compiled = compiled_gzclp();
    let state = replay_events(
        &compiled,
        &[
            TrainingEvent {
                id: "evt_partial".into(),
                kind: "session_saved".into(),
                session_id: Some("a1".into()),
                status: Some("partial".into()),
                ..empty_event()
            },
            TrainingEvent {
                id: "evt_continue".into(),
                kind: "session_continued".into(),
                session_id: Some("a1".into()),
                continues_event_id: Some("evt_partial".into()),
                effects: vec![Effect {
                    op: "increase_load".into(),
                    lane: "squat.t1".into(),
                    from: Some("80kg".into()),
                    to: Some("82.5kg".into()),
                }],
                ..empty_event()
            },
        ],
    );

    assert_eq!(state.cursor.next_session, "b1");
    assert_eq!(state.lanes["squat.t1"].load.as_deref(), Some("82.5kg"));
}

#[test]
fn partial_save_advances_cursor_to_next_workout() {
    let compiled = compiled_gzclp();
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 0);
    input.status = "partial".into();

    let result = reduce_input(&compiled, &state, &rendered, &input).unwrap();

    // Submitting a partial moves the program on to the next workout (B1), rather than re-serving A1.
    assert_eq!(result.new_state.cursor.next_session, "b1");
    assert_eq!(result.next_workout.session_id, "b1");
}

#[test]
fn saved_partial_advances_cursor_yet_stays_resumable() {
    let compiled = compiled_gzclp();
    let a1 = render_next(&compiled, &create_initial_state(&compiled)).unwrap();
    let saved = TrainingEvent {
        id: "evt_partial".into(),
        kind: "session_saved".into(),
        session_id: Some("a1".into()),
        status: Some("partial".into()),
        rendered_session_hash: Some(a1.rendered_session_hash.clone()),
        ..empty_event()
    };

    let outputs = build_outputs(&compiled, std::slice::from_ref(&saved)).unwrap();

    // Cursor has moved to B1, but A1 is re-rendered as a resumable session for History.
    assert_eq!(outputs.state.cursor.next_session, "b1");
    assert_eq!(outputs.next_workout.as_ref().unwrap().session_id, "b1");
    assert_eq!(outputs.resumable_sessions.len(), 1);
    assert_eq!(outputs.resumable_sessions[0].session_id, "a1");
    assert_eq!(
        outputs.resumable_sessions[0].rendered_session_hash,
        a1.rendered_session_hash
    );

    // Once continued, A1 is no longer offered as resumable and the cursor stays put.
    let continued = TrainingEvent {
        id: "evt_continue".into(),
        kind: "session_continued".into(),
        session_id: Some("a1".into()),
        continues_event_id: Some("evt_partial".into()),
        ..empty_event()
    };
    let after = build_outputs(&compiled, &[saved, continued]).unwrap();
    assert_eq!(after.state.cursor.next_session, "b1");
    assert!(after.resumable_sessions.is_empty());
}

#[test]
fn correction_event_refolds_projected_state() {
    let compiled = compiled_gzclp();
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 0);
    input
        .inputs
        .iter_mut()
        .find(|item| item.item_id == "a1.t2")
        .unwrap()
        .sets = vec![
        actual(1, "45kg", 10),
        actual(2, "45kg", 10),
        actual(3, "45kg", 8),
    ];
    let completed = reduce_input(&compiled, &state, &rendered, &input)
        .unwrap()
        .event
        .unwrap();
    let corrected = TrainingEvent {
        id: "evt_correction".into(),
        kind: "session_corrected".into(),
        corrects_event_id: Some(completed.id.clone()),
        changes: vec![CorrectionChange {
            path: "results[a1.t2].actual[2].reps".into(),
            before: json!(8),
            after: json!(10),
        }],
        ..empty_event()
    };

    let state = replay_events(&compiled, &[completed, corrected]);

    assert_eq!(state.lanes["bench.t2"].load.as_deref(), Some("47.5kg"));
    assert_eq!(state.lanes["bench.t2"].stage.as_deref(), Some("3x10"));
}

#[test]
fn simulation_uses_reducer_effects() {
    let compiled = compiled_gzclp();
    let initial = create_initial_state(&compiled);
    let report = simulate(&compiled, &initial, 1, "all-pass").unwrap();

    assert_eq!(report.sessions.len(), 3);
    assert_eq!(
        report.final_state.lanes["squat.t1"].load.as_deref(),
        Some("82.5kg")
    );
    assert_eq!(report.sessions[0].effects[0].op, "increase_load");
}

fn actual(set: u32, load: &str, reps: u32) -> knurled_core::ActualSet {
    knurled_core::ActualSet {
        set,
        load: Some(load.into()),
        reps,
        metrics: Default::default(),
    }
}

fn exercise_summary(rendered: &knurled_core::RenderedSession) -> Vec<(&str, usize, u32)> {
    rendered
        .items
        .iter()
        .map(|item| {
            (
                item.exercise.as_str(),
                item.prescription.sets.len(),
                item.prescription.sets[0].target_reps,
            )
        })
        .collect()
}

fn temp_repo(name: &str) -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("knurled-{name}-{nanos}"))
}

fn empty_event() -> TrainingEvent {
    TrainingEvent {
        id: String::new(),
        kind: String::new(),
        schema_version: Some("0.1".into()),
        program: None,
        session_id: None,
        plan_hash: None,
        template_hash: None,
        rendered_session_hash: None,
        engine_version: None,
        started_at: None,
        completed_at: None,
        saved_at: None,
        status: None,
        results: Vec::new(),
        results_added: Vec::new(),
        effects: Vec::new(),
        continues_event_id: None,
        corrects_event_id: None,
        reason: None,
        policy: None,
        lane: None,
        change: None,
        cursor: None,
        changes: Vec::new(),
        change_kind: None,
        from_plan: None,
        to_plan: None,
    }
}
