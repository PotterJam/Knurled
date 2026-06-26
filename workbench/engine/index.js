// Thin async wrapper over the wasm-bindgen glue. Nothing else in the workbench
// touches ./pkg directly — everything goes through these helpers, which unwrap
// the { ok, data } | { ok, error } envelope and throw on engine errors.
//
// The engine is the single source of truth: validation, build, simulation,
// submit, and backtest all run here in Rust-compiled WASM.
//
// The `.wasm` is imported with Vite's `?url` suffix and handed to `init`
// explicitly. This is the reliable way to load a wasm-bindgen `--target web`
// package under Vite: Vite emits the binary as a hashed asset and gives us its
// final URL, instead of relying on the glue's `new URL(..., import.meta.url)`
// guess. The committed package in ./pkg/ keeps the site a zero-Rust static build.
// Namespace import: new exports (submit, backtest_records) and the state-based
// build/simulate signatures land when the committed pkg is regenerated with
// workbench/scripts/build-wasm.sh. Importing the namespace (rather than named
// bindings) keeps the bundle building even before that rebuild — a missing
// export is just `undefined` until the pkg catches up.
import init, * as wasm from "./pkg/knurled_engine.js";
import wasmUrl from "./pkg/knurled_engine_bg.wasm?url";

function wasmCall(name, ...args) {
  const fn = wasm[name];
  if (typeof fn !== "function") {
    throw new Error(`engine export "${name}" is unavailable — rebuild workbench/engine/pkg (build-wasm.sh)`);
  }
  return fn(...args);
}

let ready = null;

/** Boots the WASM engine once; subsequent calls await the same promise. */
export function initEngine() {
  if (!ready) {
    ready = init({ module_or_path: wasmUrl }).then(() => true);
  }
  return ready;
}

function unwrap(jsonString) {
  let envelope;
  try {
    envelope = JSON.parse(jsonString);
  } catch (error) {
    throw new Error(`engine returned malformed JSON: ${error.message}`);
  }
  if (!envelope.ok) {
    throw new Error(envelope.error || "unknown engine error");
  }
  return envelope.data;
}

const patchesJson = (patches = []) =>
  JSON.stringify(patches.filter((p) => p.active !== false).map((p) => ({ filename: p.filename, text: p.text })));
// state/current.json is the source of truth (ADR 0007); "" means initial state.
const stateJson = (state) => (state == null ? "" : JSON.stringify(state));

export const engine = {
  validate: (planText, lockText = "", patches = []) =>
    unwrap(wasmCall("validate", planText, lockText, patchesJson(patches))),

  // Render the next workout from `state` (or initial state when null).
  build: (planText, lockText = "", patches = [], state = null) =>
    unwrap(wasmCall("build", planText, lockText, patchesJson(patches), stateJson(state))),

  simulate: (planText, lockText = "", patches = [], state = null, weeks = 8, strategy = "all-pass") =>
    unwrap(wasmCall("simulate_plan", planText, lockText, patchesJson(patches), stateJson(state), weeks, strategy)),

  // Submit a finished session: mode is "advance" | "off_day" | "reset".
  submit: (planText, lockText = "", patches = [], state = null, input = {}, mode = "advance", date) =>
    unwrap(wasmCall("submit", planText, lockText, patchesJson(patches), stateJson(state), JSON.stringify(input), mode, date)),

  // Backtest the plan over recorded days (replay-free projection).
  backtestRecords: (planText, lockText = "", patches = [], records = []) =>
    unwrap(wasmCall("backtest_records", planText, lockText, patchesJson(patches), JSON.stringify(records))),

  templateCatalog: () => unwrap(wasmCall("builtin_template_catalog")),

  exerciseCatalog: () => unwrap(wasmCall("exercise_catalog_json")),

  lockFor: (templateRef) => unwrap(wasmCall("lock_for", templateRef)),

  version: () => unwrap(wasmCall("engine_version")),
};
