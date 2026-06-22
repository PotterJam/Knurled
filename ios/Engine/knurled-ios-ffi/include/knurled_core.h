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

/* Reduces an execution_input against the repo's current rendered session.
 * -> reduction result (validation, event, effects, new_state, next_workout) */
char *knurled_reduce_input(const char *dir, const char *execution_input_json);

/* -> execution_input_validation */
char *knurled_validate_execution_input(const char *dir, const char *execution_input_json);

/* -> engine version string */
char *knurled_engine_version(void);

/* Releases a string returned by any function above. */
void knurled_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* KNURLED_CORE_H */
