/* tslint:disable */
/* eslint-disable */
/**
 * Compile + render the next workout from `state` (ADR 0007). Returns
 * `BuildOutputs` (`state`, `ir`, `next_workout`, `validation`) — the
 * workbench's main call. An empty `state_json` means the program's initial
 * state.
 */
export function build(plan_text: string, lock_text: string, patches_json: string, state_json: string): string;
/**
 * Submit a finished session (ADR 0007). The browser holds `state` and the
 * record, so they are passed in and returned: this renders the next workout
 * from `state_json`, reduces the input per `mode` (`advance` | `off_day` |
 * `reset`), and returns a `SubmitOutcome` (`validation`, `record_day` to
 * upsert into the month file, `new_state` to persist, `effects`). An empty
 * `state_json` means the program's initial state.
 */
export function submit(plan_text: string, lock_text: string, patches_json: string, state_json: string, input_json: string, mode: string, date: string): string;
/**
 * Compile + validate a plan. Returns a `ValidationReport`.
 */
export function validate(plan_text: string, lock_text: string, patches_json: string): string;
/**
 * List built-in templates with their session/slot/tier skeleton so the builder
 * canvas reflects real structure instead of hardcoded assumptions.
 */
export function builtin_template_catalog(): string;
/**
 * Generate a correct `fitspec.lock` body for a freshly authored plan's template.
 */
export function lock_for(template_ref: string): string;
/**
 * Backtest the plan over recorded days (ADR 0007). `days_json` is a JSON array
 * of day records (`logs/<yyyy>/<mm>.json` `days[]`). Returns a
 * `BacktestProjection`.
 */
export function backtest_records(plan_text: string, lock_text: string, patches_json: string, days_json: string): string;
/**
 * Project the plan forward from `state`. Returns a `SimulationReport`.
 */
export function simulate_plan(plan_text: string, lock_text: string, patches_json: string, state_json: string, weeks: number, strategy: string): string;
export function engine_version(): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
  readonly memory: WebAssembly.Memory;
  readonly backtest_records: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number) => [number, number];
  readonly build: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number) => [number, number];
  readonly builtin_template_catalog: () => [number, number];
  readonly engine_version: () => [number, number];
  readonly lock_for: (a: number, b: number) => [number, number];
  readonly simulate_plan: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number) => [number, number];
  readonly submit: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number, l: number, m: number, n: number) => [number, number];
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
