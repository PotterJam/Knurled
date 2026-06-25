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

pub fn compact_pretty_json<T: Serialize>(value: &T) -> Result<String> {
    let value = serde_json::to_value(value).map(stable_value)?;
    let mut output = String::new();
    format_compact_pretty_value(&value, 0, &mut output)?;
    output.push('\n');
    Ok(output)
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

fn format_compact_pretty_value(value: &Value, indent: usize, output: &mut String) -> Result<()> {
    if let Some(inline) = inline_json(value)? {
        output.push_str(&inline);
        return Ok(());
    }

    match value {
        Value::Array(items) => format_expanded_array(items, indent, output),
        Value::Object(object) => format_expanded_object(object, indent, output),
        _ => {
            output.push_str(&serde_json::to_string(value)?);
            Ok(())
        }
    }
}

fn format_expanded_array(items: &[Value], indent: usize, output: &mut String) -> Result<()> {
    if items.is_empty() {
        output.push_str("[]");
        return Ok(());
    }

    output.push('[');
    output.push('\n');
    for (index, item) in items.iter().enumerate() {
        write_indent(output, indent + 2);
        format_compact_pretty_value(item, indent + 2, output)?;
        if index + 1 != items.len() {
            output.push(',');
        }
        output.push('\n');
    }
    write_indent(output, indent);
    output.push(']');
    Ok(())
}

fn format_expanded_object(
    object: &Map<String, Value>,
    indent: usize,
    output: &mut String,
) -> Result<()> {
    if object.is_empty() {
        output.push_str("{}");
        return Ok(());
    }

    output.push('{');
    output.push('\n');
    for (index, (key, value)) in object.iter().enumerate() {
        write_indent(output, indent + 2);
        output.push_str(&serde_json::to_string(key)?);
        output.push_str(": ");
        format_compact_pretty_value(value, indent + 2, output)?;
        if index + 1 != object.len() {
            output.push(',');
        }
        output.push('\n');
    }
    write_indent(output, indent);
    output.push('}');
    Ok(())
}

fn inline_json(value: &Value) -> Result<Option<String>> {
    const MAX_INLINE_ARRAY_CHARS: usize = 100;
    const MAX_INLINE_OBJECT_CHARS: usize = 100;

    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {
            Ok(Some(serde_json::to_string(value)?))
        }
        Value::Array(items) => {
            let mut parts = Vec::with_capacity(items.len());
            for item in items {
                let Some(inline) = inline_json(item)? else {
                    return Ok(None);
                };
                parts.push(inline);
            }
            let inline = format!("[{}]", parts.join(", "));
            if inline.len() <= MAX_INLINE_ARRAY_CHARS {
                Ok(Some(inline))
            } else {
                Ok(None)
            }
        }
        Value::Object(object) => {
            let mut parts = Vec::with_capacity(object.len());
            for (key, value) in object {
                let Some(inline) = inline_json(value)? else {
                    return Ok(None);
                };
                parts.push(format!("{}: {}", serde_json::to_string(key)?, inline));
            }
            let inline = format!("{{ {} }}", parts.join(", "));
            if inline.len() <= MAX_INLINE_OBJECT_CHARS {
                Ok(Some(inline))
            } else {
                Ok(None)
            }
        }
    }
}

fn write_indent(output: &mut String, indent: usize) {
    for _ in 0..indent {
        output.push(' ');
    }
}

impl From<serde_json::Error> for crate::error::KnurledError {
    fn from(source: serde_json::Error) -> Self {
        crate::error::KnurledError::Json {
            path: "<memory>".into(),
            source,
        }
    }
}
