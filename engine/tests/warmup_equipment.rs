use knurled_core::{
    CompiledPlan, RenderedItem, RenderedSession, ValidationStatus, compile_plan,
    create_initial_state, render_lockfile, render_next, validate_compiled,
};

fn compiled(plan: &str, template: &str) -> CompiledPlan {
    let lock = render_lockfile(template).unwrap();
    compile_plan(plan, &lock, &[]).unwrap()
}

fn render(plan: &str, template: &str) -> RenderedSession {
    let compiled = compiled(plan, template);
    render_next(&compiled, &create_initial_state(&compiled)).unwrap()
}

fn item<'a>(session: &'a RenderedSession, slot_id: &str) -> &'a RenderedItem {
    session
        .items
        .iter()
        .find(|item| item.slot_id == slot_id)
        .unwrap_or_else(|| panic!("no item {slot_id}"))
}

const GZCLP: &str = "gzcl.gzclp@1.0.0";
const FIVE_THREE_ONE: &str = "531.beginners@1.0.0";

fn gzclp_plan(extra: &str) -> String {
    format!(
        r#"plan "Warmups" {{
  template "{GZCLP}"
  units kg

  schedule next_workout {{
    rotation A1 B1 A2 B2
    suggested_days mon wed fri
  }}

  starts {{
    squat "80kg"
    bench "55kg"
    press "37.5kg"
    deadlift "100kg"
  }}
{extra}
}}
"#
    )
}

fn five_three_one_plan(extra: &str) -> String {
    format!(
        r#"plan "Warmups 531" {{
  template "{FIVE_THREE_ONE}"
  units kg

  schedule next_workout {{
    rotation squat_day bench_day deadlift_day press_day
    suggested_days mon wed fri sat
  }}

  training_maxes {{
    squat "100kg"
    bench "65kg"
    deadlift "110kg"
    press "42.5kg"
  }}
{extra}
}}
"#
    )
}

#[test]
fn gzclp_ships_a_bay_strength_default_warmup() {
    let session = render(&gzclp_plan(""), GZCLP);
    let squat = item(&session, "a1.t1");
    let warmups = &squat.prescription.warmups;

    // One empty-bar set, then 65/80% of the 80kg work weight.
    assert_eq!(warmups.len(), 3);
    assert_eq!(warmups[0].load.as_deref(), Some("20kg"));
    assert_eq!(warmups[0].target_reps, 5);
    // 65% of 80 = 52 -> nearest 2.5 = 52.5; 80% = 64 -> 65.
    assert_eq!(warmups[1].load.as_deref(), Some("52.5kg"));
    assert_eq!(warmups[1].percentage, Some(65));
    assert_eq!(warmups[2].load.as_deref(), Some("65kg"));
    assert_eq!(warmups[2].percentage, Some(80));
    assert_eq!(warmups[2].target_reps, 2);

    // Warmups never leak into the working sets.
    assert_eq!(squat.prescription.sets.len(), 5);
    assert!(
        squat
            .prescription
            .sets
            .iter()
            .all(|set| set.percentage.is_none())
    );
}

#[test]
fn compact_default_warmup_skips_duplicate_ramp_loads() {
    let plan = gzclp_plan(
        r#"
  starts {
    squat "30kg"
    bench "55kg"
    press "37.5kg"
    deadlift "100kg"
  }
"#,
    );
    let session = render(&plan, GZCLP);
    let warmups = &item(&session, "a1.t1").prescription.warmups;

    assert_eq!(warmups.len(), 2);
    assert_eq!(warmups[0].load.as_deref(), Some("20kg"));
    assert_eq!(warmups[1].load.as_deref(), Some("25kg"));
    assert_eq!(warmups[1].percentage, Some(80));
}

#[test]
fn five_three_one_warms_up_off_the_training_max() {
    let session = render(&five_three_one_plan(""), FIVE_THREE_ONE);
    let squat = item(&session, "squat.main");
    let warmups = &squat.prescription.warmups;

    // 40/50/60% of the 100kg training max, no empty-bar sets.
    assert_eq!(warmups.len(), 3);
    assert_eq!(warmups[0].load.as_deref(), Some("40kg"));
    assert_eq!(warmups[0].percentage, Some(40));
    assert_eq!(warmups[1].load.as_deref(), Some("50kg"));
    assert_eq!(warmups[2].load.as_deref(), Some("60kg"));
}

#[test]
fn plan_warmup_overrides_the_template_default() {
    let plan = gzclp_plan(
        r#"
  warmup {
    default {
      empty_bar 1 5
      ramp {
        step 50 5
        step 75 3
      }
    }
  }
"#,
    );
    let session = render(&plan, GZCLP);
    let warmups = &item(&session, "a1.t1").prescription.warmups;

    assert_eq!(warmups.len(), 3);
    assert_eq!(warmups[0].load.as_deref(), Some("20kg"));
    assert_eq!(warmups[1].percentage, Some(50));
    assert_eq!(warmups[2].percentage, Some(75));
}

#[test]
fn warmup_scope_precedence_prefers_the_more_specific_scope() {
    let plan = gzclp_plan(
        r#"
  warmup {
    default {
      ramp { step 50 5 }
    }
    tier T1 {
      ramp { step 60 5; step 80 3 }
    }
  }
"#,
    );
    let session = render(&plan, GZCLP);

    // T1 (squat) uses the tier override.
    let t1 = &item(&session, "a1.t1").prescription.warmups;
    assert_eq!(t1.len(), 2);
    assert_eq!(t1[0].percentage, Some(60));

    // T2 (bench) falls through to the default scheme.
    let t2 = &item(&session, "a1.t2").prescription.warmups;
    assert_eq!(t2.len(), 1);
    assert_eq!(t2[0].percentage, Some(50));
}

#[test]
fn unmatched_plan_warmup_scope_falls_back_to_the_template_scheme() {
    let plan = gzclp_plan(
        r#"
  warmup {
    tier T1 {
      ramp { step 50 5 }
    }
  }
"#,
    );
    let session = render(&plan, GZCLP);

    assert_eq!(item(&session, "a1.t1").prescription.warmups.len(), 1);
    let t2 = &item(&session, "a1.t2").prescription.warmups;
    assert_eq!(t2.len(), 3);
    assert_eq!(t2[1].percentage, Some(65));
}

#[test]
fn bodyweight_lifts_get_no_warmups() {
    // Starting Strength phase 3 has a chins slot with no load to ramp from.
    let plan = r#"plan "SS" {
  template "starting-strength.phase3"
  units kg

  schedule next_workout {
    rotation b_chins_1 a_deadlift a_clean b_chins_2
    suggested_days mon wed fri
  }

  starts {
    squat "60kg"
    press "30kg"
    bench "40kg"
    deadlift "80kg"
    power_clean "40kg"
  }
}
"#;
    let session = render(plan, "starting-strength.phase3");
    let chins = item(&session, "b_chins_1.chins");
    assert!(chins.prescription.warmups.is_empty());
}

#[test]
fn explicit_bodyweight_implement_removes_work_load_and_warmups() {
    let plan = gzclp_plan(
        r#"
  exercises {
    squat { label "Air Squat"; implement bodyweight }
  }
"#,
    );
    let session = render(&plan, GZCLP);
    let squat = item(&session, "a1.t1");
    assert_eq!(squat.implement, knurled_core::Implement::Bodyweight);
    assert!(squat.prescription.warmups.is_empty());
    assert!(squat.prescription.sets.iter().all(|set| set.load.is_none()));
}

#[test]
fn warmup_rounding_uses_monotonic_work_plate_prefixes() {
    let plan = gzclp_plan(
        r#"
  equipment {
    bar default 20
    plates 20 10 5 2.5 1.25
  }
"#,
    );
    let session = render(&plan, GZCLP);
    let warmups = &item(&session, "a1.t1").prescription.warmups;
    // 80kg = 20kg bar + 20kg + 10kg per side. Prefixes are therefore 20, 60, 80;
    // the independently rounded 52.5kg/65kg prescriptions are deliberately avoided.
    assert_eq!(
        warmups
            .iter()
            .filter_map(|set| set.load.as_deref())
            .collect::<Vec<_>>(),
        vec!["20kg", "60kg"]
    );
}

#[test]
fn equipment_snaps_barbell_loads_to_available_plates() {
    // Only 20/10/5 plates: barbell totals are bar (20) + 2 x multiples of 5,
    // i.e. multiples of 10. The 65/75/85% loads (65/75/85kg) snap to the
    // nearest achievable total, ties resolving downward.
    let plan = five_three_one_plan(
        r#"
  equipment {
    bar default 20
    plates 20 10 5
  }
"#,
    );
    let session = render(&plan, FIVE_THREE_ONE);
    let loads: Vec<_> = item(&session, "squat.main")
        .prescription
        .sets
        .iter()
        .map(|set| set.load.clone())
        .collect();

    assert_eq!(
        loads,
        vec![
            Some("60kg".into()), // 65 -> {60,70} tie -> 60
            Some("70kg".into()), // 75 -> {70,80} tie -> 70
            Some("80kg".into()), // 85 -> {80,90} tie -> 80
        ]
    );
}

#[test]
fn equipment_snaps_dumbbell_lifts_to_available_sizes() {
    // Force the main lift onto dumbbells with off-2.5-grid sizes so the snap is
    // visibly different from the default 2.5 rounding.
    let plan = five_three_one_plan(
        r#"
  equipment {
    dumbbells 64 66 74 76 84 86
    implement squat dumbbell
  }
"#,
    );
    let session = render(&plan, FIVE_THREE_ONE);
    let loads: Vec<_> = item(&session, "squat.main")
        .prescription
        .sets
        .iter()
        .map(|set| set.load.clone())
        .collect();

    // 65 -> 64, 75 -> 74, 85 -> 84 (nearest dumbbell, never on the 2.5 grid).
    assert_eq!(
        loads,
        vec![
            Some("64kg".into()),
            Some("74kg".into()),
            Some("84kg".into()),
        ]
    );
}

#[test]
fn equipment_down_rounding_never_exceeds_the_target() {
    let plan = five_three_one_plan(
        r#"
  equipment {
    bar default 20
    plates 20 10 5
    rounding down
  }
"#,
    );
    let session = render(&plan, FIVE_THREE_ONE);
    let first = item(&session, "squat.main").prescription.sets[0]
        .load
        .clone();
    // 65kg target, rounding down over {..,60,70,..} -> 60.
    assert_eq!(first, Some("60kg".into()));
}

#[test]
fn invalid_warmup_percentage_is_rejected() {
    let plan = gzclp_plan(
        r#"
  warmup {
    default {
      ramp { step 120 5 }
    }
  }
"#,
    );
    let report = validate_compiled(&compiled(&plan, GZCLP));
    assert_eq!(report.status, ValidationStatus::Invalid);
    assert!(
        report
            .errors
            .iter()
            .any(|error| error.code == "invalid_warmup_percentage")
    );
}

#[test]
fn invalid_equipment_plate_is_rejected() {
    let plan = five_three_one_plan(
        r#"
  equipment {
    plates 20 -5
  }
"#,
    );
    let report = validate_compiled(&compiled(&plan, FIVE_THREE_ONE));
    assert_eq!(report.status, ValidationStatus::Invalid);
    assert!(
        report
            .errors
            .iter()
            .any(|error| error.code == "invalid_plate")
    );
}
