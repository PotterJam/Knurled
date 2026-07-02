//! Suggested workout dates (RFC-0001 D4/D5).
//!
//! `suggested_date` is **derived, never stored**: the next workout falls on the
//! first weekday in `schedule.suggested_days` strictly after the latest dated
//! record, and a `Reschedule` marker pins it to the marker's date exactly. A
//! pure function of repo files — no "today" input — so generated `build/`
//! outputs stay deterministic (ADR 0006). With no records yet there is nothing
//! to anchor to and the date stays `None`.

use crate::record::{RecordKind, TrainingRecord, record_order};

/// Suggested ISO date (`YYYY-MM-DD`) for the next workout, per the rule above.
pub fn suggest_next_date(suggested_days: &[String], records: &[TrainingRecord]) -> Option<String> {
    let latest = records.iter().max_by(|a, b| record_order(a, b))?;
    if latest.kind == RecordKind::Reschedule {
        // A reschedule pins the next workout to the chosen day exactly.
        parse_date(&latest.date)?;
        return Some(latest.date.clone());
    }
    let anchor = parse_date(&latest.date)?;
    let training_days: Vec<u32> = suggested_days
        .iter()
        .filter_map(|day| weekday_index(day))
        .collect();
    if training_days.is_empty() {
        return None;
    }
    let anchor_days = days_from_civil(anchor);
    for offset in 1..=7 {
        let candidate = anchor_days + offset;
        if training_days.contains(&weekday_from_days(candidate)) {
            return Some(format_date(civil_from_days(candidate)));
        }
    }
    None
}

/// Number of distinct Monday-based calendar weeks that contain a workout
/// record dated strictly after `since` (or all workouts when `since` is
/// `None`). Drives the `deload_week` suggestion (RFC-0001 D6).
pub fn distinct_workout_weeks(records: &[TrainingRecord], since: Option<&str>) -> usize {
    let floor = since.and_then(parse_date).map(days_from_civil);
    let mut weeks = std::collections::BTreeSet::new();
    for record in records {
        if record.kind != RecordKind::Workout {
            continue;
        }
        let Some(date) = parse_date(&record.date) else {
            continue;
        };
        let days = days_from_civil(date);
        if floor.is_some_and(|floor| days <= floor) {
            continue;
        }
        // Days since epoch of a Thursday; shifting by 3 makes the division
        // boundary fall on Mondays.
        weeks.insert((days + 3).div_euclid(7));
    }
    weeks.len()
}

/// Parse `"YYYY-MM-DD"` into (year, month, day), rejecting shapes `split_date`
/// would reject and impossible calendar days.
pub(crate) fn parse_date(date: &str) -> Option<(i64, u32, u32)> {
    let mut parts = date.splitn(3, '-');
    let year: i64 = parts.next()?.parse().ok()?;
    let month: u32 = parts.next()?.parse().ok()?;
    let day: u32 = parts.next()?.parse().ok()?;
    if !(1..=12).contains(&month) || day == 0 || day > days_in_month(year, month) {
        return None;
    }
    Some((year, month, day))
}

fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ => {
            if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
                29
            } else {
                28
            }
        }
    }
}

/// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
fn days_from_civil((year, month, day): (i64, u32, u32)) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Inverse of [`days_from_civil`].
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if month <= 2 { y + 1 } else { y }, month, day)
}

/// Weekday for a days-since-epoch value: 0 = Monday … 6 = Sunday.
fn weekday_from_days(days: i64) -> u32 {
    (days + 3).rem_euclid(7) as u32
}

/// `"mon"`-style token (as authored in `suggested_days`) → Monday-based index.
fn weekday_index(day: &str) -> Option<u32> {
    match day.trim().to_ascii_lowercase().get(..3)? {
        "mon" => Some(0),
        "tue" => Some(1),
        "wed" => Some(2),
        "thu" => Some(3),
        "fri" => Some(4),
        "sat" => Some(5),
        "sun" => Some(6),
        _ => None,
    }
}

fn format_date((year, month, day): (i64, u32, u32)) -> String {
    format!("{year:04}-{month:02}-{day:02}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::LiftRecord;

    fn workout(id: &str, date: &str) -> TrainingRecord {
        TrainingRecord::workout(
            id,
            date,
            "a1",
            format!("{date}T10:00:00Z"),
            vec![LiftRecord::new("l1", "squat", "80kg", vec![5])],
        )
    }

    fn days() -> Vec<String> {
        ["mon", "wed", "fri"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    }

    #[test]
    fn no_records_means_no_date() {
        assert_eq!(suggest_next_date(&days(), &[]), None);
    }

    #[test]
    fn next_date_is_first_training_day_after_last_workout() {
        // 2026-06-29 is a Monday.
        let records = vec![workout("w1", "2026-06-29")];
        assert_eq!(
            suggest_next_date(&days(), &records).as_deref(),
            Some("2026-07-01")
        );
        // Friday → wraps the weekend to Monday.
        let records = vec![workout("w2", "2026-07-03")];
        assert_eq!(
            suggest_next_date(&days(), &records).as_deref(),
            Some("2026-07-06")
        );
        // Training on an off-day (Saturday) still finds Monday next.
        let records = vec![workout("w3", "2026-07-04")];
        assert_eq!(
            suggest_next_date(&days(), &records).as_deref(),
            Some("2026-07-06")
        );
    }

    #[test]
    fn latest_record_wins_not_file_order() {
        let records = vec![workout("w2", "2026-07-03"), workout("w1", "2026-06-29")];
        assert_eq!(
            suggest_next_date(&days(), &records).as_deref(),
            Some("2026-07-06")
        );
    }

    #[test]
    fn reschedule_marker_pins_the_date_exactly() {
        let records = vec![
            workout("w1", "2026-06-29"),
            TrainingRecord::reschedule_marker("2026-07-04", None),
        ];
        assert_eq!(
            suggest_next_date(&days(), &records).as_deref(),
            Some("2026-07-04")
        );
    }

    #[test]
    fn month_and_year_boundaries_roll_over() {
        // 2026-12-31 is a Thursday; next mon/wed/fri day is Friday 2027-01-01.
        let records = vec![workout("w1", "2026-12-31")];
        assert_eq!(
            suggest_next_date(&days(), &records).as_deref(),
            Some("2027-01-01")
        );
    }

    #[test]
    fn empty_or_bogus_suggested_days_yield_none() {
        let records = vec![workout("w1", "2026-06-29")];
        assert_eq!(suggest_next_date(&[], &records), None);
        assert_eq!(suggest_next_date(&["someday".to_owned()], &records), None);
    }

    #[test]
    fn distinct_weeks_count_calendar_weeks_not_sessions() {
        // Three workouts in one Monday-based week count once.
        let records = vec![
            workout("w1", "2026-06-29"),
            workout("w2", "2026-07-01"),
            workout("w3", "2026-07-03"),
            workout("w4", "2026-07-06"),
        ];
        assert_eq!(distinct_workout_weeks(&records, None), 2);
        assert_eq!(distinct_workout_weeks(&records, Some("2026-07-03")), 1);
    }
}
