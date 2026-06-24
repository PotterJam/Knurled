use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::error::{KnurledError, Result};
use crate::json::{sha256_text, stable_json};
use crate::model::{ActualSet, ENGINE_VERSION, ExerciseResult, SCHEMA_VERSION, TrainingEvent};
use crate::parser::normalize_exercise;
use crate::repo::read_training_repo;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryImportDelimiter {
    Auto,
    Csv,
    Tsv,
}

#[derive(Debug, Clone)]
pub struct HistoryImportOptions {
    pub source: String,
    pub delimiter: HistoryImportDelimiter,
    pub dry_run: bool,
}

impl Default for HistoryImportOptions {
    fn default() -> Self {
        Self {
            source: "manual".into(),
            delimiter: HistoryImportDelimiter::Auto,
            dry_run: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HistoryImportReport {
    #[serde(rename = "type")]
    pub kind: String,
    pub schema_version: String,
    pub source: String,
    pub input_rows: usize,
    pub imported_sets: usize,
    pub events_parsed: usize,
    pub events_written: usize,
    pub duplicates_skipped: usize,
    pub output_files: Vec<String>,
    pub dry_run: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryImportDraft {
    pub events: Vec<TrainingEvent>,
    pub input_rows: usize,
    pub imported_sets: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FlatSetRow {
    completed_at: String,
    date_key: String,
    session_title: String,
    source_session_id: Option<String>,
    exercise: String,
    set: Option<u32>,
    set_count: u32,
    reps: u32,
    load: Option<String>,
    metrics: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct SessionKey {
    completed_at: String,
    session_title: String,
    source_session_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SessionBuilder {
    date_key: String,
    completed_at: String,
    session_title: String,
    source_session_id: Option<String>,
    exercises: Vec<ExerciseBuilder>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ExerciseBuilder {
    slot_id: String,
    exercise: String,
    sets: Vec<ImportedActualSet>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ImportedActualSet {
    set: Option<u32>,
    reps: u32,
    load: Option<String>,
    metrics: BTreeMap<String, String>,
}

pub fn import_history_repo(
    repo_path: impl AsRef<Path>,
    input_path: impl AsRef<Path>,
    options: HistoryImportOptions,
) -> Result<HistoryImportReport> {
    let input_path = input_path.as_ref();
    let text = fs::read_to_string(input_path).map_err(|source| KnurledError::Io {
        path: input_path.to_path_buf(),
        source,
    })?;
    let draft = history_import_events_from_str(&text, &options)?;
    let repo = read_training_repo(&repo_path)?;
    let existing_ids = repo
        .events
        .iter()
        .map(|event| event.id.as_str())
        .collect::<BTreeSet<_>>();
    let new_events = draft
        .events
        .iter()
        .filter(|event| !existing_ids.contains(event.id.as_str()))
        .collect::<Vec<_>>();
    let duplicates_skipped = draft.events.len() - new_events.len();

    let relative_output = format!("logs/imports/{}.jsonl", slug(&options.source));
    if !options.dry_run && !new_events.is_empty() {
        let output_path = repo_path.as_ref().join(&relative_output);
        append_events(&output_path, &new_events)?;
    }

    Ok(HistoryImportReport {
        kind: "history_import_report".into(),
        schema_version: SCHEMA_VERSION.into(),
        source: options.source,
        input_rows: draft.input_rows,
        imported_sets: draft.imported_sets,
        events_parsed: draft.events.len(),
        events_written: if options.dry_run { 0 } else { new_events.len() },
        duplicates_skipped,
        output_files: if options.dry_run || new_events.is_empty() {
            Vec::new()
        } else {
            vec![relative_output]
        },
        dry_run: options.dry_run,
    })
}

pub fn history_import_events_from_str(
    text: &str,
    options: &HistoryImportOptions,
) -> Result<HistoryImportDraft> {
    let delimiter = match options.delimiter {
        HistoryImportDelimiter::Auto => detect_delimiter(text),
        HistoryImportDelimiter::Csv => ',',
        HistoryImportDelimiter::Tsv => '\t',
    };
    let records = parse_delimited_records(text, delimiter)?;
    let Some((header_record, row_records)) = records.split_first() else {
        return Err(import_error("import file is empty"));
    };
    let headers = header_record
        .iter()
        .map(|header| normalize_header(header))
        .collect::<Vec<_>>();
    if headers.iter().all(String::is_empty) {
        return Err(import_error("import file has no headers"));
    }

    let mut rows = Vec::new();
    for (index, record) in row_records.iter().enumerate() {
        if record.iter().all(|field| field.trim().is_empty()) {
            continue;
        }
        let row_number = index + 2;
        rows.push(parse_flat_set_row(&headers, record, row_number)?);
    }

    let imported_sets = rows.iter().map(|row| row.set_count as usize).sum::<usize>();
    let events = build_import_events(rows, &options.source);
    Ok(HistoryImportDraft {
        events,
        input_rows: row_records
            .iter()
            .filter(|record| record.iter().any(|field| !field.trim().is_empty()))
            .count(),
        imported_sets,
    })
}

fn append_events(path: &Path, events: &[&TrainingEvent]) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| KnurledError::Io {
            path: parent.to_path_buf(),
            source,
        })?;
    }

    let mut text = if path.exists() {
        fs::read_to_string(path).map_err(|source| KnurledError::Io {
            path: path.to_path_buf(),
            source,
        })?
    } else {
        String::new()
    };
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    for event in events {
        text.push_str(&stable_json(event)?);
        text.push('\n');
    }
    fs::write(path, text).map_err(|source| KnurledError::Io {
        path: path.to_path_buf(),
        source,
    })
}

fn parse_flat_set_row(
    headers: &[String],
    record: &[String],
    row_number: usize,
) -> Result<FlatSetRow> {
    let row = row_map(headers, record);
    let date = required(&row, DATE_COLUMNS, row_number, "date")?;
    let completed_at = normalize_timestamp(date);
    let date_key = date_key(&completed_at);
    let session_title = value(&row, SESSION_COLUMNS)
        .map(str::to_owned)
        .unwrap_or_else(|| "Imported Workout".into());
    let source_session_id = value(&row, SOURCE_SESSION_COLUMNS).map(str::to_owned);
    let exercise = required(&row, EXERCISE_COLUMNS, row_number, "exercise")?.to_owned();
    let set = optional_u32(&row, SET_COLUMNS, row_number, "set")?;
    let set_count = optional_u32(&row, SET_COUNT_COLUMNS, row_number, "sets")?.unwrap_or(1);
    if set_count == 0 {
        return Err(import_error(format!(
            "row {row_number}: sets must be greater than zero"
        )));
    }
    let reps = required_u32(&row, REPS_COLUMNS, row_number, "reps")?;
    let load = load_from_row(&row);
    let metrics = metrics_from_row(&row);

    Ok(FlatSetRow {
        completed_at,
        date_key,
        session_title,
        source_session_id,
        exercise,
        set,
        set_count,
        reps,
        load,
        metrics,
    })
}

fn build_import_events(rows: Vec<FlatSetRow>, source: &str) -> Vec<TrainingEvent> {
    let mut sessions = BTreeMap::<SessionKey, SessionBuilder>::new();

    for row in rows {
        let key = SessionKey {
            completed_at: row.completed_at.clone(),
            session_title: row.session_title.clone(),
            source_session_id: row.source_session_id.clone(),
        };
        let session = sessions.entry(key).or_insert_with(|| SessionBuilder {
            date_key: row.date_key.clone(),
            completed_at: row.completed_at.clone(),
            session_title: row.session_title.clone(),
            source_session_id: row.source_session_id.clone(),
            exercises: Vec::new(),
        });
        let exercise = normalize_exercise(&row.exercise);
        let slot_id = slug(&exercise);
        let index = session
            .exercises
            .iter()
            .position(|candidate| candidate.slot_id == slot_id)
            .unwrap_or_else(|| {
                session.exercises.push(ExerciseBuilder {
                    slot_id: slot_id.clone(),
                    exercise: exercise.clone(),
                    sets: Vec::new(),
                });
                session.exercises.len() - 1
            });
        for offset in 0..row.set_count {
            session.exercises[index].sets.push(ImportedActualSet {
                set: row.set.map(|set| set + offset),
                reps: row.reps,
                load: row.load.clone(),
                metrics: row.metrics.clone(),
            });
        }
    }

    sessions
        .into_values()
        .map(|session| session.into_event(source))
        .collect()
}

impl SessionBuilder {
    fn into_event(self, source: &str) -> TrainingEvent {
        let results = self
            .exercises
            .into_iter()
            .map(ExerciseBuilder::into_result)
            .collect::<Vec<_>>();
        let source_slug = slug(source);
        let session_slug = slug(&self.session_title);
        let identity = format!(
            "{source}\n{}\n{}\n{}\n{}",
            self.completed_at,
            self.session_title,
            self.source_session_id.as_deref().unwrap_or_default(),
            results
                .iter()
                .map(|result| format!("{}:{}", result.slot_id, result.actual.len()))
                .collect::<Vec<_>>()
                .join(",")
        );
        let hash = short_hash(&identity);

        TrainingEvent {
            id: format!("evt_import_{}_{}_{}", source_slug, self.date_key, hash),
            kind: "session_imported".into(),
            schema_version: Some(SCHEMA_VERSION.into()),
            program: Some(format!("history_import:{source_slug}")),
            session_id: Some(session_slug),
            plan_hash: None,
            template_hash: None,
            rendered_session_hash: None,
            engine_version: Some(ENGINE_VERSION.into()),
            started_at: Some(self.completed_at.clone()),
            completed_at: Some(self.completed_at),
            saved_at: None,
            status: Some("imported".into()),
            results,
            results_added: Vec::new(),
            effects: Vec::new(),
            continues_event_id: None,
            corrects_event_id: None,
            reason: Some(self.session_title),
            policy: None,
            lane: None,
            change: None,
            cursor: None,
            changes: Vec::new(),
            change_kind: None,
            from_plan: None,
            to_plan: None,
        }
    }
}

impl ExerciseBuilder {
    fn into_result(self) -> ExerciseResult {
        let actual = self
            .sets
            .into_iter()
            .enumerate()
            .map(|(index, set)| ActualSet {
                set: set.set.unwrap_or((index + 1) as u32),
                load: set.load,
                reps: set.reps,
                metrics: set.metrics,
            })
            .collect::<Vec<_>>();

        ExerciseResult {
            slot_id: self.slot_id,
            progression_lane: None,
            progression_rule: None,
            prescribed_exercise: None,
            performed_exercise: Some(self.exercise),
            swap_reason: None,
            swap_policy: None,
            prescribed: json!({ "source": "history_import", "format": "history_flat_v1" }),
            actual,
            outcome: "imported".into(),
            effects: Vec::new(),
        }
    }
}

fn row_map(headers: &[String], record: &[String]) -> BTreeMap<String, String> {
    let mut row = BTreeMap::new();
    for (index, header) in headers.iter().enumerate() {
        if header.is_empty() {
            continue;
        }
        let value = record
            .get(index)
            .map(|field| field.trim())
            .unwrap_or_default();
        if !value.is_empty() {
            row.insert(header.clone(), value.to_owned());
        }
    }
    row
}

fn required<'a>(
    row: &'a BTreeMap<String, String>,
    aliases: &[&str],
    row_number: usize,
    name: &str,
) -> Result<&'a str> {
    value(row, aliases).ok_or_else(|| import_error(format!("row {row_number}: missing {name}")))
}

fn required_u32(
    row: &BTreeMap<String, String>,
    aliases: &[&str],
    row_number: usize,
    name: &str,
) -> Result<u32> {
    value(row, aliases)
        .ok_or_else(|| import_error(format!("row {row_number}: missing {name}")))
        .and_then(|value| parse_u32(value, row_number, name))
}

fn optional_u32(
    row: &BTreeMap<String, String>,
    aliases: &[&str],
    row_number: usize,
    name: &str,
) -> Result<Option<u32>> {
    value(row, aliases)
        .map(|value| parse_u32(value, row_number, name))
        .transpose()
}

fn value<'a>(row: &'a BTreeMap<String, String>, aliases: &[&str]) -> Option<&'a str> {
    aliases
        .iter()
        .find_map(|alias| row.get(*alias))
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
}

fn parse_u32(value: &str, row_number: usize, name: &str) -> Result<u32> {
    value.trim().parse::<u32>().map_err(|_| {
        import_error(format!(
            "row {row_number}: {name} must be a whole number, got {value:?}"
        ))
    })
}

fn load_from_row(row: &BTreeMap<String, String>) -> Option<String> {
    if let Some(load) = value(row, LOAD_KG_COLUMNS) {
        return Some(load_with_unit(load, Some("kg")));
    }
    if let Some(load) = value(row, LOAD_LB_COLUMNS) {
        return Some(load_with_unit(load, Some("lb")));
    }
    let unit = value(row, UNIT_COLUMNS).and_then(normalize_unit);
    value(row, LOAD_COLUMNS).map(|load| load_with_unit(load, unit))
}

fn load_with_unit(load: &str, unit: Option<&str>) -> String {
    let compact = load.split_whitespace().collect::<String>();
    let lower = compact.to_ascii_lowercase();
    if lower.ends_with("kg") || lower.ends_with("lb") || lower.ends_with("lbs") {
        return lower.trim_end_matches("lbs").to_owned()
            + if lower.ends_with("lbs") { "lb" } else { "" };
    }
    match unit {
        Some(unit) => format!("{compact}{unit}"),
        None => compact,
    }
}

fn normalize_unit(value: &str) -> Option<&'static str> {
    match value.trim().to_ascii_lowercase().as_str() {
        "kg" | "kgs" | "kilogram" | "kilograms" => Some("kg"),
        "lb" | "lbs" | "pound" | "pounds" => Some("lb"),
        _ => None,
    }
}

fn metrics_from_row(row: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let mut metrics = BTreeMap::new();
    for (aliases, key) in [
        (RPE_COLUMNS, "rpe"),
        (RIR_COLUMNS, "rir"),
        (SET_TYPE_COLUMNS, "set_type"),
        (NOTES_COLUMNS, "notes"),
        (DURATION_COLUMNS, "duration"),
        (DURATION_SECONDS_COLUMNS, "duration"),
        (DISTANCE_COLUMNS, "distance"),
        (DISTANCE_M_COLUMNS, "distance"),
        (DISTANCE_KM_COLUMNS, "distance"),
        (REST_SECONDS_COLUMNS, "rest"),
    ] {
        if let Some(value) = value(row, aliases) {
            metrics.insert(key.into(), metric_value(key, aliases, value));
        }
    }
    for (key, value) in row {
        if let Some(metric_key) = key.strip_prefix("metric_")
            && !metric_key.is_empty()
        {
            metrics.insert(metric_key.into(), value.clone());
        }
    }
    metrics
}

fn metric_value(key: &str, aliases: &[&str], value: &str) -> String {
    if key == "duration" && aliases == DURATION_SECONDS_COLUMNS {
        return format!("{value}s");
    }
    if key == "distance" && aliases == DISTANCE_M_COLUMNS {
        return format!("{value}m");
    }
    if key == "distance" && aliases == DISTANCE_KM_COLUMNS {
        return format!("{value}km");
    }
    if key == "rest" && aliases == REST_SECONDS_COLUMNS {
        return format!("{value}s");
    }
    value.to_owned()
}

fn normalize_timestamp(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.len() >= 10 && is_yyyy_mm_dd(&trimmed[..10]) {
        if trimmed.len() == 10 {
            return format!("{trimmed}T00:00:00Z");
        }
        let mut normalized = trimmed.replacen(' ', "T", 1);
        if !has_timezone(&normalized) {
            normalized.push('Z');
        }
        return normalized;
    }
    trimmed.to_owned()
}

fn date_key(timestamp: &str) -> String {
    if timestamp.len() >= 10 && is_yyyy_mm_dd(&timestamp[..10]) {
        timestamp[..10].replace('-', "")
    } else {
        slug(timestamp)
    }
}

fn has_timezone(value: &str) -> bool {
    value.ends_with('Z')
        || value
            .rsplit_once(['+', '-'])
            .is_some_and(|(_, offset)| offset.len() >= 5 && offset.as_bytes().get(2) == Some(&b':'))
}

fn is_yyyy_mm_dd(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 10
        && bytes[0..4].iter().all(u8::is_ascii_digit)
        && bytes[4] == b'-'
        && bytes[5..7].iter().all(u8::is_ascii_digit)
        && bytes[7] == b'-'
        && bytes[8..10].iter().all(u8::is_ascii_digit)
}

fn detect_delimiter(text: &str) -> char {
    let first_line = text.lines().next().unwrap_or_default();
    if first_line.matches('\t').count() > first_line.matches(',').count() {
        '\t'
    } else {
        ','
    }
}

fn parse_delimited_records(text: &str, delimiter: char) -> Result<Vec<Vec<String>>> {
    let mut records = Vec::new();
    let mut record = Vec::new();
    let mut field = String::new();
    let mut chars = text.chars().peekable();
    let mut in_quotes = false;

    while let Some(ch) = chars.next() {
        if in_quotes {
            if ch == '"' {
                if chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    in_quotes = false;
                }
            } else {
                field.push(ch);
            }
            continue;
        }

        if ch == '"' && field.is_empty() {
            in_quotes = true;
        } else if ch == delimiter {
            record.push(std::mem::take(&mut field));
        } else if ch == '\n' {
            record.push(std::mem::take(&mut field));
            records.push(std::mem::take(&mut record));
        } else if ch == '\r' {
            if chars.peek() == Some(&'\n') {
                chars.next();
            }
            record.push(std::mem::take(&mut field));
            records.push(std::mem::take(&mut record));
        } else {
            field.push(ch);
        }
    }

    if in_quotes {
        return Err(import_error("unterminated quoted field"));
    }
    if !field.is_empty() || !record.is_empty() {
        record.push(field);
        records.push(record);
    }
    Ok(records)
}

fn normalize_header(value: &str) -> String {
    let mut normalized = String::new();
    let mut last_was_separator = false;
    for ch in value.trim().chars() {
        if ch.is_ascii_alphanumeric() {
            normalized.push(ch.to_ascii_lowercase());
            last_was_separator = false;
        } else if !last_was_separator {
            normalized.push('_');
            last_was_separator = true;
        }
    }
    normalized.trim_matches('_').to_owned()
}

fn slug(value: &str) -> String {
    let mut slug = String::new();
    let mut last_was_separator = false;
    for ch in value.trim().chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch.to_ascii_lowercase());
            last_was_separator = false;
        } else if !last_was_separator && !slug.is_empty() {
            slug.push('_');
            last_was_separator = true;
        }
    }
    let slug = slug.trim_matches('_').to_owned();
    if slug.is_empty() {
        "unknown".into()
    } else {
        slug
    }
}

fn short_hash(value: &str) -> String {
    sha256_text(value)
        .trim_start_matches("sha256:")
        .chars()
        .take(12)
        .collect()
}

fn import_error(message: impl Into<String>) -> KnurledError {
    KnurledError::InvalidHistoryImport(message.into())
}

const DATE_COLUMNS: &[&str] = &[
    "date",
    "day",
    "started_at",
    "completed_at",
    "start_time",
    "end_time",
    "workout_date",
];
const SESSION_COLUMNS: &[&str] = &[
    "session",
    "session_title",
    "workout",
    "workout_title",
    "title",
    "name",
];
const SOURCE_SESSION_COLUMNS: &[&str] = &["source_workout_id", "workout_id", "hevy_workout_id"];
const EXERCISE_COLUMNS: &[&str] = &[
    "exercise",
    "exercise_title",
    "movement",
    "lift",
    "exercise_name",
];
const SET_COLUMNS: &[&str] = &["set", "set_index", "set_number"];
const SET_COUNT_COLUMNS: &[&str] = &["sets", "set_count"];
const REPS_COLUMNS: &[&str] = &["reps", "repetitions", "rep_count"];
const LOAD_COLUMNS: &[&str] = &["load", "weight", "weight_value"];
const LOAD_KG_COLUMNS: &[&str] = &["load_kg", "weight_kg", "kg"];
const LOAD_LB_COLUMNS: &[&str] = &["load_lb", "weight_lb", "lbs", "lb"];
const UNIT_COLUMNS: &[&str] = &["unit", "units", "weight_unit", "load_unit"];
const RPE_COLUMNS: &[&str] = &["rpe"];
const RIR_COLUMNS: &[&str] = &["rir", "reps_in_reserve"];
const SET_TYPE_COLUMNS: &[&str] = &["set_type", "type"];
const NOTES_COLUMNS: &[&str] = &["notes", "note", "description", "comments"];
const DURATION_COLUMNS: &[&str] = &["duration", "time"];
const DURATION_SECONDS_COLUMNS: &[&str] = &["duration_seconds", "duration_sec", "seconds"];
const DISTANCE_COLUMNS: &[&str] = &["distance"];
const DISTANCE_M_COLUMNS: &[&str] = &["distance_m", "meters"];
const DISTANCE_KM_COLUMNS: &[&str] = &["distance_km", "kilometers"];
const REST_SECONDS_COLUMNS: &[&str] = &["rest_seconds", "rest_sec"];
