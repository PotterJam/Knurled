use knurled_core::{
    LockEntry, PatchOperation, SwapPolicy, Units, parse_lock, parse_patch, parse_plan,
};

#[test]
fn parses_current_plan_fixtures() {
    let gzclp = parse_plan(include_str!("../../examples/gzclp-repo/plan.fitspec")).unwrap();
    assert_eq!(gzclp.name, "My GZCLP");
    assert_eq!(gzclp.template, "gzclp.standard@1.0.0");
    assert_eq!(gzclp.units, Units::Kg);
    assert_eq!(gzclp.schedule.rotation, ["a1", "b1", "a2", "b2"]);
    assert_eq!(gzclp.schedule.suggested_days, ["mon", "wed", "fri"]);
    assert_eq!(gzclp.starts["squat"], "80kg");
    assert_eq!(gzclp.accessories["A1.T3"], "lat_pulldown");

    let five_three_one = parse_plan(include_str!("../../examples/531-repo/plan.fitspec")).unwrap();
    assert_eq!(five_three_one.name, "My 5/3/1");
    assert_eq!(five_three_one.template, "531.beginners@1.0.0");
    assert_eq!(five_three_one.training_maxes["deadlift"], "110kg");
    assert!(
        five_three_one.accessories.is_empty(),
        "unknown assistance block should still be ignored"
    );

    let starting_strength =
        parse_plan(include_str!("../../examples/ss-phase3-repo/plan.fitspec")).unwrap();
    assert_eq!(starting_strength.template, "starting-strength.phase3@1.0.0");
    assert_eq!(starting_strength.starts["power_clean"], "40kg");

    let ios = parse_plan(include_str!(
        "../../ios/Knurled/Resources/Fixtures/gzclp-repo/plan.fitspec"
    ))
    .unwrap();
    let a1_t3 = &ios.exercise_options["a1.t3"];
    assert_eq!(a1_t3.primary, "lat_pulldown");
    assert_eq!(a1_t3.alternatives[0].option_id, "chin_up");
    assert_eq!(a1_t3.alternatives[0].label, "Chin-up");
    assert_eq!(a1_t3.alternatives[0].policy, SwapPolicy::TrackingOnly);
}

#[test]
fn exercise_options_parse_same_line_policy_directives() {
    let plan = parse_plan(
        r#"plan "Options" {
  template "gzclp.standard@1.0.0"
  units kg

  exercise_options {
    slot "A1.T2" {
      primary bench_press
      dumbbell_bench_press { label "DB Bench" policy progression_equivalent }
    }
  }
}
"#,
    )
    .unwrap();

    let option = &plan.exercise_options["a1.t2"].alternatives[0];
    assert_eq!(option.label, "DB Bench");
    assert_eq!(option.policy, SwapPolicy::ProgressionEquivalent);
}

#[test]
fn malformed_plan_returns_error() {
    assert!(parse_plan("").is_err());
    assert!(
        parse_plan(
            r#"plan "Missing Units" {
  template "gzclp.standard@1.0.0"
}
"#
        )
        .is_err()
    );
    assert!(
        parse_plan(
            r#"plan "Unknown" {
  template "gzclp.standard@1.0.0"
  units kg
  mystery true
}
"#
        )
        .is_err()
    );
}

#[test]
fn rest_policy_accepts_existing_duration_forms() {
    let plan = parse_plan(
        r#"plan "Rest" {
  template "gzclp.standard@1.0.0"
  units kg

  rest {
    default 180
    tier T1 3m
    slot A1.T2 5 min
    lane squat.t1 4:30
    exercise bench 210 seconds
  }
}
"#,
    )
    .unwrap();

    assert_eq!(plan.rest.default_seconds, Some(180));
    assert_eq!(plan.rest.by_tier["t1"], 180);
    assert_eq!(plan.rest.by_slot["a1.t2"], 300);
    assert_eq!(plan.rest.by_lane["squat.t1"], 270);
    assert_eq!(plan.rest.by_exercise["bench"], 210);
}

#[test]
fn parses_lockfile_template_entries() {
    let lock = parse_lock(include_str!("../../examples/gzclp-repo/fitspec.lock")).unwrap();

    assert_eq!(
        lock.templates["gzclp.standard"],
        LockEntry {
            version: "1.0.0".into(),
            source: "builtin".into(),
            content_hash: "sha256:7fb133a3013f5ebbf37c649285aa85b220919d7848e4e94696b44979d6eb7371"
                .into(),
            engine_version: "0.1.0".into(),
        }
    );
}

#[test]
fn patch_parser_preserves_typed_operations() {
    let patch = parse_patch(
        r#"patch "shoulder" {
  description "Temporary replacement"
  active from 2026-06-22
  expires 2026-07-20
  replace exercise press with landmine_press where lane matches "press.*"
  add conditioning tuesday { easy_run 25min zone2 }
  cap rpe 8 where lane matches "press.*"
}
"#,
        "patches/shoulder.fitspec",
    )
    .unwrap();

    assert_eq!(patch.name, "shoulder");
    assert_eq!(patch.filename, "patches/shoulder.fitspec");
    assert_eq!(patch.description, "Temporary replacement");
    assert_eq!(patch.active_from.as_deref(), Some("2026-06-22"));
    assert_eq!(patch.expires.as_deref(), Some("2026-07-20"));
    assert_eq!(
        patch.operations,
        vec![
            PatchOperation::ReplaceExercise {
                from: "press".into(),
                to: "landmine_press".into(),
                lane_regex: "press.*".into(),
            },
            PatchOperation::AddConditioning {
                day: "tuesday".into(),
                activity: "easy_run 25min zone2".into(),
            },
            PatchOperation::Cap {
                target: "rpe".into(),
                value: "8".into(),
                lane_regex: Some("press.*".into()),
            },
        ]
    );
}

#[test]
fn malformed_lock_and_patch_return_errors() {
    assert!(parse_lock("version = \"1.0.0\"").is_err());
    assert!(parse_patch("cap rpe 8", "patches/no-name.fitspec").is_err());
    assert!(
        parse_patch(
            r#"patch "raw" {
  block hard_intervals within 24h of heavy_squat
}
"#,
            "patches/raw.fitspec",
        )
        .is_err()
    );
}
