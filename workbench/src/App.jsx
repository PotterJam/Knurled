import { For, Show, Switch, Match, createEffect, onMount } from "solid-js";
import { workbench, templateRef } from "./workbench.js";
import { initEngine, engine } from "../engine/index.js";
import exercisesData from "./data/exercises.json";
import iconUrl from "/app-icon.png";

import Overview from "./views/Overview.jsx";
import Editor from "./views/Editor.jsx";
import Patches from "./views/Patches.jsx";
import Next from "./views/Next.jsx";
import Simulation from "./views/Simulation.jsx";
import History from "./views/History.jsx";
import Backtest from "./views/Backtest.jsx";
import Git from "./views/Git.jsx";

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

function StatusStrip() {
  const r = () => workbench.build().result;
  const cells = () => {
    const result = r();
    const ref = templateRef(workbench.state.planText);
    return [
      ["Status", result?.validation?.status || "error", result?.validation?.status === "valid" ? "ok" : "bad"],
      ["Plan", result?.ir?.plan?.name || workbench.state.planText.match(/plan\s+"([^"]+)"/)?.[1] || "—", ""],
      ["Template", ref, ""],
      ["Next", result?.next_workout?.display_name?.split(" - ").pop() || "—", ""],
    ];
  };
  return (
    <section class="status-strip">
      <For each={cells()}>
        {([label, value, cls]) => (
          <div>
            <span>{label}</span>
            <strong class={cls}>{value}</strong>
          </div>
        )}
      </For>
    </section>
  );
}

export default function App() {
  onMount(async () => {
    await initEngine();
    try {
      workbench.setTemplates(engine.templateCatalog());
    } catch (e) {
      console.error("template catalog failed", e);
      workbench.setTemplates([]);
    }
    workbench.setBaseExercises(exercisesData);
    workbench.setReady(true);
  });

  // Keep the document theme in sync with the store.
  createEffect(() => {
    document.documentElement.dataset.theme = workbench.state.theme || "sage";
  });

  return (
    <Show when={workbench.ready()} fallback={<div class="app-shell"><div class="boot">Loading engine…</div></div>}>
      <div class="app-shell">
        <aside class="rail">
          <a
            class="brand"
            href="#overview"
            aria-label="Knurled Workbench home"
            onClick={(e) => {
              e.preventDefault();
              workbench.setView("overview");
            }}
          >
            <img class="brand-mark" src={iconUrl} alt="" />
            <span class="brand-name">Knurled</span>
          </a>
          <nav aria-label="Workbench sections">
            <For each={NAV}>
              {([id, label]) => (
                <button
                  class="nav-item"
                  classList={{ active: id === workbench.view() }}
                  onClick={() => workbench.setView(id)}
                >
                  {label}
                </button>
              )}
            </For>
          </nav>
        </aside>
        <main>
          <header class="topbar">
            <div>
              <h1>Knurled</h1>
              <p>{workbench.state.repoLabel}</p>
            </div>
            <div class="actions">
              <button class="ghost" onClick={() => workbench.resetPlan()}>Reset</button>
              <button onClick={() => workbench.setView("git")}>GitHub</button>
            </div>
          </header>
          <StatusStrip />
          <div class="view">
            <Switch fallback={<Overview />}>
              <Match when={workbench.view() === "overview"}><Overview /></Match>
              <Match when={workbench.view() === "editor"}><Editor /></Match>
              <Match when={workbench.view() === "patches"}><Patches /></Match>
              <Match when={workbench.view() === "next"}><Next /></Match>
              <Match when={workbench.view() === "simulation"}><Simulation /></Match>
              <Match when={workbench.view() === "history"}><History /></Match>
              <Match when={workbench.view() === "backtest"}><Backtest /></Match>
              <Match when={workbench.view() === "git"}><Git /></Match>
            </Switch>
          </div>
        </main>
      </div>
    </Show>
  );
}
