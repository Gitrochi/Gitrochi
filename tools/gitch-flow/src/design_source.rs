//! Bounded related-source editing. Paths are repository-relative, scripts are never executed, and saves require a byte fingerprint.

use super::diagnostic;
use serde_json::{json, Value};
use std::fs::Permissions;
use std::io::Write;
use std::path::Path;
#[path = "design_source_path.rs"]
mod path;
use path::Target;
#[path = "design_source_metadata.rs"]
mod metadata;

const LIMIT: u64 = 2 * 1024 * 1024;
type Failure = (&'static str, &'static str);
type Result<T> = std::result::Result<T, Failure>;

pub(super) fn empty(path: &str) -> Value {
    json!({"schemaVersion": 1, "path": path, "content": null, "fingerprint": null, "exists": false, "saved": false, "diagnostics": []})
}

fn fail(mut response: Value, error: Failure) -> Value {
    response["diagnostics"] = json!([diagnostic(
        "error",
        error.0,
        error.1,
        response["path"].as_str(),
        None
    )]);
    response
}

struct Snapshot {
    bytes: Vec<u8>,
    permissions: Permissions,
    access: metadata::Access,
}

fn check_text(bytes: &[u8]) -> Result<()> {
    if bytes.contains(&0) || std::str::from_utf8(bytes).is_err() {
        return Err((
            "SOURCE_ENCODING",
            "Related source files must be UTF-8 text without NUL bytes.",
        ));
    }
    Ok(())
}

fn check_expected(snapshot: Option<&Snapshot>, expected: Option<&str>) -> Result<()> {
    match (snapshot, expected) {
        (Some(snapshot), Some(expected)) if crate::util::sha256_hex(&snapshot.bytes).eq_ignore_ascii_case(expected) => Ok(()),
        (None, None) => Ok(()),
        _ => Err(("SOURCE_CONFLICT", "The related file changed on disk. Reopen it before saving; your draft was not written.")),
    }
}

fn write(
    root: &Path,
    relative: &str,
    bytes: &[u8],
    expected: Option<&str>,
    create_parents: bool,
) -> Result<Option<String>> {
    if bytes.len() as u64 > LIMIT {
        return Err((
            "SOURCE_SIZE",
            "Related source files must be no larger than 2 MiB.",
        ));
    }
    check_text(bytes)?;
    let target = Target::with_parents(root, relative, create_parents)?;
    let before = target.read()?;
    check_expected(before.as_ref(), expected)?;
    if before
        .as_ref()
        .is_some_and(|snapshot| snapshot.bytes == bytes)
    {
        return Ok(None);
    }
    if before
        .as_ref()
        .is_some_and(|snapshot| snapshot.permissions.readonly())
    {
        return Err((
            "SOURCE_READ_ONLY",
            "The related file is read-only. Its existing contents were kept.",
        ));
    }
    let (mut temporary, name) = target.temporary()?;
    let result = (|| {
        // Apply a private source's permissions while the replacement is still empty.
        if let Some(snapshot) = &before {
            temporary
                .set_permissions(snapshot.permissions.clone())
                .map_err(|_| {
                    (
                        "SOURCE_WRITE",
                        "The source file permissions could not be preserved.",
                    )
                })?;
            snapshot.access.protect(&temporary)?;
        }
        temporary
            .write_all(bytes)
            .and_then(|_| temporary.sync_all())
            .map_err(|_| {
                (
                    "SOURCE_WRITE",
                    "The related file could not be saved. Its existing contents were kept.",
                )
            })?;
        // Writing may clear special Unix mode bits; restore the original mode after the data is complete.
        if let Some(snapshot) = &before {
            temporary
                .set_permissions(snapshot.permissions.clone())
                .map_err(|_| {
                    (
                        "SOURCE_WRITE",
                        "The source file permissions could not be preserved.",
                    )
                })?;
        }
        Ok(())
    })();
    // ReplaceFileW opens the replacement exclusively, after all preparation handles close.
    drop(temporary);
    let result = result.and_then(|_| {
        // Recheck both the path and bytes after preparing the replacement, before the atomic commit.
        let current_target = Target::new(root, relative)?;
        if !target.same_parent(&current_target) {
            return Err(("SOURCE_CONFLICT", "The related source folder changed. Reopen the file before saving; your draft was not written."));
        }
        let current = current_target.read()?;
        check_expected(current.as_ref(), expected)?;
        target.commit(&name, expected.is_none())
    });
    target.remove_temporary(&name);
    result
}

/// Read or save one explicitly selected repository source; this never interprets its content.
pub(super) fn handle(root: &Path, request: &Value) -> Value {
    let path = request.get("path").and_then(Value::as_str).unwrap_or("");
    let mut response = empty(path);
    let operation = request
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or("");
    if !["read", "write"].contains(&operation)
        || request.as_object().is_none_or(|values| {
            values.keys().any(|key| {
                !["operation", "path", "content", "expected", "createParents"]
                    .contains(&key.as_str())
            })
        })
    {
        return fail(
            response,
            (
                "SOURCE_REQUEST",
                "Choose read or write and provide one repository-relative source path.",
            ),
        );
    }
    if operation == "write" {
        let Some(content) = request.get("content").and_then(Value::as_str) else {
            return fail(
                response,
                (
                    "SOURCE_REQUEST",
                    "Saving a related source requires content and its expected fingerprint.",
                ),
            );
        };
        let expected = match request.get("expected") {
            Some(Value::Null) => None,
            Some(Value::String(value)) if value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) => Some(value.as_str()),
            _ => return fail(response, ("SOURCE_REQUEST", "Use the fingerprint returned when opening this file, or null only when creating a new file.")),
        };
        let create_parents = match request.get("createParents") {
            None | Some(Value::Bool(false)) => false,
            Some(Value::Bool(true)) if expected.is_none() => true,
            _ => return fail(response, ("SOURCE_REQUEST", "Creating source folders requires an explicit new-file save with expected null.")),
        };
        match write(root, path, content.as_bytes(), expected, create_parents) {
            Err(error) => return fail(response, error),
            Ok(Some(recovery)) => {
                response = fail(response, ("SOURCE_RECOVERY", "The save could not finish. The original file was kept in the recovery copy shown here. Reopen the file before editing."));
                response["diagnostics"][0]["path"] =
                    json!(Path::new(path).with_file_name(recovery).to_string_lossy());
                return response;
            }
            Ok(None) => {}
        }
        response["content"] = json!(content);
        response["fingerprint"] = json!(crate::util::sha256_hex(content.as_bytes()));
        response["exists"] = json!(true);
        response["saved"] = json!(true);
        return response;
    }
    if request.get("content").is_some()
        || request.get("expected").is_some()
        || request.get("createParents").is_some()
    {
        return fail(
            response,
            (
                "SOURCE_REQUEST",
                "Reading a source accepts only operation and path.",
            ),
        );
    }
    match Target::new(root, path).and_then(|target| target.read()) {
        Ok(Some(snapshot)) => {
            response["fingerprint"] = json!(crate::util::sha256_hex(&snapshot.bytes));
            response["content"] = json!(String::from_utf8(snapshot.bytes).unwrap());
            response["exists"] = json!(true);
            response
        }
        Ok(None) => fail(
            response,
            (
                "SOURCE_NOT_FOUND",
                "The related source file does not exist.",
            ),
        ),
        Err(error) => fail(response, error),
    }
}
