use knurled_core::{
    PatchFile, RestSource, compile_plan, create_initial_state, reduce_input, render_lockfile,
    render_next, simulate, synthetic_execution_input,
};

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
        result.results[0].outcome,
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
    let event = &result;
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
    let event = &result;
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

    let mut state = create_initial_state(&compiled);
    state.cursor.next_session = "b".into();
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
    let mut state = create_initial_state(&compiled);
    state.cursor.next_session = "b".into();
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
