use std::path::PathBuf;

pub type Result<T> = std::result::Result<T, KnurledError>;

#[derive(Debug, thiserror::Error)]
pub enum KnurledError {
    #[error("missing required file: {0}")]
    MissingRequiredFile(PathBuf),

    #[error("I/O error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("invalid JSON in {path}: {source}")]
    Json {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },

    #[error("invalid JSONL event in {path} at line {line}: {source}")]
    Jsonl {
        path: PathBuf,
        line: usize,
        #[source]
        source: serde_json::Error,
    },

    #[error("unknown built-in template: {0}")]
    UnknownTemplate(String),

    #[error("FitSpec parse error: {0}")]
    Parse(String),

    #[error("invalid execution input: {0}")]
    InvalidExecutionInput(String),

    #[error("invalid history import: {0}")]
    InvalidHistoryImport(String),
}
