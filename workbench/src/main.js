// Workbench entry point: boots the WASM engine, owns view routing, recomputes
// engine output on every change, and renders the active view.
import { initEngine, engine } from "../engine/index.js";
import { getState, setState, subscribe, resetPlan } from "./store.js";
import { VIEWS } from "./views.js";
import * as github from "./github.js";
import { importedEventFiles } from "./commit.mjs";

const NAV = [
  ["overview", "Overview"],
  ["editor", "Editor"],
  ["patches", "Patches"],
  ["next", "Next"],
  ["simulation", "Simulate"],
  ["history", "History"],
  ["backtest", "Backtest"],
  ["git", "Git"],
];

let currentView = "overview";
let templates = [];
let exercises = [];
let customExercises = [];
let githubUser = "";

function templateRef(planText) {
  const m = planText.match(/template\s+"([^"]+)"(?:\s+version="([^"]+)")?/);
  if (!m) return "gzcl.gzclp@1.0.0";
  if (m[1].includes("@")) return m[1];
  return `${m[1]}@${m[2] || "1.0.0"}`;
}

function effectiveLock(state) {
  if (state.lock && state.lock.trim()) return state.lock;
  try {
    return engine.lockFor(templateRef(state.planText));
  } catch {
    return "";
  }
}

// Recompute the engine build for the current state. Returns { result, error }.
function recompute(state) {
  const lock = effectiveLock(state);
  try {
    return { result: engine.build(state.planText, lock, state.patches, state.events), error: null, lock };
  } catch (e) {
    return { result: null, error: e.message, lock };
  }
}

function buildContext(state) {
  const { result, error, lock } = recompute(state);
  return {
    state,
    result,
    error,
    lock,
    templates,
    exercises: [...exercises, ...customExercises],
    githubUser,
    setPlanText: (text) => setState({ planText: text }),
    setPlanModel: (model) => {
      // serialize via fitspec.js (imported lazily through views) — views call this
      // with a model; serialize here to keep text canonical.
      import("./fitspec.js").then(({ serializePlan }) => setState({ planText: serializePlan(model) }));
    },
    setState,
    setView: (id) => {
      currentView = id;
      renderShell();
    },
    addCustomExercise: (ex) => {
      customExercises.push(ex);
      renderShell();
    },
    simulate: (weeks, strategy) => engine.simulate(state.planText, lock, state.patches, state.events, weeks, strategy),
    importHistory: (text, source) => engine.importHistory(text, source, "auto"),
    github: {
      connect: async () => {
        githubUser = await github.whoami(state.github.token);
      },
      load: async () => {
        const loaded = await github.loadRepo(state.github.token, state.github.repo, state.github.branch);
        setState(loaded);
      },
      commit: async () => {
        const r = result;
        const files = [
          { path: "plan.fitspec", text: state.planText },
          { path: "fitspec.lock", text: lock },
          { path: "build/current.ir.json", text: JSON.stringify(r.ir, null, 2) },
          { path: "build/next-workout.json", text: JSON.stringify(r.next_workout, null, 2) },
          { path: "build/validation.json", text: JSON.stringify(r.validation, null, 2) },
          ...state.patches
            .filter((p) => p.active !== false)
            .map((p) => ({ path: `patches/${p.filename}`, text: p.text })),
          ...importedEventFiles(state.events),
        ];
        const msg = `Update ${templateRef(state.planText).split("@")[0]} plan via workbench`;
        return github.commitFiles(state.github.token, state.github.repo, state.github.branch, files, msg);
      },
    },
  };
}

function renderStatusStrip(ctx) {
  const r = ctx.result;
  const ref = templateRef(ctx.state.planText);
  const cells = [
    ["Status", r?.validation?.status || "error", r?.validation?.status === "valid" ? "ok" : "bad"],
    ["Plan", r?.ir?.plan?.name || ctx.state.planText.match(/plan\s+"([^"]+)"/)?.[1] || "—", ""],
    ["Template", ref, ""],
    ["Next", r?.next_workout?.display_name?.split(" - ").pop() || "—", ""],
  ];
  return cells
    .map(([label, value, cls]) => `<div><span>${label}</span><strong class="${cls}">${escapeHtml(value)}</strong></div>`)
    .join("");
}

function escapeHtml(v) {
  return String(v ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

function captureRawEditorInteraction() {
  const active = document.activeElement;
  if (!(active instanceof HTMLTextAreaElement) || active.id !== "raw") return null;
  return {
    pageX: window.scrollX,
    pageY: window.scrollY,
    selectionStart: active.selectionStart,
    selectionEnd: active.selectionEnd,
    scrollLeft: active.scrollLeft,
    scrollTop: active.scrollTop,
  };
}

function restoreRawEditorInteraction(snapshot) {
  if (!snapshot) return;
  const raw = document.querySelector("#raw");
  if (!(raw instanceof HTMLTextAreaElement)) return;

  raw.focus({ preventScroll: true });
  const selectionStart = Math.min(snapshot.selectionStart, raw.value.length);
  const selectionEnd = Math.min(snapshot.selectionEnd, raw.value.length);
  raw.setSelectionRange(selectionStart, selectionEnd);
  raw.scrollLeft = snapshot.scrollLeft;
  raw.scrollTop = snapshot.scrollTop;
  window.scrollTo(snapshot.pageX, snapshot.pageY);
}

function renderShell() {
  const rawEditorInteraction = captureRawEditorInteraction();
  const state = getState();
  document.documentElement.dataset.theme = state.theme || "sage";
  const ctx = buildContext(state);
  const app = document.querySelector("#app");
  app.innerHTML = `
    <aside class="rail">
      <a class="brand" href="#overview" aria-label="Knurled Workbench home">
        <img class="brand-mark" src="./public/app-icon.png" alt="">
        <span class="brand-name">Knurled</span>
      </a>
      <nav aria-label="Workbench sections">
        ${NAV.map(
          ([id, label]) =>
            `<button class="nav-item ${id === currentView ? "active" : ""}" data-view="${id}">${label}</button>`,
        ).join("")}
      </nav>
    </aside>
    <main>
      <header class="topbar">
        <div><h1>Knurled</h1><p>${escapeHtml(state.repoLabel)}</p></div>
        <div class="actions">
          <button class="ghost" id="reset">Reset</button>
          <button id="commit-top" data-view="git">GitHub</button>
        </div>
      </header>
      <section class="status-strip">${renderStatusStrip(ctx)}</section>
      <div class="view" id="view"></div>
    </main>`;

  app.querySelectorAll(".nav-item").forEach((b) =>
    b.addEventListener("click", () => {
      currentView = b.dataset.view;
      renderShell();
    }),
  );
  app.querySelector(".brand").addEventListener("click", (event) => {
    event.preventDefault();
    currentView = "overview";
    renderShell();
  });
  app.querySelector("#reset").addEventListener("click", () => resetPlan());
  app.querySelector("#commit-top").addEventListener("click", () => {
    currentView = "git";
    renderShell();
  });

  (VIEWS[currentView] || VIEWS.overview)(app.querySelector("#view"), ctx);
  restoreRawEditorInteraction(rawEditorInteraction);
}

async function boot() {
  const app = document.querySelector("#app");
  app.innerHTML = `<div class="boot">Loading engine…</div>`;
  await initEngine();
  try {
    templates = engine.templateCatalog();
  } catch (e) {
    console.error("template catalog failed", e);
    templates = [];
  }
  try {
    exercises = await fetch("./src/data/exercises.json").then((r) => r.json());
  } catch {
    exercises = [];
  }
  // Re-render whenever the store changes; render once now.
  subscribe(() => renderShell());
  renderShell();
}

boot();
