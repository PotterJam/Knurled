//! Lean training record (ADR 0007).
//!
//! Logs are a human-facing record that the engine never replays. A month is one
//! pretty-printed JSON file at `logs/<yyyy>/<mm>.json` holding dated day records.
//! Each day is either a set of performed lifts, a program-boundary marker, or
//! both. Nothing in here pins replay metadata (hashes, prescriptions, plan
//! versions): the record stores *what happened*, and `state` is the source of
//! truth for *where you are* (see ADR 0007).
//!
//! This module is the single owner of the log format. Clients (CLI, workbench,
//! iOS) serialize and parse through here instead of hand-rolling JSON so the
//! shape cannot drift between platforms. A saved partial carries minimal resume
//! metadata (`status`, `session_id`, and per-lift `item_id`) so clients can
//! reopen it without reintroducing replay-ledger fields.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::error::{KnurledError, Result};
use crate::json::compact_pretty_json;
use crate::model::ActualSet;

/// One performed lift within a day: the exercise, the working weight it was done
/// at, and the reps achieved per set. Open, units-explicit metrics (`rpe`,
/// `rir`, later velocity — the surviving idea from ADR 0001) ride along as
/// optional keys and are ignored by the engine.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LiftRecord {
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
    pub fn new(exercise: impl Into<String>, weight: impl Into<String>, sets: Vec<u32>) -> Self {
        Self {
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

/// One dated entry in the record. A workout day carries `lifts`; a
/// program-boundary marker (decision 8 of ADR 0007) carries `program`; an entry
/// may carry both. The engine ignores `program` and `note` — they exist for the
/// human timeline, charts, and backtest segmentation.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DayRecord {
    /// ISO date, `"YYYY-MM-DD"`.
    pub date: String,
    /// Present for a saved in-progress workout.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    /// Rendered session id, e.g. `"a1"`. Present when `status` is `"partial"`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub saved_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    /// Human-facing program-boundary marker, e.g. `"531.basic"`. Present when
    /// this date starts a new program or marks a switch.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub lifts: Vec<LiftRecord>,
}

impl DayRecord {
    /// A workout day with performed lifts.
    pub fn workout(date: impl Into<String>, lifts: Vec<LiftRecord>) -> Self {
        Self {
            date: date.into(),
            status: None,
            session_id: None,
            saved_at: None,
            completed_at: None,
            program: None,
            note: None,
            lifts,
        }
    }

    /// A program-boundary marker (start of / switch to a program).
    pub fn program_marker(date: impl Into<String>, program: impl Into<String>) -> Self {
        Self {
            date: date.into(),
            status: None,
            session_id: None,
            saved_at: None,
            completed_at: None,
            program: Some(program.into()),
            note: None,
            lifts: Vec::new(),
        }
    }
}

/// One month of the record — the unit of a log file (`logs/<yyyy>/<mm>.json`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LogMonth {
    /// `"YYYY-MM"`.
    pub month: String,
    #[serde(default)]
    pub days: Vec<DayRecord>,
}

impl LogMonth {
    /// An empty month.
    pub fn new(month: impl Into<String>) -> Self {
        Self {
            month: month.into(),
            days: Vec::new(),
        }
    }

    /// Parse a month file's contents.
    pub fn parse(text: &str) -> Result<Self> {
        serde_json::from_str(text).map_err(KnurledError::from)
    }

    /// Serialize to the canonical pretty JSON written to disk (trailing newline,
    /// stable key order).
    pub fn to_pretty_json(&self) -> Result<String> {
        compact_pretty_json(self)
    }

    /// Insert a day, or replace the existing day with the same date. Days are
    /// kept sorted by date so the file — and replay-free backtest reads — stay
    /// chronological and Git-stable. Editing a day in place is a first-class
    /// operation in this model (ADR 0007): the record is mutable, single-author,
    /// and never a ledger.
    pub fn upsert_day(&mut self, day: DayRecord) {
        match self
            .days
            .iter()
            .position(|existing| existing.date == day.date)
        {
            Some(index) => self.days[index] = day,
            None => self.days.push(day),
        }
        self.days.sort_by(|left, right| left.date.cmp(&right.date));
    }
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

    fn squat_day() -> DayRecord {
        DayRecord::workout(
            "2026-06-24",
            vec![
                LiftRecord::new("squat", "82.5kg", vec![5, 5, 3]),
                LiftRecord {
                    note: Some("felt strong".into()),
                    ..LiftRecord::new("bench", "45kg", vec![10, 10, 8])
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
        month.upsert_day(squat_day());
        let text = month.to_pretty_json().unwrap();
        assert!(text.ends_with('\n'));
        // Lean shape: reps as a bare array, no replay scaffolding.
        assert!(text.contains("\"lifts\": [\n        { \"exercise\""));
        assert!(text.contains(r#"{ "exercise": "squat", "sets": [5, 5, 3], "weight": "82.5kg" }"#));
        assert!(!text.contains("\"sets\": [\n"));
        assert!(!text.contains("plan_hash"));
        assert!(!text.contains("rendered_session_hash"));
        let parsed = LogMonth::parse(&text).unwrap();
        assert_eq!(parsed, month);
    }

    #[test]
    fn upsert_replaces_same_date_and_keeps_sorted() {
        let mut month = LogMonth::new("2026-06");
        month.upsert_day(DayRecord::workout(
            "2026-06-26",
            vec![LiftRecord::new("deadlift", "100kg", vec![5])],
        ));
        month.upsert_day(squat_day()); // earlier date inserted after
        assert_eq!(
            month
                .days
                .iter()
                .map(|d| d.date.as_str())
                .collect::<Vec<_>>(),
            ["2026-06-24", "2026-06-26"]
        );

        // Editing the 24th in place replaces, does not duplicate.
        month.upsert_day(DayRecord::workout(
            "2026-06-24",
            vec![LiftRecord::new("squat", "82.5kg", vec![5, 5, 5])],
        ));
        assert_eq!(month.days.len(), 2);
        assert_eq!(month.days[0].lifts[0].sets, vec![5, 5, 5]);
    }

    #[test]
    fn program_marker_serializes_without_lifts() {
        let marker = DayRecord::program_marker("2026-06-26", "531.basic");
        let text = pretty_json(&marker).unwrap();
        assert!(text.contains("\"program\": \"531.basic\""));
        assert!(!text.contains("lifts"));
    }
}
