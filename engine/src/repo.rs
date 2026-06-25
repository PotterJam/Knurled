use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;

use crate::backtest::{BacktestProjection, backtest};
use crate::core::{
    PatchFile, build_outputs, compile_plan, create_initial_state, render_next, simulate,
};
use crate::error::{KnurledError, Result};
use crate::json::pretty_json;
use crate::model::*;
use crate::record::{DayRecord, LogMonth, month_key, month_path};
use crate::session::{SubmitMode, SubmitOutcome, submit_session};
use crate::templates::{TemplateRef, parse_template_ref, render_lockfile};

#[derive(Debug, Clone)]
pub struct TrainingRepo {
    pub root: PathBuf,
    pub plan_text: String,
    pub lock_text: String,
    pub patch_files: Vec<PatchFile>,
    pub compiled: CompiledPlan,
}

#[derive(Debug, Clone)]
pub struct InitResult {
    pub root: PathBuf,
    pub validation: ValidationReport,
    pub next_workout: Option<RenderedSession>,
}

pub fn read_training_repo(repo_path: impl AsRef<Path>) -> Result<TrainingRepo> {
    let root = repo_path.as_ref().to_path_buf();
    let plan_path = root.join("plan.fitspec");
    let lock_path = root.join("fitspec.lock");
    let plan_text = read_required(&plan_path)?;
    let lock_text = read_optional(&lock_path)?.unwrap_or_default();
    let patch_files = read_patch_files(&root)?;
    let compiled = compile_plan(&plan_text, &lock_text, &patch_files)?;

    Ok(TrainingRepo {
        root,
        plan_text,
        lock_text,
        patch_files,
        compiled,
    })
}

pub fn init_training_repo(repo_path: impl AsRef<Path>, template: &str) -> Result<InitResult> {
    let root = repo_path.as_ref();
    let reference = parse_template_ref(template);
    fs::create_dir_all(root).map_err(|source| io_error(root, source))?;
    for dir in ["patches", "templates", "logs"] {
        fs::create_dir_all(root.join(dir)).map_err(|source| io_error(root.join(dir), source))?;
    }

    let files = if reference.id.starts_with("531.") {
        initial_531_files(&reference)?
    } else if reference.id.starts_with("starting-strength.") {
        initial_starting_strength_files(&reference)?
    } else {
        initial_gzclp_files(&reference)?
    };

    for (relative_path, text) in files {
        let path = root.join(relative_path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|source| io_error(parent, source))?;
        }
        fs::write(&path, text).map_err(|source| io_error(path, source))?;
    }
    for keep in ["patches/.gitkeep", "templates/.gitkeep", "logs/.gitkeep"] {
        fs::write(root.join(keep), "").map_err(|source| io_error(root.join(keep), source))?;
    }

    let outputs = build_repo(root, true)?;
    Ok(InitResult {
        root: root.to_path_buf(),
        validation: outputs.validation,
        next_workout: outputs.next_workout,
    })
}

pub fn validate_repo(repo_path: impl AsRef<Path>) -> Result<ValidationReport> {
    let repo = read_training_repo(repo_path)?;
    Ok(crate::core::validate_compiled(&repo.compiled))
}

pub fn build_repo(repo_path: impl AsRef<Path>, write: bool) -> Result<BuildOutputs> {
    let root = repo_path.as_ref();
    let repo = read_training_repo(root)?;
    let state = read_state(root)?;
    let outputs = build_outputs(&repo.compiled, &state)?;
    if write {
        write_generated_files(root, &outputs)?;
    }
    Ok(outputs)
}

pub fn preview_repo(repo_path: impl AsRef<Path>, weeks: u32) -> Result<PreviewReport> {
    let root = repo_path.as_ref();
    let repo = read_training_repo(root)?;
    let state = read_state(root)?;
    if weeks <= 1 {
        let outputs = build_outputs(&repo.compiled, &state)?;
        Ok(PreviewReport {
            kind: "preview_report".into(),
            schema_version: SCHEMA_VERSION.into(),
            sessions: json!([outputs.next_workout]),
            final_state: None,
        })
    } else {
        let report = simulate(&repo.compiled, &state, weeks, "all-pass")?;
        Ok(PreviewReport {
            kind: "preview_report".into(),
            schema_version: SCHEMA_VERSION.into(),
            sessions: serde_json::to_value(report.sessions)?,
            final_state: Some(report.final_state),
        })
    }
}

pub fn simulate_repo(
    repo_path: impl AsRef<Path>,
    weeks: u32,
    strategy: &str,
) -> Result<SimulationReport> {
    let root = repo_path.as_ref();
    let repo = read_training_repo(root)?;
    let state = read_state(root)?;
    simulate(&repo.compiled, &state, weeks, strategy)
}

pub fn check_generated_repo(repo_path: impl AsRef<Path>) -> Result<GeneratedFileReport> {
    let root = repo_path.as_ref();
    let repo = read_training_repo(root)?;
    let state = read_state(root)?;
    let outputs = build_outputs(&repo.compiled, &state)?;
    let expected = generated_file_map(&outputs)?;
    let mut changed = Vec::new();
    let mut missing = Vec::new();

    for (relative_path, expected_text) in expected {
        let path = root.join(&relative_path);
        if !path.exists() {
            missing.push(relative_path);
            continue;
        }
        let actual = fs::read_to_string(&path).map_err(|source| io_error(&path, source))?;
        if actual != expected_text {
            changed.push(relative_path);
        }
    }

    Ok(GeneratedFileReport {
        kind: "generated_file_report".into(),
        schema_version: SCHEMA_VERSION.into(),
        status: if changed.is_empty() && missing.is_empty() {
            "current".into()
        } else {
            "stale".into()
        },
        changed,
        missing,
    })
}

// --- State-primary record flow (ADR 0007) -------------------------------------
//
// `state/current.json` is the source of truth and `logs/<yyyy>/<mm>.json` is an
// append/edit-in-place record the engine never replays. These helpers read and
// write that pair directly.

/// Read `state/current.json`, or derive the program's initial state when the
/// repo has not recorded anything yet.
pub fn read_state(repo_path: impl AsRef<Path>) -> Result<StateProjection> {
    let root = repo_path.as_ref();
    let path = root.join("state").join("current.json");
    if let Some(text) = read_optional(&path)? {
        serde_json::from_str(&text).map_err(|source| KnurledError::Json { path, source })
    } else {
        let repo = read_training_repo(root)?;
        Ok(create_initial_state(&repo.compiled))
    }
}

/// Write `state/current.json` (the source of truth).
pub fn write_state(repo_path: impl AsRef<Path>, state: &StateProjection) -> Result<()> {
    let dir = repo_path.as_ref().join("state");
    fs::create_dir_all(&dir).map_err(|source| io_error(&dir, source))?;
    let path = dir.join("current.json");
    fs::write(&path, pretty_json(state)?).map_err(|source| io_error(&path, source))
}

/// Read every day record under `logs/**/*.json`, in chronological order.
pub fn read_records(repo_path: impl AsRef<Path>) -> Result<Vec<DayRecord>> {
    let logs_dir = repo_path.as_ref().join("logs");
    if !logs_dir.exists() {
        return Ok(Vec::new());
    }
    let mut files = Vec::new();
    collect_files(&logs_dir, &mut files)?;
    files.sort();

    let mut days = Vec::new();
    for path in files
        .into_iter()
        .filter(|path| path.extension().is_some_and(|extension| extension == "json"))
    {
        let text = fs::read_to_string(&path).map_err(|source| io_error(&path, source))?;
        let month: LogMonth =
            serde_json::from_str(&text).map_err(|source| KnurledError::Json {
                path: path.clone(),
                source,
            })?;
        days.extend(month.days);
    }
    days.sort_by(|left, right| left.date.cmp(&right.date));
    Ok(days)
}

/// Insert or replace a day in its month file (`logs/<yyyy>/<mm>.json`), keeping
/// the file pretty-printed and chronological. Returns the repo-relative path.
pub fn append_day_record(repo_path: impl AsRef<Path>, day: DayRecord) -> Result<String> {
    let relative = month_path(&day.date)?;
    let path = repo_path.as_ref().join(&relative);
    let mut month = match read_optional(&path)? {
        Some(text) => LogMonth::parse(&text)?,
        None => LogMonth::new(month_key(&day.date)?),
    };
    month.upsert_day(day);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| io_error(parent, source))?;
    }
    fs::write(&path, month.to_pretty_json()?).map_err(|source| io_error(&path, source))?;
    Ok(relative)
}

/// Submit a finished session against the next workout: advance `state` per
/// `mode` and append the day to the record. On invalid input nothing is
/// written; the returned outcome carries the validation errors.
pub fn submit_repo(
    repo_path: impl AsRef<Path>,
    input: &ExecutionInput,
    mode: SubmitMode,
    date: &str,
) -> Result<SubmitOutcome> {
    let root = repo_path.as_ref();
    let repo = read_training_repo(root)?;
    let state = read_state(root)?;
    let rendered = render_next(&repo.compiled, &state)?;
    let outcome = submit_session(&repo.compiled, &state, &rendered, input, mode, date)?;
    if outcome.validation.status == ValidationStatus::Valid {
        write_state(root, &outcome.new_state)?;
        append_day_record(root, outcome.record_day.clone())?;
    }
    Ok(outcome)
}

/// Backtest the repo's plan over its recorded days (the opt-in, replay-free
/// projection of ADR 0007).
pub fn backtest_records_repo(repo_path: impl AsRef<Path>) -> Result<BacktestProjection> {
    let root = repo_path.as_ref();
    let repo = read_training_repo(root)?;
    let days = read_records(root)?;
    backtest(&repo.compiled, &days)
}

pub fn write_generated_files(root: impl AsRef<Path>, outputs: &BuildOutputs) -> Result<()> {
    let root = root.as_ref();
    for (relative_path, text) in generated_file_map(outputs)? {
        let path = root.join(relative_path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|source| io_error(parent, source))?;
        }
        fs::write(&path, text).map_err(|source| io_error(path, source))?;
    }
    Ok(())
}

fn generated_file_map(outputs: &BuildOutputs) -> Result<BTreeMap<String, String>> {
    Ok(BTreeMap::from([
        ("state/current.json".into(), pretty_json(&outputs.state)?),
        ("build/current.ir.json".into(), pretty_json(&outputs.ir)?),
        (
            "build/next-workout.json".into(),
            pretty_json(&outputs.next_workout)?,
        ),
        (
            "build/validation.json".into(),
            pretty_json(&outputs.validation)?,
        ),
    ]))
}

fn read_required(path: &Path) -> Result<String> {
    if !path.exists() {
        return Err(KnurledError::MissingRequiredFile(path.to_path_buf()));
    }
    fs::read_to_string(path).map_err(|source| io_error(path, source))
}

fn read_optional(path: &Path) -> Result<Option<String>> {
    if path.exists() {
        read_required(path).map(Some)
    } else {
        Ok(None)
    }
}

fn read_patch_files(root: &Path) -> Result<Vec<PatchFile>> {
    let patches_dir = root.join("patches");
    if !patches_dir.exists() {
        return Ok(Vec::new());
    }
    let mut files = fs::read_dir(&patches_dir)
        .map_err(|source| io_error(&patches_dir, source))?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "fitspec")
        })
        .collect::<Vec<_>>();
    files.sort();

    files
        .into_iter()
        .map(|path| {
            let filename = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .to_string();
            let text = fs::read_to_string(&path).map_err(|source| io_error(&path, source))?;
            Ok(PatchFile { filename, text })
        })
        .collect()
}

fn collect_files(dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(dir).map_err(|source| io_error(dir, source))? {
        let path = entry.map_err(|source| io_error(dir, source))?.path();
        if path.is_dir() {
            collect_files(&path, files)?;
        } else {
            files.push(path);
        }
    }
    Ok(())
}

fn initial_gzclp_files(reference: &TemplateRef) -> Result<BTreeMap<String, String>> {
    let id = &reference.id;
    let version = &reference.version;
    Ok(BTreeMap::from([
        (
            "fitspec.toml".into(),
            [
                "[repo]",
                "schema_version = \"0.1\"",
                "units = \"kg\"",
                "",
                "[build]",
                "commit_generated = true",
                "",
                "[github]",
                "default_branch = \"main\"",
                "",
            ]
            .join("\n"),
        ),
        (
            "plan.fitspec".into(),
            format!(
                r#"plan "My GZCLP" {{
  template "{id}" version="{version}"
  units kg

  schedule next_workout {{
    rotation A1 B1 A2 B2
    suggested_days mon wed fri
  }}

  starts {{
    squat "80kg"
    bench "55kg"
    press "37.5kg"
    deadlift "100kg"
  }}

  accessories {{
    A1.T3 lat_pulldown
    B1.T3 barbell_row
    A2.T3 lat_pulldown
    B2.T3 barbell_row
  }}
}}
"#
            ),
        ),
        ("fitspec.lock".into(), render_lockfile(&reference.normalized)?),
        (
            "README.md".into(),
            "# Knurled Training Repo\n\nCanonical files are `plan.fitspec`, `fitspec.lock`, `patches/*.fitspec`, `logs/**/*.json`, and `state/current.json`.\nGenerated files live in `build/`.\n".into(),
        ),
    ]))
}

fn initial_531_files(reference: &TemplateRef) -> Result<BTreeMap<String, String>> {
    let id = &reference.id;
    let version = &reference.version;
    Ok(BTreeMap::from([
        (
            "fitspec.toml".into(),
            [
                "[repo]",
                "schema_version = \"0.1\"",
                "units = \"kg\"",
                "",
                "[build]",
                "commit_generated = true",
                "",
            ]
            .join("\n"),
        ),
        (
            "plan.fitspec".into(),
            format!(
                r#"plan "My 5/3/1" {{
  template "{id}" version="{version}"
  units kg

  schedule next_workout {{
    rotation squat_day bench_day deadlift_day press_day
    suggested_days mon wed fri sat
  }}

  training_maxes {{
    squat "90kg"
    bench "65kg"
    deadlift "110kg"
    press "42.5kg"
  }}

  assistance {{
    push "50 reps"
    pull "50 reps"
    single_leg_core "50 reps"
  }}
}}
"#
            ),
        ),
        (
            "fitspec.lock".into(),
            render_lockfile(&reference.normalized)?,
        ),
        ("README.md".into(), "# Knurled 5/3/1 Training Repo\n".into()),
    ]))
}

fn initial_starting_strength_files(reference: &TemplateRef) -> Result<BTreeMap<String, String>> {
    let id = &reference.id;
    let version = &reference.version;
    Ok(BTreeMap::from([
        (
            "fitspec.toml".into(),
            [
                "[repo]",
                "schema_version = \"0.1\"",
                "units = \"kg\"",
                "",
                "[build]",
                "commit_generated = true",
                "",
            ]
            .join("\n"),
        ),
        (
            "plan.fitspec".into(),
            format!(
                r#"plan "My Starting Strength" {{
  template "{id}" version="{version}"
  units kg

  schedule next_workout {{
    suggested_days mon wed fri
  }}

  starts {{
    squat "60kg"
    press "30kg"
    bench "40kg"
    deadlift "80kg"
    power_clean "40kg"
  }}
}}
"#
            ),
        ),
        ("fitspec.lock".into(), render_lockfile(&reference.normalized)?),
        (
            "README.md".into(),
            "# Knurled Starting Strength Training Repo\n\nStarting Strength phases are built-in engine presets, locked in `fitspec.lock`, not user-authored template files.\n".into(),
        ),
    ]))
}

fn io_error(path: impl AsRef<Path>, source: std::io::Error) -> KnurledError {
    KnurledError::Io {
        path: path.as_ref().to_path_buf(),
        source,
    }
}
