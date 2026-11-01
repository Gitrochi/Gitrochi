//! Helpers for the integration tests: temporary folders, the built binary with a clean
//! environment, and a small JSON Schema checker for the subset `schema/*.json` uses.

#![allow(dead_code)]

use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

pub struct TempDir(pub PathBuf);

impl TempDir {
    pub fn new(label: &str) -> TempDir {
        let dir = std::env::temp_dir().join(format!(
            "gitrochi-ledger-it-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    pub fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The built `gitrochi-ledger`, with the ledger's environment variables cleared so the
/// developer's own database and session never take part.
pub fn binary() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_gitrochi-ledger"));
    command
        .env_remove("GITROCHI_LEDGER_DB")
        .env_remove("GITROCHI_LEDGER_SESSION")
        .env_remove("GITROCHI_LEDGER");
    command
}

pub fn cli(db: &Path, args: &[&str]) -> Output {
    binary()
        .arg("--db")
        .arg(db)
        .args(args)
        .output()
        .expect("the binary runs")
}

pub fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

pub fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

pub fn json_of(output: &Output) -> Value {
    serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|e| panic!("not JSON ({e}): {}", stdout(output)))
}

/// The app caller on a test database (as the C ABI and the Tauri command call it).
pub fn app(db: &Path, method: &str, mut args: Value) -> Value {
    args["db"] = Value::String(db.to_string_lossy().into_owned());
    let result = gitrochi_ledger::call(method, &args);
    assert!(result.get("error").is_none(), "{method}: {result}");
    result
}

pub struct Schemas {
    dir: PathBuf,
    files: HashMap<String, Value>,
}

impl Schemas {
    pub fn load() -> Schemas {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("schema");
        let mut files = HashMap::new();
        for entry in std::fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            let text = std::fs::read_to_string(&path).unwrap();
            files.insert(name, serde_json::from_str(&text).unwrap());
        }
        Schemas { dir, files }
    }

    pub fn names(&self) -> Vec<String> {
        let mut names: Vec<_> = self.files.keys().cloned().collect();
        names.sort();
        names
    }

    pub fn file(&self, name: &str) -> &Value {
        self.files
            .get(name)
            .unwrap_or_else(|| panic!("no schema {name} in {}", self.dir.display()))
    }

    /// Validates `value` against a schema file; panics with every problem found.
    pub fn check(&self, name: &str, value: &Value) {
        let mut errors = Vec::new();
        self.walk(name, self.file(name), value, "$", &mut errors);
        assert!(errors.is_empty(), "{name}:\n{}", errors.join("\n"));
    }

    fn resolve<'a>(&'a self, current: &'a str, reference: &'a str) -> (&'a str, &'a Value) {
        let (file, pointer) = match reference.split_once('#') {
            Some(("", pointer)) => (current, pointer),
            Some((file, pointer)) => (file, pointer),
            None => (reference, ""),
        };
        let root = self.file(file);
        let target = if pointer.is_empty() {
            root
        } else {
            root.pointer(pointer)
                .unwrap_or_else(|| panic!("{reference} does not resolve"))
        };
        (file, target)
    }

    fn walk(&self, file: &str, schema: &Value, value: &Value, at: &str, errors: &mut Vec<String>) {
        if let Some(reference) = schema["$ref"].as_str() {
            let (file, target) = self.resolve(file, reference);
            self.walk(file, target, value, at, errors);
            return;
        }
        if let Some(expected) = schema.get("const") {
            if expected != value {
                errors.push(format!("{at}: {value} is not {expected}"));
            }
        }
        if let Some(options) = schema["enum"].as_array() {
            if !options.contains(value) {
                errors.push(format!("{at}: {value} is not one of {options:?}"));
            }
        }
        if let Some(kind) = schema["type"].as_str() {
            let ok = match kind {
                "object" => value.is_object(),
                "array" => value.is_array(),
                "string" => value.is_string(),
                "integer" => value.is_i64() || value.is_u64(),
                "number" => value.is_number(),
                "boolean" => value.is_boolean(),
                "null" => value.is_null(),
                other => panic!("unsupported type {other}"),
            };
            if !ok {
                errors.push(format!("{at}: expected {kind}, found {value}"));
                return;
            }
        }
        if let Some(n) = value.as_f64() {
            if schema["minimum"].as_f64().is_some_and(|m| n < m) {
                errors.push(format!("{at}: {n} below the minimum"));
            }
            if schema["maximum"].as_f64().is_some_and(|m| n > m) {
                errors.push(format!("{at}: {n} above the maximum"));
            }
        }
        if let (Some(text), Some(max)) = (value.as_str(), schema["maxLength"].as_u64()) {
            if text.chars().count() as u64 > max {
                errors.push(format!("{at}: longer than {max}"));
            }
        }
        if let Some(object) = value.as_object() {
            let properties = schema["properties"].as_object();
            for required in schema["required"].as_array().into_iter().flatten() {
                let key = required.as_str().unwrap();
                if !object.contains_key(key) {
                    errors.push(format!("{at}: missing {key}"));
                }
            }
            for (key, item) in object {
                match properties.and_then(|p| p.get(key)) {
                    Some(sub) => self.walk(file, sub, item, &format!("{at}.{key}"), errors),
                    None if schema["additionalProperties"] == Value::Bool(false) => {
                        errors.push(format!("{at}: unexpected {key}"))
                    }
                    None => {}
                }
            }
        }
        if let (Some(items), Some(schema)) = (value.as_array(), schema.get("items")) {
            for (index, item) in items.iter().enumerate() {
                self.walk(file, schema, item, &format!("{at}[{index}]"), errors);
            }
        }
    }
}
