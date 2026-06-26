pub mod backtest;
pub mod core;
pub mod error;
pub mod json;
pub mod model;
pub mod parser;
pub mod plan_edit;
pub mod record;
pub mod repo;
pub mod session;
pub mod templates;

pub use backtest::{BacktestProjection, BacktestStep, backtest};
pub use core::{
    PatchFile, build_outputs, compile_plan, create_initial_state, reduce_input, render_next,
    render_session, simulate, synthetic_execution_input, validate_compiled,
    validate_execution_input,
};
pub use error::{KnurledError, Result};
pub use json::{pretty_json, sha256_json, sha256_text, stable_json};
pub use model::*;
pub use parser::{parse_lock, parse_patch, parse_plan};
pub use plan_edit::{
    PlanEdit, PlanEditOutcome, apply_plan_edit, preview_plan_edit, suggest_initial_numbers,
};
pub use record::{DayRecord, LiftRecord, LogMonth, month_key, month_path};
pub use repo::{
    InitResult, TrainingRepo, append_day_record, backtest_records_repo, build_repo,
    check_generated_repo, init_training_repo, preview_repo, read_records, read_state,
    read_training_repo, simulate_repo, submit_repo, validate_repo, write_generated_files,
    write_state,
};
pub use session::{SubmitMode, SubmitOutcome, submit_session};
pub use templates::{
    BUILTIN_TEMPLATES, BuiltinTemplateInfo, DEFAULT_TEMPLATE_ID, builtin_template,
    builtin_template_info, builtin_templates, exercise_catalog, lock_entry, render_lockfile,
    template_display_name, template_hash,
};
