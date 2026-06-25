import { Show } from "solid-js";
import { workbench } from "../workbench.js";

export default function Backtest() {
  const build = () => workbench.build();
  const r = () => build().result;
  const events = () => workbench.state.events;

  return (
    <Show
      when={r()}
      fallback={
        <div class="card">
          <p class="msg bad">{build().error || "Plan invalid."}</p>
        </div>
      }
    >
      <div class="stack">
        <div class="card">
          <div class="card-head">
            <h3>Backtest</h3>
            <span class={`pill ${r().validation.status === "valid" ? "ok" : "bad"}`}>
              {r().validation.status}
            </span>
          </div>
          <p class="muted small">{events().length} events replayed deterministically through the engine.</p>
          <div class="kv">
            <div>
              <span>Events</span>
              <strong>{events().length}</strong>
            </div>
            <div>
              <span>Last event</span>
              <strong>{r().state?.last_event_id || "—"}</strong>
            </div>
            <div>
              <span>Cursor</span>
              <strong>{r().state?.cursor ? JSON.stringify(r().state.cursor) : "—"}</strong>
            </div>
          </div>
        </div>
        <div class="card">
          <h4>State projection</h4>
          <pre class="json">{JSON.stringify(r().state, null, 2)}</pre>
        </div>
      </div>
    </Show>
  );
}
