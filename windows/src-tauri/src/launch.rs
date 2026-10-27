//! CLI 인자와 URL 핸들러는 같은 큐를 쓴다. WebView 가 준비되기 전의 링크도 보관한다.
use serde::Serialize;
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State};

const INVALID: &str = "Couldn't open the app link. Use an absolute repository path and a file inside that repository.";

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Route {
    pub repo: String,
    pub file: Option<String>,
    pub line: Option<u32>,
    pub view: Option<String>,
    pub commit: Option<String>,
}

fn inside(root: &Path, target: &Path) -> bool {
    // Deleted files are valid history targets; canonicalize the closest existing ancestor.
    let mut ancestor = target.to_path_buf();
    while std::fs::symlink_metadata(&ancestor).is_err() {
        if !ancestor.pop() { return false; }
    }
    ancestor.canonicalize().map(|p| p.starts_with(root)).unwrap_or(false)
}

pub fn parse(raw: &str) -> Result<Route, String> {
    let u = url::Url::parse(raw).map_err(|_| INVALID.to_string())?;
    if u.scheme() != "gitrochi" || u.host_str() != Some("open") || !u.username().is_empty()
        || u.password().is_some() || u.port().is_some() || u.fragment().is_some() || !["", "/"].contains(&u.path()) {
        return Err(INVALID.into());
    }
    let mut fields = std::collections::HashMap::new();
    for (key, value) in u.query_pairs() {
        if !["repo", "file", "line", "view", "commit"].contains(&key.as_ref()) || value.is_empty()
            || value.chars().any(char::is_control) || fields.insert(key.into_owned(), value.into_owned()).is_some() {
            return Err(INVALID.into());
        }
    }
    let source = PathBuf::from(fields.get("repo").ok_or(INVALID)?);
    if !source.is_absolute() { return Err(INVALID.into()); }
    let root = source.canonicalize().map_err(|_| INVALID.to_string())?;
    if !root.is_dir() || !root.join(".git").exists() { return Err(INVALID.into()); }
    let file = fields.remove("file");
    if let Some(ref f) = file {
        if f.contains(['\\', ':']) || f.split('/').any(|s| s.is_empty() || s == "." || s == "..")
            || Path::new(f).components().any(|p| !matches!(p, Component::Normal(_))) || !inside(&root, &root.join(f)) {
            return Err(INVALID.into());
        }
    }
    let line = match fields.remove("line") {
        Some(n) => {
            let value = n.parse::<u32>().map_err(|_| INVALID.to_string())?;
            if file.is_none() || !n.bytes().all(|b| b.is_ascii_digit()) || value == 0 || value > 999_999_999 { return Err(INVALID.into()); }
            Some(value)
        },
        None => None,
    };
    let view = fields.remove("view");
    if let Some(ref v) = view {
        if !["graph", "files", "modules", "changes", "tree", "diff", "affected", "precise"].contains(&v.as_str()) || v == "diff" && file.is_none() { return Err(INVALID.into()); }
    }
    // Strip Windows canonicalize's extended-length prefix; the frontend uses normal native paths.
    let path = root.to_string_lossy().to_string();
    let repo = if let Some(unc) = path.strip_prefix("\\\\?\\UNC\\") { format!("\\\\{unc}") }
        else { path.strip_prefix("\\\\?\\").unwrap_or(&path).to_string() };
    let commit = fields.remove("commit");
    if let Some(ref c) = commit {
        if ![40, 64].contains(&c.len()) || !c.bytes().all(|b| b.is_ascii_hexdigit()) { return Err(INVALID.into()); }
    }
    Ok(Route { repo, file, line, view, commit })
}

/// A folder or file passed on the command line (Open with, a shortcut): open the repository that holds it.
/// (macOS: AppRoute.init(opening:))
pub fn folder_route(raw: &str) -> Option<Result<Route, String>> {
    let path = Path::new(raw);
    if !path.is_absolute() || !path.exists() { return None; }
    let start = path.canonicalize().ok()?;
    let mut root = if start.is_dir() { start } else { start.parent()?.to_path_buf() };
    // .git is a folder in a repository and a file in a linked worktree
    while !root.join(".git").exists() {
        if !root.pop() {
            let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| raw.to_string());
            return Some(Err(format!("Couldn't open {name}: it isn't inside a Git repository.")));
        }
    }
    let text = root.to_string_lossy().to_string();
    let repo = if let Some(unc) = text.strip_prefix("\\\\?\\UNC\\") { format!("\\\\{unc}") }
        else { text.strip_prefix("\\\\?\\").unwrap_or(&text).to_string() };
    Some(Ok(Route { repo, file: None, line: None, view: None, commit: None }))
}

#[derive(Default)]
pub struct Pending(pub Mutex<Vec<Result<Route, String>>>);

pub fn receive(app: &AppHandle, args: Vec<String>) {
    let state = app.state::<Pending>();
    if let Ok(mut queue) = state.0.lock() {
        for arg in args {
            if arg.starts_with("gitrochi:") { queue.push(parse(&arg)); } else if let Some(route) = folder_route(&arg) { queue.push(route); }
        }
    }
    let _ = app.emit("app-launch", ());
}

/// Subscribe to app-launch first, then drain; warm launches arriving during startup remain queued.
#[tauri::command]
pub fn take_app_launches(pending: State<'_, Pending>) -> Vec<Result<Route, String>> {
    pending.0.lock().map(|mut q| std::mem::take(&mut *q)).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn routes_validate_and_preserve_encoded_paths() {
        let dir = std::env::temp_dir().join(format!("gitrochi-route-{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let mut url = url::Url::parse("gitrochi://open").unwrap();
        url.query_pairs_mut().append_pair("repo", &dir.to_string_lossy()).append_pair("file", "src/한글 space.ts").append_pair("line", "27");
        assert_eq!(parse(url.as_str()).unwrap().line, Some(27));
        assert_eq!(parse(url.as_str()).unwrap().file.as_deref(), Some("src/한글 space.ts"));
        for suffix in ["&line=2", "&view=bad", "&unknown=1"] { assert!(parse(&format!("{url}{suffix}")).is_err()); }
        for file in ["../escape", "/tmp/no", "a/../b", "a\\b", "C:escape", "a//b"] {
            let mut bad = url::Url::parse("gitrochi://open").unwrap();
            bad.query_pairs_mut().append_pair("repo", &dir.to_string_lossy()).append_pair("file", file);
            assert!(parse(bad.as_str()).is_err(), "{file}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn folders_open_their_repository() {
        let dir = std::env::temp_dir().join(format!("gitrochi-folder-{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::create_dir_all(dir.join("src/deep")).unwrap();
        std::fs::write(dir.join("src/deep/a.txt"), "x").unwrap();
        let root = dir.canonicalize().unwrap().to_string_lossy().to_string();
        for item in [dir.clone(), dir.join("src/deep"), dir.join("src/deep/a.txt")] {
            let route = folder_route(&item.to_string_lossy()).unwrap().unwrap();
            assert_eq!(route.repo.trim_start_matches("\\\\?\\"), root.trim_start_matches("\\\\?\\"));
            assert!(route.file.is_none());
        }
        assert!(folder_route("relative/path").is_none());
        assert!(folder_route(&dir.join("missing").to_string_lossy()).is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
