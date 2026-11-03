//! User-level Chrome host registration. Only explicitly requested installation changes these files.
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub const HOST_NAME: &str = "com.gitrochi.ledger";
const DESCRIPTION: &str = "Gitrochi Ledger browser bridge";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HostConfig {
    pub allowed_origin: String,
    pub db_path: PathBuf,
    pub host_path: PathBuf,
    pub extension_id: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConfigFile {
    version: u8,
    application: String,
    config: HostConfig,
}

struct Layout {
    manifest: PathBuf,
    config: PathBuf,
}
trait Registry {
    fn read(&self) -> Result<Option<PathBuf>>;
    fn set(&self, path: &Path) -> Result<()>;
    fn remove(&self) -> Result<()>;
}
struct NativeRegistry;

#[cfg(windows)]
mod windows_registry {
    use super::*;
    use std::ffi::c_void;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use std::ptr::{null, null_mut};
    type Key = *mut c_void;
    const CURRENT_USER: Key = 0x80000001u32 as i32 as isize as Key;
    const SUBKEY: &str = r"Software\Google\Chrome\NativeMessagingHosts\com.gitrochi.ledger";
    #[link(name = "advapi32")]
    extern "system" {
        fn RegGetValueW(
            key: Key,
            subkey: *const u16,
            value: *const u16,
            flags: u32,
            kind: *mut u32,
            data: *mut c_void,
            size: *mut u32,
        ) -> i32;
        fn RegCreateKeyExW(
            key: Key,
            subkey: *const u16,
            reserved: u32,
            class: *mut u16,
            options: u32,
            access: u32,
            security: *const c_void,
            result: *mut Key,
            disposition: *mut u32,
        ) -> i32;
        fn RegSetValueExW(
            key: Key,
            value: *const u16,
            reserved: u32,
            kind: u32,
            data: *const u8,
            size: u32,
        ) -> i32;
        fn RegCloseKey(key: Key) -> i32;
        fn RegDeleteKeyW(key: Key, subkey: *const u16) -> i32;
    }
    fn key() -> Vec<u16> {
        SUBKEY.encode_utf16().chain(Some(0)).collect()
    }
    fn check(code: i32) -> Result<()> {
        if code == 0 {
            Ok(())
        } else {
            Err(Error::invalid(format!(
                "Chrome host registry operation failed ({code})"
            )))
        }
    }
    pub fn read() -> Result<Option<PathBuf>> {
        let name = key();
        let mut size = 0;
        // The buffers are bounded and Win32 owns no pointer after each call returns.
        let code = unsafe {
            RegGetValueW(
                CURRENT_USER,
                name.as_ptr(),
                null(),
                2,
                null_mut(),
                null_mut(),
                &mut size,
            )
        };
        if code == 2 || code == 3 {
            return Ok(None);
        }
        check(code)?;
        if size == 0 || size > 65_536 || size % 2 != 0 {
            return Err(Error::invalid("The Chrome host registry path is invalid"));
        }
        let mut data = vec![0u16; size as usize / 2];
        check(unsafe {
            RegGetValueW(
                CURRENT_USER,
                name.as_ptr(),
                null(),
                2,
                null_mut(),
                data.as_mut_ptr().cast(),
                &mut size,
            )
        })?;
        let length = data.iter().position(|v| *v == 0).unwrap_or(data.len());
        Ok(Some(PathBuf::from(std::ffi::OsString::from_wide(
            &data[..length],
        ))))
    }
    pub fn set(path: &Path) -> Result<()> {
        let name = key();
        let mut handle = null_mut();
        let data = path
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect::<Vec<_>>();
        check(unsafe {
            RegCreateKeyExW(
                CURRENT_USER,
                name.as_ptr(),
                0,
                null_mut(),
                0,
                2,
                null(),
                &mut handle,
                null_mut(),
            )
        })?;
        let result = unsafe {
            RegSetValueExW(
                handle,
                null(),
                0,
                1,
                data.as_ptr().cast(),
                (data.len() * 2) as u32,
            )
        };
        unsafe {
            RegCloseKey(handle);
        }
        check(result)
    }
    pub fn remove() -> Result<()> {
        // Refuse recursive deletion: unexpected child keys are not ours to remove.
        check(unsafe { RegDeleteKeyW(CURRENT_USER, key().as_ptr()) })
    }
}

impl Registry for NativeRegistry {
    fn read(&self) -> Result<Option<PathBuf>> {
        #[cfg(windows)]
        {
            windows_registry::read()
        }
        #[cfg(not(windows))]
        {
            Ok(None)
        }
    }
    fn set(&self, path: &Path) -> Result<()> {
        #[cfg(windows)]
        {
            windows_registry::set(path)?;
        }
        #[cfg(not(windows))]
        let _ = path;
        Ok(())
    }
    fn remove(&self) -> Result<()> {
        #[cfg(windows)]
        {
            windows_registry::remove()?;
        }
        Ok(())
    }
}

fn io_error(error: std::io::Error) -> Error {
    Error::invalid(format!("Could not update the browser host: {error}"))
}
fn extension(id: &str) -> Result<String> {
    if id.len() != 32 || !id.bytes().all(|b| (b'a'..=b'p').contains(&b)) {
        return Err(Error::invalid(
            "A Chrome extension ID is 32 letters from a to p",
        ));
    }
    Ok(format!("chrome-extension://{id}/"))
}
fn host_path(path: &Path, exists: bool) -> Result<()> {
    let name = if cfg!(windows) {
        "gitrochi-ledger-browser.exe"
    } else {
        "gitrochi-ledger-browser"
    };
    if !path.is_absolute()
        || path.file_name().and_then(|n| n.to_str()) != Some(name)
        || (exists && !path.is_file())
    {
        return Err(Error::invalid(format!(
            "Choose the absolute path to the bundled {name} executable"
        )));
    }
    #[cfg(unix)]
    if exists {
        use std::os::unix::fs::PermissionsExt;
        if std::fs::metadata(path)
            .map_err(io_error)?
            .permissions()
            .mode()
            & 0o111
            == 0
        {
            return Err(Error::invalid("The browser host must be executable"));
        }
    }
    Ok(())
}
fn layout() -> Result<Layout> {
    #[cfg(target_os = "macos")]
    let dir = PathBuf::from(
        std::env::var_os("HOME")
            .ok_or_else(|| Error::invalid("The user home folder is unavailable"))?,
    )
    .join("Library/Application Support/Google/Chrome/NativeMessagingHosts");
    #[cfg(windows)]
    let dir = PathBuf::from(
        std::env::var_os("APPDATA")
            .ok_or_else(|| Error::invalid("The user application folder is unavailable"))?,
    )
    .join("Gitrochi/browser");
    #[cfg(not(any(target_os = "macos", windows)))]
    return Err(Error::not_allowed(
        "The browser host installer supports macOS and Windows",
    ));
    #[cfg(any(target_os = "macos", windows))]
    Ok(Layout {
        manifest: dir.join(format!("{HOST_NAME}.json")),
        config: dir.join(format!("{HOST_NAME}.config.json")),
    })
}
fn manifest(config: &HostConfig) -> Value {
    json!({"name":HOST_NAME,"description":DESCRIPTION,"path":config.host_path,"type":"stdio","allowed_origins":[config.allowed_origin]})
}

fn read_config(paths: &Layout) -> Result<HostConfig> {
    let data = std::fs::read(&paths.config).map_err(|_| {
        Error::not_allowed("Install the browser host in Gitrochi before connecting")
    })?;
    if data.len() > 16_384 {
        return Err(Error::not_allowed(
            "The browser host configuration is invalid",
        ));
    }
    let file: ConfigFile = serde_json::from_slice(&data)
        .map_err(|_| Error::not_allowed("The browser host configuration is invalid"))?;
    if file.version != 1
        || file.application != "gitrochi-ledger-browser"
        || file.config.allowed_origin != extension(&file.config.extension_id)?
        || !file.config.db_path.is_absolute()
    {
        return Err(Error::not_allowed(
            "The browser host configuration is invalid",
        ));
    }
    host_path(&file.config.host_path, false)?;
    Ok(file.config)
}
fn owned_manifest(paths: &Layout, config: &HostConfig) -> Result<bool> {
    let data = std::fs::read(&paths.manifest).map_err(io_error)?;
    Ok(data.len() <= 16_384
        && serde_json::from_slice::<Value>(&data).ok().as_ref() == Some(&manifest(config)))
}
fn installed(paths: &Layout, registry: &impl Registry, use_registry: bool) -> Result<HostConfig> {
    let config = read_config(paths)?;
    if !paths.manifest.exists()
        || !owned_manifest(paths, &config)?
        || (use_registry && registry.read()?.as_deref() != Some(paths.manifest.as_path()))
    {
        return Err(Error::not_allowed(
            "The browser host registration was removed or changed",
        ));
    }
    host_path(&config.host_path, true)?;
    Ok(config)
}
fn status_at(paths: &Layout, registry: &impl Registry, use_registry: bool) -> Value {
    match installed(paths, registry, use_registry) {
        Ok(config) => {
            json!({"installed":true,"extensionId":config.extension_id,"hostName":HOST_NAME,"manifestPath":paths.manifest,"hostPath":config.host_path,"hostExists":true})
        }
        // A registration whose host moved with the app (or was deleted) needs a repair, not a new setup.
        Err(_) => match read_config(paths) {
            Ok(config) if paths.manifest.exists() && !config.host_path.is_file() => {
                json!({"installed":false,"extensionId":config.extension_id,"hostName":HOST_NAME,"manifestPath":paths.manifest,"hostPath":config.host_path,"hostExists":false})
            }
            _ => json!({"installed":false,"hostName":HOST_NAME,"manifestPath":paths.manifest}),
        },
    }
}
fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::invalid("The browser registration folder is invalid"))?;
    std::fs::create_dir_all(parent).map_err(io_error)?;
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    let data = serde_json::to_vec_pretty(value)?;
    {
        use std::io::Write;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(io_error)?;
        file.write_all(&data).map_err(io_error)?;
        file.sync_all().map_err(io_error)?;
    }
    // Windows rename cannot replace an existing destination.
    #[cfg(windows)]
    if path.exists() {
        std::fs::remove_file(path).map_err(io_error)?;
    }
    std::fs::rename(&temporary, path).map_err(io_error)
}
fn install_at(
    paths: &Layout,
    registry: &impl Registry,
    use_registry: bool,
    db: &Path,
    id: &str,
    host: &Path,
) -> Result<Value> {
    let allowed_origin = extension(id)?;
    host_path(host, true)?;
    if paths.config.exists() {
        read_config(paths)?;
    }
    if use_registry && registry.read()?.is_some_and(|path| path != paths.manifest) {
        return Err(Error::conflict(
            "Another application owns the Chrome host registration",
        ));
    }
    if paths.manifest.exists() {
        let previous = read_config(paths)?;
        if !owned_manifest(paths, &previous)? {
            return Err(Error::conflict(
                "Another application owns the browser host manifest",
            ));
        }
    }
    let db_path = if db.is_absolute() {
        db.to_path_buf()
    } else {
        std::env::current_dir().map_err(io_error)?.join(db)
    };
    let config = HostConfig {
        allowed_origin,
        db_path,
        host_path: host.to_path_buf(),
        extension_id: id.into(),
    };
    write_json(
        &paths.config,
        &ConfigFile {
            version: 1,
            application: "gitrochi-ledger-browser".into(),
            config: config.clone(),
        },
    )?;
    write_json(&paths.manifest, &manifest(&config))?;
    if use_registry {
        registry.set(&paths.manifest)?;
    }
    Ok(status_at(paths, registry, use_registry))
}
fn remove_at(paths: &Layout, registry: &impl Registry, use_registry: bool) -> Result<Value> {
    if paths.config.exists() {
        read_config(paths)?;
    }
    if paths.manifest.exists() {
        let config = read_config(paths)?;
        if !owned_manifest(paths, &config)? {
            return Err(Error::conflict(
                "Another application owns the browser host manifest",
            ));
        }
    }
    if use_registry {
        if let Some(path) = registry.read()? {
            if path != paths.manifest {
                return Err(Error::conflict(
                    "Another application owns the Chrome host registration",
                ));
            }
            registry.remove()?;
        }
    }
    for path in [&paths.manifest, &paths.config] {
        if path.exists() {
            std::fs::remove_file(path).map_err(io_error)?;
        }
    }
    Ok(status_at(paths, registry, use_registry))
}

pub fn load_config() -> Result<HostConfig> {
    installed(&layout()?, &NativeRegistry, cfg!(windows))
}
pub fn status() -> Result<Value> {
    Ok(status_at(&layout()?, &NativeRegistry, cfg!(windows)))
}
pub fn install(db: &Path, extension_id: &str, host: &Path) -> Result<Value> {
    install_at(
        &layout()?,
        &NativeRegistry,
        cfg!(windows),
        db,
        extension_id,
        host,
    )
}
pub fn remove() -> Result<Value> {
    remove_at(&layout()?, &NativeRegistry, cfg!(windows))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    struct FakeRegistry(RefCell<Option<PathBuf>>);
    impl Registry for FakeRegistry {
        fn read(&self) -> Result<Option<PathBuf>> {
            Ok(self.0.borrow().clone())
        }
        fn set(&self, path: &Path) -> Result<()> {
            *self.0.borrow_mut() = Some(path.into());
            Ok(())
        }
        fn remove(&self) -> Result<()> {
            *self.0.borrow_mut() = None;
            Ok(())
        }
    }
    #[test]
    fn registration_is_owned_revocable_and_pins_the_database() {
        let root =
            std::env::temp_dir().join(format!("ledger-browser-install-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let paths = Layout {
            manifest: root.join("host.json"),
            config: root.join("config.json"),
        };
        let host = root.join(if cfg!(windows) {
            "gitrochi-ledger-browser.exe"
        } else {
            "gitrochi-ledger-browser"
        });
        std::fs::write(&host, b"fixture").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&host, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let registry = FakeRegistry(RefCell::new(None));
        let id = "abcdefghijklmnopabcdefghijklmnop";
        assert!(install_at(
            &paths,
            &registry,
            true,
            &root.join("ledger.db"),
            "invalid",
            &host
        )
        .is_err());
        let status =
            install_at(&paths, &registry, true, &root.join("ledger.db"), id, &host).unwrap();
        assert_eq!(status["installed"], true);
        assert_eq!(
            status["manifestPath"],
            paths.manifest.to_string_lossy().as_ref()
        );
        assert_eq!(status["hostExists"], true);
        let config = installed(&paths, &registry, true).unwrap();
        assert_eq!(config.db_path, root.join("ledger.db"));
        assert_eq!(config.allowed_origin, format!("chrome-extension://{id}/"));
        // a host that moved with the app is a registration to repair, with its extension ID kept
        let moved = root.join("moved");
        std::fs::rename(&host, &moved).unwrap();
        let status = status_at(&paths, &registry, true);
        assert_eq!(status["installed"], false);
        assert_eq!(status["hostExists"], false);
        assert_eq!(status["extensionId"], id);
        std::fs::rename(&moved, &host).unwrap();
        *registry.0.borrow_mut() = Some(root.join("foreign.json"));
        assert!(remove_at(&paths, &registry, true).is_err());
        assert!(paths.manifest.exists());
        *registry.0.borrow_mut() = Some(paths.manifest.clone());
        assert_eq!(
            remove_at(&paths, &registry, true).unwrap()["installed"],
            false
        );
        assert!(installed(&paths, &registry, true).is_err());
        std::fs::write(&paths.manifest, b"{\"name\":\"foreign\"}").unwrap();
        assert!(install_at(&paths, &registry, false, &root.join("ledger.db"), id, &host).is_err());
        assert!(remove_at(&paths, &registry, false).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
