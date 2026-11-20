//! Where a running host listens and the token it expects, kept in a file only the user can read. The socket or pipe
//! name is random for each host, so another user cannot occupy it in advance, and a client without the file's token
//! is turned away.

use interprocess::local_socket::prelude::*;
use interprocess::local_socket::{ListenerOptions, Name, Stream};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

/// The file in the app's state folder that names the running host
pub const ENDPOINT_FILE: &str = "terminal-host.json";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Endpoint {
    pub version: u32,
    pub pid: u32,
    /// A socket path on macOS and Linux, a pipe name on Windows
    pub name: String,
    pub token: String,
}

impl Endpoint {
    /// The host named in `state_dir`, if any (it may have ended since)
    pub fn read(state_dir: &Path) -> io::Result<Endpoint> {
        let text = fs::read(state_dir.join(ENDPOINT_FILE))?;
        serde_json::from_slice(&text).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }

    pub(crate) fn connect(&self) -> io::Result<Stream> {
        Stream::connect(socket_name(&self.name)?)
    }

    /// Writes the file whole (temporary file, then rename), readable by the user only
    pub(crate) fn write(&self, state_dir: &Path) -> io::Result<()> {
        fs::create_dir_all(state_dir)?;
        let temp = state_dir.join(format!("{ENDPOINT_FILE}.{}", self.pid));
        {
            let mut options = fs::OpenOptions::new();
            options.write(true).create(true).truncate(true);
            #[cfg(unix)]
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
            let mut file = options.open(&temp)?;
            file.write_all(&serde_json::to_vec(self).map_err(io::Error::other)?)?;
        }
        fs::rename(&temp, state_dir.join(ENDPOINT_FILE))
    }

    /// Removes the file unless a newer host has replaced it
    pub(crate) fn remove(&self, state_dir: &Path) {
        if Endpoint::read(state_dir).is_ok_and(|e| e.token == self.token) {
            let _ = fs::remove_file(state_dir.join(ENDPOINT_FILE));
        }
    }
}

/// A fresh listening endpoint and the folder to remove when the host ends (macOS and Linux)
pub(crate) fn listen() -> io::Result<(
    interprocess::local_socket::Listener,
    String,
    Option<PathBuf>,
)> {
    let tag = random_hex(8)?;
    #[cfg(unix)]
    let (name, folder) = {
        // a new private folder: create_dir fails rather than reuse one somebody else made
        let folder = std::env::temp_dir().join(format!("gitrochi-terminal-{tag}"));
        fs::create_dir(&folder)?;
        fs::set_permissions(&folder, std::os::unix::fs::PermissionsExt::from_mode(0o700))?;
        (
            folder.join("host.sock").to_string_lossy().into_owned(),
            Some(folder),
        )
    };
    #[cfg(windows)]
    let (name, folder) = (format!("gitrochi-terminal-{tag}"), None);
    let listener = ListenerOptions::new()
        .name(socket_name(&name)?)
        .nonblocking(interprocess::local_socket::ListenerNonblockingMode::Accept)
        .create_sync()?;
    Ok((listener, name, folder))
}

fn socket_name(name: &str) -> io::Result<Name<'_>> {
    #[cfg(unix)]
    return name.to_fs_name::<interprocess::local_socket::GenericFilePath>();
    #[cfg(windows)]
    return name.to_ns_name::<interprocess::local_socket::GenericNamespaced>();
}

pub(crate) fn random_hex(bytes: usize) -> io::Result<String> {
    let mut buf = vec![0u8; bytes];
    getrandom::fill(&mut buf).map_err(|e| io::Error::other(e.to_string()))?;
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
}
