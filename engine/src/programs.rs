//! Multiple authored programs in one training repository.
//!
//! Program source/state lives under `programs/<slug>/`; logs and generated build output remain
//! repository-wide. Repositories without an active-program table retain their legacy root layout
//! until the first program-bank write, when they are migrated atomically enough for local use.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::core::{
    PatchFile, build_outputs, compile_plan, compile_plan_with_template, create_initial_state,
    validate_compiled,
};
use crate::dsl::parse_template_dsl;
use crate::error::{KnurledError, Result};
use crate::json::pretty_json;
use crate::json::sha256_text;
use crate::model::*;
use crate::parser::parse_plan;
use crate::plan_edit::{default_suggested_days, render_plan, starter_plan};
use crate::templates::{builtin_template, parse_template_ref, render_lockfile};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramMeta {
    pub slug: String,
    pub display_name: String,
    pub template: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramSummary {
    pub slug: String,
    pub display_name: String,
    pub template: String,
    pub is_active: bool,
    pub validity: ValidationStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_session: Option<RenderedSession>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AddProgramRequest {
    pub display_name: String,
    pub template: String,
    #[serde(default)]
    pub units: Units,
    #[serde(default)]
    pub initial_numbers: Map<String>,
    #[serde(default)]
    pub suggested_days: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_template: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub equipment: Option<EquipmentProfile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rest: Option<RestPolicy>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProgramMutationOutcome {
    pub programs: Vec<ProgramSummary>,
    pub changed_files: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
struct ConfigWire {
    active: Option<ActiveWire>,
    #[serde(default)]
    programs: Vec<ProgramMeta>,
}

#[derive(Debug, Deserialize)]
struct ActiveWire {
    program: String,
}

pub fn active_program_dir(root: impl AsRef<Path>) -> Result<PathBuf> {
    let root = root.as_ref();
    let config = read_config(root)?;
    if let Some(active) = config.active {
        let dir = root.join("programs").join(&active.program);
        if !dir.exists() {
            return Err(KnurledError::MissingRequiredFile(dir));
        }
        Ok(dir)
    } else {
        Ok(root.to_path_buf())
    }
}

pub fn active_program_relative_path(root: impl AsRef<Path>, relative: &str) -> Result<String> {
    let root = root.as_ref();
    let active = active_program_dir(root)?;
    if active == root {
        return Ok(relative.replace('\\', "/"));
    }
    let prefix = active
        .strip_prefix(root)
        .map_err(|_| KnurledError::Parse("active program escaped repository".into()))?;
    Ok(prefix.join(relative).to_string_lossy().replace('\\', "/"))
}

pub fn ensure_program_layout(root: impl AsRef<Path>) -> Result<()> {
    let root = root.as_ref();
    let config = read_config(root)?;
    if config.active.is_some() && !config.programs.is_empty() {
        return Ok(());
    }
    let plan_path = root.join("plan.fitspec");
    if !plan_path.exists() {
        return Err(KnurledError::MissingRequiredFile(plan_path));
    }
    let plan_text =
        fs::read_to_string(&plan_path).map_err(|source| io_error(&plan_path, source))?;
    let plan = parse_plan(&plan_text)?;
    let slug = unique_slug(root, &slugify(&plan.name));
    let target = root.join("programs").join(&slug);
    fs::create_dir_all(&target).map_err(|source| io_error(&target, source))?;
    for entry in [
        "plan.fitspec",
        "fitspec.lock",
        "patches",
        "templates",
        "state",
    ] {
        let source_path = root.join(entry);
        if source_path.exists() {
            let target_path = target.join(entry);
            fs::rename(&source_path, &target_path)
                .map_err(|source| io_error(&source_path, source))?;
        }
    }
    for dir in ["patches", "templates", "state"] {
        fs::create_dir_all(target.join(dir))
            .map_err(|source| io_error(target.join(dir), source))?;
    }
    write_config(
        root,
        &slug,
        &[ProgramMeta {
            slug: slug.clone(),
            display_name: plan.name,
            template: plan.template,
        }],
    )
}

pub fn list_programs(root: impl AsRef<Path>) -> Result<Vec<ProgramSummary>> {
    let root = root.as_ref();
    let config = read_config(root)?;
    if config.programs.is_empty() {
        let plan_text = fs::read_to_string(root.join("plan.fitspec"))
            .map_err(|source| io_error(root.join("plan.fitspec"), source))?;
        let plan = parse_plan(&plan_text)?;
        return Ok(vec![summary_for(
            root,
            ProgramMeta {
                slug: "legacy".into(),
                display_name: plan.name,
                template: plan.template,
            },
            true,
        )?]);
    }
    let active = config
        .active
        .map(|active| active.program)
        .unwrap_or_default();
    config
        .programs
        .into_iter()
        .map(|meta| {
            let is_active = meta.slug == active;
            summary_for(&root.join("programs").join(&meta.slug), meta, is_active)
        })
        .collect()
}

pub fn add_program(
    root: impl AsRef<Path>,
    request: AddProgramRequest,
) -> Result<ProgramMutationOutcome> {
    let root = root.as_ref();
    ensure_program_layout(root)?;
    let mut config = read_config(root)?;
    let name = request.display_name.trim();
    if name.is_empty() {
        return Err(KnurledError::InvalidExecutionInput(
            "program name is required".into(),
        ));
    }
    let slug = unique_slug(root, &slugify(name));
    let dir = root.join("programs").join(&slug);
    for child in ["patches", "templates", "state"] {
        fs::create_dir_all(dir.join(child)).map_err(|source| io_error(dir.join(child), source))?;
    }
    let (plan, lock_text, template_id, custom_path) = if let Some(document) =
        request.custom_template
    {
        let template = parse_template_dsl(&document, "./templates/custom.fitspec")?;
        let dsl = template
            .dsl
            .as_ref()
            .expect("custom parser always sets DSL");
        let mut starts = Map::new();
        let mut training_maxes = Map::new();
        for lane in dsl.lanes.values() {
            if let Some(value) = request.initial_numbers.get(&lane.exercise) {
                match lane.basis {
                    DslBasis::WorkingWeight => {
                        starts.insert(lane.exercise.clone(), value.clone());
                    }
                    DslBasis::TrainingMax => {
                        training_maxes.insert(lane.exercise.clone(), value.clone());
                    }
                    DslBasis::Bodyweight => {}
                }
            }
        }
        let plan = Plan {
            kind: "fitspec_plan".into(),
            schema_version: SCHEMA_VERSION.into(),
            name: name.to_owned(),
            template: "./templates/custom.fitspec".into(),
            units: request.units,
            schedule: Schedule {
                mode: "next_workout".into(),
                rotation: dsl.rotation.clone(),
                suggested_days: if request.suggested_days.is_empty() {
                    vec!["mon".into(), "wed".into(), "fri".into()]
                } else {
                    request.suggested_days
                },
            },
            starts,
            training_maxes,
            accessories: Map::new(),
            exercises: Map::new(),
            exercise_options: Map::new(),
            rest: request.rest.clone().unwrap_or(RestPolicy {
                default_seconds: Some(dsl.rest_seconds),
                ..RestPolicy::default()
            }),
            warmup: WarmupPolicy::default(),
            session_exercises: SessionExercisePolicy::default(),
            equipment: request.equipment.clone(),
        };
        let lock = format!(
            "[templates.\"./templates/custom.fitspec\"]\nversion = \"{}\"\nsource = \"./templates/custom.fitspec\"\ncontent_hash = \"{}\"\nengine_version = \"{}\"\n",
            dsl.version,
            sha256_text(&document),
            ENGINE_VERSION,
        );
        (
            plan,
            lock,
            "./templates/custom.fitspec".to_owned(),
            Some(document),
        )
    } else {
        let reference = parse_template_ref(&request.template);
        let template = builtin_template(&reference.normalized)?;
        let mut plan = starter_plan(
            &reference,
            &template,
            Some(name.to_owned()),
            request.units,
            request.initial_numbers,
            if request.suggested_days.is_empty() {
                default_suggested_days(&reference.id)
            } else {
                request.suggested_days
            },
        );
        if let Some(rest) = request.rest.clone() {
            plan.rest = rest;
        }
        plan.equipment = request.equipment.clone();
        (
            plan,
            render_lockfile(&reference.normalized)?,
            reference.normalized,
            None,
        )
    };
    fs::write(dir.join("plan.fitspec"), render_plan(&plan))
        .map_err(|source| io_error(dir.join("plan.fitspec"), source))?;
    fs::write(dir.join("fitspec.lock"), lock_text)
        .map_err(|source| io_error(dir.join("fitspec.lock"), source))?;
    if let Some(document) = custom_path.as_ref() {
        fs::write(dir.join("templates/custom.fitspec"), document)
            .map_err(|source| io_error(dir.join("templates/custom.fitspec"), source))?;
    }
    let compiled = compile_program_dir(&dir)?;
    fs::write(
        dir.join("state/current.json"),
        pretty_json(&create_initial_state(&compiled))?,
    )
    .map_err(|source| io_error(dir.join("state/current.json"), source))?;
    config.programs.push(ProgramMeta {
        slug: slug.clone(),
        display_name: name.to_owned(),
        template: template_id,
    });
    let active = config
        .active
        .map(|active| active.program)
        .unwrap_or(slug.clone());
    write_config(root, &active, &config.programs)?;
    Ok(ProgramMutationOutcome {
        programs: list_programs(root)?,
        changed_files: vec![
            "fitspec.toml".into(),
            format!("programs/{slug}/plan.fitspec"),
            format!("programs/{slug}/fitspec.lock"),
            format!("programs/{slug}/state/current.json"),
        ]
        .into_iter()
        .chain(
            custom_path
                .is_some()
                .then(|| format!("programs/{slug}/templates/custom.fitspec")),
        )
        .collect(),
    })
}

pub fn set_active_program(root: impl AsRef<Path>, slug: &str) -> Result<ProgramMutationOutcome> {
    let root = root.as_ref();
    ensure_program_layout(root)?;
    let config = read_config(root)?;
    if !config.programs.iter().any(|program| program.slug == slug) {
        return Err(KnurledError::InvalidExecutionInput(format!(
            "unknown program: {slug}"
        )));
    }
    write_config(root, slug, &config.programs)?;
    crate::repo::build_repo(root, true)?;
    Ok(ProgramMutationOutcome {
        programs: list_programs(root)?,
        changed_files: vec![
            "fitspec.toml".into(),
            "build/current.ir.json".into(),
            "build/next-workout.json".into(),
            "build/validation.json".into(),
        ],
    })
}

pub fn delete_program(root: impl AsRef<Path>, slug: &str) -> Result<ProgramMutationOutcome> {
    let root = root.as_ref();
    ensure_program_layout(root)?;
    let mut config = read_config(root)?;
    let before = config.programs.len();
    if before <= 1 {
        return Err(KnurledError::InvalidExecutionInput(
            "cannot delete the only program".into(),
        ));
    }
    config.programs.retain(|program| program.slug != slug);
    if config.programs.len() == before {
        return Err(KnurledError::InvalidExecutionInput(format!(
            "unknown program: {slug}"
        )));
    }
    let old_active = config
        .active
        .map(|active| active.program)
        .unwrap_or_default();
    let active = if old_active == slug {
        config.programs[0].slug.clone()
    } else {
        old_active
    };
    fs::remove_dir_all(root.join("programs").join(slug))
        .map_err(|source| io_error(root.join("programs").join(slug), source))?;
    write_config(root, &active, &config.programs)?;
    crate::repo::build_repo(root, true)?;
    Ok(ProgramMutationOutcome {
        programs: list_programs(root)?,
        changed_files: vec!["fitspec.toml".into(), format!("programs/{slug}")],
    })
}

pub fn rename_program(
    root: impl AsRef<Path>,
    slug: &str,
    display_name: &str,
) -> Result<ProgramMutationOutcome> {
    let root = root.as_ref();
    ensure_program_layout(root)?;
    let mut config = read_config(root)?;
    let meta = config
        .programs
        .iter_mut()
        .find(|program| program.slug == slug)
        .ok_or_else(|| KnurledError::InvalidExecutionInput(format!("unknown program: {slug}")))?;
    meta.display_name = display_name.trim().to_owned();
    let dir = root.join("programs").join(slug);
    let plan_path = dir.join("plan.fitspec");
    let mut plan = parse_plan(
        &fs::read_to_string(&plan_path).map_err(|source| io_error(&plan_path, source))?,
    )?;
    plan.name = meta.display_name.clone();
    fs::write(&plan_path, render_plan(&plan)).map_err(|source| io_error(&plan_path, source))?;
    let active = config
        .active
        .map(|active| active.program)
        .unwrap_or_default();
    write_config(root, &active, &config.programs)?;
    Ok(ProgramMutationOutcome {
        programs: list_programs(root)?,
        changed_files: vec![
            "fitspec.toml".into(),
            format!("programs/{slug}/plan.fitspec"),
        ],
    })
}

fn summary_for(dir: &Path, meta: ProgramMeta, is_active: bool) -> Result<ProgramSummary> {
    let compiled = compile_program_dir(dir)?;
    let validation = validate_compiled(&compiled);
    let state_path = dir.join("state/current.json");
    let state = if state_path.exists() {
        let text =
            fs::read_to_string(&state_path).map_err(|source| io_error(&state_path, source))?;
        serde_json::from_str(&text).map_err(|source| KnurledError::Json {
            path: state_path,
            source,
        })?
    } else {
        create_initial_state(&compiled)
    };
    let next_session = if validation.status == ValidationStatus::Valid {
        build_outputs(&compiled, &state)?.next_workout
    } else {
        None
    };
    Ok(ProgramSummary {
        slug: meta.slug,
        display_name: meta.display_name,
        template: meta.template,
        is_active,
        validity: validation.status,
        next_session,
    })
}

fn compile_program_dir(dir: &Path) -> Result<crate::model::CompiledPlan> {
    let plan_path = dir.join("plan.fitspec");
    let lock_path = dir.join("fitspec.lock");
    let plan = fs::read_to_string(&plan_path).map_err(|source| io_error(&plan_path, source))?;
    let lock = if lock_path.exists() {
        fs::read_to_string(&lock_path).map_err(|source| io_error(&lock_path, source))?
    } else {
        String::new()
    };
    let patches_dir = dir.join("patches");
    let mut patches = Vec::new();
    if patches_dir.exists() {
        for entry in fs::read_dir(&patches_dir).map_err(|source| io_error(&patches_dir, source))? {
            let path = entry
                .map_err(|source| io_error(&patches_dir, source))?
                .path();
            if path
                .extension()
                .is_some_and(|extension| extension == "fitspec")
            {
                patches.push(PatchFile {
                    filename: format!("patches/{}", path.file_name().unwrap().to_string_lossy()),
                    text: fs::read_to_string(&path).map_err(|source| io_error(&path, source))?,
                });
            }
        }
    }
    patches.sort_by(|left, right| left.filename.cmp(&right.filename));
    let parsed = parse_plan(&plan)?;
    if parsed.template.starts_with("./") {
        let relative = parsed.template.trim_start_matches("./");
        if relative.split('/').any(|part| part == "..") {
            return Err(KnurledError::Parse(
                "custom template path may not contain `..`".into(),
            ));
        }
        let template_path = dir.join(relative);
        let template = fs::read_to_string(&template_path)
            .map_err(|source| io_error(&template_path, source))?;
        compile_plan_with_template(&plan, &lock, &patches, Some(&template))
    } else {
        compile_plan(&plan, &lock, &patches)
    }
}

fn read_config(root: &Path) -> Result<ConfigWire> {
    let path = root.join("fitspec.toml");
    if !path.exists() {
        return Ok(ConfigWire::default());
    }
    let text = fs::read_to_string(&path).map_err(|source| io_error(&path, source))?;
    toml::from_str(&text)
        .map_err(|error| KnurledError::Parse(format!("{}: {error}", path.display())))
}

fn write_config(root: &Path, active: &str, programs: &[ProgramMeta]) -> Result<()> {
    let path = root.join("fitspec.toml");
    let mut value = if path.exists() {
        let text = fs::read_to_string(&path).map_err(|source| io_error(&path, source))?;
        toml::from_str::<toml::Value>(&text)
            .map_err(|error| KnurledError::Parse(format!("{}: {error}", path.display())))?
    } else {
        toml::Value::Table(toml::map::Map::new())
    };
    let table = value
        .as_table_mut()
        .ok_or_else(|| KnurledError::Parse("fitspec.toml root must be a table".into()))?;
    table.insert(
        "active".into(),
        toml::Value::Table(toml::map::Map::from_iter([(
            "program".into(),
            toml::Value::String(active.into()),
        )])),
    );
    table.insert(
        "programs".into(),
        toml::Value::Array(
            programs
                .iter()
                .map(|program| {
                    toml::Value::Table(toml::map::Map::from_iter([
                        ("slug".into(), toml::Value::String(program.slug.clone())),
                        (
                            "display_name".into(),
                            toml::Value::String(program.display_name.clone()),
                        ),
                        (
                            "template".into(),
                            toml::Value::String(program.template.clone()),
                        ),
                    ]))
                })
                .collect(),
        ),
    );
    let text = toml::to_string_pretty(&value)
        .map_err(|error| KnurledError::Parse(format!("could not render fitspec.toml: {error}")))?;
    fs::write(&path, text).map_err(|source| io_error(&path, source))
}

pub(crate) fn initialize_program_config(
    root: &Path,
    display_name: &str,
    template: &str,
) -> Result<String> {
    let slug = unique_slug(root, &slugify(display_name));
    write_config(
        root,
        &slug,
        &[ProgramMeta {
            slug: slug.clone(),
            display_name: display_name.to_owned(),
            template: template.to_owned(),
        }],
    )?;
    Ok(slug)
}

fn unique_slug(root: &Path, requested: &str) -> String {
    let base = if requested.is_empty() {
        "program"
    } else {
        requested
    };
    let mut candidate = base.to_owned();
    let mut suffix = 2;
    while root.join("programs").join(&candidate).exists() {
        candidate = format!("{base}-{suffix}");
        suffix += 1;
    }
    candidate
}

fn slugify(value: &str) -> String {
    let mut slug = String::new();
    let mut separator = false;
    for ch in value.chars().flat_map(char::to_lowercase) {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch);
            separator = false;
        } else if !separator && !slug.is_empty() {
            slug.push('-');
            separator = true;
        }
    }
    slug.trim_matches('-').to_owned()
}

fn io_error(path: impl Into<PathBuf>, source: std::io::Error) -> KnurledError {
    KnurledError::Io {
        path: path.into(),
        source,
    }
}
