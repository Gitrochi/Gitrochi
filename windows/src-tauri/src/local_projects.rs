//! Local planning data never accepts a path from the webview or uses account credentials.

use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};

const MAX_BYTES: usize = 64 * 1024 * 1024;
const READ_ERROR: &str = "Local projects could not be read. Check app storage permissions.";
const WRITE_ERROR: &str = "Local projects could not be saved. Your previous data was kept.";
const CONFLICT: &str = "Local projects changed in another window. Refresh before saving.";

fn paths() -> PathBuf {
    crate::helper::data_dir().join("planning")
}

fn private_file(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

fn read_document(folder: &Path) -> Result<Option<String>, String> {
    match fs::read(folder.join("projects-v1.json")) {
        Ok(bytes) if bytes.len() <= MAX_BYTES => String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| READ_ERROR.to_owned()),
        Ok(_) => Err(READ_ERROR.to_owned()),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(_) => Err(READ_ERROR.to_owned()),
    }
}

fn locked_read(folder: &Path) -> Result<Option<String>, String> {
    fs::create_dir_all(folder).map_err(|_| READ_ERROR.to_owned())?;
    let lock = private_file(&folder.join("projects.lock")).map_err(|_| READ_ERROR.to_owned())?;
    lock.lock().map_err(|_| READ_ERROR.to_owned())?;
    read_document(folder)
}

fn compare_and_write(folder: &Path, expected: Option<&str>, content: &str) -> Result<(), String> {
    if content.len() > MAX_BYTES
        || !serde_json::from_str::<serde_json::Value>(content).is_ok_and(|value| value.is_object())
    {
        return Err("Local project data is invalid or too large.".to_owned());
    }
    fs::create_dir_all(folder).map_err(|_| WRITE_ERROR.to_owned())?;
    let lock = private_file(&folder.join("projects.lock")).map_err(|_| WRITE_ERROR.to_owned())?;
    lock.lock().map_err(|_| WRITE_ERROR.to_owned())?;
    if read_document(folder)?.as_deref() != expected {
        return Err(CONFLICT.to_owned());
    }
    let temporary = folder.join("projects-v1.pending");
    let result = (|| {
        let mut file = private_file(&temporary)?;
        file.set_len(0)?;
        file.write_all(content.as_bytes())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, folder.join("projects-v1.json"))
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
        return Err(WRITE_ERROR.to_owned());
    }
    Ok(())
}

#[tauri::command]
pub async fn local_projects_read() -> Result<Option<String>, String> {
    let folder = paths();
    tauri::async_runtime::spawn_blocking(move || locked_read(&folder))
        .await
        .map_err(|_| READ_ERROR.to_owned())?
}

#[tauri::command]
pub async fn local_projects_write(expected: Option<String>, content: String) -> Result<(), String> {
    let folder = paths();
    tauri::async_runtime::spawn_blocking(move || {
        compare_and_write(&folder, expected.as_deref(), &content)
    })
    .await
    .map_err(|_| WRITE_ERROR.to_owned())?
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> PathBuf {
        std::env::temp_dir().join(format!(
            "gitrochi-local-planning-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }
    #[test]
    fn compare_and_replace_preserves_previous_document_on_conflict_or_invalid_data() {
        let folder = fixture();
        assert_eq!(locked_read(&folder).unwrap(), None);
        compare_and_write(&folder, None, "{\"version\":1,\"projects\":[]}").unwrap();
        let first = locked_read(&folder).unwrap().unwrap();
        assert_eq!(
            compare_and_write(&folder, None, "{}"),
            Err(CONFLICT.to_owned())
        );
        assert!(compare_and_write(&folder, Some(&first), "not-json").is_err());
        assert_eq!(
            locked_read(&folder).unwrap().as_deref(),
            Some(first.as_str())
        );
        compare_and_write(&folder, Some(&first), "{\"version\":1,\"projects\":[{}]}").unwrap();
        assert_ne!(
            locked_read(&folder).unwrap().as_deref(),
            Some(first.as_str())
        );
        fs::remove_dir_all(folder).unwrap();
    }
    #[test]
    fn unreadable_existing_document_is_preserved() {
        let folder = fixture();
        fs::create_dir_all(&folder).unwrap();
        let corrupted = [0xff, 0xfe, 0xfd];
        fs::write(folder.join("projects-v1.json"), corrupted).unwrap();
        assert_eq!(locked_read(&folder), Err(READ_ERROR.to_owned()));
        assert_eq!(
            compare_and_write(&folder, None, "{}"),
            Err(READ_ERROR.to_owned())
        );
        assert_eq!(
            fs::read(folder.join("projects-v1.json")).unwrap(),
            corrupted
        );
        assert!(!folder.join("projects-v1.pending").exists());
        fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn concurrent_writers_cannot_both_replace_the_same_revision() {
        let folder = fixture();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let threads: Vec<_> = (0..2)
            .map(|index| {
                let folder = folder.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    compare_and_write(&folder, None, &format!("{{\"writer\":{index}}}"))
                })
            })
            .collect();
        assert_eq!(
            threads
                .into_iter()
                .filter_map(|thread| thread.join().ok())
                .filter(Result::is_ok)
                .count(),
            1
        );
        fs::remove_dir_all(folder).unwrap();
    }
}
