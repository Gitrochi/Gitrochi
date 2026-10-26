//! 명령 해석과 출력. 사람용 글은 gitch 처럼 한국어가 기본(`--lang en`), 기계용은 `--json` · `--events`.
//! 치명 오류는 gitch 와 같은 봉투 `{"schemaVersion":1,"error":{…}}` 를 표준오류에 쓴다.

use crate::plan::{self, Decision, PlanOptions};
use crate::run::{self, RunOptions};
use crate::spec::{self, FlowDef, NodeDef, NodeKind, Spec};
use crate::store::{self, Store};
use crate::trust;
use crate::util::{self, tr};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{IsTerminal, Read, Write};
use std::path::{Path, PathBuf};

pub const VALUE_FLAGS: &[&str] = &[
    "--env",
    "--only",
    "--jobs",
    "--since",
    "--format",
    "--out",
    "--lang",
    "--root",
    "--idempotency-key",
    "--run-id",
    "--older-than",
    "--trigger",
    "--keep",
    "--flow",
    "--tag",
    "--name",
    "--url",
    "--user",
    "--project",
    "--allow",
    "--secret-from",
    "--connection",
    "--ref",
    "--image",
    "--runs-on",
];

pub struct Args {
    pub pos: Vec<String>,
    pub flags: HashMap<String, Option<String>>,
}

impl Args {
    pub fn parse(raw: &[String]) -> Args {
        let mut pos = Vec::new();
        let mut flags = HashMap::new();
        let mut i = 0;
        while i < raw.len() {
            let a = &raw[i];
            if a == "--" {
                pos.extend(raw[i + 1..].iter().cloned());
                break;
            }
            if let Some(rest) = a.strip_prefix("--") {
                if let Some((k, v)) = rest.split_once('=') {
                    flags.insert(format!("--{k}"), Some(v.to_string()));
                } else if VALUE_FLAGS.contains(&a.as_str()) {
                    flags.insert(a.clone(), raw.get(i + 1).cloned());
                    i += 1;
                } else {
                    flags.insert(a.clone(), None);
                }
            } else if a == "-y" {
                flags.insert("--yes".into(), None);
            } else if a == "-j" {
                flags.insert("--jobs".into(), raw.get(i + 1).cloned());
                i += 1;
            } else {
                pos.push(a.clone());
            }
            i += 1;
        }
        Args { pos, flags }
    }
    pub fn has(&self, k: &str) -> bool {
        self.flags.contains_key(k)
    }
    pub fn val(&self, k: &str) -> Option<String> {
        self.flags
            .get(k)
            .cloned()
            .flatten()
            .filter(|s| !s.is_empty())
    }
}

/// 기계 출력 요청인지(파서가 실패해도 오류를 JSON 으로 내기 위해 먼저 본다).
fn wants_json(raw: &[String]) -> bool {
    raw.iter()
        .any(|a| a == "--json" || a == "--format=json" || a == "--events")
}

pub struct Out {
    pub json: bool,
}

impl Out {
    fn fail(&self, code: &str, exit: i32, message: &str, details: Value) -> i32 {
        if self.json {
            let env = json!({"schemaVersion": 1, "error": {"code": if exit == 2 { "GITCH_CONFIRMATION_REQUIRED" } else { "GITCH_ERROR" }, "flowCode": code,
                              "message": message, "exitCode": exit, "description": crate::codes::describe(code), "action": crate::codes::action(code), "details": details}});
            eprintln!("{env}");
        } else {
            eprintln!("{}", message);
            if crate::codes::known(code) {
                eprintln!("  {}", crate::codes::line(code));
            }
        }
        exit
    }
    fn print(&self, v: &Value) {
        println!("{}", serde_json::to_string_pretty(v).unwrap_or_default());
    }
}

fn root_of(args: &Args) -> Option<PathBuf> {
    let start = args
        .val("--root")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    crate::git::toplevel(&start)
}

fn spec_errors(out: &Out, errs: &[spec::SpecError]) -> i32 {
    if out.json {
        let details: Vec<Value> = errs.iter().map(|e| e.to_json()).collect();
        return out.fail(errs[0].code, 1, &errs[0].human(), Value::Array(details));
    }
    for e in errs.iter().take(30) {
        eprintln!("{}", e.human());
    }
    if errs.len() > 30 {
        eprintln!(
            "{}",
            tr(
                &format!("… 그 밖에 {}개", errs.len() - 30),
                &format!("… and {} more", errs.len() - 30)
            )
        );
    }
    eprintln!("  {}", crate::codes::line(errs[0].code));
    1
}

fn load(out: &Out, args: &Args) -> Result<Spec, i32> {
    let Some(root) = root_of(args) else {
        return Err(out.fail(
            "SPEC-08",
            1,
            &tr(
                "git 저장소 안에서 실행하세요.",
                "run this inside a git repository.",
            ),
            Value::Null,
        ));
    };
    spec::load(&root).map_err(|e| spec_errors(out, &e))
}

/// 사용자 설정(~/.config/gitsw/flow/settings.json): 운영 허용 · 기본 병렬 수 · 내부 도메인.
pub fn settings() -> Value {
    std::fs::read_to_string(util::gitsw_dir().join("flow").join("settings.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(json!({}))
}

fn prod_allowed(spec: &Spec, env: &str) -> bool {
    let s = settings();
    let repo = trust::repo_id(&spec.root);
    s["allowProd"][&repo]
        .as_array()
        .map(|a| a.iter().any(|x| x == env))
        .unwrap_or(false)
}

fn plan_opts(args: &Args, spec: &Spec, flow: &str) -> PlanOptions {
    let env = args.val("--env");
    let env_name = env
        .clone()
        .or(spec.flow(flow).and_then(|f| f.env.clone()))
        .unwrap_or_else(|| "local".into());
    PlanOptions {
        flow: flow.to_string(),
        env,
        only: args
            .val("--only")
            .map(|s| {
                s.split(',')
                    .map(|x| x.trim().to_string())
                    .filter(|x| !x.is_empty())
                    .collect()
            })
            .unwrap_or_default(),
        prod_allowed: prod_allowed(spec, &env_name),
        affected: if args.has("--affected") {
            Some(args.val("--affected").unwrap_or_else(|| "base".into()))
        } else {
            None
        },
        no_cache: args.has("--no-cache"),
    }
}

fn plan_errors(out: &Out, errs: &[plan::PlanError]) -> i32 {
    let first = &errs[0];
    if out.json {
        let details: Vec<Value> = errs.iter().map(|e| json!({"code": e.code, "message": e.message, "src": e.src.as_ref().map(|s| s.show())})).collect();
        return out.fail(first.code, 1, &first.message, Value::Array(details));
    }
    for e in errs {
        match &e.src {
            Some(s) => eprintln!("{}: [{}] {}", s.show(), e.code, e.message),
            None => eprintln!("[{}] {}", e.code, e.message),
        }
    }
    eprintln!("  {}", crate::codes::line(first.code));
    1
}

pub fn main(raw: Vec<String>) -> i32 {
    let early = Args::parse(&raw);
    util::set_lang(early.val("--lang").as_deref());
    let out = Out {
        json: wants_json(&raw),
    };
    let cmd = early.pos.first().cloned().unwrap_or_default();
    let args = Args {
        pos: early.pos.iter().skip(1).cloned().collect(),
        flags: early.flags,
    };
    if args.has("--secrets-stdin") {
        let mut buf = String::new();
        let _ = std::io::stdin().read_to_string(&mut buf);
        if let Err(e) = crate::secret::provide_json(&buf) {
            return out.fail("CONN-03", 1, &format!("--secrets-stdin: {e}"), Value::Null);
        }
    }
    match cmd.as_str() {
        "" | "help" | "-h" | "--help" => {
            println!("{}", help());
            0
        }
        "version" | "--version" | "-v" => {
            if out.json {
                out.print(&json!({"schemaVersion": 1, "tool": "gitch-flow", "version": env!("CARGO_PKG_VERSION"), "flowApi": 1, "specVersion": 1}));
            } else {
                println!("gitch-flow {}", env!("CARGO_PKG_VERSION"));
            }
            0
        }
        "schema" => cmd_schema(&out, &args),
        "init" => crate::detect::cmd_init(&out, &args),
        "doctor" => crate::doctor::cmd_doctor(&out, &args),
        "validate" => cmd_validate(&out, &args),
        "list" | "ls" => cmd_list(&out, &args),
        "plan" => cmd_plan(&out, &args),
        "run" => cmd_run(&out, &args, None),
        "test" => cmd_test(&out, &args),
        "status" => cmd_status(&out, &args),
        "events" => cmd_events(&out, &args),
        "logs" => cmd_logs(&out, &args),
        "report" => crate::report_out::cmd_report(&out, &args),
        "rerun" => cmd_rerun(&out, &args),
        "cancel" => cmd_cancel(&out, &args),
        "trust" => cmd_trust(&out, &args),
        "hold" => cmd_hold(&out, &args),
        "watch" => crate::watch::cmd_watch(&out, &args),
        "blocks" => cmd_blocks(&out, &args),
        "block" => cmd_block(&out, &args),
        "explain" => cmd_explain(&out, &args),
        "gc" => cmd_gc(&out, &args),
        "export" => crate::ci::export::cmd_export(&out, &args),
        "import" => crate::ci::import::cmd_import(&out, &args),
        "connect" => crate::connect::cmd_connect(&out, &args),
        "ci" => crate::ci::cmd_ci(&out, &args),
        "gate" => cmd_gate(&out, &args),
        "_names" => cmd_names(&args),
        other => out.fail(
            "PLAN-01",
            1,
            &tr(
                &format!("알 수 없는 명령: {other} (gitch flow help)"),
                &format!("unknown command: {other} (gitch flow help)"),
            ),
            Value::Null,
        ),
    }
}

pub fn help() -> String {
    tr(
        "gitch flow — 조립형 테스트 · CI 흐름 (.gitch/flow.yml)

  init [--dry-run] [--json] [--yes]        프로젝트를 읽고 흐름 파일을 제안 · 만든다(코드를 실행하지 않음)
  doctor [--env E] [--json]                도구 · Docker · 연결 · 신뢰 점검
  validate [--json]                        흐름 파일 검사
  list [--json]                            흐름 · 스위트 · 서비스 · 블록 목록
  plan <흐름> [--env E] [--affected[=base|staged|worktree]] [--only 노드,…] [--json]
  run <흐름> [plan 옵션] [--jobs N] [--fail-fast|--no-fail-fast] [--no-cache] [--keep-services]
             [--detach] [--json|--events|--summary] [--ci] [--idempotency-key K] [--yes]
  test [스위트|태그 …] [--affected] [--watch] [--json|--summary]
  status [실행ID|last] · events <실행ID> [--follow] [--since N] · logs <실행ID> [노드] [--follow]
  report <실행ID|last> [--format text|md|json|junit|html] [--out 파일]
  rerun <실행ID> [--failed] · cancel <실행ID> · watch <흐름> [--affected]
  trust [--show|--revoke] [--yes] · hold list|release <환경> · gate prepush|status
  blocks · block <ID> · explain <코드> · gc [--older-than 7d] [--dry-run] · schema [이름]
  export github|gitlab|jenkins [--flow F] [--out 경로] [--dry-run] · import [--dry-run]
  connect list|add|test|remove · ci status|logs|report|trigger

종료 코드: 0 성공 · 1 실패(구분은 JSON 의 state · code) · 2 사람 확인 필요",
        "gitch flow — composable test and CI flows (.gitch/flow.yml)

  init [--dry-run] [--json] [--yes]        read the project and propose a flow file (never runs project code)
  doctor [--env E] [--json]                check tools, Docker, connections and trust
  validate [--json]                        check the flow files
  list [--json]                            flows, suites, services and blocks
  plan <flow> [--env E] [--affected[=base|staged|worktree]] [--only node,…] [--json]
  run <flow> [plan options] [--jobs N] [--fail-fast|--no-fail-fast] [--no-cache] [--keep-services]
             [--detach] [--json|--events|--summary] [--ci] [--idempotency-key K] [--yes]
  test [suite|tag …] [--affected] [--watch] [--json|--summary]
  status [run-id|last] · events <run-id> [--follow] [--since N] · logs <run-id> [node] [--follow]
  report <run-id|last> [--format text|md|json|junit|html] [--out file]
  rerun <run-id> [--failed] · cancel <run-id> · watch <flow> [--affected]
  trust [--show|--revoke] [--yes] · hold list|release <env> · gate prepush|status
  blocks · block <ID> · explain <code> · gc [--older-than 7d] [--dry-run] · schema [name]
  export github|gitlab|jenkins [--flow F] [--out path] [--dry-run] · import [--dry-run]
  connect list|add|test|remove · ci status|logs|report|trigger

Exit codes: 0 success · 1 failure (see state and code in JSON) · 2 a person must confirm",
    )
}

fn cmd_schema(out: &Out, args: &Args) -> i32 {
    let name = args.pos.first().map(|s| s.as_str()).unwrap_or("flow");
    match crate::schemas::get(name) {
        Some(s) => {
            println!("{s}");
            0
        }
        None => out.fail(
            "PLAN-01",
            1,
            &tr(
                &format!(
                    "스키마 '{name}' 이(가) 없습니다({}).",
                    crate::schemas::NAMES.join(" · ")
                ),
                &format!(
                    "no schema named '{name}' ({}).",
                    crate::schemas::NAMES.join(", ")
                ),
            ),
            Value::Null,
        ),
    }
}

fn cmd_validate(out: &Out, args: &Args) -> i32 {
    match load(out, args) {
        Ok(spec) => {
            // 블록 입력까지 보려면 흐름마다 계획을 만든다.
            let mut errs = Vec::new();
            for f in &spec.flows {
                if let Err(e) = plan::build(
                    &spec,
                    &PlanOptions {
                        flow: f.name.clone(),
                        no_cache: true,
                        ..Default::default()
                    },
                ) {
                    errs.extend(e);
                }
            }
            if !errs.is_empty() {
                return plan_errors(out, &errs);
            }
            if out.json {
                out.print(&json!({"schemaVersion": 1, "valid": true, "files": spec.files.iter().map(|f| &f.rel).collect::<Vec<_>>(), "flows": spec.flows.len()}));
            } else {
                println!(
                    "{}",
                    tr(
                        &format!(
                            "✔ 흐름 파일이 올바릅니다({}개 파일, 흐름 {}개)",
                            spec.files.len(),
                            spec.flows.len()
                        ),
                        &format!(
                            "✔ the flow files are valid ({} files, {} flows)",
                            spec.files.len(),
                            spec.flows.len()
                        )
                    )
                );
            }
            0
        }
        Err(c) => c,
    }
}

fn cmd_list(out: &Out, args: &Args) -> i32 {
    let spec = match load(out, args) {
        Ok(s) => s,
        Err(c) => return c,
    };
    let st = Store::open(&spec.root);
    let last = |flow: &str| {
        st.as_ref()
            .and_then(|s| s.resolve("last", Some(flow)).and_then(|id| s.read_run(&id)))
    };
    let flows: Vec<Value> = spec
        .flows
        .iter()
        .map(|f| {
            let l = last(&f.name);
            json!({"name": f.name, "description": f.description, "trigger": f.trigger, "env": f.env, "nodes": f.nodes.len(),
                   "last": l.map(|r| json!({"runId": r["runId"], "state": r["state"], "finishedAt": r["finishedAt"], "durationMs": r["durationMs"], "signed": store::verify(&r)}))})
        })
        .collect();
    let data = json!({
        "schemaVersion": 1,
        "root": spec.root.to_string_lossy(),
        "project": spec.project_name,
        "trusted": trust::status(&spec).trusted,
        "flows": flows,
        "suites": spec.suites.iter().map(|s| json!({"name": s.name, "use": s.uses, "tags": s.tags, "affected": s.select.affected})).collect::<Vec<_>>(),
        "services": spec.services.iter().map(|s| json!({"name": s.name, "use": s.uses})).collect::<Vec<_>>(),
        "environments": spec.environments.iter().map(|e| json!({"name": e.name, "class": e.class.as_str()})).collect::<Vec<_>>(),
        "blocks": spec.blocks.iter().map(|b| json!({"name": b.name, "version": b.version})).collect::<Vec<_>>(),
    });
    if out.json {
        out.print(&data);
        return 0;
    }
    println!("{}", tr("흐름", "Flows"));
    for f in data["flows"].as_array().unwrap_or(&Vec::new()) {
        let last = match f["last"].as_object() {
            Some(l) => format!(
                "  {} {}",
                l["state"].as_str().unwrap_or(""),
                l["finishedAt"].as_str().unwrap_or("")
            ),
            None => String::new(),
        };
        println!(
            "  {}  ({} {}){last}",
            f["name"].as_str().unwrap_or(""),
            f["nodes"],
            tr("노드", "nodes")
        );
    }
    if !spec.suites.is_empty() {
        println!("{}", tr("스위트", "Suites"));
        for s in &spec.suites {
            println!("  {}  {}", s.name, s.uses);
        }
    }
    if !spec.services.is_empty() {
        println!("{}", tr("서비스", "Services"));
        for s in &spec.services {
            println!("  {}  {}", s.name, s.uses);
        }
    }
    if !trust::status(&spec).trusted {
        println!(
            "{}",
            tr(
                "⚠ 아직 신뢰하지 않은 흐름 파일입니다 — gitch flow trust",
                "⚠ this flow file is not trusted yet — gitch flow trust"
            )
        );
    }
    0
}

fn print_plan(p: &plan::Plan) {
    println!(
        "{} {} · {} ({})",
        tr("계획", "Plan"),
        p.flow,
        p.env,
        p.env_class.as_str()
    );
    for n in &p.nodes {
        let (mark, why) = match &n.decision {
            Decision::Run => ("▶", n.selection_reason.clone().unwrap_or_default()),
            Decision::Skip(_, m) => ("−", m.clone()),
            Decision::Rejected(c, m) => ("✘", format!("[{c}] {m}")),
        };
        let needs = if n.needs.is_empty() {
            String::new()
        } else {
            format!(" ← {}", n.needs.join(", "))
        };
        let branch = if n.branch_of.is_some() {
            tr(" (실패 갈래)", " (on failure)")
        } else {
            String::new()
        };
        println!(
            "  {mark} {} ({}){branch}{needs}{}",
            n.id,
            n.block,
            if why.is_empty() {
                String::new()
            } else {
                format!("  — {why}")
            }
        );
    }
    if !p.outward.is_empty() {
        println!(
            "{} {}",
            tr("외부 동작:", "Outward actions:"),
            p.outward.join(", ")
        );
    }
    for w in &p.warnings {
        println!("⚠ {w}");
    }
    println!(
        "{} {}",
        tr("예상 시간:", "Estimate:"),
        util::human_duration(p.estimate_ms())
    );
    if !p.trust.trusted {
        println!(
            "{}",
            tr(
                "⚠ 아직 신뢰하지 않은 흐름 파일입니다. 실행 전에 확인을 받습니다.",
                "⚠ this flow file is not trusted yet; you will be asked before it runs."
            )
        );
    }
}

fn cmd_plan(out: &Out, args: &Args) -> i32 {
    let spec = match load(out, args) {
        Ok(s) => s,
        Err(c) => return c,
    };
    let Some(flow) = args
        .pos
        .first()
        .cloned()
        .or_else(|| spec.flows.first().map(|f| f.name.clone()))
    else {
        return out.fail(
            "PLAN-01",
            1,
            &tr("흐름이 없습니다.", "there are no flows."),
            Value::Null,
        );
    };
    match plan::build(&spec, &plan_opts(args, &spec, &flow)) {
        Ok(p) => {
            if out.json {
                out.print(&p.to_json());
            } else {
                print_plan(&p);
            }
            0
        }
        Err(e) => plan_errors(out, &e),
    }
}

/// 신뢰 확인. Ok(true) 면 실행해도 된다.
fn ensure_trust(
    out: &Out,
    args: &Args,
    spec: &Spec,
    p: &plan::Plan,
    actor: &str,
) -> Result<(), i32> {
    if p.trust.trusted {
        return Ok(());
    }
    // CI 러너는 이미 저장소 코드를 실행하는 곳이라 따로 승인받지 않는다. AI 실행 주체에는 이 예외를 주지 않는다.
    let in_ci = std::env::var("CI")
        .map(|v| v == "true" || v == "1")
        .unwrap_or(false);
    if args.has("--ci") && in_ci && !trust::is_ai(actor) {
        return Ok(());
    }
    let changed = p.trust.changed.join(", ");
    if trust::is_ai(actor) {
        return Err(out.fail(
            "TRUST-01",
            2,
            &tr(&format!("흐름 파일을 아직 신뢰하지 않았습니다({changed}). 사람이 터미널에서 gitch flow trust 를 실행하거나 앱에서 승인해야 합니다."), &format!("the flow file is not trusted ({changed}). A person must run gitch flow trust in a terminal or approve it in the app.")),
            json!({"changed": p.trust.changed}),
        ));
    }
    if args.has("--yes") {
        let _ = trust::approve(spec, &p.outward, actor);
        return Ok(());
    }
    let tty = std::io::stdin().is_terminal() && std::io::stderr().is_terminal();
    if !tty {
        return Err(out.fail(
            "TRUST-01",
            2,
            &tr(
                &format!("흐름 파일을 아직 신뢰하지 않았습니다({changed})."),
                &format!("the flow file is not trusted ({changed})."),
            ),
            json!({"changed": p.trust.changed}),
        ));
    }
    eprintln!(
        "{}",
        tr(
            "이 저장소의 흐름 파일이 새로 생겼거나 바뀌었습니다. 아래 명령을 실행합니다:",
            "This repository's flow file is new or changed. These commands will run:"
        )
    );
    for n in p.nodes.iter().filter(|n| n.decision == Decision::Run) {
        let what = n
            .with
            .get("run")
            .and_then(|r| r.as_str())
            .map(|s| s.lines().next().unwrap_or("").to_string())
            .unwrap_or_else(|| n.block.clone());
        eprintln!("  • {}: {what}", n.id);
    }
    if !p.outward.is_empty() {
        eprintln!(
            "{} {}",
            tr("외부 동작:", "Outward actions:"),
            p.outward.join(", ")
        );
    }
    eprint!(
        "{}",
        tr(
            "이 흐름을 신뢰하고 실행할까요? [y/N] ",
            "Trust this flow and run it? [y/N] "
        )
    );
    let _ = std::io::stderr().flush();
    let mut a = String::new();
    let _ = std::io::stdin().read_line(&mut a);
    if matches!(
        a.trim().to_ascii_lowercase().as_str(),
        "y" | "yes" | "ㅇ" | "예" | "네"
    ) {
        let _ = trust::approve(spec, &p.outward, actor);
        Ok(())
    } else {
        Err(out.fail(
            "GATE-02",
            1,
            &tr("실행하지 않았습니다.", "not run."),
            Value::Null,
        ))
    }
}

fn detach(out: &Out, store: &Store) -> i32 {
    let run_id = Store::new_run_id();
    let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("gitch-flow"));
    let mut child_args: Vec<String> = std::env::args()
        .skip(1)
        .filter(|a| a != "--detach" && a != "--json" && a != "--events" && a != "--summary")
        .collect();
    child_args.push("--run-id".into());
    child_args.push(run_id.clone());
    child_args.push("--quiet".into());
    let run_dir = store.run_dir(&run_id);
    let _ = std::fs::create_dir_all(&run_dir);
    let mut c = std::process::Command::new(exe);
    c.args(&child_args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .env("GITCH_FLOW_DETACHED", "1");
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        c.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW
        c.creation_flags(0x0000_0008 | 0x0000_0200 | 0x0100_0000 | 0x0800_0000);
    }
    match c.spawn() {
        Ok(ch) => {
            let _ = std::fs::write(run_dir.join("pid"), ch.id().to_string());
            let v = json!({"schemaVersion": 1, "runId": run_id, "pid": ch.id(), "runDir": run_dir.to_string_lossy(), "eventsPath": run_dir.join("events.ndjson").to_string_lossy()});
            if out.json {
                out.print(&v);
            } else {
                println!("{}", tr(&format!("백그라운드에서 시작했습니다: {run_id}\n  따라 보기: gitch flow events {run_id} --follow"), &format!("started in the background: {run_id}\n  follow: gitch flow events {run_id} --follow")));
            }
            0
        }
        Err(e) => out.fail("ENGINE-01", 1, &e.to_string(), Value::Null),
    }
}

pub fn run_options(args: &Args, spec: &Spec, actor: &str) -> RunOptions {
    let human = !args.has("--json")
        && !args.has("--events")
        && !args.has("--summary")
        && !args.has("--quiet");
    let settings = settings();
    let jobs = args
        .val("--jobs")
        .and_then(|j| j.parse().ok())
        .or(spec.defaults.jobs)
        .or(settings["jobs"].as_u64().map(|x| x as usize))
        .unwrap_or_else(|| {
            std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(4)
        });
    RunOptions {
        jobs,
        fail_fast: if args.has("--fail-fast") {
            Some(true)
        } else if args.has("--no-fail-fast") {
            Some(false)
        } else {
            None
        },
        // AI 실행 주체의 --yes 는 사람 확인을 대신하지 못한다.
        yes: args.has("--yes") && !trust::is_ai(actor),
        interactive: std::io::stdin().is_terminal()
            && std::io::stderr().is_terminal()
            && std::env::var("GITCH_FLOW_DETACHED").is_err(),
        ci: args.has("--ci"),
        events_stdout: args.has("--events"),
        human,
        idempotency_key: args.val("--idempotency-key"),
        run_id: args.val("--run-id"),
        keep_services: args.has("--keep-services"),
        trigger: args.val("--trigger").unwrap_or_else(|| "manual".into()),
        actor: actor.to_string(),
    }
}

/// 실행 한 번(흐름 또는 즉석 흐름).
pub fn cmd_run(out: &Out, args: &Args, adhoc: Option<Spec>) -> i32 {
    let spec = match adhoc {
        Some(s) => s,
        None => match load(out, args) {
            Ok(s) => s,
            Err(c) => return c,
        },
    };
    let Some(flow) = args.pos.first().cloned().or_else(|| args.val("--flow")) else {
        return out.fail(
            "PLAN-01",
            1,
            &tr(
                "실행할 흐름 이름이 필요합니다(gitch flow list).",
                "name the flow to run (gitch flow list).",
            ),
            Value::Null,
        );
    };
    let actor = trust::actor();
    let p = match plan::build(&spec, &plan_opts(args, &spec, &flow)) {
        Ok(p) => p,
        Err(e) => return plan_errors(out, &e),
    };
    let Some(st) = Store::open(&spec.root) else {
        return out.fail(
            "ENGINE-02",
            1,
            &tr(
                "실행 기록 폴더를 열지 못했습니다.",
                "could not open the run store.",
            ),
            Value::Null,
        );
    };
    if let Err(c) = ensure_trust(out, args, &spec, &p, &actor) {
        return c;
    }
    if let Some(k) = args.val("--idempotency-key") {
        if let Ok(prev) = std::fs::read_to_string(st.idem_path(&k)) {
            if let Some(r) = st.read_run(prev.trim()) {
                if out.json {
                    out.print(&r);
                } else {
                    println!(
                        "{}",
                        tr(
                            &format!("같은 요청 키의 실행이 이미 있습니다: {}", prev.trim()),
                            &format!(
                                "a run with the same idempotency key exists: {}",
                                prev.trim()
                            )
                        )
                    );
                }
                return r["exitCode"].as_i64().unwrap_or(0) as i32;
            }
        }
    }
    if args.has("--detach") {
        return detach(out, &st);
    }
    let opts = run_options(args, &spec, &actor);
    let run_id = opts.run_id.clone().unwrap_or_else(Store::new_run_id);
    let _lock = match run::lock(&st, &p, &run_id) {
        Ok(l) => l,
        Err(holder) => {
            return out.fail(
                "LOCK-01",
                1,
                &tr(
                    &format!("같은 흐름이 이미 실행 중입니다({holder})."),
                    &format!("the same flow is already running ({holder})."),
                ),
                json!({"runId": holder}),
            );
        }
    };
    let mut opts = opts;
    opts.run_id = Some(run_id);
    if opts.human {
        println!(
            "{}",
            tr(
                &format!("흐름 {} · {} · {}개 노드", p.flow, p.env, p.nodes.len()),
                &format!("flow {} · {} · {} nodes", p.flow, p.env, p.nodes.len())
            )
        );
    }
    let res = run::execute(&spec, &p, &st, &opts);
    if args.has("--ci") {
        crate::ci::contract::write(&spec.root, &res.summary, &st);
    }
    if out.json {
        out.print(&res.summary);
    } else if args.has("--summary") {
        print!("{}", crate::report_out::digest(&res.summary, &st, true));
    } else if opts.human {
        print!("{}", crate::report_out::digest(&res.summary, &st, false));
    }
    res.exit_code
}

/// 즉석 흐름: 고른 스위트(없으면 전부)를 노드 하나씩으로.
fn cmd_test(out: &Out, args: &Args) -> i32 {
    let mut spec = match load(out, args) {
        Ok(s) => s,
        Err(c) => return c,
    };
    if args.has("--watch") {
        return crate::watch::watch_tests(out, args, spec);
    }
    let picks: Vec<String> = args.pos.clone();
    let suites: Vec<&spec::SuiteDef> = spec
        .suites
        .iter()
        .filter(|s| {
            picks.is_empty() || picks.contains(&s.name) || s.tags.iter().any(|t| picks.contains(t))
        })
        .collect();
    if suites.is_empty() {
        return out.fail(
            "PLAN-02",
            1,
            &tr(
                "돌릴 스위트가 없습니다(suites: 를 정의하거나 이름 · 태그를 확인하세요).",
                "no suites to run (define suites: or check the names and tags).",
            ),
            Value::Null,
        );
    }
    let nodes: Vec<NodeDef> = suites
        .iter()
        .map(|s| NodeDef {
            id: s.name.clone(),
            kind: NodeKind::Suite(s.name.clone()),
            needs: Vec::new(),
            cond: None,
            with: Value::Null,
            env: Vec::new(),
            secrets: Vec::new(),
            services: Vec::new(),
            executor: None,
            timeout_ms: None,
            retry: None,
            cache: None,
            expect: Default::default(),
            outputs: Vec::new(),
            locks: Vec::new(),
            optional: false,
            on_failure: Vec::new(),
            shell: None,
            cwd: None,
            weight: None,
            description: None,
            matrix: Vec::new(),
            src: s.src.clone(),
        })
        .collect();
    let name = "test".to_string();
    spec.flows.retain(|f| f.name != name);
    spec.flows.push(FlowDef {
        name: name.clone(),
        description: None,
        trigger: vec!["manual".into()],
        env: None,
        fail_fast: false,
        concurrency: spec::Concurrency::Reject,
        rollback_scope: None,
        rollback_on_check_failure: false,
        rollback_timeout_ms: None,
        notify: Vec::new(),
        timeout_ms: None,
        nodes,
        src: Default::default(),
    });
    let mut a = Args {
        pos: vec![name],
        flags: args.flags.clone(),
    };
    a.flags.remove("--watch");
    cmd_run(out, &a, Some(spec))
}

fn store_for(out: &Out, args: &Args) -> Result<(PathBuf, Store), i32> {
    let Some(root) = root_of(args) else {
        return Err(out.fail(
            "SPEC-08",
            1,
            &tr(
                "git 저장소 안에서 실행하세요.",
                "run this inside a git repository.",
            ),
            Value::Null,
        ));
    };
    match Store::open(&root) {
        Some(s) => Ok((root, s)),
        None => Err(out.fail(
            "ENGINE-02",
            1,
            &tr(
                "실행 기록 폴더를 열지 못했습니다.",
                "could not open the run store.",
            ),
            Value::Null,
        )),
    }
}

pub fn resolve_run(out: &Out, st: &Store, key: Option<&String>) -> Result<String, i32> {
    let k = key.map(|s| s.as_str()).unwrap_or("last");
    st.resolve(k, None).ok_or_else(|| {
        out.fail(
            "PLAN-02",
            1,
            &tr(
                &format!("실행 '{k}' 을(를) 찾지 못했습니다."),
                &format!("run '{k}' was not found."),
            ),
            Value::Null,
        )
    })
}

fn cmd_status(out: &Out, args: &Args) -> i32 {
    let (_, st) = match store_for(out, args) {
        Ok(x) => x,
        Err(c) => return c,
    };
    if args.has("--all") {
        let runs: Vec<Value> = st.run_ids().iter().take(50).filter_map(|id| st.read_run(id)).map(|r| json!({"runId": r["runId"], "flow": r["flow"], "env": r["env"], "state": r["state"], "startedAt": r["startedAt"], "durationMs": r["durationMs"], "signed": store::verify(&r)})).collect();
        if out.json {
            out.print(&json!({"schemaVersion": 1, "runs": runs}));
        } else {
            for r in runs {
                println!(
                    "{}  {}  {}  {}",
                    r["runId"].as_str().unwrap_or(""),
                    r["flow"].as_str().unwrap_or(""),
                    r["state"].as_str().unwrap_or(""),
                    r["startedAt"].as_str().unwrap_or("")
                );
            }
        }
        return 0;
    }
    let id = match resolve_run(out, &st, args.pos.first()) {
        Ok(i) => i,
        Err(c) => return c,
    };
    let Some(mut r) = st.read_run(&id) else {
        return out.fail(
            "ENGINE-02",
            1,
            &tr(
                "실행 기록을 읽지 못했습니다.",
                "could not read the run record.",
            ),
            Value::Null,
        );
    };
    let running = r["state"] == "RUNNING" && store::pid_alive(&st.run_dir(&id));
    r["running"] = json!(running);
    r["signed"] = json!(store::verify(&r));
    if out.json {
        out.print(&r);
    } else {
        print!("{}", crate::report_out::digest(&r, &st, false));
    }
    if r["state"] == "SUCCEEDED" || running {
        0
    } else {
        1
    }
}

fn cmd_events(out: &Out, args: &Args) -> i32 {
    let (_, st) = match store_for(out, args) {
        Ok(x) => x,
        Err(c) => return c,
    };
    let id = match resolve_run(out, &st, args.pos.first()) {
        Ok(i) => i,
        Err(c) => return c,
    };
    let since = args
        .val("--since")
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let stdout = std::io::stdout();
    store::follow(&st.run_dir(&id), since, args.has("--follow"), &mut |v| {
        let mut o = stdout.lock();
        let _ = writeln!(o, "{v}");
        let _ = o.flush();
    });
    0
}

fn cmd_logs(out: &Out, args: &Args) -> i32 {
    let (_, st) = match store_for(out, args) {
        Ok(x) => x,
        Err(c) => return c,
    };
    let id = match resolve_run(out, &st, args.pos.first()) {
        Ok(i) => i,
        Err(c) => return c,
    };
    let dir = st.run_dir(&id).join("logs");
    match args.pos.get(1) {
        Some(node) => {
            let p = dir.join(format!("{}.log", store::safe(node)));
            if args.has("--follow") {
                store::follow(&st.run_dir(&id), 0, true, &mut |v| {
                    if v["type"] == "log" && v["node"] == node.as_str() {
                        for l in v["data"]["lines"].as_array().cloned().unwrap_or_default() {
                            println!("{}", l["t"].as_str().or(l.as_str()).unwrap_or(""));
                        }
                    }
                });
                return 0;
            }
            match std::fs::read_to_string(&p) {
                Ok(t) => {
                    print!("{t}");
                    0
                }
                Err(_) => out.fail(
                    "PLAN-02",
                    1,
                    &tr(
                        &format!("노드 '{node}' 의 로그가 없습니다."),
                        &format!("no log for node '{node}'."),
                    ),
                    Value::Null,
                ),
            }
        }
        None => {
            let mut names: Vec<String> = std::fs::read_dir(&dir)
                .map(|rd| {
                    rd.flatten()
                        .map(|e| e.file_name().to_string_lossy().to_string())
                        .collect()
                })
                .unwrap_or_default();
            names.sort();
            for n in names {
                println!("{}", dir.join(n).to_string_lossy());
            }
            0
        }
    }
}

fn cmd_rerun(out: &Out, args: &Args) -> i32 {
    let (_, st) = match store_for(out, args) {
        Ok(x) => x,
        Err(c) => return c,
    };
    let id = match resolve_run(out, &st, args.pos.first()) {
        Ok(i) => i,
        Err(c) => return c,
    };
    let Some(r) = st.read_run(&id) else {
        return out.fail(
            "ENGINE-02",
            1,
            &tr(
                "실행 기록을 읽지 못했습니다.",
                "could not read the run record.",
            ),
            Value::Null,
        );
    };
    let flow = r["flow"].as_str().unwrap_or("").to_string();
    let mut a = Args {
        pos: vec![flow],
        flags: args.flags.clone(),
    };
    if let Some(e) = r["env"].as_str() {
        a.flags.entry("--env".into()).or_insert(Some(e.to_string()));
    }
    if args.has("--failed") {
        let failed: Vec<String> = r["nodes"]
            .as_array()
            .map(|ns| {
                ns.iter()
                    .filter(|n| {
                        matches!(
                            n["state"].as_str(),
                            Some("FAILED" | "INDETERMINATE" | "REJECTED" | "CANCELLED")
                        ) && n["branchOf"].is_null()
                    })
                    .filter_map(|n| n["id"].as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();
        if failed.is_empty() {
            println!(
                "{}",
                tr(
                    "다시 돌릴 실패 노드가 없습니다.",
                    "there are no failed nodes to rerun."
                )
            );
            return 0;
        }
        a.flags.insert("--only".into(), Some(failed.join(",")));
    }
    a.flags.insert("--trigger".into(), Some("rerun".into()));
    cmd_run(out, &a, None)
}

fn cmd_cancel(out: &Out, args: &Args) -> i32 {
    let (_, st) = match store_for(out, args) {
        Ok(x) => x,
        Err(c) => return c,
    };
    let id = match resolve_run(out, &st, args.pos.first()) {
        Ok(i) => i,
        Err(c) => return c,
    };
    let dir = st.run_dir(&id);
    let _ = std::fs::write(dir.join("cancel.request"), "cancel");
    #[cfg(unix)]
    if let Some(pid) = std::fs::read_to_string(dir.join("pid"))
        .ok()
        .and_then(|s| s.trim().parse::<i32>().ok())
    {
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
    }
    if out.json {
        out.print(&json!({"schemaVersion": 1, "runId": id, "cancelRequested": true}));
    } else {
        println!(
            "{}",
            tr(
                &format!("취소를 요청했습니다: {id}"),
                &format!("cancel requested: {id}")
            )
        );
    }
    0
}

fn cmd_trust(out: &Out, args: &Args) -> i32 {
    let spec = match load(out, args) {
        Ok(s) => s,
        Err(c) => return c,
    };
    let status = trust::status(&spec);
    if args.has("--revoke") {
        let removed = trust::revoke(&spec.root);
        if out.json {
            out.print(&json!({"schemaVersion": 1, "revoked": removed}));
        } else {
            println!(
                "{}",
                if removed {
                    tr("신뢰를 거두었습니다.", "trust revoked.")
                } else {
                    tr("신뢰 기록이 없습니다.", "there was no trust record.")
                }
            );
        }
        return 0;
    }
    let commands: Vec<Value> = spec
        .flows
        .iter()
        .flat_map(|f| f.nodes.iter().map(move |n| (f, n)))
        .map(|(f, n)| {
            let what = match &n.kind {
                NodeKind::Run(r) => r.clone(),
                NodeKind::Use(u) => u.clone(),
                NodeKind::Suite(s) => format!("suite {s}"),
                NodeKind::Flow(x) => format!("flow {x}"),
            };
            json!({"flow": f.name, "node": n.id, "what": what})
        })
        .collect();
    if args.has("--show") || (!args.has("--yes") && out.json) {
        let v = json!({"schemaVersion": 1, "trusted": status.trusted, "changed": status.changed, "approvedAt": status.approved_at, "files": spec.files.iter().map(|f| json!({"rel": f.rel, "sha256": f.sha256})).collect::<Vec<_>>(), "commands": commands, "record": trust::trust_path(&spec.root).to_string_lossy()});
        if out.json {
            out.print(&v);
        } else {
            println!(
                "{}",
                if status.trusted {
                    tr("✔ 신뢰함", "✔ trusted")
                } else {
                    tr("⚠ 아직 신뢰하지 않음", "⚠ not trusted yet")
                }
            );
            for f in &spec.files {
                println!("  {}  {}", &f.sha256[..12], f.rel);
            }
        }
        return 0;
    }
    let actor = trust::actor();
    if trust::is_ai(&actor) {
        return out.fail(
            "TRUST-02",
            2,
            &crate::codes::describe("TRUST-02"),
            Value::Null,
        );
    }
    if !args.has("--yes") {
        let tty = std::io::stdin().is_terminal() && std::io::stderr().is_terminal();
        if !tty {
            return out.fail(
                "CONFIRM-01",
                2,
                &tr(
                    "사람 확인이 필요합니다(터미널에서 실행하거나 --yes).",
                    "a person must confirm (run it in a terminal, or pass --yes).",
                ),
                Value::Null,
            );
        }
        eprintln!(
            "{}",
            tr(
                "이 저장소의 흐름 파일에 있는 명령:",
                "Commands in this repository's flow files:"
            )
        );
        for c in &commands {
            eprintln!(
                "  • {}/{}: {}",
                c["flow"].as_str().unwrap_or(""),
                c["node"].as_str().unwrap_or(""),
                c["what"]
                    .as_str()
                    .unwrap_or("")
                    .lines()
                    .next()
                    .unwrap_or("")
            );
        }
        eprint!(
            "{}",
            tr("신뢰할까요? [y/N] ", "Trust these flow files? [y/N] ")
        );
        let _ = std::io::stderr().flush();
        let mut a = String::new();
        let _ = std::io::stdin().read_line(&mut a);
        if !matches!(
            a.trim().to_ascii_lowercase().as_str(),
            "y" | "yes" | "ㅇ" | "예" | "네"
        ) {
            return out.fail(
                "GATE-02",
                1,
                &tr("신뢰하지 않았습니다.", "not trusted."),
                Value::Null,
            );
        }
    }
    match trust::approve(&spec, &[], &actor) {
        Ok(p) => {
            if out.json {
                out.print(
                    &json!({"schemaVersion": 1, "trusted": true, "record": p.to_string_lossy()}),
                );
            } else {
                println!(
                    "{}",
                    tr(
                        "✔ 이 흐름 파일들을 신뢰합니다. 파일이 바뀌면 다시 묻습니다.",
                        "✔ these flow files are trusted. You will be asked again if they change."
                    )
                );
            }
            0
        }
        Err(e) => out.fail("ENGINE-02", 1, &e.to_string(), Value::Null),
    }
}

fn cmd_hold(out: &Out, args: &Args) -> i32 {
    let (_, st) = match store_for(out, args) {
        Ok(x) => x,
        Err(c) => return c,
    };
    match args.pos.first().map(|s| s.as_str()) {
        Some("release") => {
            let Some(env) = args.pos.get(1) else {
                return out.fail(
                    "PLAN-03",
                    1,
                    &tr(
                        "풀 환경 이름이 필요합니다.",
                        "name the environment to release.",
                    ),
                    Value::Null,
                );
            };
            let actor = trust::actor();
            if trust::is_ai(&actor) {
                return out.fail(
                    "CONFIRM-01",
                    2,
                    &tr(
                        "hold 는 사람이 풀어야 합니다.",
                        "a person must release a hold.",
                    ),
                    Value::Null,
                );
            }
            let removed = std::fs::remove_file(st.hold_path(env)).is_ok();
            if out.json {
                out.print(&json!({"schemaVersion": 1, "env": env, "released": removed}));
            } else {
                println!(
                    "{}",
                    if removed {
                        tr("풀었습니다.", "released.")
                    } else {
                        tr("잠긴 환경이 아닙니다.", "that environment is not on hold.")
                    }
                );
            }
            0
        }
        _ => {
            let dir = st.base.join("holds");
            let holds: Vec<Value> = std::fs::read_dir(&dir)
                .map(|rd| rd.flatten().map(|e| {
                    let text = std::fs::read_to_string(e.path()).unwrap_or_default();
                    json!({"env": e.file_name().to_string_lossy().trim_end_matches(".json"), "reason": crate::rollback::hold_message(&text),
                           "record": serde_json::from_str::<Value>(&text).unwrap_or(Value::Null)})
                }).collect())
                .unwrap_or_default();
            if out.json {
                out.print(&json!({"schemaVersion": 1, "holds": holds}));
            } else if holds.is_empty() {
                println!(
                    "{}",
                    tr("잠긴 환경이 없습니다.", "no environments are on hold.")
                );
            } else {
                for h in holds {
                    println!(
                        "{}  {}",
                        h["env"].as_str().unwrap_or(""),
                        h["reason"]
                            .as_str()
                            .unwrap_or("")
                            .lines()
                            .next()
                            .unwrap_or("")
                    );
                }
            }
            0
        }
    }
}

fn cmd_blocks(out: &Out, _args: &Args) -> i32 {
    let list: Vec<Value> = crate::blocks::all()
        .iter()
        .map(|b| b.meta().to_json())
        .collect();
    if out.json {
        out.print(&json!({"schemaVersion": 1, "blocks": list, "services": crate::services::KINDS}));
    } else {
        for b in crate::blocks::all() {
            let m = b.meta();
            println!("{:<18} {:<8} {}", m.id, m.category, m.title());
        }
        println!(
            "{}",
            tr(
                &format!("서비스: {}", crate::services::KINDS.join(" · ")),
                &format!("services: {}", crate::services::KINDS.join(", "))
            )
        );
    }
    0
}

fn cmd_block(out: &Out, args: &Args) -> i32 {
    let Some(id) = args.pos.first() else {
        return out.fail(
            "PLAN-02",
            1,
            &tr("블록 ID 가 필요합니다.", "a block ID is required."),
            Value::Null,
        );
    };
    match crate::blocks::get(id) {
        Some(b) => {
            let j = b.meta().to_json();
            if out.json {
                out.print(&json!({"schemaVersion": 1, "block": j}));
            } else {
                println!("{}", serde_json::to_string_pretty(&j).unwrap_or_default());
            }
            0
        }
        None => out.fail(
            "SPEC-04",
            1,
            &tr(
                &format!("블록 '{id}' 이(가) 없습니다."),
                &format!("no block named '{id}'."),
            ),
            Value::Null,
        ),
    }
}

fn cmd_explain(out: &Out, args: &Args) -> i32 {
    match args.pos.first() {
        Some(code) if crate::codes::known(code) => {
            if out.json {
                out.print(&json!({"schemaVersion": 1, "code": code, "description": crate::codes::describe(code), "action": crate::codes::action(code)}));
            } else {
                println!("{}", crate::codes::line(code));
            }
            0
        }
        Some(code) => out.fail(
            "PLAN-02",
            1,
            &tr(
                &format!("모르는 코드: {code}"),
                &format!("unknown code: {code}"),
            ),
            Value::Null,
        ),
        None => {
            if out.json {
                out.print(&json!({"schemaVersion": 1, "codes": crate::codes::catalog()}));
            } else {
                for r in crate::codes::CODES {
                    println!("{}", crate::codes::line(r.0));
                }
            }
            0
        }
    }
}

fn cmd_gc(out: &Out, args: &Args) -> i32 {
    let (_, st) = match store_for(out, args) {
        Ok(x) => x,
        Err(c) => return c,
    };
    let older = args
        .val("--older-than")
        .and_then(|d| {
            util::parse_duration(&d.replace('d', "h").replace("hh", "h")).map(|ms| {
                if d.ends_with('d') {
                    ms * 24
                } else {
                    ms
                }
            })
        })
        .unwrap_or(7 * 24 * 3_600_000);
    let keep = args
        .val("--keep")
        .and_then(|k| k.parse().ok())
        .unwrap_or(50);
    let dry = args.has("--dry-run");
    let removed = st.gc(older, keep, dry);
    let cache = crate::cache::gc(older.max(14 * 24 * 3_600_000), dry);
    let leftovers: Vec<Value> = if crate::docker::available().is_ok() {
        crate::docker::leftovers()
            .into_iter()
            .filter(|(_, run)| {
                !st.run_dir(run).join("pid").is_file() || !store::pid_alive(&st.run_dir(run))
            })
            .map(|(name, run)| {
                if !dry {
                    crate::docker::remove_container(&name);
                }
                json!({"container": name, "runId": run})
            })
            .collect()
    } else {
        Vec::new()
    };
    if out.json {
        out.print(&json!({"schemaVersion": 1, "dryRun": dry, "runs": removed, "cacheEntries": cache, "containers": leftovers}));
    } else {
        println!(
            "{}",
            tr(
                &format!(
                    "실행 기록 {}개 · 캐시 {}개 · 남은 컨테이너 {}개{}",
                    removed.len(),
                    cache,
                    leftovers.len(),
                    if dry { " (미리 보기)" } else { "" }
                ),
                &format!(
                    "{} runs, {} cache entries, {} leftover containers{}",
                    removed.len(),
                    cache,
                    leftovers.len(),
                    if dry { " (dry run)" } else { "" }
                )
            )
        );
    }
    0
}

/// 자동완성용 이름 목록(흐름 · 스위트). 오류는 조용히 빈 목록.
fn cmd_names(args: &Args) -> i32 {
    let Some(root) = root_of(args) else { return 0 };
    let Ok(spec) = spec::load(&root) else {
        return 0;
    };
    match args.pos.first().map(|s| s.as_str()) {
        Some("suites") => spec.suites.iter().for_each(|s| println!("{}", s.name)),
        _ => spec.flows.iter().for_each(|f| println!("{}", f.name)),
    }
    0
}

/// `gate prepush|status`: pre-push 게이트 판단(gitch 훅 · Push 검토가 같은 함수를 쓴다).
fn cmd_gate(out: &Out, args: &Args) -> i32 {
    crate::gate_check::cmd_gate(out, args)
}

pub fn repo_root(args: &Args) -> Option<PathBuf> {
    root_of(args)
}

pub fn exists(p: &Path) -> bool {
    p.exists()
}
