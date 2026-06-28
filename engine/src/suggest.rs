//! Advisory program adjustments. Suggestions never mutate authored state or plans.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::repo::{read_records, read_state};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramAdjustmentSuggestion {
    pub kind: String,
    pub lane: String,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proposed_value: Option<String>,
}

pub fn suggest_program_adjustments(
    repo_path: impl AsRef<Path>,
) -> Result<Vec<ProgramAdjustmentSuggestion>> {
    let root = repo_path.as_ref();
    let state = read_state(root)?;
    let records = read_records(root)?;
    let mut suggestions = Vec::new();
    for (lane, lane_state) in &state.lanes {
        if lane_state
            .stage
            .as_deref()
            .is_some_and(|stage| matches!(stage, "10x1+" | "3x6"))
        {
            suggestions.push(ProgramAdjustmentSuggestion {
                kind: "deload".into(),
                lane: lane.clone(),
                reason: "This lane is at the final failure stage; review its load before the next attempt.".into(),
                proposed_value: lane_state.load.clone(),
            });
        }
        let exercise = lane.split('.').next().unwrap_or(lane);
        let recent = records
            .iter()
            .rev()
            .flat_map(|record| record.lifts.iter())
            .filter(|lift| lift.exercise.eq_ignore_ascii_case(exercise))
            .take(3)
            .collect::<Vec<_>>();
        if recent.len() == 3
            && recent.iter().all(|lift| lift.weight == recent[0].weight)
            && recent
                .iter()
                .all(|lift| lift.sets.last().copied().unwrap_or_default() == 0)
        {
            suggestions.push(ProgramAdjustmentSuggestion {
                kind: "stall".into(),
                lane: lane.clone(),
                reason: "Three recent attempts at the same load ended with zero final-set reps."
                    .into(),
                proposed_value: lane_state.load.clone(),
            });
        }
    }
    Ok(suggestions)
}
