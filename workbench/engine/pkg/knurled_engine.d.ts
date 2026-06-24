/* tslint:disable */
/* eslint-disable */
/**
 * Project the plan forward. Returns a `SimulationReport`.
 */
export function simulate_plan(plan_text: string, lock_text: string, patches_json: string, events_json: string, weeks: number, strategy: string): string;
/**
 * Generate a correct `fitspec.lock` body for a freshly authored plan's template.
 */
export function lock_for(template_ref: string): string;
export function engine_version(): string;
/**
 * List built-in templates with their session/slot/tier skeleton so the builder
 * canvas reflects real structure instead of hardcoded assumptions.
 */
export function builtin_template_catalog(): string;
/**
 * Compile + replay events + render. Returns `BuildOutputs`
 * (`state`, `ir`, `next_workout`, `validation`) — the workbench's main call.
 */
export function build(plan_text: string, lock_text: string, patches_json: string, events_json: string): string;
/**
 * Compile + validate a plan. Returns a `ValidationReport`.
 */
export function validate(plan_text: string, lock_text: string, patches_json: string): string;
/**
 * Parse delimited history text into a `HistoryImportDraft` (events + per-row
 * diagnostics), entirely in memory. `delimiter` is "auto" | "csv" | "tsv".
 */
export function import_history(text: string, source: string, delimiter: string): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
  readonly memory: WebAssembly.Memory;
  readonly build: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number) => [number, number];
  readonly builtin_template_catalog: () => [number, number];
  readonly engine_version: () => [number, number];
  readonly import_history: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number];
  readonly lock_for: (a: number, b: number) => [number, number];
  readonly simulate_plan: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number) => [number, number];
  readonly validate: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number];
  readonly __wbindgen_export_0: WebAssembly.Table;
  readonly __wbindgen_malloc: (a: number, b: number) => number;
  readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
  readonly __wbindgen_free: (a: number, b: number, c: number) => void;
  readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;
/**
* Instantiates the given `module`, which can either be bytes or
* a precompiled `WebAssembly.Module`.
*
* @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
*
* @returns {InitOutput}
*/
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
* If `module_or_path` is {RequestInfo} or {URL}, makes a request and
* for everything else, calls `WebAssembly.instantiate` directly.
*
* @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
*
* @returns {Promise<InitOutput>}
*/
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
