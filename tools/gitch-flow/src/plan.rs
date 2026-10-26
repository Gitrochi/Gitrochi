//! Planning: expands a flow (composite blocks, sub-flows, failure branches) and decides run, skip or refuse for each node.
//! What `gitch flow plan` shows is the same plan `run` uses.

use crate::blocks;
use crate::spec::{
    self, Concurrency, EnvClass, Expect, NodeDef, NodeKind, Retry, RollbackScope, Select, Spec, Src,
};
use crate::trust;
use crate::util::{self, tr};
use serde_json::{json, Map, Value};
use std::collections::{BTreeSet, HashMap};

#[derive(Debug, Clone, PartialEq)]
pub enum Decision {
    Run,
    Skip(&'static str, String),
    Rejected(&'static str, String),
}

impl Decision {
    pub fn as_str(&self) -> &'static str {
        match self {
            Decision::Run => "run",
            Decision::Skip(..) => "skip",
            Decision::Rejected(..) => "rejected",
        }
    }
}

#[derive(Debug, Clone)]
pub struct PNode {
    pub id: String,
    pub title: String,
    pub block: String,
    pub needs: Vec<String>,
    pub cond: Option<String>,
    pub with: Value,
    pub scope_inputs: Value,
    pub def: NodeDef,
    pub expect: Expect,
    pub retry: Option<Retry>,
    pub services: Vec<String>,
    pub select: Option<Select>,
    pub suite: Option<String>,
    pub group: Option<String>,
    pub branch_of: Option<String>,
    pub decision: Decision,
    pub outward: bool,
    pub destructive: bool,
    pub capabilities: Vec<String>,
    pub estimate_ms: u64,
    pub timeout_ms: Option<u64>,
    pub selection: Option<Vec<String>>,
    pub selection_reason: Option<String>,
    pub cache_key: Option<String>,
    /// Where shell commands run (node, then environment, then local).
    pub executor: crate::executor::Executor,
    /// This node's matrix values (`${{ matrix.X }}`); empty without a matrix.
    pub matrix: Value,
    pub src: Src,
}

#[derive(Debug, Clone, Default)]
pub struct GitInfo {
    pub sha: String,
    pub branch: String,
    pub clean: bool,
}

#[derive(Debug, Clone)]
pub struct Plan {
    pub flow: String,
    pub env: String,
    pub env_class: EnvClass,
    pub nodes: Vec<PNode>,
    pub services: Vec<String>,
    pub outward: Vec<String>,
    pub trust: trust::Status,
    pub hash: String,
    pub files_hash: String,
    pub warnings: Vec<String>,
    pub fail_fast: bool,
    pub rollback_scope: RollbackScope,
    pub on_check_failure: bool,
    pub rollback_timeout_ms: u64,
    pub concurrency: Concurrency,
    pub timeout_ms: Option<u64>,
    pub gates: Vec<String>,
    pub git: GitInfo,
    pub affected: Option<Value>,
}

#[derive(Debug, Clone, Default)]
pub struct PlanOptions {
    pub flow: String,
    pub env: Option<String>,
    pub only: Vec<String>,
    /// Whether user settings allow destructive production-class blocks for this repository and environment.
    pub prod_allowed: bool,
    /// Affected selection (None turns it off): base, staged or worktree.
    pub affected: Option<String>,
    pub no_cache: bool,
}

#[derive(Debug, Clone)]
pub struct PlanError {
    pub code: &'static str,
    pub message: String,
    pub src: Option<Src>,
}

fn merge_with(base: &Value, over: &Value) -> Value {
    let mut b = if base.is_object() {
        base.clone()
    } else {
        Value::Object(Map::new())
    };
    if over.is_object() {
        spec::deep_merge(&mut b, over);
    }
    b
}

fn merge_expect(base: &Expect, over: &Expect) -> Expect {
    let mut raw = merge_with(&base.raw, &over.raw);
    if raw.as_object().map(|o| o.is_empty()).unwrap_or(true) {
        raw = Value::Null;
    }
    Expect {
        min_tests: over.min_tests.or(base.min_tests),
        pass_rate: over.pass_rate.or(base.pass_rate),
        result: over.result.clone().or(base.result.clone()),
        output: over.output.clone().or(base.output.clone()),
        exit: over.exit.clone().or(base.exit.clone()),
        raw,
    }
}

/// The matrix combinations, multiplied in the order they are defined.
fn combinations(m: &[(String, Vec<Value>)]) -> Vec<Vec<(String, Value)>> {
    let mut out: Vec<Vec<(String, Value)>> = vec![Vec::new()];
    for (k, vals) in m {
        let mut next = Vec::new();
        for base in &out {
            for v in vals {
                let mut c = base.clone();
                c.push((k.clone(), v.clone()));
                next.push(c);
            }
        }
        out = next;
    }
    out
}

/// Replaces only the placeholders known at planning time (`${{ matrix.X }}` and `${{ inputs.X }}`).
fn render_static(text: &str, matrix: &Value, inputs: &Value) -> String {
    let re = regex::Regex::new(r"\$\{\{\s*(matrix|inputs)\.([A-Za-z0-9_]+)\s*\}\}").expect("re");
    re.replace_all(text, |c: &regex::Captures| {
        let src = if &c[1] == "matrix" { matrix } else { inputs };
        src.get(&c[2])
            .map(crate::expr::to_text)
            .unwrap_or_else(|| c[0].to_string())
    })
    .into_owned()
}

struct Ex<'a> {
    spec: &'a Spec,
    out: Vec<PNode>,
    groups: HashMap<String, Vec<String>>,
    errors: Vec<PlanError>,
}

impl Ex<'_> {
    fn expand(
        &mut self,
        nodes: &[NodeDef],
        prefix: &str,
        scope: &Value,
        outer_needs: &[String],
        group: Option<&str>,
        depth: usize,
    ) {
        if depth > 8 {
            self.errors.push(PlanError {
                code: "SPEC-05",
                message: tr(
                    "흐름 · 블록이 너무 깊게 겹쳤습니다.",
                    "flows or blocks are nested too deeply.",
                ),
                src: None,
            });
            return;
        }
        let local: BTreeSet<&str> = nodes.iter().map(|n| n.id.as_str()).collect();
        for n in nodes {
            let id = format!("{prefix}{}", n.id);
            let mut needs: Vec<String> = n
                .needs
                .iter()
                .filter(|x| local.contains(x.as_str()))
                .map(|x| format!("{prefix}{x}"))
                .collect();
            if n.needs.is_empty() {
                needs.extend(outer_needs.iter().cloned());
            }
            match &n.kind {
                NodeKind::Flow(f) => {
                    let Some(fd) = self.spec.flow(f) else {
                        continue;
                    };
                    let inner_scope = merge_with(scope, &n.with);
                    let before = self.out.len();
                    let nodes = fd.nodes.clone();
                    self.expand(
                        &nodes,
                        &format!("{id}/"),
                        &inner_scope,
                        &needs,
                        Some(&id),
                        depth + 1,
                    );
                    let members: Vec<String> = self.out[before..]
                        .iter()
                        .filter(|x| x.branch_of.is_none())
                        .map(|x| x.id.clone())
                        .collect();
                    self.groups.insert(id, members);
                }
                NodeKind::Use(u) if spec::composite_name(u).is_some() => {
                    let name = spec::composite_name(u).unwrap_or_default().to_string();
                    let Some(c) = self.spec.composite(&name) else {
                        continue;
                    };
                    let mut defaults = Map::new();
                    for i in &c.inputs {
                        if let Some(d) = &i.default {
                            defaults.insert(i.name.clone(), d.clone());
                        }
                    }
                    let inputs = merge_with(&Value::Object(defaults), &n.with);
                    for i in &c.inputs {
                        if i.required && inputs.get(&i.name).map(|v| v.is_null()).unwrap_or(true) {
                            self.errors.push(PlanError {
                                code: "SPEC-03",
                                message: tr(
                                    &format!(
                                        "{id}: 복합 블록 {name} 에 입력 {} 이(가) 필요합니다.",
                                        i.name
                                    ),
                                    &format!(
                                        "{id}: composite block {name} needs input {}.",
                                        i.name
                                    ),
                                ),
                                src: Some(n.src.clone()),
                            });
                        }
                    }
                    let before = self.out.len();
                    let nodes = c.nodes.clone();
                    self.expand(
                        &nodes,
                        &format!("{id}/"),
                        &inputs,
                        &needs,
                        Some(&id),
                        depth + 1,
                    );
                    let members: Vec<String> = self.out[before..]
                        .iter()
                        .filter(|x| x.branch_of.is_none())
                        .map(|x| x.id.clone())
                        .collect();
                    self.groups.insert(id, members);
                }
                _ if !n.matrix.is_empty() => {
                    // One node per combination (`unit/node-20`); needs: [unit] waits for all of them.
                    let mut members = Vec::new();
                    for combo in combinations(&n.matrix) {
                        let suffix = combo
                            .iter()
                            .map(|(k, v)| {
                                format!("{k}-{}", crate::store::safe(&crate::expr::to_text(v)))
                            })
                            .collect::<Vec<_>>()
                            .join("-");
                        let cid = format!("{id}/{suffix}");
                        let mvals: Map<String, Value> = combo.into_iter().collect();
                        let before = self.out.len();
                        self.push_leaf(n, &cid, needs.clone(), scope, Some(&id), None);
                        for f in &n.on_failure {
                            let fid = format!("{cid}/on-failure/{}", f.id);
                            let mut fneeds = vec![cid.clone()];
                            fneeds.extend(f.needs.iter().map(|x| format!("{cid}/on-failure/{x}")));
                            self.push_leaf(f, &fid, fneeds, scope, Some(&id), Some(cid.clone()));
                        }
                        for p in self.out[before..].iter_mut() {
                            p.matrix = Value::Object(mvals.clone());
                        }
                        members.push(cid);
                    }
                    self.groups.insert(id, members);
                }
                _ => {
                    self.push_leaf(n, &id, needs, scope, group, None);
                    for f in &n.on_failure {
                        let fid = format!("{id}/on-failure/{}", f.id);
                        let mut fneeds = vec![id.clone()];
                        fneeds.extend(f.needs.iter().map(|x| format!("{id}/on-failure/{x}")));
                        self.push_leaf(f, &fid, fneeds, scope, group, Some(id.clone()));
                    }
                }
            }
        }
    }

    fn push_leaf(
        &mut self,
        n: &NodeDef,
        id: &str,
        needs: Vec<String>,
        scope: &Value,
        group: Option<&str>,
        branch_of: Option<String>,
    ) {
        let mut block = String::new();
        let mut with = n.with.clone();
        let mut expect = n.expect.clone();
        let mut retry = n.retry.clone();
        let mut services = n.services.clone();
        let mut select = None;
        let mut suite = None;
        let mut timeout = n.timeout_ms;
        match &n.kind {
            NodeKind::Run(cmd) => {
                block = "cmd".into();
                with = merge_with(&json!({"run": cmd}), &n.with);
            }
            NodeKind::Use(u) => block = u.clone(),
            NodeKind::Suite(s) => {
                if let Some(sd) = self.spec.suite(s) {
                    block = sd.uses.clone();
                    with = merge_with(&sd.with, &n.with);
                    expect = merge_expect(&sd.expect, &n.expect);
                    retry = n.retry.clone().or(sd.retry.clone());
                    for sv in &sd.services {
                        if !services.contains(sv) {
                            services.push(sv.clone());
                        }
                    }
                    select = Some(sd.select.clone());
                    suite = Some(s.clone());
                    timeout = n.timeout_ms.or(sd.timeout_ms);
                }
            }
            NodeKind::Flow(_) => {}
        }
        let (title, outward, destructive, caps, est) = match blocks::get(&block) {
            Some(b) => {
                let m = b.meta();
                for e in b.validate(&with) {
                    self.errors.push(PlanError {
                        code: "SPEC-03",
                        message: format!("{id} ({block}): {e}"),
                        src: Some(n.src.clone()),
                    });
                }
                (
                    m.title(),
                    m.outward,
                    m.destructive,
                    m.capabilities.iter().map(|s| s.to_string()).collect(),
                    m.estimate_ms,
                )
            }
            None => {
                self.errors.push(PlanError {
                    code: "SPEC-04",
                    message: tr(
                        &format!(
                            "{id}: 블록 '{block}' 이(가) 없습니다(gitch flow blocks 로 목록 확인)."
                        ),
                        &format!("{id}: block '{block}' does not exist (see gitch flow blocks)."),
                    ),
                    src: Some(n.src.clone()),
                });
                (block.clone(), false, false, Vec::new(), 0)
            }
        };
        self.out.push(PNode {
            id: id.to_string(),
            title: n.description.clone().unwrap_or(title),
            block,
            needs,
            cond: n.cond.clone(),
            with,
            scope_inputs: scope.clone(),
            def: n.clone(),
            expect,
            retry,
            services,
            select,
            suite,
            group: group.map(|g| g.to_string()),
            branch_of,
            decision: Decision::Run,
            outward,
            destructive,
            capabilities: caps,
            estimate_ms: est,
            timeout_ms: timeout,
            selection: None,
            selection_reason: None,
            cache_key: None,
            executor: crate::executor::Executor::Local,
            matrix: Value::Object(Map::new()),
            src: n.src.clone(),
        });
    }
}

/// Builds the plan. Nothing runs when it has errors.
pub fn build(spec: &Spec, opts: &PlanOptions) -> Result<Plan, Vec<PlanError>> {
    let Some(flow) = spec.flow(&opts.flow) else {
        return Err(vec![PlanError {
            code: "PLAN-01",
            message: tr(
                &format!("흐름 '{}' 이(가) 없습니다.", opts.flow),
                &format!("no flow named '{}'.", opts.flow),
            ),
            src: None,
        }]);
    };
    let env_name = opts
        .env
        .clone()
        .or(flow.env.clone())
        .unwrap_or_else(|| "local".into());
    let env_class = match spec.environment(&env_name) {
        Some(e) => e.class,
        None if env_name == "local" || env_name == "dev" => EnvClass::Dev,
        None => {
            return Err(vec![PlanError {
                code: "PLAN-03",
                message: tr(
                    &format!("환경 '{env_name}' 이(가) 없습니다."),
                    &format!("no environment named '{env_name}'."),
                ),
                src: None,
            }]);
        }
    };
    let mut ex = Ex {
        spec,
        out: Vec::new(),
        groups: HashMap::new(),
        errors: Vec::new(),
    };
    ex.expand(&flow.nodes, "", &Value::Object(Map::new()), &[], None, 0);
    if !ex.errors.is_empty() {
        return Err(ex.errors);
    }
    // A group (sub-flow or composite block) in needs stands for all of its members.
    let groups = ex.groups.clone();
    fn expand_need(
        n: &str,
        groups: &HashMap<String, Vec<String>>,
        out: &mut Vec<String>,
        depth: usize,
    ) {
        match groups.get(n) {
            Some(members) if depth < 10 => {
                for m in members {
                    expand_need(m, groups, out, depth + 1);
                }
            }
            _ => out.push(n.to_string()),
        }
    }
    let mut nodes = ex.out;
    for n in nodes.iter_mut() {
        let mut needs = Vec::new();
        for x in &n.needs {
            expand_need(x, &groups, &mut needs, 0);
        }
        needs.dedup();
        n.needs = needs;
    }
    let mut warnings = Vec::new();
    // Executor: the node's, then the environment's, then local. Only blocks that run shell commands (cmd, test.*) follow it.
    let env_exec = spec.environment(&env_name).and_then(|e| e.executor.clone());
    for n in nodes.iter_mut() {
        let raw = n.def.executor.clone().or_else(|| env_exec.clone());
        let Some(raw) = raw else { continue };
        let raw = render_static(&raw, &n.matrix, &n.scope_inputs);
        let ex = match crate::executor::Executor::parse(&raw) {
            Ok(ex) => ex,
            Err(msg) => {
                n.decision = Decision::Rejected("SPEC-03", format!("executor: {msg}"));
                continue;
            }
        };
        if ex.is_docker() {
            if n.block == "cmd" || n.block.starts_with("test.") {
                if !n.capabilities.iter().any(|c| c == "docker") {
                    n.capabilities.push("docker".into());
                }
            } else if n.def.executor.is_some() {
                warnings.push(tr(
                    &format!(
                        "{}: {} 블록은 엔진 안에서 돌아 executor 를 따르지 않습니다.",
                        n.id, n.block
                    ),
                    &format!(
                        "{}: {} runs inside the engine and ignores executor.",
                        n.id, n.block
                    ),
                ));
                continue;
            } else {
                continue;
            }
        }
        n.executor = ex;
    }
    // --only: the chosen nodes and what they depend on.
    if !opts.only.is_empty() {
        let mut keep: BTreeSet<String> = BTreeSet::new();
        let mut stack: Vec<String> = Vec::new();
        for o in &opts.only {
            let hits: Vec<String> = nodes
                .iter()
                .filter(|n| {
                    &n.id == o
                        || n.id.starts_with(&format!("{o}/"))
                        || n.suite.as_deref() == Some(o.as_str())
                })
                .map(|n| n.id.clone())
                .collect();
            if hits.is_empty() {
                return Err(vec![PlanError {
                    code: "PLAN-02",
                    message: tr(
                        &format!("노드 '{o}' 이(가) 없습니다."),
                        &format!("no node named '{o}'."),
                    ),
                    src: None,
                }]);
            }
            stack.extend(hits);
        }
        while let Some(id) = stack.pop() {
            if keep.insert(id.clone()) {
                if let Some(n) = nodes.iter().find(|n| n.id == id) {
                    stack.extend(n.needs.iter().cloned());
                }
            }
        }
        for n in nodes.iter_mut() {
            let keep_branch = n
                .branch_of
                .as_ref()
                .map(|b| keep.contains(b))
                .unwrap_or(false);
            if !keep.contains(&n.id) && !keep_branch {
                n.decision = Decision::Skip(
                    "only",
                    tr("--only 로 고르지 않음", "not selected by --only"),
                );
            }
        }
    }
    // Production guard.
    for n in nodes.iter_mut() {
        if n.decision != Decision::Run {
            continue;
        }
        if let Some(b) = blocks::get(&n.block) {
            let m = b.meta();
            if !m.env_classes.is_empty() && !m.env_classes.contains(&env_class) {
                n.decision = Decision::Rejected(
                    "GUARD-03",
                    tr(
                        &format!(
                            "{} 블록은 {} 환경에서 쓸 수 없습니다.",
                            n.block,
                            env_class.as_str()
                        ),
                        &format!(
                            "{} cannot run in a {} environment.",
                            n.block,
                            env_class.as_str()
                        ),
                    ),
                );
            } else if env_class == EnvClass::Prod && m.destructive && !opts.prod_allowed {
                n.decision = Decision::Rejected(
                    "GUARD-01",
                    tr(
                        &format!("운영 환경 '{env_name}' 에서 {} 를 거부했습니다.", n.block),
                        &format!(
                            "{} was refused on production environment '{env_name}'.",
                            n.block
                        ),
                    ),
                );
            }
        }
    }
    let gates: Vec<String> = nodes
        .iter()
        .filter(|n| n.block == "gate.manual" && n.decision == Decision::Run)
        .map(|n| n.id.clone())
        .collect();
    let outward: Vec<String> = nodes
        .iter()
        .filter(|n| n.outward && n.decision == Decision::Run)
        .map(|n| format!("{} ({})", n.id, n.block))
        .collect();
    let mut services: Vec<String> = Vec::new();
    for n in nodes.iter().filter(|n| n.decision == Decision::Run) {
        for s in &n.services {
            let mut stack = vec![s.clone()];
            while let Some(x) = stack.pop() {
                if !services.contains(&x) {
                    if let Some(sd) = spec.service(&x) {
                        stack.extend(sd.needs.iter().cloned());
                    }
                    services.push(x);
                }
            }
        }
    }
    for s in &services {
        if let Some(sd) = spec.service(s) {
            if !crate::services::known(&sd.uses) {
                warnings.push(tr(
                    &format!(
                        "서비스 '{s}' 의 종류 '{}' 은(는) 아직 지원하지 않습니다.",
                        sd.uses
                    ),
                    &format!(
                        "service '{s}' uses '{}', which is not supported yet.",
                        sd.uses
                    ),
                ));
            }
        }
    }
    let root = &spec.root;
    let git = GitInfo {
        sha: crate::git::head_sha(root).unwrap_or_default(),
        branch: crate::git::branch(root).unwrap_or_default(),
        clean: crate::git::is_clean(root),
    };
    let mut hasher = String::new();
    hasher.push_str(&format!(
        "{}\n{}\n{}\n",
        opts.flow,
        env_name,
        spec.files_hash()
    ));
    for n in &nodes {
        hasher.push_str(&format!(
            "{}|{}|{}|{}|{}|{}\n",
            n.id,
            n.block,
            n.with,
            n.needs.join(","),
            n.decision.as_str(),
            n.executor.as_str()
        ));
    }
    let hash = util::sha256_hex(hasher.as_bytes())[..24].to_string();
    let trust_status = trust::status(spec);
    let mut plan = Plan {
        flow: opts.flow.clone(),
        env: env_name,
        env_class,
        nodes,
        services,
        outward,
        trust: trust_status,
        hash,
        files_hash: spec.files_hash(),
        warnings,
        fail_fast: flow.fail_fast,
        rollback_scope: flow.rollback_scope.unwrap_or(RollbackScope::Node),
        on_check_failure: flow.rollback_on_check_failure,
        rollback_timeout_ms: flow.rollback_timeout_ms.unwrap_or(10 * 60_000),
        concurrency: flow.concurrency,
        timeout_ms: flow.timeout_ms,
        gates,
        git,
        affected: None,
    };
    if let Some(mode) = &opts.affected {
        crate::affected::apply(spec, &mut plan, mode);
    }
    if !opts.no_cache {
        crate::cache::annotate(spec, &mut plan);
    }
    Ok(plan)
}

impl Plan {
    pub fn node(&self, id: &str) -> Option<&PNode> {
        self.nodes.iter().find(|n| n.id == id)
    }

    pub fn to_json(&self) -> Value {
        json!({
            "schemaVersion": 1,
            "flow": self.flow,
            "env": self.env,
            "envClass": self.env_class.as_str(),
            "hash": self.hash,
            "filesHash": self.files_hash,
            "git": {"sha": self.git.sha, "branch": self.git.branch, "clean": self.git.clean},
            "trust": {"trusted": self.trust.trusted, "changed": self.trust.changed, "approvedAt": self.trust.approved_at},
            "failFast": self.fail_fast,
            "rollback": {"scope": match self.rollback_scope { RollbackScope::Node => "node", RollbackScope::Flow => "flow" }, "onCheckFailure": self.on_check_failure, "timeoutMs": self.rollback_timeout_ms},
            "outward": self.outward,
            "gates": self.gates,
            "services": self.services,
            "warnings": self.warnings,
            "affected": self.affected,
            "estimateMs": self.estimate_ms(),
            "nodes": self.nodes.iter().map(|n| json!({
                "id": n.id,
                "title": n.title,
                "block": n.block,
                "needs": n.needs,
                "if": n.cond,
                "suite": n.suite,
                "group": n.group,
                "branchOf": n.branch_of,
                "decision": n.decision.as_str(),
                "reason": match &n.decision { Decision::Run => Value::Null, Decision::Skip(c, m) | Decision::Rejected(c, m) => json!({"code": c, "message": m}) },
                "outward": n.outward,
                "destructive": n.destructive,
                "services": n.services,
                "estimateMs": n.estimate_ms,
                "optional": n.def.optional,
                "selection": n.selection,
                "selectionReason": n.selection_reason,
                "cacheKey": n.cache_key,
                "executor": n.executor.as_str(),
                "matrix": n.matrix,
                // So the trust prompt can show the commands that will run, as written in the flow file (secrets cannot appear in run).
                "run": n.with.get("run").and_then(|r| r.as_str()),
                "undo": n.with.get("undo").map(|u| if u.is_string() { u.clone() } else { u["run"].clone() }),
                "src": n.src.show(),
            })).collect::<Vec<_>>(),
        })
    }

    /// Estimated duration along the critical path (the longest needs chain).
    pub fn estimate_ms(&self) -> u64 {
        let mut memo: HashMap<&str, u64> = HashMap::new();
        fn longest<'a>(
            id: &'a str,
            plan: &'a Plan,
            memo: &mut HashMap<&'a str, u64>,
            depth: usize,
        ) -> u64 {
            if let Some(v) = memo.get(id) {
                return *v;
            }
            let Some(n) = plan.node(id) else { return 0 };
            let own = if n.decision == Decision::Run && n.branch_of.is_none() {
                n.estimate_ms
            } else {
                0
            };
            let before = if depth > 64 {
                0
            } else {
                n.needs
                    .iter()
                    .map(|x| longest(x, plan, memo, depth + 1))
                    .max()
                    .unwrap_or(0)
            };
            memo.insert(&n.id, own + before);
            own + before
        }
        self.nodes
            .iter()
            .map(|n| longest(&n.id, self, &mut memo, 0))
            .max()
            .unwrap_or(0)
    }
}
