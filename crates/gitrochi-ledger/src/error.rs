use serde_json::{json, Value};

/// A failure with a stable code for callers (see CONTRACT.md) and a message for people.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new("INVALID_ARGUMENT", message)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new("NOT_FOUND", message)
    }

    pub fn conflict(message: impl Into<String>) -> Self {
        Self::new("CONFLICT", message)
    }

    pub fn not_allowed(message: impl Into<String>) -> Self {
        Self::new("NOT_ALLOWED", message)
    }

    pub fn to_json(&self) -> Value {
        json!({"code": self.code, "message": self.message})
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Self::new("DATABASE", error.to_string())
    }
}

impl From<serde_json::Error> for Error {
    fn from(error: serde_json::Error) -> Self {
        Self::new(
            "DATABASE",
            format!("Stored JSON could not be read: {error}"),
        )
    }
}
