use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};

/// 기존 TSV 분석 레코드의 확장 필드를 보존하며 공개 JSON 계약으로 바꾼다.
pub fn to_json(text: &str, meta: &HashMap<String, String>) -> Result<Value, String> {
    let get = |key: &str| meta.get(key).map(String::as_str).unwrap_or("");
    let (mut nodes, mut edges, mut notes, mut diagnostics) = (vec![], vec![], vec![], vec![]);
    let mut stats = Map::new();
    let mut cycles: BTreeMap<&str, Vec<Value>> = BTreeMap::new();
    let mut heuristic = 0;
    for line in text.lines() {
        let f: Vec<_> = line.split('\t').collect();
        match f.first().copied().unwrap_or("") {
            "0" if f.len() >= 3 => match f[1] {
                "note" => notes.push(json!(f[2])),
                "diagnostic" => diagnostics.push(
                    serde_json::from_str::<Value>(f[2]).map_err(|_| "Invalid graph diagnostic")?,
                ),
                key => {
                    stats.insert(
                        key.into(),
                        serde_json::from_str::<Value>(f[2])
                            .map_err(|_| "Invalid graph statistics")?,
                    );
                }
            },
            "1" if f.len() >= 5 => {
                let mut node = json!({"id":f[1],"kind":f[2],"label":f[3],"group":f[4]});
                attributes(&mut node, f.get(5).copied().unwrap_or(""))?;
                nodes.push(node);
            }
            "2" if f.len() >= 6 => {
                let weight = f[4]
                    .parse::<i64>()
                    .map(Value::from)
                    .unwrap_or_else(|_| json!(f[4].parse::<f64>().unwrap_or(0.0)));
                let mut edge = json!({"source":f[1],"target":f[2],"kind":f[3],"weight":weight});
                if f[5] == "h" {
                    edge["heuristic"] = json!(true);
                    heuristic += 1;
                }
                attributes(&mut edge, f.get(6).copied().unwrap_or(""))?;
                edges.push(edge);
            }
            "3" if f.len() >= 4 => {
                let mut cycle = json!({"nodes":f[3].split('\u{1c}').collect::<Vec<_>>()});
                if let Some(before) = f.get(4).filter(|s| !s.is_empty()) {
                    cycle["before"] = json!(before.split('\u{1c}').collect::<Vec<_>>());
                }
                if f[2] == "h" {
                    cycle["heuristic"] = json!(true);
                }
                cycles.entry(f[1]).or_default().push(cycle);
            }
            _ => {}
        }
    }
    stats.entry("nodes").or_insert(json!(nodes.len()));
    stats.entry("edges").or_insert(json!(edges.len()));
    stats.entry("heuristicEdges").or_insert(json!(heuristic));
    let mut out = json!({"tool":"gitch graph","schemaVersion":1,"version":get("ver"),"relation":get("rel"),"directed":get("rel")!="changes",
        "repo":get("repo"),"repoPath":get("repoPath"),"branch":get("branch"),"scope":get("scope"),
        "lang":if get("langs").is_empty(){Value::Null}else{json!(get("langs").split(',').collect::<Vec<_>>())},
        "commit":if get("commit").is_empty(){Value::Null}else{json!(get("commit"))},"generated":get("when"),"stats":stats,"notes":notes,"diagnostics":diagnostics,
        "analysisLevels":{"detection":"file-extension","declared":"static-import-or-manifest","heuristic":"name-only","indexed":"compiler-index"},"nodes":nodes,"edges":edges});
    if !get("diffbase").is_empty() {
        out["diff"] = json!({"base":get("diffbase"),"baseName":get("diffname"),"head":if get("diffhead").is_empty(){"worktree"}else{get("diffhead")}});
        out["cycles"] = json!({"new":cycles.get("new").cloned().unwrap_or_default(),"changed":cycles.get("changed").cloned().unwrap_or_default(),"gone":cycles.get("gone").cloned().unwrap_or_default(),"existing":cycles.get("existing").cloned().unwrap_or_default()});
    }
    Ok(out)
}

fn attributes(out: &mut Value, text: &str) -> Result<(), String> {
    if !text.is_empty() {
        let fields: Map<String, Value> =
            serde_json::from_str(&format!("{{{text}}}")).map_err(|_| "Invalid graph attributes")?;
        out.as_object_mut().unwrap().extend(fields);
    }
    Ok(())
}

pub struct ImpactInput<'a> {
    pub changed: &'a str,
    pub untracked: &'a str,
    pub deleted: &'a str,
    pub before: &'a str,
    pub before_modules: &'a str,
    pub now: &'a str,
    pub modules: &'a str,
    pub base: &'a str,
}

/// 인접 목록의 큐로 역방향 의존을 한 번씩만 방문한다. 삭제 파일은 기준 그래프도 포함한다.
pub fn affected(input: ImpactInput<'_>) -> String {
    let list = |s: &str| {
        s.lines()
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect::<BTreeSet<_>>()
    };
    let changed = list(input.changed);
    let untracked = list(input.untracked);
    let deleted = list(input.deleted);
    let mut kinds = HashMap::new();
    let mut ecosystems = HashMap::new();
    let mut reverse: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut before = HashMap::new();
    let mut before_modules = HashMap::new();
    let mut current = HashSet::new();
    let mut paths = BTreeSet::new();
    let mut old_edges = vec![];
    for (source, text) in [
        (0, input.before),
        (1, input.before_modules),
        (2, input.now),
        (3, input.modules),
    ] {
        for line in text.lines() {
            let f: Vec<_> = line.split('\t').collect();
            match f.first().copied().unwrap_or("") {
                "1" if f.len() >= 5 => {
                    kinds.insert(f[1], f[2]);
                    ecosystems.insert(f[1], f[4]);
                    match source {
                        0 => {
                            before.insert(f[1], line);
                        }
                        1 => {
                            before_modules.insert(f[1], line);
                        }
                        _ => {
                            current.insert(f[1]);
                        }
                    }
                }
                "2" if f.len() >= 3 => {
                    reverse.entry(f[2]).or_default().push(f[1]);
                    if source < 2 {
                        old_edges.push((if source == 0 { "files" } else { "modules" }, line));
                    }
                }
                "4" if f.len() >= 3 => {
                    paths.insert((f[1], if f[2] == "." { "" } else { f[2] }));
                }
                _ => {}
            }
        }
    }
    fn closure(
        seeds: impl Iterator<Item = String>,
        reverse: &HashMap<&str, Vec<&str>>,
        kinds: Option<&HashMap<&str, &str>>,
    ) -> BTreeSet<String> {
        let mut seen = BTreeSet::new();
        let mut queue = VecDeque::new();
        for seed in seeds {
            if seen.insert(seed.clone()) {
                queue.push_back(seed);
            }
        }
        while let Some(t) = queue.pop_front() {
            if let Some(sources) = reverse.get(t.as_str()) {
                for s in sources {
                    if kinds.is_some_and(|k| k.get(s) != Some(&"module")) {
                        continue;
                    }
                    if seen.insert((*s).into()) {
                        queue.push_back((*s).into());
                    }
                }
            }
        }
        seen
    }
    let all = closure(changed.iter().cloned(), &reverse, None);
    // 파일마다 전체 모듈 목록을 훑지 않고 폴더 조상을 따라 가장 가까운 소유 모듈을 찾는다.
    let mut owners: HashMap<&str, Vec<(&str, &str)>> = HashMap::new();
    for (id, path) in paths {
        owners
            .entry(path)
            .or_default()
            .push((id, ecosystems.get(id).copied().unwrap_or("")));
    }
    let mut module_seeds = BTreeSet::new();
    for file in &all {
        let mut folder = file.as_str();
        let mut owned = HashSet::new();
        loop {
            if let Some(candidates) = owners.get(folder) {
                // 같은 폴더·생태계의 모듈은 모두 소유자로 남긴다.
                for (id, eco) in candidates {
                    if !owned.contains(eco) {
                        module_seeds.insert((*id).to_owned());
                    }
                }
                for (_, eco) in candidates {
                    owned.insert(*eco);
                }
            }
            if folder.is_empty() {
                break;
            }
            folder = folder.rsplit_once('/').map_or("", |(p, _)| p);
        }
    }
    let modules = closure(module_seeds.into_iter(), &reverse, Some(&kinds));
    let files: Vec<_> = all
        .iter()
        .filter(|f| kinds.get(f.as_str()) == Some(&"file") || changed.contains(*f))
        .cloned()
        .collect();
    let unresolved: Vec<_> = changed
        .iter()
        .filter(|f| !kinds.contains_key(f.as_str()))
        .cloned()
        .collect();
    let mut output = String::new();
    for f in &files {
        output += &format!("A\t{f}\t{}\n", changed.contains(f));
        if deleted.contains(f) {
            output += &format!("D\t{f}\n");
        }
        if untracked.contains(f) {
            output += &format!("U\t{f}\n");
        }
        if let Some(record) = before.get(f.as_str()) {
            output += &format!("G\tfiles\t{record}\n");
        } else if !current.contains(f.as_str()) {
            let name = f.rsplit('/').next().unwrap_or(f);
            output+=&format!("G\tfiles\t1\t{f}\tfile\t{name}\tunknown\t\"path\":{},\"analysis\":\"unresolved\"\n",json!(f));
        }
    }
    for id in &modules {
        output += &format!("A\t{id}\tfalse\n");
        if !current.contains(id.as_str()) {
            output += &format!("D\t{id}\n");
        }
        if let Some(record) = before_modules.get(id.as_str()) {
            output += &format!("G\tmodules\t{record}\n");
        }
    }
    for (relation, record) in old_edges {
        output += &format!("E\t{relation}\t{record}\n");
    }
    output += &format!(
        "B\t{}\n0\taffected\t{}\n",
        input.base,
        json!({"base":input.base,"changedFiles":changed,"files":files,"modules":modules,"unresolvedFiles":unresolved,"includesBaseDependencies":true})
    );
    output+"0\tnote\t영향 범위는 변경 파일에서 역방향 의존을 따라갑니다. 삭제한 파일은 기준 커밋도 분석합니다. 인식하지 못한 언어·동적 참조·미추적 파일의 영향은 완전하지 않을 수 있습니다.\n"
}
