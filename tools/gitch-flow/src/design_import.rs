//! Format recognition and remote-only proposals for supplied CI text. No imports, plugins or scripts are evaluated.

use super::{diagnostic, emit};
use serde_json::{json, Value};

pub(super) fn detect(
    document: Option<&Value>,
    source: &str,
    file_name: Option<&str>,
) -> &'static str {
    let name = file_name
        .unwrap_or("")
        .replace('\\', "/")
        .to_ascii_lowercase();
    let base = name.rsplit('/').next().unwrap_or("");
    if base == "jenkinsfile"
        || base.starts_with("jenkinsfile.")
        || regex::Regex::new(r"^\s*(?://[^\n]*\n\s*)*(pipeline|node)\s*(?:\([^\n]*\))?\s*\{")
            .is_ok_and(|pattern| pattern.is_match(source))
    {
        return "jenkins";
    }
    if name.contains(".github/workflows/") {
        return "github";
    }
    if base == ".gitlab-ci.yml" || base == ".gitlab-ci.yaml" {
        return "gitlab";
    }
    if [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ]
    .contains(&base)
    {
        return "compose";
    }
    if ["flow.yml", "flow.yaml", "flow.local.yml", "flow.local.yaml"].contains(&base)
        || name.contains(".gitch/flows/")
        || name.contains(".gitch/blocks/")
    {
        return "flow";
    }
    if let Some(document) = document {
        if document.get("flows").is_some()
            || document.get("suites").is_some()
            || document.get("quarantine").is_some()
        {
            return "flow";
        }
        if document.get("workflows").is_none()
            && document
                .get("jobs")
                .and_then(Value::as_object)
                .is_some_and(|jobs| {
                    document.get("on").is_some()
                        || jobs.values().any(|job| {
                            job.get("runs-on").is_some()
                                || job.get("uses").is_some()
                                || job.get("steps").is_some()
                        })
                })
        {
            return "github";
        }
        if document.get("services").is_some_and(Value::is_object) {
            let services = document["services"].as_object().unwrap();
            if services
                .values()
                .any(|service| service.get("use").is_some())
            {
                return "flow";
            }
            return "compose";
        }
        if document.as_object().is_some_and(|values| {
            values
                .values()
                .any(|job| job.get("script").is_some() || job.get("trigger").is_some())
        }) || document
            .get("stages")
            .and_then(Value::as_array)
            .is_some_and(|stages| !stages.is_empty() && stages.iter().all(Value::is_string))
        {
            return "gitlab";
        }
    }
    "unknown"
}

fn warn_features(value: &Value, path: &str, diagnostics: &mut Vec<Value>) {
    match value {
        Value::Object(values) => {
            for (key, value) in values {
                let path = if path.is_empty() {
                    key.to_string()
                } else {
                    format!("{path}.{key}")
                };
                if [
                    "if",
                    "when",
                    "rules",
                    "only",
                    "except",
                    "strategy",
                    "matrix",
                    "parallel",
                    "uses",
                    "container",
                    "services",
                    "environment",
                    "permissions",
                    "concurrency",
                    "secrets",
                    "include",
                    "extends",
                    "artifacts",
                    "cache",
                    "defaults",
                    "default",
                    "before_script",
                    "after_script",
                ]
                .contains(&key.as_str())
                {
                    diagnostics.push(diagnostic("warning", "CI_PROVIDER_SEMANTICS", "This provider-specific field is preserved in the original source and is not translated into local flow commands. The remote proposal runs the original CI definition.", Some(&path), None));
                }
                warn_features(value, &path, diagnostics);
            }
        }
        Value::Array(values) => {
            for (index, value) in values.iter().enumerate() {
                warn_features(value, &format!("{path}[{index}]"), diagnostics);
            }
        }
        _ => {}
    }
}

pub(super) fn annotate(response: &mut Value, document: Option<&Value>, file_name: Option<&str>) {
    let format = response["format"].as_str().unwrap_or("unknown").to_string();
    if !["github", "gitlab", "jenkins", "compose"].contains(&format.as_str()) {
        return;
    }
    let mut diagnostics = response["diagnostics"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    if format == "compose" {
        diagnostics.push(diagnostic("warning", "COMPOSE_SOURCE_ONLY", "Compose service dependencies can be previewed. The complete source is kept unchanged; container startup, volumes, networks, secrets and deployment settings are not converted into local scripts. Choose the original file and configure a Compose service or deployment explicitly.", None, None));
        response["diagnostics"] = json!(diagnostics);
        return;
    }
    diagnostics.push(diagnostic("info", "CI_REMOTE_SOURCE_PRESERVED", "The complete CI definition stays with its provider. The proposal dispatches that original workflow or job remotely; it does not extract shell commands or omit deployment guards, Actions, plugins, expressions or runner settings.", None, None));
    diagnostics.push(diagnostic("warning", "CI_CONFIGURATION_REQUIRED", "Choose an existing connection and verify the remote repository, workflow or job before using this proposal. Importing does not approve trust or start a run.", None, None));
    if let Some(document) = document {
        warn_features(document, "", &mut diagnostics);
    }
    let mut with = json!({"connection": ""});
    let (block, node, description) = match format.as_str() {
        "github" => {
            let workflow = file_name
                .and_then(|name| name.rsplit(['/', '\\']).next())
                .filter(|name| {
                    !name.is_empty()
                        && !name.chars().any(char::is_control)
                        && (name.ends_with(".yml") || name.ends_with(".yaml"))
                })
                .unwrap_or("");
            with["workflow"] = json!(workflow);
            if workflow.is_empty() {
                diagnostics.push(diagnostic("warning", "CI_TARGET_REQUIRED", "The workflow file name is not known. Set workflow to the original GitHub Actions file name or ID.", Some("workflow"), None));
            }
            (
                "ci.github.workflow",
                "workflow",
                "Run the original GitHub Actions workflow remotely",
            )
        }
        "gitlab" => (
            "ci.gitlab.pipeline",
            "pipeline",
            "Run the original GitLab pipeline remotely",
        ),
        _ => {
            with["job"] = json!("");
            diagnostics.push(diagnostic("warning", "CI_TARGET_REQUIRED", "Set job to the original Jenkins job path. Groovy stages, when/post/parallel directives and plugin steps remain in Jenkins.", Some("job"), None));
            (
                "ci.jenkins.job",
                "job",
                "Run the original Jenkins job remotely",
            )
        }
    };
    let mut nodes = serde_json::Map::new();
    nodes.insert(node.into(), json!({"use": block, "with": with}));
    let mut flows = serde_json::Map::new();
    flows.insert(
        format!("imported-{format}"),
        json!({"description": description, "trigger": ["manual"], "nodes": nodes}),
    );
    let proposal = json!({"version": 1, "flows": flows});
    if let Ok(yaml) = emit(&proposal) {
        response["proposal"] = json!({"document": proposal, "yaml": yaml});
    }
    response["diagnostics"] = json!(diagnostics);
}
