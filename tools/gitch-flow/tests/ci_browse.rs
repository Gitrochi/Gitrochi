mod common;

use common::fake::{Resp, Server};
use common::Fx;
use serde_json::json;

fn connection(fx: &Fx, base: &str, allow: &str) {
    let (code, _, error) = fx.run(
        "script",
        &[
            "connect",
            "add",
            "jenkins",
            "--name",
            "builds",
            "--url",
            base,
            "--secret-from",
            "env:BUILD_TOKEN",
            "--allow",
            allow,
        ],
    );
    assert_eq!(code, 0, "{error}");
}

#[test]
fn browse_jenkins_jobs_history_and_masked_logs_without_writes() {
    let server = Server::start(|req| {
        assert_eq!(req.method, "GET");
        Some(match req.path.as_str() {
            "/api/json" => {
                Resp::json(json!({"jobs":[{"name":"team","_class":"Folder"},{"name":"other"}]}))
            }
            "/job/team/api/json" => Resp::json(json!({"jobs":[{"name":"app"}]})),
            "/job/team/job/app/api/json" => Resp::json(
                json!({"builds":[{"number":42,"displayName":"Build 42","building":false,"result":"SUCCESS","timestamp":123,"duration":45},{"number":43,"building":true}]}),
            ),
            "/job/team/job/app/42/consoleText" => {
                Resp::text(200, "ready\nopaque-test-credential\n")
            }
            _ => Resp::status(404),
        })
    });
    let fx = Fx::new(&[]);
    connection(&fx, &server.base, "team/app");
    let (code, root) = fx.json(
        "script",
        &["ci", "browse", "--connection", "builds", "--json"],
    );
    assert_eq!(code, 0, "{root}");
    assert_eq!(root["jobs"].as_array().unwrap().len(), 1);
    assert_eq!(root["jobs"][0]["path"], "team");
    let (code, runs) = fx.json(
        "script",
        &[
            "ci",
            "browse",
            "team/app",
            "--connection",
            "builds",
            "--json",
        ],
    );
    assert_eq!(code, 0, "{runs}");
    assert_eq!(runs["runs"][0]["status"], "success");
    assert_eq!(runs["runs"][1]["status"], "running");
    assert!(runs["runs"][0]["url"]
        .as_str()
        .unwrap()
        .starts_with(&server.base));
    let output = fx
        .cmd(
            "script",
            &[
                "ci",
                "browse",
                "team/app",
                "42",
                "--connection",
                "builds",
                "--json",
            ],
        )
        .env("BUILD_TOKEN", "opaque-test-credential")
        .output()
        .unwrap();
    assert!(output.status.success());
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(!text.contains("opaque-test-credential"));
    let log: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert!(log["log"].as_str().unwrap().contains("ready"));
    assert!(server.requests().iter().all(|r| r.method == "GET"));
    assert!(!fx.repo().join(".gitch").exists());
}

#[test]
fn refuses_disallowed_jobs_and_invalid_build_numbers_before_request() {
    let server = Server::start(|_| Some(Resp::status(500)));
    let fx = Fx::new(&[]);
    connection(&fx, &server.base, "team/app");
    for args in [
        vec!["other"],
        vec!["team/app", "../secret"],
        vec!["team/../app"],
        vec!["team", "42"],
    ] {
        let mut command = vec!["ci", "browse"];
        command.extend(args);
        command.extend(["--connection", "builds", "--json"]);
        let (code, error) = fx.json("script", &command);
        assert_eq!(code, 1);
        assert!(error["error"]["message"].is_string());
    }
    assert!(server.requests().is_empty());
}

#[test]
fn log_redirect_never_forwards_credentials_to_another_origin() {
    let target = Server::start(|req| {
        assert!(req.header("Authorization").is_none());
        Some(Resp::text(200, "redirected log"))
    });
    let redirect = format!("{}/log", target.base);
    let server = Server::start(move |_| Some(Resp::status(302).header("Location", &redirect)));
    let fx = Fx::new(&[]);
    connection(&fx, &server.base, "team/app");
    let output = fx
        .cmd(
            "script",
            &[
                "ci",
                "browse",
                "team/app",
                "1",
                "--connection",
                "builds",
                "--json",
            ],
        )
        .env("BUILD_TOKEN", "opaque-test-credential")
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(target.count("GET", "/log"), 1);
}
