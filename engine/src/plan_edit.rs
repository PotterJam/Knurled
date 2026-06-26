use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::core::{PatchFile, build_outputs, compile_plan, create_initial_state};
use crate::error::{KnurledError, Result};
use crate::model::*;
use crate::parser::{normalize_exercise, parse_plan};
use crate::record::{DayRecord, month_path};
use crate::repo::{
    append_day_record, read_state, read_training_repo, write_generated_files, write_state,
};
use crate::templates::{builtin_template, parse_template_ref, render_lockfile};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PlanEdit {
    Quick {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        suggested_days: Option<Vec<String>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        equipment: Option<EquipmentProfile>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        custom_exercise: Option<CustomExerciseEdit>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        accessory: Option<AccessoryEdit>,
    },
    SavePatch {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        filename: Option<String>,
        name: String,
        #[serde(default)]
        description: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        active_from: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        expires: Option<String>,
        operations: Vec<PatchEditOperation>,
    },
    DeletePatch {
        filename: String,
    },
    SwitchProgram {
        template: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        plan_name: Option<String>,
        units: Units,
        initial_numbers: Map<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        suggested_days: Option<Vec<String>>,
        date: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        note: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CustomExerciseEdit {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pattern: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub implement: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AccessoryEdit {
    pub slot: String,
    pub exercise: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum PatchEditOperation {
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
        #[serde(default, skip_serializing_if = "Option::is_none")]
        lane_regex: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlanEditOutcome {
    pub applied: bool,
    pub changed_files: Vec<String>,
    pub outputs: BuildOutputs,
}

struct Candidate {
    plan_text: String,
    lock_text: String,
    patch_files: Vec<PatchFile>,
    writes: Vec<(String, Option<String>)>,
    marker: Option<DayRecord>,
    changed_files: Vec<String>,
    switch_program: bool,
}

pub fn preview_plan_edit(repo_path: impl AsRef<Path>, edit: PlanEdit) -> Result<PlanEditOutcome> {
    let root = repo_path.as_ref();
    let candidate = candidate(root, edit)?;
    let outputs = candidate_outputs(root, &candidate)?;
    Ok(PlanEditOutcome {
        applied: false,
        changed_files: candidate.changed_files,
        outputs,
    })
}

pub fn apply_plan_edit(repo_path: impl AsRef<Path>, edit: PlanEdit) -> Result<PlanEditOutcome> {
    let root = repo_path.as_ref();
    let candidate = candidate(root, edit)?;
    let outputs = candidate_outputs(root, &candidate)?;
    if outputs.validation.status != ValidationStatus::Valid {
        return Ok(PlanEditOutcome {
            applied: false,
            changed_files: candidate.changed_files,
            outputs,
        });
    }

    for (relative, text) in &candidate.writes {
        let path = root.join(relative);
        match text {
            Some(text) => {
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent).map_err(|source| io_error(parent, source))?;
                }
                fs::write(&path, text).map_err(|source| io_error(path, source))?;
            }
            None => {
                if path.exists() {
                    fs::remove_file(&path).map_err(|source| io_error(path, source))?;
                }
            }
        }
    }

    if let Some(marker) = candidate.marker.clone() {
        append_day_record(root, marker)?;
    }
    if candidate.switch_program {
        write_state(root, &outputs.state)?;
    }
    write_generated_files(root, &outputs)?;

    Ok(PlanEditOutcome {
        applied: true,
        changed_files: candidate.changed_files,
        outputs,
    })
}

fn candidate(root: &Path, edit: PlanEdit) -> Result<Candidate> {
    let repo = read_training_repo(root)?;
    let mut plan_text = repo.plan_text.clone();
    let mut lock_text = repo.lock_text.clone();
    let mut patch_files = repo.patch_files.clone();
    let mut writes = Vec::new();
    let mut changed = BTreeSet::new();
    let mut marker = None;
    let mut switch_program = false;

    match edit {
        PlanEdit::Quick {
            suggested_days,
            equipment,
            custom_exercise,
            accessory,
        } => {
            let mut plan = parse_plan(&plan_text)?;
            if let Some(days) = suggested_days {
                plan.schedule.suggested_days = days
                    .into_iter()
                    .map(|day| day.trim().to_ascii_lowercase())
                    .filter(|day| !day.is_empty())
                    .collect();
            }
            if let Some(equipment) = equipment {
                plan.equipment = Some(equipment);
            }
            if let Some(exercise) = custom_exercise {
                plan.exercises.insert(
                    normalize_exercise(&exercise.id),
                    CustomExercise {
                        label: exercise.label,
                        pattern: exercise.pattern.map(|value| normalize_token(&value)),
                        implement: exercise.implement.map(|value| normalize_token(&value)),
                    },
                );
            }
            if let Some(accessory) = accessory {
                plan.accessories.insert(
                    accessory.slot.to_ascii_uppercase(),
                    normalize_exercise(&accessory.exercise),
                );
            }
            plan_text = render_plan(&plan);
            writes.push(("plan.fitspec".into(), Some(plan_text.clone())));
            changed.insert("plan.fitspec".to_owned());
        }
        PlanEdit::SavePatch {
            filename,
            name,
            description,
            active_from,
            expires,
            operations,
        } => {
            let filename = patch_filename(filename.as_deref(), &name)?;
            let text = render_patch(&name, &description, active_from, expires, &operations);
            upsert_patch_file(&mut patch_files, &filename, text.clone());
            writes.push((filename.clone(), Some(text)));
            changed.insert(filename);
        }
        PlanEdit::DeletePatch { filename } => {
            let filename = patch_filename(Some(&filename), "patch")?;
            patch_files.retain(|file| file.filename != filename);
            writes.push((filename.clone(), None));
            changed.insert(filename);
        }
        PlanEdit::SwitchProgram {
            template,
            plan_name,
            units,
            initial_numbers,
            suggested_days,
            date,
            note,
        } => {
            let reference = parse_template_ref(&template);
            let template_model = builtin_template(&reference.normalized)?;
            let plan = starter_plan(
                &reference,
                &template_model,
                plan_name,
                units,
                initial_numbers,
                suggested_days
                    .or_else(|| current_suggested_days(&plan_text).ok())
                    .unwrap_or_else(|| default_suggested_days(&reference.id)),
            );
            plan_text = render_plan(&plan);
            lock_text = render_lockfile(&reference.normalized)?;
            patch_files.clear();
            writes.push(("plan.fitspec".into(), Some(plan_text.clone())));
            writes.push(("fitspec.lock".into(), Some(lock_text.clone())));
            changed.insert("plan.fitspec".to_owned());
            changed.insert("fitspec.lock".to_owned());
            changed.insert("state/current.json".to_owned());
            changed.insert(month_path(&date)?);
            let mut day = DayRecord::program_marker(date, reference.id);
            day.note = note;
            marker = Some(day);
            switch_program = true;
        }
    }

    for generated in [
        "state/current.json",
        "build/current.ir.json",
        "build/next-workout.json",
        "build/validation.json",
    ] {
        changed.insert(generated.to_owned());
    }

    Ok(Candidate {
        plan_text,
        lock_text,
        patch_files,
        writes,
        marker,
        changed_files: changed.into_iter().collect(),
        switch_program,
    })
}

fn candidate_outputs(root: &Path, candidate: &Candidate) -> Result<BuildOutputs> {
    let compiled = compile_plan(
        &candidate.plan_text,
        &candidate.lock_text,
        &candidate.patch_files,
    )?;
    let state = if candidate.switch_program {
        create_initial_state(&compiled)
    } else {
        read_state(root)?
    };
    build_outputs(&compiled, &state)
}

fn starter_plan(
    reference: &crate::templates::TemplateRef,
    template: &BuiltinTemplate,
    plan_name: Option<String>,
    units: Units,
    initial_numbers: Map<String>,
    suggested_days: Vec<String>,
) -> Plan {
    let mut starts = Map::new();
    let mut training_maxes = Map::new();
    match template.kind {
        TemplateKind::FiveThreeOne => training_maxes = normalize_lift_map(initial_numbers),
        TemplateKind::Gzclp | TemplateKind::StartingStrength => {
            starts = normalize_lift_map(initial_numbers)
        }
    }

    Plan {
        kind: "fitspec_plan".into(),
        schema_version: SCHEMA_VERSION.into(),
        name: plan_name.unwrap_or_else(|| format!("My {}", template_display_title(&reference.id))),
        template: reference.normalized.clone(),
        units,
        schedule: Schedule {
            mode: "next_workout".into(),
            rotation: template.default_rotation.clone(),
            suggested_days,
        },
        starts,
        training_maxes,
        accessories: default_accessories(&template.kind, &template.sessions),
        exercises: Map::new(),
        exercise_options: Map::new(),
        rest: RestPolicy::default(),
        warmup: WarmupPolicy::default(),
        equipment: None,
    }
}

fn default_accessories(kind: &TemplateKind, sessions: &Map<Vec<TemplateSlot>>) -> Map<String> {
    if *kind != TemplateKind::Gzclp {
        return Map::new();
    }
    sessions
        .values()
        .flat_map(|slots| slots.iter())
        .filter_map(|slot| {
            Some((
                slot.accessory_key.as_ref()?.to_ascii_uppercase(),
                slot.default_exercise.clone()?,
            ))
        })
        .collect()
}

fn current_suggested_days(plan_text: &str) -> Result<Vec<String>> {
    Ok(parse_plan(plan_text)?.schedule.suggested_days)
}

fn default_suggested_days(template_id: &str) -> Vec<String> {
    if template_id.starts_with("531.") {
        vec!["mon", "wed", "fri", "sat"]
    } else {
        vec!["mon", "wed", "fri"]
    }
    .into_iter()
    .map(str::to_owned)
    .collect()
}

fn normalize_lift_map(values: Map<String>) -> Map<String> {
    values
        .into_iter()
        .map(|(key, value)| (normalize_exercise(&key), value))
        .collect()
}

fn normalize_token(value: &str) -> String {
    value.trim().to_ascii_lowercase().replace(' ', "_")
}

fn upsert_patch_file(patches: &mut Vec<PatchFile>, filename: &str, text: String) {
    if let Some(existing) = patches.iter_mut().find(|file| file.filename == filename) {
        existing.text = text;
    } else {
        patches.push(PatchFile {
            filename: filename.to_owned(),
            text,
        });
        patches.sort_by(|left, right| left.filename.cmp(&right.filename));
    }
}

fn patch_filename(filename: Option<&str>, name: &str) -> Result<String> {
    let raw = filename
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("patches/{}.fitspec", slug(name)));
    let normalized = raw.trim().replace('\\', "/");
    if normalized.contains("..") || normalized.starts_with('/') {
        return Err(KnurledError::Parse(format!(
            "invalid patch filename: {normalized}"
        )));
    }
    let with_dir = if normalized.starts_with("patches/") {
        normalized
    } else {
        format!("patches/{normalized}")
    };
    if !with_dir.ends_with(".fitspec") {
        return Err(KnurledError::Parse(format!(
            "patch filename must end with .fitspec: {with_dir}"
        )));
    }
    Ok(with_dir)
}

fn slug(value: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in value.chars().flat_map(char::to_lowercase) {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }
    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() {
        "modification".into()
    } else {
        trimmed.into()
    }
}

fn render_plan(plan: &Plan) -> String {
    let mut out = Vec::new();
    let reference = parse_template_ref(&plan.template);
    out.push(format!("plan \"{}\" {{", escape(&plan.name)));
    out.push(format!(
        "  template \"{}\" version=\"{}\"",
        reference.id, reference.version
    ));
    out.push(format!("  units {}", unit_token(&plan.units)));
    out.push(String::new());
    out.push(format!("  schedule {} {{", plan.schedule.mode));
    if !plan.schedule.rotation.is_empty() {
        out.push(format!("    rotation {}", plan.schedule.rotation.join(" ")));
    }
    if !plan.schedule.suggested_days.is_empty() {
        out.push(format!(
            "    suggested_days {}",
            plan.schedule.suggested_days.join(" ")
        ));
    }
    out.push("  }".into());
    render_string_map(&mut out, "starts", &plan.starts, true);
    render_string_map(&mut out, "training_maxes", &plan.training_maxes, true);
    render_string_map(&mut out, "accessories", &plan.accessories, false);
    render_exercises(&mut out, &plan.exercises);
    render_rest(&mut out, &plan.rest);
    render_warmup(&mut out, &plan.warmup);
    render_equipment(&mut out, plan.equipment.as_ref());
    render_exercise_options(&mut out, &plan.exercise_options);
    out.push("}".into());
    out.push(String::new());
    out.join("\n")
}

fn render_patch(
    name: &str,
    description: &str,
    active_from: Option<String>,
    expires: Option<String>,
    operations: &[PatchEditOperation],
) -> String {
    let mut out = Vec::new();
    out.push(format!("patch \"{}\" {{", escape(name)));
    if !description.trim().is_empty() {
        out.push(format!("  description \"{}\"", escape(description)));
    }
    if let Some(active_from) = active_from.filter(|value| !value.trim().is_empty()) {
        out.push(format!("  active-from \"{}\"", escape(&active_from)));
    }
    if let Some(expires) = expires.filter(|value| !value.trim().is_empty()) {
        out.push(format!("  expires \"{}\"", escape(&expires)));
    }
    for operation in operations {
        match operation {
            PatchEditOperation::ReplaceExercise {
                from,
                to,
                lane_regex,
            } => out.push(format!(
                "  replace-exercise from={} to={} lane=\"{}\"",
                normalize_exercise(from),
                normalize_exercise(to),
                escape(lane_regex)
            )),
            PatchEditOperation::AddConditioning { day, activity } => out.push(format!(
                "  add-conditioning day={} activity=\"{}\"",
                day.trim().to_ascii_lowercase(),
                escape(activity)
            )),
            PatchEditOperation::Cap {
                target,
                value,
                lane_regex,
            } => {
                let lane = lane_regex
                    .as_ref()
                    .filter(|value| !value.trim().is_empty())
                    .map(|value| format!(" lane=\"{}\"", escape(value)))
                    .unwrap_or_default();
                out.push(format!(
                    "  cap target={} value=\"{}\"{}",
                    normalize_token(target),
                    escape(value),
                    lane
                ));
            }
        }
    }
    out.push("}".into());
    out.push(String::new());
    out.join("\n")
}

fn render_string_map(out: &mut Vec<String>, name: &str, values: &Map<String>, quote: bool) {
    if values.is_empty() {
        return;
    }
    out.push(String::new());
    out.push(format!("  {name} {{"));
    for (key, value) in values {
        if quote {
            out.push(format!("    {key} \"{}\"", escape(value)));
        } else {
            out.push(format!("    {key} {value}"));
        }
    }
    out.push("  }".into());
}

fn render_exercises(out: &mut Vec<String>, exercises: &Map<CustomExercise>) {
    if exercises.is_empty() {
        return;
    }
    out.push(String::new());
    out.push("  exercises {".into());
    for (id, exercise) in exercises {
        let mut parts = vec![format!("label \"{}\"", escape(&exercise.label))];
        if let Some(pattern) = &exercise.pattern {
            parts.push(format!("pattern {pattern}"));
        }
        if let Some(implement) = &exercise.implement {
            parts.push(format!("implement {implement}"));
        }
        out.push(format!("    {id} {{ {} }}", parts.join("; ")));
    }
    out.push("  }".into());
}

fn render_rest(out: &mut Vec<String>, rest: &RestPolicy) {
    if rest.default_seconds.is_none()
        && rest.by_tier.is_empty()
        && rest.by_slot.is_empty()
        && rest.by_lane.is_empty()
        && rest.by_exercise.is_empty()
    {
        return;
    }
    out.push(String::new());
    out.push("  rest {".into());
    if let Some(seconds) = rest.default_seconds {
        out.push(format!("    default {seconds}s"));
    }
    for (scope, values) in [
        ("tier", &rest.by_tier),
        ("slot", &rest.by_slot),
        ("lane", &rest.by_lane),
        ("exercise", &rest.by_exercise),
    ] {
        for (key, seconds) in values {
            out.push(format!("    {scope} {key} {seconds}s"));
        }
    }
    out.push("  }".into());
}

fn render_warmup(out: &mut Vec<String>, warmup: &WarmupPolicy) {
    if warmup.is_empty() {
        return;
    }
    out.push(String::new());
    out.push("  warmup {".into());
    if let Some(scheme) = &warmup.default {
        render_warmup_scheme(out, "default", None, scheme);
    }
    for (scope, values) in [
        ("tier", &warmup.by_tier),
        ("slot", &warmup.by_slot),
        ("lane", &warmup.by_lane),
        ("exercise", &warmup.by_exercise),
    ] {
        for (key, scheme) in values {
            render_warmup_scheme(out, scope, Some(key), scheme);
        }
    }
    out.push("  }".into());
}

fn render_warmup_scheme(
    out: &mut Vec<String>,
    scope: &str,
    key: Option<&String>,
    scheme: &WarmupScheme,
) {
    match key {
        Some(key) => out.push(format!("    {scope} \"{}\" {{", escape(key))),
        None => out.push(format!("    {scope} {{")),
    }
    if scheme.empty_bar_sets > 0 || scheme.empty_bar_reps > 0 {
        out.push(format!(
            "      empty_bar {} {}",
            scheme.empty_bar_sets, scheme.empty_bar_reps
        ));
    }
    if !scheme.ramp.is_empty() {
        out.push("      ramp {".into());
        for step in &scheme.ramp {
            out.push(format!("        step {} {}", step.percentage, step.reps));
        }
        out.push("      }".into());
    }
    if scheme.basis != WarmupBasis::TopSet {
        out.push(format!("      basis {}", warmup_basis_token(&scheme.basis)));
    }
    out.push("    }".into());
}

fn render_equipment(out: &mut Vec<String>, equipment: Option<&EquipmentProfile>) {
    let Some(equipment) = equipment else { return };
    out.push(String::new());
    out.push("  equipment {".into());
    for (key, weight) in &equipment.bars {
        out.push(format!("    bar {key} {}", number(*weight)));
    }
    if !equipment.plate_pairs.is_empty() {
        out.push(format!(
            "    plates {}",
            equipment
                .plate_pairs
                .iter()
                .map(|value| number(*value))
                .collect::<Vec<_>>()
                .join(" ")
        ));
    }
    if !equipment.dumbbells.is_empty() {
        out.push(format!(
            "    dumbbells {}",
            equipment
                .dumbbells
                .iter()
                .map(|value| number(*value))
                .collect::<Vec<_>>()
                .join(" ")
        ));
    }
    if equipment.rounding != RoundingMode::Nearest {
        out.push(format!("    rounding {}", rounding_token(&equipment.rounding)));
    }
    for (exercise, implement) in &equipment.implements {
        out.push(format!(
            "    implement {exercise} {}",
            implement_token(implement)
        ));
    }
    out.push("  }".into());
}

fn render_exercise_options(out: &mut Vec<String>, options: &Map<ExerciseOptions>) {
    if options.is_empty() {
        return;
    }
    out.push(String::new());
    out.push("  exercise_options {".into());
    for (slot, option) in options {
        out.push(format!("    slot \"{}\" {{", escape(slot)));
        if !option.primary.is_empty() {
            out.push(format!("      primary {}", option.primary));
        }
        for alt in &option.alternatives {
            out.push(format!(
                "      {} {{ label \"{}\"; policy {} }}",
                alt.exercise,
                escape(&alt.label),
                policy_token(&alt.policy)
            ));
        }
        out.push("    }".into());
    }
    out.push("  }".into());
}

fn unit_token(units: &Units) -> &'static str {
    match units {
        Units::Kg => "kg",
        Units::Lb => "lb",
    }
}

fn policy_token(policy: &SwapPolicy) -> &'static str {
    match policy {
        SwapPolicy::TrackingOnly => "tracking_only",
        SwapPolicy::ProgressionEquivalent => "progression_equivalent",
    }
}

fn warmup_basis_token(basis: &WarmupBasis) -> &'static str {
    match basis {
        WarmupBasis::TopSet => "top_set",
        WarmupBasis::WorkingWeight => "working_weight",
        WarmupBasis::TrainingMax => "training_max",
    }
}

fn rounding_token(rounding: &RoundingMode) -> &'static str {
    match rounding {
        RoundingMode::Nearest => "nearest",
        RoundingMode::Down => "down",
    }
}

fn implement_token(implement: &Implement) -> &'static str {
    match implement {
        Implement::Barbell => "barbell",
        Implement::Dumbbell => "dumbbell",
    }
}

fn template_display_title(id: &str) -> String {
    id.replace("gzcl.gzclp", "GZCLP")
        .replace("531.beginners", "5/3/1")
        .replace("531.basic", "5/3/1")
        .replace("starting-strength.phase1", "Starting Strength")
        .replace("starting-strength.phase2", "Starting Strength")
        .replace("starting-strength.phase3", "Starting Strength")
}

fn number(value: f64) -> String {
    let text = format!("{value:.4}");
    text.trim_end_matches('0').trim_end_matches('.').to_owned()
}

fn escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn io_error(path: impl AsRef<Path>, source: std::io::Error) -> KnurledError {
    KnurledError::Io {
        path: path.as_ref().to_path_buf(),
        source,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repo::init_training_repo;

    fn temp_dir(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("knurled-plan-edit-{name}-{}", std::process::id()))
    }

    #[test]
    fn preview_quick_edit_does_not_write() {
        let dir = temp_dir("preview");
        let _ = fs::remove_dir_all(&dir);
        init_training_repo(&dir, "gzcl.gzclp@1.0.0").unwrap();
        let before = fs::read_to_string(dir.join("plan.fitspec")).unwrap();

        let result = preview_plan_edit(
            &dir,
            PlanEdit::Quick {
                suggested_days: Some(vec!["tue".into(), "thu".into()]),
                equipment: None,
                custom_exercise: None,
                accessory: None,
            },
        )
        .unwrap();

        assert!(!result.applied);
        assert_eq!(fs::read_to_string(dir.join("plan.fitspec")).unwrap(), before);
        assert!(result.changed_files.contains(&"plan.fitspec".into()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn apply_patch_edit_writes_patch_and_generated_files() {
        let dir = temp_dir("patch");
        let _ = fs::remove_dir_all(&dir);
        init_training_repo(&dir, "gzcl.gzclp@1.0.0").unwrap();

        let result = apply_plan_edit(
            &dir,
            PlanEdit::SavePatch {
                filename: None,
                name: "Shoulder Friendly".into(),
                description: "Temporary press swap".into(),
                active_from: Some("2026-06-26".into()),
                expires: None,
                operations: vec![PatchEditOperation::ReplaceExercise {
                    from: "press".into(),
                    to: "landmine press".into(),
                    lane_regex: "press.*".into(),
                }],
            },
        )
        .unwrap();

        assert!(result.applied);
        assert!(dir.join("patches/shoulder-friendly.fitspec").exists());
        assert!(result.changed_files.contains(&"build/current.ir.json".into()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn switch_program_rewrites_state_and_program_marker() {
        let dir = temp_dir("switch");
        let _ = fs::remove_dir_all(&dir);
        init_training_repo(&dir, "gzcl.gzclp@1.0.0").unwrap();

        let result = apply_plan_edit(
            &dir,
            PlanEdit::SwitchProgram {
                template: "531.beginners@1.0.0".into(),
                plan_name: None,
                units: Units::Kg,
                initial_numbers: Map::from([
                    ("squat".into(), "100kg".into()),
                    ("bench".into(), "70kg".into()),
                    ("deadlift".into(), "120kg".into()),
                    ("press".into(), "45kg".into()),
                ]),
                suggested_days: Some(vec!["mon".into(), "wed".into(), "fri".into(), "sat".into()]),
                date: "2026-06-26".into(),
                note: Some("finished LP".into()),
            },
        )
        .unwrap();

        assert!(result.applied);
        assert!(fs::read_to_string(dir.join("plan.fitspec")).unwrap().contains("training_maxes"));
        assert!(fs::read_to_string(dir.join("logs/2026/06.json")).unwrap().contains("531.beginners"));
        assert_eq!(
            result.outputs.state.lanes["squat.main"]
                .training_max
                .as_deref(),
            Some("100kg")
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
