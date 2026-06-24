pub mod core;
pub mod error;
pub mod import;
pub mod json;
pub mod model;
pub mod parser;
pub mod repo;
pub mod templates;

pub use core::{
    PatchFile, build_outputs, compile_plan, create_initial_state, reduce_input, render_next,
    replay_events, simulate, synthetic_execution_input, validate_compiled,
    validate_execution_input,
};
pub use error::{KnurledError, Result};
pub use import::{
    HistoryImportDelimiter, HistoryImportDraft, HistoryImportOptions, HistoryImportReport,
    history_import_events_from_str, import_history_repo,
};
pub use json::{pretty_json, sha256_json, sha256_text, stable_json};
pub use model::*;
pub use parser::{parse_lock, parse_patch, parse_plan};
pub use repo::{
    InitResult, TrainingRepo, backtest_repo, build_repo, check_generated_repo, init_training_repo,
    preview_repo, read_training_repo, replay_repo, simulate_repo, validate_repo,
    write_generated_files,
};
pub use templates::{
    BUILTIN_TEMPLATES, BuiltinTemplateInfo, DEFAULT_TEMPLATE_ID, builtin_template,
    builtin_template_info, builtin_templates, lock_entry, render_lockfile, template_display_name,
    template_hash,
};
