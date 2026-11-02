use crate::error::{Error, Result};
use crate::sha1;
use crate::util::Ms;
use serde_json::Value;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

#[cfg(unix)]
fn same_file(opened: &fs::Metadata, expected: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    opened.dev() == expected.dev() && opened.ino() == expected.ino()
}

#[cfg(windows)]
fn opened_path(file: &fs::File) -> Option<PathBuf> {
    use std::os::windows::ffi::OsStringExt;
    use std::os::windows::io::AsRawHandle;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFinalPathNameByHandleW(
            handle: *mut std::ffi::c_void,
            path: *mut u16,
            count: u32,
            flags: u32,
        ) -> u32;
    }
    let mut path = vec![0u16; 32_768];
    // Resolve the opened handle, so a directory link swapped during open cannot escape a root.
    let length = unsafe {
        GetFinalPathNameByHandleW(
            file.as_raw_handle(),
            path.as_mut_ptr(),
            path.len() as u32,
            0,
        )
    } as usize;
    if length == 0 || length >= path.len() {
        return None;
    }
    Some(PathBuf::from(std::ffi::OsString::from_wide(
        &path[..length],
    )))
}

fn read_document(path: &Path, canonical: &Path, _expected: &fs::Metadata) -> Option<Vec<u8>> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // O_NOFOLLOW | O_NONBLOCK: a raced link or special file cannot redirect or stall the scan.
        #[cfg(target_os = "macos")]
        options.custom_flags(0x100 | 0x4);
        #[cfg(target_os = "linux")]
        options.custom_flags(0x20000 | 0x800);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // FILE_FLAG_OPEN_REPARSE_POINT opens a raced link itself instead of its target.
        options.custom_flags(0x00200000);
    }
    let file = options.open(path).ok()?;
    let opened = file.metadata().ok()?;
    if !opened.is_file() {
        return None;
    }
    #[cfg(unix)]
    if !same_file(&opened, _expected) {
        return None;
    }
    #[cfg(windows)]
    if opened_path(&file).as_deref() != Some(canonical) {
        return None;
    }
    #[cfg(not(any(unix, windows)))]
    if fs::canonicalize(path).ok().as_deref() != Some(canonical) {
        return None;
    }
    let mut data = Vec::new();
    (&file).take(MAX_FILE + 1).read_to_end(&mut data).ok()?;
    if data.len() as u64 > MAX_FILE {
        return None;
    }
    let after = file.metadata().ok()?;
    if opened.len() != after.len()
        || opened.modified().ok() != after.modified().ok()
        || fs::canonicalize(path).ok().as_deref() != Some(canonical)
    {
        return None;
    }
    Some(data)
}

const MAX_FILE: u64 = 1024 * 1024;
const MAX_TOTAL: u64 = 32 * MAX_FILE;
const MAX_FILES: usize = 5000;

pub(super) struct File {
    pub root: String,
    pub path: String,
    pub hash: String,
    pub modified: Ms,
    pub entries: Vec<Value>,
}

/// A deterministic bounded walk never follows links, including links added after enumeration.
pub(super) fn scan(roots: &[String]) -> Result<(Vec<File>, Vec<String>)> {
    let mut files = Vec::new();
    let mut warnings = Vec::new();
    let mut total = 0;
    let mut visited = 0;
    let mut evidence_count = 0;
    for root in roots {
        let base = Path::new(root);
        if fs::canonicalize(base).ok().as_deref() != Some(base) || !base.is_dir() {
            warnings.push(format!("Document folder is unavailable: {root}"));
            continue;
        }
        let mut pending: Vec<(PathBuf, usize)> = vec![(base.to_path_buf(), 0)];
        while let Some((dir, depth)) = pending.pop() {
            let entries = match fs::read_dir(&dir) {
                Ok(entries) => entries,
                Err(_) => {
                    warnings.push(format!("Could not read folder: {}", dir.display()));
                    continue;
                }
            };
            let remaining = MAX_FILES * 4 - visited;
            let mut paths: Vec<_> = entries
                .take(remaining + 1)
                .filter_map(|e| e.ok().map(|e| e.path()))
                .collect();
            if paths.len() > remaining {
                return Err(Error::invalid(
                    "Document scan exceeded 20,000 directory entries; choose a smaller folder",
                ));
            }
            paths.sort();
            for path in paths {
                visited += 1;
                if visited > MAX_FILES * 4 {
                    return Err(Error::invalid(
                        "Document scan exceeded 20,000 directory entries; choose a smaller folder",
                    ));
                }
                let Ok(meta) = fs::symlink_metadata(&path) else {
                    continue;
                };
                if meta.file_type().is_symlink() {
                    continue;
                }
                let name = path.file_name().unwrap_or_default().to_string_lossy();
                if name.starts_with('.') {
                    continue;
                }
                if meta.is_dir() {
                    if depth < 8
                        && !["node_modules", "target", "build", "vendor"].contains(&name.as_ref())
                    {
                        pending.push((path, depth + 1));
                    }
                    continue;
                }
                if !meta.is_file()
                    || !matches!(
                        path.extension().and_then(|e| e.to_str()),
                        Some("md" | "markdown" | "txt")
                    )
                {
                    continue;
                }
                if files.len() >= MAX_FILES {
                    return Err(Error::invalid(
                        "Document scan exceeded 5,000 files; choose a smaller folder",
                    ));
                }
                if meta.len() > MAX_FILE {
                    warnings.push(format!(
                        "Skipped a document larger than 1 MiB: {}",
                        path.display()
                    ));
                    continue;
                }
                let Ok(canonical) = fs::canonicalize(&path) else {
                    continue;
                };
                if !canonical.starts_with(base) || canonical != path {
                    continue;
                }
                let Some(data) = read_document(&path, &canonical, &meta) else {
                    warnings.push(format!("Could not read document: {}", path.display()));
                    continue;
                };
                // Rechecking closes ordinary rename/link races before caching any evidence.
                if fs::canonicalize(&path).ok().as_deref() != Some(canonical.as_path())
                    || fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink())
                {
                    continue;
                }
                total += data.len() as u64;
                if total > MAX_TOTAL {
                    return Err(Error::invalid(
                        "Document scan exceeded 32 MiB; choose a smaller folder",
                    ));
                }
                let Ok(text) = std::str::from_utf8(&data) else {
                    warnings.push(format!(
                        "Skipped a document that is not UTF-8: {}",
                        path.display()
                    ));
                    continue;
                };
                let modified = meta
                    .modified()
                    .ok()
                    .and_then(|m| m.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0);
                let entries = super::parse::entries(text);
                evidence_count += entries.len();
                if evidence_count > 50_000 {
                    return Err(Error::invalid(
                        "Document scan exceeded 50,000 evidence rows; choose a smaller folder",
                    ));
                }
                if entries.len() >= 5_000 {
                    warnings.push(format!(
                        "Showing at most 5,000 evidence rows from: {}",
                        path.display()
                    ));
                }
                files.push(File {
                    root: root.clone(),
                    path: path
                        .strip_prefix(base)
                        .unwrap()
                        .to_string_lossy()
                        .replace('\\', "/"),
                    hash: sha1::hex(&data),
                    modified,
                    entries,
                });
            }
        }
    }
    files.sort_by(|a, b| (&a.root, &a.path).cmp(&(&b.root, &b.path)));
    Ok((files, warnings))
}
