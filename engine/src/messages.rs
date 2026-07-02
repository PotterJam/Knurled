//! Engine-owned human copy (RFC-0001 D3/D9).
//!
//! The engine owns meaning *and* the human rendering of its own concepts:
//! validation codes get user-facing sentences here, template vocabulary gets
//! group labels, and truly untranslatable terms (AMRAP, e1RM) get one
//! `explain` entry each. Clients never hardcode per-code or per-tier strings.

use serde::{Deserialize, Serialize};

/// Human explanation of one validation code, for the error detail screen.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ValidationExplanation {
    pub code: String,
    pub title: String,
    pub body: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
}

/// One glossary entry for a term the app cannot translate away (AMRAP, e1RM).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Explanation {
    pub term: String,
    pub title: String,
    pub body: String,
}

/// Copy for a validation code: (title, body, hint).
fn code_copy(code: &str) -> Option<(&'static str, &'static str, Option<&'static str>)> {
    Some(match code {
        "lock_hash_mismatch" => (
            "Program file changed outside the app",
            "The locked template no longer matches its recorded fingerprint, so the program can't be trusted as-is.",
            Some("Re-save the program (or restore the template file) to refresh the lock."),
        ),
        "lock_version_mismatch" => (
            "Program version mismatch",
            "The plan asks for a different template version than the one that was locked.",
            Some("Re-save the program to re-lock it at the current version."),
        ),
        "lock_engine_mismatch" => (
            "Program was locked by a different engine version",
            "The lock file was written by another version of the engine.",
            Some("Re-save the program to refresh the lock."),
        ),
        "missing_lock_entry" => (
            "Program isn't locked yet",
            "There is no lock entry for this template, so its exact behaviour isn't pinned.",
            Some("Saving the program writes the lock entry."),
        ),
        "unknown_template" => (
            "Unknown program template",
            "The plan references a template this engine doesn't ship.",
            Some("Pick one of the built-in programs, or restore the custom template file."),
        ),
        "missing_custom_start" => (
            "A starting weight is missing",
            "Every progressing lift needs a starting weight (or training max) before workouts can be built.",
            Some("Add the missing number in Plan Overview → starting weights."),
        ),
        "invalid_lane_regex" => (
            "A change targets lifts with a broken pattern",
            "One of the plan's changes uses a lift-matching pattern that isn't valid.",
            Some("Remove or re-create the change; guided edits always write valid patterns."),
        ),
        "invalid_scale_percent" => (
            "Temporary load change is out of range",
            "A temporary load adjustment must be between −90% and +100% and not zero.",
            Some("Re-create the temporary change with a smaller adjustment."),
        ),
        "invalid_warmup_percentage" => (
            "Warmup step percentage is out of range",
            "Warmup ramp steps must be between 1% and 100% of the working weight.",
            Some("Fix the step in the warmup editor."),
        ),
        "invalid_warmup_reps" => (
            "Warmup step has no reps",
            "Every warmup ramp step needs at least one rep.",
            Some("Fix the step in the warmup editor."),
        ),
        "invalid_bar_weight" => (
            "Bar weight must be positive",
            "An equipment bar is set to zero or a negative weight.",
            Some("Fix the bar weight under Equipment."),
        ),
        "invalid_plate" => (
            "Plates must be positive weights",
            "The equipment profile lists a plate that is zero or negative.",
            Some("Fix the plate list under Equipment."),
        ),
        "invalid_dumbbell" => (
            "Dumbbells must be positive weights",
            "The equipment profile lists a dumbbell that is zero or negative.",
            Some("Fix the dumbbell list under Equipment."),
        ),
        "empty_equipment" => (
            "Equipment has no plates or dumbbells",
            "With no plates or dumbbells listed, loads fall back to simple 2.5-unit rounding.",
            Some("Add your plates under Equipment to get exact loadable weights."),
        ),
        "missing_template" => (
            "Nothing to preview",
            "The preview needs a template to render.",
            None,
        ),
        "template_parse_error" => (
            "The program text couldn't be read",
            "The template has a syntax problem and can't be parsed.",
            Some("The detail below points at the offending line."),
        ),
        "template_compile_error" => (
            "The program couldn't be built",
            "The template parsed but couldn't be compiled into workouts.",
            Some("The detail below explains what's inconsistent."),
        ),
        "invalid_type" => (
            "Unrecognised workout data",
            "The submitted workout data wasn't in the shape the engine expects.",
            None,
        ),
        "rendered_session_hash_mismatch" => (
            "Workout no longer matches the plan",
            "This workout was started from an older version of the plan, so its results can't be applied as-is.",
            Some("Finish and save the workout as a record, or restart it from the current plan."),
        ),
        "missing_started_at" | "invalid_started_at" => (
            "Workout start time is missing",
            "A workout needs a valid start time to be recorded.",
            None,
        ),
        "missing_completed_at" | "invalid_completed_at" => (
            "Workout finish time is missing",
            "A workout needs a valid finish time to be recorded.",
            None,
        ),
        _ => return None,
    })
}

/// Human explanation for a validation code. Unknown codes get honest generic
/// copy rather than an error, so the app can always render *something*.
pub fn validation_code_message(code: &str) -> ValidationExplanation {
    match code_copy(code) {
        Some((title, body, hint)) => ValidationExplanation {
            code: code.to_owned(),
            title: title.to_owned(),
            body: body.to_owned(),
            hint: hint.map(str::to_owned),
        },
        None => ValidationExplanation {
            code: code.to_owned(),
            title: "The plan has a problem".to_owned(),
            body: "The engine reported a problem it has no friendlier wording for yet. The technical detail is shown below.".to_owned(),
            hint: None,
        },
    }
}

/// The one-line `user_message` stamped onto every `ValidationMessage` at
/// construction. Parameterised codes splice the specific subject back in from
/// the technical text so "add a starting weight" says *which* lift.
pub(crate) fn user_message(code: &str, technical: &str) -> String {
    if code == "missing_custom_start"
        && let Some(exercise) = technical.rsplit(" for ").next().filter(|s| !s.is_empty())
    {
        return format!(
            "Add a starting weight for {} before this program can build workouts.",
            title_words(exercise)
        );
    }
    match code_copy(code) {
        Some((title, _, Some(hint))) => format!("{title}. {hint}"),
        Some((title, body, None)) => format!("{title}. {body}"),
        None => technical.to_owned(),
    }
}

/// Template-vocabulary group label for a lane's tier (RFC-0001 D3): the role a
/// lift plays in this program, in the program's own words. Recognised template
/// families get their canonical vocabulary; custom templates fall back to a
/// generic reading of the tier, and unknown tiers to none at all.
pub(crate) fn tier_group_label(template_id: &str, tier: &str) -> Option<String> {
    let tier = tier.to_ascii_lowercase();
    if template_id.starts_with("531.") && tier == "main" {
        return Some("5/3/1 sets".to_owned());
    }
    if template_id.starts_with("starting-strength.") && tier == "linear" {
        return Some("Work sets".to_owned());
    }
    match tier.as_str() {
        "t1" => Some("Main lift".to_owned()),
        "t2" => Some("Supplemental".to_owned()),
        "t3" => Some("Accessory".to_owned()),
        "main" => Some("Main lift".to_owned()),
        "linear" => Some("Work sets".to_owned()),
        _ => None,
    }
}

/// Glossary for terms the UI cannot translate away. Returns `None` for
/// anything not in the (deliberately short) list.
pub fn explain(term: &str) -> Option<Explanation> {
    let normalized = term
        .trim()
        .to_ascii_lowercase()
        .replace([' ', '-'], "_")
        .replace(['/', '+'], "");
    let (title, body): (&str, &str) = match normalized.as_str() {
        "amrap" => (
            "AMRAP — as many reps as possible",
            "On an AMRAP set you keep going past the target as long as your form holds. The reps you get decide how the program progresses.",
        ),
        "rpe" => (
            "RPE — rating of perceived exertion",
            "A 1–10 score of how hard a set felt. RPE 10 means nothing left; RPE 8 means about two more reps were there.",
        ),
        "e1rm" => (
            "e1RM — estimated one-rep max",
            "An estimate of the most you could lift once, computed from a set's weight and reps. Used to track strength without actually maxing out.",
        ),
        "training_max" | "tm" => (
            "Training max",
            "A working ceiling — usually 85–90% of your true max — that percentage programs like 5/3/1 compute their weights from.",
        ),
        "working_weight" => (
            "Working weight",
            "The weight your work sets use today. Linear programs move it up a little every session you pass.",
        ),
        "deload" => (
            "Deload",
            "A deliberate step back — lighter weights for a stretch — so you recover and keep progressing. Programs bake them in after stalls or long runs.",
        ),
        "rotation" => (
            "Rotation",
            "The repeating order of workout days (like A1, B1, A2, B2). Finishing one workout moves you to the next in the rotation.",
        ),
        "stage" => (
            "Stage",
            "A set-and-rep scheme a lift is currently on (like 5×3). Failing a stage moves you to the next, easier-to-progress one instead of stalling.",
        ),
        "t1" => (
            "T1 — main lift",
            "The day's heaviest barbell lift, trained with low reps and the most rest. Its progress drives the program.",
        ),
        "t2" => (
            "T2 — supplemental lift",
            "A second barbell lift at a lighter weight and higher reps, building the volume behind the T1s.",
        ),
        "t3" => (
            "T3 — accessory",
            "Higher-rep assistance work (rows, pulldowns) that builds muscle and balances the heavy lifts.",
        ),
        _ => return None,
    };
    Some(Explanation {
        term: normalized,
        title: title.to_owned(),
        body: body.to_owned(),
    })
}

pub(crate) fn title_words(value: &str) -> String {
    value
        .split(['_', ' '])
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            chars
                .next()
                .map(|first| format!("{}{}", first.to_ascii_uppercase(), chars.as_str()))
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_codes_have_specific_copy() {
        let explanation = validation_code_message("missing_custom_start");
        assert_eq!(explanation.code, "missing_custom_start");
        assert!(explanation.title.contains("starting weight"));
        assert!(explanation.hint.is_some());
    }

    #[test]
    fn unknown_codes_fall_back_honestly() {
        let explanation = validation_code_message("mystery_code");
        assert_eq!(explanation.code, "mystery_code");
        assert!(!explanation.title.is_empty());
    }

    #[test]
    fn missing_start_user_message_names_the_lift() {
        let text = "template lane squat.t1 requires an initial value for squat";
        assert_eq!(
            user_message("missing_custom_start", text),
            "Add a starting weight for Squat before this program can build workouts."
        );
    }

    #[test]
    fn tier_groups_speak_the_template_vocabulary() {
        assert_eq!(
            tier_group_label("gzcl.gzclp", "t1").as_deref(),
            Some("Main lift")
        );
        assert_eq!(
            tier_group_label("531.basic", "main").as_deref(),
            Some("5/3/1 sets")
        );
        assert_eq!(
            tier_group_label("starting-strength.phase1", "linear").as_deref(),
            Some("Work sets")
        );
        assert_eq!(
            tier_group_label("./templates/custom.fitspec", "t2").as_deref(),
            Some("Supplemental")
        );
        assert_eq!(tier_group_label("gzcl.gzclp", "conditioning"), None);
    }

    #[test]
    fn explain_normalizes_terms_and_rejects_unknowns() {
        assert!(explain("AMRAP").is_some());
        assert!(explain("training max").is_some());
        assert!(explain("Training-Max").is_some());
        assert!(explain("quantum_lifting").is_none());
    }
}
