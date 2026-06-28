//! Declarative template-authoring DSL from ADR 0003.
//!
//! The grammar is KDL and deliberately bounded: sessions reference lanes; lanes select a basis,
//! sequence, stage schemes, triggers, and effects. There is no executable code or control flow.

use kdl::{KdlDocument, KdlNode, KdlValue};

use crate::error::{KnurledError, Result};
use crate::model::*;
use crate::parser::normalize_exercise;
use crate::templates::{DEFAULT_TEMPLATE_VERSION, builtin_template, parse_template_ref};

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
    if let Some(node) = body
        .nodes()
        .iter()
        .find(|node| node.name().value() == "builtin")
    {
        return builtin_template(&arg(node, "builtin template reference")?);
    }

    let name = arg(top, "template name")?;
    let version = prop(top, "version").unwrap_or_else(|| DEFAULT_TEMPLATE_VERSION.into());
    let mut rotation = Vec::new();
    let mut rest_seconds = 120;
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
            "session" => {
                let id = arg(node, "session id")?.to_ascii_lowercase();
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
        sessions: sessions.clone(),
        lanes: lanes.clone(),
    };
    let template_slots = sessions
        .iter()
        .map(|(session, items)| {
            let slots = items
                .iter()
                .map(|item| TemplateSlot {
                    slot_id: item.slot_id.clone(),
                    tier: "dsl".into(),
                    exercise: Some(lanes[&item.lane].exercise.clone()),
                    accessory_key: None,
                    default_exercise: None,
                })
                .collect();
            (session.clone(), slots)
        })
        .collect();
    Ok(BuiltinTemplate {
        id: source_id.into(),
        version,
        kind: TemplateKind::Custom,
        default_rotation: rotation,
        sessions: template_slots,
        rest: RestPolicy {
            default_seconds: Some(rest_seconds),
            ..RestPolicy::default()
        },
        lanes: TemplateLaneRules {
            t1_stages: Vec::new(),
            t2_stages: Vec::new(),
            t3_target_reps: 0,
            t3_pass_final_set_reps: 0,
        },
        increments: TemplateIncrements {
            default: 2.5,
            upper: 2.5,
            lower: 5.0,
        },
        weeks: Vec::new(),
        dsl: Some(dsl),
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
    let mut warmup = Vec::new();
    for child in body.nodes() {
        match child.name().value() {
            "stage" => stages.push(parse_stage(child)?),
            "on" => rules.push(parse_rule(child)?),
            "warmup" => warmup.push(WarmupStep {
                percentage: uint_prop(child, "intensity", 0)?,
                reps: uint_prop(child, "reps", 0)?,
            }),
            other => return Err(parse_error(format!("unknown lane directive: {other}"))),
        }
    }
    if stages.is_empty() {
        return Err(parse_error("lane requires at least one stage"));
    }
    Ok(DslLane {
        exercise,
        basis,
        sequence,
        stages,
        rules,
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
        groups.push(DslSetGroup {
            count,
            reps,
            intensity: uint_prop(group, "intensity", 100)?,
            amrap: bool_prop(group, "amrap", false),
            rep_min: optional_uint_prop(group, "rep_min")?,
            rep_max: optional_uint_prop(group, "rep_max")?,
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
        "stall" => DslTrigger::Stall {
            count: uint_prop(node, "count", 1)?,
        },
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
            "recompute_tm" => DslEffect::RecomputeTm {
                amount: prop(effect, "by").unwrap_or_else(|| "2.5".into()),
            },
            "advance_cycle" => DslEffect::AdvanceCycle,
            other => return Err(parse_error(format!("unknown effect: {other}"))),
        });
    }
    Ok(DslRule { trigger, effects })
}

/// Vendor a built-in as a pinned DSL document. The `builtin` bridge is also the parity fixture:
/// parsing it must yield byte-identical output before a built-in can be expanded into primitives.
pub fn vendor_template(input: &str) -> Result<String> {
    let reference = parse_template_ref(input);
    let template = builtin_template(&reference.normalized)?;
    Ok(format!(
        "template \"{}\" version=\"{}\" {{\n  builtin \"{}\"\n}}\n",
        template.id, template.version, reference.normalized
    ))
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
