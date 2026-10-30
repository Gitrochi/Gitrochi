//! Read-only YAML authoring bridge. The apps edit complete JSON trees; the engine owns parsing and lossless rendering.

use crate::cli::Args;
use serde_json::{json, Value};
use std::io::Read;
use yaml_rust2::{Yaml, YamlEmitter};

#[path = "design_import.rs"]
mod imports;

const MAX_REQUEST_BYTES: u64 = 4 * 1024 * 1024;
const MAX_YAML_BYTES: usize = 2 * 1024 * 1024;

fn diagnostic(
    severity: &str,
    code: &str,
    message: &str,
    path: Option<&str>,
    line: Option<usize>,
) -> Value {
    let mut result = json!({"severity": severity, "code": code, "message": message});
    if let Some(path) = path {
        result["path"] = json!(path);
    }
    if let Some(line) = line {
        result["line"] = json!(line);
    }
    result
}

fn inspection(yaml: &str, format: &str) -> Value {
    json!({"schemaVersion": 1, "document": null, "yaml": yaml, "format": format, "diagnostics": [], "editable": false, "proposal": null})
}

fn rendered() -> Value {
    json!({"schemaVersion": 1, "yaml": "", "diagnostics": [], "formattingChanged": false})
}

fn reject(mut response: Value, code: &str, message: &str) -> Value {
    response["diagnostics"] = json!([diagnostic("error", code, message, None, None)]);
    response
}

fn bounded_tree(value: &Value, depth: usize) -> bool {
    if depth > 64 {
        return false;
    }
    match value {
        Value::Array(values) => values.iter().all(|value| bounded_tree(value, depth + 1)),
        Value::Object(values) => values.values().all(|value| bounded_tree(value, depth + 1)),
        _ => true,
    }
}

fn unsafe_number(value: &Value) -> bool {
    match value {
        Value::Number(number) => {
            const MAX_EXACT: i64 = 9_007_199_254_740_991;
            if let Some(value) = number.as_i64() {
                return !(-MAX_EXACT..=MAX_EXACT).contains(&value);
            }
            if let Some(value) = number.as_u64() {
                return value > MAX_EXACT as u64;
            }
            number
                .as_f64()
                .is_some_and(|value| value.fract() == 0.0 && value.abs() > MAX_EXACT as f64)
        }
        Value::Array(values) => values.iter().any(unsafe_number),
        Value::Object(values) => values.values().any(unsafe_number),
        _ => false,
    }
}

const PRECISION_MESSAGE: &str = "This document contains integers outside the app's exact range (plus or minus 9007199254740991). Edit the original YAML source to preserve them without rounding.";

/// Parse a supplied source without opening files, expanding imports, approving trust or executing code.
pub fn inspect(request: &Value) -> Value {
    let Some(source) = request.get("yaml").and_then(Value::as_str) else {
        return reject(
            inspection("", "unknown"),
            "DESIGN_REQUEST",
            "The inspect request needs a yaml string.",
        );
    };
    let file_name = request.get("fileName").and_then(Value::as_str);
    let initial_format = imports::detect(None, source, file_name);
    let mut response = inspection(source, initial_format);
    if request.as_object().is_some_and(|values| {
        values
            .keys()
            .any(|key| !["yaml", "fileName"].contains(&key.as_str()))
    }) {
        return reject(response, "DESIGN_REQUEST", "Inspect accepts only yaml and optional fileName; it cannot read paths, write files or execute code.");
    }
    if request.get("fileName").is_some() && file_name.is_none() {
        return reject(
            response,
            "DESIGN_REQUEST",
            "fileName must be a string when supplied.",
        );
    }
    if source.len() > MAX_YAML_BYTES {
        return reject(
            response,
            "DESIGN_SIZE",
            "The YAML source exceeds the 2 MiB authoring limit.",
        );
    }
    if initial_format == "jenkins" {
        response["diagnostics"] = json!([diagnostic("warning", "JENKINS_REMOTE_ONLY", "Jenkinsfile is executable Groovy. It is kept unchanged and is not evaluated or translated into local commands.", None, None)]);
        imports::annotate(&mut response, None, file_name);
        return response;
    }
    let document = match crate::yaml::parse(source) {
        Ok(document) => document,
        Err(error) => {
            response["diagnostics"] = json!([diagnostic(
                "error",
                "DESIGN_YAML",
                &error.message,
                None,
                Some(error.line)
            )]);
            imports::annotate(&mut response, None, file_name);
            return response;
        }
    };
    let format = imports::detect(Some(&document.value), source, file_name);
    response["format"] = json!(format);
    if !document.value.is_object() {
        return reject(
            response,
            "DESIGN_MAPPING",
            "A visual flow source must have a mapping at its root.",
        );
    }
    if !bounded_tree(&document.value, 0) {
        return reject(
            response,
            "DESIGN_DEPTH",
            "This document is too deeply nested for visual editing (maximum depth 64).",
        );
    }
    response["document"] = document.value.clone();
    if unsafe_number(&document.value) {
        return reject(response, "NUMERIC_PRECISION", PRECISION_MESSAGE);
    }
    response["editable"] = json!(format == "flow");
    let mut diagnostics = Vec::new();
    if format == "flow" {
        if let Some(version) = document.value.get("version") {
            if version != &json!(1) {
                diagnostics.push(diagnostic("warning", "FLOW_VERSION", "The execution engine supports version 1. Other fields are preserved for review.", Some("version"), document.line_of("version")));
            }
        }
        if let Some(flows) = document.value.get("flows") {
            if !flows.is_object() {
                diagnostics.push(diagnostic(
                    "error",
                    "FLOW_MAPPING",
                    "flows must be a mapping of flow names to definitions.",
                    Some("flows"),
                    document.line_of("flows"),
                ));
            }
        }
    } else if format == "unknown" {
        diagnostics.push(diagnostic("info", "FORMAT_UNKNOWN", "The YAML mapping is preserved, but its format is not recognized as a flow or supported CI source.", None, None));
    }
    response["diagnostics"] = json!(diagnostics);
    imports::annotate(&mut response, Some(&document.value), file_name);
    response
}

fn as_yaml(value: &Value) -> Yaml {
    match value {
        Value::Null => Yaml::Null,
        Value::Bool(value) => Yaml::Boolean(*value),
        Value::Number(value) => value
            .as_i64()
            .map(Yaml::Integer)
            .unwrap_or_else(|| Yaml::Real(value.to_string())),
        Value::String(value) => Yaml::String(value.clone()),
        Value::Array(values) => Yaml::Array(values.iter().map(as_yaml).collect()),
        Value::Object(values) => Yaml::Hash(
            values
                .iter()
                .map(|(key, value)| (Yaml::String(key.clone()), as_yaml(value)))
                .collect(),
        ),
    }
}

/// Emit the entire tree and verify it with the same parser the execution engine uses.
fn emit(document: &Value) -> Result<String, String> {
    let yaml = as_yaml(document);
    // Literal blocks improve scripts; quoted strings cover unusual whitespace and scalar spellings without changing values.
    for multiline in [true, false] {
        let mut output = String::new();
        let mut emitter = YamlEmitter::new(&mut output);
        emitter.multiline_strings(multiline);
        emitter.dump(&yaml).map_err(|error| error.to_string())?;
        let output = output.strip_prefix("---\n").unwrap_or(&output).to_string() + "\n";
        if crate::yaml::parse(&output).is_ok_and(|parsed| parsed.value == *document) {
            return Ok(output);
        }
    }
    // JSON is a strict YAML subset and quotes every key/string, including numeric-looking strings the emitter misses.
    let output = serde_json::to_string_pretty(document).map_err(|error| error.to_string())? + "\n";
    if crate::yaml::parse(&output).is_ok_and(|parsed| parsed.value == *document) {
        return Ok(output);
    }
    Err("The document cannot be represented without changing a value. Keep editing the original YAML source.".into())
}

/// Render a complete edited document, preserving the original text exactly when its meaning is unchanged.
pub fn render(request: &Value) -> Value {
    let Some(document) = request
        .get("document")
        .filter(|document| document.is_object())
    else {
        return reject(
            rendered(),
            "DESIGN_REQUEST",
            "The render request needs a complete document mapping.",
        );
    };
    if !bounded_tree(document, 0) {
        return reject(
            rendered(),
            "DESIGN_DEPTH",
            "This document is too deeply nested for visual editing (maximum depth 64).",
        );
    }
    let mut response = rendered();
    if request.as_object().is_some_and(|values| {
        values
            .keys()
            .any(|key| !["document", "originalYaml"].contains(&key.as_str()))
    }) {
        return reject(response, "DESIGN_REQUEST", "Render accepts only document and optional originalYaml; it cannot write files or execute code.");
    }
    let original = request.get("originalYaml").and_then(Value::as_str);
    if request.get("originalYaml").is_some() && original.is_none() {
        return reject(
            response,
            "DESIGN_REQUEST",
            "originalYaml must be a string when supplied.",
        );
    }
    if let Some(original) = original {
        if original.len() > MAX_YAML_BYTES {
            return reject(
                response,
                "DESIGN_SIZE",
                "The original YAML exceeds the 2 MiB authoring limit.",
            );
        }
        match crate::yaml::parse(original) {
            Ok(parsed) if parsed.value == *document => {
                response["yaml"] = json!(original);
                return response;
            }
            Ok(parsed) => {
                if unsafe_number(&parsed.value) {
                    return reject(response, "NUMERIC_PRECISION", PRECISION_MESSAGE);
                }
            }
            Err(error) => {
                return reject(
                    response,
                    "DESIGN_ORIGINAL",
                    &format!(
                        "The original YAML cannot be safely compared: {}",
                        error.message
                    ),
                );
            }
        }
    }
    if unsafe_number(document) {
        return reject(response, "NUMERIC_PRECISION", PRECISION_MESSAGE);
    }
    match emit(document) {
        Ok(yaml) if yaml.len() <= MAX_YAML_BYTES => response["yaml"] = json!(yaml),
        Ok(_) => {
            return reject(
                response,
                "DESIGN_SIZE",
                "The rendered YAML exceeds the 2 MiB authoring limit.",
            )
        }
        Err(error) => return reject(response, "DESIGN_RENDER", &error),
    }
    if original.is_some() {
        response["formattingChanged"] = json!(true);
        response["diagnostics"] = json!([diagnostic("warning", "FORMAT_NORMALIZED", "Visual edits preserved every document value, but normalized YAML formatting and removed comments. Review the source before saving.", None, None)]);
    }
    response
}

/// Stdin/stdout transport for the read-only designer; it deliberately has no repository or filesystem access.
pub fn command(args: &Args) -> i32 {
    let operation = args.pos.first().map(String::as_str).unwrap_or("help");
    if ["help", "--help", "-h"].contains(&operation) {
        println!("design inspect --json  < {{\"yaml\":\"...\",\"fileName\":\"flow.yml\"}}\ndesign render --json   < {{\"document\":{{...}},\"originalYaml\":\"...\"}}\nRead-only: prints proposals and diagnostics; never opens files or executes commands.");
        return 0;
    }
    let empty = if operation == "render" {
        rendered()
    } else {
        inspection("", "unknown")
    };
    let invalid = if !["inspect", "render"].contains(&operation) || args.pos.len() != 1 {
        Some("Choose design inspect or design render and pass one JSON request on stdin.")
    } else if args
        .flags
        .keys()
        .any(|flag| !["--json", "--lang"].contains(&flag.as_str()))
    {
        Some("Design commands are read-only and accept only --json and --lang; write, execute and output-path options are not supported.")
    } else {
        None
    };
    if let Some(message) = invalid {
        println!("{}", reject(empty, "DESIGN_REQUEST", message));
        return 1;
    }
    let mut input = Vec::new();
    if std::io::stdin()
        .take(MAX_REQUEST_BYTES + 1)
        .read_to_end(&mut input)
        .is_err()
        || input.len() as u64 > MAX_REQUEST_BYTES
    {
        println!(
            "{}",
            reject(
                empty,
                "DESIGN_SIZE",
                "The JSON request could not be read or exceeds the 4 MiB authoring limit."
            )
        );
        return 1;
    }
    let request: Value = match serde_json::from_slice(&input) {
        Ok(value @ Value::Object(_)) => value,
        _ => {
            println!(
                "{}",
                reject(empty, "DESIGN_REQUEST", "Pass a JSON object on stdin.")
            );
            return 1;
        }
    };
    let result = if operation == "render" {
        render(&request)
    } else {
        inspect(&request)
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&result).unwrap_or_default()
    );
    0
}
