import { For, Show } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase } from "../lib/format.js";

const ACTIONS = [
  ["editor", "Edit program", "Build & tune the plan visually"],
  ["next", "Next workout", "See the rendered session"],
  ["simulation", "Simulate", "Project weeks forward"],
  ["backtest", "Backtest", "Replay & check determinism"],
  ["history", "Import history", "Fold past logs in"],
  ["git", "Commit", "Push to GitHub"],
];

export default function Overview() {
  const build = () => workbench.build();
  const next = () => build().result?.next_workout;
  const status = () => build().result?.validation?.status || "error";

  return (
    <div class="stack">
      <div class="hero card">
        <div>
          <p class="eyebrow">Next workout</p>
          <h2>{next() ? next().display_name : "—"}</h2>
          <p class="muted">
            <Show
              when={next()}
              fallback={build().error || "Plan is invalid — fix validation to render."}
            >
              {next().items.map((i) => titleCase(i.exercise)).join(" · ")}
            </Show>
          </p>
        </div>
        <span class={`pill ${status() === "valid" ? "ok" : "bad"}`}>{status()}</span>
      </div>
      <div class="action-grid">
        <For each={ACTIONS}>
          {([id, label, sub]) => (
            <button class="action-card" onClick={() => workbench.setView(id)}>
              <strong>{label}</strong>
              <span>{sub}</span>
            </button>
          )}
        </For>
      </div>
    </div>
  );
}
