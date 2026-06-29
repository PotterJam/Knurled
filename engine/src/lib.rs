pub mod backtest;
pub mod core;
pub mod dsl;
pub mod error;
pub mod json;
pub mod model;
pub mod parser;
pub mod plan_edit;
pub mod programs;
pub mod record;
pub mod repo;
pub mod session;
pub mod suggest;
pub mod templates;

pub use backtest::{BacktestProjection, BacktestStep, backtest};
pub use core::{
    PatchFile, build_outputs, compile_plan, compile_plan_with_template, create_initial_state,
    preview_template, reduce_input, render_next, render_session, simulate,
    synthetic_execution_input, validate_compiled, validate_execution_input,
};
pub use dsl::{parse_template_dsl, render_template_dsl, vendor_template};
pub use error::{KnurledError, Result};
pub use json::{pretty_json, sha256_json, sha256_text, stable_json};
pub use model::*;
pub use parser::{parse_lock, parse_patch, parse_plan};
pub use plan_edit::{
    PlanEdit, PlanEditOutcome, apply_plan_edit, preview_plan_edit, suggest_initial_numbers,
    suggest_load,
};
pub use programs::{
    AddProgramRequest, ProgramMeta, ProgramMutationOutcome, ProgramSummary, active_program_dir,
    active_program_relative_path, add_program, delete_program, ensure_program_layout,
    list_programs, rename_program, set_active_program,
};
pub use record::{
    AmendRecordOutcome, AmendRecordRequest, LiftRecord, LogMonth, RecordAmendment, RecordKind,
    TrainingRecord, lift_record_id, month_key, month_path, workout_record_id,
};
pub use repo::{
    InitResult, TrainingRepo, amend_training_record, backtest_records_repo, build_repo,
    check_generated_repo, init_training_repo, merge_record_repos, merge_training_records,
    preview_repo, read_records, read_state, read_training_repo, serialize_record_files,
    simulate_repo, submit_rendered_repo, submit_repo, validate_repo, write_generated_files,
    write_state, write_training_record,
};
pub use session::{SubmitMode, SubmitOutcome, submit_session};
pub use suggest::{ProgramAdjustmentSuggestion, suggest_program_adjustments};
pub use templates::{
    BUILTIN_TEMPLATES, BuiltinTemplateInfo, DEFAULT_TEMPLATE_ID, builtin_template,
    builtin_template_info, builtin_templates, exercise_catalog, lock_entry, render_lockfile,
    template_display_name, template_hash,
};
