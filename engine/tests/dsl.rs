use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use knurled_core::{
    PreviewTemplateRequest, SubmitMode, Units, ValidationStatus, builtin_template,
    builtin_templates, compile_plan, create_initial_state, parse_template_dsl, preview_template,
    read_state, read_training_repo, reduce_input, render_lockfile, render_next,
    render_template_dsl, submit_repo, synthetic_execution_input, vendor_template,
};

fn temp_repo(name: &str) -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("knurled-dsl-{name}-{nanos}"))
}

#[test]
fn every_catalog_entry_vendors_a_real_dsl_document() {
    assert_eq!(builtin_templates().len(), 7);
    for info in builtin_templates() {
        let reference = format!("{}@{}", info.id, info.version);
        let document = vendor_template(&reference).unwrap();
        assert!(!document.contains("builtin \""));
        let vendored = parse_template_dsl(&document, "vendored").unwrap();
        let shipped = builtin_template(&reference).unwrap();
        assert_eq!(vendored.dsl, shipped.dsl);
    }
}

fn gzclp_compiled() -> knurled_core::CompiledPlan {
    let plan = include_str!("../../examples/gzclp-repo/plan.fitspec");
    compile_plan(plan, &render_lockfile("gzcl.gzclp@1.0.0").unwrap(), &[]).unwrap()
}

#[test]
fn starting_strength_third_consecutive_failure_deloads_and_resets_stall() {
    let plan = r#"plan "SS" {
  template "starting-strength.phase1@1.0.0"
  units kg
  schedule next_workout { rotation a b; suggested_days mon wed fri }
  starts { squat "60kg"; press "30kg"; bench "40kg"; deadlift "80kg" }
}
"#;
    let compiled = compile_plan(
        plan,
        &render_lockfile("starting-strength.phase1@1.0.0").unwrap(),
        &[],
    )
    .unwrap();
    let mut state = create_initial_state(&compiled);
    for index in 0..3 {
        let rendered = render_next(&compiled, &state).unwrap();
        let input = synthetic_execution_input(&rendered, "all-fail", index);
        state = reduce_input(&compiled, &state, &rendered, &input)
            .unwrap()
            .new_state;
    }
    assert_eq!(state.lanes["squat.linear"].load.as_deref(), Some("55kg"));
    assert_eq!(state.lanes["squat.linear"].stall, Some(0));
}

#[test]
fn gzclp_last_stage_failure_resets_load_and_stage() {
    let compiled = gzclp_compiled();
    let mut state = create_initial_state(&compiled);
    state.lanes.get_mut("squat.t1").unwrap().load = Some("100kg".into());
    state.lanes.get_mut("squat.t1").unwrap().stage = Some("10x1+".into());
    let rendered = render_next(&compiled, &state).unwrap();
    let input = synthetic_execution_input(&rendered, "all-fail", 0);
    let state = reduce_input(&compiled, &state, &rendered, &input)
        .unwrap()
        .new_state;
    assert_eq!(state.lanes["squat.t1"].load.as_deref(), Some("90kg"));
    assert_eq!(state.lanes["squat.t1"].stage.as_deref(), Some("5x3+"));
}

#[test]
fn gzclp_accessory_uses_double_progression_and_first_performed_load() {
    let compiled = gzclp_compiled();
    let state = create_initial_state(&compiled);
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 0);
    let accessory = input
        .inputs
        .iter_mut()
        .find(|item| item.item_id == "a1.t3")
        .unwrap();
    accessory.load = Some("40kg".into());
    accessory.final_set_reps = Some(20);
    let state = reduce_input(&compiled, &state, &rendered, &input)
        .unwrap()
        .new_state;
    assert_eq!(state.lanes["lat_pulldown.t3"].load.as_deref(), Some("40kg"));
    assert_eq!(state.lanes["lat_pulldown.t3"].reps, Some(16));

    let mut state = state;
    state.cursor.next_session = "a1".into();
    let rendered = render_next(&compiled, &state).unwrap();
    let mut input = synthetic_execution_input(&rendered, "all-pass", 1);
    let accessory = input
        .inputs
        .iter_mut()
        .find(|item| item.item_id == "a1.t3")
        .unwrap();
    accessory.final_set_reps = Some(25);
    let state = reduce_input(&compiled, &state, &rendered, &input)
        .unwrap()
        .new_state;
    assert_eq!(
        state.lanes["lat_pulldown.t3"].load.as_deref(),
        Some("42.5kg")
    );
    assert_eq!(state.lanes["lat_pulldown.t3"].reps, Some(15));
}

#[test]
fn five_three_one_bumps_training_max_after_deload() {
    let plan = include_str!("../../examples/531-repo/plan.fitspec");
    let compiled =
        compile_plan(plan, &render_lockfile("531.beginners@1.0.0").unwrap(), &[]).unwrap();
    let mut state = create_initial_state(&compiled);
    for index in 0..4 {
        state.cursor.next_session = "squat_day".into();
        let rendered = render_next(&compiled, &state).unwrap();
        let input = synthetic_execution_input(&rendered, "all-pass", index);
        state = reduce_input(&compiled, &state, &rendered, &input)
            .unwrap()
            .new_state;
    }
    let squat = &state.lanes["squat.main"];
    assert_eq!(squat.training_max.as_deref(), Some("95kg"));
    assert_eq!(squat.stage.as_deref(), Some("week 1"));
    assert_eq!(squat.week, Some(1));
    assert_eq!(squat.cycle, Some(2));
}

#[test]
fn custom_wave_amrap_and_deload_run_through_the_generic_evaluator() {
    let root = temp_repo("custom-wave");
    fs::create_dir_all(root.join("templates")).unwrap();
    fs::create_dir_all(root.join("logs")).unwrap();
    fs::write(
        root.join("plan.fitspec"),
        r#"plan "Custom Wave" {
  template "./templates/custom.fitspec"
  units kg
  schedule next_workout { rotation day; suggested_days mon wed fri }
  starts { squat "100kg" }
}
"#,
    )
    .unwrap();
    fs::write(root.join("fitspec.lock"), "").unwrap();
    fs::write(
        root.join("templates/custom.fitspec"),
        r#"template "Wave + AMRAP" version="1.0.0" {
  rotation day
  rest 150
  session day { item "squat.main" slot="day.squat" }
  lane "squat.main" exercise="squat" basis="working_weight" sequence="cycle" {
    warmup intensity=50 reps=5
    stage "wave" {
      set count=1 reps=5 intensity=80
      set count=1 reps=3 intensity=90
      set count=1 reps=1 intensity=100 amrap=#true
    }
    stage "deload" { set count=3 reps=5 intensity=60 }
    on pass { increase_load by=2.5; advance_stage }
    on amrap_gte reps=8 { increase_load by="5%" }
    on cycle_end { reset_stage; advance_cycle }
  }
}
"#,
    )
    .unwrap();

    let repo = read_training_repo(&root).unwrap();
    let first = render_next(&repo.compiled, &read_state(&root).unwrap()).unwrap();
    assert_eq!(first.items[0].prescription.sets.len(), 3);
    assert_eq!(
        first.items[0].prescription.sets[0].load.as_deref(),
        Some("80kg")
    );
    assert!(first.items[0].prescription.sets[2].amrap);
    assert_eq!(
        first.items[0].prescription.warmups[0].load.as_deref(),
        Some("50kg")
    );

    let input = synthetic_execution_input(&first, "all-pass", 0);
    submit_repo(&root, &input, SubmitMode::Advance, "2026-06-28").unwrap();
    let after_wave = read_state(&root).unwrap();
    assert_eq!(
        after_wave.lanes["squat.main"].load.as_deref(),
        Some("102.5kg")
    );
    assert_eq!(
        after_wave.lanes["squat.main"].stage.as_deref(),
        Some("deload")
    );

    let repo = read_training_repo(&root).unwrap();
    let deload = render_next(&repo.compiled, &after_wave).unwrap();
    assert_eq!(
        deload.items[0].prescription.sets[0].load.as_deref(),
        Some("62.5kg")
    );
    let input = synthetic_execution_input(&deload, "all-pass", 1);
    submit_repo(&root, &input, SubmitMode::Advance, "2026-06-30").unwrap();
    let after_deload = read_state(&root).unwrap();
    assert_eq!(
        after_deload.lanes["squat.main"].stage.as_deref(),
        Some("wave")
    );
    assert_eq!(after_deload.cursor.cycle, 2);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn render_round_trips_every_builtin_template() {
    for info in builtin_templates() {
        let reference = format!("{}@{}", info.id, info.version);
        let document = vendor_template(&reference).unwrap();
        let parsed = parse_template_dsl(&document, "vendored").unwrap();

        let rendered = render_template_dsl(&parsed.dsl);
        let reparsed = parse_template_dsl(&rendered, "vendored").unwrap();
        assert_eq!(
            reparsed.dsl, parsed.dsl,
            "render∘parse is not a fixed point for {reference}\n--- rendered ---\n{rendered}"
        );

        // Idempotent: rendering the already-canonical form changes nothing.
        assert_eq!(
            render_template_dsl(&reparsed.dsl),
            rendered,
            "render is not idempotent for {reference}"
        );
    }
}

#[test]
fn preview_template_renders_first_workout_for_a_forked_builtin() {
    let document = vendor_template("gzcl.gzclp@1.0.0").unwrap();
    let dsl = parse_template_dsl(&document, "preview").unwrap().dsl;
    let request = PreviewTemplateRequest {
        dsl: Some(dsl),
        units: Units::Kg,
        initial_numbers: [
            ("squat".to_string(), "100kg".to_string()),
            ("bench".to_string(), "60kg".to_string()),
            ("press".to_string(), "40kg".to_string()),
            ("deadlift".to_string(), "140kg".to_string()),
        ]
        .into_iter()
        .collect(),
        ..PreviewTemplateRequest::default()
    };
    let result = preview_template(request).unwrap();
    assert_eq!(result.validation.status, ValidationStatus::Valid);
    let preview = result.preview.expect("a valid template previews a session");
    assert!(!preview.items.is_empty());
    assert_eq!(preview.session_id, "a1");
}

#[test]
fn preview_template_surfaces_missing_initial_numbers_as_errors() {
    let document = vendor_template("gzcl.gzclp@1.0.0").unwrap();
    let dsl = parse_template_dsl(&document, "preview").unwrap().dsl;
    let result = preview_template(PreviewTemplateRequest {
        dsl: Some(dsl),
        ..PreviewTemplateRequest::default()
    })
    .unwrap();
    assert_eq!(result.validation.status, ValidationStatus::Invalid);
    assert!(result.preview.is_none());
    assert!(
        result
            .validation
            .errors
            .iter()
            .any(|error| error.code == "missing_custom_start")
    );
}

#[test]
fn preview_template_reports_a_parse_error_for_an_empty_lane() {
    let result = preview_template(PreviewTemplateRequest {
        text: Some(
            r#"template "Broken" version="1.0.0" {
  rotation day
  rest 120
  session day { item "squat.main" slot="day.squat" }
  lane "squat.main" exercise="squat" basis="working_weight" {
  }
}
"#
            .to_string(),
        ),
        ..PreviewTemplateRequest::default()
    })
    .unwrap();
    assert_eq!(result.validation.status, ValidationStatus::Invalid);
    assert_eq!(result.validation.errors[0].code, "template_parse_error");
}
