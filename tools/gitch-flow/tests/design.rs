//! The designer is a pure stdin/stdout bridge: no repository, source-file reads, trust writes or command execution.

use gitch_flow::design::{inspect, render};
use serde_json::{json, Value};
use std::io::Write;
use std::process::{Command, Stdio};

fn has_code(response: &Value, code: &str) -> bool {
    response["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|diagnostic| diagnostic["code"] == code)
}

fn cli(operation: &str, request: &Value, extra: &[&str]) -> (i32, Value) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_gitch-flow"))
        .args(["design", operation, "--json", "--lang", "en"])
        .args(extra)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // Rejected options can exit before reading stdin.
    let _ = child
        .stdin
        .take()
        .unwrap()
        .write_all(request.to_string().as_bytes());
    let output = child.wait_with_output().unwrap();
    let response = serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        panic!(
            "Invalid design response: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    });
    (output.status.code().unwrap_or(-1), response)
}

#[test]
fn no_op_preserves_comments_styles_expressions_and_line_endings_exactly() {
    let source = "# Keep this comment\r\nversion: 1\r\nflows:\r\n  verify: # inline comment\r\n    nodes:\r\n      check: {run: 'echo ${{ git.sha }}', timeout: 2m}\r\n";
    let inspected = inspect(&json!({"yaml": source}));
    assert_eq!(inspected["format"], "flow");
    assert_eq!(inspected["editable"], true);
    let rendered = render(&json!({"document": inspected["document"], "originalYaml": source}));
    assert_eq!(rendered["yaml"], source);
    assert_eq!(rendered["formattingChanged"], false);
    assert!(rendered["diagnostics"].as_array().unwrap().is_empty());
}

#[test]
fn edited_document_keeps_every_unknown_and_advanced_field() {
    let source = r#"# Review formatting after editing
version: 1
defaults: {jobs: 4, envPolicy: allowlist}
x-future: {nested: [true, null, 0.125, "0012", {value: "${{ inputs.mode }}"}]}
flows:
  verify:
    concurrency: cancel-previous
    nodes:
      check:
        run: |
          echo "${{ matrix.runtime }}"
          echo done
        with: {arbitrary: {payload: [one, two]}}
        matrix: {runtime: [20, 22]}
        when: "${{ success() }}"
        cache: {inputs: [src/**], key: [runtime]}
        onFailure: {dump: {run: echo diagnostics}}
        timeout: 2m
"#;
    let inspected = inspect(&json!({"yaml": source}));
    let mut document = inspected["document"].clone();
    document["flows"]["verify"]["nodes"]["check"]["run"] = json!("echo edited\necho done\n");
    let rendered = render(&json!({"document": document, "originalYaml": source}));
    assert_eq!(rendered["formattingChanged"], true);
    assert!(has_code(&rendered, "FORMAT_NORMALIZED"));
    let reparsed = gitch_flow::yaml::parse(rendered["yaml"].as_str().unwrap())
        .unwrap()
        .value;
    assert_eq!(reparsed, document);
    assert_eq!(reparsed["x-future"], inspected["document"]["x-future"]);
    assert_eq!(
        reparsed["flows"]["verify"]["nodes"]["check"]["matrix"],
        json!({"runtime": [20, 22]})
    );
}

#[test]
fn renderer_preserves_ambiguous_strings_and_unusual_multiline_whitespace() {
    let document = json!({"version": 1, "flows": {}, "on": "on", "values": ["true", "null", "1_000", "0o12", "01", "1e3", " a", "a ", "${{ secrets.EXAMPLE }}", "\n leading\n\n", "first\nsecond\n\n", "a\rb", "a\tb"]});
    let rendered = render(&json!({"document": document}));
    assert!(
        rendered["diagnostics"].as_array().unwrap().is_empty(),
        "{rendered}"
    );
    assert_eq!(
        gitch_flow::yaml::parse(rendered["yaml"].as_str().unwrap())
            .unwrap()
            .value,
        document
    );
}

#[test]
fn unsupported_yaml_is_read_only_and_original_text_is_retained() {
    for source in [
        "flows: {x: &base {nodes: {a: echo}}}\n",
        "flows: {x: {nodes: {a: !command echo}}}\n",
        "version: 1\nversion: 2\n",
        "version: 1\n---\nflows: {}\n",
        "flows: [\n",
    ] {
        let inspected = inspect(&json!({"yaml": source, "fileName": ".gitch/flow.yml"}));
        assert_eq!(inspected["editable"], false, "{inspected}");
        assert!(inspected["document"].is_null());
        assert_eq!(inspected["yaml"], source);
        assert!(has_code(&inspected, "DESIGN_YAML"));
        assert!(inspected["diagnostics"][0]["line"].as_u64().unwrap() > 0);
        let rendered = render(&json!({"document": {"flows": {}}, "originalYaml": source}));
        assert_eq!(rendered["yaml"], "");
        assert!(has_code(&rendered, "DESIGN_ORIGINAL"));
    }
}

#[test]
fn github_source_is_complete_and_proposal_keeps_provider_execution() {
    let source = r#"name: Verify and release
on: [push, workflow_dispatch]
permissions: {contents: write}
jobs:
  ship:
    environment: production
    if: "${{ github.ref == 'refs/heads/main' }}"
    strategy: {matrix: {runtime: [20, 22]}}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: example/deploy@v1
        with: {token: "${{ secrets.EXAMPLE }}"}
      - run: ./deploy.sh
"#;
    let inspected = inspect(&json!({"yaml": source, "fileName": ".github/workflows/release.yml"}));
    assert_eq!(inspected["format"], "github");
    assert_eq!(
        inspected["document"],
        gitch_flow::yaml::parse(source).unwrap().value
    );
    assert_eq!(inspected["editable"], false);
    let node = &inspected["proposal"]["document"]["flows"]["imported-github"]["nodes"]["workflow"];
    assert_eq!(node["use"], "ci.github.workflow");
    assert_eq!(node["with"]["workflow"], "release.yml");
    assert_eq!(node["with"]["connection"], "");
    assert!(node.get("run").is_none());
    assert!(has_code(&inspected, "CI_PROVIDER_SEMANTICS"));
    assert!(has_code(&inspected, "CI_CONFIGURATION_REQUIRED"));
    assert!(inspected["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|diagnostic| diagnostic["path"] == "jobs.ship.if"));
    assert_eq!(
        gitch_flow::yaml::parse(inspected["proposal"]["yaml"].as_str().unwrap())
            .unwrap()
            .value,
        inspected["proposal"]["document"]
    );
}

#[test]
fn gitlab_jenkins_and_compose_never_become_local_shell_jobs() {
    let gitlab = inspect(
        &json!({"yaml": "include: other.yml\nstages: [build, deploy]\nship: {stage: deploy, script: ./ship.sh, when: manual, rules: [{if: '$CI_COMMIT_TAG'}]}\n", "fileName": ".gitlab-ci.yml"}),
    );
    assert_eq!(
        gitlab["proposal"]["document"]["flows"]["imported-gitlab"]["nodes"]["pipeline"]["use"],
        "ci.gitlab.pipeline"
    );
    assert!(has_code(&gitlab, "CI_PROVIDER_SEMANTICS"));
    let jenkins_source = "pipeline { agent any; stages { stage('Deploy') { when { branch 'main' }; steps { sh './ship.sh' }; post { failure { notify() } } } } }";
    let jenkins = inspect(&json!({"yaml": jenkins_source, "fileName": "Jenkinsfile"}));
    assert_eq!(jenkins["format"], "jenkins");
    assert_eq!(jenkins["yaml"], jenkins_source);
    assert!(jenkins["document"].is_null());
    assert_eq!(
        jenkins["proposal"]["document"]["flows"]["imported-jenkins"]["nodes"]["job"]["use"],
        "ci.jenkins.job"
    );
    assert!(has_code(&jenkins, "JENKINS_REMOTE_ONLY"));
    let compose_source = "services:\n  db: {image: postgres:17, volumes: [data:/data]}\n  web: {build: ., depends_on: {db: {condition: service_healthy}}, secrets: [example]}\nvolumes: {data: {}}\nsecrets: {example: {file: ./example.txt}}\n";
    let compose = inspect(&json!({"yaml": compose_source, "fileName": "compose.yml"}));
    assert_eq!(compose["format"], "compose");
    assert_eq!(
        compose["document"],
        gitch_flow::yaml::parse(compose_source).unwrap().value
    );
    assert!(compose["proposal"].is_null());
    assert!(has_code(&compose, "COMPOSE_SOURCE_ONLY"));
}

#[test]
fn stdin_bridge_works_without_repository_and_rejects_mutation_options() {
    let path = std::env::temp_dir().join(format!("gitch-design-readonly-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::create_dir_all(&path).unwrap();
    let source_path = path.join("flow.yml");
    std::fs::write(&source_path, "do not read or replace this file").unwrap();
    let command = format!(
        "touch {}",
        gitch_flow::util::shell_quote(&path.join("marker").to_string_lossy())
    );
    let source = format!(
        "version: 1\nflows: {{verify: {{nodes: {{script: {}}}}}}}\n",
        serde_json::to_string(&command).unwrap()
    );
    let request = json!({"yaml": source, "fileName": source_path});
    let (status, inspected) = cli("inspect", &request, &[]);
    assert_eq!(status, 0);
    assert_eq!(inspected["document"]["version"], 1);
    let (status, rejected) = cli(
        "inspect",
        &request,
        &["--yes", "--out", source_path.to_str().unwrap()],
    );
    assert_ne!(status, 0);
    assert!(has_code(&rejected, "DESIGN_REQUEST"));
    assert_eq!(
        std::fs::read_to_string(&source_path).unwrap(),
        "do not read or replace this file"
    );
    assert_eq!(std::fs::read_dir(&path).unwrap().count(), 1);
    let (status, rendered) = cli(
        "render",
        &json!({"document": inspected["document"], "originalYaml": request["yaml"]}),
        &[],
    );
    assert_eq!(status, 0);
    assert_eq!(rendered["yaml"], request["yaml"]);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn malformed_requests_do_not_produce_partial_yaml() {
    for request in [
        json!({"document": []}),
        json!({"document": {}, "originalYaml": null}),
        json!({"document": {}, "write": true}),
    ] {
        let result = render(&request);
        assert_eq!(result["yaml"], "");
        assert!(has_code(&result, "DESIGN_REQUEST"));
    }
    let inspected = inspect(&json!({"yaml": "flows: {}\n", "readPath": "private.yml"}));
    assert!(has_code(&inspected, "DESIGN_REQUEST"));
    assert!(inspected["document"].is_null());
}

#[test]
fn standalone_flow_overlays_and_unknown_sources_remain_lossless() {
    let overlay =
        inspect(&json!({"yaml": "defaults: {jobs: 2}\n", "fileName": ".gitch/flow.local.yml"}));
    assert_eq!(overlay["format"], "flow");
    assert_eq!(overlay["editable"], true);
    let unknown = inspect(&json!({"yaml": "arbitrary: {nested: [1, 2, 3]}\n"}));
    assert_eq!(unknown["format"], "unknown");
    assert_eq!(
        unknown["document"],
        json!({"arbitrary": {"nested": [1, 2, 3]}})
    );
    assert_eq!(unknown["editable"], false);
    assert!(has_code(&unknown, "FORMAT_UNKNOWN"));
}

#[test]
fn unsafe_integers_cannot_be_rounded_by_visual_edits() {
    for number in [
        "9007199254740992",
        "-9007199254740992",
        "18446744073709551615",
        "1e20",
    ] {
        let source = format!("version: 1\nflows: {{}}\nfuture: {{identifier: {number}}}\n");
        let inspected = inspect(&json!({"yaml": source}));
        assert_eq!(inspected["editable"], false);
        assert!(inspected["proposal"].is_null());
        assert!(has_code(&inspected, "NUMERIC_PRECISION"));
        assert_eq!(inspected["yaml"], source);
        let unchanged = render(&json!({"document": inspected["document"], "originalYaml": source}));
        assert_eq!(unchanged["yaml"], source);
        let mut changed = inspected["document"].clone();
        changed["description"] = json!("An unrelated visual edit");
        let rejected = render(&json!({"document": changed, "originalYaml": source}));
        assert_eq!(rejected["yaml"], "");
        assert!(has_code(&rejected, "NUMERIC_PRECISION"));
    }
    let safe = inspect(&json!({"yaml": "version: 1\nflows: {}\nvalue: 9007199254740991\n"}));
    assert_eq!(safe["editable"], true);
}

#[test]
fn other_ci_formats_and_embedded_jenkins_scripts_are_not_misclassified() {
    for (source, file_name) in [
        ("version: 2.1\njobs: {build: {steps: [{run: make}]}}\nworkflows: {checks: {jobs: [build]}}\n", ".circleci/config.yml"),
        ("trigger: [main]\njobs: [{job: Build, steps: [{script: make}]}]\n", "azure-pipelines.yml"),
        ("stages: [{stage: Build, jobs: [{job: test}]}]\n", "azure-pipelines.yml"),
    ] {
        let inspected = inspect(&json!({"yaml": source, "fileName": file_name}));
        assert_eq!(inspected["format"], "unknown");
        assert!(inspected["proposal"].is_null());
        assert_eq!(inspected["document"], gitch_flow::yaml::parse(source).unwrap().value);
    }
    let native = inspect(
        &json!({"yaml": "version: 1\nflows:\n  generate:\n    nodes:\n      pipeline:\n        run: |\n          pipeline { agent any }\n"}),
    );
    assert_eq!(native["format"], "flow");
}

#[test]
fn deep_sources_and_trees_return_bounded_diagnostics() {
    let source = "values: ".to_string() + &"[".repeat(20_000) + "0" + &"]".repeat(20_000);
    let inspected = inspect(&json!({"yaml": source, "fileName": ".gitch/flow.yml"}));
    assert!(has_code(&inspected, "DESIGN_YAML"));
    let source = "values: ".to_string() + &"[".repeat(70) + "0" + &"]".repeat(70);
    let inspected = inspect(&json!({"yaml": source, "fileName": ".gitch/flow.yml"}));
    assert!(has_code(&inspected, "DESIGN_DEPTH"));
    assert_eq!(inspected["editable"], false);
}

#[test]
fn http_ci_metadata_exposes_endpoint_forms_with_truthful_runtime_defaults() {
    let block = gitch_flow::blocks::get("ci.http").unwrap();
    let inputs = (block.meta().inputs)();
    let fields = &inputs["properties"];
    for name in ["trigger", "status", "logs", "cancel", "find"] {
        let endpoint = &fields[name];
        assert_eq!(endpoint["required"], json!(["url"]));
        assert_eq!(endpoint["properties"]["method"]["default"], "GET");
        assert_eq!(
            endpoint["properties"]["headers"]["additionalProperties"]["type"],
            "string"
        );
        assert_eq!(
            endpoint["properties"]["body"]["oneOf"]
                .as_array()
                .unwrap()
                .len(),
            3
        );
    }
    assert_eq!(fields["id"]["default"], "/id");
    assert_eq!(fields["find"]["properties"]["id"]["default"], "/id");
    assert_eq!(
        fields["status"]["properties"]["pointer"]["default"],
        "/status"
    );
    assert_eq!(
        fields["status"]["properties"]["success"]["default"],
        json!(["success", "succeeded", "passed", "ok"])
    );
}
