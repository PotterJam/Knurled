// Single source of truth for the workbench. Holds the canonical plan text,
// generated lock, patches, imported events, and UI/connection settings.
// Persists to localStorage and notifies subscribers on change.

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
  events: [], // imported TrainingEvent[]
  repoLabel: "Static workbench",
  theme: "sage",
  github: { token: "", repo: "", branch: "main" },
});

let state = load();
const listeners = new Set();

function load() {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return { ...defaults(), ...JSON.parse(raw) };
  } catch {
    /* fall through to defaults */
  }
  return defaults();
}

function persist() {
  try {
    // Never persist the GitHub token outside its own dedicated key handling;
    // here it lives only in localStorage on this device (spec §3A auth model).
    localStorage.setItem(KEY, JSON.stringify(state));
  } catch {
    /* ignore quota / private-mode errors */
  }
}

export function getState() {
  return state;
}

export function setState(patch) {
  state = { ...state, ...patch };
  persist();
  emit();
}

export function resetPlan() {
  setState({ planText: SAMPLE_PLAN, patches: [], events: [] });
}

export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function emit() {
  for (const fn of listeners) fn(state);
}
