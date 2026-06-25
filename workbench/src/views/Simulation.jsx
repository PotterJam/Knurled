import { For, Show, createSignal } from "solid-js";
import { workbench } from "../workbench.js";
import { titleCase } from "../lib/format.js";

// --------------------------------------------------------------------------
// Data shaping
//
// A simulation report is a list of sessions, each carrying `effects` that change
// a "lane" (e.g. squat.t1, bench.t2). Effects come in two flavours:
//   - increase_load: numeric weight progression  ("80kg" → "82.5kg")
//   - advance_stage: rep-scheme progression       ("5x3+" → "6x2+")
// We turn each lane into its own normalized trajectory over the whole run so the
// grid shows, at a glance, how every track moves — instead of cramming
// everything onto one shared, un-normalized axis.
// --------------------------------------------------------------------------

const LIFT_ORDER = ["squat", "bench", "press", "deadlift"];

function parseLoad(raw) {
  const s = String(raw ?? "").trim();
  // Rep schemes ("5x3+", "3x10") also start with a digit — reject anything that
  // looks like SETSxREPS so they're treated as stage progressions, not loads.
  if (/\d\s*x\s*\d/i.test(s)) return null;
  const m = s.match(/^(-?[0-9]*\.?[0-9]+)\s*(kg|lb|%)?$/i);
  if (!m) return null;
  return { value: Number(m[1]), unit: m[2] || "" };
}

const round = (n) => (Math.round(n * 100) / 100).toString();

function buildLanes(report) {
  const sessions = report.sessions || [];
  const n = sessions.length;
  const lanes = new Map();

  sessions.forEach((s, idx) => {
    for (const eff of s.effects || []) {
      let lane = lanes.get(eff.lane);
      if (!lane) {
        const [lift, tier] = eff.lane.split(".");
        const load = parseLoad(eff.to);
        lane = {
          id: eff.lane,
          lift: lift || eff.lane,
          tier: (tier || "").toUpperCase(),
          kind: load ? "load" : "stage",
          unit: load?.unit || "",
          startRaw: eff.from,
          changes: [],
        };
        lanes.set(eff.lane, lane);
      }
      lane.changes.push({ idx, fromRaw: eff.from, toRaw: eff.to });
    }
  });

  for (const lane of lanes.values()) {
    // Map a raw value to a numeric y. Stage lanes are ordinal by appearance.
    const order = [];
    const ordinal = (label) => {
      let i = order.indexOf(label);
      if (i === -1) {
        order.push(label);
        i = order.length - 1;
      }
      return i;
    };
    const toY = lane.kind === "load" ? (raw) => parseLoad(raw)?.value ?? 0 : ordinal;

    // Forward-fill a value for every session so cadence (how often a lane moves)
    // is visible on a shared x-axis. Dots mark the sessions where it changed.
    const series = new Array(n).fill(null);
    const dots = [];
    let current = toY(lane.startRaw);
    let currentRaw = lane.startRaw;
    let ci = 0;
    for (let i = 0; i < n; i++) {
      while (ci < lane.changes.length && lane.changes[ci].idx === i) {
        current = toY(lane.changes[ci].toRaw);
        currentRaw = lane.changes[ci].toRaw;
        if (lane.changes[ci].toRaw !== lane.changes[ci].fromRaw) dots.push(i);
        ci++;
      }
      series[i] = current;
    }

    lane.series = series;
    lane.dots = dots;
    lane.endRaw = currentRaw;
    lane.steps = dots.length;

    if (lane.kind === "load") {
      const start = parseLoad(lane.startRaw)?.value ?? 0;
      const end = parseLoad(lane.endRaw)?.value ?? 0;
      lane.delta = end - start;
      lane.deltaText = `${lane.delta > 0 ? "+" : ""}${round(lane.delta)}${lane.unit}`;
      lane.dir = lane.delta > 0 ? "up" : lane.delta < 0 ? "down" : "flat";
    } else {
      lane.deltaText = `${lane.steps} stage${lane.steps === 1 ? "" : "s"}`;
      lane.dir = "step";
    }
  }

  return [...lanes.values()].sort((a, b) => {
    const oa = LIFT_ORDER.indexOf(a.lift),
      ob = LIFT_ORDER.indexOf(b.lift);
    return (oa === -1 ? 99 : oa) - (ob === -1 ? 99 : ob) || a.lift.localeCompare(b.lift) || a.tier.localeCompare(b.tier);
  });
}

// --------------------------------------------------------------------------
// Per-lane mini chart — fixed viewBox scaled uniformly (no aspect distortion),
// non-scaling strokes so lines/dots stay crisp at any card width.
// --------------------------------------------------------------------------
function LaneChart(props) {
  const W = 280,
    H = 76,
    P = 10;
  const lane = () => props.lane;
  const pts = () => lane().series;
  const n = () => pts().length;
  const vals = () => pts().filter((v) => v != null);
  const min = () => Math.min(...vals());
  const max = () => Math.max(...vals());
  const flat = () => max() === min();
  const x = (i) => (n() <= 1 ? W / 2 : P + (i * (W - 2 * P)) / (n() - 1));
  const y = (v) => (flat() ? H / 2 : H - P - ((v - min()) / (max() - min())) * (H - 2 * P));
  const linePath = () => pts().map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join(" ");
  const areaPath = () => `${linePath()} L${x(n() - 1).toFixed(1)} ${H - P} L${x(0).toFixed(1)} ${H - P} Z`;

  return (
    <svg class={`spark dir-${lane().dir}`} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="xMidYMid meet" role="img" aria-label={`${lane().id} progression`}>
      <line class="spark-base" x1={P} y1={H - P} x2={W - P} y2={H - P} />
      <path class="spark-area" d={areaPath()} />
      <path class="spark-line" d={linePath()} vector-effect="non-scaling-stroke" />
      <For each={lane().dots}>
        {(i) => <circle class="spark-dot" cx={x(i).toFixed(1)} cy={y(pts()[i]).toFixed(1)} r="3" vector-effect="non-scaling-stroke" />}
      </For>
    </svg>
  );
}

function laneEffectText(eff) {
  return `${eff.from ?? "?"} → ${eff.to ?? "?"}`;
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
  run(); // run once on mount

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
            const lanes = buildLanes(report);
            const activeSessions = report.sessions.filter((s) => (s.effects || []).length);
            return (
              <>
                <div class="sim-stats">
                  <div><span>Weeks</span><strong>{report.weeks ?? weeks()}</strong></div>
                  <div><span>Sessions</span><strong>{report.sessions.length}</strong></div>
                  <div><span>Lanes advancing</span><strong>{lanes.length}</strong></div>
                  <div><span>Strategy</span><strong>{report.strategy || strategy()}</strong></div>
                </div>

                <Show
                  when={lanes.length}
                  fallback={
                    <div class="card">
                      <p class="muted">Nothing changed across this run — no progression to chart.</p>
                    </div>
                  }
                >
                  <div class="sim-grid">
                    <For each={lanes}>
                      {(lane) => (
                        <div class="lane-card">
                          <header>
                            <div class="lane-title">
                              <strong>{titleCase(lane.lift)}</strong>
                              <Show when={lane.tier}>
                                <span class="tier-badge">{lane.tier}</span>
                              </Show>
                            </div>
                            <span class={`kind-tag ${lane.kind}`}>{lane.kind}</span>
                          </header>
                          <LaneChart lane={lane} />
                          <div class="lane-foot">
                            <span class="lane-range">
                              {lane.startRaw} <span class="arrow">→</span> {lane.endRaw}
                            </span>
                            <span class={`delta ${lane.dir}`}>{lane.deltaText}</span>
                          </div>
                        </div>
                      )}
                    </For>
                  </div>
                </Show>

                <div class="card">
                  <div class="card-head">
                    <h4>Session timeline</h4>
                    <span class="muted small">{activeSessions.length} of {report.sessions.length} sessions changed something</span>
                  </div>
                  <Show
                    when={activeSessions.length}
                    fallback={<p class="muted">No session produced an effect.</p>}
                  >
                    <div class="timeline">
                      <For each={activeSessions}>
                        {(s) => (
                          <div class="tl-row">
                            <span class="tl-n">{s.index}</span>
                            <strong>{s.display_name}</strong>
                            <span class="tl-effects">
                              <For each={s.effects}>
                                {(eff) => (
                                  <span class="tl-effect">
                                    <span class="lane">{eff.lane}</span> {laneEffectText(eff)}
                                  </span>
                                )}
                              </For>
                            </span>
                          </div>
                        )}
                      </For>
                    </div>
                  </Show>
                </div>
              </>
            );
          })()}
        </Show>
      </Show>
    </div>
  );
}
