// Single source of truth for the workbench document: the canonical plan text,
// generated lock, patches, lean records/current state, and UI/connection settings.
//
// Built on a SolidJS store so reads are fine-grained reactive — editing the raw
// plan text only re-runs the computations that actually depend on it, instead of
// re-rendering the whole shell (the old buildless version had to snapshot and
// restore textarea selection because every keystroke rebuilt the DOM).
//
// State is persisted to localStorage and rehydrated on load.
import { createRoot, createEffect } from "solid-js";
import { createStore } from "solid-js/store";

const KEY = "knurled.workbench.v2";

export const SAMPLE_PLAN = `plan "James GZCLP" {
  template "gzcl.gzclp" version="1.0.0"
  units kg

  schedule next_workout {
    rotation A1 B1 A2 B2
    suggested_days mon wed fri
  }

  starts {
    squat "80kg"
    bench "55kg"
    press "37.5kg"
    deadlift "100kg"
  }

  accessories {
    A1.T3 lat_pulldown
    B1.T3 barbell_row
    A2.T3 lat_pulldown
    B2.T3 barbell_row
  }
}
`;

const defaults = () => ({
  planText: SAMPLE_PLAN,
  lock: "",
  patches: [], // { filename, text, name, active }
  records: [], // TrainingRecord[] loaded from logs/<yyyy>/<mm>.json (ADR 0007)
  currentState: null, // state/current.json — the source of truth, or null when fresh
  repoLabel: "Static workbench",
  theme: "sage",
  github: { token: "", repo: "", branch: "main" },
  ui: { historyNotice: null },
});

function load() {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return { ...defaults(), ...JSON.parse(raw) };
  } catch {
    /* fall through to defaults */
  }
  return defaults();
}

export const [state, setStore] = createStore(load());

// Persist on any change. Reading the whole tree via JSON.stringify subscribes the
// effect to every property, so it re-runs whenever anything in the store changes.
createRoot(() => {
  createEffect(() => {
    const snapshot = JSON.stringify(state);
    try {
      localStorage.setItem(KEY, snapshot);
    } catch {
      /* ignore quota / private-mode errors */
    }
  });
});

/** Merge a partial patch into the store at the top level (replacing given keys). */
export function setState(patch) {
  setStore(patch);
}

export function resetPlan() {
  const next = defaults();
  setStore({
    planText: next.planText,
    lock: next.lock,
    patches: next.patches,
    records: next.records,
    currentState: next.currentState,
    repoLabel: next.repoLabel,
    ui: next.ui,
  });
}
