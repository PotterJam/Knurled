//! Lean training record (ADR 0007).
//!
//! Logs are a human-facing record that the engine never replays. A month is one
//! pretty-printed JSON file at `logs/<yyyy>/<mm>.json` holding session-grain records.
//! Each entry is either a workout or a program-boundary marker. Nothing in here
//! pins replay metadata (hashes, prescriptions, plan
//! versions): the record stores *what happened*, and `state` is the source of
//! truth for *where you are* (see ADR 0007).
//!
//! This module is the single owner of the log format. Clients (CLI, workbench,
//! iOS) serialize and parse through here instead of hand-rolling JSON so the
//! shape cannot drift between platforms. A saved partial carries minimal resume
//! metadata (`status`, `session_id`, and per-lift `item_id`) so clients can
//! reopen it without reintroducing replay-ledger fields.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::error::{KnurledError, Result};
use crate::json::{compact_pretty_json, sha256_text};
use crate::model::ActualSet;

pub const RECORD_FORMAT_VERSION: u32 = 1;

/// One performed lift within a workout record: the exercise and performed work
/// at, and the reps achieved per set. Open, units-explicit metrics (`rpe`,
/// (`rpe`, `rir`, later velocity — the surviving idea from ADR 0001) ride along as
/// optional keys and are ignored by the engine.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LiftRecord {
    pub lift_id: String,
    /// Rendered workout item id. Present for saved partials so clients can put
    /// recorded sets back onto the exact card when continuing later.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    pub exercise: String,
    /// Working weight as authored, e.g. `"82.5kg"`. Optional for bodyweight or
    /// metric-only efforts (a run interval carries metrics, not a weight).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub weight: Option<String>,
    /// Reps achieved per set, in order: `[5, 5, 3]`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sets: Vec<u32>,
    /// Optional per-set detail. Omitted for ordinary strength logs so the
    /// human-facing record stays compact; present when a set carries metrics
    /// such as RPE that cannot be represented by `sets` alone.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actual: Vec<ActualSet>,
    /// Free-form, units-explicit measured metrics for the lift. A richer
    /// per-set form is a future additive change; the keys here apply to the
    /// effort as a whole for now.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metrics: BTreeMap<String, String>,
    /// Human note, e.g. `"felt strong"`. Never read by the engine.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

impl LiftRecord {
    /// A plain strength lift: exercise, working weight, reps per set.
    pub fn new(
        lift_id: impl Into<String>,
        exercise: impl Into<String>,
        weight: impl Into<String>,
        sets: Vec<u32>,
    ) -> Self {
        Self {
            lift_id: lift_id.into(),
            item_id: None,
            exercise: exercise.into(),
            weight: Some(weight.into()),
            sets,
            actual: Vec::new(),
            metrics: BTreeMap::new(),
            note: None,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecordKind {
    Workout,
    ProgramMarker,
}

/// One independently identifiable entry in the human training record.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TrainingRecord {
    pub id: String,
    pub revision: u64,
    pub kind: RecordKind,
    pub date: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub saved_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub lifts: Vec<LiftRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AmendRecordRequest {
    pub record_id: String,
    pub expected_revision: u64,
    pub updated_at: String,
    #[serde(flatten)]
    pub amendment: RecordAmendment,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum RecordAmendment {
    AddSet {
        lift_id: String,
        load: Option<String>,
        reps: u32,
        #[serde(default)]
        metrics: BTreeMap<String, String>,
    },
    AddExercise {
        exercise: String,
        weight: Option<String>,
        note: Option<String>,
        sets: Vec<ActualSet>,
    },
    ReplaceLifts {
        lifts: Vec<LiftRecord>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AmendRecordOutcome {
    pub record: TrainingRecord,
    pub changed_files: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recomputed_lanes: Vec<String>,
}

impl TrainingRecord {
    pub fn workout(
        id: impl Into<String>,
        date: impl Into<String>,
        session_id: impl Into<String>,
        started_at: impl Into<String>,
        lifts: Vec<LiftRecord>,
    ) -> Self {
        let started_at = started_at.into();
        Self {
            id: id.into(),
            revision: 1,
            kind: RecordKind::Workout,
            date: date.into(),
            status: None,
            session_id: Some(session_id.into()),
            started_at: Some(started_at.clone()),
            saved_at: None,
            completed_at: Some(started_at),
            updated_at: None,
            program: None,
            note: None,
            lifts,
        }
    }

    pub fn program_marker(date: impl Into<String>, program: impl Into<String>) -> Self {
        let date = date.into();
        let program = program.into();
        Self {
            id: sha256_text(&format!("program_marker\0{date}\0{program}")),
            revision: 1,
            kind: RecordKind::ProgramMarker,
            date,
            status: None,
            session_id: None,
            started_at: None,
            saved_at: None,
            completed_at: None,
            updated_at: None,
            program: Some(program),
            note: None,
            lifts: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LogMonth {
    pub format_version: u32,
    pub month: String,
    pub records: Vec<TrainingRecord>,
}

impl LogMonth {
    /// An empty month.
    pub fn new(month: impl Into<String>) -> Self {
        Self {
            format_version: RECORD_FORMAT_VERSION,
            month: month.into(),
            records: Vec::new(),
        }
    }

    /// Parse a month file's contents.
    pub fn parse(text: &str) -> Result<Self> {
        let month: Self = serde_json::from_str(text).map_err(KnurledError::from)?;
        if month.format_version != RECORD_FORMAT_VERSION {
            return Err(KnurledError::Parse(format!(
                "unsupported training record format version {}",
                month.format_version
            )));
        }
        month.validate()?;
        Ok(month)
    }

    /// Serialize to the canonical pretty JSON written to disk (trailing newline,
    /// stable key order).
    pub fn to_pretty_json(&self) -> Result<String> {
        self.validate()?;
        compact_pretty_json(self)
    }

    pub fn put_record(&mut self, mut record: TrainingRecord) {
        match self
            .records
            .iter()
            .position(|existing| existing.id == record.id)
        {
            Some(index) => {
                record.revision = self.records[index].revision + 1;
                self.records[index] = record;
            }
            None => self.records.push(record),
        }
        self.records.sort_by(record_order);
    }

    fn validate(&self) -> Result<()> {
        let mut ids = BTreeSet::new();
        for record in &self.records {
            if record.id.is_empty() || record.revision == 0 {
                return Err(KnurledError::Parse(
                    "training records require a non-empty id and positive revision".into(),
                ));
            }
            if !ids.insert(&record.id) {
                return Err(KnurledError::Parse(format!(
                    "duplicate training record id {:?}",
                    record.id
                )));
            }
            if month_key(&record.date)? != self.month {
                return Err(KnurledError::Parse(format!(
                    "training record {:?} does not belong to month {}",
                    record.id, self.month
                )));
            }
            if record.lifts.iter().any(|lift| lift.lift_id.is_empty()) {
                return Err(KnurledError::Parse(format!(
                    "training record {:?} contains a lift without lift_id",
                    record.id
                )));
            }
            match record.kind {
                RecordKind::Workout => {
                    if record.session_id.as_deref().is_none_or(str::is_empty)
                        || record.started_at.as_deref().is_none_or(str::is_empty)
                    {
                        return Err(KnurledError::Parse(format!(
                            "workout record {:?} requires session_id and started_at",
                            record.id
                        )));
                    }
                    if record.status.as_deref() == Some("partial") {
                        if record.saved_at.as_deref().is_none_or(str::is_empty) {
                            return Err(KnurledError::Parse(format!(
                                "partial workout record {:?} requires saved_at",
                                record.id
                            )));
                        }
                    } else if record.status.is_some()
                        || record.completed_at.as_deref().is_none_or(str::is_empty)
                    {
                        return Err(KnurledError::Parse(format!(
                            "completed workout record {:?} requires completed_at and no status",
                            record.id
                        )));
                    }
                }
                RecordKind::ProgramMarker => {
                    if record.program.as_deref().is_none_or(str::is_empty)
                        || !record.lifts.is_empty()
                        || record.session_id.is_some()
                    {
                        return Err(KnurledError::Parse(format!(
                            "program marker {:?} has invalid workout fields",
                            record.id
                        )));
                    }
                }
            }
        }
        Ok(())
    }
}

pub fn workout_record_id(rendered_session_hash: &str, started_at: &str) -> String {
    sha256_text(&format!("workout\0{rendered_session_hash}\0{started_at}"))
}

pub fn lift_record_id(record_id: &str, item_id: &str) -> String {
    sha256_text(&format!("lift\0{record_id}\0{item_id}"))
}

pub fn record_order(left: &TrainingRecord, right: &TrainingRecord) -> std::cmp::Ordering {
    let left_time = left
        .started_at
        .as_deref()
        .or(left.completed_at.as_deref())
        .or(left.saved_at.as_deref())
        .unwrap_or_default();
    let right_time = right
        .started_at
        .as_deref()
        .or(right.completed_at.as_deref())
        .or(right.saved_at.as_deref())
        .unwrap_or_default();
    left.date
        .cmp(&right.date)
        .then_with(|| left_time.cmp(right_time))
        .then_with(|| left.id.cmp(&right.id))
}

/// `"YYYY-MM"` month key for an ISO date. Used to pick the log file a day
/// belongs to.
pub fn month_key(date: &str) -> Result<String> {
    let (year, month, _day) = split_date(date)?;
    Ok(format!("{year}-{month}"))
}

/// Repo-relative path of the log file that owns a given ISO date:
/// `logs/<yyyy>/<mm>.json`.
pub fn month_path(date: &str) -> Result<String> {
    let (year, month, _day) = split_date(date)?;
    Ok(format!("logs/{year}/{month}.json"))
}

/// Split `"YYYY-MM-DD"` into its zero-padded parts, rejecting anything that is
/// not a plausible ISO date. We validate shape, not calendar validity.
fn split_date(date: &str) -> Result<(&str, &str, &str)> {
    let mut parts = date.splitn(3, '-');
    let year = parts.next().unwrap_or_default();
    let month = parts.next().unwrap_or_default();
    let day = parts.next().unwrap_or_default();
    let ok = year.len() == 4
        && month.len() == 2
        && day.len() == 2
        && [year, month, day]
            .iter()
            .all(|part| part.bytes().all(|byte| byte.is_ascii_digit()));
    if !ok {
        return Err(KnurledError::Parse(format!(
            "expected an ISO date YYYY-MM-DD, got {date:?}"
        )));
    }
    Ok((year, month, day))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::pretty_json;

    fn squat_record(id: &str, started_at: &str) -> TrainingRecord {
        TrainingRecord::workout(
            id,
            "2026-06-24",
            "a1",
            started_at,
            vec![
                LiftRecord::new("squat-lift", "squat", "82.5kg", vec![5, 5, 3]),
                LiftRecord {
                    note: Some("felt strong".into()),
                    ..LiftRecord::new("bench-lift", "bench", "45kg", vec![10, 10, 8])
                },
            ],
        )
    }

    #[test]
    fn month_path_and_key_derive_from_date() {
        assert_eq!(month_path("2026-06-24").unwrap(), "logs/2026/06.json");
        assert_eq!(month_key("2026-06-24").unwrap(), "2026-06");
    }

    #[test]
    fn bad_dates_are_rejected() {
        for bad in ["2026-6-24", "2026/06/24", "not-a-date", "2026-06", ""] {
            assert!(month_path(bad).is_err(), "{bad:?} should be rejected");
        }
    }

    #[test]
    fn pretty_json_round_trips() {
        let mut month = LogMonth::new("2026-06");
        month.put_record(squat_record("workout-a", "2026-06-24T10:00:00Z"));
        let text = month.to_pretty_json().unwrap();
        assert!(text.ends_with('\n'));
        assert!(text.contains("\"format_version\": 1"));
        assert!(text.contains("\"records\""));
        assert!(!text.contains("\"sets\": [\n"));
        assert!(!text.contains("plan_hash"));
        assert!(!text.contains("rendered_session_hash"));
        let parsed = LogMonth::parse(&text).unwrap();
        assert_eq!(parsed, month);
    }

    #[test]
    fn records_are_identified_by_id_not_date() {
        let mut month = LogMonth::new("2026-06");
        month.put_record(squat_record("workout-a", "2026-06-24T10:00:00Z"));
        month.put_record(squat_record("workout-b", "2026-06-24T14:00:00Z"));
        month.put_record(TrainingRecord::program_marker("2026-06-24", "gzcl.gzclp"));
        assert_eq!(month.records.len(), 3);

        let mut revised = squat_record("workout-a", "2026-06-24T10:00:00Z");
        revised.lifts[0].sets = vec![5, 5, 5];
        month.put_record(revised);
        assert_eq!(month.records.len(), 3);
        let revised = month
            .records
            .iter()
            .find(|record| record.id == "workout-a")
            .unwrap();
        assert_eq!(revised.revision, 2);
        assert_eq!(revised.lifts[0].sets, vec![5, 5, 5]);
    }

    #[test]
    fn program_marker_serializes_without_lifts() {
        let marker = TrainingRecord::program_marker("2026-06-26", "531.basic");
        let text = pretty_json(&marker).unwrap();
        assert!(text.contains("\"program\": \"531.basic\""));
        assert!(!text.contains("lifts"));
    }

    #[test]
    fn deleted_day_record_format_is_rejected() {
        let old = r#"{"month":"2026-06","days":[]}"#;
        assert!(LogMonth::parse(old).is_err());
    }
}
