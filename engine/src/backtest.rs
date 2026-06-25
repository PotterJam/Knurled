//! Standalone backtest over the lean record (ADR 0007).
//!
//! Backtesting is the one engine consumer of the log besides the human, and it
//! is opt-in. It answers "if I had been running *this* program, what would it
//! have done with my actual performance?" — a pure function of `(recorded
//! numbers, candidate program)`. It needs only the lean record (exercise +
//! reps), never replay metadata, so it imposes no cost on the log format.
//!
//! The recorded reps are mapped onto the candidate program's prescriptions by
//! exercise name and fed through the same progression rules as a live submit.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::core::{create_initial_state, reduce_input, render_next, synthetic_execution_input};
use crate::error::Result;
use crate::model::{CompiledPlan, Effect, ENGINE_VERSION, StateProjection};
use crate::parser::normalize_exercise;
use crate::record::DayRecord;

/// What the candidate program would have done on one recorded day.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BacktestStep {
    pub date: String,
    pub session_id: String,
    pub display_name: String,
    pub effects: Vec<Effect>,
}

/// The projection of a candidate program over a record.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BacktestProjection {
    #[serde(rename = "type")]
    pub kind: String,
    pub engine_version: String,
    pub sessions_replayed: usize,
    pub steps: Vec<BacktestStep>,
    pub final_state: StateProjection,
}

/// Run `compiled` forward over the workout days in `days`, feeding each day's
/// recorded reps into the program's prescriptions and progressing as a live
/// submit would. Program-boundary markers and empty days are skipped.
pub fn backtest(compiled: &CompiledPlan, days: &[DayRecord]) -> Result<BacktestProjection> {
    let mut workout_days: Vec<&DayRecord> =
        days.iter().filter(|day| !day.lifts.is_empty()).collect();
    workout_days.sort_by(|left, right| left.date.cmp(&right.date));

    let mut state = create_initial_state(compiled);
    let mut steps = Vec::new();

    for day in workout_days {
        let rendered = render_next(compiled, &state)?;

        // Recorded reps keyed by normalized exercise. Last entry wins if a day
        // repeats an exercise (a known limitation of name-based matching).
        let recorded: BTreeMap<String, Vec<u32>> = day
            .lifts
            .iter()
            .map(|lift| (normalize_exercise(&lift.exercise), lift.sets.clone()))
            .collect();

        let exercise_by_item: BTreeMap<String, String> = rendered
            .items
            .iter()
            .map(|item| (item.item_id.clone(), normalize_exercise(&item.exercise)))
            .collect();

        let mut input = synthetic_execution_input(&rendered, "pass", 0);
        for item_input in input.inputs.iter_mut() {
            let Some(exercise) = exercise_by_item.get(&item_input.item_id) else {
                continue;
            };
            let Some(reps) = recorded.get(exercise) else {
                continue;
            };
            if !item_input.sets.is_empty() {
                for (set, recorded_reps) in item_input.sets.iter_mut().zip(reps.iter()) {
                    set.reps = *recorded_reps;
                }
            } else if let Some(last) = reps.last() {
                // amrap_final_set: the AMRAP result is the last recorded set.
                item_input.final_set_reps = Some(*last);
            }
        }

        let reduced = reduce_input(compiled, &state, &rendered, &input)?;
        steps.push(BacktestStep {
            date: day.date.clone(),
            session_id: rendered.session_id.clone(),
            display_name: rendered.display_name.clone(),
            effects: reduced.effects.clone(),
        });
        state = reduced.new_state;
    }

    Ok(BacktestProjection {
        kind: "backtest_projection".into(),
        engine_version: ENGINE_VERSION.into(),
        sessions_replayed: steps.len(),
        steps,
        final_state: state,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{compile_plan, create_initial_state, render_next};
    use crate::session::{SubmitMode, submit_session};
    use crate::templates::render_lockfile;

    fn gzclp() -> CompiledPlan {
        let plan = r#"plan "Backtest" {
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

    /// Feeding a program its own performance records reproduces exactly the
    /// state its live progression produced — backtest is the same rules over
    /// the same numbers, read from the lean record alone.
    #[test]
    fn backtest_reproduces_live_progression() {
        let compiled = gzclp();
        let mut state = create_initial_state(&compiled);
        let mut days = Vec::new();

        for i in 0..4u32 {
            let rendered = render_next(&compiled, &state).unwrap();
            let input = synthetic_execution_input(&rendered, "pass", i);
            let date = format!("2026-06-0{}", i + 1);
            let outcome =
                submit_session(&compiled, &state, &rendered, &input, SubmitMode::Advance, &date)
                    .unwrap();
            days.push(outcome.record_day.clone());
            state = outcome.new_state;
        }

        let projection = backtest(&compiled, &days).unwrap();

        assert_eq!(projection.sessions_replayed, 4);
        assert_eq!(projection.steps.len(), 4);
        assert!(projection.steps.iter().any(|step| !step.effects.is_empty()));
        // The key property: same lanes as the live run.
        assert_eq!(projection.final_state.lanes, state.lanes);
    }

    #[test]
    fn markers_and_empty_days_are_skipped() {
        let compiled = gzclp();
        let days = vec![
            DayRecord::program_marker("2026-06-01", "gzcl.gzclp"),
            DayRecord::workout("2026-06-02", Vec::new()),
        ];
        let projection = backtest(&compiled, &days).unwrap();
        assert_eq!(projection.sessions_replayed, 0);
    }
}
