use regex::Regex;
use serde_json::json;

use crate::dsl::parse_template_dsl;
use crate::error::{KnurledError, Result};
use crate::json::{sha256_json, sha256_text};
use crate::model::*;
use crate::parser::{normalize_exercise, parse_lock, parse_patch, parse_plan};
use crate::templates::{
    builtin_template, default_exercise_alternatives, exercise_catalog, lock_entry,
    parse_template_ref, template_hash,
};

#[derive(Debug, Clone)]
pub struct PatchFile {
    pub filename: String,
    pub text: String,
}

pub fn compile_plan(
    plan_text: &str,
    lock_text: &str,
    patch_files: &[PatchFile],
) -> Result<CompiledPlan> {
    compile_plan_with_template(plan_text, lock_text, patch_files, None)
}

pub fn compile_plan_with_template(
    plan_text: &str,
    lock_text: &str,
    patch_files: &[PatchFile],
    custom_template_text: Option<&str>,
) -> Result<CompiledPlan> {
    let plan = parse_plan(plan_text)?;
    let reference = parse_template_ref(&plan.template);
    let template = match custom_template_text {
        Some(text) => parse_template_dsl(text, &reference.id)?,
        None => builtin_template(&plan.template)?,
    };
    let lock = parse_lock(lock_text)?;
    let patches = patch_files
        .iter()
        .map(|file| parse_patch(&file.text, file.filename.clone()))
        .collect::<Result<Vec<_>>>()?;

    // Identity hashes the canonical parsed plan, not the raw file bytes, so
    // reformatting, comments, or whitespace never rewrite a plan's identity —
    // only a real semantic change does.
    let plan_hash = sha256_json(&plan)?;

    Ok(CompiledPlan {
        kind: "compiled_plan".into(),
        schema_version: SCHEMA_VERSION.into(),
        engine_version: ENGINE_VERSION.into(),
        plan_hash,
        lock_hash: sha256_json(&lock)?,
        template_hash: match custom_template_text {
            Some(text) => sha256_text(text),
            None => template_hash(&plan.template)?,
        },
        patch_hash: sha256_json(&patches)?,
        plan: PlanIdentity {
            name: plan.name,
            units: plan.units,
            template: reference.normalized,
            template_id: reference.id,
            template_version: reference.version,
        },
        schedule: normalize_schedule(plan.schedule, &template),
        starts: plan.starts,
        training_maxes: plan.training_maxes,
        accessories: plan.accessories,
        exercises: plan.exercises,
        exercise_options: plan.exercise_options,
        rest: plan.rest,
        warmup: plan.warmup,
        session_exercises: plan.session_exercises,
        equipment: plan.equipment,
        template,
        lock,
        patches,
    })
}

pub fn validate_compiled(compiled: &CompiledPlan) -> ValidationReport {
    let mut errors = Vec::new();
    let mut warnings = Vec::new();

    if compiled.plan.template_id.starts_with("./") {
        match compiled.lock.templates.get(&compiled.plan.template_id) {
            Some(entry) => {
                if entry.content_hash != compiled.template_hash {
                    errors.push(message(
                        "lock_hash_mismatch",
                        format!(
                            "fitspec.lock content hash for {} does not match the template file",
                            compiled.plan.template_id
                        ),
                    ));
                }
                if entry.engine_version != ENGINE_VERSION {
                    errors.push(message(
                        "lock_engine_mismatch",
                        format!(
                            "fitspec.lock pins engine {}, expected {}",
                            entry.engine_version, ENGINE_VERSION
                        ),
                    ));
                }
            }
            None => warnings.push(message(
                "missing_lock_entry",
                format!(
                    "fitspec.lock has no entry for {}",
                    compiled.plan.template_id
                ),
            )),
        }
    } else {
        match compiled.lock.templates.get(&compiled.plan.template_id) {
            Some(entry) => match lock_entry(&compiled.plan.template) {
                Ok(expected) => {
                    if entry.version != expected.version {
                        errors.push(message(
                            "lock_version_mismatch",
                            format!(
                                "fitspec.lock pins {}@{}, expected {}",
                                compiled.plan.template_id, entry.version, expected.version
                            ),
                        ));
                    }
                    if entry.content_hash != expected.content_hash {
                        errors.push(message(
                        "lock_hash_mismatch",
                        format!(
                            "fitspec.lock content hash for {} does not match the built-in template",
                            compiled.plan.template_id
                        ),
                    ));
                    }
                }
                Err(error) => errors.push(message("unknown_template", error.to_string())),
            },
            None => warnings.push(message(
                "missing_lock_entry",
                format!(
                    "fitspec.lock has no entry for {}",
                    compiled.plan.template_id
                ),
            )),
        }
    }

    {
        let dsl = &compiled.template.dsl;
        for item in dsl.sessions.values().flatten() {
            let Some(lane) = dsl.lanes.get(&item.lane) else {
                continue;
            };
            let exercise = dsl_item_exercise(compiled, item, lane);
            let present = match lane.basis {
                DslBasis::WorkingWeight => {
                    lane.initial == DslInitial::Performed || compiled.starts.contains_key(&exercise)
                }
                DslBasis::TrainingMax => compiled.training_maxes.contains_key(&exercise),
                DslBasis::Bodyweight => true,
            };
            if !present {
                errors.push(message(
                    "missing_custom_start",
                    format!(
                        "template lane {} requires an initial value for {exercise}",
                        item.lane
                    ),
                ));
            }
        }
    }

    for patch in &compiled.patches {
        for operation in &patch.operations {
            if let PatchOperation::ReplaceExercise { lane_regex, .. }
            | PatchOperation::Cap {
                lane_regex: Some(lane_regex),
                ..
            } = operation
                && let Err(error) = Regex::new(lane_regex)
            {
                errors.push(message(
                    "invalid_lane_regex",
                    format!(
                        "{} contains invalid lane regex {lane_regex}: {error}",
                        patch.filename
                    ),
                ));
            }
        }
    }

    validate_warmup(&compiled.warmup, &mut errors);
    if let Some(equipment) = compiled.equipment.as_ref() {
        validate_equipment(equipment, &mut errors, &mut warnings);
    }

    let is_valid = errors.is_empty();
    ValidationReport {
        kind: "validation_report".into(),
        schema_version: SCHEMA_VERSION.into(),
        engine_version: ENGINE_VERSION.into(),
        status: if is_valid {
            ValidationStatus::Valid
        } else {
            ValidationStatus::Invalid
        },
        errors,
        warnings,
        checked: ValidationChecks {
            plan_syntax: true,
            template_lock: true,
            patch_validity: true,
            renderability: is_valid,
            execution_contracts: is_valid,
            state_log_consistency: true,
            generated_file_freshness: false,
        },
    }
}

fn validate_warmup(warmup: &WarmupPolicy, errors: &mut Vec<ValidationMessage>) {
    let scoped = warmup
        .default
        .iter()
        .map(|scheme| ("default".to_owned(), scheme))
        .chain(
            [
                &warmup.by_tier,
                &warmup.by_slot,
                &warmup.by_lane,
                &warmup.by_exercise,
            ]
            .into_iter()
            .flat_map(|map| map.iter().map(|(key, scheme)| (key.clone(), scheme))),
        );

    for (scope, scheme) in scoped {
        for step in &scheme.ramp {
            if step.percentage == 0 || step.percentage > 100 {
                errors.push(message(
                    "invalid_warmup_percentage",
                    format!(
                        "warmup {scope} has a ramp step at {}% (must be 1–100)",
                        step.percentage
                    ),
                ));
            }
            if step.reps == 0 {
                errors.push(message(
                    "invalid_warmup_reps",
                    format!("warmup {scope} has a ramp step with zero reps"),
                ));
            }
        }
    }
}

fn validate_equipment(
    equipment: &EquipmentProfile,
    errors: &mut Vec<ValidationMessage>,
    warnings: &mut Vec<ValidationMessage>,
) {
    for (exercise, weight) in &equipment.bars {
        if *weight <= 0.0 {
            errors.push(message(
                "invalid_bar_weight",
                format!("equipment bar `{exercise}` must be a positive weight"),
            ));
        }
    }
    if equipment.plate_pairs.iter().any(|plate| *plate <= 0.0) {
        errors.push(message(
            "invalid_plate",
            "equipment plates must all be positive weights".to_owned(),
        ));
    }
    if equipment.dumbbells.iter().any(|weight| *weight <= 0.0) {
        errors.push(message(
            "invalid_dumbbell",
            "equipment dumbbells must all be positive weights".to_owned(),
        ));
    }
    if equipment.plate_pairs.is_empty() && equipment.dumbbells.is_empty() {
        warnings.push(message(
            "empty_equipment",
            "equipment has neither plates nor dumbbells; loads fall back to 2.5-unit rounding"
                .to_owned(),
        ));
    }
}

pub fn create_initial_state(compiled: &CompiledPlan) -> StateProjection {
    create_initial_dsl_state(compiled)
}

pub fn render_next(compiled: &CompiledPlan, state: &StateProjection) -> Result<RenderedSession> {
    render_dsl_next(compiled, state)
}

/// Renders a specific session by id against the current state, independent of where the cursor
/// currently points. Saved partials store their session id in the record, so the app can
/// re-render that specific session when the user continues from history.
pub fn render_session(
    compiled: &CompiledPlan,
    state: &StateProjection,
    session_id: &str,
) -> Result<RenderedSession> {
    let mut scratch = state.clone();
    scratch.cursor.next_session = session_id.to_ascii_lowercase();
    render_next(compiled, &scratch)
}

pub fn validate_execution_input(
    rendered_session: &RenderedSession,
    input: &ExecutionInput,
) -> ExecutionInputValidation {
    let mut errors = Vec::new();

    if input.kind != "execution_input" {
        errors.push(message(
            "invalid_type",
            "ExecutionInput must have type execution_input",
        ));
    }

    if input.rendered_session_hash != rendered_session.rendered_session_hash {
        errors.push(message(
            "rendered_session_hash_mismatch",
            "ExecutionInput was not created against this rendered session",
        ));
    }

    if input.status != "complete" && input.status != "partial" {
        errors.push(message(
            "invalid_execution_status",
            "ExecutionInput status must be complete or partial",
        ));
    }
    if input.started_at.as_deref().is_none_or(str::is_empty) {
        errors.push(message(
            "missing_started_at",
            "ExecutionInput requires started_at for stable record identity",
        ));
    }
    if input
        .started_at
        .as_deref()
        .is_some_and(|value| !is_iso_timestamp(value))
    {
        errors.push(message(
            "invalid_started_at",
            "ExecutionInput started_at must be an ISO-8601 timestamp",
        ));
    }
    if input.status == "complete" && input.completed_at.as_deref().is_none_or(str::is_empty) {
        errors.push(message(
            "missing_completed_at",
            "A complete ExecutionInput requires completed_at",
        ));
    }
    if input
        .completed_at
        .as_deref()
        .is_some_and(|value| !is_iso_timestamp(value))
    {
        errors.push(message(
            "invalid_completed_at",
            "ExecutionInput completed_at must be an ISO-8601 timestamp",
        ));
    }
    if input.status == "partial" && input.saved_at.as_deref().is_none_or(str::is_empty) {
        errors.push(message(
            "missing_saved_at",
            "A partial ExecutionInput requires saved_at",
        ));
    }
    if input
        .saved_at
        .as_deref()
        .is_some_and(|value| !is_iso_timestamp(value))
    {
        errors.push(message(
            "invalid_saved_at",
            "ExecutionInput saved_at must be an ISO-8601 timestamp",
        ));
    }

    for item in rendered_session.items.iter().filter(|item| {
        item.execution_contract.required_for_completion && input.status == "complete"
    }) {
        if !input
            .inputs
            .iter()
            .any(|candidate| candidate.item_id == item.item_id)
        {
            errors.push(message(
                "missing_required_input",
                format!("Missing required input for {}", item.item_id),
            ));
        }
    }

    ExecutionInputValidation {
        kind: "execution_input_validation".into(),
        schema_version: SCHEMA_VERSION.into(),
        status: if errors.is_empty() {
            ValidationStatus::Valid
        } else {
            ValidationStatus::Invalid
        },
        errors,
    }
}

fn is_iso_timestamp(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() >= 20
        && bytes.get(4) == Some(&b'-')
        && bytes.get(7) == Some(&b'-')
        && bytes.get(10) == Some(&b'T')
        && bytes.get(13) == Some(&b':')
        && bytes.get(16) == Some(&b':')
        && bytes[..4].iter().all(u8::is_ascii_digit)
        && bytes[5..7].iter().all(u8::is_ascii_digit)
        && bytes[8..10].iter().all(u8::is_ascii_digit)
}

pub fn reduce_input(
    compiled: &CompiledPlan,
    state: &StateProjection,
    rendered_session: &RenderedSession,
    input: &ExecutionInput,
) -> Result<ReductionResult> {
    let validation = validate_execution_input(rendered_session, input);
    if validation.status != ValidationStatus::Valid {
        return Ok(ReductionResult {
            validation,
            results: Vec::new(),
            effects: Vec::new(),
            new_state: state.clone(),
            next_workout: rendered_session.clone(),
        });
    }

    let mut new_state = state.clone();
    let mut results = Vec::new();
    let mut effects = Vec::new();

    // Tracking-only items still belong in the workout record, but they have no
    // program consequence to preview as an exercise result.
    for item in rendered_session
        .items
        .iter()
        .filter(|item| item.progression_rule != "tracking_only")
    {
        if let Some(item_input) = input
            .inputs
            .iter()
            .find(|candidate| candidate.item_id == item.item_id)
        {
            let result = reduce_item(item, item_input, compiled, state)?;
            effects.extend(result.effects.clone());
            results.push(result);
        }
    }

    apply_effects(&mut new_state, &effects);
    // Advance to the next workout whenever the cursor is still sitting on the session being
    // submitted. This runs for partial submits too — only the per-exercise effects above are
    // gated on completion; moving on to the next workout is not.
    if new_state
        .cursor
        .next_session
        .eq_ignore_ascii_case(&rendered_session.session_id)
    {
        advance_cursor(
            &mut new_state,
            &compiled.schedule.rotation,
            &rendered_session.session_id,
        );
    }

    let next_workout = render_next(compiled, &new_state)?;
    Ok(ReductionResult {
        validation,
        results,
        effects,
        new_state,
        next_workout,
    })
}

/// Advance the schedule cursor to the next session in the rotation, wrapping to
/// the next week at the end of the rotation.
pub(crate) fn advance_cursor(state: &mut StateProjection, rotation: &[String], session_id: &str) {
    let normalized = session_id.to_ascii_lowercase();
    let index = rotation
        .iter()
        .position(|candidate| candidate == &normalized)
        .unwrap_or(0);
    let next_index = (index + 1) % rotation.len().max(1);
    state.cursor.next_session = rotation
        .get(next_index)
        .cloned()
        .unwrap_or_else(|| normalized.clone());
    if next_index == 0 {
        state.cursor.week += 1;
    }
}

/// Build the generated outputs from the source-of-truth `state` (ADR 0007):
/// the next workout rendered from `state`, plus the compiled-plan IR and
/// validation. No replay — `state` is authoritative.
pub fn build_outputs(compiled: &CompiledPlan, state: &StateProjection) -> Result<BuildOutputs> {
    let validation = validate_compiled(compiled);
    let next_workout = if validation.status == ValidationStatus::Valid {
        Some(render_next(compiled, state)?)
    } else {
        None
    };
    let mut ir = serde_json::to_value(compiled)?;
    if let Some(object) = ir.as_object_mut() {
        object.remove("lock");
    }
    Ok(BuildOutputs {
        state: state.clone(),
        ir,
        next_workout,
        validation,
    })
}

pub fn simulate(
    compiled: &CompiledPlan,
    state: &StateProjection,
    weeks: u32,
    strategy: &str,
) -> Result<SimulationReport> {
    let sessions_per_week = compiled.schedule.suggested_days.len().max(1) as u32;
    let mut working_state = state.clone();
    let mut sessions = Vec::new();

    for index in 0..weeks * sessions_per_week {
        let rendered = render_next(compiled, &working_state)?;
        let input = synthetic_execution_input(&rendered, strategy, index);
        let reduced = reduce_input(compiled, &working_state, &rendered, &input)?;
        working_state = reduced.new_state;
        sessions.push(SimulatedSession {
            index: index + 1,
            session_id: rendered.session_id,
            display_name: rendered.display_name,
            effects: reduced.effects,
        });
    }

    Ok(SimulationReport {
        kind: "simulation_report".into(),
        schema_version: SCHEMA_VERSION.into(),
        engine_version: ENGINE_VERSION.into(),
        strategy: strategy.into(),
        weeks,
        sessions,
        final_state: working_state,
    })
}

pub fn synthetic_execution_input(
    rendered_session: &RenderedSession,
    strategy: &str,
    index: u32,
) -> ExecutionInput {
    let inputs = rendered_session
        .items
        .iter()
        .map(|item| {
            if item.execution_contract.recommended_input == "amrap_final_set" {
                let target = item
                    .prescription
                    .sets
                    .last()
                    .map(|set| set.target_reps)
                    .unwrap_or_default();
                ItemInput {
                    item_id: item.item_id.clone(),
                    mode: "amrap_final_set".into(),
                    final_set_reps: Some(if strategy == "all-fail" {
                        target.saturating_sub(1)
                    } else {
                        target + 2
                    }),
                    sets: Vec::new(),
                    load: None,
                    performed_exercise: None,
                    swap_reason: None,
                    swap_policy: None,
                }
            } else {
                ItemInput {
                    item_id: item.item_id.clone(),
                    mode: "per_set_reps".into(),
                    final_set_reps: None,
                    sets: item
                        .prescription
                        .sets
                        .iter()
                        .map(|set| ActualSet {
                            set: set.set,
                            load: set.load.clone(),
                            reps: if strategy == "all-fail" {
                                set.target_reps.saturating_sub(1)
                            } else {
                                set.target_reps
                            },
                            metrics: Default::default(),
                        })
                        .collect(),
                    load: None,
                    performed_exercise: None,
                    swap_reason: None,
                    swap_policy: None,
                }
            }
        })
        .collect();

    let day = index + 1;
    ExecutionInput {
        kind: "execution_input".into(),
        schema_version: SCHEMA_VERSION.into(),
        rendered_session_hash: rendered_session.rendered_session_hash.clone(),
        status: "complete".into(),
        started_at: Some(format!("2026-06-{day:02}T10:00:00+01:00")),
        completed_at: Some(format!("2026-06-{day:02}T11:00:00+01:00")),
        saved_at: None,
        inputs,
    }
}

fn normalize_schedule(schedule: Schedule, template: &BuiltinTemplate) -> Schedule {
    let rotation = if schedule.rotation.is_empty() {
        template.default_rotation.clone()
    } else {
        schedule
            .rotation
            .into_iter()
            .map(|item| item.to_ascii_lowercase())
            .collect()
    };

    Schedule {
        mode: "next_workout".into(),
        rotation,
        suggested_days: if schedule.suggested_days.is_empty() {
            vec!["mon".into(), "wed".into(), "fri".into()]
        } else {
            schedule.suggested_days
        },
    }
}

// ---------------------------------------------------------------------------
// Warmup sets
// ---------------------------------------------------------------------------

/// Build the warmup (ramp-up) sets for an item. Returns empty when no scheme
/// resolves or the lift has no load to ramp from (e.g. bodyweight work), so
/// plans and lifts without warmups serialise exactly as before.
fn compute_warmups(
    compiled: &CompiledPlan,
    slot: &RenderSlot,
    spec: &RenderedItemSpec<'_>,
) -> Vec<PrescribedSet> {
    if implement_for_compiled(compiled, &spec.exercise) == Implement::Bodyweight {
        return Vec::new();
    }
    let Some(scheme) = resolve_warmup(compiled, slot, &spec.lane, &spec.exercise) else {
        return Vec::new();
    };

    let basis = match scheme.basis {
        WarmupBasis::TrainingMax => spec.training_max.clone(),
        WarmupBasis::WorkingWeight | WarmupBasis::TopSet => top_working_load(&spec.sets),
    };
    let Some(basis) = basis else {
        return Vec::new();
    };
    let parsed = parse_load(&basis);
    if parsed.value <= 0.0 {
        return Vec::new();
    }

    let mut sets = Vec::new();
    let mut index = 1;

    if scheme.empty_bar_sets > 0
        && scheme.empty_bar_reps > 0
        && let Some(bar) = warmup_bar_weight(compiled, &spec.exercise)
    {
        let load = Some(format_load(bar, parsed.unit));
        for _ in 0..scheme.empty_bar_sets {
            sets.push(PrescribedSet {
                set: index,
                load: load.clone(),
                target_reps: scheme.empty_bar_reps,
                amrap: false,
                percentage: None,
                rep_min: None,
                rep_max: None,
            });
            index += 1;
        }
    }

    for step in &scheme.ramp {
        let target = parsed.value * (step.percentage as f64) / 100.0;
        let value = snap_warmup_load(compiled, &spec.exercise, &spec.sets, target);
        if sets
            .last()
            .and_then(|set| set.load.as_deref())
            .is_some_and(|load| value <= parse_load(load).value)
        {
            continue;
        }
        sets.push(PrescribedSet {
            set: index,
            load: Some(format_load(value, parsed.unit)),
            target_reps: step.reps,
            amrap: false,
            percentage: Some(step.percentage),
            rep_min: None,
            rep_max: None,
        });
        index += 1;
    }

    sets
}

/// Warmup barbell loads use prefixes of the working-set plate stack. Each ramp step only adds
/// plates that stay on for all later steps, avoiding the add/remove-small-plates churn produced
/// by independently snapping every percentage. Non-barbell or unconfigured plans retain the
/// normal equipment snapping behaviour.
fn snap_warmup_load(
    compiled: &CompiledPlan,
    exercise: &str,
    working_sets: &[PrescribedSet],
    target: f64,
) -> f64 {
    let Some(equipment) = compiled.equipment.as_ref() else {
        return snap_load(compiled, exercise, target);
    };
    if implement_for_compiled(compiled, exercise) != Implement::Barbell {
        return snap_load(compiled, exercise, target);
    }
    let Some(work_load) = top_working_load(working_sets) else {
        return snap_load(compiled, exercise, target);
    };
    let work_total = parse_load(&work_load).value;
    let bar = bar_weight(equipment, &compiled.plan.units, exercise);
    let Some(stack) = plate_stack_for_total(bar, &equipment.plate_pairs, work_total) else {
        return snap_load(compiled, exercise, target);
    };
    let mut total = bar;
    let mut prefixes = vec![bar];
    for plate in stack {
        total += 2.0 * plate;
        prefixes.push(total);
    }
    match equipment.rounding {
        RoundingMode::Nearest => nearest(prefixes.into_iter(), target).unwrap_or(bar),
        RoundingMode::Down => prefixes
            .into_iter()
            .filter(|value| *value <= target + SNAP_EPSILON)
            .fold(bar, f64::max),
    }
}

/// Fewest-plate exact decomposition of a work set, preferring larger plates on ties. Returning
/// the stack largest-first makes its prefixes a monotonic loading sequence.
fn plate_stack_for_total(bar: f64, plate_pairs: &[f64], total: f64) -> Option<Vec<f64>> {
    const SCALE: f64 = 100.0;
    if total < bar - SNAP_EPSILON {
        return None;
    }
    let target = (((total - bar) / 2.0) * SCALE).round() as usize;
    if target == 0 {
        return Some(Vec::new());
    }
    if target > 200_000 {
        return None;
    }
    let mut plates = plate_pairs
        .iter()
        .copied()
        .filter(|plate| plate.is_finite() && *plate > 0.0)
        .collect::<Vec<_>>();
    plates.sort_by(|left, right| right.partial_cmp(left).unwrap_or(std::cmp::Ordering::Equal));
    let denoms = plates
        .iter()
        .map(|plate| (*plate * SCALE).round() as usize)
        .collect::<Vec<_>>();
    let mut best: Vec<Option<Vec<usize>>> = vec![None; target + 1];
    best[0] = Some(Vec::new());
    for amount in 1..=target {
        for (index, denom) in denoms.iter().copied().enumerate() {
            if denom > amount {
                continue;
            }
            let Some(previous) = best[amount - denom].as_ref() else {
                continue;
            };
            let mut candidate = previous.clone();
            candidate.push(index);
            if best[amount]
                .as_ref()
                .is_none_or(|current| candidate.len() < current.len())
            {
                best[amount] = Some(candidate);
            }
        }
    }
    let mut stack = best[target]
        .take()?
        .into_iter()
        .map(|index| plates[index])
        .collect::<Vec<_>>();
    stack.sort_by(|left, right| right.partial_cmp(left).unwrap_or(std::cmp::Ordering::Equal));
    Some(stack)
}

/// Heaviest working load of an item — the load a Bay-Strength-style ramp warms
/// up to. All-equal working sets (GZCLP, Starting Strength) collapse to that
/// load; ascending sets (5/3/1) pick the top set.
fn top_working_load(sets: &[PrescribedSet]) -> Option<String> {
    sets.iter()
        .filter_map(|set| set.load.as_deref())
        .max_by(|left, right| {
            parse_load(left)
                .value
                .partial_cmp(&parse_load(right).value)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(str::to_owned)
}

/// Bar weight to prescribe for empty-bar warmups, or `None` when the lift is
/// not barbell work (dumbbell lifts have no empty bar).
fn warmup_bar_weight(compiled: &CompiledPlan, exercise: &str) -> Option<f64> {
    if implement_for_compiled(compiled, exercise) == Implement::Bodyweight {
        return None;
    }
    match compiled.equipment.as_ref() {
        Some(equipment) => match implement_for(equipment, exercise) {
            Implement::Barbell => Some(bar_weight(equipment, &compiled.plan.units, exercise)),
            Implement::Dumbbell | Implement::Bodyweight => None,
        },
        None => Some(match compiled.plan.units {
            Units::Kg => 20.0,
            Units::Lb => 45.0,
        }),
    }
}

/// Resolve the warmup scheme for an item: the plan's policy first (most
/// specific scope wins), then the template's built-in defaults.
fn resolve_warmup(
    compiled: &CompiledPlan,
    slot: &RenderSlot,
    lane: &str,
    exercise: &str,
) -> Option<WarmupScheme> {
    let slot_key = slot.slot_id.to_ascii_lowercase();
    let lane_key = lane.to_ascii_lowercase();
    let exercise_key = normalize_exercise(exercise);
    let tier_key = slot.tier.to_ascii_lowercase();

    pick_warmup(
        &compiled.warmup,
        &slot_key,
        &lane_key,
        &exercise_key,
        &tier_key,
    )
}

fn pick_warmup(
    policy: &WarmupPolicy,
    slot: &str,
    lane: &str,
    exercise: &str,
    tier: &str,
) -> Option<WarmupScheme> {
    policy
        .by_slot
        .get(slot)
        .or_else(|| policy.by_lane.get(lane))
        .or_else(|| policy.by_exercise.get(exercise))
        .or_else(|| policy.by_tier.get(tier))
        .or(policy.default.as_ref())
        .cloned()
}

fn base_state(compiled: &CompiledPlan, lanes: Map<LaneState>) -> StateProjection {
    StateProjection {
        kind: "state_projection".into(),
        schema_version: SCHEMA_VERSION.into(),
        engine_version: ENGINE_VERSION.into(),
        program_hash: compiled.plan_hash.clone(),
        last_event_id: None,
        cursor: Cursor {
            next_session: compiled
                .schedule
                .rotation
                .first()
                .cloned()
                .unwrap_or_else(|| "a1".into()),
            week: 1,
            cycle: 1,
        },
        lanes,
        sessions: Map::new(),
        previous_lanes: Map::new(),
    }
}

fn create_initial_dsl_state(compiled: &CompiledPlan) -> StateProjection {
    let mut lanes = Map::new();
    {
        let dsl = &compiled.template.dsl;
        for item in dsl.sessions.values().flatten() {
            let Some(lane) = dsl.lanes.get(&item.lane) else {
                continue;
            };
            let exercise = dsl_item_exercise(compiled, item, lane);
            let lane_id = dsl_progression_lane(&item.lane, lane, &exercise);
            let first_stage = lane.stages.first().map(|stage| stage.id.clone());
            let initial_value = match lane.initial {
                DslInitial::Basis => compiled
                    .starts
                    .get(&exercise)
                    .or_else(|| compiled.training_maxes.get(&exercise))
                    .cloned(),
                DslInitial::Percent { percentage } => compiled
                    .starts
                    .get(&exercise)
                    .or_else(|| compiled.training_maxes.get(&exercise))
                    .map(|load| scale_load(compiled, &exercise, load, percentage as f64 / 100.0)),
                DslInitial::Performed => compiled.starts.get(&exercise).cloned(),
            };
            let sequenced = matches!(lane.sequence, DslSequence::Cycle | DslSequence::Waves);
            let state = LaneState {
                load: (lane.basis == DslBasis::WorkingWeight)
                    .then_some(initial_value.clone())
                    .flatten(),
                training_max: (lane.basis == DslBasis::TrainingMax)
                    .then_some(initial_value)
                    .flatten(),
                stage: first_stage,
                week: sequenced.then_some(1),
                cycle: sequenced.then_some(1),
                reps: lane
                    .stages
                    .first()
                    .and_then(|stage| stage.groups.iter().find_map(|group| group.rep_min)),
                ..LaneState::default()
            };
            lanes.entry(lane_id).or_insert(state);
        }
    }
    base_state(compiled, lanes)
}

fn dsl_lane_tier(lane_id: &str, lane: &DslLane) -> String {
    lane.tier
        .clone()
        .unwrap_or_else(|| lane_id.rsplit('.').next().unwrap_or("main").to_owned())
}

fn dsl_item_exercise(compiled: &CompiledPlan, item: &DslSessionItem, lane: &DslLane) -> String {
    item.accessory_key
        .as_ref()
        .and_then(|key| compiled.accessories.get(key))
        .cloned()
        .or_else(|| item.default_exercise.clone())
        .unwrap_or_else(|| lane.exercise.clone())
}

fn dsl_progression_lane(lane_id: &str, lane: &DslLane, exercise: &str) -> String {
    format!(
        "{}.{}",
        normalize_exercise(exercise),
        dsl_lane_tier(lane_id, lane)
    )
}

fn render_dsl_next(compiled: &CompiledPlan, state: &StateProjection) -> Result<RenderedSession> {
    let dsl = &compiled.template.dsl;
    let session_id = state.cursor.next_session.to_ascii_lowercase();
    let session = dsl
        .sessions
        .get(&session_id)
        .or_else(|| dsl.sessions.values().next())
        .ok_or_else(|| KnurledError::Parse("custom template has no session".into()))?;
    let mut items = Vec::new();
    for session_item in session {
        let lane = dsl.lanes.get(&session_item.lane).ok_or_else(|| {
            KnurledError::Parse(format!("missing custom lane {}", session_item.lane))
        })?;
        let authored_exercise = dsl_item_exercise(compiled, session_item, lane);
        let progression_lane = dsl_progression_lane(&session_item.lane, lane, &authored_exercise);
        let rendered_exercise =
            apply_exercise_patches(compiled, &authored_exercise, &progression_lane)?;
        let lane_state = state
            .lanes
            .get(&progression_lane)
            .cloned()
            .unwrap_or_default();
        let stage_index = lane_state
            .stage
            .as_deref()
            .and_then(|stage| {
                lane.stages
                    .iter()
                    .position(|candidate| candidate.id == stage)
            })
            .unwrap_or(0);
        let stage = &lane.stages[stage_index];
        let basis = match lane.basis {
            DslBasis::WorkingWeight => lane_state.load.clone(),
            DslBasis::TrainingMax => lane_state.training_max.clone(),
            DslBasis::Bodyweight => None,
        };
        let mut set_number = 1;
        let mut sets = Vec::new();
        for group in &stage.groups {
            for index in 0..group.count {
                let load = basis.as_ref().map(|basis| {
                    scale_load(
                        compiled,
                        &rendered_exercise,
                        basis,
                        group.intensity as f64 / 100.0,
                    )
                });
                sets.push(PrescribedSet {
                    set: set_number,
                    load,
                    target_reps: group
                        .rep_min
                        .map(|minimum| {
                            lane_state
                                .reps
                                .unwrap_or(minimum)
                                .clamp(minimum, group.rep_max.unwrap_or(u32::MAX))
                        })
                        .unwrap_or(group.reps),
                    amrap: group.amrap && index + 1 == group.count,
                    percentage: (group.intensity != 100).then_some(group.intensity),
                    rep_min: group.rep_min,
                    rep_max: group.rep_max,
                });
                set_number += 1;
            }
        }
        let rendered_rules = lane
            .rules
            .iter()
            .filter_map(|rule| {
                if rule.stage.as_deref().is_some_and(|id| id != stage.id) {
                    return None;
                }
                let trigger = match rule.trigger {
                    DslTrigger::CycleEnd if stage_index + 1 != lane.stages.len() => return None,
                    ref trigger => trigger.clone(),
                };
                Some(RenderedDslRule {
                    trigger,
                    effects: rule.effects.clone(),
                })
            })
            .collect::<Vec<_>>();
        let context = RenderedDslContext {
            basis: lane.basis,
            sequence: lane.sequence,
            initial: lane.initial,
            first_stage: lane.stages[0].id.clone(),
            next_stage: lane.stages.get(stage_index + 1).unwrap_or(stage).id.clone(),
        };
        let rep_min = stage.groups.iter().find_map(|group| group.rep_min);
        let preview = EffectPreview {
            pass: rendered_rules
                .iter()
                .filter(|rule| {
                    matches!(rule.trigger, DslTrigger::Pass | DslTrigger::CycleEnd)
                })
                .flat_map(|rule| &rule.effects)
                .filter_map(|effect| {
                    custom_effect(
                        compiled,
                        &progression_lane,
                        &rendered_exercise,
                        &lane_state,
                        &context,
                        rep_min,
                        None,
                        effect,
                    )
                })
                .collect(),
            fail: rendered_rules
                .iter()
                .filter(|rule| {
                    matches!(rule.trigger, DslTrigger::Fail)
                        || matches!(rule.trigger, DslTrigger::Stall { count } if lane_state.stall.unwrap_or(0).saturating_add(1) >= count)
                })
                .flat_map(|rule| &rule.effects)
                .filter_map(|effect| {
                    custom_effect(
                        compiled,
                        &progression_lane,
                        &rendered_exercise,
                        &lane_state,
                        &context,
                        rep_min,
                        None,
                        effect,
                    )
                })
                .collect(),
            adjusted_today: Vec::new(),
        };
        let slot = RenderSlot {
            slot_id: session_item.slot_id.clone(),
            tier: dsl_lane_tier(&session_item.lane, lane),
        };
        let mut item = rendered_item(
            compiled,
            &slot,
            RenderedItemSpec {
                exercise: rendered_exercise.clone(),
                lane: progression_lane,
                stage: Some(stage.id.clone()),
                sets,
                recommended_input: if stage.groups.iter().any(|group| group.amrap) {
                    "amrap_final_set"
                } else {
                    "per_set_reps"
                },
                effect_preview: preview,
                training_max: lane_state.training_max.clone(),
            },
        )?;
        if lane.basis == DslBasis::Bodyweight {
            item.implement = Implement::Bodyweight;
            for set in &mut item.prescription.sets {
                set.load = None;
            }
            item.prescription.warmups.clear();
        }
        item.dsl_rules = rendered_rules;
        item.dsl_context = Some(context);
        let plan_warmup = pick_warmup(
            &compiled.warmup,
            &slot.slot_id.to_ascii_lowercase(),
            &item.progression_lane.to_ascii_lowercase(),
            &normalize_exercise(&rendered_exercise),
            &slot.tier.to_ascii_lowercase(),
        );
        if plan_warmup.is_none() {
            if let Some(warmup_spec) = lane.warmup.as_ref().or(dsl.warmup.as_ref()) {
                let warmup_basis = match warmup_spec.basis {
                    WarmupBasis::TrainingMax => lane_state.training_max.clone(),
                    WarmupBasis::WorkingWeight => lane_state.load.clone(),
                    WarmupBasis::TopSet => top_working_load(&item.prescription.sets),
                };
                item.prescription.warmups = custom_warmups(
                    compiled,
                    &rendered_exercise,
                    warmup_basis.as_deref(),
                    &item.prescription.sets,
                    warmup_spec,
                );
            }
        }
        items.push(item);
    }
    attach_rendered_session_hash(
        compiled,
        RenderedSession {
            kind: "rendered_session".into(),
            schema_version: SCHEMA_VERSION.into(),
            engine_version: ENGINE_VERSION.into(),
            session_id: session_id.clone(),
            display_name: format!(
                "{} - {}",
                dsl.name,
                dsl.session_display_names
                    .get(&session_id)
                    .cloned()
                    .unwrap_or_else(|| session_id.to_ascii_uppercase())
            ),
            suggested_date: None,
            plan_hash: compiled.plan_hash.clone(),
            template_hash: compiled.template_hash.clone(),
            rendered_session_hash: String::new(),
            items: with_session_exercises(compiled, items),
        },
    )
}

fn custom_warmups(
    compiled: &CompiledPlan,
    exercise: &str,
    basis: Option<&str>,
    working_sets: &[PrescribedSet],
    scheme: &WarmupScheme,
) -> Vec<PrescribedSet> {
    let Some(basis) = basis else {
        return Vec::new();
    };
    let parsed = parse_load(basis);
    let mut sets = Vec::new();
    let mut set_number = 1;
    if scheme.empty_bar_sets > 0
        && scheme.empty_bar_reps > 0
        && let Some(bar) = warmup_bar_weight(compiled, exercise)
    {
        for _ in 0..scheme.empty_bar_sets {
            sets.push(PrescribedSet {
                set: set_number,
                load: Some(format_load(bar, parsed.unit)),
                target_reps: scheme.empty_bar_reps,
                amrap: false,
                percentage: None,
                rep_min: None,
                rep_max: None,
            });
            set_number += 1;
        }
    }
    for step in &scheme.ramp {
        let target = parsed.value * step.percentage as f64 / 100.0;
        let value = snap_warmup_load(compiled, exercise, working_sets, target);
        if sets
            .last()
            .and_then(|set| set.load.as_deref())
            .is_some_and(|load| value <= parse_load(load).value)
        {
            continue;
        }
        sets.push(PrescribedSet {
            set: set_number,
            load: Some(format_load(value, parsed.unit)),
            target_reps: step.reps,
            amrap: false,
            percentage: Some(step.percentage),
            rep_min: None,
            rep_max: None,
        });
        set_number += 1;
    }
    sets
}

fn custom_effect(
    compiled: &CompiledPlan,
    lane_id: &str,
    exercise: &str,
    state: &LaneState,
    context: &RenderedDslContext,
    rep_min: Option<u32>,
    performed_load: Option<&str>,
    effect: &DslEffect,
) -> Option<Effect> {
    let current_load = match context.basis {
        DslBasis::TrainingMax => state.training_max.as_deref(),
        _ => state.load.as_deref(),
    }
    .or(performed_load);
    let result = match effect {
        DslEffect::IncreaseLoad { amount } => Effect {
            op: if context.basis == DslBasis::TrainingMax {
                "recompute_tm".into()
            } else {
                "increase_load".into()
            },
            lane: lane_id.into(),
            from: current_load.map(str::to_owned),
            to: current_load.map(|load| {
                if let Some(percent) = amount
                    .strip_suffix('%')
                    .and_then(|value| value.parse::<f64>().ok())
                {
                    scale_load(compiled, exercise, load, 1.0 + percent / 100.0)
                } else {
                    add_load(compiled, exercise, load, parse_load(amount).value)
                }
            }),
        },
        DslEffect::Deload { percent } => Effect {
            op: "deload".into(),
            lane: lane_id.into(),
            from: current_load.map(str::to_owned),
            to: current_load
                .map(|load| scale_load(compiled, exercise, load, *percent as f64 / 100.0)),
        },
        DslEffect::ResetLoad { percent } => Effect {
            op: "reset_load".into(),
            lane: lane_id.into(),
            from: current_load.map(str::to_owned),
            to: current_load
                .map(|load| scale_load(compiled, exercise, load, *percent as f64 / 100.0)),
        },
        DslEffect::AdvanceStage => {
            let current = state.stage.as_deref().unwrap_or(&context.first_stage);
            Effect {
                op: "advance_stage".into(),
                lane: lane_id.into(),
                from: Some(current.into()),
                to: Some(context.next_stage.clone()),
            }
        }
        DslEffect::ResetStage => Effect {
            op: "reset_stage".into(),
            lane: lane_id.into(),
            from: state.stage.clone(),
            to: Some(context.first_stage.clone()),
        },
        DslEffect::IncreaseReps { amount } => Effect {
            op: "increase_reps".into(),
            lane: lane_id.into(),
            from: state.reps.or(rep_min).map(|value| value.to_string()),
            to: Some(
                state
                    .reps
                    .or(rep_min)
                    .unwrap_or(0)
                    .saturating_add(*amount)
                    .to_string(),
            ),
        },
        DslEffect::ResetReps => Effect {
            op: "reset_reps".into(),
            lane: lane_id.into(),
            from: state.reps.map(|value| value.to_string()),
            to: rep_min.map(|value| value.to_string()),
        },
        DslEffect::RecomputeTm { amount } => Effect {
            op: "recompute_tm".into(),
            lane: lane_id.into(),
            from: state.training_max.clone(),
            to: state
                .training_max
                .as_deref()
                .map(|load| add_load(compiled, exercise, load, parse_load(amount).value)),
        },
        DslEffect::AdvanceCycle => Effect {
            op: "advance_cycle".into(),
            lane: lane_id.into(),
            from: state.cycle.map(|value| value.to_string()),
            to: Some(state.cycle.unwrap_or(1).saturating_add(1).to_string()),
        },
    };
    result.to.as_ref()?;
    Some(result)
}

fn with_session_exercises(
    compiled: &CompiledPlan,
    mut main_items: Vec<RenderedItem>,
) -> Vec<RenderedItem> {
    let mut items = Vec::new();
    items.extend(
        compiled
            .session_exercises
            .warmup
            .iter()
            .enumerate()
            .map(|(index, exercise)| {
                session_exercise_item(compiled, RenderedItemPhase::Warmup, index, exercise)
            }),
    );
    items.append(&mut main_items);
    items.extend(compiled.session_exercises.warmdown.iter().enumerate().map(
        |(index, exercise)| {
            session_exercise_item(compiled, RenderedItemPhase::Warmdown, index, exercise)
        },
    ));
    items
}

fn session_exercise_item(
    compiled: &CompiledPlan,
    phase: RenderedItemPhase,
    index: usize,
    exercise: &SessionExercise,
) -> RenderedItem {
    let phase_id = match phase {
        RenderedItemPhase::Warmup => "warmup",
        RenderedItemPhase::Warmdown => "warmdown",
        RenderedItemPhase::Main => "main",
    };
    let item_id = format!("{phase_id}.{}.{}", index + 1, exercise.exercise);
    let implement = implement_for_compiled(compiled, &exercise.exercise);
    let load = (implement != Implement::Bodyweight)
        .then(|| exercise.load.clone())
        .flatten();
    let sets = (1..=exercise.sets.max(1))
        .map(|set| PrescribedSet {
            set,
            load: load.clone(),
            target_reps: exercise.reps,
            amrap: false,
            percentage: None,
            rep_min: None,
            rep_max: None,
        })
        .collect::<Vec<_>>();
    let title = exercise
        .label
        .clone()
        .unwrap_or_else(|| title_case(&exercise.exercise));
    let phase_title = match phase {
        RenderedItemPhase::Warmup => "Warmup",
        RenderedItemPhase::Warmdown => "Warmdown",
        RenderedItemPhase::Main => "Exercise",
    };

    RenderedItem {
        phase,
        item_id: item_id.clone(),
        slot_id: item_id.clone(),
        progression_lane: String::new(),
        progression_rule: "tracking_only".into(),
        exercise: exercise.exercise.clone(),
        implement,
        display: DisplayFields {
            title,
            subtitle: exercise
                .note
                .clone()
                .unwrap_or_else(|| phase_title.to_owned()),
        },
        prescription: Prescription {
            warmups: Vec::new(),
            sets: sets.clone(),
        },
        execution_contract: ExecutionContract {
            recommended_input: "per_set_reps".into(),
            fallback_inputs: Vec::new(),
            completion_rule: "optional".into(),
            event_template: "tracking_only_v1".into(),
            required_for_completion: false,
            input_schema: InputSchema {
                mode: "per_set_reps".into(),
                fields: Vec::new(),
                fallback: None,
            },
        },
        effect_preview: EffectPreview {
            pass: Vec::new(),
            fail: Vec::new(),
            adjusted_today: Vec::new(),
        },
        rest: RestPrescription {
            seconds: 30,
            source: RestSource::EngineFallback,
            key: phase_id.into(),
        },
        identity: ItemIdentity {
            item_id: item_id.clone(),
            slot_id: item_id,
            progression_lane: String::new(),
            progression_rule: "tracking_only".into(),
            plan_hash: compiled.plan_hash.clone(),
            rendered_session_hash: String::new(),
        },
        exercise_options: None,
        dsl_rules: Vec::new(),
        dsl_context: None,
    }
}

struct RenderedItemSpec<'a> {
    exercise: String,
    lane: String,
    stage: Option<String>,
    sets: Vec<PrescribedSet>,
    recommended_input: &'a str,
    effect_preview: EffectPreview,
    /// Training max for this lane, when the program tracks one (5/3/1). Lets a
    /// warmup scheme ramp off the training max rather than the working set.
    training_max: Option<String>,
}

struct RenderSlot {
    slot_id: String,
    tier: String,
}

fn rendered_item(
    compiled: &CompiledPlan,
    slot: &RenderSlot,
    spec: RenderedItemSpec<'_>,
) -> Result<RenderedItem> {
    let implement = implement_for_compiled(compiled, &spec.exercise);
    let mut sets = spec.sets.clone();
    if implement == Implement::Bodyweight {
        for set in &mut sets {
            set.load = None;
        }
    }
    // A plan's own `exercise_options` for a slot win outright; otherwise fall
    // back to the template's built-in swaps for the prescribed main lift, so the
    // headline barbell lifts always carry approved alternatives even when the
    // plan author never curated the slot.
    let exercise_options = compiled
        .exercise_options
        .get(&slot.slot_id.to_ascii_lowercase())
        .map(|options| RenderedExerciseOptions {
            primary: options.primary.clone(),
            allow_runtime_swap: true,
            default_policy: SwapPolicy::TrackingOnly,
            alternatives: options.alternatives.clone(),
        })
        .or_else(|| {
            let alternatives = default_exercise_alternatives(&spec.exercise);
            (!alternatives.is_empty()).then(|| RenderedExerciseOptions {
                primary: spec.exercise.clone(),
                allow_runtime_swap: true,
                default_policy: SwapPolicy::TrackingOnly,
                alternatives,
            })
        });
    Ok(RenderedItem {
        phase: RenderedItemPhase::Main,
        item_id: slot.slot_id.clone(),
        slot_id: slot.slot_id.clone(),
        progression_lane: spec.lane.clone(),
        progression_rule: format!("dsl.{}", slot.tier),
        exercise: spec.exercise.clone(),
        implement,
        display: DisplayFields {
            title: format!(
                "{} {}",
                title_case(&spec.exercise),
                slot.tier.to_ascii_uppercase()
            ),
            subtitle: subtitle_for(&sets, spec.stage.as_deref()),
        },
        prescription: Prescription {
            warmups: compute_warmups(compiled, slot, &spec),
            sets: sets.clone(),
        },
        execution_contract: execution_contract(spec.recommended_input, &sets),
        effect_preview: spec.effect_preview,
        rest: resolve_rest(compiled, slot, &spec.lane, &spec.exercise),
        identity: ItemIdentity {
            item_id: slot.slot_id.clone(),
            slot_id: slot.slot_id.clone(),
            progression_lane: spec.lane,
            progression_rule: String::new(),
            plan_hash: compiled.plan_hash.clone(),
            rendered_session_hash: String::new(),
        },
        exercise_options,
        dsl_rules: Vec::new(),
        dsl_context: None,
    })
}

fn resolve_rest(
    compiled: &CompiledPlan,
    slot: &RenderSlot,
    lane: &str,
    exercise: &str,
) -> RestPrescription {
    let slot_key = slot.slot_id.to_ascii_lowercase();
    let lane_key = lane.to_ascii_lowercase();
    let exercise_key = normalize_exercise(exercise);
    let tier_key = slot.tier.to_ascii_lowercase();

    find_rest(&compiled.rest.by_slot, &slot_key, RestSource::PlanSlot)
        .or_else(|| find_rest(&compiled.rest.by_lane, &lane_key, RestSource::PlanLane))
        .or_else(|| {
            find_rest(
                &compiled.rest.by_exercise,
                &exercise_key,
                RestSource::PlanExercise,
            )
        })
        .or_else(|| find_rest(&compiled.rest.by_tier, &tier_key, RestSource::PlanTier))
        .or_else(|| {
            compiled
                .rest
                .default_seconds
                .map(|seconds| rest_prescription(seconds, RestSource::PlanDefault, "default"))
        })
        .or_else(|| {
            find_rest(
                &compiled.template.rest.by_slot,
                &slot_key,
                RestSource::TemplateSlot,
            )
        })
        .or_else(|| {
            find_rest(
                &compiled.template.rest.by_lane,
                &lane_key,
                RestSource::TemplateLane,
            )
        })
        .or_else(|| {
            find_rest(
                &compiled.template.rest.by_exercise,
                &exercise_key,
                RestSource::TemplateExercise,
            )
        })
        .or_else(|| {
            find_rest(
                &compiled.template.rest.by_tier,
                &tier_key,
                RestSource::TemplateTier,
            )
        })
        .or_else(|| {
            compiled
                .template
                .rest
                .default_seconds
                .map(|seconds| rest_prescription(seconds, RestSource::TemplateDefault, "default"))
        })
        .unwrap_or_else(|| rest_prescription(120, RestSource::EngineFallback, "engine_fallback"))
}

fn find_rest(map: &Map<u32>, key: &str, source: RestSource) -> Option<RestPrescription> {
    map.get(key)
        .map(|seconds| rest_prescription(*seconds, source, key))
}

fn rest_prescription(seconds: u32, source: RestSource, key: &str) -> RestPrescription {
    RestPrescription {
        seconds,
        source,
        key: key.to_owned(),
    }
}

fn attach_rendered_session_hash(
    compiled: &CompiledPlan,
    mut session: RenderedSession,
) -> Result<RenderedSession> {
    let hash = sha256_json(&session)?;
    session.rendered_session_hash = hash.clone();
    for item in &mut session.items {
        item.identity = ItemIdentity {
            item_id: item.item_id.clone(),
            slot_id: item.slot_id.clone(),
            progression_lane: item.progression_lane.clone(),
            progression_rule: item.progression_rule.clone(),
            plan_hash: compiled.plan_hash.clone(),
            rendered_session_hash: hash.clone(),
        };
    }
    Ok(session)
}

fn execution_contract(mode: &str, sets: &[PrescribedSet]) -> ExecutionContract {
    ExecutionContract {
        recommended_input: mode.into(),
        fallback_inputs: if mode == "amrap_final_set" {
            vec!["per_set_reps".into(), "load_override".into(), "note".into()]
        } else {
            vec!["load_override".into(), "note".into()]
        },
        completion_rule: "all_required_sets_meet_target".into(),
        event_template: "exercise_result_v1".into(),
        required_for_completion: true,
        input_schema: if mode == "amrap_final_set" {
            let target = sets.last().map(|set| set.target_reps).unwrap_or_default();
            InputSchema {
                mode: mode.into(),
                fields: vec![InputField {
                    name: "final_set_reps".into(),
                    field_type: "integer".into(),
                    min: Some(0),
                    max: None,
                    default: Some(json!(target)),
                    required: true,
                }],
                fallback: Some("per_set_reps".into()),
            }
        } else {
            InputSchema {
                mode: mode.into(),
                fields: vec![InputField {
                    name: "sets".into(),
                    field_type: "set_results".into(),
                    min: None,
                    max: None,
                    default: Some(json!("done_as_prescribed")),
                    required: true,
                }],
                fallback: Some("per_set_reps".into()),
            }
        },
    }
}

pub(crate) fn reduce_item(
    item: &RenderedItem,
    input: &ItemInput,
    compiled: &CompiledPlan,
    state: &StateProjection,
) -> Result<ExerciseResult> {
    let actual = actual_sets_for(item, input)?;
    // A lift only progresses when all of its prescribed working sets (warmups are
    // separate) were performed. An exercise left unfinished is recorded but moves
    // nothing — so a partial session still progresses the lifts that were done.
    let all_working_sets_done = item
        .prescription
        .sets
        .iter()
        .all(|prescribed| actual.iter().any(|done| done.set == prescribed.set));
    let adjusted_today = actual.iter().any(|set| {
        let prescribed = item
            .prescription
            .sets
            .iter()
            .find(|prescribed| prescribed.set == set.set)
            .and_then(|set| set.load.as_ref());
        set.load
            .as_ref()
            .zip(prescribed)
            .is_some_and(|(actual, prescribed)| actual != prescribed)
    });
    let outcome = if !all_working_sets_done {
        "incomplete".to_owned()
    } else if adjusted_today {
        "adjusted_today".to_owned()
    } else {
        outcome_for(item, &actual)
    };
    let effects = if all_working_sets_done {
        effects_for_outcome(compiled, item, &outcome, &actual, state)
    } else {
        Vec::new()
    };

    Ok(ExerciseResult {
        slot_id: item.slot_id.clone(),
        progression_lane: Some(item.progression_lane.clone()),
        progression_rule: Some(item.progression_rule.clone()),
        prescribed_exercise: Some(item.exercise.clone()),
        performed_exercise: Some(
            input
                .performed_exercise
                .clone()
                .unwrap_or_else(|| item.exercise.clone()),
        ),
        swap_reason: input.swap_reason.clone(),
        swap_policy: input.swap_policy.clone(),
        prescribed: compact_prescribed(&item.prescription.sets),
        actual,
        outcome,
        effects,
    })
}

fn compact_prescribed(sets: &[PrescribedSet]) -> serde_json::Value {
    let same_load = sets
        .first()
        .map(|first| sets.iter().all(|set| set.load == first.load))
        .unwrap_or(true);
    let no_percentages = sets.iter().all(|set| set.percentage.is_none());

    if same_load && no_percentages {
        let reps = sets
            .iter()
            .map(|set| {
                if set.amrap {
                    json!(format!("{}+", set.target_reps))
                } else {
                    json!(set.target_reps)
                }
            })
            .collect::<Vec<_>>();
        if let Some(load) = sets.first().and_then(|set| set.load.clone()) {
            json!({ "load": load, "reps": reps })
        } else {
            json!({ "reps": reps })
        }
    } else {
        json!({ "sets": sets })
    }
}

fn actual_sets_for(item: &RenderedItem, input: &ItemInput) -> Result<Vec<ActualSet>> {
    match input.mode.as_str() {
        "amrap_final_set" => {
            let final_reps = input.final_set_reps.ok_or_else(|| {
                KnurledError::InvalidExecutionInput(format!(
                    "{} requires final_set_reps",
                    item.item_id
                ))
            })?;
            Ok(item
                .prescription
                .sets
                .iter()
                .enumerate()
                .map(|(index, set)| ActualSet {
                    set: set.set,
                    load: input
                        .load
                        .clone()
                        .or_else(|| {
                            input
                                .sets
                                .iter()
                                .find(|actual| actual.set == set.set)
                                .and_then(|actual| actual.load.clone())
                        })
                        .or_else(|| set.load.clone()),
                    reps: if index == item.prescription.sets.len() - 1 {
                        final_reps
                    } else {
                        set.target_reps
                    },
                    metrics: input
                        .sets
                        .iter()
                        .find(|actual| actual.set == set.set)
                        .map(|actual| actual.metrics.clone())
                        .unwrap_or_default(),
                })
                .collect())
        }
        "per_set_reps" => Ok(input
            .sets
            .iter()
            .filter(|actual| {
                item.prescription
                    .sets
                    .iter()
                    .any(|prescribed| prescribed.set == actual.set)
            })
            .cloned()
            .collect()),
        _ => Ok(item
            .prescription
            .sets
            .iter()
            .map(|set| ActualSet {
                set: set.set,
                load: set.load.clone(),
                reps: set.target_reps,
                metrics: Default::default(),
            })
            .collect()),
    }
}

fn outcome_for(item: &RenderedItem, actual: &[ActualSet]) -> String {
    if item
        .prescription
        .sets
        .iter()
        .zip(actual)
        .all(|(target, actual)| actual.reps >= target.target_reps)
    {
        "pass".into()
    } else {
        "fail".into()
    }
}

fn effects_for_outcome(
    compiled: &CompiledPlan,
    item: &RenderedItem,
    outcome: &str,
    actual: &[ActualSet],
    state: &StateProjection,
) -> Vec<Effect> {
    if let Some(context) = &item.dsl_context {
        let lane_state = state
            .lanes
            .get(&item.progression_lane)
            .cloned()
            .unwrap_or_default();
        let range_top = dsl_range_top(item, actual);
        let matched = item
            .dsl_rules
            .iter()
            .filter(|rule| {
                !(range_top && matches!(rule.trigger, DslTrigger::Pass))
                    && dsl_trigger_matches(&rule.trigger, outcome, item, actual, &lane_state)
            })
            .collect::<Vec<_>>();
        let performed_load = actual.iter().rev().find_map(|set| set.load.as_deref());
        let rep_min = item.prescription.sets.iter().find_map(|set| set.rep_min);
        let mut effects = Vec::new();
        let matched_changes_load = matched.iter().flat_map(|rule| &rule.effects).any(|effect| {
            matches!(
                effect,
                DslEffect::IncreaseLoad { .. }
                    | DslEffect::Deload { .. }
                    | DslEffect::ResetLoad { .. }
            )
        });
        if context.initial == DslInitial::Performed
            && lane_state.load.is_none()
            && !matched_changes_load
            && matches!(outcome, "pass" | "fail")
            && let Some(load) = performed_load
        {
            effects.push(set_load_effect(&item.progression_lane, None, load));
        }
        effects.extend(
            matched
                .iter()
                .flat_map(|rule| &rule.effects)
                .filter_map(|effect| {
                    custom_effect(
                        compiled,
                        &item.progression_lane,
                        &item.exercise,
                        &lane_state,
                        context,
                        rep_min,
                        performed_load,
                        effect,
                    )
                }),
        );

        let old_stall = lane_state.stall.unwrap_or(0);
        let next_stall = match outcome {
            "pass" => 0,
            "fail" => old_stall.saturating_add(1),
            _ => old_stall,
        };
        let deloaded = matched
            .iter()
            .flat_map(|rule| &rule.effects)
            .any(|effect| matches!(effect, DslEffect::Deload { .. }));
        let final_stall = if deloaded { 0 } else { next_stall };
        if final_stall != old_stall {
            effects.push(Effect {
                op: "set_stall".into(),
                lane: item.progression_lane.clone(),
                from: Some(old_stall.to_string()),
                to: Some(final_stall.to_string()),
            });
        }
        return effects;
    }
    let effects = match outcome {
        "pass" => &item.effect_preview.pass,
        "fail" => &item.effect_preview.fail,
        "adjusted_today" => &item.effect_preview.adjusted_today,
        _ => &item.effect_preview.fail,
    };
    effects
        .iter()
        .filter(|effect| effect.to.is_some())
        .cloned()
        .collect()
}

fn dsl_trigger_matches(
    trigger: &DslTrigger,
    outcome: &str,
    item: &RenderedItem,
    actual: &[ActualSet],
    state: &LaneState,
) -> bool {
    match trigger {
        DslTrigger::Pass => outcome == "pass",
        DslTrigger::Fail => outcome == "fail",
        DslTrigger::AmrapGte { reps } => {
            outcome != "incomplete" && actual.last().is_some_and(|set| set.reps >= *reps)
        }
        DslTrigger::RangeTop => outcome == "pass" && dsl_range_top(item, actual),
        DslTrigger::CycleEnd => outcome == "pass",
        DslTrigger::Stall { count } => {
            outcome == "fail" && state.stall.unwrap_or(0).saturating_add(1) >= *count
        }
    }
}

fn dsl_range_top(item: &RenderedItem, actual: &[ActualSet]) -> bool {
    let ranged = item
        .prescription
        .sets
        .iter()
        .filter_map(|set| set.rep_max.map(|maximum| (set.set, maximum)))
        .collect::<Vec<_>>();
    !ranged.is_empty()
        && ranged.iter().all(|(set, maximum)| {
            actual
                .iter()
                .find(|actual| actual.set == *set)
                .is_some_and(|actual| actual.reps >= *maximum)
        })
}

pub(crate) fn apply_effects(state: &mut StateProjection, effects: &[Effect]) {
    for effect in effects {
        match effect.op.as_str() {
            "increase_load" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.load = effect.to.clone();
                }
            }
            "set_load" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.load = effect.to.clone();
                }
            }
            "advance_stage" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.stage = effect.to.clone();
                    if lane.week.is_some() {
                        lane.week = Some(lane.week.unwrap_or(1).saturating_add(1));
                    }
                }
            }
            "reset_stage" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.stage = effect.to.clone();
                    if lane.week.is_some() {
                        lane.week = Some(1);
                    }
                }
            }
            "reset_load" | "deload" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.load = effect.to.clone();
                    if lane.training_max.is_some() {
                        lane.training_max = effect.to.clone();
                    }
                    if effect.op == "deload" {
                        lane.stall = Some(0);
                    }
                }
            }
            "increase_reps" | "reset_reps" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.reps = effect.to.as_deref().and_then(|value| value.parse().ok());
                }
            }
            "set_stall" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.stall = effect.to.as_deref().and_then(|value| value.parse().ok());
                }
            }
            "recompute_tm" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.training_max = effect.to.clone();
                }
            }
            "advance_cycle" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.cycle = effect.to.as_deref().and_then(|value| value.parse().ok());
                }
                state.cursor.cycle = effect
                    .to
                    .as_deref()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(state.cursor.cycle);
            }
            _ => {}
        }
    }
}

fn set_load_effect(lane: &str, from: Option<&str>, to: &str) -> Effect {
    Effect {
        op: "set_load".into(),
        lane: lane.into(),
        from: from.map(str::to_owned),
        to: Some(to.into()),
    }
}

fn apply_exercise_patches(compiled: &CompiledPlan, exercise: &str, lane: &str) -> Result<String> {
    let mut next = exercise.to_owned();
    for patch in &compiled.patches {
        for operation in &patch.operations {
            if let PatchOperation::ReplaceExercise {
                from,
                to,
                lane_regex,
            } = operation
                && from == &next
                && Regex::new(lane_regex)
                    .map(|regex| regex.is_match(lane))
                    .unwrap_or(false)
            {
                next = to.clone();
            }
        }
    }
    Ok(next)
}

#[derive(Debug, Clone, Copy)]
struct ParsedLoad<'a> {
    value: f64,
    unit: &'a str,
}

fn parse_load(load: &str) -> ParsedLoad<'_> {
    let split = load
        .find(|ch: char| ch.is_ascii_alphabetic())
        .unwrap_or(load.len());
    let value = load[..split].parse().unwrap_or_default();
    let unit = &load[split..];
    ParsedLoad { value, unit }
}

fn scale_load(compiled: &CompiledPlan, exercise: &str, load: &str, multiplier: f64) -> String {
    let parsed = parse_load(load);
    format_load(
        snap_load(compiled, exercise, parsed.value * multiplier),
        parsed.unit,
    )
}

fn add_load(compiled: &CompiledPlan, exercise: &str, load: &str, increment: f64) -> String {
    let parsed = parse_load(load);
    let value = parsed.value + increment;
    // With no equipment configured, progression increments are applied as-is —
    // historical behaviour, and what keeps existing plans byte-identical. Only
    // an explicit equipment profile snaps the result onto the lifter's grid.
    let value = match compiled.equipment.as_ref() {
        Some(equipment) => snap_with_equipment(equipment, &compiled.plan.units, exercise, value),
        None => value,
    };
    format_load(value, parsed.unit)
}

const SNAP_EPSILON: f64 = 1e-6;

/// Round a raw numeric load to the nearest weight the lifter can actually
/// load. With no equipment configured this is the historical fixed 2.5-unit
/// rounding, so existing plans are unaffected.
fn snap_load(compiled: &CompiledPlan, exercise: &str, value: f64) -> f64 {
    match compiled.equipment.as_ref() {
        Some(equipment) => snap_with_equipment(equipment, &compiled.plan.units, exercise, value),
        None => round_to_increment(value, 2.5),
    }
}

fn snap_with_equipment(
    equipment: &EquipmentProfile,
    units: &Units,
    exercise: &str,
    value: f64,
) -> f64 {
    match implement_for(equipment, exercise) {
        Implement::Bodyweight => 0.0,
        Implement::Dumbbell => snap_to_list(&equipment.dumbbells, equipment.rounding, value)
            .unwrap_or_else(|| round_to_increment(value, 2.5)),
        Implement::Barbell => {
            let bar = bar_weight(equipment, units, exercise);
            snap_barbell(bar, &equipment.plate_pairs, equipment.rounding, value)
                .unwrap_or_else(|| round_to_increment(value, 2.5))
        }
    }
}

fn implement_for(equipment: &EquipmentProfile, exercise: &str) -> Implement {
    if let Some(implement) = equipment.implements.get(exercise) {
        return *implement;
    }
    if exercise.contains("dumbbell") || exercise.contains("_db") || exercise.starts_with("db_") {
        Implement::Dumbbell
    } else {
        Implement::Barbell
    }
}

/// Resolve exercise metadata without teaching clients exercise-name semantics. Explicit plan
/// metadata wins, then the equipment override, then the engine-owned built-in catalogue.
fn implement_for_compiled(compiled: &CompiledPlan, exercise: &str) -> Implement {
    let normalized = normalize_exercise(exercise);
    if let Some(value) = compiled
        .exercises
        .get(&normalized)
        .and_then(|exercise| exercise.implement.as_deref())
    {
        return implement_from_metadata(value);
    }
    if let Some(equipment) = compiled.equipment.as_ref()
        && let Some(implement) = equipment.implements.get(&normalized)
    {
        return *implement;
    }
    if let Some(value) = exercise_catalog()
        .into_iter()
        .find(|entry| entry.id == normalized)
        .and_then(|entry| entry.implement)
    {
        return implement_from_metadata(&value);
    }
    if normalized.contains("dumbbell")
        || normalized.contains("_db")
        || normalized.starts_with("db_")
    {
        Implement::Dumbbell
    } else {
        Implement::Barbell
    }
}

fn implement_from_metadata(value: &str) -> Implement {
    match value.trim().to_ascii_lowercase().as_str() {
        "bodyweight" => Implement::Bodyweight,
        "dumbbell" => Implement::Dumbbell,
        _ => Implement::Barbell,
    }
}

fn bar_weight(equipment: &EquipmentProfile, units: &Units, exercise: &str) -> f64 {
    equipment
        .bars
        .get(exercise)
        .or_else(|| equipment.bars.get("default"))
        .copied()
        .unwrap_or(match units {
            Units::Kg => 20.0,
            Units::Lb => 45.0,
        })
}

/// Nearest value in a discrete list (dumbbell sizes). Ties resolve downward;
/// `Down` never exceeds the target.
fn snap_to_list(values: &[f64], rounding: RoundingMode, target: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    match rounding {
        RoundingMode::Down => values
            .iter()
            .copied()
            .filter(|value| *value <= target + SNAP_EPSILON)
            .fold(None, |best: Option<f64>, value| {
                Some(best.map_or(value, |best| best.max(value)))
            })
            .or_else(|| {
                values
                    .iter()
                    .copied()
                    .reduce(|min, value| if value < min { value } else { min })
            }),
        RoundingMode::Nearest => nearest(values.iter().copied(), target),
    }
}

/// Nearest achievable barbell total: `bar + 2 × (multiset of plate pairs)`.
/// Plates are treated as unlimited in quantity (we do not model plate counts).
fn snap_barbell(bar: f64, plate_pairs: &[f64], rounding: RoundingMode, target: f64) -> Option<f64> {
    if plate_pairs.is_empty() {
        return None;
    }
    if target <= bar + SNAP_EPSILON {
        return Some(bar);
    }
    let per_side_target = (target - bar) / 2.0;
    let reachable = reachable_per_side_sums(plate_pairs, per_side_target);
    let chosen = match rounding {
        RoundingMode::Down => reachable
            .iter()
            .copied()
            .filter(|sum| *sum <= per_side_target + SNAP_EPSILON)
            .fold(0.0, f64::max),
        RoundingMode::Nearest => nearest(reachable.iter().copied(), per_side_target)?,
    };
    Some(bar + 2.0 * chosen)
}

/// Per-side sums reachable from unlimited copies of `plate_pairs`, from 0 up to
/// just past `target`. Computed on a centi-unit integer grid so float error
/// never makes an achievable load look unreachable.
fn reachable_per_side_sums(plate_pairs: &[f64], target: f64) -> Vec<f64> {
    const SCALE: f64 = 100.0;
    // Cap the search a little past the target (plus the largest plate) so the
    // nearest sum above the target is still considered, with a hard ceiling to
    // bound the allocation for pathological inputs.
    let largest = plate_pairs.iter().copied().fold(0.0, f64::max);
    let cap_units = (((target + largest) * SCALE).ceil() as usize + 1).min(200_000);
    let denoms: Vec<usize> = plate_pairs
        .iter()
        .map(|plate| (plate * SCALE).round() as usize)
        .filter(|units| *units > 0)
        .collect();
    let mut reachable = vec![false; cap_units + 1];
    reachable[0] = true;
    for index in 1..=cap_units {
        if denoms
            .iter()
            .any(|denom| *denom <= index && reachable[index - denom])
        {
            reachable[index] = true;
        }
    }
    reachable
        .iter()
        .enumerate()
        .filter(|(_, ok)| **ok)
        .map(|(index, _)| index as f64 / SCALE)
        .collect()
}

/// Value nearest to `target`; equidistant candidates resolve to the lower one.
fn nearest(values: impl Iterator<Item = f64>, target: f64) -> Option<f64> {
    values.reduce(|best, value| {
        let best_gap = (best - target).abs();
        let gap = (value - target).abs();
        if gap < best_gap - SNAP_EPSILON {
            value
        } else if (gap - best_gap).abs() <= SNAP_EPSILON {
            best.min(value)
        } else {
            best
        }
    })
}

fn format_load(value: f64, unit: &str) -> String {
    if value.fract() == 0.0 {
        format!("{}{}", value as i64, unit)
    } else {
        format!("{}{}", trim_float(value), unit)
    }
}

fn round_to_increment(value: f64, increment: f64) -> f64 {
    (value / increment).round() * increment
}

fn trim_float(value: f64) -> String {
    let mut text = format!("{value:.2}");
    while text.contains('.') && text.ends_with('0') {
        text.pop();
    }
    if text.ends_with('.') {
        text.pop();
    }
    text
}

fn subtitle_for(sets: &[PrescribedSet], stage: Option<&str>) -> String {
    let load = sets
        .first()
        .and_then(|set| set.load.as_deref())
        .unwrap_or("bodyweight");
    if let Some(stage) = stage {
        format!("{load} - {stage}")
    } else {
        let reps = sets
            .iter()
            .map(|set| {
                if set.amrap {
                    format!("{}+", set.target_reps)
                } else {
                    set.target_reps.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join(" / ");
        format!("{load} - {reps}")
    }
}

fn title_case(value: &str) -> String {
    normalize_exercise(value)
        .split('_')
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

fn message(code: impl Into<String>, message: impl Into<String>) -> ValidationMessage {
    ValidationMessage {
        code: code.into(),
        message: message.into(),
    }
}
