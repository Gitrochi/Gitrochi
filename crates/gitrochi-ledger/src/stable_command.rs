//! The stable copy of the ledger command that hooks and MCP entries name: it keeps one path
//! when the app moves or updates, and the apps keep its content equal to their bundled
//! command. It is created only when a person sets up or repairs a connection; otherwise the
//! apps refresh a copy that already exists and never make one.

use crate::{Error, Result};
use serde::Serialize;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

const NAME: &str = if cfg!(windows) {
    "gitrochi-ledger.exe"
} else {
    "gitrochi-ledger"
};

/// macOS `~/Library/Application Support/Gitrochi/bin/gitrochi-ledger`, Windows
/// `%APPDATA%\Gitrochi\bin\gitrochi-ledger.exe`.
pub fn default_path() -> PathBuf {
    crate::db::data_dir().join("bin").join(NAME)
}

/// What a refresh found and did.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StableCommand {
    pub path: PathBuf,
    pub exists: bool,
    /// Same bytes as the bundled command.
    pub current: bool,
    pub refreshed: bool,
    /// The bundled command is older than the database, so an existing copy was kept.
    pub held: bool,
}

fn io_error(error: io::Error) -> Error {
    Error::new("IO", error.to_string())
}

/// Replaces `stable` with `bundled` when their bytes differ. Without `create`, a missing copy
/// stays missing. With `hold`, an existing copy is never replaced: an app older than the
/// database must not put back a command that cannot write to it.
pub fn refresh(bundled: &Path, stable: &Path, create: bool, hold: bool) -> Result<StableCommand> {
    let exists = stable.is_file();
    let mut result = StableCommand {
        path: stable.to_path_buf(),
        exists,
        current: false,
        refreshed: false,
        held: false,
    };
    if !exists && !create {
        return Ok(result);
    }
    if !bundled.is_file() {
        // A build without the command (a development run) leaves an existing copy alone.
        if !create {
            return Ok(result);
        }
        return Err(Error::not_found(format!(
            "The bundled ledger command is missing: {}",
            bundled.display()
        )));
    }
    if exists && same_content(bundled, stable).map_err(io_error)? {
        result.current = true;
        return Ok(result);
    }
    if exists && hold {
        result.held = true;
        return Ok(result);
    }
    copy(bundled, stable).map_err(io_error)?;
    result.exists = true;
    result.current = true;
    result.refreshed = true;
    Ok(result)
}

fn fill(file: &mut File, buffer: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while filled < buffer.len() {
        match file.read(&mut buffer[filled..])? {
            0 => break,
            n => filled += n,
        }
    }
    Ok(filled)
}

fn same_content(a: &Path, b: &Path) -> io::Result<bool> {
    if fs::metadata(a)?.len() != fs::metadata(b)?.len() {
        return Ok(false);
    }
    let (mut a, mut b) = (File::open(a)?, File::open(b)?);
    let (mut x, mut y) = (vec![0; 1 << 16], vec![0; 1 << 16]);
    loop {
        let (n, m) = (fill(&mut a, &mut x)?, fill(&mut b, &mut y)?);
        if n != m || x[..n] != y[..m] {
            return Ok(false);
        }
        if n == 0 {
            return Ok(true);
        }
    }
}

fn stamp() -> String {
    format!(
        "{}-{}-{}",
        crate::util::now_ms(),
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    )
}

/// A new file renamed over the old one: running hooks keep the old file, and macOS never sees
/// a signed executable change in place.
fn copy(bundled: &Path, stable: &Path) -> io::Result<()> {
    let parent = stable
        .parent()
        .ok_or_else(|| io::Error::other("The stable command needs a folder"))?;
    let mut folder = fs::DirBuilder::new();
    folder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        folder.mode(0o700);
    }
    folder.create(parent)?;
    remove_leftovers(parent);
    let temporary = parent.join(format!(".{NAME}.{}.tmp", stamp()));
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o755);
        }
        let mut file = options.open(&temporary)?;
        io::copy(&mut File::open(bundled)?, &mut file)?;
        file.sync_all()?;
        drop(file);
        replace(&temporary, stable)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn replace(from: &Path, to: &Path) -> io::Result<()> {
    match fs::rename(from, to) {
        Ok(()) => Ok(()),
        // Windows cannot replace a running executable but can rename it out of the way; the
        // old file goes once nothing runs it.
        Err(error) if cfg!(windows) && to.exists() => {
            let aside = to.with_file_name(format!("{NAME}.{}.old", stamp()));
            fs::rename(to, &aside).map_err(|_| error)?;
            if let Err(error) = fs::rename(from, to) {
                let _ = fs::rename(&aside, to);
                return Err(error);
            }
            let _ = fs::remove_file(&aside);
            Ok(())
        }
        Err(error) => Err(error),
    }
}

/// Copies set aside by earlier refreshes, and temporary files of interrupted ones.
fn remove_leftovers(folder: &Path) {
    let Ok(entries) = fs::read_dir(folder) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let old = name.starts_with(&format!("{NAME}.")) && name.ends_with(".old");
        let temporary = name.starts_with(&format!(".{NAME}.")) && name.ends_with(".tmp");
        let stale = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| m.elapsed().ok())
            .is_some_and(|age| age.as_secs() > 600);
        if old || (temporary && stale) {
            let _ = fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "gitrochi-ledger-stable-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn never_creates_without_a_request_and_replaces_only_different_bytes() {
        let dir = folder("refresh");
        let bundled = dir.join("bundled");
        fs::write(&bundled, b"new build").unwrap();
        let stable = dir.join("bin").join(NAME);
        let untouched = refresh(&bundled, &stable, false, false).unwrap();
        assert!(!untouched.exists && !untouched.refreshed);
        assert!(!stable.parent().unwrap().exists());

        let created = refresh(&bundled, &stable, true, false).unwrap();
        assert!(created.exists && created.current && created.refreshed);
        assert_eq!(fs::read(&stable).unwrap(), b"new build");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&stable).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o755);
        }
        let again = refresh(&bundled, &stable, false, false).unwrap();
        assert!(again.current && !again.refreshed);

        fs::write(&stable, b"old build").unwrap();
        let held = refresh(&bundled, &stable, false, true).unwrap();
        assert!(held.held && !held.current && !held.refreshed);
        assert_eq!(fs::read(&stable).unwrap(), b"old build");
        let replaced = refresh(&bundled, &stable, false, false).unwrap();
        assert!(replaced.refreshed);
        assert_eq!(fs::read(&stable).unwrap(), b"new build");
        let leftovers: Vec<_> = fs::read_dir(stable.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(leftovers, vec![std::ffi::OsString::from(NAME)]);

        fs::remove_file(&bundled).unwrap();
        let without = refresh(&bundled, &stable, false, false).unwrap();
        assert!(without.exists && !without.current && !without.refreshed);
        assert!(refresh(&bundled, &stable, true, false).is_err());
        let _ = fs::remove_dir_all(&dir);
    }
}
