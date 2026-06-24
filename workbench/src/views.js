// View renderers. Each takes (root, ctx) and renders into `root`, wiring its own
// listeners. `ctx` carries the latest engine result and the shared actions.
//
// ctx = {
//   state, result (BuildOutputs | null), error (string | null),
//   templates (catalog), exercises,
//   setPlanText(text), setPlanModel(model), setState(patch),
//   setView(id), build(), simulate(weeks, strategy), importHistory(text, source, delim),
//   github: { connect, load, commit }, status,
// }
import { parsePlan, serializePlan, serializePatch } from "./fitspec.js";
import { lineChart, legend } from "./charts.js";

const esc = (v) =>
  String(v ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const titleCase = (v) => String(v).split(/[_\s]+/).map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join(" ");

const PALETTE = ["#618FEB", "#8CB587", "#D4A350", "#A378EB", "#cf6d6d", "#46b1a8"];

function importSetSummary(set) {
  return [set.load, set.reps ? `${set.reps} reps` : ""].filter(Boolean).join(" x ");
}

function importExerciseSummary(result) {
  const name = titleCase(result.performed_exercise || result.slot_id || "Exercise");
  const sets = (result.actual || []).slice(0, 4).map(importSetSummary).filter(Boolean);
  const more = (result.actual || []).length > sets.length ? ` +${result.actual.length - sets.length} sets` : "";
  return `${name}: ${sets.join(", ")}${more}`;
}

// --------------------------------------------------------------------------
// Overview
// --------------------------------------------------------------------------
export function overview(root, ctx) {
  const r = ctx.result;
  const next = r?.next_workout;
  const actions = [
    ["editor", "Edit program", "Build & tune the plan visually"],
    ["next", "Next workout", "See the rendered session"],
    ["simulate", "Simulate", "Project weeks forward"],
    ["backtest", "Backtest", "Replay & check determinism"],
    ["history", "Import history", "Fold past logs in"],
    ["git", "Commit", "Push to GitHub"],
  ];
  root.innerHTML = `
    <div class="stack">
      <div class="hero card">
        <div>
          <p class="eyebrow">Next workout</p>
          <h2>${next ? esc(next.display_name) : "—"}</h2>
          <p class="muted">${
            next
              ? next.items.map((i) => esc(titleCase(i.exercise))).join(" · ")
              : ctx.error
                ? esc(ctx.error)
                : "Plan is invalid — fix validation to render."
          }</p>
        </div>
        <span class="pill ${r?.validation?.status === "valid" ? "ok" : "bad"}">${esc(r?.validation?.status || "error")}</span>
      </div>
      <div class="action-grid">
        ${actions
          .map(
            ([id, label, sub]) =>
              `<button class="action-card" data-go="${id}"><strong>${esc(label)}</strong><span>${esc(sub)}</span></button>`,
          )
          .join("")}
      </div>
    </div>`;
  root.querySelectorAll("[data-go]").forEach((b) => b.addEventListener("click", () => ctx.setView(b.dataset.go)));
}

// --------------------------------------------------------------------------
// Editor: Builder / Form / Raw
// --------------------------------------------------------------------------
let editorTab = "builder";

export function editor(root, ctx) {
  root.innerHTML = `
    <div class="subtabs">
      ${["builder", "form", "raw"]
        .map((t) => `<button class="subtab ${t === editorTab ? "active" : ""}" data-tab="${t}">${titleCase(t)}</button>`)
        .join("")}
      <span class="grow"></span>
      <span class="pill ${ctx.result?.validation?.status === "valid" ? "ok" : "bad"}">${esc(ctx.result?.validation?.status || "error")}</span>
    </div>
    <div class="editor-body" id="editor-body"></div>`;
  root.querySelectorAll(".subtab").forEach((b) =>
    b.addEventListener("click", () => {
      editorTab = b.dataset.tab;
      editor(root, ctx);
    }),
  );
  const body = root.querySelector("#editor-body");
  if (editorTab === "raw") rawEditor(body, ctx);
  else if (editorTab === "form") formEditor(body, ctx);
  else builderEditor(body, ctx);
}

function rawEditor(root, ctx) {
  root.innerHTML = `<textarea id="raw" spellcheck="false">${esc(ctx.state.planText)}</textarea>
    <div class="validation-rail" id="vrail"></div>`;
  const ta = root.querySelector("#raw");
  ta.addEventListener("input", () => ctx.setPlanText(ta.value));
  renderValidationRail(root.querySelector("#vrail"), ctx);
}

function formEditor(root, ctx) {
  const m = parsePlan(ctx.state.planText);
  const templateOpts = ctx.templates
    .map((t) => `<option value="${t.ref}" ${t.id === m.templateId ? "selected" : ""}>${esc(t.display_name)}</option>`)
    .join("");
  const lifts = Object.keys({ ...m.starts, ...m.trainingMaxes, squat: 1, bench: 1, press: 1, deadlift: 1 });
  root.innerHTML = `
    <div class="form stack">
      <label>Plan name <input id="f-name" value="${esc(m.name)}"></label>
      <div class="row">
        <label>Template <select id="f-template">${templateOpts}</select></label>
        <label>Units
          <select id="f-units">
            <option value="kg" ${m.units === "kg" ? "selected" : ""}>kg</option>
            <option value="lb" ${m.units === "lb" ? "selected" : ""}>lb</option>
          </select>
        </label>
      </div>
      <label>Rotation <input id="f-rotation" value="${esc(m.rotation.join(" "))}"></label>
      <label>Suggested days <input id="f-days" value="${esc(m.suggestedDays.join(" "))}"></label>
      <fieldset><legend>Starting weights</legend>
        <div class="grid2">
          ${lifts
            .map(
              (l) =>
                `<label>${titleCase(l)} <input data-start="${l}" value="${esc(m.starts[l] || m.trainingMaxes[l] || "")}"></label>`,
            )
            .join("")}
        </div>
      </fieldset>
      <div class="validation-rail" id="vrail"></div>
    </div>`;

  const commit = () => {
    const next = parsePlan(ctx.state.planText);
    next.name = root.querySelector("#f-name").value || "Untitled Plan";
    const ref = root.querySelector("#f-template").value;
    [next.templateId, next.templateVersion] = ref.includes("@") ? ref.split("@") : [ref, next.templateVersion];
    next.units = root.querySelector("#f-units").value;
    next.rotation = root.querySelector("#f-rotation").value.trim().split(/\s+/).filter(Boolean);
    next.suggestedDays = root.querySelector("#f-days").value.trim().split(/\s+/).filter(Boolean);
    root.querySelectorAll("[data-start]").forEach((inp) => {
      const v = inp.value.trim();
      if (v) next.starts[inp.dataset.start] = v;
      else delete next.starts[inp.dataset.start];
    });
    ctx.setPlanModel(next);
  };
  root.querySelectorAll("input, select").forEach((el) => el.addEventListener("change", commit));
  renderValidationRail(root.querySelector("#vrail"), ctx);
}

// ---- Builder (drag & drop) ----
function builderEditor(root, ctx) {
  const m = parsePlan(ctx.state.planText);
  const tpl = ctx.templates.find((t) => t.id === m.templateId) || ctx.templates[0];
  const sessions = tpl?.skeleton?.sessions || {};

  const byPattern = {};
  for (const ex of ctx.exercises) (byPattern[ex.pattern] ||= []).push(ex);

  root.innerHTML = `
    <div class="builder">
      <aside class="palette">
        <input id="ex-search" placeholder="Search exercises…" />
        <div class="palette-list" id="palette-list">
          ${Object.entries(byPattern)
            .map(
              ([pattern, items]) => `
            <div class="palette-group">
              <h4>${esc(titleCase(pattern))}</h4>
              ${items
                .map(
                  (ex) =>
                    `<div class="ex-chip" draggable="true" data-ex="${ex.id}" title="${esc(ex.muscles.join(", "))}">${esc(ex.label)}</div>`,
                )
                .join("")}
            </div>`,
            )
            .join("")}
        </div>
        <button class="ghost" id="add-custom">+ Custom exercise</button>
      </aside>

      <div class="canvas stack">
        <section class="card">
          <h3>Rotation</h3>
          <p class="muted small">Drag to reorder the session cycle.</p>
          <div class="rotation" id="rotation">
            ${m.rotation.map((s, i) => `<span class="rot-chip" draggable="true" data-idx="${i}">${esc(s)}</span>`).join("")}
          </div>
          <div class="days" id="days">
            ${["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
              .map(
                (d) =>
                  `<button class="day ${m.suggestedDays.includes(d) ? "on" : ""}" data-day="${d}">${esc(d)}</button>`,
              )
              .join("")}
          </div>
        </section>

        <section class="sessions">
          ${Object.entries(sessions)
            .map(([name, slots]) => sessionCard(name, slots, m))
            .join("")}
        </section>
      </div>
    </div>`;

  // --- palette search
  const search = root.querySelector("#ex-search");
  search.addEventListener("input", () => {
    const q = search.value.toLowerCase();
    root.querySelectorAll(".ex-chip").forEach((c) => {
      c.style.display = c.textContent.toLowerCase().includes(q) ? "" : "none";
    });
  });

  // --- palette drag
  root.querySelectorAll(".ex-chip").forEach((chip) => {
    chip.addEventListener("dragstart", (e) => e.dataTransfer.setData("text/exercise", chip.dataset.ex));
  });

  // --- slot drop targets
  root.querySelectorAll("[data-slot-key]").forEach((zone) => {
    zone.addEventListener("dragover", (e) => {
      e.preventDefault();
      zone.classList.add("drag-over");
    });
    zone.addEventListener("dragleave", () => zone.classList.remove("drag-over"));
    zone.addEventListener("drop", (e) => {
      e.preventDefault();
      const ex = e.dataTransfer.getData("text/exercise");
      if (!ex) return;
      const next = parsePlan(ctx.state.planText);
      const key = zone.dataset.slotKey;
      if (zone.dataset.role === "alt") {
        const opt = (next.exerciseOptions[key] ||= { primary: next.accessories[key] || "", alternatives: [] });
        if (!opt.alternatives.some((a) => a.id === ex)) {
          const label = ctx.exercises.find((x) => x.id === ex)?.label || titleCase(ex);
          opt.alternatives.push({ id: ex, label, policy: "tracking_only" });
        }
      } else {
        next.accessories[key] = ex;
      }
      ctx.setPlanModel(next);
    });
  });

  // --- remove accessory / alternative
  root.querySelectorAll("[data-remove-alt]").forEach((b) =>
    b.addEventListener("click", () => {
      const next = parsePlan(ctx.state.planText);
      const [key, id] = b.dataset.removeAlt.split("|");
      const opt = next.exerciseOptions[key];
      if (opt) opt.alternatives = opt.alternatives.filter((a) => a.id !== id);
      ctx.setPlanModel(next);
    }),
  );
  root.querySelectorAll("[data-policy]").forEach((b) =>
    b.addEventListener("click", () => {
      const next = parsePlan(ctx.state.planText);
      const [key, id] = b.dataset.policy.split("|");
      const alt = next.exerciseOptions[key]?.alternatives.find((a) => a.id === id);
      if (alt) alt.policy = alt.policy === "tracking_only" ? "progression_equivalent" : "tracking_only";
      ctx.setPlanModel(next);
    }),
  );

  // --- day toggles
  root.querySelectorAll("[data-day]").forEach((b) =>
    b.addEventListener("click", () => {
      const next = parsePlan(ctx.state.planText);
      const d = b.dataset.day;
      next.suggestedDays = next.suggestedDays.includes(d)
        ? next.suggestedDays.filter((x) => x !== d)
        : [...next.suggestedDays, d];
      ctx.setPlanModel(next);
    }),
  );

  // --- rotation drag-reorder
  let dragIdx = null;
  root.querySelectorAll(".rot-chip").forEach((chip) => {
    chip.addEventListener("dragstart", () => (dragIdx = Number(chip.dataset.idx)));
    chip.addEventListener("dragover", (e) => e.preventDefault());
    chip.addEventListener("drop", () => {
      const target = Number(chip.dataset.idx);
      if (dragIdx === null || dragIdx === target) return;
      const next = parsePlan(ctx.state.planText);
      const [moved] = next.rotation.splice(dragIdx, 1);
      next.rotation.splice(target, 0, moved);
      ctx.setPlanModel(next);
    });
  });

  root.querySelector("#add-custom").addEventListener("click", () => {
    const id = prompt("Exercise id (snake_case), e.g. landmine_press");
    if (id) {
      const clean = id.trim().toLowerCase().replace(/\s+/g, "_");
      ctx.addCustomExercise({ id: clean, label: titleCase(clean), pattern: "custom", muscles: [] });
    }
  });
}

function sessionCard(name, slots, m) {
  return `<div class="session card">
    <h3>${esc(name)}</h3>
    ${slots
      .map((slot) => {
        const isAccessory = !!slot.accessory_key;
        const key = slot.accessory_key;
        const current = isAccessory ? m.accessories[key] || slot.default_exercise || "" : slot.exercise || slot.default_exercise || "";
        const opt = isAccessory ? m.exerciseOptions[key] : null;
        return `<div class="slot ${isAccessory ? "editable" : "locked"}">
          <span class="tier">${esc((slot.tier || "").toUpperCase())}</span>
          ${
            isAccessory
              ? `<div class="slot-drop" data-slot-key="${esc(key)}" data-role="primary">${current ? esc(titleCase(current)) : "drop an exercise"}</div>
                 <div class="alts">
                   ${(opt?.alternatives || [])
                     .map(
                       (a) =>
                         `<span class="alt-chip">${esc(a.label)}
                            <button class="policy ${a.policy}" data-policy="${esc(key)}|${esc(a.id)}" title="toggle policy">${a.policy === "progression_equivalent" ? "≡" : "~"}</button>
                            <button class="x" data-remove-alt="${esc(key)}|${esc(a.id)}">×</button>
                          </span>`,
                     )
                     .join("")}
                   <span class="alt-drop" data-slot-key="${esc(key)}" data-role="alt">+ alternative</span>
                 </div>`
              : `<span class="slot-fixed">${esc(titleCase(current))}</span>`
          }
        </div>`;
      })
      .join("")}
  </div>`;
}

function renderValidationRail(root, ctx) {
  if (!root) return;
  const v = ctx.result?.validation;
  if (ctx.error) {
    root.innerHTML = `<p class="msg bad">${esc(ctx.error)}</p>`;
    return;
  }
  if (!v) return;
  const msgs = [...v.errors.map((e) => ["bad", e]), ...v.warnings.map((w) => ["warn", w])];
  root.innerHTML = msgs.length
    ? msgs.map(([k, msg]) => `<p class="msg ${k}"><code>${esc(msg.code || "")}</code> ${esc(msg.message)}</p>`).join("")
    : `<p class="msg ok">Plan is valid.</p>`;
}

// --------------------------------------------------------------------------
// Patches
// --------------------------------------------------------------------------
export function patches(root, ctx) {
  const list = ctx.state.patches;
  root.innerHTML = `
    <div class="stack">
      <div class="card">
        <div class="card-head"><h3>Patches</h3><button class="ghost" id="add-patch">+ Add modification</button></div>
        <p class="muted small">Layered, toggleable changes (injury, travel, deload). Recompiles live.</p>
        ${
          list.length
            ? list
                .map(
                  (p, i) => `
          <div class="patch-row">
            <label class="switch"><input type="checkbox" data-toggle="${i}" ${p.active !== false ? "checked" : ""}><span></span></label>
            <div><strong>${esc(p.name)}</strong><pre class="patch-text">${esc(p.text.trim())}</pre></div>
            <button class="x" data-del="${i}">×</button>
          </div>`,
                )
                .join("")
            : `<p class="muted">No patches yet.</p>`
        }
      </div>
      <div class="card" id="patch-form" hidden></div>
    </div>`;

  root.querySelectorAll("[data-toggle]").forEach((cb) =>
    cb.addEventListener("change", () => {
      const next = ctx.state.patches.slice();
      next[Number(cb.dataset.toggle)] = { ...next[Number(cb.dataset.toggle)], active: cb.checked };
      ctx.setState({ patches: next });
    }),
  );
  root.querySelectorAll("[data-del]").forEach((b) =>
    b.addEventListener("click", () => {
      const next = ctx.state.patches.slice();
      next.splice(Number(b.dataset.del), 1);
      ctx.setState({ patches: next });
    }),
  );
  root.querySelector("#add-patch").addEventListener("click", () => renderPatchForm(root.querySelector("#patch-form"), ctx));
}

function renderPatchForm(root, ctx) {
  root.hidden = false;
  root.innerHTML = `
    <div class="card-head"><h3>New modification</h3></div>
    <div class="form stack">
      <label>Name <input id="p-name" placeholder="shoulder-friendly-press"></label>
      <label>Type
        <select id="p-op">
          <option value="add-conditioning">Add conditioning day</option>
          <option value="replace-exercise">Swap an exercise</option>
          <option value="cap">Cap a target</option>
        </select>
      </label>
      <div id="p-fields"></div>
      <div class="row"><button id="p-save">Add modification</button></div>
    </div>`;

  const fields = root.querySelector("#p-fields");
  const renderFields = () => {
    const op = root.querySelector("#p-op").value;
    if (op === "add-conditioning")
      fields.innerHTML = `<label>Day <input id="a-day" placeholder="sat"></label><label>Activity <input id="a-act" placeholder="zone2 run 30m"></label>`;
    else if (op === "replace-exercise")
      fields.innerHTML = `<label>From <input id="a-from" placeholder="overhead_press"></label><label>To <input id="a-to" placeholder="incline_db_press"></label><label>Lane regex <input id="a-lane" placeholder="press\\.t1"></label>`;
    else
      fields.innerHTML = `<label>Target <input id="a-target" placeholder="rpe"></label><label>Value <input id="a-value" placeholder="8"></label><label>Lane regex (optional) <input id="a-lane" placeholder="squat\\..*"></label>`;
  };
  renderFields();
  root.querySelector("#p-op").addEventListener("change", renderFields);

  root.querySelector("#p-save").addEventListener("click", () => {
    const name = root.querySelector("#p-name").value.trim() || "modification";
    const op = root.querySelector("#p-op").value;
    let operation;
    const val = (id) => root.querySelector(id)?.value.trim();
    if (op === "add-conditioning") operation = { op, day: val("#a-day"), activity: val("#a-act") };
    else if (op === "replace-exercise") operation = { op, from: val("#a-from"), to: val("#a-to"), lane: val("#a-lane") };
    else operation = { op, target: val("#a-target"), value: val("#a-value"), lane: val("#a-lane") || undefined };

    const patch = { name, operations: [operation] };
    const text = serializePatch(patch);
    const filename = `${name.replace(/[^a-z0-9-]+/gi, "-").toLowerCase()}.fitspec`;
    ctx.setState({ patches: [...ctx.state.patches, { filename, name, text, active: true }] });
  });
}

// --------------------------------------------------------------------------
// Next workout (rendered session)
// --------------------------------------------------------------------------
export function next(root, ctx) {
  const session = ctx.result?.next_workout;
  if (!session) {
    root.innerHTML = `<div class="card"><p class="msg bad">${esc(ctx.error || "Plan invalid — no session to render.")}</p></div>`;
    return;
  }
  root.innerHTML = `
    <div class="session-render">
      <div class="session-head">
        <h2>${esc(session.display_name)}</h2>
        ${session.suggested_date ? `<span class="muted">${esc(session.suggested_date)}</span>` : ""}
      </div>
      ${session.items
        .map((item) => {
          const sets = item.prescription.sets
            .map(
              (s) =>
                `<div class="set"><span class="set-n">${s.set}</span><span>${esc(s.load || "—")}</span><span>${esc(s.target_reps ?? "")}${s.amrap ? "+" : ""} reps</span></div>`,
            )
            .join("");
          const restSecs = item.rest?.seconds;
          return `<article class="exercise-card">
            <header><h3>${esc(item.display?.title || titleCase(item.exercise))}</h3><span class="lane">${esc(item.progression_lane)}</span></header>
            <div class="sets">${sets}</div>
            ${restSecs ? `<p class="rest">Rest ${Math.round(restSecs / 60)}m ${restSecs % 60 ? `${restSecs % 60}s` : ""}</p>` : ""}
          </article>`;
        })
        .join("")}
    </div>`;
}

// --------------------------------------------------------------------------
// Simulation (charts)
// --------------------------------------------------------------------------
let simWeeks = 8;
let simStrategy = "all-pass";

export function simulation(root, ctx) {
  root.innerHTML = `
    <div class="stack">
      <div class="card-head">
        <h3>Simulation</h3>
        <div class="row">
          <label>Weeks <input id="sim-weeks" type="number" min="1" max="52" value="${simWeeks}" style="width:64px"></label>
          <label>Strategy
            <select id="sim-strategy">
              <option value="all-pass" ${simStrategy === "all-pass" ? "selected" : ""}>all-pass</option>
              <option value="all-fail" ${simStrategy === "all-fail" ? "selected" : ""}>all-fail</option>
            </select>
          </label>
          <button id="sim-run">Run</button>
        </div>
      </div>
      <div id="sim-out"></div>
    </div>`;

  const out = root.querySelector("#sim-out");
  const run = () => {
    simWeeks = Number(root.querySelector("#sim-weeks").value) || 8;
    simStrategy = root.querySelector("#sim-strategy").value;
    let report;
    try {
      report = ctx.simulate(simWeeks, simStrategy);
    } catch (e) {
      out.innerHTML = `<div class="card"><p class="msg bad">${esc(e.message)}</p></div>`;
      return;
    }
    renderSim(out, report);
  };
  root.querySelector("#sim-run").addEventListener("click", run);
  run();
}

function renderSim(out, report) {
  // Build per-lift load series from effects that carry a numeric load.
  const series = {};
  report.sessions.forEach((s, idx) => {
    for (const eff of s.effects || []) {
      const lane = eff.lane || "lift";
      const load = numeric(eff.to); // Effect.to carries the new load string
      if (load == null) continue;
      (series[lane] ||= Array(report.sessions.length).fill(null))[idx] = load;
    }
  });
  const lanes = Object.keys(series);
  const chartSeries = lanes.map((lane, i) => ({
    label: titleCase(lane),
    color: PALETTE[i % PALETTE.length],
    points: forwardFill(series[lane]),
  }));

  out.innerHTML = `
    <div class="card">
      <h4>Projected working load</h4>
      ${chartSeries.length ? lineChart(chartSeries) + legend(chartSeries) : `<p class="muted">No numeric load effects to chart for this strategy.</p>`}
    </div>
    <div class="card">
      <h4>Session timeline</h4>
      <div class="timeline">
        ${report.sessions
          .map(
            (s) =>
              `<div class="tl-row"><span class="tl-n">${s.index}</span><strong>${esc(s.display_name)}</strong><span class="muted small">${esc((s.effects || []).map((e) => `${e.lane} ${e.op}${e.to ? ` → ${e.to}` : ""}`).join(", "))}</span></div>`,
          )
          .join("")}
      </div>
    </div>`;
}

const numeric = (v) => {
  if (v == null) return null;
  const n = Number(String(v).match(/[0-9.]+/)?.[0]);
  return Number.isFinite(n) ? n : null;
};
function forwardFill(arr) {
  let last = 0;
  return arr.map((v) => (v == null ? last : (last = v)));
}

// --------------------------------------------------------------------------
// History import
// --------------------------------------------------------------------------
function mergeEvents(existing, incoming) {
  const merged = [...(existing || [])];
  const seen = new Set(merged.map((event) => event.id).filter(Boolean));
  let added = 0;
  for (const event of incoming || []) {
    if (event.id && seen.has(event.id)) continue;
    if (event.id) seen.add(event.id);
    merged.push(event);
    added++;
  }
  return { events: merged, added };
}

export function history(root, ctx) {
  const historyNotice = ctx.state.ui?.historyNotice;
  root.innerHTML = `
    <div class="stack">
      ${
        historyNotice
          ? `<div class="card">
              <div class="card-head">
                <h3>${esc(historyNotice.title)}</h3>
                <div class="row">
                  <button id="hist-commit">Commit imported data</button>
                  <button class="ghost" id="hist-backtest">Review backtest</button>
                </div>
              </div>
              <p class="msg ${historyNotice.kind}">${esc(historyNotice.message)}</p>
            </div>`
          : ""
      }
      <div class="card">
        <div class="card-head"><h3>Import history</h3></div>
        <p class="muted small">Paste or drop a CSV/TSV export (e.g. Hevy). The engine parses it — nothing is reimplemented here.</p>
        <div class="dropzone" id="drop">Drop a .csv / .tsv here, or paste below</div>
        <textarea id="hist-text" spellcheck="false" placeholder="completed_at,exercise,set,reps,load&#10;2026-01-02,squat,1,5,80kg"></textarea>
        <div class="row">
          <label>Source <input id="hist-source" value="hevy"></label>
          <button id="hist-run">Preview import</button>
        </div>
      </div>
      <div id="hist-out"></div>
    </div>`;

  root.querySelector("#hist-commit")?.addEventListener("click", () => ctx.setView("git"));
  root.querySelector("#hist-backtest")?.addEventListener("click", () => ctx.setView("backtest"));

  const text = root.querySelector("#hist-text");
  const drop = root.querySelector("#drop");
  drop.addEventListener("dragover", (e) => {
    e.preventDefault();
    drop.classList.add("drag-over");
  });
  drop.addEventListener("dragleave", () => drop.classList.remove("drag-over"));
  drop.addEventListener("drop", async (e) => {
    e.preventDefault();
    drop.classList.remove("drag-over");
    const file = e.dataTransfer.files[0];
    if (file) text.value = await file.text();
  });

  const out = root.querySelector("#hist-out");
  root.querySelector("#hist-run").addEventListener("click", () => {
    let draft;
    try {
      draft = ctx.importHistory(text.value, root.querySelector("#hist-source").value);
    } catch (err) {
      out.innerHTML = `<div class="card"><p class="msg bad">${esc(err.message)}</p></div>`;
      return;
    }
    out.innerHTML = `
      <div class="card">
        <div class="card-head"><h4>Parsed ${draft.events.length} session events · ${draft.imported_sets} sets from ${draft.input_rows} rows</h4>
          <button id="hist-accept">Add to plan data</button></div>
        <div class="timeline import-preview">
          ${draft.events
            .slice(0, 40)
            .map((ev) => {
              const setCount = (ev.results || []).reduce((sum, result) => sum + (result.actual || []).length, 0);
              const exerciseCount = (ev.results || []).length;
              const date = (ev.completed_at || "").replace("T00:00:00Z", "");
              const detail = (ev.results || []).slice(0, 4).map(importExerciseSummary).join(" · ");
              const more = (ev.results || []).length > 4 ? ` · +${ev.results.length - 4} exercises` : "";
              return `<div class="import-row">
                <div class="import-main">
                  <strong>${esc(ev.reason || ev.session_id || ev.id)}</strong>
                  <span class="muted small">${esc(date)}</span>
                </div>
                <span class="muted small">${exerciseCount} exercises · ${setCount} sets</span>
                <span class="import-detail">${esc(detail + more)}</span>
              </div>`;
            })
            .join("")}
        </div>
      </div>`;
    out.querySelector("#hist-accept").addEventListener("click", () => {
      const merged = mergeEvents(ctx.state.events, draft.events);
      const historyNotice = {
        kind: "ok",
        title: "Import added",
        message:
          merged.added === draft.events.length
            ? `Added ${merged.added} imported session event${merged.added === 1 ? "" : "s"} to plan data.`
            : `Added ${merged.added} new session event${merged.added === 1 ? "" : "s"}; skipped ${
                draft.events.length - merged.added
              } duplicate${draft.events.length - merged.added === 1 ? "" : "s"}.`,
      };
      ctx.setState({ events: merged.events, ui: { ...ctx.state.ui, historyNotice } });
    });
  });
}

// --------------------------------------------------------------------------
// Backtest
// --------------------------------------------------------------------------
export function backtest(root, ctx) {
  const r = ctx.result;
  if (!r) {
    root.innerHTML = `<div class="card"><p class="msg bad">${esc(ctx.error || "Plan invalid.")}</p></div>`;
    return;
  }
  const cursor = r.state?.cursor;
  root.innerHTML = `
    <div class="stack">
      <div class="card">
        <div class="card-head"><h3>Backtest</h3><span class="pill ${r.validation.status === "valid" ? "ok" : "bad"}">${esc(r.validation.status)}</span></div>
        <p class="muted small">${ctx.state.events.length} events replayed deterministically through the engine.</p>
        <div class="kv">
          <div><span>Events</span><strong>${ctx.state.events.length}</strong></div>
          <div><span>Last event</span><strong>${esc(r.state?.last_event_id || "—")}</strong></div>
          <div><span>Cursor</span><strong>${esc(cursor ? JSON.stringify(cursor) : "—")}</strong></div>
        </div>
      </div>
      <div class="card">
        <h4>State projection</h4>
        <pre class="json">${esc(JSON.stringify(r.state, null, 2))}</pre>
      </div>
    </div>`;
}

// --------------------------------------------------------------------------
// Git / Settings
// --------------------------------------------------------------------------
export function git(root, ctx) {
  const g = ctx.state.github;
  const canCommit = Boolean(g.token && g.repo && ctx.result?.validation?.status === "valid");
  root.innerHTML = `
    <div class="stack">
      <div class="card">
        <div class="card-head"><h3>GitHub</h3>${ctx.githubUser ? `<span class="pill ok">@${esc(ctx.githubUser)}</span>` : ""}</div>
        <p class="muted small">Fine-grained PAT, stored only in this browser. Never sent to any server but GitHub.</p>
        <div class="form stack">
          <label>Token <input id="g-token" type="password" value="${esc(g.token)}" placeholder="github_pat_…"></label>
          <div class="row">
            <label>Repo <input id="g-repo" value="${esc(g.repo)}" placeholder="owner/name"></label>
            <label>Branch <input id="g-branch" value="${esc(g.branch || "main")}" style="width:120px"></label>
          </div>
          <div class="row">
            <button id="g-connect">Connect</button>
            <button class="ghost" id="g-load">Load repo</button>
            <button class="ghost" id="g-clear">Clear token</button>
          </div>
        </div>
      </div>
      <div class="card">
        <div class="card-head"><h3>Commit</h3><button id="g-commit" ${canCommit ? "" : "disabled"}>Commit changes</button></div>
        <p class="muted small">Writes one atomic Git commit: plan.fitspec, fitspec.lock, state/current.json, build/*.json, active patches, and imported logs. Blocked unless valid.</p>
        <div id="g-status"></div>
      </div>
      <div class="card">
        <h3>Appearance</h3>
        <div class="themes">
          ${["sage", "steel", "brass", "violet"]
            .map(
              (t) =>
                `<button class="theme-chip ${ctx.state.theme === t ? "active" : ""}" data-theme="${t}"><span class="sw sw-${t}"></span>${titleCase(t)}</button>`,
            )
            .join("")}
        </div>
      </div>
    </div>`;

  const formGithub = () => ({
    token: root.querySelector("#g-token").value.trim(),
    repo: root.querySelector("#g-repo").value.trim(),
    branch: root.querySelector("#g-branch").value.trim() || "main",
  });
  const commitButton = root.querySelector("#g-commit");
  const updateCommitState = () => {
    const next = formGithub();
    commitButton.disabled = !(next.token && next.repo && ctx.result?.validation?.status === "valid");
  };
  const save = () => ctx.setState({ github: formGithub() });
  root.querySelectorAll("#g-token, #g-repo, #g-branch").forEach((el) => {
    el.addEventListener("input", updateCommitState);
    el.addEventListener("change", save);
  });
  const status = root.querySelector("#g-status");

  root.querySelector("#g-connect").addEventListener("click", async () => {
    const nextGithub = formGithub();
    status.innerHTML = `<p class="muted">Connecting…</p>`;
    try {
      await ctx.github.connect(nextGithub);
      ctx.setState({ github: nextGithub });
    } catch (e) {
      status.innerHTML = `<p class="msg bad">${esc(e.message)}</p>`;
    }
  });
  root.querySelector("#g-load").addEventListener("click", async () => {
    const nextGithub = formGithub();
    status.innerHTML = `<p class="muted">Loading repo…</p>`;
    try {
      await ctx.github.load(nextGithub);
      ctx.setView("editor");
    } catch (e) {
      status.innerHTML = `<p class="msg bad">${esc(e.message)}</p>`;
    }
  });
  root.querySelector("#g-clear").addEventListener("click", () =>
    ctx.setState({ github: { ...ctx.state.github, token: "" } }),
  );
  root.querySelector("#g-commit").addEventListener("click", async () => {
    if (ctx.result?.validation?.status !== "valid") {
      status.innerHTML = `<p class="msg bad">Plan is not valid — fix validation before committing.</p>`;
      return;
    }
    const nextGithub = formGithub();
    status.innerHTML = `<p class="muted">Committing…</p>`;
    try {
      const res = await ctx.github.commit(nextGithub);
      if (res.skipped) {
        status.innerHTML = `<p class="msg ok">${esc(res.message || "No changes to commit.")}</p>`;
      } else {
        const shortSha = res.commitSha ? res.commitSha.slice(0, 7) : "";
        status.innerHTML = `
          <p class="msg ok">Committed ${res.committed} paths${shortSha ? ` at <a href="${esc(res.htmlUrl)}" target="_blank" rel="noreferrer">${esc(shortSha)}</a>` : ""}.</p>
          <pre class="patch-text">${esc((res.changedFiles || []).join("\n"))}</pre>`;
      }
    } catch (e) {
      status.innerHTML = `<p class="msg bad">${esc(e.message)}</p>`;
    }
  });
  root.querySelectorAll("[data-theme]").forEach((b) =>
    b.addEventListener("click", () => {
      document.documentElement.dataset.theme = b.dataset.theme;
      ctx.setState({ theme: b.dataset.theme });
    }),
  );
}

export const VIEWS = { overview, editor, patches, next, simulation, history, backtest, git };
