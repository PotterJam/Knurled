use crate::error::{KnurledError, Result};
use crate::json::sha256_json;
use crate::model::{
    BuiltinTemplate, ENGINE_VERSION, ExerciseAlternative, ExerciseCatalogEntry, FiveThreeOneWeek,
    LockEntry, Map, RestPolicy, SwapPolicy, TemplateIncrements, TemplateKind, TemplateLaneRules,
    TemplateSlot,
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

pub fn exercise_catalog() -> Vec<ExerciseCatalogEntry> {
    const ENTRIES: &[(&str, &str, &str, &[&str], &str)] = &[
        ("squat", "Squat", "squat", &["quads", "glutes"], "barbell"),
        (
            "back_squat",
            "Back Squat",
            "squat",
            &["quads", "glutes"],
            "barbell",
        ),
        (
            "front_squat",
            "Front Squat",
            "squat",
            &["quads", "core"],
            "barbell",
        ),
        (
            "pause_squat",
            "Pause Squat",
            "squat",
            &["quads", "glutes"],
            "barbell",
        ),
        (
            "box_squat",
            "Box Squat",
            "squat",
            &["quads", "glutes"],
            "barbell",
        ),
        (
            "goblet_squat",
            "Goblet Squat",
            "squat",
            &["quads", "glutes"],
            "dumbbell",
        ),
        ("hack_squat", "Hack Squat", "squat", &["quads"], "machine"),
        (
            "leg_press",
            "Leg Press",
            "squat",
            &["quads", "glutes"],
            "machine",
        ),
        (
            "belt_squat",
            "Belt Squat",
            "squat",
            &["quads", "glutes"],
            "machine",
        ),
        (
            "split_squat",
            "Split Squat",
            "squat",
            &["quads", "glutes"],
            "dumbbell",
        ),
        (
            "bulgarian_split_squat",
            "Bulgarian Split Squat",
            "squat",
            &["quads", "glutes"],
            "dumbbell",
        ),
        ("lunge", "Lunge", "squat", &["quads", "glutes"], "dumbbell"),
        (
            "step_up",
            "Step-up",
            "squat",
            &["quads", "glutes"],
            "dumbbell",
        ),
        (
            "leg_extension",
            "Leg Extension",
            "squat",
            &["quads"],
            "machine",
        ),
        (
            "deadlift",
            "Deadlift",
            "hinge",
            &["hamstrings", "glutes", "back"],
            "barbell",
        ),
        (
            "sumo_deadlift",
            "Sumo Deadlift",
            "hinge",
            &["hamstrings", "glutes", "back"],
            "barbell",
        ),
        (
            "romanian_deadlift",
            "Romanian Deadlift",
            "hinge",
            &["hamstrings", "glutes"],
            "barbell",
        ),
        (
            "rdl",
            "Romanian Deadlift",
            "hinge",
            &["hamstrings", "glutes"],
            "barbell",
        ),
        (
            "stiff_leg_deadlift",
            "Stiff-Leg Deadlift",
            "hinge",
            &["hamstrings", "glutes"],
            "barbell",
        ),
        (
            "dumbbell_rdl",
            "Dumbbell Romanian Deadlift",
            "hinge",
            &["hamstrings", "glutes"],
            "dumbbell",
        ),
        (
            "good_morning",
            "Good Morning",
            "hinge",
            &["hamstrings", "back"],
            "barbell",
        ),
        ("hip_thrust", "Hip Thrust", "hinge", &["glutes"], "barbell"),
        (
            "glute_bridge",
            "Glute Bridge",
            "hinge",
            &["glutes"],
            "barbell",
        ),
        (
            "back_extension",
            "Back Extension",
            "hinge",
            &["lower_back", "glutes"],
            "bodyweight",
        ),
        ("leg_curl", "Leg Curl", "hinge", &["hamstrings"], "machine"),
        (
            "bench",
            "Bench Press",
            "horizontal_push",
            &["chest", "triceps"],
            "barbell",
        ),
        (
            "bench_press",
            "Bench Press",
            "horizontal_push",
            &["chest", "triceps"],
            "barbell",
        ),
        (
            "close_grip_bench",
            "Close-Grip Bench Press",
            "horizontal_push",
            &["triceps", "chest"],
            "barbell",
        ),
        (
            "pause_bench",
            "Pause Bench Press",
            "horizontal_push",
            &["chest", "triceps"],
            "barbell",
        ),
        (
            "incline_bench",
            "Incline Bench Press",
            "horizontal_push",
            &["chest", "shoulders"],
            "barbell",
        ),
        (
            "incline_bench_press",
            "Incline Bench Press",
            "horizontal_push",
            &["chest", "shoulders"],
            "barbell",
        ),
        (
            "dumbbell_bench",
            "Dumbbell Bench",
            "horizontal_push",
            &["chest", "triceps"],
            "dumbbell",
        ),
        (
            "dumbbell_bench_press",
            "Dumbbell Bench Press",
            "horizontal_push",
            &["chest", "triceps"],
            "dumbbell",
        ),
        (
            "dumbbell_incline",
            "Dumbbell Incline",
            "horizontal_push",
            &["chest", "shoulders"],
            "dumbbell",
        ),
        (
            "incline_db_press",
            "Incline Dumbbell Press",
            "horizontal_push",
            &["chest", "shoulders"],
            "dumbbell",
        ),
        (
            "machine_chest_press",
            "Machine Chest Press",
            "horizontal_push",
            &["chest"],
            "machine",
        ),
        (
            "push_up",
            "Push-up",
            "horizontal_push",
            &["chest", "triceps"],
            "bodyweight",
        ),
        (
            "dip",
            "Dip",
            "horizontal_push",
            &["chest", "triceps"],
            "bodyweight",
        ),
        (
            "cable_fly",
            "Cable Fly",
            "horizontal_push",
            &["chest"],
            "cable",
        ),
        (
            "press",
            "Overhead Press",
            "vertical_push",
            &["shoulders", "triceps"],
            "barbell",
        ),
        (
            "overhead_press",
            "Overhead Press",
            "vertical_push",
            &["shoulders", "triceps"],
            "barbell",
        ),
        (
            "strict_press",
            "Strict Press",
            "vertical_push",
            &["shoulders", "triceps"],
            "barbell",
        ),
        (
            "push_press",
            "Push Press",
            "vertical_push",
            &["shoulders", "triceps"],
            "barbell",
        ),
        (
            "dumbbell_press",
            "Dumbbell Press",
            "vertical_push",
            &["shoulders", "triceps"],
            "dumbbell",
        ),
        (
            "seated_db_press",
            "Seated Dumbbell Press",
            "vertical_push",
            &["shoulders"],
            "dumbbell",
        ),
        (
            "landmine_press",
            "Landmine Press",
            "vertical_push",
            &["shoulders", "triceps"],
            "barbell",
        ),
        (
            "machine_shoulder_press",
            "Machine Shoulder Press",
            "vertical_push",
            &["shoulders"],
            "machine",
        ),
        (
            "lateral_raise",
            "Lateral Raise",
            "vertical_push",
            &["shoulders"],
            "dumbbell",
        ),
        (
            "rear_delt_fly",
            "Rear-Delt Fly",
            "vertical_push",
            &["rear_delts"],
            "dumbbell",
        ),
        (
            "barbell_row",
            "Barbell Row",
            "horizontal_pull",
            &["back", "biceps"],
            "barbell",
        ),
        (
            "pendlay_row",
            "Pendlay Row",
            "horizontal_pull",
            &["back"],
            "barbell",
        ),
        (
            "dumbbell_row",
            "Dumbbell Row",
            "horizontal_pull",
            &["back", "biceps"],
            "dumbbell",
        ),
        (
            "one_arm_db_row",
            "One-Arm Dumbbell Row",
            "horizontal_pull",
            &["back", "biceps"],
            "dumbbell",
        ),
        (
            "cable_row",
            "Cable Row",
            "horizontal_pull",
            &["back"],
            "cable",
        ),
        (
            "seated_cable_row",
            "Seated Cable Row",
            "horizontal_pull",
            &["back"],
            "cable",
        ),
        (
            "chest_supported_row",
            "Chest-Supported Row",
            "horizontal_pull",
            &["back"],
            "machine",
        ),
        (
            "machine_row",
            "Machine Row",
            "horizontal_pull",
            &["back"],
            "machine",
        ),
        (
            "face_pull",
            "Face Pull",
            "horizontal_pull",
            &["rear_delts", "back"],
            "cable",
        ),
        (
            "pull_up",
            "Pull-up",
            "vertical_pull",
            &["back", "biceps"],
            "bodyweight",
        ),
        (
            "chin_up",
            "Chin-up",
            "vertical_pull",
            &["back", "biceps"],
            "bodyweight",
        ),
        (
            "lat_pulldown",
            "Lat Pulldown",
            "vertical_pull",
            &["back", "biceps"],
            "cable",
        ),
        (
            "neutral_grip_pulldown",
            "Neutral-Grip Pulldown",
            "vertical_pull",
            &["back"],
            "cable",
        ),
        (
            "straight_arm_pulldown",
            "Straight-Arm Pulldown",
            "vertical_pull",
            &["lats"],
            "cable",
        ),
        (
            "barbell_curl",
            "Barbell Curl",
            "arms",
            &["biceps"],
            "barbell",
        ),
        (
            "dumbbell_curl",
            "Dumbbell Curl",
            "arms",
            &["biceps"],
            "dumbbell",
        ),
        (
            "hammer_curl",
            "Hammer Curl",
            "arms",
            &["biceps"],
            "dumbbell",
        ),
        (
            "preacher_curl",
            "Preacher Curl",
            "arms",
            &["biceps"],
            "machine",
        ),
        (
            "tricep_pushdown",
            "Tricep Pushdown",
            "arms",
            &["triceps"],
            "cable",
        ),
        (
            "skullcrusher",
            "Skullcrusher",
            "arms",
            &["triceps"],
            "barbell",
        ),
        (
            "overhead_tricep_extension",
            "Overhead Tricep Extension",
            "arms",
            &["triceps"],
            "dumbbell",
        ),
        ("plank", "Plank", "core", &["core"], "bodyweight"),
        ("side_plank", "Side Plank", "core", &["core"], "bodyweight"),
        (
            "hanging_leg_raise",
            "Hanging Leg Raise",
            "core",
            &["core"],
            "bodyweight",
        ),
        ("ab_wheel", "Ab Wheel", "core", &["core"], "bodyweight"),
        ("cable_crunch", "Cable Crunch", "core", &["core"], "cable"),
        ("sit_up", "Sit-up", "core", &["core"], "bodyweight"),
        ("calf_raise", "Calf Raise", "calves", &["calves"], "machine"),
        (
            "standing_calf_raise",
            "Standing Calf Raise",
            "calves",
            &["calves"],
            "machine",
        ),
        (
            "seated_calf_raise",
            "Seated Calf Raise",
            "calves",
            &["calves"],
            "machine",
        ),
        (
            "power_clean",
            "Power Clean",
            "olympic",
            &["traps", "glutes", "hamstrings"],
            "barbell",
        ),
        (
            "clean",
            "Clean",
            "olympic",
            &["traps", "glutes", "hamstrings"],
            "barbell",
        ),
        (
            "snatch",
            "Snatch",
            "olympic",
            &["shoulders", "glutes", "hamstrings"],
            "barbell",
        ),
        (
            "kettlebell_swing",
            "Kettlebell Swing",
            "conditioning",
            &["glutes", "hamstrings"],
            "kettlebell",
        ),
        (
            "band_pull_apart",
            "Band Pull-Apart",
            "activation",
            &["rear_delts", "upper_back"],
            "band",
        ),
        (
            "band_external_rotation",
            "Band External Rotation",
            "activation",
            &["rotator_cuff"],
            "band",
        ),
        (
            "face_pull",
            "Face Pull",
            "activation",
            &["rear_delts", "upper_back"],
            "cable",
        ),
        (
            "scap_push_up",
            "Scap Push-up",
            "activation",
            &["serratus", "shoulders"],
            "bodyweight",
        ),
        (
            "dead_bug",
            "Dead Bug",
            "activation",
            &["core"],
            "bodyweight",
        ),
        (
            "bird_dog",
            "Bird Dog",
            "activation",
            &["core", "glutes"],
            "bodyweight",
        ),
        (
            "glute_bridge_march",
            "Glute Bridge March",
            "activation",
            &["glutes", "core"],
            "bodyweight",
        ),
        (
            "hip_airplane",
            "Hip Airplane",
            "mobility",
            &["hips", "glutes"],
            "bodyweight",
        ),
        (
            "worlds_greatest_stretch",
            "World's Greatest Stretch",
            "mobility",
            &["hips", "hamstrings", "t_spine"],
            "bodyweight",
        ),
        (
            "cossack_squat",
            "Cossack Squat",
            "mobility",
            &["hips", "adductors"],
            "bodyweight",
        ),
        (
            "ankle_rocks",
            "Ankle Rocks",
            "mobility",
            &["ankles", "calves"],
            "bodyweight",
        ),
        (
            "thoracic_rotation",
            "Thoracic Rotation",
            "mobility",
            &["t_spine"],
            "bodyweight",
        ),
        ("cat_cow", "Cat-Cow", "mobility", &["spine"], "bodyweight"),
        (
            "jump_rope",
            "Jump Rope",
            "conditioning",
            &["cardio", "calves"],
            "bodyweight",
        ),
        (
            "easy_bike",
            "Easy Bike",
            "conditioning",
            &["cardio"],
            "machine",
        ),
        (
            "easy_walk",
            "Easy Walk",
            "conditioning",
            &["cardio"],
            "bodyweight",
        ),
        (
            "farmer_carry",
            "Farmer Carry",
            "carry",
            &["grip", "core", "traps"],
            "dumbbell",
        ),
        (
            "suitcase_carry",
            "Suitcase Carry",
            "carry",
            &["grip", "core"],
            "dumbbell",
        ),
        (
            "couch_stretch",
            "Couch Stretch",
            "stretch",
            &["quads", "hips"],
            "bodyweight",
        ),
        (
            "hamstring_stretch",
            "Hamstring Stretch",
            "stretch",
            &["hamstrings"],
            "bodyweight",
        ),
        (
            "pec_doorway_stretch",
            "Pec Doorway Stretch",
            "stretch",
            &["chest", "shoulders"],
            "bodyweight",
        ),
        (
            "lat_stretch",
            "Lat Stretch",
            "stretch",
            &["lats"],
            "bodyweight",
        ),
        ("row_erg", "Row Erg", "conditioning", &["cardio"], "machine"),
        (
            "assault_bike",
            "Assault Bike",
            "conditioning",
            &["cardio"],
            "machine",
        ),
        (
            "easy_run",
            "Easy Run",
            "conditioning",
            &["cardio"],
            "bodyweight",
        ),
        (
            "zone2_run",
            "Zone-2 Run",
            "conditioning",
            &["cardio"],
            "bodyweight",
        ),
        (
            "sled_push",
            "Sled Push",
            "conditioning",
            &["quads", "glutes", "cardio"],
            "sled",
        ),
    ];

    ENTRIES
        .iter()
        .map(
            |(id, label, pattern, muscles, implement)| ExerciseCatalogEntry {
                id: (*id).to_owned(),
                label: (*label).to_owned(),
                pattern: (*pattern).to_owned(),
                muscles: muscles.iter().map(|muscle| (*muscle).to_owned()).collect(),
                implement: Some((*implement).to_owned()),
                custom: false,
            },
        )
        .collect()
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

/// Built-in exercise swaps every template offers for common starter lifts,
/// keyed by the resolved exercise name.
///
/// These are the swaps a lifter always has on hand even when the plan author
/// never spelled out `exercise_options` for a slot: a barbell bench can always
/// be logged as a dumbbell bench, a deadlift as an RDL, and so on. A plan's own
/// `exercise_options` for a slot take precedence over these defaults, so an
/// author can still curate (or suppress) the list per slot.
///
/// All defaults are `tracking_only`: the substitute is recorded faithfully but
/// does not drive the main lift's progression, since none of these movements
/// loads identically to the barbell lift it stands in for.
pub fn default_exercise_alternatives(exercise: &str) -> Vec<ExerciseAlternative> {
    let alternatives: &[(&str, &str)] = match exercise.trim().to_ascii_lowercase().as_str() {
        "bench" => &[
            ("dumbbell_bench", "Dumbbell Bench"),
            ("dumbbell_incline", "Dumbbell Incline"),
            ("incline_bench", "Incline Bench"),
        ],
        "deadlift" => &[
            ("rdl", "Romanian Deadlift"),
            ("dumbbell_rdl", "Dumbbell Romanian Deadlift"),
        ],
        "squat" => &[
            ("hack_squat", "Hack Squat"),
            ("goblet_squat", "Goblet Squat"),
        ],
        "press" => &[
            ("dumbbell_press", "Dumbbell Press"),
            ("landmine_press", "Landmine Press"),
        ],
        "lat_pulldown" => &[
            ("pull_up", "Pull-up"),
            ("chin_up", "Chin-up"),
            ("neutral_grip_pulldown", "Neutral-Grip Pulldown"),
        ],
        "barbell_row" => &[
            ("dumbbell_row", "DB Row"),
            ("cable_row", "Cable Row"),
            ("chest_supported_row", "Chest-Supported Row"),
        ],
        _ => &[],
    };

    alternatives
        .iter()
        .map(|(exercise, label)| ExerciseAlternative {
            option_id: (*exercise).to_owned(),
            exercise: (*exercise).to_owned(),
            label: (*label).to_owned(),
            policy: SwapPolicy::TrackingOnly,
        })
        .collect()
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
