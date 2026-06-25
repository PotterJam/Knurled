import { For, Show, createSignal } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase, PALETTE } from "../lib/format.js";
import { lineChart, legend } from "../lib/charts.js";

const numeric = (v) => {
  if (v == null) return null;
  const n = Number(String(v).match(/[0-9.]+/)?.[0]);
  return Number.isFinite(n) ? n : null;
};
function forwardFill(arr) {
  let last = 0;
  return arr.map((v) => (v == null ? last : (last = v)));
}

function chartSeriesFor(report) {
  const series = {};
  report.sessions.forEach((s, idx) => {
    for (const eff of s.effects || []) {
      const lane = eff.lane || "lift";
      const load = numeric(eff.to);
      if (load == null) continue;
      (series[lane] ||= Array(report.sessions.length).fill(null))[idx] = load;
    }
  });
  return Object.keys(series).map((lane, i) => ({
    label: titleCase(lane),
    color: PALETTE[i % PALETTE.length],
    points: forwardFill(series[lane]),
  }));
}

export default function Simulation() {
  const [weeks, setWeeks] = createSignal(8);
  const [strategy, setStrategy] = createSignal("all-pass");
  // { report } | { error } | null
  const [outcome, setOutcome] = createSignal(null);

  const run = () => {
    try {
      setOutcome({ report: workbench.simulate(weeks(), strategy()) });
    } catch (e) {
      setOutcome({ error: e.message });
    }
  };

  // Run once on mount.
  run();

  return (
    <div class="stack">
      <div class="card-head">
        <h3>Simulation</h3>
        <div class="row">
          <label>
            Weeks
            <input
              type="number"
              min="1"
              max="52"
              style="width:64px"
              value={weeks()}
              onInput={(e) => setWeeks(Number(e.target.value) || 8)}
            />
          </label>
          <label>
            Strategy
            <select value={strategy()} onChange={(e) => setStrategy(e.target.value)}>
              <option value="all-pass">all-pass</option>
              <option value="all-fail">all-fail</option>
            </select>
          </label>
          <button onClick={run}>Run</button>
        </div>
      </div>
      <Show when={outcome()}>
        <Show
          when={!outcome().error}
          fallback={
            <div class="card">
              <p class="msg bad">{outcome().error}</p>
            </div>
          }
        >
          {(() => {
            const report = outcome().report;
            const series = chartSeriesFor(report);
            return (
              <>
                <div class="card">
                  <h4>Projected working load</h4>
                  <Show
                    when={series.length}
                    fallback={<p class="muted">No numeric load effects to chart for this strategy.</p>}
                  >
                    <div innerHTML={lineChart(series) + legend(series)} />
                  </Show>
                </div>
                <div class="card">
                  <h4>Session timeline</h4>
                  <div class="timeline">
                    <For each={report.sessions}>
                      {(s) => (
                        <div class="tl-row">
                          <span class="tl-n">{s.index}</span>
                          <strong>{s.display_name}</strong>
                          <span class="muted small">
                            {(s.effects || [])
                              .map((e) => `${e.lane} ${e.op}${e.to ? ` → ${e.to}` : ""}`)
                              .join(", ")}
                          </span>
                        </div>
                      )}
                    </For>
                  </div>
                </div>
              </>
            );
          })()}
        </Show>
      </Show>
    </div>
  );
}
