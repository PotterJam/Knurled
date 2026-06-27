// App-level reactive state: the active view, the booted engine's catalog data,
// the GitHub session, and — crucially — the derived engine build. Everything
// here lives in a single `createRoot` so the signals/memos are global and never
// disposed, and so components can simply `import { workbench }` without prop
// drilling or a context provider.
//
// The engine is the only semantic authority: `build` recomputes by calling the
// Rust/WASM engine whenever the plan text, lock, patches, or current state change.
import { createRoot, createSignal, createMemo } from "solid-js";
import { state, setState, resetPlan } from "./store.js";
import { engine } from "../engine/index.js";
import { serializePlan } from "./lib/fitspec.js";
import * as github from "./lib/github.js";
import { buildCommitPlan } from "./lib/commit.mjs";

export function templateRef(planText) {
  const m = planText.match(/template\s+"([^"]+)"(?:\s+version="([^"]+)")?/);
  if (!m) return "gzcl.gzclp@1.0.0";
  if (m[1].includes("@")) return m[1];
  return `${m[1]}@${m[2] || "1.0.0"}`;
}

function effectiveLock() {
  if (state.lock && state.lock.trim()) return state.lock;
  try {
    return engine.lockFor(templateRef(state.planText));
  } catch {
    return "";
  }
}

// Recompute the engine build for the current state. Returns { result, error, lock }.
function recompute() {
  const lock = effectiveLock();
  try {
    return { result: engine.build(state.planText, lock, state.patches, state.currentState), error: null, lock };
  } catch (e) {
    return { result: null, error: e.message, lock };
  }
}

export const workbench = createRoot(() => {
  const [ready, setReady] = createSignal(false);
  const [view, setView] = createSignal("overview");
  const [templates, setTemplates] = createSignal([]);
  const [baseExercises, setBaseExercises] = createSignal([]);
  const [customExercises, setCustomExercises] = createSignal([]);
  const [githubUser, setGithubUser] = createSignal("");

  const exercises = createMemo(() => [...baseExercises(), ...customExercises()]);

  // The single derived engine build. Memos compute eagerly at creation, so this
  // depends on `ready()` to avoid calling into the WASM engine before it has
  // booted (which would cache a failure forever). Once ready flips, it recomputes
  // and from then on re-runs only when a store field it reads (planText, lock,
  // patches, currentState) changes.
  const build = createMemo(() => {
    if (!ready()) return { result: null, error: null, lock: "" };
    return recompute();
  });

  return {
    // store passthrough
    state,
    setState,
    resetPlan,

    // app signals
    ready,
    setReady,
    view,
    setView,
    templates,
    setTemplates,
    setBaseExercises,
    customExercises,
    exercises,
    githubUser,
    setGithubUser,

    // derived engine output
    build,
    templateRef,

    // actions
    setPlanText: (text) => setState({ planText: text }),
    setPlanModel: (model) => setState({ planText: serializePlan(model) }),
    addCustomExercise: (ex) => setCustomExercises((list) => [...list, ex]),
    simulate: (weeks, strategy) =>
      engine.simulate(state.planText, build().lock, state.patches, state.currentState, weeks, strategy),
    backtestRecords: () => engine.backtestRecords(state.planText, build().lock, state.patches, state.records),
    engineMergeRecords: (existing, incoming) => engine.mergeRecords(existing, incoming),
    submit: (input, mode = "advance", date) => {
      const outcome = engine.submit(state.planText, build().lock, state.patches, state.currentState, input, mode, date);
      if (outcome.validation?.status === "valid") {
        const historyNotice = {
          kind: "ok",
          title: "Session recorded",
          message: `Recorded ${outcome.record?.date || date} and updated current state.`,
        };
        setState({
          currentState: outcome.new_state,
          records: engine.mergeRecords(state.records, [outcome.record]),
          ui: { ...state.ui, historyNotice },
        });
      }
      return outcome;
    },

    github: {
      connect: async (config = state.github) => {
        const login = await github.whoami(config.token);
        setGithubUser(login);
        return login;
      },
      load: async (config = state.github) => {
        const githubConfig = { ...state.github, ...config };
        const loaded = await github.loadRepo(githubConfig.token, githubConfig.repo, githubConfig.branch);
        setState({ ...loaded, github: githubConfig, ui: { ...state.ui, historyNotice: null } });
      },
      commit: async (config = state.github) => {
        const githubConfig = { ...state.github, ...config };
        const { result, lock } = build();
        const commitState = { ...state, github: githubConfig };
        const plan = buildCommitPlan({
          state: commitState,
          result,
          lock,
          templateRef: templateRef(state.planText),
          recordFiles: engine.recordFiles(commitState.records),
        });
        return github.commitFiles(githubConfig.token, githubConfig.repo, githubConfig.branch, plan);
      },
    },
  };
});
