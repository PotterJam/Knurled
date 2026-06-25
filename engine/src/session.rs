//! Submit-time progression against `state` (ADR 0007).
//!
//! In the logs-as-record model, finishing a session does two independent things:
//! it appends a lean [`DayRecord`] to the log (what happened), and it advances
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

use serde::{Deserialize, Serialize};

use crate::core::{advance_cursor, reduce_input, validate_execution_input};
use crate::error::Result;
use crate::model::{
    CompiledPlan, Effect, ExecutionInput, ExecutionInputValidation, ItemInput, RenderedSession,
    StateProjection, ValidationStatus,
};
use crate::record::{DayRecord, LiftRecord};

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
    /// The day to upsert into `logs/<yyyy>/<mm>.json`.
    pub record_day: DayRecord,
    /// The new state to write to `state/current.json`.
    pub new_state: StateProjection,
    /// State changes applied, for the app's consequence-first preview.
    pub effects: Vec<Effect>,
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
    let record_day = build_record_day(rendered_session, input, date);

    let validation = validate_execution_input(rendered_session, input);
    if validation.status != ValidationStatus::Valid {
        return Ok(SubmitOutcome {
            validation,
            record_day,
            new_state: state.clone(),
            effects: Vec::new(),
        });
    }

    let (new_state, effects) = match mode {
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

    Ok(SubmitOutcome {
        validation,
        record_day,
        new_state,
        effects,
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
        let Some(weight) = performed_weight(item_input) else {
            continue;
        };
        let Some(lane) = state.lanes.get_mut(&item.progression_lane) else {
            continue;
        };
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
fn build_record_day(
    rendered_session: &RenderedSession,
    input: &ExecutionInput,
    date: &str,
) -> DayRecord {
    let mut lifts = Vec::new();
    for item in &rendered_session.items {
        let Some(item_input) = find_input(input, &item.item_id) else {
            continue;
        };
        let exercise = item_input
            .performed_exercise
            .clone()
            .unwrap_or_else(|| item.exercise.clone());
        let weight = performed_weight(item_input);
        let mut reps: Vec<(u32, u32)> = item_input
            .sets
            .iter()
            .map(|set| (set.set, set.reps))
            .collect();
        reps.sort_by_key(|(set, _)| *set);
        lifts.push(LiftRecord {
            exercise,
            weight,
            sets: reps.into_iter().map(|(_, reps)| reps).collect(),
            metrics: Default::default(),
            note: None,
        });
    }
    DayRecord::workout(date, lifts)
}

fn find_input<'a>(input: &'a ExecutionInput, item_id: &str) -> Option<&'a ItemInput> {
    input
        .inputs
        .iter()
        .find(|candidate| candidate.item_id == item_id)
}

/// The load a lift was performed at: the item-level load if given, else the load
/// recorded on the first working set.
fn performed_weight(item_input: &ItemInput) -> Option<String> {
    item_input
        .load
        .clone()
        .or_else(|| item_input.sets.first().and_then(|set| set.load.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{compile_plan, create_initial_state, render_next, synthetic_execution_input};
    use crate::templates::render_lockfile;

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

        let outcome =
            submit_session(&compiled, &state, &rendered, &input, SubmitMode::Advance, "2026-06-24")
                .unwrap();

        assert_eq!(outcome.validation.status, ValidationStatus::Valid);
        assert_eq!(outcome.record_day.date, "2026-06-24");
        assert!(!outcome.record_day.lifts.is_empty());
        // A passing T1 advances its lane's load, so state moved.
        assert_ne!(outcome.new_state.lanes, state.lanes);
        assert!(!outcome.effects.is_empty());
    }

    #[test]
    fn off_day_records_but_leaves_lanes_untouched() {
        let compiled = gzclp();
        let state = create_initial_state(&compiled);
        let rendered = render_next(&compiled, &state).unwrap();
        let input = passing_input(&rendered);

        let outcome =
            submit_session(&compiled, &state, &rendered, &input, SubmitMode::OffDay, "2026-06-24")
                .unwrap();

        // Lanes unchanged: targets, stages, and fail-counts do not move.
        assert_eq!(outcome.new_state.lanes, state.lanes);
        assert!(outcome.effects.is_empty());
        // But the day is still recorded and the cursor still advanced.
        assert!(!outcome.record_day.lifts.is_empty());
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

        let outcome =
            submit_session(&compiled, &state, &rendered, &input, SubmitMode::Reset, "2026-06-24")
                .unwrap();

        let lane_state = &outcome.new_state.lanes[&lane];
        assert_eq!(lane_state.load.as_deref(), Some("40kg"));
        assert!(outcome.effects.iter().any(|e| e.op == "reset_load"));
    }
}
