#ifndef KNURLED_CORE_H
#define KNURLED_CORE_H

/*
 * C ABI for knurled-core (see ../src/lib.rs).
 *
 * Every function returns a heap-allocated, NUL-terminated JSON string holding an
 * envelope: {"ok":true,"data":...} or {"ok":false,"error":"..."}. The caller
 * owns the returned pointer and must release it with knurled_string_free.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* -> validation_report */
char *knurled_validate_repo(const char *dir);

/* write != 0 regenerates state/ and build/ on disk. -> build outputs */
char *knurled_build_repo(const char *dir, int write);

/* Initializes a new training repo from a built-in template. -> init result */
char *knurled_init_repo(const char *dir, const char *template_ref);

/* Reduces an execution_input against the rendered session snapshot captured when the
 * workout started (passed as JSON), not the repo's current next workout. Preview only —
 * nothing is persisted. -> reduction result (validation, results, effects, new_state, next_workout) */
char *knurled_reduce_input(const char *dir, const char *rendered_session_json, const char *execution_input_json);

/* Submits a finished session against its rendered-session snapshot (ADR 0007): advances
 * state per mode ("advance" | "off_day" | "reset"), writes state/current.json, and appends
 * the day to logs/<yyyy>/<mm>.json. On invalid input nothing is written.
 * -> submit outcome (validation, record_day, new_state, effects) */
char *knurled_submit(const char *dir, const char *rendered_session_json, const char *execution_input_json, const char *mode, const char *date);

/* Re-renders a specific session by id against the repo's current state, ignoring the cursor,
 * so a saved partial can be resumed from history after the cursor has advanced. -> rendered session */
char *knurled_render_session(const char *dir, const char *session_id);

/* -> execution_input_validation */
char *knurled_validate_execution_input(const char *dir, const char *execution_input_json);

/* Previews an engine-owned plan edit without mutating the repo. The edit JSON is a typed
 * PlanEdit payload owned by knurled-core. -> plan edit outcome */
char *knurled_preview_plan_edit(const char *dir, const char *plan_edit_json);

/* Applies an engine-owned plan edit. On invalid validation, returns applied=false and does
 * not write files. On success, writes canonical/generated files and returns changed paths.
 * -> plan edit outcome */
char *knurled_apply_plan_edit(const char *dir, const char *plan_edit_json);

/* Suggests initial starts/training maxes for a target template from recent matching log lifts.
 * Request JSON: { "template": "...@...", "units": "kg"|"lb" }. -> initial number suggestions */
char *knurled_suggest_initial_numbers(const char *dir, const char *request_json);

/* -> engine version string */
char *knurled_engine_version(void);

/* Lists the built-in starter templates (reference, display_name, description) so the app
 * never hardcodes template ids or names. -> array of template descriptors */
char *knurled_builtin_templates(void);

/* Lists built-in exercise metadata for picker/search UI. -> array of exercise descriptors */
char *knurled_exercise_catalog(void);

/* Releases a string returned by any function above. */
void knurled_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* KNURLED_CORE_H */
