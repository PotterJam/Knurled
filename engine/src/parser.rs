//! FitSpec parser.
//!
//! FitSpec is a [KDL](https://kdl.dev) dialect: every construct is a KDL node
//! with arguments, properties, and an optional `{ children }` block. The `kdl`
//! crate owns phase one — tokenizing, brace matching, strings, numbers,
//! comments, and line-numbered syntax errors. This module owns phase two: a
//! single walk over the parsed document that interprets known nodes into the
//! typed model and rejects the rest. Lockfiles are TOML and go straight through
//! `serde`.
//!
//! Keep new syntax declarative: add a match arm here, not another bespoke
//! sub-parser. The model shapes this produces are part of the engine's public
//! contract, so changing field semantics ripples into hashes and every client.

use std::collections::BTreeMap;

use kdl::{KdlDocument, KdlNode, KdlValue};
use serde::Deserialize;

use crate::error::{KnurledError, Result};
use crate::model::{
    EquipmentProfile, ExerciseAlternative, ExerciseOptions, Implement, LockEntry, Lockfile, Map,
    Patch, PatchOperation, Plan, RestPolicy, RoundingMode, SCHEMA_VERSION, Schedule, SwapPolicy,
    Units, WarmupBasis, WarmupPolicy, WarmupScheme, WarmupStep,
};
use crate::templates::parse_template_ref;

pub fn parse_plan(text: &str) -> Result<Plan> {
    let doc = parse_document(text)?;
    let plan = single_top_node(&doc, "plan")?;
    let name = node_string_arg(plan, "plan name")?;
    let body = plan
        .children()
        .ok_or_else(|| parse_error("plan is missing its `{ … }` block"))?;

    let mut template = None;
    let mut units = None;
    let mut schedule = Schedule {
        mode: "next_workout".into(),
        rotation: Vec::new(),
        suggested_days: Vec::new(),
    };
    let mut starts = Map::new();
    let mut training_maxes = Map::new();
    let mut accessories = Map::new();
    let mut exercise_options = Map::new();
    let mut rest = RestPolicy::default();
    let mut warmup = WarmupPolicy::default();
    let mut equipment = None;

    for node in body.nodes() {
        match node.name().value() {
            "template" => template = Some(parse_template_directive(node)?),
            "units" => units = Some(parse_units(node)?),
            "schedule" => schedule = parse_schedule(node)?,
            "starts" => starts = normalize_lift_map(parse_pairs(node)?),
            "training_maxes" => training_maxes = normalize_lift_map(parse_pairs(node)?),
            "accessories" => accessories = normalize_accessory_map(parse_pairs(node)?),
            "exercise_options" => exercise_options = parse_exercise_options(node)?,
            "rest" => rest = parse_rest(node)?,
            "warmup" => warmup = parse_warmup(node)?,
            "equipment" => equipment = Some(parse_equipment(node)?),
            // `assistance` is a documented future construct (spec §11) that the
            // MVP templates do not yet consume: accept it, but ignore it.
            "assistance" => {}
            other => return Err(parse_error(format!("unknown plan directive: {other}"))),
        }
    }

    Ok(Plan {
        kind: "fitspec_plan".into(),
        schema_version: SCHEMA_VERSION.into(),
        name,
        template: template
            .ok_or_else(|| parse_error("plan is missing required template directive"))?,
        units: units.ok_or_else(|| parse_error("plan is missing required units directive"))?,
        schedule,
        starts,
        training_maxes,
        accessories,
        exercise_options,
        rest,
        warmup,
        equipment,
    })
}

pub fn parse_patch(text: &str, filename: impl Into<String>) -> Result<Patch> {
    let filename = filename.into();
    let doc = parse_document(text)?;
    let patch = single_top_node(&doc, "patch")?;
    let name = node_string_arg(patch, "patch name")?;
    let body = patch
        .children()
        .ok_or_else(|| parse_error("patch is missing its `{ … }` block"))?;

    let mut description = String::new();
    let mut active_from = None;
    let mut expires = None;
    let mut operations = Vec::new();

    for node in body.nodes() {
        match node.name().value() {
            "description" => description = node_string_arg(node, "description")?,
            "active-from" => active_from = Some(node_string_arg(node, "active-from")?),
            "expires" => expires = Some(node_string_arg(node, "expires")?),
            "replace-exercise" => operations.push(parse_replace_exercise(node)?),
            "add-conditioning" => operations.push(parse_add_conditioning(node)?),
            "cap" => operations.push(parse_cap(node)?),
            other => {
                return Err(parse_error(format!(
                    "unknown patch operation in {filename}: {other}"
                )));
            }
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

pub fn parse_lock(text: &str) -> Result<Lockfile> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct LockToml {
        #[serde(default)]
        templates: BTreeMap<String, LockEntryToml>,
    }

    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct LockEntryToml {
        version: String,
        source: String,
        content_hash: String,
        engine_version: String,
    }

    let parsed: LockToml =
        toml::from_str(text).map_err(|error| parse_error(format!("invalid lockfile: {error}")))?;

    let templates = parsed
        .templates
        .into_iter()
        .map(|(id, entry)| {
            (
                id,
                LockEntry {
                    version: entry.version,
                    source: entry.source,
                    content_hash: entry.content_hash,
                    engine_version: entry.engine_version,
                },
            )
        })
        .collect();

    Ok(Lockfile {
        kind: "fitspec_lock".into(),
        schema_version: SCHEMA_VERSION.into(),
        templates,
    })
}

// ---------------------------------------------------------------------------
// Plan sub-parsers
// ---------------------------------------------------------------------------

/// Accepts both `template "id@version"` and the friendlier
/// `template "id" version="x"` property form. Both normalize to the same
/// `id@version` string, so a plan's identity is unaffected by which is used.
fn parse_template_directive(node: &KdlNode) -> Result<String> {
    let id = node_string_arg(node, "template")?;
    let raw = match prop_string(node, "version") {
        Some(version) if !id.contains('@') => format!("{id}@{version}"),
        _ => id,
    };
    Ok(parse_template_ref(&raw).normalized)
}

fn parse_units(node: &KdlNode) -> Result<Units> {
    let unit = node_string_arg(node, "units")?;
    Ok(match unit.to_ascii_lowercase().as_str() {
        "lb" => Units::Lb,
        _ => Units::Kg,
    })
}

fn parse_schedule(node: &KdlNode) -> Result<Schedule> {
    let mode = first_arg_string(node).unwrap_or_else(|| "next_workout".into());
    let mut rotation = Vec::new();
    let mut suggested_days = Vec::new();

    if let Some(body) = node.children() {
        for line in body.nodes() {
            match line.name().value() {
                "rotation" => rotation = lowercased_args(line),
                "suggested_days" => suggested_days = lowercased_args(line),
                other => {
                    return Err(parse_error(format!("unknown schedule directive: {other}")));
                }
            }
        }
    }

    Ok(Schedule {
        mode,
        rotation,
        suggested_days,
    })
}

fn parse_pairs(node: &KdlNode) -> Result<Map<String>> {
    let mut values = Map::new();
    let label = node.name().value();
    if let Some(body) = node.children() {
        for entry in body.nodes() {
            let key = entry.name().value().to_owned();
            let value = node_string_arg(entry, &format!("{label} entry `{key}`"))?;
            if values.insert(key.clone(), value).is_some() {
                return Err(parse_error(format!("duplicate {label} key: {key}")));
            }
        }
    }
    Ok(values)
}

fn parse_exercise_options(node: &KdlNode) -> Result<Map<ExerciseOptions>> {
    let mut options = Map::new();
    if let Some(body) = node.children() {
        for slot in body.nodes() {
            if slot.name().value() != "slot" {
                return Err(parse_error(format!(
                    "expected a `slot` in exercise_options, found `{}`",
                    slot.name().value()
                )));
            }
            let slot_id = node_string_arg(slot, "slot")?.to_ascii_lowercase();
            let mut primary = String::new();
            let mut alternatives = Vec::new();

            if let Some(slot_body) = slot.children() {
                for line in slot_body.nodes() {
                    match line.name().value() {
                        "primary" => {
                            primary = normalize_exercise(&node_string_arg(line, "primary")?)
                        }
                        // Both the spec's nested `alternatives { … }` block and a
                        // flat list of alternative nodes are accepted.
                        "alternatives" => {
                            if let Some(alts) = line.children() {
                                for alt in alts.nodes() {
                                    alternatives.push(parse_alternative(alt)?);
                                }
                            }
                        }
                        _ => alternatives.push(parse_alternative(line)?),
                    }
                }
            }

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
    }
    Ok(options)
}

fn parse_alternative(node: &KdlNode) -> Result<ExerciseAlternative> {
    let raw = node.name().value().to_owned();
    let exercise = normalize_exercise(&raw);
    let mut label = raw;
    let mut policy = SwapPolicy::TrackingOnly;

    if let Some(body) = node.children() {
        for line in body.nodes() {
            match line.name().value() {
                "label" => label = node_string_arg(line, "label")?,
                "policy" => policy = parse_policy(&node_string_arg(line, "policy")?),
                _ => {}
            }
        }
    }

    Ok(ExerciseAlternative {
        option_id: exercise.clone(),
        exercise,
        label,
        policy,
    })
}

fn parse_policy(value: &str) -> SwapPolicy {
    match value {
        "progression_equivalent" => SwapPolicy::ProgressionEquivalent,
        _ => SwapPolicy::TrackingOnly,
    }
}

fn parse_rest(node: &KdlNode) -> Result<RestPolicy> {
    let mut policy = RestPolicy::default();
    if let Some(body) = node.children() {
        for line in body.nodes() {
            let scope = line.name().value().to_ascii_lowercase();
            let args = positional_strings(line);

            if scope == "default" {
                policy.default_seconds = Some(
                    parse_rest_seconds(&args)
                        .ok_or_else(|| parse_error("invalid rest default duration"))?,
                );
                continue;
            }

            let mut args = args.into_iter();
            let key = args
                .next()
                .ok_or_else(|| parse_error(format!("rest {scope} is missing a key")))?;
            let duration: Vec<String> = args.collect();
            let seconds = parse_rest_seconds(&duration)
                .ok_or_else(|| parse_error(format!("invalid rest {scope} duration")))?;
            let key = normalize_rest_key(&scope, &key);

            match scope.as_str() {
                "tier" => policy.by_tier.insert(key, seconds),
                "slot" => policy.by_slot.insert(key, seconds),
                "lane" => policy.by_lane.insert(key, seconds),
                "exercise" => policy.by_exercise.insert(key, seconds),
                other => return Err(parse_error(format!("unknown rest scope: {other}"))),
            };
        }
    }
    Ok(policy)
}

fn parse_warmup(node: &KdlNode) -> Result<WarmupPolicy> {
    let mut policy = WarmupPolicy::default();
    if let Some(body) = node.children() {
        for line in body.nodes() {
            let scope = line.name().value().to_ascii_lowercase();
            if scope == "default" {
                policy.default = Some(parse_warmup_scheme(line)?);
                continue;
            }

            let key = node_string_arg(line, &format!("warmup {scope}"))?;
            let key = normalize_rest_key(&scope, &key);
            let scheme = parse_warmup_scheme(line)?;
            let existing = match scope.as_str() {
                "tier" => policy.by_tier.insert(key.clone(), scheme),
                "slot" => policy.by_slot.insert(key.clone(), scheme),
                "lane" => policy.by_lane.insert(key.clone(), scheme),
                "exercise" => policy.by_exercise.insert(key.clone(), scheme),
                other => return Err(parse_error(format!("unknown warmup scope: {other}"))),
            };
            if existing.is_some() {
                return Err(parse_error(format!("duplicate warmup {scope}: {key}")));
            }
        }
    }
    Ok(policy)
}

fn parse_warmup_scheme(node: &KdlNode) -> Result<WarmupScheme> {
    let mut scheme = WarmupScheme::default();
    if let Some(body) = node.children() {
        for line in body.nodes() {
            match line.name().value() {
                "empty_bar" => {
                    let args = positional_strings(line);
                    scheme.empty_bar_sets = args
                        .first()
                        .and_then(|value| value.parse().ok())
                        .ok_or_else(|| parse_error("warmup empty_bar needs a set count"))?;
                    scheme.empty_bar_reps = args
                        .get(1)
                        .and_then(|value| value.parse().ok())
                        .ok_or_else(|| parse_error("warmup empty_bar needs a rep count"))?;
                }
                "ramp" => {
                    if let Some(steps) = line.children() {
                        for step in steps.nodes() {
                            scheme.ramp.push(parse_warmup_step(step)?);
                        }
                    }
                }
                "basis" => scheme.basis = parse_warmup_basis(&node_string_arg(line, "basis")?)?,
                other => return Err(parse_error(format!("unknown warmup directive: {other}"))),
            }
        }
    }
    Ok(scheme)
}

/// A ramp step is `step <percentage> <reps>`, e.g. `step 65 3`. Reps may also
/// be given as `reps=`, and the percentage as `pct=`, for readability.
fn parse_warmup_step(node: &KdlNode) -> Result<WarmupStep> {
    if node.name().value() != "step" {
        return Err(parse_error(format!(
            "expected a `step` in warmup ramp, found `{}`",
            node.name().value()
        )));
    }
    let args = positional_strings(node);
    let percentage = args
        .first()
        .and_then(|value| value.parse().ok())
        .or_else(|| prop_string(node, "pct").and_then(|value| value.parse().ok()))
        .ok_or_else(|| parse_error("warmup step needs a percentage"))?;
    let reps = args
        .get(1)
        .and_then(|value| value.parse().ok())
        .or_else(|| prop_string(node, "reps").and_then(|value| value.parse().ok()))
        .ok_or_else(|| parse_error("warmup step needs a rep count"))?;
    Ok(WarmupStep { percentage, reps })
}

fn parse_warmup_basis(value: &str) -> Result<WarmupBasis> {
    Ok(match value.to_ascii_lowercase().as_str() {
        "top_set" => WarmupBasis::TopSet,
        "working_weight" => WarmupBasis::WorkingWeight,
        "training_max" => WarmupBasis::TrainingMax,
        other => return Err(parse_error(format!("unknown warmup basis: {other}"))),
    })
}

fn parse_equipment(node: &KdlNode) -> Result<EquipmentProfile> {
    let mut profile = EquipmentProfile::default();
    if let Some(body) = node.children() {
        for line in body.nodes() {
            match line.name().value() {
                "bar" => {
                    let args = positional_strings(line);
                    let key = args
                        .first()
                        .map(|key| normalize_exercise(key))
                        .ok_or_else(|| {
                            parse_error("equipment bar needs an exercise or `default`")
                        })?;
                    let weight = args
                        .get(1)
                        .and_then(|value| parse_number(value))
                        .ok_or_else(|| parse_error("equipment bar needs a weight"))?;
                    profile.bars.insert(key, weight);
                }
                "plates" => profile.plate_pairs = parse_number_list(line, "plates")?,
                "dumbbells" => profile.dumbbells = parse_number_list(line, "dumbbells")?,
                "rounding" => {
                    profile.rounding = parse_rounding(&node_string_arg(line, "rounding")?)?
                }
                "implement" => {
                    let args = positional_strings(line);
                    let exercise = args
                        .first()
                        .map(|value| normalize_exercise(value))
                        .ok_or_else(|| parse_error("equipment implement needs an exercise"))?;
                    let implement = args
                        .get(1)
                        .ok_or_else(|| parse_error("equipment implement needs barbell|dumbbell"))?;
                    profile
                        .implements
                        .insert(exercise, parse_implement(implement)?);
                }
                other => return Err(parse_error(format!("unknown equipment directive: {other}"))),
            }
        }
    }
    Ok(profile)
}

fn parse_number_list(node: &KdlNode, label: &str) -> Result<Vec<f64>> {
    let values: Vec<f64> = positional_strings(node)
        .iter()
        .filter_map(|value| parse_number(value))
        .collect();
    if values.is_empty() {
        return Err(parse_error(format!(
            "equipment {label} needs at least one value"
        )));
    }
    Ok(values)
}

fn parse_number(value: &str) -> Option<f64> {
    value
        .trim()
        .parse()
        .ok()
        .filter(|number: &f64| number.is_finite())
}

fn parse_rounding(value: &str) -> Result<RoundingMode> {
    Ok(match value.to_ascii_lowercase().as_str() {
        "nearest" => RoundingMode::Nearest,
        "down" => RoundingMode::Down,
        other => return Err(parse_error(format!("unknown rounding mode: {other}"))),
    })
}

fn parse_implement(value: &str) -> Result<Implement> {
    Ok(match value.to_ascii_lowercase().as_str() {
        "barbell" => Implement::Barbell,
        "dumbbell" => Implement::Dumbbell,
        other => return Err(parse_error(format!("unknown implement: {other}"))),
    })
}

// ---------------------------------------------------------------------------
// Patch sub-parsers
// ---------------------------------------------------------------------------

fn parse_replace_exercise(node: &KdlNode) -> Result<PatchOperation> {
    let from = required_prop(node, "from", "replace-exercise")?;
    let to = required_prop(node, "to", "replace-exercise")?;
    let lane_regex = required_prop(node, "lane", "replace-exercise")?;
    Ok(PatchOperation::ReplaceExercise {
        from: normalize_exercise(&from),
        to: normalize_exercise(&to),
        lane_regex,
    })
}

fn parse_add_conditioning(node: &KdlNode) -> Result<PatchOperation> {
    let day = required_prop(node, "day", "add-conditioning")?.to_ascii_lowercase();
    let activity = required_prop(node, "activity", "add-conditioning")?;
    Ok(PatchOperation::AddConditioning { day, activity })
}

fn parse_cap(node: &KdlNode) -> Result<PatchOperation> {
    let target = required_prop(node, "target", "cap")?;
    let value = required_prop(node, "value", "cap")?;
    let lane_regex = prop_string(node, "lane");
    Ok(PatchOperation::Cap {
        target,
        value,
        lane_regex,
    })
}

// ---------------------------------------------------------------------------
// Rest duration helpers (pure string math, unit-aware)
// ---------------------------------------------------------------------------

fn parse_rest_seconds(args: &[String]) -> Option<u32> {
    match args {
        [value] => parse_rest_seconds_value(value),
        [value, unit] => parse_rest_seconds_with_unit(value, &unit.to_ascii_lowercase())
            .or_else(|| parse_rest_seconds_value(value)),
        _ => None,
    }
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

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// KDL access helpers
// ---------------------------------------------------------------------------

fn parse_document(text: &str) -> Result<KdlDocument> {
    text.parse::<KdlDocument>()
        .map_err(|error| parse_error(format!("syntax error: {error}")))
}

fn single_top_node<'a>(doc: &'a KdlDocument, name: &str) -> Result<&'a KdlNode> {
    match doc.nodes() {
        [node] if node.name().value() == name => Ok(node),
        [] => Err(parse_error(format!("missing {name} block"))),
        [node] => Err(parse_error(format!(
            "expected a `{name}` block, found `{}`",
            node.name().value()
        ))),
        _ => Err(parse_error(format!(
            "expected a single top-level {name} block"
        ))),
    }
}

/// Every positional argument of `node`, rendered to a string.
fn positional_strings(node: &KdlNode) -> Vec<String> {
    node.entries()
        .iter()
        .filter(|entry| entry.name().is_none())
        .map(|entry| value_to_string(entry.value()))
        .collect()
}

fn lowercased_args(node: &KdlNode) -> Vec<String> {
    positional_strings(node)
        .into_iter()
        .map(|value| value.to_ascii_lowercase())
        .collect()
}

fn first_arg_string(node: &KdlNode) -> Option<String> {
    node.entries()
        .iter()
        .find(|entry| entry.name().is_none())
        .map(|entry| value_to_string(entry.value()))
}

fn node_string_arg(node: &KdlNode, label: &str) -> Result<String> {
    first_arg_string(node).ok_or_else(|| parse_error(format!("{label} is missing a value")))
}

/// The last value bound to property `key` (KDL keeps the last write).
fn prop_string(node: &KdlNode, key: &str) -> Option<String> {
    node.entries()
        .iter()
        .rfind(|entry| entry.name().is_some_and(|name| name.value() == key))
        .map(|entry| value_to_string(entry.value()))
}

fn required_prop(node: &KdlNode, key: &str, op: &str) -> Result<String> {
    prop_string(node, key).ok_or_else(|| parse_error(format!("{op} is missing required `{key}=`")))
}

fn value_to_string(value: &KdlValue) -> String {
    if let Some(text) = value.as_string() {
        text.to_owned()
    } else if let Some(integer) = value.as_integer() {
        integer.to_string()
    } else if let Some(float) = value.as_float() {
        float.to_string()
    } else if let Some(boolean) = value.as_bool() {
        boolean.to_string()
    } else {
        String::new()
    }
}

fn parse_error(message: impl Into<String>) -> KnurledError {
    KnurledError::Parse(message.into())
}
