// File previews in a browser tab: a Ctrl-clicked word in a terminal is resolved to a file, and the page for it is
// served to the tab's child webview through the gitrochi-preview protocol. Only what the app registered is served,
// each under a random token, so a web page in another tab cannot read files through it.
// macOS: Core/TerminalWord.swift and BrowserSession.openFile

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::http::{header, Response, StatusCode};

pub const SCHEME: &str = "gitrochi-preview";

enum Source {
    Html(String),
    File(PathBuf),
}

struct Entry {
    mime: String,
    source: Source,
}

#[derive(Default)]
pub struct Previews(Mutex<HashMap<String, Entry>>);

/// The address the webview loads a registered page from
fn address(token: &str) -> String {
    // WebView2 serves custom protocols over http://<scheme>.localhost
    if cfg!(windows) {
        format!("http://{SCHEME}.localhost/{token}")
    } else {
        format!("{SCHEME}://localhost/{token}")
    }
}

/// Whether a URL is one of these pages (a browser tab keeps its file while it shows one)
pub fn is_preview(url: &tauri::Url) -> bool {
    url.scheme() == SCHEME || url.host_str() == Some(&format!("{SCHEME}.localhost"))
}

/// Registers a built page (html) or a file the webview shows itself (path, mime) and returns its address
#[tauri::command]
pub fn preview_register(
    state: tauri::State<'_, Previews>,
    html: Option<String>,
    path: Option<String>,
    mime: Option<String>,
) -> Result<String, String> {
    let entry = match (html, path) {
        (Some(html), _) => Entry {
            mime: "text/html; charset=utf-8".into(),
            source: Source::Html(html),
        },
        (None, Some(path)) => Entry {
            mime: mime.unwrap_or_else(|| "application/octet-stream".into()),
            source: Source::File(PathBuf::from(path)),
        },
        _ => return Err("nothing to preview".into()),
    };
    let token = uuid_like();
    let mut map = state.0.lock().unwrap();
    // a long session previews many files; keep the store small
    if map.len() > 200 {
        map.clear();
    }
    map.insert(token.clone(), entry);
    Ok(address(&token))
}

/// An unguessable token: std's per-process random hash keys over a clock reading and a counter
fn uuid_like() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    (0..2)
        .map(|_| {
            let mut h = RandomState::new().build_hasher();
            h.write_u128(nanos);
            h.write_u64(n);
            format!("{:016x}", h.finish())
        })
        .collect()
}

/// Serves a registered page to the webview
pub fn serve(app: &tauri::AppHandle, request: &tauri::http::Request<Vec<u8>>) -> Response<Vec<u8>> {
    use tauri::Manager;
    let token = request.uri().path().trim_start_matches('/').to_string();
    let state = app.state::<Previews>();
    let found = {
        let map = state.0.lock().unwrap();
        map.get(&token).map(|e| {
            (
                e.mime.clone(),
                match &e.source {
                    Source::Html(html) => Ok(html.clone().into_bytes()),
                    Source::File(path) => Err(path.clone()),
                },
            )
        })
    };
    let Some((mime, body)) = found else {
        return Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Vec::new())
            .unwrap();
    };
    let bytes = match body {
        Ok(bytes) => bytes,
        Err(path) => match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(_) => {
                return Response::builder()
                    .status(StatusCode::NOT_FOUND)
                    .body(Vec::new())
                    .unwrap()
            }
        },
    };
    let mut response = Response::builder()
        .header(header::CONTENT_TYPE, mime.as_str())
        .header(header::CACHE_CONTROL, "no-store");
    // built pages and the user's own HTML files run no script here
    if mime.starts_with("text/html") {
        response = response.header(
            header::CONTENT_SECURITY_POLICY,
            "default-src 'none'; style-src 'unsafe-inline'; img-src data:",
        );
    }
    response.body(bytes).unwrap()
}

// MARK: Resolving a clicked word

/// The file a word names, from the shell's folder: `~` expanded, a `:line[:column]` suffix dropped, git's `a/` and
/// `b/` diff prefixes tried; then the shallowest file below the folder whose path ends with it (`ls sub` prints bare
/// names). Folders are not files.
#[tauri::command]
pub async fn preview_resolve(word: String, directory: String) -> Option<String> {
    resolve(&word, Path::new(&directory)).map(|p| p.to_string_lossy().into_owned())
}

fn strip_location(word: &str) -> &str {
    let bytes = word.as_bytes();
    let mut end = word.len();
    for _ in 0..2 {
        let digits = bytes[..end]
            .iter()
            .rev()
            .take_while(|b| b.is_ascii_digit())
            .count();
        if digits == 0 || end <= digits || bytes[end - digits - 1] != b':' {
            break;
        }
        end -= digits + 1;
    }
    &word[..end]
}

fn home() -> Option<PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from)
}

pub fn resolve(word: &str, directory: &Path) -> Option<PathBuf> {
    let mut candidates = vec![word.to_string()];
    let bare = strip_location(word);
    if bare != word {
        candidates.push(bare.to_string());
    }
    if let Some(rest) = bare.strip_prefix("a/").or_else(|| bare.strip_prefix("b/")) {
        candidates.push(rest.to_string());
    }
    for candidate in &candidates {
        let expanded = match candidate
            .strip_prefix("~/")
            .or_else(|| candidate.strip_prefix("~\\"))
        {
            Some(rest) => home()?.join(rest),
            None => PathBuf::from(candidate),
        };
        let path = if expanded.is_absolute() {
            expanded
        } else {
            directory.join(expanded)
        };
        if path.is_file() {
            return Some(path);
        }
    }
    search(bare, directory, 6, 50_000)
}

const SKIPPED: &[&str] = &[
    "node_modules",
    "build",
    "dist",
    "target",
    "Pods",
    "DerivedData",
    "vendor",
    "__pycache__",
];

fn search(name: &str, root: &Path, max_depth: usize, max_entries: usize) -> Option<PathBuf> {
    if name.is_empty()
        || name.starts_with('~')
        || Path::new(name).is_absolute()
        || !(name.contains('.') || name.contains('/') || name.contains('\\'))
    {
        return None;
    }
    let wanted: Vec<String> = name
        .split(['/', '\\'])
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();
    // breadth first, so the shallowest match wins
    let mut queue = std::collections::VecDeque::from([(root.to_path_buf(), 0usize)]);
    let mut seen = 0;
    while let Some((dir, depth)) = queue.pop_front() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            seen += 1;
            if seen > max_entries {
                return None;
            }
            let file_name = entry.file_name().to_string_lossy().into_owned();
            if file_name.starts_with('.') {
                continue;
            }
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let path = entry.path();
            if kind.is_dir() {
                if depth + 1 < max_depth && !SKIPPED.contains(&file_name.as_str()) {
                    queue.push_back((path, depth + 1));
                }
            } else if kind.is_file() && ends_with(&path, &wanted) {
                return Some(path);
            }
        }
    }
    None
}

fn ends_with(path: &Path, wanted: &[String]) -> bool {
    let parts: Vec<String> = path
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    parts.len() >= wanted.len() && parts[parts.len() - wanted.len()..] == *wanted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_files_from_the_shell_folder_and_below() {
        let root = std::env::temp_dir().join(format!("gitrochi-preview-{}", uuid_like()));
        std::fs::create_dir_all(root.join("samples/deep")).unwrap();
        std::fs::create_dir_all(root.join("node_modules/x")).unwrap();
        std::fs::write(root.join("samples/schema.sql"), "select 1;").unwrap();
        std::fs::write(root.join("samples/deep/schema.sql"), "").unwrap();
        std::fs::write(root.join("node_modules/x/only.sql"), "").unwrap();
        let sql = root.join("samples/schema.sql");
        assert_eq!(resolve("samples/schema.sql", &root), Some(sql.clone()));
        assert_eq!(resolve("samples/schema.sql:12:4", &root), Some(sql.clone()));
        assert_eq!(resolve("b/samples/schema.sql", &root), Some(sql.clone()));
        assert_eq!(resolve("schema.sql", &root), Some(sql.clone()));
        assert_eq!(resolve("only.sql", &root), None);
        assert_eq!(resolve("samples", &root), None);
        assert_eq!(resolve("missing.sql", &root), None);
        let _ = std::fs::remove_dir_all(root);
    }
}
