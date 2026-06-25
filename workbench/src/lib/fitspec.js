// FitSpec (a KDL dialect) <-> plain JS model.
//
// The ENGINE is the only semantic authority — it validates and compiles the raw
// text. This module just lets the form/builder edit a structured projection of
// a plan and regenerate text. The grammar handled here is the "Implemented"
// subset documented in docs/LANGUAGE.md.

// ---- helpers ---------------------------------------------------------------

// Find `header {` at top level of `text` and return the inner body (brace-matched).
function blockBody(text, header) {
  const re = new RegExp(`(^|\\n)\\s*${header}\\b[^\\n{]*\\{`);
  const m = re.exec(text);
  if (!m) return null;
  const open = text.indexOf("{", m.index);
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === "{") depth++;
    else if (text[i] === "}") {
      depth--;
      if (depth === 0) return text.slice(open + 1, i);
    }
  }
  return null;
}

const lines = (body) =>
  (body || "")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("//"));

const unquote = (s) => (s ? s.replace(/^"(.*)"$/s, "$1") : s);

// ---- plan parsing ----------------------------------------------------------

export function parsePlan(text) {
  const model = {
    name: unquote(text.match(/plan\s+"([^"]+)"/)?.[1]) || "Untitled Plan",
    templateId: "gzcl.gzclp",
    templateVersion: "1.0.0",
    units: (text.match(/\bunits\s+(kg|lb)\b/i)?.[1] || "kg").toLowerCase(),
    rotation: [],
    suggestedDays: [],
    starts: {},
    trainingMaxes: {},
    accessories: {},
    exerciseOptions: {},
  };

  // template "id@version"  OR  template "id" version="x"
  const tpl = text.match(/template\s+"([^"]+)"(?:\s+version="([^"]+)")?/);
  if (tpl) {
    if (tpl[1].includes("@")) {
      [model.templateId, model.templateVersion] = tpl[1].split("@");
    } else {
      model.templateId = tpl[1];
      if (tpl[2]) model.templateVersion = tpl[2];
    }
  }

  const sched = blockBody(text, "schedule");
  if (sched) {
    model.rotation = (sched.match(/rotation\s+([^\n]+)/)?.[1] || "").trim().split(/\s+/).filter(Boolean);
    model.suggestedDays = (sched.match(/suggested_days\s+([^\n]+)/)?.[1] || "").trim().split(/\s+/).filter(Boolean);
  }

  for (const [key, block] of [["starts", "starts"], ["trainingMaxes", "training_maxes"]]) {
    const body = blockBody(text, block);
    for (const line of lines(body)) {
      const m = line.match(/^([A-Za-z0-9_]+)\s+(.+)$/);
      if (m) model[key][m[1]] = unquote(m[2].trim());
    }
  }

  for (const line of lines(blockBody(text, "accessories"))) {
    const m = line.match(/^([A-Za-z0-9_.]+)\s+(.+)$/);
    if (m) model.accessories[m[1]] = m[2].trim();
  }

  const opts = blockBody(text, "exercise_options");
  if (opts) {
    const slotRe = /slot\s+"([^"]+)"\s*\{/g;
    let sm;
    while ((sm = slotRe.exec(opts))) {
      const open = opts.indexOf("{", sm.index);
      let depth = 0, end = open;
      for (let i = open; i < opts.length; i++) {
        if (opts[i] === "{") depth++;
        else if (opts[i] === "}") { depth--; if (depth === 0) { end = i; break; } }
      }
      const inner = opts.slice(open + 1, end);
      const slotId = sm.lastIndex;
      const primary = inner.match(/primary\s+([A-Za-z0-9_]+)/)?.[1] || "";
      const alternatives = [];
      const altRe = /([A-Za-z0-9_]+)\s*\{([^}]*)\}/g;
      let am;
      while ((am = altRe.exec(inner))) {
        if (am[1] === "alternatives") continue;
        alternatives.push({
          id: am[1],
          label: unquote(am[2].match(/label\s+("[^"]*"|[^;\n]+)/)?.[1]?.trim()) || am[1],
          policy: am[2].match(/policy\s+(tracking_only|progression_equivalent)/)?.[1] || "tracking_only",
        });
      }
      model.exerciseOptions[sm[1]] = { primary, alternatives };
      slotRe.lastIndex = end;
      void slotId;
    }
  }

  return model;
}

// ---- plan serialization ----------------------------------------------------

export function serializePlan(m) {
  const out = [];
  out.push(`plan "${m.name}" {`);
  out.push(`  template "${m.templateId}" version="${m.templateVersion}"`);
  out.push(`  units ${m.units}`);
  out.push("");
  out.push("  schedule next_workout {");
  out.push(`    rotation ${m.rotation.join(" ")}`);
  out.push(`    suggested_days ${m.suggestedDays.join(" ")}`);
  out.push("  }");

  const mapBlock = (name, obj, quoteVal) => {
    const keys = Object.keys(obj || {});
    if (!keys.length) return;
    out.push("");
    out.push(`  ${name} {`);
    for (const k of keys) out.push(`    ${k} ${quoteVal ? `"${obj[k]}"` : obj[k]}`);
    out.push("  }");
  };
  mapBlock("starts", m.starts, true);
  mapBlock("training_maxes", m.trainingMaxes, true);
  mapBlock("accessories", m.accessories, false);

  const slots = Object.keys(m.exerciseOptions || {}).filter(
    (s) => m.exerciseOptions[s].alternatives?.length || m.exerciseOptions[s].primary,
  );
  if (slots.length) {
    out.push("");
    out.push("  exercise_options {");
    for (const slot of slots) {
      const o = m.exerciseOptions[slot];
      out.push(`    slot "${slot}" {`);
      if (o.primary) out.push(`      primary ${o.primary}`);
      for (const alt of o.alternatives || []) {
        out.push(`      ${alt.id} { label "${alt.label}"; policy ${alt.policy} }`);
      }
      out.push("    }");
    }
    out.push("  }");
  }

  out.push("}");
  out.push("");
  return out.join("\n");
}

// ---- patches ---------------------------------------------------------------

export function serializePatch(p) {
  const out = [`patch "${p.name}" {`];
  if (p.description) out.push(`  description "${p.description}"`);
  if (p.activeFrom) out.push(`  active-from "${p.activeFrom}"`);
  if (p.expires) out.push(`  expires "${p.expires}"`);
  for (const op of p.operations || []) {
    if (op.op === "replace-exercise") out.push(`  replace-exercise from=${op.from} to=${op.to} lane="${op.lane}"`);
    else if (op.op === "add-conditioning") out.push(`  add-conditioning day=${op.day} activity="${op.activity}"`);
    else if (op.op === "cap") out.push(`  cap target=${op.target} value="${op.value}"${op.lane ? ` lane="${op.lane}"` : ""}`);
  }
  out.push("}");
  out.push("");
  return out.join("\n");
}
