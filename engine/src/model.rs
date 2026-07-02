use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: &str = "0.1";
pub const ENGINE_VERSION: &str = "0.1.0";

pub type Map<T> = BTreeMap<String, T>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum Units {
    #[default]
    Kg,
    Lb,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Plan {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub name: String,
    pub template: String,
    pub units: Units,
    pub schedule: Schedule,
    pub starts: Map<String>,
    pub training_maxes: Map<String>,
    pub accessories: Map<String>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub exercises: Map<CustomExercise>,
    pub exercise_options: Map<ExerciseOptions>,
    pub rest: RestPolicy,
    #[serde(default, skip_serializing_if = "WarmupPolicy::is_empty")]
    pub warmup: WarmupPolicy,
    #[serde(default, skip_serializing_if = "SessionExercisePolicy::is_empty")]
    pub session_exercises: SessionExercisePolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub equipment: Option<EquipmentProfile>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CustomExercise {
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pattern: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub implement: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExerciseCatalogEntry {
    pub id: String,
    pub label: String,
    pub pattern: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub muscles: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub implement: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub custom: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Schedule {
    pub mode: String,
    pub rotation: Vec<String>,
    pub suggested_days: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExerciseOptions {
    pub primary: String,
    pub alternatives: Vec<ExerciseAlternative>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExerciseAlternative {
    pub option_id: String,
    pub exercise: String,
    pub label: String,
    pub policy: SwapPolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SwapPolicy {
    TrackingOnly,
    ProgressionEquivalent,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Lockfile {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub templates: Map<LockEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LockEntry {
    pub version: String,
    pub source: String,
    pub content_hash: String,
    pub engine_version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Patch {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub name: String,
    pub filename: String,
    pub description: String,
    pub active_from: Option<String>,
    pub expires: Option<String>,
    pub operations: Vec<PatchOperation>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum PatchOperation {
    ReplaceExercise {
        from: String,
        to: String,
        lane_regex: String,
    },
    AddConditioning {
        day: String,
        activity: String,
    },
    Cap {
        target: String,
        value: String,
        lane_regex: Option<String>,
    },
    /// Scale prescribed set loads on matching lanes by `percent` (−10 = 10%
    /// lighter) at render time, snapped via the equipment rounder. Progression
    /// state is untouched — this is the render-time overlay behind
    /// `PlanEdit::TemporaryLoadAdjust` (RFC-0001 D10).
    ScaleLoad {
        percent: i32,
        lane_regex: String,
    },
    Raw {
        text: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuiltinTemplate {
    pub id: String,
    pub version: String,
    pub default_rotation: Vec<String>,
    pub rest: RestPolicy,
    pub dsl: DslTemplate,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DslTemplate {
    pub name: String,
    pub version: String,
    pub rotation: Vec<String>,
    pub rest_seconds: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warmup: Option<WarmupScheme>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub session_display_names: Map<String>,
    pub sessions: Map<Vec<DslSessionItem>>,
    pub lanes: Map<DslLane>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DslSessionItem {
    pub lane: String,
    pub slot_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accessory_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_exercise: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DslLane {
    pub exercise: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tier: Option<String>,
    pub basis: DslBasis,
    #[serde(default)]
    pub initial: DslInitial,
    pub sequence: DslSequence,
    pub stages: Vec<DslStage>,
    pub rules: Vec<DslRule>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rest_seconds: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warmup: Option<WarmupScheme>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DslInitial {
    #[default]
    Basis,
    Percent {
        percentage: u32,
    },
    Performed,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DslBasis {
    WorkingWeight,
    TrainingMax,
    Bodyweight,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum DslSequence {
    #[default]
    None,
    Stages,
    Cycle,
    Waves,
    Rotation,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DslStage {
    pub id: String,
    pub groups: Vec<DslSetGroup>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DslSetGroup {
    pub count: u32,
    pub reps: u32,
    /// Integer percent of the selected basis.
    pub intensity: u32,
    #[serde(default)]
    pub amrap: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rep_min: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rep_max: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rpe: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DslRule {
    pub trigger: DslTrigger,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage: Option<String>,
    pub effects: Vec<DslEffect>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DslTrigger {
    Pass,
    Fail,
    AmrapGte { reps: u32 },
    Stall { count: u32 },
    CycleEnd,
    RangeTop,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum DslEffect {
    IncreaseLoad { amount: String },
    Deload { percent: u32 },
    ResetLoad { percent: u32 },
    AdvanceStage,
    ResetStage,
    IncreaseReps { amount: u32 },
    ResetReps,
    RecomputeTm { amount: String },
    AdvanceCycle,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RenderedDslRule {
    pub trigger: DslTrigger,
    pub effects: Vec<DslEffect>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RenderedDslContext {
    pub basis: DslBasis,
    pub sequence: DslSequence,
    pub initial: DslInitial,
    pub first_stage: String,
    pub next_stage: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlanIdentity {
    pub name: String,
    pub units: Units,
    pub template: String,
    pub template_id: String,
    pub template_version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CompiledPlan {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub engine_version: String,
    pub plan_hash: String,
    pub lock_hash: String,
    pub template_hash: String,
    pub patch_hash: String,
    pub plan: PlanIdentity,
    pub schedule: Schedule,
    pub starts: Map<String>,
    pub training_maxes: Map<String>,
    pub accessories: Map<String>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub exercises: Map<CustomExercise>,
    pub exercise_options: Map<ExerciseOptions>,
    pub rest: RestPolicy,
    #[serde(default, skip_serializing_if = "WarmupPolicy::is_empty")]
    pub warmup: WarmupPolicy,
    #[serde(default, skip_serializing_if = "SessionExercisePolicy::is_empty")]
    pub session_exercises: SessionExercisePolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub equipment: Option<EquipmentProfile>,
    pub template: BuiltinTemplate,
    pub lock: Lockfile,
    pub patches: Vec<Patch>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct RestPolicy {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_seconds: Option<u32>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub by_tier: Map<u32>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub by_slot: Map<u32>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub by_lane: Map<u32>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub by_exercise: Map<u32>,
}

/// Configurable warmup (ramp-up) sets, scoped exactly like [`RestPolicy`]:
/// the engine resolves a single [`WarmupScheme`] for an item by precedence
/// `exercise` > `lane` > `slot` > `tier` > `default`, with the plan's policy
/// taking precedence over the template's built-in defaults.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct WarmupPolicy {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<WarmupScheme>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub by_tier: Map<WarmupScheme>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub by_slot: Map<WarmupScheme>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub by_lane: Map<WarmupScheme>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub by_exercise: Map<WarmupScheme>,
}

impl WarmupPolicy {
    pub fn is_empty(&self) -> bool {
        self.default.is_none()
            && self.by_tier.is_empty()
            && self.by_slot.is_empty()
            && self.by_lane.is_empty()
            && self.by_exercise.is_empty()
    }
}

/// One warmup prescription: some empty-bar sets followed by a percentage ramp
/// of the resolved [`WarmupBasis`]. The number of sets (empty bar + ramp
/// steps) and their reps are fully configurable, which is what lets different
/// lifts, tiers, and program phases carry different warmup volumes.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct WarmupScheme {
    #[serde(default)]
    pub empty_bar_sets: u32,
    #[serde(default)]
    pub empty_bar_reps: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ramp: Vec<WarmupStep>,
    #[serde(default)]
    pub basis: WarmupBasis,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WarmupStep {
    /// Percentage (1–100) of the resolved basis load.
    pub percentage: u32,
    pub reps: u32,
}

/// What a warmup ramp is computed from.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum WarmupBasis {
    /// Heaviest working set of the item (default; matches Bay Strength style).
    #[default]
    TopSet,
    /// The lane's current working weight.
    WorkingWeight,
    /// The lane's training max (e.g. canonical 5/3/1 warmups).
    TrainingMax,
}

/// Optional whole-session exercises rendered before and after the program work.
/// These are not ramp-up sets for a lift; they are separate, user-owned
/// exercises such as mobility drills, light conditioning, or stretching.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct SessionExercisePolicy {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warmup: Vec<SessionExercise>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warmdown: Vec<SessionExercise>,
}

impl SessionExercisePolicy {
    pub fn is_empty(&self) -> bool {
        self.warmup.is_empty() && self.warmdown.is_empty()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionExercise {
    pub exercise: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default = "one")]
    pub sets: u32,
    #[serde(default)]
    pub reps: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub load: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

fn one() -> u32 {
    1
}

/// Optional, user-owned description of the equipment available in a gym, used
/// to snap computed loads to the nearest weight the lifter can actually load.
/// Purely plan-level: it is never part of a template (a template describes the
/// program, not the user's plates).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct EquipmentProfile {
    /// Bar weight by exercise, plus an optional `default`. Bare numbers are in
    /// the plan's units.
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub bars: Map<f64>,
    /// Available plate denominations (per side). Barbell loads are bar plus
    /// twice a multiset of these.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub plate_pairs: Vec<f64>,
    /// Discrete dumbbell sizes available.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dumbbells: Vec<f64>,
    #[serde(default)]
    pub rounding: RoundingMode,
    /// Per-exercise implement override; absent exercises are inferred by name.
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub implements: Map<Implement>,
}

// `f64` fields keep `EquipmentProfile` out of `Eq`'s derive; the values are
// authored, finite numbers, so structural equality is well-defined here.
impl Eq for EquipmentProfile {}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum RoundingMode {
    /// Snap to the nearest achievable load (ties resolve downward).
    #[default]
    Nearest,
    /// Snap down to the nearest achievable load (never prescribe more than asked).
    Down,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Implement {
    Barbell,
    Dumbbell,
    Bodyweight,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ValidationReport {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub engine_version: String,
    pub status: ValidationStatus,
    pub errors: Vec<ValidationMessage>,
    pub warnings: Vec<ValidationMessage>,
    pub checked: ValidationChecks,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ValidationStatus {
    Valid,
    Invalid,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ValidationMessage {
    pub code: String,
    pub message: String,
    /// Human sentence for this problem, stamped at construction so every
    /// report already carries user copy (RFC-0001 D9).
    #[serde(default)]
    pub user_message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ValidationChecks {
    pub plan_syntax: bool,
    pub template_lock: bool,
    pub patch_validity: bool,
    pub renderability: bool,
    pub execution_contracts: bool,
    pub state_log_consistency: bool,
    pub generated_file_freshness: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StateProjection {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub engine_version: String,
    pub program_hash: String,
    pub last_event_id: Option<String>,
    pub cursor: Cursor,
    pub lanes: Map<LaneState>,
    pub sessions: Map<SessionState>,
    /// One authored transition back per lane. This is enough to revise the latest record on a
    /// lane without turning authored state into a replay-derived projection.
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub previous_lanes: Map<LaneCheckpoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LaneCheckpoint {
    pub record_id: String,
    pub previous_state: LaneState,
    pub item: Box<RenderedItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Cursor {
    pub next_session: String,
    pub week: u32,
    pub cycle: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct LaneState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub load: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stage: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub training_max: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub week: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cycle: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reps: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stall: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionState {
    pub status: String,
    pub source_events: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RenderedSession {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub engine_version: String,
    pub session_id: String,
    pub display_name: String,
    /// The day's lifts at a glance ("Squat · Bench Press · Lat Pulldown"),
    /// engine-composed so clients never re-derive it (RFC-0001 D3).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_description: Option<String>,
    pub suggested_date: Option<String>,
    pub plan_hash: String,
    pub template_hash: String,
    pub rendered_session_hash: String,
    pub items: Vec<RenderedItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RenderedItem {
    #[serde(default, skip_serializing_if = "RenderedItemPhase::is_main")]
    pub phase: RenderedItemPhase,
    pub item_id: String,
    pub slot_id: String,
    pub progression_lane: String,
    pub progression_rule: String,
    pub exercise: String,
    pub implement: Implement,
    pub display: DisplayFields,
    pub prescription: Prescription,
    pub execution_contract: ExecutionContract,
    pub effect_preview: EffectPreview,
    pub rest: RestPrescription,
    pub identity: ItemIdentity,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exercise_options: Option<RenderedExerciseOptions>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dsl_rules: Vec<RenderedDslRule>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dsl_context: Option<RenderedDslContext>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum RenderedItemPhase {
    #[default]
    Main,
    Warmup,
    Warmdown,
}

impl RenderedItemPhase {
    pub fn is_main(&self) -> bool {
        matches!(self, Self::Main)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RestPrescription {
    pub seconds: u32,
    pub source: RestSource,
    pub key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RestSource {
    PlanSlot,
    PlanLane,
    PlanExercise,
    PlanTier,
    PlanDefault,
    TemplateSlot,
    TemplateLane,
    TemplateExercise,
    TemplateTier,
    TemplateDefault,
    EngineFallback,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DisplayFields {
    pub title: String,
    pub subtitle: String,
    /// Clean exercise name ("Overhead Press") — the engine-owned label clients
    /// render instead of raw ids (RFC-0001 D3). `default` so snapshots captured
    /// before this field existed still decode.
    #[serde(default)]
    pub label: String,
    /// The lift's role in this program, in the template's own vocabulary
    /// ("Main lift", "Supplemental", "5/3/1 sets").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Prescription {
    /// Warmup (ramp-up) sets. Prescription-only guidance: they are never
    /// required for completion and never feed progression outcomes, so they
    /// live in a separate field from the working `sets`. Omitted from JSON
    /// when empty so plans without a configured warmup hash identically to
    /// before this field existed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warmups: Vec<PrescribedSet>,
    pub sets: Vec<PrescribedSet>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PrescribedSet {
    pub set: u32,
    pub load: Option<String>,
    pub target_reps: u32,
    pub amrap: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub percentage: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rep_min: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rep_max: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExecutionContract {
    pub recommended_input: String,
    pub fallback_inputs: Vec<String>,
    pub completion_rule: String,
    pub event_template: String,
    pub required_for_completion: bool,
    pub input_schema: InputSchema,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InputSchema {
    pub mode: String,
    pub fields: Vec<InputField>,
    pub fallback: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InputField {
    pub name: String,
    #[serde(rename = "type")]
    pub field_type: String,
    pub min: Option<i32>,
    pub max: Option<i32>,
    pub default: Option<serde_json::Value>,
    pub required: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EffectPreview {
    pub pass: Vec<Effect>,
    pub fail: Vec<Effect>,
    pub adjusted_today: Vec<Effect>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Effect {
    pub op: String,
    pub lane: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ItemIdentity {
    pub item_id: String,
    pub slot_id: String,
    pub progression_lane: String,
    pub progression_rule: String,
    pub plan_hash: String,
    pub rendered_session_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RenderedExerciseOptions {
    pub primary: String,
    pub allow_runtime_swap: bool,
    pub default_policy: SwapPolicy,
    pub alternatives: Vec<ExerciseAlternative>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExecutionInput {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub rendered_session_hash: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub inputs: Vec<ItemInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ItemInput {
    pub item_id: String,
    pub mode: String,
    pub final_set_reps: Option<u32>,
    #[serde(default)]
    pub sets: Vec<ActualSet>,
    pub load: Option<String>,
    pub performed_exercise: Option<String>,
    pub swap_reason: Option<String>,
    pub swap_policy: Option<SwapPolicy>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ActualSet {
    pub set: u32,
    pub load: Option<String>,
    pub reps: u32,
    /// Open, units-explicit measured metrics for the set (ADR 0001): e.g. `rpe`, `rir`,
    /// later velocity. Tier 0 of the autoregulation plan records these losslessly; the engine
    /// passes them through replay without acting on them. Omitted from JSON when empty so
    /// existing logs and hashes are byte-identical.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metrics: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExecutionInputValidation {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub status: ValidationStatus,
    pub errors: Vec<ValidationMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReductionResult {
    pub validation: ExecutionInputValidation,
    /// Per-progression-item outcomes (pass/fail and the progression each
    /// triggered). Tracking-only session exercises are omitted: they remain in
    /// the workout record but have no program consequence to preview. In the
    /// logs-as-record model (ADR 0007) this is surfaced for the consequence
    /// preview and is no longer wrapped in an event.
    pub results: Vec<ExerciseResult>,
    pub effects: Vec<Effect>,
    pub new_state: StateProjection,
    pub next_workout: RenderedSession,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExerciseResult {
    pub slot_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progression_lane: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progression_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prescribed_exercise: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub performed_exercise: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub swap_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub swap_policy: Option<SwapPolicy>,
    pub prescribed: serde_json::Value,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actual: Vec<ActualSet>,
    pub outcome: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub effects: Vec<Effect>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildOutputs {
    pub state: StateProjection,
    pub ir: serde_json::Value,
    pub next_workout: Option<RenderedSession>,
    pub validation: ValidationReport,
    /// Why `next_workout` is absent (the plan failed validation), so the app
    /// can explain the fallback instead of a silent "plan invalid" chip
    /// (RFC-0001 D9).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stale_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InitialNumberSuggestions {
    pub template: String,
    pub units: Units,
    pub values: Map<String>,
    pub suggestions: Vec<InitialNumberSuggestion>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InitialNumberSuggestion {
    pub exercise: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_exercise: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_load: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GeneratedFileReport {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub status: String,
    pub changed: Vec<String>,
    pub missing: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SimulationReport {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub engine_version: String,
    pub strategy: String,
    pub weeks: u32,
    pub sessions: Vec<SimulatedSession>,
    pub final_state: StateProjection,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SimulatedSession {
    pub index: u32,
    pub session_id: String,
    pub display_name: String,
    pub effects: Vec<Effect>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PreviewReport {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub sessions: serde_json::Value,
    pub final_state: Option<StateProjection>,
}

/// Input to [`crate::preview_template`]: a candidate template (structured `dsl`
/// or raw `text`) plus the plan-level numbers needed to render a first workout.
/// The app posts this on every edit to drive live validation + preview without
/// writing anything to disk.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct PreviewTemplateRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dsl: Option<DslTemplate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default)]
    pub units: Units,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub initial_numbers: Map<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub suggested_days: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rest: Option<RestPolicy>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PreviewTemplateResult {
    pub validation: ValidationReport,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<RenderedSession>,
}
