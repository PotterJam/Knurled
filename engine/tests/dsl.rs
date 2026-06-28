use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use knurled_core::{
    SubmitMode, builtin_template, compile_plan, create_initial_state, parse_template_dsl,
    read_state, read_training_repo, render_next, stable_json, submit_repo,
    synthetic_execution_input, vendor_template,
};

fn temp_repo(name: &str) -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("knurled-dsl-{name}-{nanos}"))
}

#[test]
fn vendored_builtins_are_byte_identical_at_the_evaluator_gate() {
    for (reference, plan) in [
        (
            "gzcl.gzclp@1.0.0",
            include_str!("../../examples/gzclp-repo/plan.fitspec"),
        ),
        (
            "531.beginners@1.0.0",
            include_str!("../../examples/531-repo/plan.fitspec"),
        ),
        (
            "starting-strength.phase3@1.0.0",
            include_str!("../../examples/ss-phase3-repo/plan.fitspec"),
        ),
    ] {
        let lock = knurled_core::render_lockfile(reference).unwrap();
        let compiled = compile_plan(plan, &lock, &[]).unwrap();
        let legacy = builtin_template(reference).unwrap();
        let vendored =
            parse_template_dsl(&vendor_template(reference).unwrap(), "vendored").unwrap();
        assert_eq!(vendored, legacy);

        let state = create_initial_state(&compiled);
        let expected = render_next(&compiled, &state).unwrap();
        let mut through_document = compiled.clone();
        through_document.template = vendored;
        let actual = render_next(&through_document, &state).unwrap();
        assert_eq!(
            stable_json(&actual).unwrap(),
            stable_json(&expected).unwrap()
        );
    }
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
