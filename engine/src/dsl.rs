//! Declarative template-authoring DSL from ADR 0003.
//!
//! The grammar is KDL and deliberately bounded: sessions reference lanes; lanes select a basis,
//! sequence, stage schemes, triggers, and effects. There is no executable code or control flow.

use kdl::{KdlDocument, KdlNode, KdlValue};

use crate::error::{KnurledError, Result};
use crate::model::*;
use crate::parser::normalize_exercise;
use crate::templates::{DEFAULT_TEMPLATE_VERSION, builtin_template_document, parse_template_ref};

pub fn parse_template_dsl(text: &str, source_id: &str) -> Result<BuiltinTemplate> {
    let doc = text
        .parse::<KdlDocument>()
        .map_err(|error| parse_error(format!("template syntax error: {error:?}")))?;
    let top = match doc.nodes() {
        [node] if node.name().value() == "template" => node,
        _ => return Err(parse_error("expected one top-level `template` block")),
    };
    let body = top
        .children()
        .ok_or_else(|| parse_error("template requires a body"))?;
    let name = arg(top, "template name")?;
    let version = prop(top, "version").unwrap_or_else(|| DEFAULT_TEMPLATE_VERSION.into());
    let mut rotation = Vec::new();
    let mut rest_seconds = 120;
    let mut template_warmup = None;
    let mut session_display_names = Map::new();
    let mut sessions = Map::new();
    let mut lanes = Map::new();

    for node in body.nodes() {
        match node.name().value() {
            "rotation" => {
                rotation = args(node)
                    .into_iter()
                    .map(|value| value.to_ascii_lowercase())
                    .collect()
            }
            "rest" => {
                rest_seconds = arg(node, "rest seconds")?
                    .parse()
                    .map_err(|_| parse_error("rest must be integer seconds"))?
            }
            "warmup" => template_warmup = Some(parse_warmup(node)?),
            "session" => {
                let id = arg(node, "session id")?.to_ascii_lowercase();
                if let Some(display_name) = prop(node, "display") {
                    session_display_names.insert(id.clone(), display_name);
                }
                let session_body = node
                    .children()
                    .ok_or_else(|| parse_error("session requires items"))?;
                let mut items = Vec::new();
                for item in session_body.nodes() {
                    if item.name().value() != "item" {
                        return Err(parse_error(format!(
                            "unknown session directive: {}",
                            item.name().value()
                        )));
                    }
                    let lane = arg(item, "item lane")?.to_ascii_lowercase();
                    items.push(DslSessionItem {
                        slot_id: prop(item, "slot").unwrap_or_else(|| format!("{id}.{lane}")),
                        lane,
                        accessory_key: prop(item, "accessory"),
                        default_exercise: prop(item, "default_exercise")
                            .map(|exercise| normalize_exercise(&exercise)),
                    });
                }
                sessions.insert(id, items);
            }
            "lane" => {
                let id = arg(node, "lane id")?.to_ascii_lowercase();
                if lanes.insert(id.clone(), parse_lane(node)?).is_some() {
                    return Err(parse_error(format!("duplicate lane: {id}")));
                }
            }
            other => return Err(parse_error(format!("unknown template directive: {other}"))),
        }
    }
    if rotation.is_empty() {
        rotation = sessions.keys().cloned().collect();
    }
    if sessions.is_empty() || lanes.is_empty() {
        return Err(parse_error(
            "template requires at least one session and lane",
        ));
    }
    for (session, items) in &sessions {
        for item in items {
            if !lanes.contains_key(&item.lane) {
                return Err(parse_error(format!(
                    "session {session} references unknown lane {}",
                    item.lane
                )));
            }
        }
    }

    let dsl = DslTemplate {
        name: name.clone(),
        version: version.clone(),
        rotation: rotation.clone(),
        rest_seconds,
        warmup: template_warmup,
        session_display_names,
        sessions: sessions.clone(),
        lanes: lanes.clone(),
    };
    Ok(BuiltinTemplate {
        id: source_id.into(),
        version,
        default_rotation: rotation,
        rest: RestPolicy {
            default_seconds: Some(rest_seconds),
            by_tier: lanes
                .iter()
                .filter_map(|(lane_id, lane)| {
                    lane.rest_seconds.map(|seconds| {
                        (
                            lane.tier.clone().unwrap_or_else(|| lane_tier(lane_id)),
                            seconds,
                        )
                    })
                })
                .collect(),
            ..RestPolicy::default()
        },
        dsl,
    })
}

fn parse_lane(node: &KdlNode) -> Result<DslLane> {
    let exercise = normalize_exercise(
        &prop(node, "exercise").ok_or_else(|| parse_error("lane requires exercise="))?,
    );
    let basis = match prop(node, "basis").as_deref().unwrap_or("working_weight") {
        "working_weight" => DslBasis::WorkingWeight,
        "training_max" => DslBasis::TrainingMax,
        "bodyweight" => DslBasis::Bodyweight,
        other => return Err(parse_error(format!("unknown basis: {other}"))),
    };
    let initial = match prop(node, "initial").as_deref().unwrap_or("basis") {
        "basis" => DslInitial::Basis,
        "performed" => DslInitial::Performed,
        value if value.ends_with('%') => {
            let percentage = value
                .trim_end_matches('%')
                .parse::<u32>()
                .map_err(|_| parse_error("initial percentage must be an integer"))?;
            if percentage == 0 {
                return Err(parse_error("initial percentage must be positive"));
            }
            DslInitial::Percent { percentage }
        }
        other => return Err(parse_error(format!("unknown initial source: {other}"))),
    };
    let sequence = match prop(node, "sequence").as_deref().unwrap_or("none") {
        "none" => DslSequence::None,
        "stages" => DslSequence::Stages,
        "cycle" => DslSequence::Cycle,
        "waves" => DslSequence::Waves,
        "rotation" => DslSequence::Rotation,
        other => return Err(parse_error(format!("unknown sequence: {other}"))),
    };
    let body = node
        .children()
        .ok_or_else(|| parse_error("lane requires a body"))?;
    let mut stages = Vec::new();
    let mut rules = Vec::new();
    let mut warmup: Option<WarmupScheme> = None;
    for child in body.nodes() {
        match child.name().value() {
            "stage" => stages.push(parse_stage(child)?),
            "on" => rules.push(parse_rule(child)?),
            "warmup" => merge_warmup(&mut warmup, parse_warmup(child)?),
            other => return Err(parse_error(format!("unknown lane directive: {other}"))),
        }
    }
    if stages.is_empty() {
        return Err(parse_error("lane requires at least one stage"));
    }
    for rule in &rules {
        if let Some(stage) = &rule.stage
            && !stages.iter().any(|candidate| candidate.id == *stage)
        {
            return Err(parse_error(format!(
                "rule references unknown stage: {stage}"
            )));
        }
    }
    Ok(DslLane {
        exercise,
        tier: prop(node, "tier").map(|tier| tier.to_ascii_lowercase()),
        basis,
        initial,
        sequence,
        stages,
        rules,
        rest_seconds: optional_uint_prop(node, "rest")?,
        warmup,
    })
}

fn parse_stage(node: &KdlNode) -> Result<DslStage> {
    let id = arg(node, "stage id")?;
    let body = node
        .children()
        .ok_or_else(|| parse_error("stage requires set groups"))?;
    let mut groups = Vec::new();
    for group in body.nodes() {
        if group.name().value() != "set" {
            return Err(parse_error(format!(
                "unknown stage directive: {}",
                group.name().value()
            )));
        }
        let count = uint_prop(group, "count", 1)?;
        let reps = uint_prop(group, "reps", 0)?;
        if count == 0 {
            return Err(parse_error("set count must be positive"));
        }
        let rep_min = optional_uint_prop(group, "rep_min")?;
        let rep_max = optional_uint_prop(group, "rep_max")?;
        if rep_min.is_some() != rep_max.is_some()
            || rep_min
                .zip(rep_max)
                .is_some_and(|(minimum, maximum)| minimum == 0 || maximum < minimum)
        {
            return Err(parse_error(
                "rep_min and rep_max must form a positive ascending range",
            ));
        }
        groups.push(DslSetGroup {
            count,
            reps,
            intensity: uint_prop(group, "intensity", 100)?,
            amrap: bool_prop(group, "amrap", false),
            rep_min,
            rep_max,
            rpe: optional_uint_prop(group, "rpe")?,
        });
    }
    if groups.is_empty() {
        return Err(parse_error("stage requires at least one set group"));
    }
    Ok(DslStage { id, groups })
}

fn parse_rule(node: &KdlNode) -> Result<DslRule> {
    let trigger = match arg(node, "trigger")?.as_str() {
        "pass" => DslTrigger::Pass,
        "fail" => DslTrigger::Fail,
        "amrap_gte" => DslTrigger::AmrapGte {
            reps: uint_prop(node, "reps", 0)?,
        },
        "stall" => {
            let count = uint_prop(node, "count", 1)?;
            if count == 0 {
                return Err(parse_error("stall count must be positive"));
            }
            DslTrigger::Stall { count }
        }
        "cycle_end" => DslTrigger::CycleEnd,
        "range_top" => DslTrigger::RangeTop,
        other => return Err(parse_error(format!("unknown trigger: {other}"))),
    };
    let body = node
        .children()
        .ok_or_else(|| parse_error("trigger requires effects"))?;
    let mut effects = Vec::new();
    for effect in body.nodes() {
        effects.push(match effect.name().value() {
            "increase_load" => DslEffect::IncreaseLoad {
                amount: prop(effect, "by").unwrap_or_else(|| "2.5".into()),
            },
            "deload" => DslEffect::Deload {
                percent: uint_prop(effect, "percent", 90)?,
            },
            "reset_load" => DslEffect::ResetLoad {
                percent: uint_prop(effect, "percent", 90)?,
            },
            "advance_stage" => DslEffect::AdvanceStage,
            "reset_stage" => DslEffect::ResetStage,
            "increase_reps" => DslEffect::IncreaseReps {
                amount: uint_prop(effect, "by", 1)?,
            },
            "reset_reps" => DslEffect::ResetReps,
            "recompute_tm" => DslEffect::RecomputeTm {
                amount: prop(effect, "by").unwrap_or_else(|| "2.5".into()),
            },
            "advance_cycle" => DslEffect::AdvanceCycle,
            other => return Err(parse_error(format!("unknown effect: {other}"))),
        });
    }
    Ok(DslRule {
        trigger,
        stage: prop(node, "stage"),
        effects,
    })
}

fn parse_warmup(node: &KdlNode) -> Result<WarmupScheme> {
    let mut scheme = WarmupScheme {
        empty_bar_sets: uint_prop(node, "empty_bar_sets", 0)?,
        empty_bar_reps: uint_prop(node, "empty_bar_reps", 0)?,
        basis: match prop(node, "basis").as_deref().unwrap_or("top_set") {
            "top_set" => WarmupBasis::TopSet,
            "working_weight" => WarmupBasis::WorkingWeight,
            "training_max" => WarmupBasis::TrainingMax,
            other => return Err(parse_error(format!("unknown warmup basis: {other}"))),
        },
        ..WarmupScheme::default()
    };

    if prop(node, "intensity").is_some() || prop(node, "reps").is_some() {
        scheme.ramp.push(WarmupStep {
            percentage: uint_prop(node, "intensity", 0)?,
            reps: uint_prop(node, "reps", 0)?,
        });
    }
    if let Some(body) = node.children() {
        for child in body.nodes() {
            if child.name().value() != "step" {
                return Err(parse_error(format!(
                    "unknown warmup directive: {}",
                    child.name().value()
                )));
            }
            scheme.ramp.push(WarmupStep {
                percentage: uint_prop(child, "intensity", 0)?,
                reps: uint_prop(child, "reps", 0)?,
            });
        }
    }
    if scheme.empty_bar_sets > 0 && scheme.empty_bar_reps == 0 {
        return Err(parse_error("warmup empty-bar reps must be positive"));
    }
    if scheme
        .ramp
        .iter()
        .any(|step| step.percentage == 0 || step.percentage > 100 || step.reps == 0)
    {
        return Err(parse_error(
            "warmup steps require intensity 1-100 and positive reps",
        ));
    }
    Ok(scheme)
}

fn merge_warmup(target: &mut Option<WarmupScheme>, incoming: WarmupScheme) {
    if let Some(existing) = target {
        existing.empty_bar_sets = existing.empty_bar_sets.max(incoming.empty_bar_sets);
        existing.empty_bar_reps = existing.empty_bar_reps.max(incoming.empty_bar_reps);
        existing.ramp.extend(incoming.ramp);
    } else {
        *target = Some(incoming);
    }
}

fn lane_tier(lane: &str) -> String {
    lane.rsplit('.').next().unwrap_or("main").to_owned()
}

/// Vendor the real embedded DSL document for a built-in template.
pub fn vendor_template(input: &str) -> Result<String> {
    let reference = parse_template_ref(input);
    Ok(builtin_template_document(&reference.normalized)?.to_owned())
}

fn args(node: &KdlNode) -> Vec<String> {
    node.entries()
        .iter()
        .filter(|entry| entry.name().is_none())
        .map(|entry| value(entry.value()))
        .collect()
}

fn arg(node: &KdlNode, label: &str) -> Result<String> {
    args(node)
        .into_iter()
        .next()
        .ok_or_else(|| parse_error(format!("{label} is missing")))
}

fn prop(node: &KdlNode, key: &str) -> Option<String> {
    node.entries()
        .iter()
        .rfind(|entry| entry.name().is_some_and(|name| name.value() == key))
        .map(|entry| value(entry.value()))
}

fn uint_prop(node: &KdlNode, key: &str, default: u32) -> Result<u32> {
    optional_uint_prop(node, key).map(|value| value.unwrap_or(default))
}

fn optional_uint_prop(node: &KdlNode, key: &str) -> Result<Option<u32>> {
    prop(node, key)
        .map(|value| {
            value
                .parse()
                .map_err(|_| parse_error(format!("{key} must be an integer")))
        })
        .transpose()
}

fn bool_prop(node: &KdlNode, key: &str, default: bool) -> bool {
    prop(node, key)
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

fn value(value: &KdlValue) -> String {
    if let Some(value) = value.as_string() {
        value.into()
    } else if let Some(value) = value.as_integer() {
        value.to_string()
    } else if let Some(value) = value.as_float() {
        value.to_string()
    } else if let Some(value) = value.as_bool() {
        value.to_string()
    } else {
        String::new()
    }
}

fn parse_error(message: impl Into<String>) -> KnurledError {
    KnurledError::Parse(message.into())
}
