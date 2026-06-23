use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;

use crate::core::{PatchFile, build_outputs, compile_plan, replay_events, simulate};
use crate::error::{KnurledError, Result};
use crate::json::pretty_json;
use crate::model::*;
use crate::templates::{parse_template_ref, render_lockfile};

#[derive(Debug, Clone)]
pub struct TrainingRepo {
    pub root: PathBuf,
    pub plan_text: String,
    pub lock_text: String,
    pub patch_files: Vec<PatchFile>,
    pub events: Vec<TrainingEvent>,
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
    let events = read_log_events(&root)?;
    let compiled = compile_plan(&plan_text, &lock_text, &patch_files)?;

    Ok(TrainingRepo {
        root,
        plan_text,
        lock_text,
        patch_files,
        events,
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
        initial_531_files(&reference.normalized)?
    } else if reference.id.starts_with("starting-strength.") {
        initial_starting_strength_files(&reference.normalized)?
    } else {
        initial_gzclp_files(&reference.normalized)?
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
    let repo = read_training_repo(repo_path)?;
    let outputs = build_outputs(&repo.compiled, &repo.events)?;
    if write {
        write_generated_files(&repo.root, &outputs)?;
    }
    Ok(outputs)
}

pub fn preview_repo(repo_path: impl AsRef<Path>, weeks: u32) -> Result<PreviewReport> {
    let repo = read_training_repo(repo_path)?;
    let outputs = build_outputs(&repo.compiled, &repo.events)?;
    if weeks <= 1 {
        Ok(PreviewReport {
            kind: "preview_report".into(),
            schema_version: SCHEMA_VERSION.into(),
            sessions: json!([outputs.next_workout]),
            final_state: None,
        })
    } else {
        let report = simulate(&repo.compiled, &outputs.state, weeks, "all-pass")?;
        Ok(PreviewReport {
            kind: "preview_report".into(),
            schema_version: SCHEMA_VERSION.into(),
            sessions: serde_json::to_value(report.sessions)?,
            final_state: Some(report.final_state),
        })
    }
}

pub fn replay_repo(repo_path: impl AsRef<Path>, write: bool) -> Result<StateProjection> {
    let repo = read_training_repo(repo_path)?;
    let state = replay_events(&repo.compiled, &repo.events);
    if write {
        let state_dir = repo.root.join("state");
        fs::create_dir_all(&state_dir).map_err(|source| io_error(&state_dir, source))?;
        fs::write(state_dir.join("current.json"), pretty_json(&state)?)
            .map_err(|source| io_error(state_dir.join("current.json"), source))?;
    }
    Ok(state)
}

pub fn simulate_repo(
    repo_path: impl AsRef<Path>,
    weeks: u32,
    strategy: &str,
) -> Result<SimulationReport> {
    let repo = read_training_repo(repo_path)?;
    let outputs = build_outputs(&repo.compiled, &repo.events)?;
    simulate(&repo.compiled, &outputs.state, weeks, strategy)
}

pub fn check_generated_repo(repo_path: impl AsRef<Path>) -> Result<GeneratedFileReport> {
    let repo = read_training_repo(repo_path)?;
    let outputs = build_outputs(&repo.compiled, &repo.events)?;
    let expected = generated_file_map(&outputs)?;
    let mut changed = Vec::new();
    let mut missing = Vec::new();

    for (relative_path, expected_text) in expected {
        let path = repo.root.join(&relative_path);
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

pub fn backtest_repo(repo_path: impl AsRef<Path>) -> Result<BacktestReport> {
    let repo = read_training_repo(&repo_path)?;
    let generated = check_generated_repo(&repo_path)?;
    let state = replay_events(&repo.compiled, &repo.events);
    Ok(BacktestReport {
        kind: "backtest_report".into(),
        schema_version: SCHEMA_VERSION.into(),
        status: if generated.status == "current" {
            "passed".into()
        } else {
            "failed".into()
        },
        events_replayed: repo.events.len(),
        corrections_applied: repo
            .events
            .iter()
            .filter(|event| event.kind == "session_corrected")
            .count(),
        skips: repo
            .events
            .iter()
            .filter(|event| event.kind == "session_skipped")
            .count(),
        state_projection: "rebuilt".into(),
        generated_files: generated,
        cursor: state.cursor,
    })
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

fn read_log_events(root: &Path) -> Result<Vec<TrainingEvent>> {
    let logs_dir = root.join("logs");
    if !logs_dir.exists() {
        return Ok(Vec::new());
    }
    let mut files = Vec::new();
    collect_files(&logs_dir, &mut files)?;
    files.sort();

    let mut events = Vec::new();
    for path in files.into_iter().filter(|path| {
        path.extension()
            .is_some_and(|extension| extension == "jsonl")
    }) {
        let text = fs::read_to_string(&path).map_err(|source| io_error(&path, source))?;
        for (index, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            events.push(
                serde_json::from_str(line).map_err(|source| KnurledError::Jsonl {
                    path: path.clone(),
                    line: index + 1,
                    source,
                })?,
            );
        }
    }
    Ok(events)
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

fn initial_gzclp_files(template: &str) -> Result<BTreeMap<String, String>> {
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
  template "{template}"
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
        ("fitspec.lock".into(), render_lockfile(template)?),
        (
            "README.md".into(),
            "# Knurled Training Repo\n\nCanonical files are `plan.fitspec`, `fitspec.lock`, `patches/*.fitspec`, and `logs/**/*.jsonl`.\nGenerated files live in `state/` and `build/`.\n".into(),
        ),
    ]))
}

fn initial_531_files(template: &str) -> Result<BTreeMap<String, String>> {
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
  template "{template}"
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
        ("fitspec.lock".into(), render_lockfile(template)?),
        ("README.md".into(), "# Knurled 5/3/1 Training Repo\n".into()),
    ]))
}

fn initial_starting_strength_files(template: &str) -> Result<BTreeMap<String, String>> {
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
  template "{template}"
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
        ("fitspec.lock".into(), render_lockfile(template)?),
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
