// Thin async wrapper over the wasm-bindgen glue. Nothing else in the workbench
// touches ./pkg directly — everything goes through these helpers, which unwrap
// the { ok, data } | { ok, error } envelope and throw on engine errors.
//
// The engine is the single source of truth: validation, build, simulation, and
// history import all run here in Rust-compiled WASM, never reimplemented in JS.
import init, {
  validate as wasmValidate,
  build as wasmBuild,
  simulate_plan as wasmSimulate,
  import_history as wasmImportHistory,
  builtin_template_catalog as wasmTemplates,
  lock_for as wasmLockFor,
  engine_version as wasmEngineVersion,
} from "./pkg/knurled_engine.js";

let ready = null;

/** Boots the WASM engine once; subsequent calls await the same promise. */
export function initEngine() {
  if (!ready) {
    ready = init().then(() => true);
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
const eventsJson = (events = []) => JSON.stringify(events);

export const engine = {
  validate: (planText, lockText = "", patches = []) =>
    unwrap(wasmValidate(planText, lockText, patchesJson(patches))),

  build: (planText, lockText = "", patches = [], events = []) =>
    unwrap(wasmBuild(planText, lockText, patchesJson(patches), eventsJson(events))),

  simulate: (planText, lockText = "", patches = [], events = [], weeks = 8, strategy = "all-pass") =>
    unwrap(wasmSimulate(planText, lockText, patchesJson(patches), eventsJson(events), weeks, strategy)),

  importHistory: (text, source = "manual", delimiter = "auto") =>
    unwrap(wasmImportHistory(text, source, delimiter)),

  templateCatalog: () => unwrap(wasmTemplates()),

  lockFor: (templateRef) => unwrap(wasmLockFor(templateRef)),

  version: () => unwrap(wasmEngineVersion()),
};
