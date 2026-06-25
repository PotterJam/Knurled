import { For, Show } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase } from "../lib/format.js";

function restLabel(seconds) {
  return `Rest ${Math.round(seconds / 60)}m ${seconds % 60 ? `${seconds % 60}s` : ""}`;
}

export default function Next() {
  const build = () => workbench.build();
  const session = () => build().result?.next_workout;

  return (
    <Show
      when={session()}
      fallback={
        <div class="card">
          <p class="msg bad">{build().error || "Plan invalid — no session to render."}</p>
        </div>
      }
    >
      <div class="session-render">
        <div class="session-head">
          <h2>{session().display_name}</h2>
          <Show when={session().suggested_date}>
            <span class="muted">{session().suggested_date}</span>
          </Show>
        </div>
        <For each={session().items}>
          {(item) => (
            <article class="exercise-card">
              <header>
                <h3>{item.display?.title || titleCase(item.exercise)}</h3>
                <span class="lane">{item.progression_lane}</span>
              </header>
              <div class="sets">
                <For each={item.prescription.sets}>
                  {(s) => (
                    <div class="set">
                      <span class="set-n">{s.set}</span>
                      <span>{s.load || "—"}</span>
                      <span>
                        {s.target_reps ?? ""}
                        {s.amrap ? "+" : ""} reps
                      </span>
                    </div>
                  )}
                </For>
              </div>
              <Show when={item.rest?.seconds}>
                <p class="rest">{restLabel(item.rest.seconds)}</p>
              </Show>
            </article>
          )}
        </For>
      </div>
    </Show>
  );
}
