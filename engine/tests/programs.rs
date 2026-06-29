use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use knurled_core::{
    AddProgramRequest, Map, SubmitMode, Units, active_program_dir, add_program, build_repo,
    init_training_repo, list_programs, read_records, read_state, read_training_repo,
    set_active_program, submit_repo, synthetic_execution_input,
};

fn temp_repo(name: &str) -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("knurled-programs-{name}-{nanos}"))
}

fn submit_next(root: &std::path::Path, index: u32, date: &str) {
    let repo = read_training_repo(root).unwrap();
    let state = read_state(root).unwrap();
    let rendered = knurled_core::render_next(&repo.compiled, &state).unwrap();
    let input = synthetic_execution_input(&rendered, "all-pass", index);
    submit_repo(root, &input, SubmitMode::Advance, date).unwrap();
}

#[test]
fn add_and_switch_preserve_program_state_and_share_logs() {
    let root = temp_repo("switch");
    init_training_repo(&root, "gzcl.gzclp@1.0.0").unwrap();
    let first = list_programs(&root).unwrap().remove(0);
    assert!(
        active_program_dir(&root)
            .unwrap()
            .starts_with(root.join("programs"))
    );

    submit_next(&root, 0, "2026-06-20");
    let first_state = read_state(&root).unwrap();

    let added = add_program(
        &root,
        AddProgramRequest {
            display_name: "My 5/3/1".into(),
            template: "531.beginners@1.0.0".into(),
            units: Units::Kg,
            initial_numbers: Map::from([
                ("squat".into(), "100kg".into()),
                ("bench".into(), "70kg".into()),
                ("deadlift".into(), "120kg".into()),
                ("press".into(), "45kg".into()),
            ]),
            suggested_days: vec![],
            custom_template: None,
            equipment: None,
            rest: None,
        },
    )
    .unwrap();
    let second = added
        .programs
        .iter()
        .find(|program| program.slug != first.slug)
        .unwrap()
        .clone();

    set_active_program(&root, &second.slug).unwrap();
    submit_next(&root, 1, "2026-06-21");
    let second_state = read_state(&root).unwrap();
    assert_ne!(first_state.program_hash, second_state.program_hash);

    set_active_program(&root, &first.slug).unwrap();
    assert_eq!(read_state(&root).unwrap(), first_state);
    set_active_program(&root, &second.slug).unwrap();
    assert_eq!(read_state(&root).unwrap(), second_state);
    assert_eq!(read_records(&root).unwrap().len(), 2);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn legacy_root_repo_builds_and_migrates_on_program_write() {
    let root = temp_repo("legacy");
    fs::create_dir_all(root.join("state")).unwrap();
    fs::create_dir_all(root.join("logs")).unwrap();
    fs::create_dir_all(root.join("patches")).unwrap();
    fs::write(
        root.join("plan.fitspec"),
        include_str!("../../examples/gzclp-repo/plan.fitspec"),
    )
    .unwrap();
    fs::write(
        root.join("fitspec.lock"),
        include_str!("../../examples/gzclp-repo/fitspec.lock"),
    )
    .unwrap();
    fs::write(
        root.join("fitspec.toml"),
        "[repo]\nschema_version = \"0.1\"\n",
    )
    .unwrap();

    assert!(build_repo(&root, false).unwrap().next_workout.is_some());
    add_program(
        &root,
        AddProgramRequest {
            display_name: "Second GZCLP".into(),
            template: "gzcl.gzclp@1.0.0".into(),
            units: Units::Kg,
            initial_numbers: Map::from([
                ("squat".into(), "60kg".into()),
                ("bench".into(), "40kg".into()),
                ("deadlift".into(), "80kg".into()),
                ("press".into(), "30kg".into()),
            ]),
            suggested_days: vec![],
            custom_template: None,
            equipment: None,
            rest: None,
        },
    )
    .unwrap();

    assert!(!root.join("plan.fitspec").exists());
    assert_eq!(list_programs(&root).unwrap().len(), 2);
    assert!(build_repo(&root, false).unwrap().next_workout.is_some());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn custom_program_is_authored_into_its_program_template_directory() {
    let root = temp_repo("custom");
    init_training_repo(&root, "gzcl.gzclp@1.0.0").unwrap();
    let outcome = add_program(
        &root,
        AddProgramRequest {
            display_name: "Custom Linear".into(),
            template: "custom".into(),
            units: Units::Kg,
            initial_numbers: Map::from([("squat".into(), "80kg".into())]),
            suggested_days: vec!["mon".into(), "fri".into()],
            custom_template: Some(
                r#"template "Custom Linear" {
  rotation day
  session day { item "squat.main" slot="day.squat" }
  lane "squat.main" exercise="squat" basis="working_weight" sequence="none" {
    stage "work" { set count=3 reps=5 intensity=100 }
    on pass { increase_load by=2.5 }
  }
}
"#
                .into(),
            ),
            equipment: None,
            rest: None,
        },
    )
    .unwrap();
    let custom = outcome
        .programs
        .iter()
        .find(|program| program.display_name == "Custom Linear")
        .unwrap();
    assert_eq!(custom.validity, knurled_core::ValidationStatus::Valid);
    assert!(
        root.join("programs")
            .join(&custom.slug)
            .join("templates/custom.fitspec")
            .exists()
    );
    let _ = fs::remove_dir_all(root);
}
