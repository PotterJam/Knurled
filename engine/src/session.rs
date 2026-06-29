//! Submit-time progression against `state` (ADR 0007).
//!
//! In the logs-as-record model, finishing a session does two independent things:
//! it writes a lean [`TrainingRecord`] to the log (what happened), and it advances
//! the source-of-truth `state` (where you are). How `state` advances is the
//! user's intent, chosen at submit time, never inferred from the numbers:
//!
//! - [`SubmitMode::Advance`] — run the program's progression rules (the existing
//!   [`reduce_input`] path) and update the lanes.
//! - [`SubmitMode::OffDay`] — record the session but leave the lanes untouched.
//!   The program's targets, stages, and fail-counts do not move; the cursor
//!   still advances to the next workout. (Felt-bad / backed-off days.)
//! - [`SubmitMode::Reset`] — set a new baseline in the lanes from what was just
//!   performed (e.g. lighter weights after a layoff).
//!
//! The record is always built from what was performed, regardless of mode. The
//! engine never reads it back.
//!
//! Finishing is not all-or-nothing. Every submit — full or `partial` ("save
//! progress") — advances the cursor to the next workout, and progression is
//! decided per exercise: a lift only moves when all of its working sets (warmups
//! excluded) were done. So an unfinished session still progresses the lifts you
//! completed and leaves the rest where they were. A saved partial stays resumable
//! from history by its session id ([`crate::render_session`] ignores the cursor).

use serde::{Deserialize, Serialize};

use crate::core::{advance_cursor, reduce_input, validate_execution_input};
use crate::error::Result;
use crate::model::{
    ActualSet, CompiledPlan, Effect, ExecutionInput, ExecutionInputValidation, ItemInput,
    LaneCheckpoint, RenderedItem, RenderedSession, StateProjection, ValidationStatus,
};
use crate::record::{LiftRecord, TrainingRecord, lift_record_id, workout_record_id};

/// How a finished session should move `state`. Defaults to [`SubmitMode::Advance`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SubmitMode {
    /// Run the program's progression rules.
    #[default]
    Advance,
    /// Record only; leave the lanes (targets/stages/fails) unchanged.
    OffDay,
    /// Make the performed loads the new baseline.
    Reset,
}

/// The result of submitting a session: the lean record to append, the new
/// source-of-truth `state` to persist, and the effects for a consequence
/// preview. `state` is persisted directly — it is never re-derived from logs.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SubmitOutcome {
    pub validation: ExecutionInputValidation,
    pub record: TrainingRecord,
    /// The new state to write to `state/current.json`.
    pub new_state: StateProjection,
    /// State changes applied, for the app's consequence-first preview.
    pub effects: Vec<Effect>,
    #[serde(default)]
    pub changed_files: Vec<String>,
}

/// Submit a finished session: build its record and advance `state` per `mode`.
pub fn submit_session(
    compiled: &CompiledPlan,
    state: &StateProjection,
    rendered_session: &RenderedSession,
    input: &ExecutionInput,
    mode: SubmitMode,
    date: &str,
) -> Result<SubmitOutcome> {
    let validation = validate_execution_input(rendered_session, input);
    let record = build_training_record(rendered_session, input, date);
    if validation.status != ValidationStatus::Valid {
        return Ok(SubmitOutcome {
            validation,
            record,
            new_state: state.clone(),
            effects: Vec::new(),
            changed_files: Vec::new(),
        });
    }

    // A `partial` submit is not special-cased here: it advances the cursor and
    // runs progression like any submit. Progression is gated per exercise (an
    // exercise only moves when all its working sets are done — see `reduce_item`),
    // so an unfinished session simply progresses the lifts that were completed and
    // leaves the rest untouched. The saved partial stays resumable from history by
    // its session id (`render_session` ignores the cursor).
    let (mut new_state, effects) = match mode {
        SubmitMode::Advance => {
            let reduced = reduce_input(compiled, state, rendered_session, input)?;
            (reduced.new_state, reduced.effects)
        }
        SubmitMode::OffDay => {
            // Record only: the lanes do not move. The session still happened, so
            // the cursor advances to the next workout.
            let mut new_state = state.clone();
            advance_after(compiled, &mut new_state, rendered_session);
            (new_state, Vec::new())
        }
        SubmitMode::Reset => {
            let mut new_state = state.clone();
            let effects = reset_baselines(&mut new_state, rendered_session, input);
            advance_after(compiled, &mut new_state, rendered_session);
            (new_state, effects)
        }
    };

    for lane in effects
        .iter()
        .map(|effect| &effect.lane)
        .collect::<std::collections::BTreeSet<_>>()
    {
        if let Some(item) = rendered_session
            .items
            .iter()
            .find(|item| item.progression_lane == *lane)
        {
            new_state.previous_lanes.insert(
                lane.clone(),
                LaneCheckpoint {
                    record_id: record.id.clone(),
                    previous_state: state.lanes.get(lane).cloned().unwrap_or_default(),
                    item: Box::new(item.clone()),
                },
            );
        }
    }

    Ok(SubmitOutcome {
        validation,
        record,
        new_state,
        effects,
        changed_files: Vec::new(),
    })
}

/// Advance the cursor to the next workout if it is still sitting on the session
/// just submitted (mirrors the idempotent guard in `reduce_input`).
fn advance_after(
    compiled: &CompiledPlan,
    state: &mut StateProjection,
    rendered_session: &RenderedSession,
) {
    if state
        .cursor
        .next_session
        .eq_ignore_ascii_case(&rendered_session.session_id)
    {
        advance_cursor(
            state,
            &compiled.schedule.rotation,
            &rendered_session.session_id,
        );
    }
}

/// Reset each performed lane's baseline to the load that was just used. Lanes
/// driven by a training max (5/3/1) reset the training max; load-driven lanes
/// (GZCLP, Starting Strength) reset the working load. Returns the changes for
/// the preview.
fn reset_baselines(
    state: &mut StateProjection,
    rendered_session: &RenderedSession,
    input: &ExecutionInput,
) -> Vec<Effect> {
    let mut effects = Vec::new();
    for item in &rendered_session.items {
        let Some(item_input) = find_input(input, &item.item_id) else {
            continue;
        };
        let Some(weight) = performed_weight(item, item_input) else {
            continue;
        };
        let Some(lane) = state.lanes.get_mut(&item.progression_lane) else {
            continue;
        };
        lane.stall = Some(0);
        if lane.training_max.is_some() {
            let from = lane.training_max.clone();
            lane.training_max = Some(weight.clone());
            effects.push(Effect {
                op: "reset_training_max".into(),
                lane: item.progression_lane.clone(),
                from,
                to: Some(weight),
            });
        } else {
            let from = lane.load.clone();
            lane.load = Some(weight.clone());
            effects.push(Effect {
                op: "reset_load".into(),
                lane: item.progression_lane.clone(),
                from,
                to: Some(weight),
            });
        }
    }
    effects
}

/// Build the lean record for the day from what was performed. Independent of
/// mode and of the program — it is purely descriptive.
fn build_training_record(
    rendered_session: &RenderedSession,
    input: &ExecutionInput,
    date: &str,
) -> TrainingRecord {
    let started_at = input.started_at.clone().unwrap_or_default();
    let record_id = workout_record_id(&rendered_session.rendered_session_hash, &started_at);
    let mut lifts = Vec::new();
    for item_input in &input.inputs {
        if let Some(item) = rendered_session
            .items
            .iter()
            .find(|item| item.item_id == item_input.item_id)
        {
            let exercise = item_input
                .performed_exercise
                .clone()
                .unwrap_or_else(|| item.exercise.clone());
            lifts.push(LiftRecord {
                lift_id: lift_record_id(&record_id, &item.item_id),
                item_id: Some(item.item_id.clone()),
                exercise,
                weight: performed_weight(item, item_input),
                sets: performed_reps(item, item_input),
                actual: performed_actual(item, item_input)
                    .into_iter()
                    .filter(|set| !set.metrics.is_empty())
                    .collect(),
                metrics: Default::default(),
                note: None,
            });
        } else if let Some(lift) =
            extra_lift_record(&record_id, item_input, input.status == "partial")
        {
            lifts.push(lift);
        }
    }
    let mut record = TrainingRecord::workout(
        record_id,
        date,
        rendered_session.session_id.clone(),
        started_at,
        lifts,
    );
    if input.status == "partial" {
        record.status = Some(input.status.clone());
        record.completed_at = None;
        record.saved_at = input.saved_at.clone();
    } else {
        record.completed_at = input.completed_at.clone();
    }
    record
}

fn extra_lift_record(
    record_id: &str,
    item_input: &ItemInput,
    include_item_id: bool,
) -> Option<LiftRecord> {
    if item_input.sets.is_empty() && item_input.final_set_reps.is_none() {
        return None;
    }
    let exercise = item_input
        .performed_exercise
        .clone()
        .unwrap_or_else(|| item_input.item_id.clone());
    let mut sets = item_input.sets.clone();
    sets.sort_by_key(|set| set.set);
    let reps = if sets.is_empty() {
        item_input.final_set_reps.into_iter().collect()
    } else {
        sets.iter().map(|set| set.reps).collect()
    };
    let actual = sets
        .iter()
        .filter(|set| !set.metrics.is_empty())
        .cloned()
        .collect();
    Some(LiftRecord {
        lift_id: lift_record_id(record_id, &item_input.item_id),
        item_id: include_item_id.then(|| item_input.item_id.clone()),
        exercise,
        weight: item_input
            .load
            .clone()
            .or_else(|| sets.first().and_then(|set| set.load.clone())),
        sets: reps,
        actual,
        metrics: Default::default(),
        note: None,
    })
}

fn find_input<'a>(input: &'a ExecutionInput, item_id: &str) -> Option<&'a ItemInput> {
    input
        .inputs
        .iter()
        .find(|candidate| candidate.item_id == item_id)
}

/// Per-set detail for metrics that cannot fit in the compact `sets` vector.
/// AMRAP inputs normally carry only `final_set_reps`, but clients may include
/// set-numbered metrics alongside them; those metrics are merged into the
/// reconstructed prescribed sets here.
fn performed_actual(item: &RenderedItem, item_input: &ItemInput) -> Vec<ActualSet> {
    if item_input.mode == "amrap_final_set" {
        let mut sets = item
            .prescription
            .sets
            .iter()
            .map(|set| {
                let logged = item_input.sets.iter().find(|actual| actual.set == set.set);
                ActualSet {
                    set: set.set,
                    load: item_input
                        .load
                        .clone()
                        .or_else(|| logged.and_then(|actual| actual.load.clone()))
                        .or_else(|| set.load.clone()),
                    reps: set.target_reps,
                    metrics: logged
                        .map(|actual| actual.metrics.clone())
                        .unwrap_or_default(),
                }
            })
            .collect::<Vec<_>>();
        if let (Some(last), Some(final_reps)) = (sets.last_mut(), item_input.final_set_reps) {
            last.reps = final_reps;
        }
        let prescribed = item
            .prescription
            .sets
            .iter()
            .map(|set| set.set)
            .collect::<std::collections::BTreeSet<_>>();
        let mut extras = item_input
            .sets
            .iter()
            .filter(|actual| !prescribed.contains(&actual.set))
            .cloned()
            .collect::<Vec<_>>();
        extras.sort_by_key(|set| set.set);
        sets.extend(extras);
        return sets;
    }

    let mut sets = item_input.sets.clone();
    sets.sort_by_key(|set| set.set);
    sets
}

/// Reps achieved per set, in order. For `per_set_reps` inputs this is the
/// recorded sets; for `amrap_final_set` inputs (e.g. GZCLP T1) the preceding
/// sets are reconstructed from the prescription and the final set carries the
/// AMRAP result.
fn performed_reps(item: &RenderedItem, item_input: &ItemInput) -> Vec<u32> {
    if item_input.mode != "amrap_final_set" && !item_input.sets.is_empty() {
        let mut sets: Vec<&_> = item_input.sets.iter().collect();
        sets.sort_by_key(|set| set.set);
        return sets.into_iter().map(|set| set.reps).collect();
    }
    let mut reps: Vec<u32> = item
        .prescription
        .sets
        .iter()
        .map(|set| set.target_reps)
        .collect();
    if let (Some(last), Some(final_reps)) = (reps.last_mut(), item_input.final_set_reps) {
        *last = final_reps;
    }
    let prescribed = item
        .prescription
        .sets
        .iter()
        .map(|set| set.set)
        .collect::<std::collections::BTreeSet<_>>();
    let mut extras = item_input
        .sets
        .iter()
        .filter(|actual| !prescribed.contains(&actual.set))
        .collect::<Vec<_>>();
    extras.sort_by_key(|set| set.set);
    reps.extend(extras.into_iter().map(|set| set.reps));
    reps
}

/// The load a lift was performed at: the item-level load, else the first
/// working set's load, else the prescribed load (AMRAP inputs carry no load
/// because the lifter used the prescription).
fn performed_weight(item: &RenderedItem, item_input: &ItemInput) -> Option<String> {
    item_input
        .load
        .clone()
        .or_else(|| {
            let mut sets: Vec<&_> = item_input.sets.iter().collect();
            sets.sort_by_key(|set| set.set);
            sets.first().and_then(|set| set.load.clone())
        })
        .or_else(|| {
            item.prescription
                .sets
                .first()
                .and_then(|set| set.load.clone())
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{
        compile_plan, create_initial_state, reduce_input, render_next, synthetic_execution_input,
    };
    use crate::templates::render_lockfile;
    use std::collections::BTreeMap;

    fn gzclp() -> CompiledPlan {
        let plan = r#"plan "Submit Test" {
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
"#;
        let lock = render_lockfile("gzcl.gzclp@1.0.0").unwrap();
        compile_plan(plan, &lock, &[]).unwrap()
    }

    /// A completed session at the prescribed loads, passing every set.
    fn passing_input(rendered: &RenderedSession) -> ExecutionInput {
        synthetic_execution_input(rendered, "pass", 0)
    }

    #[test]
    fn advance_runs_progression_and_records_the_day() {
        let compiled = gzclp();
        let state = create_initial_state(&compiled);
        let rendered = render_next(&compiled, &state).unwrap();
        let input = passing_input(&rendered);

        let outcome = submit_session(
            &compiled,
            &state,
            &rendered,
            &input,
            SubmitMode::Advance,
            "2026-06-24",
        )
        .unwrap();

        assert_eq!(outcome.validation.status, ValidationStatus::Valid);
        assert_eq!(outcome.record.date, "2026-06-24");
        assert!(!outcome.record.lifts.is_empty());
        // A passing T1 advances its lane's load, so state moved.
        assert_ne!(outcome.new_state.lanes, state.lanes);
        assert!(!outcome.effects.is_empty());
    }

    #[test]
    fn submit_preserves_per_set_metrics_in_record_detail() {
        let compiled = gzclp();
        let state = create_initial_state(&compiled);
        let rendered = render_next(&compiled, &state).unwrap();
        let mut input = passing_input(&rendered);
        let t1 = rendered
            .items
            .iter()
            .find(|item| item.item_id == "a1.t1")
            .unwrap();
        let final_set = t1.prescription.sets.last().unwrap();
        let item_input = input
            .inputs
            .iter_mut()
            .find(|item| item.item_id == "a1.t1")
            .unwrap();
        item_input.final_set_reps = Some(7);
        item_input.sets = vec![ActualSet {
            set: final_set.set,
            load: final_set.load.clone(),
            reps: 7,
            metrics: BTreeMap::from([("rpe".into(), "8.5".into())]),
        }];

        let outcome = submit_session(
            &compiled,
            &state,
            &rendered,
            &input,
            SubmitMode::Advance,
            "2026-06-24",
        )
        .unwrap();

        let squat = outcome
            .record
            .lifts
            .iter()
            .find(|lift| lift.exercise == "squat")
            .unwrap();
        assert_eq!(squat.sets.last(), Some(&7));
        assert_eq!(squat.actual.len(), 1);
        assert_eq!(
            squat.actual[0].metrics.get("rpe").map(String::as_str),
            Some("8.5")
        );
    }

    #[test]
    fn submit_records_tracking_only_extra_inputs_in_input_order() {
        let compiled = gzclp();
        let state = create_initial_state(&compiled);
        let rendered = render_next(&compiled, &state).unwrap();
        let mut input = passing_input(&rendered);
        let extra = ItemInput {
            item_id: "extra.landmine_press".into(),
            mode: "per_set_reps".into(),
            final_set_reps: None,
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
            load: None,
            performed_exercise: Some("landmine_press".into()),
            swap_reason: None,
            swap_policy: None,
        };
        input.inputs.insert(0, extra);

        let outcome = submit_session(
            &compiled,
            &state,
            &rendered,
            &input,
            SubmitMode::Advance,
            "2026-06-24",
        )
        .unwrap();

        assert_eq!(outcome.validation.status, ValidationStatus::Valid);
        assert_eq!(outcome.record.lifts[0].exercise, "landmine_press");
        assert_eq!(outcome.record.lifts[0].sets, vec![12, 12]);
        assert_eq!(outcome.record.lifts[0].weight.as_deref(), Some("20kg"));
    }

    #[test]
    fn bonus_sets_are_recorded_but_do_not_drive_progression() {
        let compiled = gzclp();
        let state = create_initial_state(&compiled);
        let rendered = render_next(&compiled, &state).unwrap();
        let t3 = rendered
            .items
            .iter()
            .find(|item| item.progression_rule.ends_with(".t3"))
            .unwrap();
        let mut input = passing_input(&rendered);
        let item_input = input
            .inputs
            .iter_mut()
            .find(|candidate| candidate.item_id == t3.item_id)
            .unwrap();
        item_input.sets.push(ActualSet {
            set: 99,
            load: t3
                .prescription
                .sets
                .first()
                .and_then(|set| set.load.clone()),
            reps: 99,
            metrics: BTreeMap::new(),
        });

        let outcome = submit_session(
            &compiled,
            &state,
            &rendered,
            &input,
            SubmitMode::Advance,
            "2026-06-24",
        )
        .unwrap();

        let recorded = outcome
            .record
            .lifts
            .iter()
            .find(|lift| lift.exercise == t3.exercise)
            .unwrap();
        assert_eq!(recorded.sets.last(), Some(&99));
        let preview = reduce_input(&compiled, &state, &rendered, &input).unwrap();
        assert!(
            preview
                .results
                .iter()
                .find(|result| result.slot_id == t3.slot_id)
                .unwrap()
                .actual
                .iter()
                .all(|set| set.set != 99)
        );
    }

    #[test]
    fn off_day_records_but_leaves_lanes_untouched() {
        let compiled = gzclp();
        let state = create_initial_state(&compiled);
        let rendered = render_next(&compiled, &state).unwrap();
        let input = passing_input(&rendered);

        let outcome = submit_session(
            &compiled,
            &state,
            &rendered,
            &input,
            SubmitMode::OffDay,
            "2026-06-24",
        )
        .unwrap();

        // Lanes unchanged: targets, stages, and fail-counts do not move.
        assert_eq!(outcome.new_state.lanes, state.lanes);
        assert!(outcome.effects.is_empty());
        // But the day is still recorded and the cursor still advanced.
        assert!(!outcome.record.lifts.is_empty());
        assert_ne!(
            outcome.new_state.cursor.next_session,
            state.cursor.next_session
        );
    }

    #[test]
    fn reset_sets_new_baseline_from_performed_loads() {
        let compiled = gzclp();
        let mut state = create_initial_state(&compiled);
        let rendered = render_next(&compiled, &state).unwrap();

        // Perform every working set lighter than prescribed.
        let mut input = passing_input(&rendered);
        for item in input.inputs.iter_mut() {
            item.load = Some("40kg".into());
            for set in item.sets.iter_mut() {
                set.load = Some("40kg".into());
            }
        }
        // Pretend a lane started somewhere else so the reset is observable.
        let lane = rendered.items[0].progression_lane.clone();
        state.lanes.entry(lane.clone()).or_default().load = Some("82.5kg".into());

        let outcome = submit_session(
            &compiled,
            &state,
            &rendered,
            &input,
            SubmitMode::Reset,
            "2026-06-24",
        )
        .unwrap();

        let lane_state = &outcome.new_state.lanes[&lane];
        assert_eq!(lane_state.load.as_deref(), Some("40kg"));
        assert!(outcome.effects.iter().any(|e| e.op == "reset_load"));
    }

    #[test]
    fn partial_save_advances_cursor_without_moving_lanes() {
        let compiled = gzclp();
        let state = create_initial_state(&compiled);
        let rendered = render_next(&compiled, &state).unwrap();
        let first_item = &rendered.items[0];
        let input = ExecutionInput {
            kind: "execution_input".into(),
            schema_version: crate::model::SCHEMA_VERSION.into(),
            rendered_session_hash: rendered.rendered_session_hash.clone(),
            status: "partial".into(),
            started_at: Some("2026-06-24T10:00:00Z".into()),
            completed_at: None,
            saved_at: Some("2026-06-24T10:45:00Z".into()),
            inputs: vec![ItemInput {
                item_id: first_item.item_id.clone(),
                mode: "per_set_reps".into(),
                final_set_reps: None,
                sets: vec![crate::model::ActualSet {
                    set: 1,
                    load: first_item.prescription.sets[0].load.clone(),
                    reps: first_item.prescription.sets[0].target_reps,
                    metrics: Default::default(),
                }],
                load: None,
                performed_exercise: None,
                swap_reason: None,
                swap_policy: None,
            }],
        };

        let outcome = submit_session(
            &compiled,
            &state,
            &rendered,
            &input,
            SubmitMode::Advance,
            "2026-06-24",
        )
        .unwrap();

        assert_eq!(outcome.validation.status, ValidationStatus::Valid);
        // The cursor moves on to the next workout, but the only logged exercise was
        // unfinished (one set of many), so no lift progresses and the lanes are left
        // exactly as they were.
        assert_eq!(state.cursor.next_session, "a1");
        assert_eq!(outcome.new_state.cursor.next_session, "b1");
        assert_eq!(outcome.new_state.lanes, state.lanes);
        assert!(outcome.effects.is_empty());
        assert_eq!(outcome.record.status.as_deref(), Some("partial"));
        assert_eq!(outcome.record.session_id.as_deref(), Some("a1"));
        assert_eq!(
            outcome.record.lifts[0].item_id.as_deref(),
            Some(first_item.item_id.as_str())
        );
    }

    #[test]
    fn partial_submit_progresses_finished_lifts_and_skips_unfinished_ones() {
        let compiled = gzclp();
        let state = create_initial_state(&compiled);
        let rendered = render_next(&compiled, &state).unwrap();

        let t1 = rendered
            .items
            .iter()
            .find(|item| item.progression_rule.ends_with(".t1"))
            .unwrap();
        let t2 = rendered
            .items
            .iter()
            .find(|item| item.progression_rule.ends_with(".t2"))
            .unwrap();
        let t1_lane = t1.progression_lane.clone();
        let t2_lane = t2.progression_lane.clone();
        let t1_load_before = state.lanes[&t1_lane].load.clone();
        let t2_load_before = state.lanes[&t2_lane].load.clone();

        // A "save progress": T1 finished (every set passing), T2 only one set logged.
        let mut input = passing_input(&rendered);
        input.status = "partial".into();
        input.completed_at = None;
        input.saved_at = Some("2026-06-24T10:45:00Z".into());
        let t2_input = input
            .inputs
            .iter_mut()
            .find(|candidate| candidate.item_id == t2.item_id)
            .unwrap();
        t2_input.mode = "per_set_reps".into();
        t2_input.final_set_reps = None;
        t2_input.sets = vec![ActualSet {
            set: t2.prescription.sets[0].set,
            load: t2.prescription.sets[0].load.clone(),
            reps: t2.prescription.sets[0].target_reps,
            metrics: BTreeMap::new(),
        }];

        let outcome = submit_session(
            &compiled,
            &state,
            &rendered,
            &input,
            SubmitMode::Advance,
            "2026-06-24",
        )
        .unwrap();

        assert_eq!(outcome.validation.status, ValidationStatus::Valid);
        // Cursor moves on even though the session was not finished.
        assert_ne!(
            outcome.new_state.cursor.next_session,
            state.cursor.next_session
        );
        // The finished T1 lift progressed; the unfinished T2 lift stayed put.
        assert_ne!(outcome.new_state.lanes[&t1_lane].load, t1_load_before);
        assert_eq!(outcome.new_state.lanes[&t2_lane].load, t2_load_before);
    }
}
