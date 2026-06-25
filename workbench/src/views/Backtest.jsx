import { For, Show, createMemo } from "solid-js";
import { workbench } from "../workbench.js";

export default function Backtest() {
  const build = () => workbench.build();
  const r = () => build().result;
  const records = () => workbench.state.records || [];
  const projection = createMemo(() => {
    if (!r()) return null;
    try {
      return { report: workbench.backtestRecords() };
    } catch (error) {
      return { error: error.message };
    }
  });

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
          <p class="muted small">{records().length} day records projected through the candidate plan.</p>
          <Show when={projection()?.error}>
            <p class="msg bad">{projection().error}</p>
          </Show>
          <div class="kv">
            <div>
              <span>Records</span>
              <strong>{records().length}</strong>
            </div>
            <div>
              <span>Sessions replayed</span>
              <strong>{projection()?.report?.sessions_replayed ?? "—"}</strong>
            </div>
            <div>
              <span>Cursor</span>
              <strong>
                {projection()?.report?.final_state?.cursor
                  ? JSON.stringify(projection().report.final_state.cursor)
                  : "—"}
              </strong>
            </div>
          </div>
        </div>
        <div class="card">
          <h4>Projection steps</h4>
          <Show
            when={projection()?.report?.steps?.length}
            fallback={<p class="muted small">No matching recorded workout days yet.</p>}
          >
            <div class="timeline">
              <For each={projection().report.steps}>
                {(step, i) => (
                  <div class="tl-row">
                    <span class="tl-n">{i() + 1}</span>
                    <strong>{step.date}</strong>
                    <span class="muted small">{step.display_name || step.session_id || "Recorded workout"}</span>
                  </div>
                )}
              </For>
            </div>
          </Show>
        </div>
        <div class="card">
          <h4>Final state</h4>
          <pre class="json">{JSON.stringify(projection()?.report?.final_state || r().state, null, 2)}</pre>
        </div>
      </div>
    </Show>
  );
}
