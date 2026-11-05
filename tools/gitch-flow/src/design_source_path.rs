//! Portable path checks and pinned parent handles for repository source edits.

use super::{check_text, Result, Snapshot, LIMIT};
use std::fs::File;
use std::io::Read;
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd};
use std::path::Path;
#[cfg(not(unix))]
use std::path::PathBuf;

fn safe_path(path: &str) -> bool {
    if path.is_empty()
        || path.len() > 4096
        || path.contains(['\\', ':', '<', '>', '"', '|', '?', '*'])
        || path.chars().any(char::is_control)
    {
        return false;
    }
    path.split('/').all(|part| {
        let stem = part.split('.').next().unwrap_or("").to_ascii_uppercase();
        !part.is_empty()
            && part != "."
            && part != ".."
            && !part.eq_ignore_ascii_case(".git")
            && !part.ends_with(['.', ' '])
            && !["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "CLOCK$"].contains(&stem.as_str())
            && !(stem.chars().count() == 4
                && (stem.starts_with("COM") || stem.starts_with("LPT"))
                && stem.chars().nth(3).is_some_and(|suffix| {
                    suffix.is_ascii_digit() || ['¹', '²', '³'].contains(&suffix)
                }))
    })
}

fn contained(root: &Path, path: &Path) -> bool {
    path.canonicalize()
        .ok()
        .and_then(|path| path.strip_prefix(root).ok().map(Path::to_owned))
        .is_some_and(|relative| {
            relative.components().all(|component| {
                !component
                    .as_os_str()
                    .to_string_lossy()
                    .eq_ignore_ascii_case(".git")
            })
        })
}

pub(super) struct Target {
    #[cfg(not(unix))]
    path: PathBuf,
    #[cfg(not(unix))]
    parent: PathBuf,
    #[cfg(unix)]
    leaf: String,
    #[cfg(unix)]
    directory: File,
    #[cfg(windows)]
    _ancestors: Vec<File>,
}

fn is_link(metadata: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        // Junctions and other reparse points can escape just as symbolic links do.
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

#[cfg(windows)]
fn pin_directory(path: &Path) -> Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    // Excluding FILE_SHARE_DELETE prevents an opened parent from being renamed during the save.
    let file = std::fs::OpenOptions::new()
        .read(true)
        .share_mode(1 | 2)
        .custom_flags(0x02000000 | 0x00200000)
        .open(path)
        .map_err(|_| {
            (
                "SOURCE_PARENT",
                "The source folder changed or cannot be opened safely.",
            )
        })?;
    let metadata = file.metadata().map_err(|_| {
        (
            "SOURCE_PARENT",
            "The source folder changed or cannot be opened safely.",
        )
    })?;
    if is_link(&metadata) || !metadata.is_dir() {
        return Err((
            "SOURCE_SYMLINK",
            "Related source files and their folders must not be symbolic links.",
        ));
    }
    Ok(file)
}

impl Target {
    pub(super) fn new(root: &Path, relative: &str) -> Result<Self> {
        Self::with_parents(root, relative, false)
    }

    pub(super) fn with_parents(root: &Path, relative: &str, create_parents: bool) -> Result<Self> {
        if !safe_path(relative) {
            return Err((
                "SOURCE_PATH",
                "Choose a repository-relative file path without traversal or Git metadata.",
            ));
        }
        let root = root
            .canonicalize()
            .map_err(|_| ("SOURCE_REPOSITORY", "The repository folder is unavailable."))?;
        let parts = relative.split('/').collect::<Vec<_>>();
        let leaf = parts.last().unwrap().to_string();
        let mut parent = root.clone();
        #[cfg(windows)]
        let mut ancestors = vec![pin_directory(&root)?];
        #[cfg(unix)]
        let mut directory = {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&root)
                .map_err(|_| {
                    (
                        "SOURCE_PARENT",
                        "The source folder must be an existing directory inside this repository.",
                    )
                })?
        };
        for part in &parts[..parts.len() - 1] {
            parent.push(part);
            let mut metadata = std::fs::symlink_metadata(&parent);
            if create_parents
                && metadata
                    .as_ref()
                    .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
            {
                #[cfg(unix)]
                let created = {
                    use std::os::unix::fs::MetadataExt;
                    let current = parent.parent().unwrap();
                    let same = directory
                        .metadata()
                        .ok()
                        .zip(std::fs::symlink_metadata(current).ok())
                        .is_some_and(|(a, b)| {
                            !is_link(&b) && a.dev() == b.dev() && a.ino() == b.ino()
                        });
                    if !same || !contained(&root, current) {
                        return Err(("SOURCE_CONFLICT", "The related source folder changed. Reopen the file before saving; your draft was not written."));
                    }
                    let name = std::ffi::CString::new(*part).unwrap();
                    if unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o777) } == 0 {
                        Ok(())
                    } else {
                        Err(std::io::Error::last_os_error())
                    }
                };
                #[cfg(not(unix))]
                let created = std::fs::create_dir(&parent);
                if created.is_err_and(|error| error.kind() != std::io::ErrorKind::AlreadyExists) {
                    return Err((
                        "SOURCE_PARENT",
                        "The required source folders could not be created safely.",
                    ));
                }
                metadata = std::fs::symlink_metadata(&parent);
            }
            let meta = metadata.map_err(|error| if error.kind() == std::io::ErrorKind::NotFound {
                ("SOURCE_PARENT_NOT_FOUND", "The source folder does not exist. Choose New file to create the required folders.")
            } else {
                (
                    "SOURCE_PARENT",
                    "The source folder must be an existing directory inside this repository.",
                )
            })?;
            if is_link(&meta) {
                return Err((
                    "SOURCE_SYMLINK",
                    "Related source files and their folders must not be symbolic links.",
                ));
            }
            if !meta.is_dir() || !contained(&root, &parent) {
                return Err((
                    "SOURCE_PATH",
                    "The related file must remain inside this repository.",
                ));
            }
            #[cfg(windows)]
            ancestors.push(pin_directory(&parent)?);
            #[cfg(unix)]
            {
                directory = open_at(&directory, part, libc::O_RDONLY | libc::O_DIRECTORY, 0)
                    .map_err(|_| {
                        (
                            "SOURCE_PARENT",
                            "The source folder changed or cannot be opened safely.",
                        )
                    })?;
            }
        }
        let path = parent.join(&leaf);
        if let Ok(meta) = std::fs::symlink_metadata(&path) {
            if is_link(&meta) {
                return Err((
                    "SOURCE_SYMLINK",
                    "Related source files and their folders must not be symbolic links.",
                ));
            }
            if !contained(&root, &path) {
                return Err((
                    "SOURCE_PATH",
                    "The related file must remain inside this repository.",
                ));
            }
        }
        Ok(Self {
            #[cfg(not(unix))]
            path,
            #[cfg(not(unix))]
            parent,
            #[cfg(unix)]
            leaf,
            #[cfg(unix)]
            directory,
            #[cfg(windows)]
            _ancestors: ancestors,
        })
    }

    pub(super) fn same_parent(&self, other: &Self) -> bool {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            self.directory
                .metadata()
                .ok()
                .zip(other.directory.metadata().ok())
                .is_some_and(|(a, b)| a.dev() == b.dev() && a.ino() == b.ino())
        }
        #[cfg(not(unix))]
        {
            self.parent
                .canonicalize()
                .ok()
                .zip(other.parent.canonicalize().ok())
                .is_some_and(|(a, b)| a == b)
        }
    }

    pub(super) fn read(&self) -> Result<Option<Snapshot>> {
        #[cfg(unix)]
        let opened = open_at(
            &self.directory,
            &self.leaf,
            libc::O_RDONLY | libc::O_NONBLOCK,
            0,
        );
        #[cfg(windows)]
        let opened = {
            use std::os::windows::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(0x00200000)
                .open(&self.path)
        };
        #[cfg(not(any(unix, windows)))]
        let opened = File::open(&self.path);
        let file = match opened {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => {
                return Err((
                    "SOURCE_READ",
                    "The related file cannot be opened safely. Reopen it before editing.",
                ))
            }
        };
        let metadata = file
            .metadata()
            .map_err(|_| ("SOURCE_READ", "The related file cannot be read."))?;
        if is_link(&metadata) {
            return Err((
                "SOURCE_SYMLINK",
                "Related source files and their folders must not be symbolic links.",
            ));
        }
        if !metadata.is_file() {
            return Err(("SOURCE_TYPE", "Choose a regular UTF-8 source file."));
        }
        if metadata.len() > LIMIT {
            return Err((
                "SOURCE_SIZE",
                "Related source files must be no larger than 2 MiB.",
            ));
        }
        let mut bytes = Vec::new();
        let access = super::metadata::Access::capture(&file);
        file.take(LIMIT + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| ("SOURCE_READ", "The related file cannot be read."))?;
        if bytes.len() as u64 > LIMIT {
            return Err((
                "SOURCE_SIZE",
                "Related source files must be no larger than 2 MiB.",
            ));
        }
        check_text(&bytes)?;
        Ok(Some(Snapshot {
            bytes,
            permissions: metadata.permissions(),
            access,
        }))
    }

    pub(super) fn temporary(&self) -> Result<(File, String)> {
        let name = format!(".gitrochi-source-{}.tmp", crate::util::random_hex(8));
        #[cfg(unix)]
        let created = open_at(
            &self.directory,
            &name,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            0o666,
        );
        #[cfg(windows)]
        let created = {
            use std::os::windows::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .write(true)
                .access_mode(0xC0040000)
                .create_new(true)
                .open(self.parent.join(&name))
        };
        #[cfg(not(any(unix, windows)))]
        let created = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(self.parent.join(&name));
        created.map(|file| (file, name)).map_err(|_| {
            (
                "SOURCE_WRITE",
                "A temporary source file could not be created.",
            )
        })
    }

    pub(super) fn remove_temporary(&self, name: &str) {
        #[cfg(unix)]
        if let Ok(name) = std::ffi::CString::new(name) {
            unsafe {
                libc::unlinkat(self.directory.as_raw_fd(), name.as_ptr(), 0);
            }
        }
        #[cfg(not(unix))]
        let _ = std::fs::remove_file(self.parent.join(name));
    }

    pub(super) fn commit(&self, name: &str, create: bool) -> Result<Option<String>> {
        #[cfg(unix)]
        let result = {
            let name = std::ffi::CString::new(name).unwrap();
            let leaf = std::ffi::CString::new(self.leaf.as_str()).unwrap();
            let fd = self.directory.as_raw_fd();
            let result = unsafe {
                if create {
                    libc::linkat(fd, name.as_ptr(), fd, leaf.as_ptr(), 0)
                } else {
                    libc::renameat(fd, name.as_ptr(), fd, leaf.as_ptr())
                }
            };
            if result == 0 {
                Ok(None)
            } else {
                Err(std::io::Error::last_os_error())
            }
        };
        #[cfg(windows)]
        let result = if create {
            std::fs::hard_link(self.parent.join(name), &self.path).map(|_| None)
        } else {
            super::metadata::replace(&self.path, &self.parent.join(name))
        };
        #[cfg(not(any(unix, windows)))]
        let result = if create {
            std::fs::hard_link(self.parent.join(name), &self.path)
        } else {
            std::fs::rename(self.parent.join(name), &self.path)
        };
        #[cfg(not(any(unix, windows)))]
        let result = result.map(|_| None);
        result.map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                (
                    "SOURCE_CONFLICT",
                    "The related file already exists. Reopen it before saving.",
                )
            } else {
                (
                    "SOURCE_WRITE",
                    "The related file could not be saved. Its existing contents were kept.",
                )
            }
        })
    }
}

#[cfg(unix)]
fn open_at(directory: &File, name: &str, flags: i32, mode: libc::mode_t) -> std::io::Result<File> {
    let name = std::ffi::CString::new(name)?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            mode as libc::c_uint,
        )
    };
    if fd < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::Target;

    #[test]
    fn replaced_parent_is_distinct_even_when_file_bytes_are_identical() {
        let root = std::env::temp_dir().join(format!(
            "gitch-source-parent-{}",
            crate::util::random_hex(8)
        ));
        std::fs::create_dir_all(root.join("scripts")).unwrap();
        std::fs::write(root.join("scripts/check.sh"), "original").unwrap();
        let before = Target::new(&root, "scripts/check.sh").unwrap();
        std::fs::rename(root.join("scripts"), root.join("old-scripts")).unwrap();
        std::fs::create_dir(root.join("scripts")).unwrap();
        std::fs::write(root.join("scripts/check.sh"), "original").unwrap();
        let current = Target::new(&root, "scripts/check.sh").unwrap();
        assert!(!before.same_parent(&current));
        drop((before, current));
        std::fs::remove_dir_all(root).unwrap();
    }
}
