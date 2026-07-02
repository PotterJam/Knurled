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

/// Canonical `.fitspec` serializer — the inverse of [`parse_template_dsl`].
///
/// The round-trip invariant `parse_template_dsl(render_template_dsl(d)).dsl == d`
/// holds for every valid [`DslTemplate`]: the app edits a structured model and
/// renders it here so the engine remains the sole producer of DSL text. The
/// output is *canonical*, not byte-identical to a hand-authored source file —
/// maps are emitted in key order and incidental whitespace is normalized — so
/// `render ∘ parse` is a fixed point but is not guaranteed to reproduce
/// arbitrary source formatting.
pub fn render_template_dsl(dsl: &DslTemplate) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "template {} version={} {{\n",
        kdl_string(&dsl.name),
        kdl_string(&dsl.version)
    ));

    out.push_str("  rotation");
    for session in &dsl.rotation {
        out.push(' ');
        out.push_str(&ident_or_quoted(session));
    }
    out.push('\n');
    out.push_str(&format!("  rest {}\n", dsl.rest_seconds));
    if let Some(warmup) = &dsl.warmup {
        render_warmup(&mut out, "  ", warmup);
    }

    for (id, items) in &dsl.sessions {
        out.push_str("  session ");
        out.push_str(&ident_or_quoted(id));
        if let Some(display) = dsl.session_display_names.get(id) {
            out.push_str(&format!(" display={}", kdl_string(display)));
        }
        out.push_str(" {\n");
        for item in items {
            out.push_str(&format!(
                "    item {} slot={}",
                kdl_string(&item.lane),
                kdl_string(&item.slot_id)
            ));
            if let Some(accessory) = &item.accessory_key {
                out.push_str(&format!(" accessory={}", kdl_string(accessory)));
            }
            if let Some(default_exercise) = &item.default_exercise {
                out.push_str(&format!(
                    " default_exercise={}",
                    kdl_string(default_exercise)
                ));
            }
            out.push('\n');
        }
        out.push_str("  }\n");
    }

    for (id, lane) in &dsl.lanes {
        render_lane(&mut out, id, lane);
    }

    out.push_str("}\n");
    out
}

fn render_lane(out: &mut String, id: &str, lane: &DslLane) {
    out.push_str(&format!(
        "  lane {} exercise={}",
        kdl_string(id),
        kdl_string(&lane.exercise)
    ));
    if let Some(tier) = &lane.tier {
        out.push_str(&format!(" tier={}", kdl_string(tier)));
    }
    out.push_str(&format!(" basis={}", kdl_string(basis_word(lane.basis))));
    match lane.initial {
        DslInitial::Basis => {}
        DslInitial::Performed => out.push_str(" initial=\"performed\""),
        DslInitial::Percent { percentage } => out.push_str(&format!(" initial=\"{percentage}%\"")),
    }
    if lane.sequence != DslSequence::None {
        out.push_str(&format!(
            " sequence={}",
            kdl_string(sequence_word(lane.sequence))
        ));
    }
    if let Some(rest) = lane.rest_seconds {
        out.push_str(&format!(" rest={rest}"));
    }
    out.push_str(" {\n");

    if let Some(warmup) = &lane.warmup {
        render_warmup(out, "    ", warmup);
    }
    for stage in &lane.stages {
        render_stage(out, stage);
    }
    for rule in &lane.rules {
        render_rule(out, rule);
    }
    out.push_str("  }\n");
}

fn render_stage(out: &mut String, stage: &DslStage) {
    if stage.groups.len() == 1 {
        out.push_str(&format!("    stage {} {{ ", kdl_string(&stage.id)));
        render_set_group(out, &stage.groups[0]);
        out.push_str(" }\n");
        return;
    }
    out.push_str(&format!("    stage {} {{\n", kdl_string(&stage.id)));
    for group in &stage.groups {
        out.push_str("      ");
        render_set_group(out, group);
        out.push('\n');
    }
    out.push_str("    }\n");
}

fn render_set_group(out: &mut String, group: &DslSetGroup) {
    out.push_str(&format!("set count={} reps={}", group.count, group.reps));
    if group.intensity != 100 {
        out.push_str(&format!(" intensity={}", group.intensity));
    }
    if let Some(rep_min) = group.rep_min {
        out.push_str(&format!(" rep_min={rep_min}"));
    }
    if let Some(rep_max) = group.rep_max {
        out.push_str(&format!(" rep_max={rep_max}"));
    }
    if group.amrap {
        out.push_str(" amrap=#true");
    }
    if let Some(rpe) = group.rpe {
        out.push_str(&format!(" rpe={rpe}"));
    }
}

fn render_rule(out: &mut String, rule: &DslRule) {
    out.push_str("    on ");
    match &rule.trigger {
        DslTrigger::Pass => out.push_str("pass"),
        DslTrigger::Fail => out.push_str("fail"),
        DslTrigger::AmrapGte { reps } => out.push_str(&format!("amrap_gte reps={reps}")),
        DslTrigger::Stall { count } => out.push_str(&format!("stall count={count}")),
        DslTrigger::CycleEnd => out.push_str("cycle_end"),
        DslTrigger::RangeTop => out.push_str("range_top"),
    }
    if let Some(stage) = &rule.stage {
        out.push_str(&format!(" stage={}", kdl_string(stage)));
    }
    out.push_str(" { ");
    let effects: Vec<String> = rule.effects.iter().map(render_effect).collect();
    out.push_str(&effects.join("; "));
    out.push_str(" }\n");
}

fn render_effect(effect: &DslEffect) -> String {
    match effect {
        DslEffect::IncreaseLoad { amount } => format!("increase_load by={}", kdl_string(amount)),
        DslEffect::Deload { percent } => format!("deload percent={percent}"),
        DslEffect::ResetLoad { percent } => format!("reset_load percent={percent}"),
        DslEffect::AdvanceStage => "advance_stage".into(),
        DslEffect::ResetStage => "reset_stage".into(),
        DslEffect::IncreaseReps { amount } => format!("increase_reps by={amount}"),
        DslEffect::ResetReps => "reset_reps".into(),
        DslEffect::RecomputeTm { amount } => format!("recompute_tm by={}", kdl_string(amount)),
        DslEffect::AdvanceCycle => "advance_cycle".into(),
    }
}

fn render_warmup(out: &mut String, indent: &str, warmup: &WarmupScheme) {
    out.push_str(&format!(
        "{indent}warmup basis={}",
        kdl_string(warmup_basis_word(&warmup.basis))
    ));
    if warmup.empty_bar_sets > 0 {
        out.push_str(&format!(
            " empty_bar_sets={} empty_bar_reps={}",
            warmup.empty_bar_sets, warmup.empty_bar_reps
        ));
    }
    if warmup.ramp.is_empty() {
        out.push('\n');
        return;
    }
    out.push_str(" {\n");
    for step in &warmup.ramp {
        out.push_str(&format!(
            "{indent}  step intensity={} reps={}\n",
            step.percentage, step.reps
        ));
    }
    out.push_str(&format!("{indent}}}\n"));
}

fn basis_word(basis: DslBasis) -> &'static str {
    match basis {
        DslBasis::WorkingWeight => "working_weight",
        DslBasis::TrainingMax => "training_max",
        DslBasis::Bodyweight => "bodyweight",
    }
}

fn sequence_word(sequence: DslSequence) -> &'static str {
    match sequence {
        DslSequence::None => "none",
        DslSequence::Stages => "stages",
        DslSequence::Cycle => "cycle",
        DslSequence::Waves => "waves",
        DslSequence::Rotation => "rotation",
    }
}

fn warmup_basis_word(basis: &WarmupBasis) -> &'static str {
    match basis {
        WarmupBasis::TopSet => "top_set",
        WarmupBasis::WorkingWeight => "working_weight",
        WarmupBasis::TrainingMax => "training_max",
    }
}

/// Emits a bare KDL word when `value` is a simple identifier, else a quoted
/// string. Session ids are lower-cased and usually bare in source; lane/slot
/// references carry dots and are always quoted via [`kdl_string`].
fn ident_or_quoted(value: &str) -> String {
    if !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    {
        value.to_owned()
    } else {
        kdl_string(value)
    }
}

fn kdl_string(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
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
