use serde::Serialize;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::error::Result;

pub fn stable_value(value: Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.into_iter().map(stable_value).collect()),
        Value::Object(object) => {
            let mut entries: Vec<_> = object.into_iter().collect();
            entries.sort_by(|(left, _), (right, _)| left.cmp(right));
            Value::Object(
                entries
                    .into_iter()
                    .map(|(key, value)| (key, stable_value(value)))
                    .collect::<Map<_, _>>(),
            )
        }
        value => value,
    }
}

pub fn stable_json<T: Serialize>(value: &T) -> Result<String> {
    let value = serde_json::to_value(value).map(stable_value)?;
    Ok(serde_json::to_string(&value)?)
}

pub fn pretty_json<T: Serialize>(value: &T) -> Result<String> {
    let value = serde_json::to_value(value).map(stable_value)?;
    Ok(format!("{}\n", serde_json::to_string_pretty(&value)?))
}

pub fn sha256_text(text: &str) -> String {
    format!(
        "sha256:{}",
        hex_lower(Sha256::digest(text.as_bytes()).as_slice())
    )
}

pub fn sha256_json<T: Serialize>(value: &T) -> Result<String> {
    Ok(sha256_text(&stable_json(value)?))
}

fn hex_lower(bytes: &[u8]) -> String {
    const TABLE: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(TABLE[(byte >> 4) as usize] as char);
        output.push(TABLE[(byte & 0x0f) as usize] as char);
    }
    output
}

impl From<serde_json::Error> for crate::error::KnurledError {
    fn from(source: serde_json::Error) -> Self {
        crate::error::KnurledError::Json {
            path: "<memory>".into(),
            source,
        }
    }
}
