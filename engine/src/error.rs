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

    #[error("unknown built-in template: {0}")]
    UnknownTemplate(String),

    #[error("FitSpec parse error: {0}")]
    Parse(String),

    #[error("invalid execution input: {0}")]
    InvalidExecutionInput(String),
}

impl KnurledError {
    /// Stable machine-readable kind for the FFI/wasm `error_detail` envelope
    /// (RFC-0001 D9). Clients branch on this, never on message text.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::MissingRequiredFile(_) => "missing_file",
            Self::Io { .. } => "io",
            Self::Json { .. } => "invalid_json",
            Self::UnknownTemplate(_) => "unknown_template",
            Self::Parse(_) => "parse",
            Self::InvalidExecutionInput(_) => "invalid_input",
        }
    }

    /// Whether retrying the same call can plausibly succeed. The engine has no
    /// network path, so only I/O qualifies; everything else is permanent until
    /// the inputs change.
    pub fn retryable(&self) -> bool {
        matches!(self, Self::Io { .. })
    }
}
