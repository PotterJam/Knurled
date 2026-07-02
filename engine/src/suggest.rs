//! Advisory program adjustments. Suggestions never mutate authored state or plans.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::calendar::distinct_workout_weeks;
use crate::error::Result;
use crate::messages::title_words;
use crate::record::RecordKind;
use crate::repo::{read_records, read_state};
use crate::templates::{BuiltinTemplateInfo, builtin_template_info};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramAdjustmentSuggestion {
    pub kind: String,
    pub lane: String,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proposed_value: Option<String>,
    /// Human copy for the suggestion card (RFC-0001 D3); `reason` stays the
    /// technical explanation.
    #[serde(default)]
    pub user_description: String,
}

/// Training weeks without a deload before the engine suggests one (RFC-0001 D6).
const DELOAD_SUGGESTION_WEEKS: usize = 8;

pub fn suggest_program_adjustments(
    repo_path: impl AsRef<Path>,
) -> Result<Vec<ProgramAdjustmentSuggestion>> {
    let root = repo_path.as_ref();
    let state = read_state(root)?;
    let records = read_records(root)?;
    let mut suggestions = Vec::new();
    for (lane, lane_state) in &state.lanes {
        let display = lane_label(lane);
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
                user_description: format!(
                    "{display} is at its last fallback stage. Plan a lighter reset before the next attempt."
                ),
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
                user_description: format!(
                    "{display} has stalled — three attempts at the same weight without finishing. Consider dropping the load."
                ),
            });
        }
    }

    // Marker-based deload nudge (RFC-0001 D6): distinct calendar weeks with
    // workouts since the last deload or program start. Deliberately does not
    // depend on the deferred progress module (RFC-0003).
    let last_break = records
        .iter()
        .filter(|record| matches!(record.kind, RecordKind::Deload | RecordKind::ProgramMarker))
        .map(|record| record.date.as_str())
        .max();
    let weeks = distinct_workout_weeks(&records, last_break);
    if weeks >= DELOAD_SUGGESTION_WEEKS {
        suggestions.push(ProgramAdjustmentSuggestion {
            kind: "deload_week".into(),
            lane: "all".into(),
            reason: format!(
                "{weeks} distinct training weeks recorded since the last deload or program start."
            ),
            proposed_value: Some("10%".into()),
            user_description: format!(
                "It's been {weeks} weeks of training without a deload. Time for a lighter week?"
            ),
        });
    }
    Ok(suggestions)
}

fn lane_label(lane: &str) -> String {
    title_words(lane.split('.').next().unwrap_or(lane))
}

// ---------------------------------------------------------------------------
// Template recommendation (RFC-0001 D2)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Experience {
    Beginner,
    Intermediate,
    Advanced,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Goal {
    Strength,
    Hypertrophy,
    Mixed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProfileRequest {
    pub experience: Experience,
    pub days_per_week: u8,
    pub goal: Goal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TemplateRecommendation {
    /// `id@version` reference to pass to `init_training_repo` / `add_program`.
    pub primary_ref: String,
    pub display_name: String,
    pub rationale: String,
    pub alternates: Vec<TemplateAlternate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TemplateAlternate {
    pub reference: String,
    pub display_name: String,
    pub reason: String,
}

/// Engine-owned "help me choose" matching over the built-in templates. The
/// wizard collects three answers; the engine owns which program they map to
/// and the words explaining why, so clients never hardcode program knowledge.
pub fn recommend_template(profile: &ProfileRequest) -> TemplateRecommendation {
    let four_plus_days = profile.days_per_week >= 4;
    let (primary, rationale, alternates): (&str, String, Vec<(&str, &str)>) = if four_plus_days {
        let primary = match profile.experience {
            Experience::Beginner => "531.beginners",
            _ => "531.basic",
        };
        (
            primary,
            format!(
                "With {} training days a week, a four-day 5/3/1 split gives every big lift its own day and steady monthly waves{}.",
                profile.days_per_week,
                match profile.goal {
                    Goal::Hypertrophy =>
                        ", with room for the assistance volume that drives muscle growth",
                    Goal::Mixed => ", balancing heavy top sets with assistance volume",
                    Goal::Strength => "",
                }
            ),
            vec![(
                "gzcl.gzclp",
                "Prefer pushing weight up every session instead of monthly waves? GZCLP also runs well on four days.",
            )],
        )
    } else {
        match profile.experience {
            Experience::Advanced => (
                "531.basic",
                "On three days a week with training experience, 5/3/1's training-max waves keep progress coming when session-to-session jumps have dried up.".to_owned(),
                vec![(
                    "gzcl.gzclp",
                    "If you'd rather retest linear progress first, GZCLP will find your working weights fast.",
                )],
            ),
            _ => (
                "gzcl.gzclp",
                match profile.goal {
                    Goal::Strength => "GZCLP adds weight every session you earn it, with built-in fallbacks instead of grinding stalls — the fastest route to strength on three days a week.".to_owned(),
                    Goal::Hypertrophy => "GZCLP pairs its heavy main lift with lighter supplemental and accessory work, so you get high-rep volume for muscle alongside steady strength gains.".to_owned(),
                    Goal::Mixed => "GZCLP covers both bases on three days a week: heavy main-lift progress plus supplemental and accessory volume.".to_owned(),
                },
                vec![
                    (
                        "starting-strength.phase1",
                        "Want the absolute minimum moving parts? Starting Strength is the classic bare-bones novice program.",
                    ),
                    (
                        "531.beginners",
                        "Prefer calmer, percentage-based waves over session-to-session jumps? 5/3/1 for Beginners fits three or four days.",
                    ),
                ],
            ),
        }
    };

    let info = |id: &str| -> &'static BuiltinTemplateInfo {
        builtin_template_info(id).expect("recommendation table only names built-in templates")
    };
    let primary_info = info(primary);
    TemplateRecommendation {
        primary_ref: format!("{}@{}", primary_info.id, primary_info.version),
        display_name: primary_info.display_name.to_owned(),
        rationale,
        alternates: alternates
            .into_iter()
            .map(|(id, reason)| {
                let info = info(id);
                TemplateAlternate {
                    reference: format!("{}@{}", info.id, info.version),
                    display_name: info.display_name.to_owned(),
                    reason: reason.to_owned(),
                }
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn beginner_three_day_strength_gets_gzclp() {
        let recommendation = recommend_template(&ProfileRequest {
            experience: Experience::Beginner,
            days_per_week: 3,
            goal: Goal::Strength,
        });
        assert_eq!(recommendation.primary_ref, "gzcl.gzclp@1.0.0");
        assert!(!recommendation.rationale.is_empty());
        assert!(!recommendation.alternates.is_empty());
    }

    #[test]
    fn four_days_prefers_531_variants_by_experience() {
        let beginner = recommend_template(&ProfileRequest {
            experience: Experience::Beginner,
            days_per_week: 4,
            goal: Goal::Mixed,
        });
        assert_eq!(beginner.primary_ref, "531.beginners@1.0.0");
        let advanced = recommend_template(&ProfileRequest {
            experience: Experience::Advanced,
            days_per_week: 4,
            goal: Goal::Strength,
        });
        assert_eq!(advanced.primary_ref, "531.basic@1.0.0");
    }

    #[test]
    fn advanced_three_day_gets_531() {
        let recommendation = recommend_template(&ProfileRequest {
            experience: Experience::Advanced,
            days_per_week: 3,
            goal: Goal::Strength,
        });
        assert_eq!(recommendation.primary_ref, "531.basic@1.0.0");
    }

    #[test]
    fn every_recommendation_references_a_built_in() {
        for experience in [
            Experience::Beginner,
            Experience::Intermediate,
            Experience::Advanced,
        ] {
            for days in 1..=6 {
                for goal in [Goal::Strength, Goal::Hypertrophy, Goal::Mixed] {
                    let recommendation = recommend_template(&ProfileRequest {
                        experience,
                        days_per_week: days,
                        goal,
                    });
                    assert!(recommendation.primary_ref.contains('@'));
                    for alternate in &recommendation.alternates {
                        assert_ne!(alternate.reference, recommendation.primary_ref);
                    }
                }
            }
        }
    }
}
