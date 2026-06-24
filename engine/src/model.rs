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
#[serde(rename_all = "snake_case")]
pub enum TemplateKind {
    Gzclp,
    FiveThreeOne,
    StartingStrength,
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
    pub exercise_options: Map<ExerciseOptions>,
    pub rest: RestPolicy,
    #[serde(default, skip_serializing_if = "WarmupPolicy::is_empty")]
    pub warmup: WarmupPolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub equipment: Option<EquipmentProfile>,
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
    Raw {
        text: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuiltinTemplate {
    pub id: String,
    pub version: String,
    pub kind: TemplateKind,
    pub default_rotation: Vec<String>,
    pub sessions: Map<Vec<TemplateSlot>>,
    pub rest: RestPolicy,
    pub lanes: TemplateLaneRules,
    pub increments: TemplateIncrements,
    pub weeks: Vec<FiveThreeOneWeek>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TemplateSlot {
    pub slot_id: String,
    pub tier: String,
    pub exercise: Option<String>,
    pub accessory_key: Option<String>,
    pub default_exercise: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TemplateLaneRules {
    pub t1_stages: Vec<String>,
    pub t2_stages: Vec<String>,
    pub t3_target_reps: u32,
    pub t3_pass_final_set_reps: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TemplateIncrements {
    pub default: f64,
    pub upper: f64,
    pub lower: f64,
}

impl Eq for TemplateIncrements {}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FiveThreeOneWeek {
    pub week: u32,
    pub percentages: Vec<u32>,
    pub reps: Vec<String>,
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
    pub exercise_options: Map<ExerciseOptions>,
    pub rest: RestPolicy,
    #[serde(default, skip_serializing_if = "WarmupPolicy::is_empty")]
    pub warmup: WarmupPolicy,
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
    pub suggested_date: Option<String>,
    pub plan_hash: String,
    pub template_hash: String,
    pub rendered_session_hash: String,
    pub items: Vec<RenderedItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RenderedItem {
    pub item_id: String,
    pub slot_id: String,
    pub progression_lane: String,
    pub progression_rule: String,
    pub exercise: String,
    pub display: DisplayFields,
    pub prescription: Prescription,
    pub execution_contract: ExecutionContract,
    pub effect_preview: EffectPreview,
    pub rest: RestPrescription,
    pub identity: ItemIdentity,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exercise_options: Option<RenderedExerciseOptions>,
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
    pub status: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub saved_at: Option<String>,
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
    pub event: Option<TrainingEvent>,
    pub effects: Vec<Effect>,
    pub new_state: StateProjection,
    pub next_workout: RenderedSession,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TrainingEvent {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: Option<String>,
    pub program: Option<String>,
    pub session_id: Option<String>,
    pub plan_hash: Option<String>,
    pub template_hash: Option<String>,
    pub rendered_session_hash: Option<String>,
    pub engine_version: Option<String>,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub saved_at: Option<String>,
    pub status: Option<String>,
    #[serde(default)]
    pub results: Vec<ExerciseResult>,
    #[serde(default)]
    pub results_added: Vec<ExerciseResult>,
    #[serde(default)]
    pub effects: Vec<Effect>,
    pub continues_event_id: Option<String>,
    pub corrects_event_id: Option<String>,
    pub reason: Option<String>,
    pub policy: Option<String>,
    pub lane: Option<String>,
    pub change: Option<StateChange>,
    pub cursor: Option<CursorChange>,
    #[serde(default)]
    pub changes: Vec<CorrectionChange>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub change_kind: Option<String>,
    #[serde(rename = "from", skip_serializing_if = "Option::is_none")]
    pub from_plan: Option<PlanChangeRef>,
    #[serde(rename = "to", skip_serializing_if = "Option::is_none")]
    pub to_plan: Option<PlanChangeRef>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExerciseResult {
    pub slot_id: String,
    pub progression_lane: Option<String>,
    pub progression_rule: Option<String>,
    pub prescribed_exercise: Option<String>,
    pub performed_exercise: Option<String>,
    pub swap_reason: Option<String>,
    pub swap_policy: Option<SwapPolicy>,
    pub prescribed: serde_json::Value,
    #[serde(default)]
    pub actual: Vec<ActualSet>,
    pub outcome: String,
    #[serde(default)]
    pub effects: Vec<Effect>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StateChange {
    pub load: Option<LoadChange>,
    pub stage: Option<StageChange>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LoadChange {
    pub from: Option<String>,
    pub to: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StageChange {
    pub from: Option<String>,
    pub to: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CursorChange {
    pub next_session: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CorrectionChange {
    pub path: String,
    pub before: serde_json::Value,
    pub after: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlanChangeRef {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan_hash: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub template: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildOutputs {
    pub state: StateProjection,
    pub ir: serde_json::Value,
    pub next_workout: Option<RenderedSession>,
    pub validation: ValidationReport,
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
pub struct BacktestReport {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub status: String,
    pub events_replayed: usize,
    pub corrections_applied: usize,
    pub skips: usize,
    pub state_projection: String,
    pub generated_files: GeneratedFileReport,
    pub cursor: Cursor,
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
    pub event_id: String,
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
