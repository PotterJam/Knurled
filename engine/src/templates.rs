use crate::error::{KnurledError, Result};
use crate::json::sha256_json;
use crate::model::{
    BuiltinTemplate, ENGINE_VERSION, FiveThreeOneWeek, LockEntry, Map, RestPolicy,
    TemplateIncrements, TemplateKind, TemplateLaneRules, TemplateSlot,
};

pub const DEFAULT_TEMPLATE_VERSION: &str = "1.0.0";

/// Metadata describing a built-in template.
///
/// `BUILTIN_TEMPLATES` is the single source of truth for template identifiers
/// and their human-readable names. Renaming a template here propagates
/// everywhere: engine output, the CLI default, and the iOS app (which only ever
/// sees names the engine hands it). Change a name in one place, change it
/// everywhere.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuiltinTemplateInfo {
    pub id: &'static str,
    pub version: &'static str,
    pub display_name: &'static str,
    pub description: &'static str,
    pub kind: TemplateKind,
}

/// Every built-in template the engine knows how to render.
pub const BUILTIN_TEMPLATES: &[BuiltinTemplateInfo] = &[
    BuiltinTemplateInfo {
        id: "gzcl.gzclp",
        version: DEFAULT_TEMPLATE_VERSION,
        display_name: "GZCLP",
        description: "Simple linear progression with A/B rotation.",
        kind: TemplateKind::Gzclp,
    },
    BuiltinTemplateInfo {
        id: "gzcl.p-zero",
        version: DEFAULT_TEMPLATE_VERSION,
        display_name: "GZCLP P-Zero",
        description: "GZCLP variant with the same starter lifts.",
        kind: TemplateKind::Gzclp,
    },
    BuiltinTemplateInfo {
        id: "531.basic",
        version: DEFAULT_TEMPLATE_VERSION,
        display_name: "5/3/1 Basic",
        description: "Four-day 5/3/1 starter using training maxes.",
        kind: TemplateKind::FiveThreeOne,
    },
    BuiltinTemplateInfo {
        id: "531.beginners",
        version: DEFAULT_TEMPLATE_VERSION,
        display_name: "5/3/1 for Beginners",
        description: "Beginner-friendly 5/3/1 starter.",
        kind: TemplateKind::FiveThreeOne,
    },
    BuiltinTemplateInfo {
        id: "starting-strength.phase1",
        version: DEFAULT_TEMPLATE_VERSION,
        display_name: "Starting Strength Phase 1",
        description: "Novice A/B progression with squat, press, bench, and deadlift.",
        kind: TemplateKind::StartingStrength,
    },
    BuiltinTemplateInfo {
        id: "starting-strength.phase2",
        version: DEFAULT_TEMPLATE_VERSION,
        display_name: "Starting Strength Phase 2",
        description: "Adds the next novice phase while staying template-driven.",
        kind: TemplateKind::StartingStrength,
    },
    BuiltinTemplateInfo {
        id: "starting-strength.phase3",
        version: DEFAULT_TEMPLATE_VERSION,
        display_name: "Starting Strength Phase 3",
        description: "Adds power cleans for later novice progression.",
        kind: TemplateKind::StartingStrength,
    },
];

/// The template a fresh repo is seeded with when none is specified.
pub const DEFAULT_TEMPLATE_ID: &str = "gzcl.gzclp";

/// All built-in templates, for callers (CLI, app) that need to list them.
pub fn builtin_templates() -> &'static [BuiltinTemplateInfo] {
    BUILTIN_TEMPLATES
}

/// Look up a built-in template's metadata by id.
pub fn builtin_template_info(id: &str) -> Option<&'static BuiltinTemplateInfo> {
    BUILTIN_TEMPLATES.iter().find(|info| info.id == id)
}

/// Human-readable display name for a template id, falling back to the id itself.
pub fn template_display_name(id: &str) -> &str {
    builtin_template_info(id)
        .map(|info| info.display_name)
        .unwrap_or(id)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateRef {
    pub id: String,
    pub version: String,
    pub normalized: String,
}

pub fn parse_template_ref(input: &str) -> TemplateRef {
    let clean = input.trim().trim_matches('"');
    let (id, version) = clean
        .split_once('@')
        .map(|(id, version)| (id.to_owned(), version.to_owned()))
        .unwrap_or_else(|| (clean.to_owned(), DEFAULT_TEMPLATE_VERSION.to_owned()));
    let normalized = format!("{id}@{version}");
    TemplateRef {
        id,
        version,
        normalized,
    }
}

pub fn builtin_template(input: &str) -> Result<BuiltinTemplate> {
    let reference = parse_template_ref(input);
    let kind = builtin_template_info(&reference.id)
        .filter(|info| info.version == reference.version)
        .map(|info| info.kind.clone())
        .ok_or(KnurledError::UnknownTemplate(reference.normalized))?;
    Ok(match kind {
        TemplateKind::Gzclp => gzclp_template(reference.id),
        TemplateKind::FiveThreeOne => five_three_one_template(reference.id),
        TemplateKind::StartingStrength => starting_strength_template(reference.id),
    })
}

pub fn template_hash(input: &str) -> Result<String> {
    sha256_json(&builtin_template(input)?)
}

pub fn lock_entry(input: &str) -> Result<LockEntry> {
    let reference = parse_template_ref(input);
    Ok(LockEntry {
        version: reference.version,
        source: "builtin".to_owned(),
        content_hash: template_hash(input)?,
        engine_version: ENGINE_VERSION.to_owned(),
    })
}

pub fn render_lockfile(input: &str) -> Result<String> {
    let reference = parse_template_ref(input);
    let entry = lock_entry(input)?;
    Ok(format!(
        "[templates.\"{}\"]\nversion = \"{}\"\nsource = \"{}\"\ncontent_hash = \"{}\"\nengine_version = \"{}\"\n",
        reference.id, entry.version, entry.source, entry.content_hash, entry.engine_version
    ))
}

fn gzclp_template(id: String) -> BuiltinTemplate {
    BuiltinTemplate {
        id,
        version: DEFAULT_TEMPLATE_VERSION.to_owned(),
        kind: TemplateKind::Gzclp,
        default_rotation: vec!["a1".into(), "b1".into(), "a2".into(), "b2".into()],
        sessions: gzclp_sessions(),
        rest: rest_policy(120, &[("t1", 180), ("t2", 150), ("t3", 90)], &[], &[], &[]),
        lanes: TemplateLaneRules {
            t1_stages: vec!["5x3+".into(), "6x2+".into(), "10x1+".into()],
            t2_stages: vec!["3x10".into(), "3x8".into(), "3x6".into()],
            t3_target_reps: 15,
            t3_pass_final_set_reps: 25,
        },
        increments: TemplateIncrements {
            default: 2.5,
            upper: 2.5,
            lower: 5.0,
        },
        weeks: Vec::new(),
    }
}

fn five_three_one_template(id: String) -> BuiltinTemplate {
    BuiltinTemplate {
        id,
        version: DEFAULT_TEMPLATE_VERSION.to_owned(),
        kind: TemplateKind::FiveThreeOne,
        default_rotation: vec![
            "squat_day".into(),
            "bench_day".into(),
            "deadlift_day".into(),
            "press_day".into(),
        ],
        sessions: five_three_one_sessions(),
        rest: rest_policy(150, &[("main", 180)], &[], &[], &[]),
        lanes: TemplateLaneRules {
            t1_stages: Vec::new(),
            t2_stages: Vec::new(),
            t3_target_reps: 0,
            t3_pass_final_set_reps: 0,
        },
        increments: TemplateIncrements {
            default: 2.5,
            upper: 2.5,
            lower: 5.0,
        },
        weeks: vec![
            FiveThreeOneWeek {
                week: 1,
                percentages: vec![65, 75, 85],
                reps: vec!["5".into(), "5".into(), "5+".into()],
            },
            FiveThreeOneWeek {
                week: 2,
                percentages: vec![70, 80, 90],
                reps: vec!["3".into(), "3".into(), "3+".into()],
            },
            FiveThreeOneWeek {
                week: 3,
                percentages: vec![75, 85, 95],
                reps: vec!["5".into(), "3".into(), "1+".into()],
            },
            FiveThreeOneWeek {
                week: 4,
                percentages: vec![40, 50, 60],
                reps: vec!["5".into(), "5".into(), "5".into()],
            },
        ],
    }
}

fn starting_strength_template(id: String) -> BuiltinTemplate {
    let (default_rotation, sessions) = match id.as_str() {
        "starting-strength.phase1" => (
            vec!["a".into(), "b".into()],
            starting_strength_phase1_sessions(),
        ),
        "starting-strength.phase2" => (
            vec!["a".into(), "b".into()],
            starting_strength_phase2_sessions(),
        ),
        "starting-strength.phase3" => (
            vec![
                "a_deadlift".into(),
                "b_chins_1".into(),
                "a_clean".into(),
                "b_chins_2".into(),
            ],
            starting_strength_phase3_sessions(),
        ),
        _ => unreachable!("caller only passes known Starting Strength templates"),
    };

    BuiltinTemplate {
        id,
        version: DEFAULT_TEMPLATE_VERSION.to_owned(),
        kind: TemplateKind::StartingStrength,
        default_rotation,
        sessions,
        rest: rest_policy(
            120,
            &[("3x5", 180), ("1x5", 240), ("5x3", 180), ("chins", 120)],
            &[],
            &[],
            &[],
        ),
        lanes: TemplateLaneRules {
            t1_stages: Vec::new(),
            t2_stages: Vec::new(),
            t3_target_reps: 0,
            t3_pass_final_set_reps: 0,
        },
        increments: TemplateIncrements {
            default: 2.5,
            upper: 2.5,
            lower: 5.0,
        },
        weeks: Vec::new(),
    }
}

fn rest_policy(
    default_seconds: u32,
    by_tier: &[(&str, u32)],
    by_slot: &[(&str, u32)],
    by_lane: &[(&str, u32)],
    by_exercise: &[(&str, u32)],
) -> RestPolicy {
    RestPolicy {
        default_seconds: Some(default_seconds),
        by_tier: by_tier
            .iter()
            .map(|(key, seconds)| (key.to_ascii_lowercase(), *seconds))
            .collect(),
        by_slot: by_slot
            .iter()
            .map(|(key, seconds)| (key.to_ascii_lowercase(), *seconds))
            .collect(),
        by_lane: by_lane
            .iter()
            .map(|(key, seconds)| (key.to_ascii_lowercase(), *seconds))
            .collect(),
        by_exercise: by_exercise
            .iter()
            .map(|(key, seconds)| (key.to_ascii_lowercase().replace(' ', "_"), *seconds))
            .collect(),
    }
}

fn gzclp_sessions() -> Map<Vec<TemplateSlot>> {
    Map::from([
        (
            "a1".to_owned(),
            vec![
                slot("a1.t1", "t1", Some("squat"), None, None),
                slot("a1.t2", "t2", Some("bench"), None, None),
                slot("a1.t3", "t3", None, Some("A1.T3"), Some("lat_pulldown")),
            ],
        ),
        (
            "b1".to_owned(),
            vec![
                slot("b1.t1", "t1", Some("press"), None, None),
                slot("b1.t2", "t2", Some("deadlift"), None, None),
                slot("b1.t3", "t3", None, Some("B1.T3"), Some("barbell_row")),
            ],
        ),
        (
            "a2".to_owned(),
            vec![
                slot("a2.t1", "t1", Some("bench"), None, None),
                slot("a2.t2", "t2", Some("squat"), None, None),
                slot("a2.t3", "t3", None, Some("A2.T3"), Some("lat_pulldown")),
            ],
        ),
        (
            "b2".to_owned(),
            vec![
                slot("b2.t1", "t1", Some("deadlift"), None, None),
                slot("b2.t2", "t2", Some("press"), None, None),
                slot("b2.t3", "t3", None, Some("B2.T3"), Some("barbell_row")),
            ],
        ),
    ])
}

fn five_three_one_sessions() -> Map<Vec<TemplateSlot>> {
    Map::from([
        (
            "squat_day".into(),
            vec![slot("squat.main", "main", Some("squat"), None, None)],
        ),
        (
            "bench_day".into(),
            vec![slot("bench.main", "main", Some("bench"), None, None)],
        ),
        (
            "deadlift_day".into(),
            vec![slot("deadlift.main", "main", Some("deadlift"), None, None)],
        ),
        (
            "press_day".into(),
            vec![slot("press.main", "main", Some("press"), None, None)],
        ),
    ])
}

fn starting_strength_phase1_sessions() -> Map<Vec<TemplateSlot>> {
    Map::from([
        (
            "a".into(),
            vec![
                slot("a.squat", "3x5", Some("squat"), None, None),
                slot("a.press", "3x5", Some("press"), None, None),
                slot("a.deadlift", "1x5", Some("deadlift"), None, None),
            ],
        ),
        (
            "b".into(),
            vec![
                slot("b.squat", "3x5", Some("squat"), None, None),
                slot("b.bench", "3x5", Some("bench"), None, None),
                slot("b.deadlift", "1x5", Some("deadlift"), None, None),
            ],
        ),
    ])
}

fn starting_strength_phase2_sessions() -> Map<Vec<TemplateSlot>> {
    Map::from([
        (
            "a".into(),
            vec![
                slot("a.squat", "3x5", Some("squat"), None, None),
                slot("a.press", "3x5", Some("press"), None, None),
                slot("a.deadlift", "1x5", Some("deadlift"), None, None),
            ],
        ),
        (
            "b".into(),
            vec![
                slot("b.squat", "3x5", Some("squat"), None, None),
                slot("b.bench", "3x5", Some("bench"), None, None),
                slot("b.power_clean", "5x3", Some("power_clean"), None, None),
            ],
        ),
    ])
}

fn starting_strength_phase3_sessions() -> Map<Vec<TemplateSlot>> {
    Map::from([
        (
            "a_deadlift".into(),
            vec![
                slot("a_deadlift.squat", "3x5", Some("squat"), None, None),
                slot("a_deadlift.press", "3x5", Some("press"), None, None),
                slot("a_deadlift.deadlift", "1x5", Some("deadlift"), None, None),
            ],
        ),
        (
            "b_chins_1".into(),
            vec![
                slot("b_chins_1.squat", "3x5", Some("squat"), None, None),
                slot("b_chins_1.bench", "3x5", Some("bench"), None, None),
                slot("b_chins_1.chins", "chins", Some("chin_up"), None, None),
            ],
        ),
        (
            "a_clean".into(),
            vec![
                slot("a_clean.squat", "3x5", Some("squat"), None, None),
                slot("a_clean.press", "3x5", Some("press"), None, None),
                slot(
                    "a_clean.power_clean",
                    "5x3",
                    Some("power_clean"),
                    None,
                    None,
                ),
            ],
        ),
        (
            "b_chins_2".into(),
            vec![
                slot("b_chins_2.squat", "3x5", Some("squat"), None, None),
                slot("b_chins_2.bench", "3x5", Some("bench"), None, None),
                slot("b_chins_2.chins", "chins", Some("chin_up"), None, None),
            ],
        ),
    ])
}

fn slot(
    slot_id: &str,
    tier: &str,
    exercise: Option<&str>,
    accessory_key: Option<&str>,
    default_exercise: Option<&str>,
) -> TemplateSlot {
    TemplateSlot {
        slot_id: slot_id.to_owned(),
        tier: tier.to_owned(),
        exercise: exercise.map(str::to_owned),
        accessory_key: accessory_key.map(str::to_owned),
        default_exercise: default_exercise.map(str::to_owned),
    }
}
