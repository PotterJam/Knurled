use winnow::Result as ParseResult;
use winnow::ascii::{space0, space1};
use winnow::combinator::{delimited, opt, preceded};
use winnow::error::ContextError;
use winnow::prelude::*;
use winnow::token::{take_till, take_while};

// Parser roadmap for humans and future agents:
// FitSpec is now parsed with `winnow` rather than the original bootstrap
// regex/block parser. Keep new syntax as local, named parser functions so the
// DSL remains readable here. The parser is strict: syntax errors are surfaced
// through the engine Result path instead of being converted into defaults.

use crate::error::{KnurledError, Result};
use crate::model::{
    ExerciseAlternative, ExerciseOptions, LockEntry, Lockfile, Map, Patch, PatchOperation, Plan,
    RestPolicy, SCHEMA_VERSION, Schedule, SwapPolicy, Units,
};
use crate::templates::parse_template_ref;

type MarkerParser = fn(&mut &str) -> ParseResult<()>;

pub fn parse_plan(text: &str) -> Result<Plan> {
    let clean = without_comments(text);
    let (name, body) = extract_required_named_block(&clean, plan_header, "plan")?;
    validate_plan_body(&body)?;

    let template = find_unique_line(&body, template_directive, "template")?
        .map(|item| parse_template_ref(&item).normalized)
        .ok_or_else(|| parse_error("plan is missing required template directive"))?;
    let units = find_unique_line(&body, units_directive, "units")?
        .ok_or_else(|| parse_error("plan is missing required units directive"))?;

    let schedule_block = extract_optional_unique_block(&body, schedule_marker, "schedule")?;
    let starts_block = extract_optional_unique_block(&body, starts_marker, "starts")?;
    let training_maxes_block =
        extract_optional_unique_block(&body, training_maxes_marker, "training_maxes")?;
    let accessories_block =
        extract_optional_unique_block(&body, accessories_marker, "accessories")?;
    let exercise_options_block =
        extract_optional_unique_block(&body, exercise_options_marker, "exercise_options")?;
    let rest_block = extract_optional_unique_block(&body, rest_marker, "rest")?;

    Ok(Plan {
        kind: "fitspec_plan".into(),
        schema_version: SCHEMA_VERSION.into(),
        name,
        template,
        units,
        schedule: Schedule {
            mode: "next_workout".into(),
            rotation: parse_list_line(&schedule_block, "rotation")?,
            suggested_days: parse_list_line(&schedule_block, "suggested_days")?,
        },
        starts: normalize_lift_map(parse_key_value_block(&starts_block, "starts")?),
        training_maxes: normalize_lift_map(parse_key_value_block(
            &training_maxes_block,
            "training_maxes",
        )?),
        accessories: normalize_accessory_map(parse_key_value_block(
            &accessories_block,
            "accessories",
        )?),
        exercise_options: parse_exercise_options(&exercise_options_block)?,
        rest: parse_rest_policy(&rest_block)?,
    })
}

pub fn parse_lock(text: &str) -> Result<Lockfile> {
    let clean = without_comments(text);
    let mut templates = Map::new();
    let mut current_id: Option<String> = None;
    let mut current_pairs = Map::new();

    for (index, line) in clean.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(id) = parse_line(line, template_section) {
            insert_lock_entry(&mut templates, current_id.take(), &current_pairs);
            current_pairs.clear();
            current_id = Some(id);
        } else if current_id.is_some()
            && let Some((key, value)) = parse_line(line, toml_pair)
        {
            current_pairs.insert(key, value);
        } else {
            return Err(parse_error(format!(
                "invalid lockfile syntax at line {}: {line}",
                index + 1
            )));
        }
    }
    insert_lock_entry(&mut templates, current_id, &current_pairs);

    Ok(Lockfile {
        kind: "fitspec_lock".into(),
        schema_version: SCHEMA_VERSION.into(),
        templates,
    })
}

pub fn parse_patch(text: &str, filename: impl Into<String>) -> Result<Patch> {
    let filename = filename.into();
    let clean = without_comments(text);
    let (name, body) = extract_required_named_block(&clean, patch_header, "patch")?;
    let description =
        find_unique_line(&body, description_directive, "description")?.unwrap_or_default();
    let active_from = find_unique_line(&body, active_from_directive, "active from")?;
    let expires = find_unique_line(&body, expires_directive, "expires")?;
    let mut operations = Vec::new();

    for (index, raw) in body.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if parse_line(line, description_directive).is_some()
            || parse_line(line, active_from_directive).is_some()
            || parse_line(line, expires_directive).is_some()
        {
            continue;
        } else if let Some(operation) = parse_line(line, patch_operation) {
            operations.push(operation);
        } else {
            return Err(parse_error(format!(
                "invalid patch syntax in {filename} at line {}: {line}",
                index + 1
            )));
        }
    }

    Ok(Patch {
        kind: "fitspec_patch".into(),
        schema_version: SCHEMA_VERSION.into(),
        name,
        filename,
        description,
        active_from,
        expires,
        operations,
    })
}

fn parse_line<T>(line: &str, parser: fn(&mut &str) -> ParseResult<T>) -> Option<T> {
    let mut input = line.trim();
    let output = parser(&mut input).ok()?;
    input.trim().is_empty().then_some(output)
}

fn find_line<T>(text: &str, parser: fn(&mut &str) -> ParseResult<T>) -> Option<T> {
    text.lines().find_map(|line| parse_line(line, parser))
}

fn find_unique_line<T>(
    text: &str,
    parser: fn(&mut &str) -> ParseResult<T>,
    label: &str,
) -> Result<Option<T>> {
    let mut found = None;
    for line in text.lines() {
        let Some(value) = parse_line(line, parser) else {
            continue;
        };
        if found.is_some() {
            return Err(parse_error(format!("duplicate {label} directive")));
        }
        found = Some(value);
    }
    Ok(found)
}

fn find_in_text<T>(text: &str, parser: fn(&mut &str) -> ParseResult<T>) -> Option<T> {
    text.char_indices().find_map(|(offset, _)| {
        let mut input = &text[offset..];
        parser(&mut input).ok()
    })
}

fn without_comments(text: &str) -> String {
    text.lines()
        .map(|line| line.split_once('#').map(|(left, _)| left).unwrap_or(line))
        .collect::<Vec<_>>()
        .join("\n")
}

fn parse_error(message: impl Into<String>) -> KnurledError {
    KnurledError::Parse(message.into())
}

fn extract_required_named_block<T>(
    text: &str,
    parser: fn(&mut &str) -> ParseResult<T>,
    label: &str,
) -> Result<(T, String)> {
    let start = text
        .find(|ch: char| !ch.is_whitespace())
        .ok_or_else(|| parse_error(format!("missing {label} block")))?;
    let mut input = &text[start..];
    let name = parser(&mut input).map_err(|_| parse_error(format!("invalid {label} header")))?;
    let marker_end = text.len().saturating_sub(input.len());
    let (body, close) = extract_block_at(text, marker_end, label)?;
    if !text[close + 1..].trim().is_empty() {
        return Err(parse_error(format!(
            "unexpected content after closing {label} block"
        )));
    }
    Ok((name, body))
}

fn plan_header(input: &mut &str) -> ParseResult<String> {
    quoted_after_keyword(input, "plan")
}

fn patch_header(input: &mut &str) -> ParseResult<String> {
    quoted_after_keyword(input, "patch")
}

fn template_directive(input: &mut &str) -> ParseResult<String> {
    quoted_after_keyword(input, "template")
}

fn description_directive(input: &mut &str) -> ParseResult<String> {
    quoted_after_keyword(input, "description")
}

fn units_directive(input: &mut &str) -> ParseResult<Units> {
    keyword_with_space(input, "units")?;
    let unit = bare_word(input)?;
    Ok(match unit.to_ascii_lowercase().as_str() {
        "lb" => Units::Lb,
        _ => Units::Kg,
    })
}

fn active_from_directive(input: &mut &str) -> ParseResult<String> {
    keyword_with_space(input, "active")?;
    keyword(input, "from")?;
    space1.parse_next(input)?;
    date_token(input)
}

fn expires_directive(input: &mut &str) -> ParseResult<String> {
    keyword_with_space(input, "expires")?;
    date_token(input)
}

fn quoted_after_keyword(input: &mut &str, word: &'static str) -> ParseResult<String> {
    keyword_with_space(input, word)?;
    quoted_string(input)
}

fn keyword_with_space(input: &mut &str, word: &'static str) -> ParseResult<()> {
    marker_word(input, word)?;
    space1.parse_next(input)?;
    Ok(())
}

fn keyword(input: &mut &str, mut word: &'static str) -> ParseResult<()> {
    word.parse_next(input)?;
    Ok(())
}

fn quoted_string(input: &mut &str) -> ParseResult<String> {
    delimited('"', take_till(0.., '"'), '"')
        .map(str::to_owned)
        .parse_next(input)
}

fn date_token(input: &mut &str) -> ParseResult<String> {
    take_while(1.., |ch: char| ch.is_ascii_digit() || ch == '-')
        .map(str::to_owned)
        .parse_next(input)
}

fn bare_word<'s>(input: &mut &'s str) -> ParseResult<&'s str> {
    take_while(1.., |ch: char| {
        !ch.is_whitespace() && ch != '{' && ch != '}' && ch != ','
    })
    .parse_next(input)
}

fn exercise_identifier<'s>(input: &mut &'s str) -> ParseResult<&'s str> {
    take_while(1.., |ch: char| ch.is_ascii_alphanumeric() || ch == '_').parse_next(input)
}

fn line_value(input: &mut &str) -> ParseResult<String> {
    take_till(0.., |ch| ch == '\r' || ch == '\n')
        .map(|value: &str| value.trim().trim_end_matches(',').trim().to_owned())
        .parse_next(input)
}

fn key_value_line(input: &mut &str) -> ParseResult<(String, String)> {
    space0.parse_next(input)?;
    let key = bare_word(input)?;
    space1.parse_next(input)?;
    let value = line_value(input)?;
    if value.is_empty() {
        fail(input)
    } else {
        Ok((key.to_owned(), value))
    }
}

fn template_section(input: &mut &str) -> ParseResult<String> {
    space0.parse_next(input)?;
    '['.parse_next(input)?;
    "templates.".parse_next(input)?;
    let id = quoted_string(input)?;
    ']'.parse_next(input)?;
    Ok(id)
}

fn toml_pair(input: &mut &str) -> ParseResult<(String, String)> {
    space0.parse_next(input)?;
    let key = take_while(1.., |ch: char| {
        ch.is_ascii_alphanumeric() || ch == '_' || ch == '.' || ch == '-'
    })
    .parse_next(input)?;
    space0.parse_next(input)?;
    '='.parse_next(input)?;
    space0.parse_next(input)?;
    let value = quoted_string(input)?;
    Ok((key.to_owned(), value))
}

fn schedule_marker(input: &mut &str) -> ParseResult<()> {
    marker_word(input, "schedule")?;
    space1.parse_next(input)?;
    keyword(input, "next_workout")?;
    Ok(())
}

fn starts_marker(input: &mut &str) -> ParseResult<()> {
    marker_word(input, "starts")
}

fn training_maxes_marker(input: &mut &str) -> ParseResult<()> {
    marker_word(input, "training_maxes")
}

fn accessories_marker(input: &mut &str) -> ParseResult<()> {
    marker_word(input, "accessories")
}

fn exercise_options_marker(input: &mut &str) -> ParseResult<()> {
    marker_word(input, "exercise_options")
}

fn rest_marker(input: &mut &str) -> ParseResult<()> {
    marker_word(input, "rest")
}

fn assistance_marker(input: &mut &str) -> ParseResult<()> {
    marker_word(input, "assistance")
}

fn marker_word(input: &mut &str, mut word: &'static str) -> ParseResult<()> {
    space0.parse_next(input)?;
    word.parse_next(input)?;
    Ok(())
}

fn extract_optional_unique_block(text: &str, marker: MarkerParser, label: &str) -> Result<String> {
    let matches = find_top_level_marker_ends(text, marker);
    match matches.as_slice() {
        [] => Ok(String::new()),
        [marker_end] => extract_block_at(text, *marker_end, label).map(|(body, _)| body),
        _ => Err(parse_error(format!("duplicate {label} block"))),
    }
}

fn extract_block_at(text: &str, marker_end: usize, label: &str) -> Result<(String, usize)> {
    let open = text[marker_end..]
        .find('{')
        .map(|offset| offset + marker_end)
        .ok_or_else(|| parse_error(format!("{label} block is missing '{{'")))?;
    if !text[marker_end..open].trim().is_empty() {
        return Err(parse_error(format!(
            "unexpected content before {label} block opening brace"
        )));
    }
    let mut depth = 1;
    for (offset, ch) in text[open + 1..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    let close = open + 1 + offset;
                    return Ok((text[open + 1..close].to_owned(), close));
                }
            }
            _ => {}
        }
    }
    Err(parse_error(format!(
        "{label} block is missing closing '}}'"
    )))
}

fn find_marker_end(text: &str, marker: MarkerParser) -> Option<usize> {
    text.char_indices()
        .find_map(|(offset, _)| marker_end_at(text, marker, offset))
}

fn marker_end_at(text: &str, marker: MarkerParser, offset: usize) -> Option<usize> {
    let mut input = &text[offset..];
    marker(&mut input)
        .ok()
        .map(|()| text.len().saturating_sub(input.len()))
}

fn find_top_level_marker_ends(text: &str, marker: MarkerParser) -> Vec<usize> {
    let mut matches = Vec::new();
    let mut depth: isize = 0;
    let mut offset = 0;
    for line in text.lines() {
        let trimmed = line.trim_start();
        if depth == 0 {
            let line_offset = offset + line.len().saturating_sub(trimmed.len());
            if let Some(marker_end) = marker_end_at(text, marker, line_offset) {
                matches.push(marker_end);
            }
        }
        depth += line.chars().filter(|ch| *ch == '{').count() as isize;
        depth -= line.chars().filter(|ch| *ch == '}').count() as isize;
        offset += line.len() + 1;
    }
    matches
}

fn validate_plan_body(body: &str) -> Result<()> {
    let mut depth: isize = 0;
    for (index, raw) in body.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if depth == 0
            && parse_line(line, template_directive).is_none()
            && parse_line(line, units_directive).is_none()
            && !line_starts_block(line, schedule_marker)
            && !line_starts_block(line, starts_marker)
            && !line_starts_block(line, training_maxes_marker)
            && !line_starts_block(line, accessories_marker)
            && !line_starts_block(line, exercise_options_marker)
            && !line_starts_block(line, rest_marker)
            && !line_starts_block(line, assistance_marker)
        {
            return Err(parse_error(format!(
                "invalid plan syntax at line {}: {line}",
                index + 1
            )));
        }
        depth += line.chars().filter(|ch| *ch == '{').count() as isize;
        depth -= line.chars().filter(|ch| *ch == '}').count() as isize;
        if depth < 0 {
            return Err(parse_error(format!(
                "unexpected closing brace in plan at line {}",
                index + 1
            )));
        }
    }
    if depth != 0 {
        return Err(parse_error("plan has an unclosed nested block"));
    }
    Ok(())
}

fn line_starts_block(line: &str, marker: MarkerParser) -> bool {
    let mut input = line;
    marker(&mut input).is_ok() && input.trim_start().starts_with('{')
}

fn parse_list_line(block: &str, key: &str) -> Result<Vec<String>> {
    let mut result = None;
    for (index, line) in block.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let Some((line_key, value)) = parse_line(line, key_value_line) else {
            return Err(parse_error(format!(
                "invalid schedule syntax at line {}: {}",
                index + 1,
                line.trim()
            )));
        };
        if !matches!(line_key.as_str(), "rotation" | "suggested_days") {
            return Err(parse_error(format!(
                "unknown schedule directive at line {}: {line_key}",
                index + 1
            )));
        }
        if line_key == key {
            if result.is_some() {
                return Err(parse_error(format!("duplicate schedule {key} directive")));
            }
            result = Some(
                value
                    .split([',', ' ', '\t'])
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_ascii_lowercase)
                    .collect(),
            );
        }
    }
    Ok(result.unwrap_or_default())
}

fn parse_key_value_block(block: &str, label: &str) -> Result<Map<String>> {
    let mut values = Map::new();
    for (index, line) in block.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let Some((key, value)) = parse_line(line, key_value_line) else {
            return Err(parse_error(format!(
                "invalid {label} syntax at line {}: {}",
                index + 1,
                line.trim()
            )));
        };
        if values.insert(key.clone(), value).is_some() {
            return Err(parse_error(format!("duplicate {label} key: {key}")));
        }
    }
    Ok(values)
}

fn parse_exercise_options(block: &str) -> Result<Map<ExerciseOptions>> {
    validate_exercise_options_block(block)?;
    let mut options = Map::new();
    let mut input = block;

    while let Some((slot_id, slot_block, rest)) = take_next_slot(input) {
        input = rest;
        let primary = find_line(&slot_block, primary_directive)
            .map(|item| normalize_exercise(&item))
            .unwrap_or_default();
        let alternatives = parse_alternatives(&slot_block);
        let slot_id = slot_id.to_ascii_lowercase();
        if options
            .insert(
                slot_id.clone(),
                ExerciseOptions {
                    primary,
                    alternatives,
                },
            )
            .is_some()
        {
            return Err(parse_error(format!(
                "duplicate exercise_options slot: {slot_id}"
            )));
        }
    }

    Ok(options)
}

fn validate_exercise_options_block(block: &str) -> Result<()> {
    let mut depth: isize = 0;
    for (index, raw) in block.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        match depth {
            0 if line_starts_slot_block(line) => {}
            1 if parse_line(line, primary_directive).is_some() => {}
            1 if line_starts_exercise_block(line) => {}
            1 if line_starts_block(line, alternatives_marker) => {}
            2 if parse_line(line, label_directive).is_some() => {}
            2 if parse_line(line, policy_directive).is_some() => {}
            _ if line == "}" => {}
            _ => {
                return Err(parse_error(format!(
                    "invalid exercise_options syntax at line {}: {line}",
                    index + 1
                )));
            }
        }
        depth += line.chars().filter(|ch| *ch == '{').count() as isize;
        depth -= line.chars().filter(|ch| *ch == '}').count() as isize;
        if depth < 0 {
            return Err(parse_error(format!(
                "unexpected closing brace in exercise_options at line {}",
                index + 1
            )));
        }
    }
    if depth != 0 {
        return Err(parse_error("exercise_options has an unclosed nested block"));
    }
    Ok(())
}

fn take_next_slot(input: &str) -> Option<(String, String, &str)> {
    let marker_end = find_marker_end(input, slot_marker)?;
    let mut header = input[marker_end..].trim_start();
    let slot_id = quoted_string(&mut header).ok()?;
    let body_start = input.len().saturating_sub(header.len());
    let open = input[body_start..].find('{')? + body_start;
    let close = find_matching_brace(input, open);
    let body = input[open + 1..close].to_owned();
    let rest = input.get(close + 1..).unwrap_or_default();
    Some((slot_id, body, rest))
}

fn slot_marker(input: &mut &str) -> ParseResult<()> {
    space0.parse_next(input)?;
    "slot".parse_next(input)?;
    space1.parse_next(input)?;
    Ok(())
}

fn alternatives_marker(input: &mut &str) -> ParseResult<()> {
    marker_word(input, "alternatives")
}

fn primary_directive(input: &mut &str) -> ParseResult<String> {
    space0.parse_next(input)?;
    "primary".parse_next(input)?;
    space1.parse_next(input)?;
    exercise_identifier.map(str::to_owned).parse_next(input)
}

fn parse_alternatives(block: &str) -> Vec<ExerciseAlternative> {
    let mut alternatives = Vec::new();
    let mut input = block;

    while let Some((option_id, body, rest)) = take_next_alternative(input) {
        input = rest;
        if option_id == "alternatives" {
            alternatives.extend(parse_alternatives(&body));
            continue;
        }
        let exercise = normalize_exercise(&option_id);
        alternatives.push(ExerciseAlternative {
            option_id: exercise.clone(),
            exercise,
            label: find_in_text(&body, label_directive).unwrap_or(option_id),
            policy: find_in_text(&body, policy_directive).unwrap_or(SwapPolicy::TrackingOnly),
        });
    }

    alternatives
}

fn take_next_alternative(input: &str) -> Option<(String, String, &str)> {
    let marker_start = find_exercise_block_start(input)?;
    let mut header = &input[marker_start..];
    let option_id = exercise_identifier
        .map(str::to_owned)
        .parse_next(&mut header)
        .ok()?;
    let consumed = input.len().saturating_sub(header.len());
    let trimmed = header.trim_start();
    let open = consumed + header.len().saturating_sub(trimmed.len());
    if !trimmed.starts_with('{') {
        return None;
    }
    let close = find_matching_brace(input, open);
    let body = input[open + 1..close].to_owned();
    let rest = input.get(close + 1..).unwrap_or_default();
    Some((option_id, body, rest))
}

fn find_exercise_block_start(input: &str) -> Option<usize> {
    input.char_indices().find_map(|(offset, _)| {
        let mut cursor = &input[offset..];
        exercise_identifier.parse_next(&mut cursor).ok()?;
        cursor.trim_start().starts_with('{').then_some(offset)
    })
}

fn line_starts_exercise_block(line: &str) -> bool {
    let mut input = line;
    exercise_identifier.parse_next(&mut input).is_ok() && input.trim_start().starts_with('{')
}

fn line_starts_slot_block(line: &str) -> bool {
    let mut input = line;
    slot_marker(&mut input).is_ok()
        && quoted_string(&mut input).is_ok()
        && input.trim_start().starts_with('{')
}

fn find_matching_brace(input: &str, open: usize) -> usize {
    let mut depth = 1;
    for (offset, ch) in input[open + 1..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return open + 1 + offset;
                }
            }
            _ => {}
        }
    }
    input.len()
}

fn label_directive(input: &mut &str) -> ParseResult<String> {
    space0.parse_next(input)?;
    "label".parse_next(input)?;
    space1.parse_next(input)?;
    quoted_string(input)
}

fn policy_directive(input: &mut &str) -> ParseResult<SwapPolicy> {
    space0.parse_next(input)?;
    "policy".parse_next(input)?;
    space1.parse_next(input)?;
    let policy = exercise_identifier(input)?;
    Ok(match policy {
        "progression_equivalent" => SwapPolicy::ProgressionEquivalent,
        _ => SwapPolicy::TrackingOnly,
    })
}

fn parse_rest_policy(block: &str) -> Result<RestPolicy> {
    let mut policy = RestPolicy::default();

    for (index, raw) in block.lines().enumerate() {
        if raw.trim().is_empty() {
            continue;
        };
        let Some(line) = parse_line(raw, rest_line) else {
            return Err(parse_error(format!(
                "invalid rest syntax at line {}: {}",
                index + 1,
                raw.trim()
            )));
        };
        match line {
            RestLine::Default(seconds) => policy.default_seconds = Some(seconds),
            RestLine::Scoped {
                scope,
                key,
                seconds,
            } => {
                let key = normalize_rest_key(&scope, &key);
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
                    _ => {
                        return Err(parse_error(format!(
                            "unknown rest scope at line {}: {scope}",
                            index + 1
                        )));
                    }
                }
            }
        }
    }

    Ok(policy)
}

enum RestLine {
    Default(u32),
    Scoped {
        scope: String,
        key: String,
        seconds: u32,
    },
}

fn rest_line(input: &mut &str) -> ParseResult<RestLine> {
    space0.parse_next(input)?;
    let scope = bare_word(input)?.to_ascii_lowercase();
    space1.parse_next(input)?;
    if scope == "default" {
        let seconds = rest_seconds(input)?;
        return Ok(RestLine::Default(seconds));
    }

    let key = bare_word(input)?.to_owned();
    space1.parse_next(input)?;
    let seconds = rest_seconds(input)?;
    Ok(RestLine::Scoped {
        scope,
        key,
        seconds,
    })
}

fn rest_seconds(input: &mut &str) -> ParseResult<u32> {
    let value = bare_word(input)?.to_ascii_lowercase();
    let unit = opt(preceded(space1, bare_word)).parse_next(input)?;

    if let Some(unit) = unit
        && let Some(seconds) = parse_rest_seconds_with_unit(&value, &unit.to_ascii_lowercase())
    {
        return Ok(seconds);
    }

    parse_rest_seconds_value(&value).ok_or_else(ContextError::new)
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

fn patch_operation(input: &mut &str) -> ParseResult<PatchOperation> {
    let mut attempt = *input;
    if let Ok(operation) = replace_exercise_operation.parse_next(&mut attempt) {
        *input = attempt;
        return Ok(operation);
    }
    let mut attempt = *input;
    if let Ok(operation) = add_conditioning_operation.parse_next(&mut attempt) {
        *input = attempt;
        return Ok(operation);
    }
    cap_operation(input)
}

fn replace_exercise_operation(input: &mut &str) -> ParseResult<PatchOperation> {
    keyword_with_space(input, "replace")?;
    keyword(input, "exercise")?;
    space1.parse_next(input)?;
    let from = exercise_identifier(input)?;
    space1.parse_next(input)?;
    keyword(input, "with")?;
    space1.parse_next(input)?;
    let to = exercise_identifier(input)?;
    let lane_regex = where_lane_matches(input)?;

    Ok(PatchOperation::ReplaceExercise {
        from: normalize_exercise(from),
        to: normalize_exercise(to),
        lane_regex,
    })
}

fn add_conditioning_operation(input: &mut &str) -> ParseResult<PatchOperation> {
    keyword_with_space(input, "add")?;
    keyword(input, "conditioning")?;
    space1.parse_next(input)?;
    let day = take_while(1.., |ch: char| ch.is_ascii_alphabetic()).parse_next(input)?;
    space0.parse_next(input)?;
    let activity = delimited('{', take_till(0.., '}'), '}')
        .map(|activity: &str| activity.trim().to_owned())
        .parse_next(input)?;

    Ok(PatchOperation::AddConditioning {
        day: day.to_ascii_lowercase(),
        activity,
    })
}

fn cap_operation(input: &mut &str) -> ParseResult<PatchOperation> {
    keyword_with_space(input, "cap")?;
    let rest = line_value(input)?;
    let (rest, lane_regex) = split_where_lane_suffix(&rest);
    let (target, value) = split_cap_target_value(rest).ok_or_else(ContextError::new)?;

    Ok(PatchOperation::Cap {
        target,
        value,
        lane_regex,
    })
}

fn split_where_lane_suffix(value: &str) -> (&str, Option<String>) {
    for (index, _) in value.match_indices(" where") {
        let mut suffix = &value[index..];
        if let Ok(lane_regex) = where_lane_matches(&mut suffix)
            && suffix.trim().is_empty()
        {
            return (value[..index].trim(), Some(lane_regex));
        }
    }
    (value.trim(), None)
}

fn where_lane_matches(input: &mut &str) -> ParseResult<String> {
    space1.parse_next(input)?;
    keyword(input, "where")?;
    space1.parse_next(input)?;
    keyword(input, "lane")?;
    space1.parse_next(input)?;
    keyword(input, "matches")?;
    space1.parse_next(input)?;
    quoted_string(input)
}

fn split_cap_target_value(rest: &str) -> Option<(String, String)> {
    let (target, value) = rest.trim().split_once(char::is_whitespace)?;
    let value = value
        .trim()
        .strip_prefix("at ")
        .unwrap_or(value.trim())
        .trim();
    (!target.is_empty() && !value.is_empty()).then(|| (target.to_owned(), value.to_owned()))
}

fn insert_lock_entry(templates: &mut Map<LockEntry>, id: Option<String>, pairs: &Map<String>) {
    let Some(id) = id else {
        return;
    };
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

fn fail<T>(_input: &mut &str) -> ParseResult<T> {
    Err(ContextError::new())
}
