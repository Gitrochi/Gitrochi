//! 원격 CI 블록: `ci.gitlab.pipeline` · `ci.gitlab.job` · `ci.github.workflow` · `ci.jenkins.job` · `ci.http`.
//! 같은 운전 규칙(ci::drive)을 쓰고, 판정은 결과 계약 → 기본 보고서 → 판정 불가 순서. CI 결론은 관측값으로만 남긴다.

use super::{schema, Block, Issue, Meta, NodeCx, NodeResult, PreCx};
use crate::ci::{self, DriveOpts, RState};
use crate::connect;
use crate::spec::FlakyPolicy;
use crate::util::tr;
use crate::verify::{self, Outcome, Verdict};
use serde_json::{json, Value};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    GitlabPipeline,
    GitlabJob,
    GithubWorkflow,
    JenkinsJob,
    Http,
}

pub struct CiBlock {
    pub meta: Meta,
    pub kind: Kind,
}

const CODES: &[&str] = &[
    "CI-01", "CI-02", "CI-03", "CI-04", "CI-05", "CI-06", "CI-07", "CONN-01", "CONN-02", "CONN-03",
    "CONN-04", "CONN-05", "CONN-06", "EXEC-05", "TEST-01", "TEST-02", "TEST-03",
];

fn inputs_gl_pipeline() -> Value {
    schema(
        json!({"connection": {"type": "string"}, "project": {"type": "string"}, "ref": {"type": "string"}, "variables": {"type": "object"}, "timeout": {"type": "string", "default": "60m"}}),
        &["connection"],
    )
}
fn inputs_gl_job() -> Value {
    schema(
        json!({"connection": {"type": "string"}, "project": {"type": "string"}, "ref": {"type": "string"}, "job": {"type": "string"}, "pipeline": {"type": "string"}, "variables": {"type": "object"}, "timeout": {"type": "string"}}),
        &["connection", "job"],
    )
}
fn inputs_gh() -> Value {
    schema(
        json!({"connection": {"type": "string"}, "repo": {"type": "string"}, "workflow": {"type": "string"}, "ref": {"type": "string"}, "inputs": {"type": "object"}, "correlate": {"type": "boolean", "default": true}, "timeout": {"type": "string"}}),
        &["connection", "workflow"],
    )
}
fn inputs_jenkins() -> Value {
    schema(
        json!({"connection": {"type": "string"}, "job": {"type": "string"}, "parameters": {"type": "object"}, "correlate": {"type": "boolean", "default": true}, "timeout": {"type": "string"}}),
        &["connection", "job"],
    )
}
fn inputs_http() -> Value {
    schema(
        json!({"connection": {"type": "string"}, "trigger": {"type": "object"}, "id": {"type": "string"}, "status": {"type": "object"}, "logs": {"type": "object"}, "cancel": {"type": "object"}, "find": {"type": "object"}, "timeout": {"type": "string"}}),
        &["trigger", "status"],
    )
}

macro_rules! ci_block {
    ($id:literal, $ko:literal, $en:literal, $kind:expr, $inputs:ident) => {
        CiBlock {
            meta: Meta {
                id: $id,
                version: "1.0.0",
                title: ($ko, $en),
                category: "ci",
                capabilities: &["network", "ci-api", "outward"],
                env_classes: &[],
                destructive: false,
                outward: true,
                codes: CODES,
                inputs: $inputs,
                selects_files: false,
                estimate_ms: 600_000,
            },
            kind: $kind,
        }
    };
}

pub static CI_BLOCKS: &[CiBlock] = &[
    ci_block!(
        "ci.gitlab.pipeline",
        "GitLab 파이프라인",
        "GitLab pipeline",
        Kind::GitlabPipeline,
        inputs_gl_pipeline
    ),
    ci_block!(
        "ci.gitlab.job",
        "GitLab 수동 작업",
        "GitLab manual job",
        Kind::GitlabJob,
        inputs_gl_job
    ),
    ci_block!(
        "ci.github.workflow",
        "GitHub Actions 워크플로",
        "GitHub Actions workflow",
        Kind::GithubWorkflow,
        inputs_gh
    ),
    ci_block!(
        "ci.jenkins.job",
        "Jenkins 작업",
        "Jenkins job",
        Kind::JenkinsJob,
        inputs_jenkins
    ),
    ci_block!("ci.http", "HTTP CI", "HTTP CI", Kind::Http, inputs_http),
];

fn target_name(kind: Kind, with: &Value) -> String {
    let s = |k: &str| {
        with.get(k)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    match kind {
        Kind::GitlabPipeline => format!("pipeline:{}", s("ref")),
        Kind::GitlabJob => s("job"),
        Kind::GithubWorkflow => s("workflow"),
        Kind::JenkinsJob => s("job"),
        Kind::Http => s("trigger"),
    }
}

fn str_map(v: Option<&Value>) -> Vec<(String, String)> {
    v.and_then(|x| x.as_object())
        .map(|o| {
            o.iter()
                .map(|(k, x)| (k.clone(), crate::expr::to_text(x)))
                .collect()
        })
        .unwrap_or_default()
}

fn verdict(
    rule: &'static str,
    title: String,
    observed: String,
    expected: &str,
    result: Outcome,
    code: &'static str,
) -> Verdict {
    Verdict {
        rule,
        title,
        observed,
        expected: expected.into(),
        result,
        code: if result == Outcome::Pass {
            None
        } else {
            Some(code)
        },
        phase: "main",
    }
}

impl Block for CiBlock {
    fn meta(&self) -> &Meta {
        &self.meta
    }

    fn validate(&self, with: &Value) -> Vec<String> {
        let need = |k: &str| with.get(k).map(|v| !v.is_null()).unwrap_or(false);
        let mut e = Vec::new();
        match self.kind {
            Kind::Http => {
                if !need("trigger") || !need("status") {
                    e.push(tr(
                        "ci.http 에는 trigger 와 status 가 필요합니다.",
                        "ci.http needs trigger and status.",
                    ));
                }
            }
            _ => {
                if !need("connection") {
                    e.push(tr(
                        "connection(연결 이름)이 필요합니다.",
                        "connection (a connection name) is required.",
                    ));
                }
            }
        }
        if matches!(self.kind, Kind::GitlabJob | Kind::JenkinsJob) && !need("job") {
            e.push(tr("job 이 필요합니다.", "job is required."));
        }
        if self.kind == Kind::GithubWorkflow && !need("workflow") {
            e.push(tr(
                "workflow(파일 이름 또는 ID)가 필요합니다.",
                "workflow (file name or id) is required.",
            ));
        }
        e
    }

    fn preflight(&self, cx: &PreCx) -> Vec<Issue> {
        let Some(name) = cx.with.get("connection").and_then(|v| v.as_str()) else {
            return Vec::new();
        };
        if name.contains("${{") {
            return Vec::new();
        }
        match connect::find(name) {
            None => vec![Issue {
                code: "CONN-01",
                message: tr(
                    &format!("연결 '{name}' 이(가) 없습니다."),
                    &format!("connection '{name}' does not exist."),
                ),
            }],
            Some(c) => {
                let t = target_name(self.kind, cx.with);
                if !connect::allowed(&c, &t) {
                    vec![Issue {
                        code: "CI-07",
                        message: tr(
                            &format!("'{t}' 은(는) 연결 '{name}' 의 허용 목록에 없습니다."),
                            &format!("'{t}' is not on the allow list of connection '{name}'."),
                        ),
                    }]
                } else {
                    Vec::new()
                }
            }
        }
    }

    fn run(&self, cx: &mut NodeCx) -> NodeResult {
        let mut r = NodeResult {
            attempts: 1,
            ..Default::default()
        };
        let conn = cx.input_str("connection").and_then(|n| connect::find(&n));
        if self.kind != Kind::Http && conn.is_none() {
            r.verdicts.push(verdict(
                "C0",
                tr("연결", "connection"),
                tr("없음", "missing"),
                "ok",
                Outcome::Indeterminate,
                "CONN-01",
            ));
            return r;
        }
        let token = conn.as_ref().and_then(|c| connect::secret(c, cx.ci));
        if let Some(t) = &token {
            cx.masker.add_secret(
                &format!(
                    "conn-{}",
                    conn.as_ref().map(|c| c.name.as_str()).unwrap_or("x")
                ),
                t,
            );
        }
        let remote = crate::git::remote_url(&cx.root).unwrap_or_default();
        let git_ref = cx
            .input_str("ref")
            .or_else(|| crate::git::branch(&cx.root))
            .unwrap_or_else(|| "main".into());
        let timeout = cx
            .input_str("timeout")
            .and_then(|t| crate::util::parse_duration(&t))
            .unwrap_or(60 * 60_000);
        let opts = DriveOpts {
            timeout_ms: timeout,
            find_ms: 120_000,
            poll_ms: 5000,
            require_contract: cx.expect.result.as_deref() == Some("required"),
        };
        let correlate = cx
            .with
            .get("correlate")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        let driven = match self.kind {
            Kind::GitlabPipeline | Kind::GitlabJob => {
                let c = conn.clone().unwrap();
                let project = cx
                    .input_str("project")
                    .or(c.project.clone())
                    .unwrap_or_else(|| ci::repo_path(&remote));
                let api = ci::gitlab::Api::new(&c, token.clone());
                let vars = str_map(cx.with.get("variables"));
                if self.kind == Kind::GitlabPipeline {
                    let p = ci::gitlab::Pipeline {
                        api,
                        project: ci::gitlab::enc(&project),
                        git_ref: git_ref.clone(),
                        variables: vars,
                    };
                    ci::drive(&p, cx, &opts)
                } else {
                    let p = ci::gitlab::ManualJob {
                        api,
                        project: ci::gitlab::enc(&project),
                        git_ref: git_ref.clone(),
                        job: cx.input_str("job").unwrap_or_default(),
                        pipeline: cx.input_str("pipeline"),
                        variables: vars,
                    };
                    ci::drive(&p, cx, &opts)
                }
            }
            Kind::GithubWorkflow => {
                let c = conn.clone().unwrap();
                let repo = cx
                    .input_str("repo")
                    .or(c.project.clone())
                    .unwrap_or_else(|| ci::repo_path(&remote));
                let p = ci::github::Workflow {
                    api: ci::github::Api::new(&c, token.clone()),
                    repo,
                    workflow: cx.input_str("workflow").unwrap_or_default(),
                    git_ref: git_ref.clone(),
                    inputs: cx.with.get("inputs").cloned().unwrap_or(json!({})),
                    correlate,
                    before: Default::default(),
                    sent: Default::default(),
                };
                ci::drive(&p, cx, &opts)
            }
            Kind::JenkinsJob => {
                let c = conn.clone().unwrap();
                let p = ci::jenkins::Job::new(
                    &c,
                    token.clone(),
                    &cx.input_str("job").unwrap_or_default(),
                    str_map(cx.with.get("parameters")),
                    correlate,
                );
                ci::drive(&p, cx, &opts)
            }
            Kind::Http => {
                let auth = token.as_ref().map(|t| format!("Bearer {t}"));
                let p = ci::httpci::Http {
                    with: cx.with.clone(),
                    auth,
                };
                ci::drive(&p, cx, &opts)
            }
        };
        r.observe(
            "remote",
            json!(driven.run.as_ref().map(|x| cx.masker.mask(&x.url))),
        );
        r.observe(
            "conclusion",
            json!(driven.status.as_ref().map(|s| s.conclusion.clone())),
        );
        r.observe("reused", json!(driven.reused));
        r.observe("logLines", json!(driven.log_lines));
        r.observe(
            "correlation",
            json!(ci::correlation(cx.events_run_id(), &cx.id)),
        );
        r.mutated = false;
        let title = tr("원격 실행", "remote run");
        if let Some(e) = &driven.error {
            let result = if e.unknown_outcome || e.code == "CI-01" {
                Outcome::Indeterminate
            } else {
                Outcome::Fail
            };
            r.verdicts.push(verdict(
                "C0",
                title,
                e.message.clone(),
                "ok",
                result,
                e.code,
            ));
            r.detail = Some(e.message.clone());
            return r;
        }
        if driven.we_cancelled {
            let code = if driven.timed_out { "CI-05" } else { "EXEC-05" };
            r.verdicts.push(verdict(
                "C0",
                title,
                tr("기다리다 멈춤", "stopped while waiting"),
                "finished",
                Outcome::Fail,
                code,
            ));
            return r;
        }
        if let Some(s) = &driven.status {
            if s.state == RState::Cancelled {
                r.verdicts.push(verdict(
                    "C0",
                    title.clone(),
                    s.conclusion.clone(),
                    "finished",
                    Outcome::Fail,
                    "CI-04",
                ));
            }
        }
        match (&driven.contract, &driven.report) {
            (Some(c), _) => {
                r.observe("contract", c.clone());
                r.verdicts.push(verify::remote_result(
                    Some(ci::contract::outcome(c)),
                    driven
                        .status
                        .as_ref()
                        .map(|s| s.conclusion.as_str())
                        .unwrap_or(""),
                ));
            }
            (None, Some(rep)) if !opts.require_contract => {
                r.verdicts.push(verify::report_present(Some(rep)));
                r.verdicts
                    .push(verify::min_tests(rep, cx.expect.min_tests.unwrap_or(1)));
                let q = verify::Quarantined {
                    entries: &cx.quarantine,
                    today: cx.today.clone(),
                };
                r.verdicts.push(verify::pass_rate(
                    rep,
                    cx.expect.pass_rate.unwrap_or(1.0),
                    FlakyPolicy::Fail,
                    &q,
                ));
            }
            _ => r.verdicts.push(verify::remote_result(
                None,
                driven
                    .status
                    .as_ref()
                    .map(|s| s.conclusion.as_str())
                    .unwrap_or(""),
            )),
        }
        r.report = driven.report;
        r
    }
}
