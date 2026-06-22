use regex::Regex;

// Parser roadmap for humans and future agents:
// This file is a bootstrap parser for the tiny MVP FitSpec surface. It was kept
// hand-written to avoid over-designing syntax while the domain model was still
// moving. Do not grow this into the real language parser. The intended next
// parser is `winnow`: FitSpec is block-oriented, and winnow gives Rust-native
// parser combinators, local parsing functions, spans, diagnostics, and an
// incremental migration path. Use lalrpop only if FitSpec later becomes
// expression-heavy enough to justify a generated grammar.

use crate::model::{
    ExerciseAlternative, ExerciseOptions, LockEntry, Lockfile, Map, Patch, PatchOperation, Plan,
    RestPolicy, SCHEMA_VERSION, Schedule, SwapPolicy, Units,
};
use crate::templates::parse_template_ref;

pub fn parse_plan(text: &str) -> Plan {
    let name = first_capture(text, r#"plan\s+"([^"]+)""#).unwrap_or_else(|| "Untitled Plan".into());
    let template = first_capture(text, r#"template\s+"([^"]+)""#)
        .map(|item| parse_template_ref(&item).normalized)
        .unwrap_or_else(|| "gzclp.standard@1.0.0".into());
    let units = match first_capture(text, r"\bunits\s+(kg|lb)\b")
        .unwrap_or_else(|| "kg".into())
        .to_ascii_lowercase()
        .as_str()
    {
        "lb" => Units::Lb,
        _ => Units::Kg,
    };

    let schedule_block = extract_block(text, "schedule next_workout").unwrap_or_default();
    let starts_block = extract_block(text, "starts").unwrap_or_default();
    let training_maxes_block = extract_block(text, "training_maxes").unwrap_or_default();
    let accessories_block = extract_block(text, "accessories").unwrap_or_default();
    let exercise_options_block = extract_block(text, "exercise_options").unwrap_or_default();
    let rest_block = extract_block(text, "rest").unwrap_or_default();

    Plan {
        kind: "fitspec_plan".into(),
        schema_version: SCHEMA_VERSION.into(),
        name,
        template,
        units,
        schedule: Schedule {
            mode: "next_workout".into(),
            rotation: parse_list_line(&schedule_block, "rotation"),
            suggested_days: parse_list_line(&schedule_block, "suggested_days"),
        },
        starts: normalize_lift_map(parse_key_value_block(&starts_block)),
        training_maxes: normalize_lift_map(parse_key_value_block(&training_maxes_block)),
        accessories: normalize_accessory_map(parse_key_value_block(&accessories_block)),
        exercise_options: parse_exercise_options(&exercise_options_block),
        rest: parse_rest_policy(&rest_block),
    }
}

pub fn parse_lock(text: &str) -> Lockfile {
    let mut templates = Map::new();
    let section_re = Regex::new(r#"(?s)\[templates\."([^"]+)"\](.*?)(?:\n\[|$)"#).unwrap();
    for capture in section_re.captures_iter(text) {
        let id = capture[1].to_owned();
        let body = capture.get(2).map(|m| m.as_str()).unwrap_or_default();
        let pairs = parse_toml_pairs(body);
        templates.insert(
            id,
            LockEntry {
                version: pairs.get("version").cloned().unwrap_or_default(),
                source: pairs.get("source").cloned().unwrap_or_default(),
                content_hash: pairs.get("content_hash").cloned().unwrap_or_default(),
                engine_version: pairs.get("engine_version").cloned().unwrap_or_default(),
            },
        );
    }

    Lockfile {
        kind: "fitspec_lock".into(),
        schema_version: SCHEMA_VERSION.into(),
        templates,
    }
}

pub fn parse_patch(text: &str, filename: impl Into<String>) -> Patch {
    let filename = filename.into();
    let name = first_capture(text, r#"patch\s+"([^"]+)""#)
        .unwrap_or_else(|| filename.trim_end_matches(".fitspec").to_owned());
    let description = first_capture(text, r#"description\s+"([^"]+)""#).unwrap_or_default();
    let active_from = first_capture(text, r"\bactive\s+from\s+([0-9-]+)");
    let expires = first_capture(text, r"\bexpires\s+([0-9-]+)");
    let mut operations = Vec::new();

    let replace_re = Regex::new(
        r#"^replace\s+exercise\s+([A-Za-z0-9_]+)\s+with\s+([A-Za-z0-9_]+)\s+where\s+lane\s+matches\s+"([^"]+)""#,
    )
    .unwrap();
    let conditioning_re =
        Regex::new(r#"^add\s+conditioning\s+([A-Za-z]+)\s*\{\s*([^}]+)\s*\}"#).unwrap();
    let cap_re =
        Regex::new(r#"^cap\s+(.+?)\s+(?:at\s+)?(.+?)(?:\s+where\s+lane\s+matches\s+"([^"]+)")?$"#)
            .unwrap();

    for raw in without_comments(text).lines() {
        let line = raw.trim();
        if line.is_empty() || line == "{" || line == "}" || line.starts_with("patch ") {
            continue;
        }
        if let Some(capture) = replace_re.captures(line) {
            operations.push(PatchOperation::ReplaceExercise {
                from: normalize_exercise(&capture[1]),
                to: normalize_exercise(&capture[2]),
                lane_regex: capture[3].to_owned(),
            });
        } else if let Some(capture) = conditioning_re.captures(line) {
            operations.push(PatchOperation::AddConditioning {
                day: capture[1].to_ascii_lowercase(),
                activity: capture[2].trim().to_owned(),
            });
        } else if let Some(capture) = cap_re.captures(line).filter(|_| line.starts_with("cap ")) {
            operations.push(PatchOperation::Cap {
                target: capture[1].trim().to_owned(),
                value: capture[2].trim().to_owned(),
                lane_regex: capture.get(3).map(|m| m.as_str().to_owned()),
            });
        } else if matches!(
            line.split_whitespace().next(),
            Some("add" | "cap" | "block" | "change" | "enable" | "disable" | "temporary")
        ) {
            operations.push(PatchOperation::Raw {
                text: line.to_owned(),
            });
        }
    }

    Patch {
        kind: "fitspec_patch".into(),
        schema_version: SCHEMA_VERSION.into(),
        name,
        filename,
        description,
        active_from,
        expires,
        operations,
    }
}

fn first_capture(text: &str, pattern: &str) -> Option<String> {
    Regex::new(pattern)
        .ok()?
        .captures(text)
        .and_then(|capture| capture.get(1))
        .map(|capture| capture.as_str().trim().to_owned())
}

fn without_comments(text: &str) -> String {
    text.lines()
        .map(|line| line.split_once('#').map(|(left, _)| left).unwrap_or(line))
        .collect::<Vec<_>>()
        .join("\n")
}

fn extract_block(text: &str, marker: &str) -> Option<String> {
    let text = without_comments(text);
    let marker_index = text.find(marker)?;
    let open = text[marker_index..].find('{')? + marker_index;
    let mut depth = 1;
    for (offset, ch) in text[open + 1..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    let close = open + 1 + offset;
                    return Some(text[open + 1..close].to_owned());
                }
            }
            _ => {}
        }
    }
    Some(text[open + 1..].to_owned())
}

fn parse_list_line(block: &str, key: &str) -> Vec<String> {
    block
        .lines()
        .find_map(|line| {
            let line = line.trim();
            line.strip_prefix(key).map(|value| {
                value
                    .split([',', ' ', '\t'])
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
            })
        })
        .into_iter()
        .flatten()
        .map(|item| item.to_ascii_lowercase())
        .collect()
}

fn parse_key_value_block(block: &str) -> Map<String> {
    block
        .lines()
        .filter_map(|line| {
            let mut parts = line.trim().splitn(2, char::is_whitespace);
            let key = parts.next()?.trim();
            let value = parts.next()?.trim().trim_end_matches(',');
            (!key.is_empty() && !value.is_empty()).then(|| (key.to_owned(), value.to_owned()))
        })
        .collect()
}

fn parse_toml_pairs(block: &str) -> Map<String> {
    let pair_re = Regex::new(r#"^([A-Za-z0-9_.-]+)\s*=\s*"([^"]*)"\s*$"#).unwrap();
    block
        .lines()
        .filter_map(|line| {
            let capture = pair_re.captures(line.trim())?;
            Some((capture[1].to_owned(), capture[2].to_owned()))
        })
        .collect()
}

fn parse_exercise_options(block: &str) -> Map<ExerciseOptions> {
    let slot_re = Regex::new(r#"(?s)slot\s+"([^"]+)"\s*\{(.*?)\n\s*\}"#).unwrap();
    let alt_re = Regex::new(r#"(?s)([A-Za-z0-9_]+)\s*\{(.*?)\}"#).unwrap();
    let mut options = Map::new();

    for slot_capture in slot_re.captures_iter(block) {
        let slot_id = slot_capture[1].to_ascii_lowercase();
        let slot_block = slot_capture[2].to_owned();
        let primary = first_capture(&slot_block, r"\bprimary\s+([A-Za-z0-9_]+)")
            .map(|item| normalize_exercise(&item))
            .unwrap_or_default();
        let alternatives = alt_re
            .captures_iter(&slot_block)
            .filter_map(|capture| {
                let option_id = normalize_exercise(&capture[1]);
                (option_id != "alternatives").then(|| ExerciseAlternative {
                    option_id: option_id.clone(),
                    exercise: option_id,
                    label: first_capture(&capture[2], r#"label\s+"([^"]+)""#)
                        .unwrap_or_else(|| capture[1].to_owned()),
                    policy: match first_capture(&capture[2], r"\bpolicy\s+([A-Za-z0-9_]+)")
                        .unwrap_or_else(|| "tracking_only".into())
                        .as_str()
                    {
                        "progression_equivalent" => SwapPolicy::ProgressionEquivalent,
                        _ => SwapPolicy::TrackingOnly,
                    },
                })
            })
            .collect();
        options.insert(
            slot_id,
            ExerciseOptions {
                primary,
                alternatives,
            },
        );
    }

    options
}

fn parse_rest_policy(block: &str) -> RestPolicy {
    let mut policy = RestPolicy::default();

    let clean = without_comments(block);
    for raw in clean.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }

        let parts = line.split_whitespace().collect::<Vec<_>>();
        let Some(raw_scope) = parts.first() else {
            continue;
        };
        let scope = raw_scope.to_ascii_lowercase();

        if scope == "default" {
            if let Some(seconds) = parse_rest_seconds(&parts[1..]) {
                policy.default_seconds = Some(seconds);
            }
            continue;
        }

        let Some(key) = parts.get(1) else {
            continue;
        };
        let rest = parts.get(2..).unwrap_or_default();
        let Some(seconds) = parse_rest_seconds(rest) else {
            continue;
        };
        let key = normalize_rest_key(&scope, key);

        match scope.as_str() {
            "tier" => {
                policy.by_tier.insert(key, seconds);
            }
            "slot" => {
                policy.by_slot.insert(key, seconds);
            }
            "lane" => {
                policy.by_lane.insert(key, seconds);
            }
            "exercise" => {
                policy.by_exercise.insert(key, seconds);
            }
            _ => {}
        }
    }

    policy
}

fn parse_rest_seconds(parts: &[&str]) -> Option<u32> {
    let value = parts.first()?.trim().to_ascii_lowercase();
    let unit = parts.get(1).map(|item| item.trim().to_ascii_lowercase());

    if let Some(unit) = unit
        && let Some(seconds) = parse_rest_seconds_with_unit(&value, &unit)
    {
        return Some(seconds);
    }

    parse_rest_seconds_value(&value)
}

fn parse_rest_seconds_with_unit(value: &str, unit: &str) -> Option<u32> {
    match unit {
        "s" | "sec" | "secs" | "second" | "seconds" => parse_duration_number(value),
        "m" | "min" | "mins" | "minute" | "minutes" => {
            parse_duration_number(value).and_then(|minutes| minutes.checked_mul(60))
        }
        _ => None,
    }
}

fn parse_rest_seconds_value(value: &str) -> Option<u32> {
    if let Some((minutes, seconds)) = value.split_once(':') {
        return parse_duration_number(minutes)
            .and_then(|minutes| minutes.checked_mul(60))
            .and_then(|total| total.checked_add(parse_duration_number(seconds)?));
    }

    for suffix in ["seconds", "second", "secs", "sec", "s"] {
        if let Some(value) = value.strip_suffix(suffix) {
            return parse_duration_number(value);
        }
    }

    for suffix in ["minutes", "minute", "mins", "min", "m"] {
        if let Some(value) = value.strip_suffix(suffix) {
            return parse_duration_number(value).and_then(|minutes| minutes.checked_mul(60));
        }
    }

    parse_duration_number(value)
}

fn parse_duration_number(value: &str) -> Option<u32> {
    value.trim().parse().ok()
}

fn normalize_rest_key(scope: &str, key: &str) -> String {
    match scope {
        "tier" | "slot" | "lane" => key.to_ascii_lowercase(),
        "exercise" => normalize_exercise(key),
        _ => key.to_owned(),
    }
}

fn normalize_lift_map(values: Map<String>) -> Map<String> {
    values
        .into_iter()
        .map(|(key, value)| (normalize_exercise(&key), value))
        .collect()
}

fn normalize_accessory_map(values: Map<String>) -> Map<String> {
    values
        .into_iter()
        .map(|(key, value)| (key.to_ascii_uppercase(), normalize_exercise(&value)))
        .collect()
}

pub fn normalize_exercise(value: &str) -> String {
    value
        .trim()
        .to_ascii_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("_")
}
