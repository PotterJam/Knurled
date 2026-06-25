use regex::Regex;
use serde_json::json;

use crate::error::{KnurledError, Result};
use crate::json::sha256_json;
use crate::model::*;
use crate::parser::{normalize_exercise, parse_lock, parse_patch, parse_plan};
use crate::templates::{
    builtin_template, lock_entry, parse_template_ref, template_display_name, template_hash,
};

const MAIN_LIFTS: [&str; 4] = ["squat", "bench", "press", "deadlift"];

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
    let plan = parse_plan(plan_text)?;
    let reference = parse_template_ref(&plan.template);
    let template = builtin_template(&plan.template)?;
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
        template_hash: template_hash(&plan.template)?,
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
        exercise_options: plan.exercise_options,
        rest: plan.rest,
        warmup: plan.warmup,
        equipment: plan.equipment,
        template,
        lock,
        patches,
    })
}

pub fn validate_compiled(compiled: &CompiledPlan) -> ValidationReport {
    let mut errors = Vec::new();
    let mut warnings = Vec::new();

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

    match compiled.template.kind {
        TemplateKind::Gzclp => {
            for lift in MAIN_LIFTS {
                if !compiled.starts.contains_key(lift) {
                    errors.push(message(
                        "missing_start",
                        format!("GZCLP requires a starting load for {lift}"),
                    ));
                }
            }
        }
        TemplateKind::FiveThreeOne => {
            for lift in MAIN_LIFTS {
                if !compiled.training_maxes.contains_key(lift) {
                    errors.push(message(
                        "missing_training_max",
                        format!("5/3/1 requires a training max for {lift}"),
                    ));
                }
            }
        }
        TemplateKind::StartingStrength => {
            for lift in required_starting_strength_starts(compiled) {
                if !compiled.starts.contains_key(&lift) {
                    errors.push(message(
                        "missing_start",
                        format!("Starting Strength requires a starting load for {lift}"),
                    ));
                }
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
    match compiled.template.kind {
        TemplateKind::Gzclp => create_initial_gzclp_state(compiled),
        TemplateKind::FiveThreeOne => create_initial_531_state(compiled),
        TemplateKind::StartingStrength => create_initial_starting_strength_state(compiled),
    }
}

pub fn render_next(compiled: &CompiledPlan, state: &StateProjection) -> Result<RenderedSession> {
    match compiled.template.kind {
        TemplateKind::Gzclp => render_gzclp_next(compiled, state),
        TemplateKind::FiveThreeOne => render_531_next(compiled, state),
        TemplateKind::StartingStrength => render_starting_strength_next(compiled, state),
    }
}

/// Renders a specific session by id against the current state, independent of where the cursor
/// currently points. A partial save advances the cursor to the next workout, so the snapshot a
/// saved partial was logged against is no longer the "next" one — this lets the app re-render it
/// to be resumed from history (§16/§19).
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
            event: None,
            effects: Vec::new(),
            new_state: state.clone(),
            next_workout: rendered_session.clone(),
        });
    }

    let mut new_state = state.clone();
    let mut results = Vec::new();
    let mut effects = Vec::new();

    for item in &rendered_session.items {
        if let Some(item_input) = input
            .inputs
            .iter()
            .find(|candidate| candidate.item_id == item.item_id)
        {
            let result = reduce_item(item, item_input, compiled)?;
            effects.extend(result.effects.clone());
            results.push(result);
        }
    }

    apply_effects(&mut new_state, &effects);
    // Advance to the next workout whenever the cursor is still sitting on the session being
    // submitted — for a complete *or* a partial save (§16). Guarding on the cursor keeps this
    // idempotent: continuing a saved partial (whose save already advanced the cursor) does not
    // advance a second time.
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

    let event_type = if input.status == "complete" {
        "session_completed"
    } else {
        "session_saved"
    };
    let timestamp = input
        .completed_at
        .as_deref()
        .or(input.saved_at.as_deref())
        .or(input.started_at.as_deref())
        .unwrap_or("unknown-time");
    let event_id = make_event_id(event_type, &rendered_session.session_id, timestamp);

    let event = TrainingEvent {
        id: event_id.clone(),
        kind: event_type.into(),
        schema_version: Some(SCHEMA_VERSION.into()),
        program: Some(match compiled.template.kind {
            TemplateKind::Gzclp => "gzcl".into(),
            TemplateKind::FiveThreeOne => "531".into(),
            TemplateKind::StartingStrength => "starting_strength".into(),
        }),
        session_id: Some(rendered_session.session_id.clone()),
        plan_hash: Some(compiled.plan_hash.clone()),
        template_hash: Some(compiled.template_hash.clone()),
        rendered_session_hash: Some(rendered_session.rendered_session_hash.clone()),
        engine_version: Some(ENGINE_VERSION.into()),
        started_at: input.started_at.clone(),
        completed_at: input.completed_at.clone(),
        saved_at: input.saved_at.clone(),
        status: Some(input.status.clone()),
        results,
        results_added: Vec::new(),
        effects: effects.clone(),
        continues_event_id: None,
        corrects_event_id: None,
        reason: None,
        policy: None,
        lane: None,
        change: None,
        cursor: None,
        changes: Vec::new(),
        change_kind: None,
        from_plan: None,
        to_plan: None,
    };

    new_state.last_event_id = Some(event_id.clone());
    new_state.sessions.insert(
        format!("{}_{}", rendered_session.session_id, event_id),
        SessionState {
            status: input.status.clone(),
            source_events: vec![event_id],
        },
    );

    let next_workout = render_next(compiled, &new_state)?;
    Ok(ReductionResult {
        validation,
        event: Some(event),
        effects,
        new_state,
        next_workout,
    })
}

pub fn replay_events(compiled: &CompiledPlan, events: &[TrainingEvent]) -> StateProjection {
    let events = fold_corrections(compiled, events);
    let mut state = create_initial_state(compiled);

    for event in &events {
        match event.kind.as_str() {
            "session_completed" => {
                apply_effects(&mut state, &event.effects);
                if let Some(session_id) = &event.session_id {
                    advance_cursor(&mut state, &compiled.schedule.rotation, session_id);
                    state.sessions.insert(
                        format!("{}_{}", session_id, event.id),
                        SessionState {
                            status: "complete".into(),
                            source_events: vec![event.id.clone()],
                        },
                    );
                }
                state.last_event_id = Some(event.id.clone());
            }
            "session_saved" => {
                if let Some(session_id) = &event.session_id {
                    // A partial save moves the program on to the next workout; the saved snapshot
                    // stays resumable from history (§16/§19). Guard on the cursor so repeated saves
                    // of the same session don't advance more than once.
                    if state.cursor.next_session.eq_ignore_ascii_case(session_id) {
                        advance_cursor(&mut state, &compiled.schedule.rotation, session_id);
                    }
                    state.sessions.insert(
                        format!("{}_{}", session_id, event.id),
                        SessionState {
                            status: "partial".into(),
                            source_events: vec![event.id.clone()],
                        },
                    );
                }
                state.last_event_id = Some(event.id.clone());
            }
            "session_continued" => {
                apply_effects(&mut state, &event.effects);
                if let Some(session_id) = &event.session_id {
                    // The partial this continues already advanced the cursor; only advance here if
                    // the cursor is somehow still on this session (e.g. a continue with no prior
                    // save in the log).
                    if state.cursor.next_session.eq_ignore_ascii_case(session_id) {
                        advance_cursor(&mut state, &compiled.schedule.rotation, session_id);
                    }
                    state.sessions.insert(
                        format!("{}_{}", session_id, event.id),
                        SessionState {
                            status: "complete".into(),
                            source_events: vec![
                                event.continues_event_id.clone().unwrap_or_default(),
                                event.id.clone(),
                            ],
                        },
                    );
                }
                state.last_event_id = Some(event.id.clone());
            }
            "session_skipped" => {
                if let Some(session_id) = &event.session_id {
                    advance_cursor(&mut state, &compiled.schedule.rotation, session_id);
                }
                state.last_event_id = Some(event.id.clone());
            }
            "state_adjusted" => {
                apply_state_adjustment(&mut state, event);
                state.last_event_id = Some(event.id.clone());
            }
            "session_corrected" => {
                state.last_event_id = Some(event.id.clone());
            }
            "plan_changed" => {
                state.last_event_id = Some(event.id.clone());
            }
            _ => {}
        }
    }

    state
}

fn fold_corrections(compiled: &CompiledPlan, events: &[TrainingEvent]) -> Vec<TrainingEvent> {
    let mut folded = Vec::<TrainingEvent>::new();
    for event in events {
        if event.kind == "session_corrected" {
            if let Some(target_id) = &event.corrects_event_id
                && let Some(target) = folded
                    .iter_mut()
                    .find(|candidate| &candidate.id == target_id)
            {
                apply_correction_changes(compiled, target, &event.changes);
            }
            folded.push(event.clone());
        } else {
            folded.push(event.clone());
        }
    }
    folded
}

fn apply_correction_changes(
    compiled: &CompiledPlan,
    target: &mut TrainingEvent,
    changes: &[CorrectionChange],
) {
    let path_re = Regex::new(r"^results\[([^\]]+)\]\.actual\[(\d+)\]\.reps$").unwrap();
    for change in changes {
        let Some(capture) = path_re.captures(&change.path) else {
            continue;
        };
        let slot_id = &capture[1];
        let Some(set_index) = capture[2].parse::<usize>().ok() else {
            continue;
        };
        let Some(reps) = change
            .after
            .as_u64()
            .and_then(|value| u32::try_from(value).ok())
        else {
            continue;
        };
        let Some(result) = target
            .results
            .iter_mut()
            .chain(target.results_added.iter_mut())
            .find(|result| result.slot_id == slot_id)
        else {
            continue;
        };
        if let Some(actual) = result.actual.get_mut(set_index) {
            actual.reps = reps;
            recompute_result(compiled, result);
        }
    }
    target.effects = target
        .results
        .iter()
        .chain(target.results_added.iter())
        .flat_map(|result| result.effects.clone())
        .collect();
}

fn recompute_result(compiled: &CompiledPlan, result: &mut ExerciseResult) {
    let prescribed_sets = prescribed_sets_from_log(&result.prescribed);
    let adjusted_today = result.actual.iter().any(|actual| {
        prescribed_sets
            .first()
            .and_then(|set| set.load.as_ref())
            .zip(actual.load.as_ref())
            .is_some_and(|(prescribed, actual)| prescribed != actual)
    });

    result.outcome = if adjusted_today {
        "adjusted_today".into()
    } else if result
        .progression_rule
        .as_deref()
        .is_some_and(|rule| rule.ends_with(".t3"))
    {
        let final_reps = result.actual.last().map(|set| set.reps).unwrap_or_default();
        if final_reps >= compiled.template.lanes.t3_pass_final_set_reps {
            "pass".into()
        } else {
            "fail".into()
        }
    } else if prescribed_sets
        .iter()
        .zip(&result.actual)
        .all(|(target, actual)| actual.reps >= target.target_reps)
    {
        "pass".into()
    } else {
        "fail".into()
    };

    result.effects = recompute_result_effects(compiled, result, &prescribed_sets);
}

fn recompute_result_effects(
    compiled: &CompiledPlan,
    result: &ExerciseResult,
    prescribed_sets: &[PrescribedSet],
) -> Vec<Effect> {
    if result.outcome == "adjusted_today" {
        return Vec::new();
    }

    let Some(lane) = result.progression_lane.as_deref() else {
        return Vec::new();
    };
    let rule = result.progression_rule.as_deref().unwrap_or_default();
    let load = prescribed_sets.first().and_then(|set| set.load.as_deref());

    match (rule, result.outcome.as_str()) {
        (rule, "pass") if rule.ends_with(".t1") || rule.ends_with(".t2") => {
            vec![increase_load_effect(
                compiled,
                lane,
                load,
                compiled.template.increments.default,
            )]
        }
        (rule, "pass") if rule.ends_with(".t3") => {
            let basis = load.or_else(|| {
                result
                    .actual
                    .iter()
                    .rev()
                    .find_map(|set| set.load.as_deref())
            });
            basis
                .map(|load| {
                    increase_load_effect(
                        compiled,
                        lane,
                        Some(load),
                        compiled.template.increments.default,
                    )
                })
                .into_iter()
                .collect()
        }
        (rule, "fail") if rule.ends_with(".t3") && load.is_none() => result
            .actual
            .iter()
            .rev()
            .find_map(|set| set.load.as_deref())
            .map(|load| vec![set_load_effect(lane, None, load)])
            .unwrap_or_default(),
        (rule, "fail") if rule.ends_with(".t1") => {
            let from = stage_from_prescribed_t1(prescribed_sets);
            vec![advance_stage_effect(
                lane,
                Some(&from),
                next_stage(&compiled.template.lanes.t1_stages, &from).as_deref(),
            )]
        }
        (rule, "fail") if rule.ends_with(".t2") => {
            let from = stage_from_prescribed_t2(prescribed_sets);
            vec![advance_stage_effect(
                lane,
                Some(&from),
                next_stage(&compiled.template.lanes.t2_stages, &from).as_deref(),
            )]
        }
        (rule, "pass") if rule.ends_with(".main") => {
            let from = result
                .effects
                .iter()
                .find(|effect| effect.op == "advance_531_week")
                .and_then(|effect| effect.from.clone())
                .unwrap_or_else(|| "1".into());
            let to = if from == "4" {
                "1".into()
            } else {
                from.parse::<u32>()
                    .map(|week| (week + 1).to_string())
                    .unwrap_or_else(|_| "2".into())
            };
            vec![Effect {
                op: "advance_531_week".into(),
                lane: lane.into(),
                from: Some(from),
                to: Some(to),
            }]
        }
        (rule, "pass")
            if rule.starts_with("starting_strength.") && rule != "starting_strength.chins" =>
        {
            vec![increase_load_effect(
                compiled,
                lane,
                load,
                starting_strength_increment(compiled, lane),
            )]
        }
        _ => Vec::new(),
    }
}

fn stage_from_prescribed_t1(sets: &[PrescribedSet]) -> String {
    match (sets.len(), sets.first().map(|set| set.target_reps)) {
        (6, Some(2)) => "6x2+".into(),
        (10, Some(1)) => "10x1+".into(),
        _ => "5x3+".into(),
    }
}

fn stage_from_prescribed_t2(sets: &[PrescribedSet]) -> String {
    let reps = sets.first().map(|set| set.target_reps).unwrap_or(10);
    format!("3x{reps}")
}

pub fn build_outputs(compiled: &CompiledPlan, events: &[TrainingEvent]) -> Result<BuildOutputs> {
    let state = replay_events(compiled, events);
    let validation = validate_compiled(compiled);
    let next_workout = if validation.status == ValidationStatus::Valid {
        Some(render_next(compiled, &state)?)
    } else {
        None
    };
    let resumable_sessions = if validation.status == ValidationStatus::Valid {
        resumable_sessions(compiled, &state, events)
    } else {
        Vec::new()
    };
    let mut ir = serde_json::to_value(compiled)?;
    if let Some(object) = ir.as_object_mut() {
        object.remove("lock");
    }
    Ok(BuildOutputs {
        state,
        ir,
        next_workout,
        resumable_sessions,
        validation,
    })
}

/// Re-renders each saved partial that has not yet been continued, so the app can resume it from
/// history after the cursor has moved on (§16/§19). One entry per session id (most recent save
/// wins); a render is only included when it still matches the snapshot the partial was logged
/// against, otherwise the plan has changed underneath it and it falls back to correction.
fn resumable_sessions(
    compiled: &CompiledPlan,
    state: &StateProjection,
    events: &[TrainingEvent],
) -> Vec<RenderedSession> {
    let continued: Vec<&str> = events
        .iter()
        .filter_map(|event| event.continues_event_id.as_deref())
        .collect();

    let mut sessions = Vec::new();
    let mut seen = Vec::new();
    for event in events.iter().rev() {
        if event.kind != "session_saved" || continued.contains(&event.id.as_str()) {
            continue;
        }
        let Some(session_id) = &event.session_id else {
            continue;
        };
        if seen.iter().any(|id: &String| id == session_id) {
            continue;
        }
        seen.push(session_id.clone());
        if let Ok(rendered) = render_session(compiled, state, session_id)
            && event
                .rendered_session_hash
                .as_deref()
                .is_none_or(|hash| hash == rendered.rendered_session_hash)
        {
            sessions.push(rendered);
        }
    }
    sessions
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
            event_id: reduced.event.map(|event| event.id).unwrap_or_default(),
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

fn create_initial_gzclp_state(compiled: &CompiledPlan) -> StateProjection {
    let mut lanes = Map::new();
    for lift in MAIN_LIFTS {
        let Some(start) = compiled.starts.get(lift) else {
            continue;
        };
        lanes.insert(
            format!("{lift}.t1"),
            LaneState {
                load: Some(start.clone()),
                stage: Some("5x3+".into()),
                ..LaneState::default()
            },
        );
        lanes.insert(
            format!("{lift}.t2"),
            LaneState {
                load: Some(scale_load(compiled, lift, start, 0.8)),
                stage: Some("3x10".into()),
                ..LaneState::default()
            },
        );
    }

    for exercise in compiled.accessories.values() {
        lanes.insert(
            format!("{exercise}.t3"),
            LaneState {
                load: compiled.starts.get(exercise).cloned(),
                stage: Some("3x15+".into()),
                ..LaneState::default()
            },
        );
    }

    base_state(compiled, lanes)
}

fn create_initial_531_state(compiled: &CompiledPlan) -> StateProjection {
    let mut lanes = Map::new();
    for lift in MAIN_LIFTS {
        if let Some(training_max) = compiled.training_maxes.get(lift) {
            lanes.insert(
                format!("{lift}.main"),
                LaneState {
                    training_max: Some(training_max.clone()),
                    week: Some(1),
                    cycle: Some(1),
                    ..LaneState::default()
                },
            );
        }
    }
    base_state(compiled, lanes)
}

fn create_initial_starting_strength_state(compiled: &CompiledPlan) -> StateProjection {
    let mut lanes = Map::new();
    for lift in required_starting_strength_starts(compiled) {
        if let Some(start) = compiled.starts.get(&lift) {
            lanes.insert(
                starting_strength_lane(&lift),
                LaneState {
                    load: Some(start.clone()),
                    stage: Some(starting_strength_stage(compiled, &lift)),
                    ..LaneState::default()
                },
            );
        }
    }
    lanes.insert(
        "chin_up.bodyweight".into(),
        LaneState {
            stage: Some("3 sets to fatigue".into()),
            ..LaneState::default()
        },
    );
    base_state(compiled, lanes)
}

fn required_starting_strength_starts(compiled: &CompiledPlan) -> Vec<String> {
    compiled
        .template
        .sessions
        .values()
        .flatten()
        .filter(|slot| slot.tier != "chins")
        .filter_map(|slot| slot.exercise.clone())
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn starting_strength_lane(exercise: &str) -> String {
    format!("{}.linear", normalize_exercise(exercise))
}

fn starting_strength_stage(compiled: &CompiledPlan, exercise: &str) -> String {
    compiled
        .template
        .sessions
        .values()
        .flatten()
        .find(|slot| slot.exercise.as_deref() == Some(exercise) && slot.tier != "chins")
        .map(|slot| slot.tier.clone())
        .unwrap_or_else(|| "3x5".into())
}

fn starting_strength_sets(load: Option<String>, tier: &str) -> Vec<PrescribedSet> {
    let (set_count, target_reps) = match tier {
        "1x5" => (1, 5),
        "5x3" => (5, 3),
        _ => (3, 5),
    };

    (1..=set_count)
        .map(|set| PrescribedSet {
            set,
            load: load.clone(),
            target_reps,
            amrap: false,
            percentage: None,
        })
        .collect()
}

fn starting_strength_increment(compiled: &CompiledPlan, lane: &str) -> f64 {
    if lane.starts_with("squat.") || lane.starts_with("deadlift.") {
        compiled.template.increments.lower
    } else {
        compiled.template.increments.upper
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
    slot: &TemplateSlot,
    spec: &RenderedItemSpec<'_>,
) -> Vec<PrescribedSet> {
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
            });
            index += 1;
        }
    }

    for step in &scheme.ramp {
        let value = snap_load(
            compiled,
            &spec.exercise,
            parsed.value * (step.percentage as f64) / 100.0,
        );
        sets.push(PrescribedSet {
            set: index,
            load: Some(format_load(value, parsed.unit)),
            target_reps: step.reps,
            amrap: false,
            percentage: Some(step.percentage),
        });
        index += 1;
    }

    sets
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
    match compiled.equipment.as_ref() {
        Some(equipment) => match implement_for(equipment, exercise) {
            Implement::Barbell => Some(bar_weight(equipment, &compiled.plan.units, exercise)),
            Implement::Dumbbell => None,
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
    slot: &TemplateSlot,
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
    .or_else(|| {
        pick_warmup(
            &template_warmup_defaults(&compiled.template.kind),
            &slot_key,
            &lane_key,
            &exercise_key,
            &tier_key,
        )
    })
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

/// Sensible per-program warmup defaults. These are engine behaviour (pinned by
/// `ENGINE_VERSION`, like every other rendering rule) rather than part of the
/// hashed template, so adding them does not perturb existing template hashes or
/// lockfiles. A plan's own `warmup { … }` block overrides them.
fn template_warmup_defaults(kind: &TemplateKind) -> WarmupPolicy {
    match kind {
        // GZCLP / Starting Strength: Bay-Strength novice ramp — two empty-bar
        // sets, then 45/65/85% of the work weight for 5/3/2.
        TemplateKind::Gzclp | TemplateKind::StartingStrength => WarmupPolicy {
            default: Some(WarmupScheme {
                empty_bar_sets: 2,
                empty_bar_reps: 5,
                ramp: vec![
                    WarmupStep {
                        percentage: 45,
                        reps: 5,
                    },
                    WarmupStep {
                        percentage: 65,
                        reps: 3,
                    },
                    WarmupStep {
                        percentage: 85,
                        reps: 2,
                    },
                ],
                basis: WarmupBasis::TopSet,
            }),
            ..WarmupPolicy::default()
        },
        // 5/3/1: canonical warmup is 40/50/60% of the training max.
        TemplateKind::FiveThreeOne => WarmupPolicy {
            default: Some(WarmupScheme {
                empty_bar_sets: 0,
                empty_bar_reps: 0,
                ramp: vec![
                    WarmupStep {
                        percentage: 40,
                        reps: 5,
                    },
                    WarmupStep {
                        percentage: 50,
                        reps: 5,
                    },
                    WarmupStep {
                        percentage: 60,
                        reps: 3,
                    },
                ],
                basis: WarmupBasis::TrainingMax,
            }),
            ..WarmupPolicy::default()
        },
    }
}

fn starting_strength_display_name(compiled: &CompiledPlan, session_id: &str) -> String {
    let phase = compiled
        .plan
        .template_id
        .strip_prefix("starting-strength.")
        .unwrap_or("phase");
    let day = match session_id {
        "a" => "Day A",
        "b" => "Day B",
        "a_deadlift" => "Day A - Deadlift",
        "a_clean" => "Day A - Power Clean",
        "b_chins_1" | "b_chins_2" => "Day B - Chin-ups",
        other => other,
    };
    format!("Starting Strength {} - {day}", title_case(phase))
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
    }
}

fn render_gzclp_next(compiled: &CompiledPlan, state: &StateProjection) -> Result<RenderedSession> {
    let session_id = state.cursor.next_session.to_ascii_lowercase();
    let slots = compiled
        .template
        .sessions
        .get(&session_id)
        .or_else(|| compiled.template.sessions.get("a1"))
        .ok_or_else(|| KnurledError::UnknownTemplate(compiled.plan.template.clone()))?;
    let items = slots
        .iter()
        .map(|slot| render_gzclp_item(compiled, state, slot))
        .collect::<Result<Vec<_>>>()?;
    attach_rendered_session_hash(
        compiled,
        RenderedSession {
            kind: "rendered_session".into(),
            schema_version: SCHEMA_VERSION.into(),
            engine_version: ENGINE_VERSION.into(),
            session_id: session_id.clone(),
            display_name: format!(
                "{} - {}",
                template_display_name(&compiled.plan.template_id),
                session_id.to_ascii_uppercase()
            ),
            suggested_date: None,
            plan_hash: compiled.plan_hash.clone(),
            template_hash: compiled.template_hash.clone(),
            rendered_session_hash: String::new(),
            items,
        },
    )
}

fn render_gzclp_item(
    compiled: &CompiledPlan,
    state: &StateProjection,
    slot: &TemplateSlot,
) -> Result<RenderedItem> {
    let exercise = if slot.tier == "t3" {
        slot.accessory_key
            .as_ref()
            .and_then(|key| compiled.accessories.get(key))
            .cloned()
            .or_else(|| slot.default_exercise.clone())
            .unwrap_or_else(|| "accessory".into())
    } else {
        slot.exercise.clone().unwrap_or_else(|| "exercise".into())
    };
    let lane = format!("{exercise}.{}", slot.tier);
    let lane_state = state.lanes.get(&lane).cloned().unwrap_or_default();
    let exercise = apply_exercise_patches(compiled, &exercise, &lane)?;

    match slot.tier.as_str() {
        "t1" => {
            let load = lane_state.load.clone();
            let stage = lane_state.stage.clone().unwrap_or_else(|| "5x3+".into());
            let sets = sets_for_t1(load.clone(), &stage);
            rendered_item(
                compiled,
                slot,
                RenderedItemSpec {
                    exercise,
                    training_max: None,
                    lane: lane.clone(),
                    stage: Some(stage.clone()),
                    sets,
                    recommended_input: "amrap_final_set",
                    effect_preview: EffectPreview {
                        pass: vec![increase_load_effect(
                            compiled,
                            &lane,
                            load.as_deref(),
                            compiled.template.increments.default,
                        )],
                        fail: vec![advance_stage_effect(
                            &lane,
                            Some(&stage),
                            next_stage(&compiled.template.lanes.t1_stages, &stage).as_deref(),
                        )],
                        adjusted_today: Vec::new(),
                    },
                },
            )
        }
        "t2" => {
            let load = lane_state.load.clone();
            let stage = lane_state.stage.clone().unwrap_or_else(|| "3x10".into());
            let sets = sets_for_straight_stage(load.clone(), &stage);
            rendered_item(
                compiled,
                slot,
                RenderedItemSpec {
                    exercise,
                    training_max: None,
                    lane: lane.clone(),
                    stage: Some(stage.clone()),
                    sets,
                    recommended_input: "per_set_reps",
                    effect_preview: EffectPreview {
                        pass: vec![increase_load_effect(
                            compiled,
                            &lane,
                            load.as_deref(),
                            compiled.template.increments.default,
                        )],
                        fail: vec![advance_stage_effect(
                            &lane,
                            Some(&stage),
                            next_stage(&compiled.template.lanes.t2_stages, &stage).as_deref(),
                        )],
                        adjusted_today: Vec::new(),
                    },
                },
            )
        }
        _ => {
            let load = lane_state.load.clone();
            let target = compiled.template.lanes.t3_target_reps;
            let sets = (1..=3)
                .map(|set| PrescribedSet {
                    set,
                    load: load.clone(),
                    target_reps: target,
                    amrap: set == 3,
                    percentage: None,
                })
                .collect();
            rendered_item(
                compiled,
                slot,
                RenderedItemSpec {
                    exercise,
                    training_max: None,
                    lane: lane.clone(),
                    stage: Some("3x15+".into()),
                    sets,
                    recommended_input: "amrap_final_set",
                    effect_preview: EffectPreview {
                        pass: load
                            .as_deref()
                            .map(|load| {
                                increase_load_effect(
                                    compiled,
                                    &lane,
                                    Some(load),
                                    compiled.template.increments.default,
                                )
                            })
                            .into_iter()
                            .collect(),
                        fail: Vec::new(),
                        adjusted_today: Vec::new(),
                    },
                },
            )
        }
    }
}

fn render_531_next(compiled: &CompiledPlan, state: &StateProjection) -> Result<RenderedSession> {
    let session_id = state.cursor.next_session.to_ascii_lowercase();
    let slot = compiled
        .template
        .sessions
        .get(&session_id)
        .and_then(|items| items.first())
        .or_else(|| {
            compiled
                .template
                .sessions
                .get("squat_day")
                .and_then(|items| items.first())
        })
        .ok_or_else(|| KnurledError::UnknownTemplate(compiled.plan.template.clone()))?;
    let exercise = slot.exercise.clone().unwrap_or_else(|| "squat".into());
    let lane = format!("{exercise}.main");
    let lane_state = state.lanes.get(&lane).cloned().unwrap_or_default();
    let week_number = lane_state.week.unwrap_or(state.cursor.week).clamp(1, 4);
    let week = compiled
        .template
        .weeks
        .iter()
        .find(|week| week.week == week_number)
        .unwrap_or(&compiled.template.weeks[0]);
    let training_max = lane_state.training_max.as_deref().unwrap_or("0kg");
    let parsed = parse_load(training_max);
    let sets = week
        .percentages
        .iter()
        .zip(&week.reps)
        .enumerate()
        .map(|(index, (percentage, reps))| PrescribedSet {
            set: index as u32 + 1,
            load: Some(format_load(
                snap_load(
                    compiled,
                    &exercise,
                    parsed.value * (*percentage as f64) / 100.0,
                ),
                parsed.unit,
            )),
            target_reps: reps.trim_end_matches('+').parse().unwrap_or(1),
            amrap: reps.ends_with('+'),
            percentage: Some(*percentage),
        })
        .collect();
    let item = rendered_item(
        compiled,
        slot,
        RenderedItemSpec {
            exercise: exercise.clone(),
            lane: lane.clone(),
            stage: None,
            sets,
            training_max: lane_state.training_max.clone(),
            recommended_input: "amrap_final_set",
            effect_preview: EffectPreview {
                pass: vec![Effect {
                    op: "advance_531_week".into(),
                    lane,
                    from: Some(week_number.to_string()),
                    to: Some(if week_number == 4 {
                        "1".into()
                    } else {
                        (week_number + 1).to_string()
                    }),
                }],
                fail: Vec::new(),
                adjusted_today: Vec::new(),
            },
        },
    )?;

    attach_rendered_session_hash(
        compiled,
        RenderedSession {
            kind: "rendered_session".into(),
            schema_version: SCHEMA_VERSION.into(),
            engine_version: ENGINE_VERSION.into(),
            session_id,
            display_name: format!("5/3/1 - {}", title_case(&exercise)),
            suggested_date: None,
            plan_hash: compiled.plan_hash.clone(),
            template_hash: compiled.template_hash.clone(),
            rendered_session_hash: String::new(),
            items: vec![item],
        },
    )
}

fn render_starting_strength_next(
    compiled: &CompiledPlan,
    state: &StateProjection,
) -> Result<RenderedSession> {
    let session_id = state.cursor.next_session.to_ascii_lowercase();
    let slots = compiled
        .template
        .sessions
        .get(&session_id)
        .or_else(|| compiled.template.sessions.get("a"))
        .ok_or_else(|| KnurledError::UnknownTemplate(compiled.plan.template.clone()))?;
    let items = slots
        .iter()
        .map(|slot| render_starting_strength_item(compiled, state, slot))
        .collect::<Result<Vec<_>>>()?;

    attach_rendered_session_hash(
        compiled,
        RenderedSession {
            kind: "rendered_session".into(),
            schema_version: SCHEMA_VERSION.into(),
            engine_version: ENGINE_VERSION.into(),
            session_id: session_id.clone(),
            display_name: starting_strength_display_name(compiled, &session_id),
            suggested_date: None,
            plan_hash: compiled.plan_hash.clone(),
            template_hash: compiled.template_hash.clone(),
            rendered_session_hash: String::new(),
            items,
        },
    )
}

fn render_starting_strength_item(
    compiled: &CompiledPlan,
    state: &StateProjection,
    slot: &TemplateSlot,
) -> Result<RenderedItem> {
    let exercise = slot.exercise.clone().unwrap_or_else(|| "exercise".into());
    let lane = if slot.tier == "chins" {
        "chin_up.bodyweight".to_owned()
    } else {
        starting_strength_lane(&exercise)
    };
    let lane_state = state.lanes.get(&lane).cloned().unwrap_or_default();
    let exercise = apply_exercise_patches(compiled, &exercise, &lane)?;

    let (sets, stage, effect_preview) = if slot.tier == "chins" {
        (
            (1..=3)
                .map(|set| PrescribedSet {
                    set,
                    load: None,
                    target_reps: 0,
                    amrap: true,
                    percentage: None,
                })
                .collect(),
            Some("3 sets to fatigue".to_owned()),
            EffectPreview {
                pass: Vec::new(),
                fail: Vec::new(),
                adjusted_today: Vec::new(),
            },
        )
    } else {
        let load = lane_state.load.clone();
        (
            starting_strength_sets(load.clone(), &slot.tier),
            Some(slot.tier.clone()),
            EffectPreview {
                pass: vec![increase_load_effect(
                    compiled,
                    &lane,
                    load.as_deref(),
                    starting_strength_increment(compiled, &lane),
                )],
                fail: Vec::new(),
                adjusted_today: Vec::new(),
            },
        )
    };

    rendered_item(
        compiled,
        slot,
        RenderedItemSpec {
            exercise,
            lane,
            stage,
            sets,
            recommended_input: "per_set_reps",
            effect_preview,
            training_max: None,
        },
    )
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

fn rendered_item(
    compiled: &CompiledPlan,
    slot: &TemplateSlot,
    spec: RenderedItemSpec<'_>,
) -> Result<RenderedItem> {
    let exercise_options = compiled
        .exercise_options
        .get(&slot.slot_id.to_ascii_lowercase())
        .map(|options| RenderedExerciseOptions {
            primary: options.primary.clone(),
            allow_runtime_swap: true,
            default_policy: SwapPolicy::TrackingOnly,
            alternatives: options.alternatives.clone(),
        });
    Ok(RenderedItem {
        item_id: slot.slot_id.clone(),
        slot_id: slot.slot_id.clone(),
        progression_lane: spec.lane.clone(),
        progression_rule: format!(
            "{}.{}",
            match compiled.template.kind {
                TemplateKind::Gzclp => "gzcl",
                TemplateKind::FiveThreeOne => "531",
                TemplateKind::StartingStrength => "starting_strength",
            },
            slot.tier
        ),
        exercise: spec.exercise.clone(),
        display: DisplayFields {
            title: format!(
                "{} {}",
                title_case(&spec.exercise),
                slot.tier.to_ascii_uppercase()
            ),
            subtitle: subtitle_for(&spec.sets, spec.stage.as_deref()),
        },
        prescription: Prescription {
            warmups: compute_warmups(compiled, slot, &spec),
            sets: spec.sets.clone(),
        },
        execution_contract: execution_contract(spec.recommended_input, &spec.sets),
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
    })
}

fn resolve_rest(
    compiled: &CompiledPlan,
    slot: &TemplateSlot,
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

fn reduce_item(
    item: &RenderedItem,
    input: &ItemInput,
    compiled: &CompiledPlan,
) -> Result<ExerciseResult> {
    let actual = actual_sets_for(item, input)?;
    let adjusted_today = actual.iter().any(|set| {
        let prescribed = item
            .prescription
            .sets
            .first()
            .and_then(|set| set.load.as_ref());
        set.load
            .as_ref()
            .zip(prescribed)
            .is_some_and(|(actual, prescribed)| actual != prescribed)
    });
    let outcome = if adjusted_today {
        "adjusted_today".to_owned()
    } else {
        outcome_for(item, &actual, compiled)
    };
    let effects = effects_for_outcome(compiled, item, &outcome, &actual);

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

fn prescribed_sets_from_log(value: &serde_json::Value) -> Vec<PrescribedSet> {
    if let Some(sets) = value
        .get("sets")
        .cloned()
        .and_then(|value| serde_json::from_value::<Vec<PrescribedSet>>(value).ok())
    {
        return sets;
    }

    let load = value
        .get("load")
        .and_then(|value| value.as_str())
        .map(str::to_owned);
    value
        .get("reps")
        .and_then(|value| value.as_array())
        .into_iter()
        .flatten()
        .enumerate()
        .filter_map(|(index, reps)| {
            let (target_reps, amrap) = if let Some(number) = reps.as_u64() {
                (u32::try_from(number).ok()?, false)
            } else {
                let text = reps.as_str()?;
                let target = text.strip_suffix('+').unwrap_or(text);
                (target.parse::<u32>().ok()?, text.ends_with('+'))
            };
            Some(PrescribedSet {
                set: u32::try_from(index + 1).ok()?,
                load: load.clone(),
                target_reps,
                amrap,
                percentage: None,
            })
        })
        .collect()
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
                    load: input.load.clone().or_else(|| set.load.clone()),
                    reps: if index == item.prescription.sets.len() - 1 {
                        final_reps
                    } else {
                        set.target_reps
                    },
                    metrics: Default::default(),
                })
                .collect())
        }
        "per_set_reps" => Ok(input.sets.clone()),
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

fn outcome_for(item: &RenderedItem, actual: &[ActualSet], compiled: &CompiledPlan) -> String {
    if item.progression_rule.ends_with(".t3") {
        let final_reps = actual.last().map(|set| set.reps).unwrap_or_default();
        return if final_reps >= compiled.template.lanes.t3_pass_final_set_reps {
            "pass"
        } else {
            "fail"
        }
        .into();
    }

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
) -> Vec<Effect> {
    if item.progression_rule.ends_with(".t3")
        && item
            .prescription
            .sets
            .first()
            .and_then(|set| set.load.as_ref())
            .is_none()
    {
        return initial_t3_load_effect(compiled, item, outcome, actual);
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

fn initial_t3_load_effect(
    compiled: &CompiledPlan,
    item: &RenderedItem,
    outcome: &str,
    actual: &[ActualSet],
) -> Vec<Effect> {
    let Some(actual_load) = actual.iter().rev().find_map(|set| set.load.as_deref()) else {
        return Vec::new();
    };
    match outcome {
        "pass" => vec![increase_load_effect(
            compiled,
            &item.progression_lane,
            Some(actual_load),
            compiled.template.increments.default,
        )],
        "fail" => vec![set_load_effect(&item.progression_lane, None, actual_load)],
        _ => Vec::new(),
    }
}

fn apply_effects(state: &mut StateProjection, effects: &[Effect]) {
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
                }
            }
            "advance_531_week" => {
                if let Some(lane) = state.lanes.get_mut(&effect.lane) {
                    lane.week = effect.to.as_deref().and_then(|to| to.parse().ok());
                }
            }
            _ => {}
        }
    }
}

fn apply_state_adjustment(state: &mut StateProjection, event: &TrainingEvent) {
    if let (Some(lane_id), Some(change)) = (&event.lane, &event.change)
        && let Some(lane) = state.lanes.get_mut(lane_id)
    {
        if let Some(load) = &change.load {
            lane.load = Some(load.to.clone());
        }
        if let Some(stage) = &change.stage {
            lane.stage = Some(stage.to.clone());
        }
    }
    if let Some(cursor) = &event.cursor
        && let Some(next_session) = &cursor.next_session
    {
        state.cursor.next_session = next_session.to_ascii_lowercase();
    }
}

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

fn sets_for_t1(load: Option<String>, stage: &str) -> Vec<PrescribedSet> {
    let (count, reps) = match stage {
        "6x2+" => (6, 2),
        "10x1+" => (10, 1),
        _ => (5, 3),
    };
    (1..=count)
        .map(|set| PrescribedSet {
            set,
            load: load.clone(),
            target_reps: reps,
            amrap: set == count,
            percentage: None,
        })
        .collect()
}

fn sets_for_straight_stage(load: Option<String>, stage: &str) -> Vec<PrescribedSet> {
    let reps = stage
        .split_once('x')
        .and_then(|(_, reps)| reps.parse().ok())
        .unwrap_or(10);
    (1..=3)
        .map(|set| PrescribedSet {
            set,
            load: load.clone(),
            target_reps: reps,
            amrap: false,
            percentage: None,
        })
        .collect()
}

fn increase_load_effect(
    compiled: &CompiledPlan,
    lane: &str,
    from: Option<&str>,
    increment: f64,
) -> Effect {
    Effect {
        op: "increase_load".into(),
        lane: lane.into(),
        from: from.map(str::to_owned),
        to: from.map(|from| add_load(compiled, lane_exercise(lane), from, increment)),
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

fn advance_stage_effect(lane: &str, from: Option<&str>, to: Option<&str>) -> Effect {
    Effect {
        op: "advance_stage".into(),
        lane: lane.into(),
        from: from.map(str::to_owned),
        to: to.map(str::to_owned),
    }
}

fn next_stage(stages: &[String], current: &str) -> Option<String> {
    let index = stages.iter().position(|stage| stage == current)?;
    stages
        .get(index + 1)
        .cloned()
        .or_else(|| Some(current.into()))
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

/// Exercise name embedded in a lane id (`squat.t1` -> `squat`).
fn lane_exercise(lane: &str) -> &str {
    lane.split('.').next().unwrap_or(lane)
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

fn make_event_id(event_type: &str, session_id: &str, timestamp: &str) -> String {
    let clean = timestamp
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .take(20)
        .collect::<String>()
        .to_ascii_lowercase();
    format!("evt_{clean}_{event_type}_{session_id}")
}

fn message(code: impl Into<String>, message: impl Into<String>) -> ValidationMessage {
    ValidationMessage {
        code: code.into(),
        message: message.into(),
    }
}
