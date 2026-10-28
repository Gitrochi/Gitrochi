//! Opens validated working-copy paths in a fixed set of installed applications.

mod discovery;

use discovery::{discover, Platform};
use serde::Serialize;
use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use tauri_plugin_opener::OpenerExt;

const INVALID_REPOSITORY: &str = "The repository folder is unavailable.";
const INVALID_FILE: &str = "Choose a file inside this repository.";
const MISSING_FILE: &str = "The local file is missing or is not a regular file.";
const NOT_A_FILE: &str = MISSING_FILE;
const UNKNOWN_EDITOR: &str = "Choose a supported application.";
const NOT_INSTALLED: &str = "This application is not installed.";
const NO_FOLDERS: &str = "This application cannot open a repository folder.";
const UNSAFE_DEFAULT: &str = "Open executable files in a text editor instead.";
const UNSAFE_APPLICATION: &str = "Applications inside the repository cannot be launched.";
const OPEN_FAILED: &str = "Couldn't open this path in the selected application.";

/// Application names are proper nouns; installation paths never cross the bridge.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExternalEditor {
    id: &'static str,
    name: &'static str,
    available: bool,
    supports_folders: bool,
}

#[derive(Debug, PartialEq)]
enum LaunchPlan {
    System(PathBuf),
    Process {
        program: PathBuf,
        args: Vec<OsString>,
    },
}

struct Target {
    root: PathBuf,
    path: PathBuf,
    folder: bool,
}

fn valid_relative_file(file: &str) -> bool {
    !file.is_empty()
        && file.len() <= 32_768
        && !file.chars().any(char::is_control)
        && !file.contains(['\\', ':'])
        && file
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
        && Path::new(file)
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
}

fn validate_target(repo: &str, file: Option<&str>) -> Result<Target, String> {
    let source = PathBuf::from(crate::process::native(repo));
    if repo.chars().any(char::is_control) || !source.is_absolute() {
        return Err(INVALID_REPOSITORY.into());
    }
    let root = source.canonicalize().map_err(|_| INVALID_REPOSITORY)?;
    if !root.is_dir() {
        return Err(INVALID_REPOSITORY.into());
    }
    let Some(file) = file else {
        return Ok(Target {
            path: root.clone(),
            root,
            folder: true,
        });
    };
    if !valid_relative_file(file) {
        return Err(INVALID_FILE.into());
    }
    let path = root.join(file).canonicalize().map_err(|_| MISSING_FILE)?;
    if !path.starts_with(&root) {
        return Err(INVALID_FILE.into());
    }
    if !path.is_file() {
        return Err(NOT_A_FILE.into());
    }
    Ok(Target {
        root,
        path,
        folder: false,
    })
}

fn native_argument(path: &Path) -> OsString {
    #[cfg(windows)]
    {
        let text = path.to_string_lossy();
        if let Some(unc) = text.strip_prefix("\\\\?\\UNC\\") {
            return OsString::from(format!("\\\\{unc}"));
        }
        if let Some(local) = text.strip_prefix("\\\\?\\") {
            return OsString::from(local);
        }
    }
    path.as_os_str().to_os_string()
}

fn runnable_default(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if path
            .metadata()
            .is_ok_and(|metadata| metadata.permissions().mode() & 0o111 != 0)
        {
            return true;
        }
    }
    let extension = path
        .extension()
        .and_then(|part| part.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    matches!(
        extension.as_str(),
        "app"
            | "applescript"
            | "application"
            | "appref-ms"
            | "bash"
            | "bat"
            | "cmd"
            | "com"
            | "command"
            | "cpl"
            | "csh"
            | "desktop"
            | "dmg"
            | "exe"
            | "fish"
            | "hta"
            | "htm"
            | "html"
            | "jar"
            | "jnlp"
            | "js"
            | "jse"
            | "ksh"
            | "lnk"
            | "mht"
            | "mhtml"
            | "msi"
            | "msp"
            | "pif"
            | "pkg"
            | "pl"
            | "ps1"
            | "psm1"
            | "py"
            | "pyw"
            | "rb"
            | "reg"
            | "run"
            | "scpt"
            | "scptd"
            | "scr"
            | "sh"
            | "svg"
            | "svgz"
            | "url"
            | "vbe"
            | "vbs"
            | "webloc"
            | "workflow"
            | "wsf"
            | "wsh"
            | "xht"
            | "xhtml"
            | "zsh"
    )
}

fn launch_plan(
    platform: Platform,
    editor: &discovery::LocatedEditor,
    target: &Target,
) -> Result<LaunchPlan, String> {
    if target.folder && !editor.definition.supports_folders {
        return Err(NO_FOLDERS.into());
    }
    if editor.definition.id == "system" {
        if !target.folder && runnable_default(&target.path) {
            return Err(UNSAFE_DEFAULT.into());
        }
        if target.folder && platform == Platform::MacOS {
            return Ok(LaunchPlan::Process {
                program: PathBuf::from("/usr/bin/open"),
                args: vec![
                    OsString::from("-a"),
                    OsString::from("/System/Library/CoreServices/Finder.app"),
                    native_argument(&target.path),
                ],
            });
        }
        return Ok(LaunchPlan::System(target.path.clone()));
    }
    let application = editor.application.as_ref().ok_or(NOT_INSTALLED)?;
    let canonical = application.canonicalize().map_err(|_| NOT_INSTALLED)?;
    if canonical.starts_with(&target.root) {
        return Err(UNSAFE_APPLICATION.into());
    }
    let argument = native_argument(&target.path);
    if platform == Platform::MacOS {
        Ok(LaunchPlan::Process {
            program: PathBuf::from("/usr/bin/open"),
            args: vec![OsString::from("-a"), canonical.into_os_string(), argument],
        })
    } else {
        Ok(LaunchPlan::Process {
            program: canonical,
            args: vec![argument],
        })
    }
}

fn execute_plan(plan: LaunchPlan, app: &tauri::AppHandle) -> Result<(), String> {
    match plan {
        LaunchPlan::System(path) => app
            .opener()
            .open_path(native_argument(&path).to_string_lossy(), None::<&str>)
            .map_err(|_| OPEN_FAILED.into()),
        LaunchPlan::Process { program, args } => {
            let mut command = Command::new(&program);
            command
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            if let Some(parent) = program.parent() {
                command.current_dir(parent);
            }
            crate::process::hide_window(&mut command);
            let mut child = command.spawn().map_err(|_| OPEN_FAILED)?;
            std::thread::spawn(move || {
                let _ = child.wait();
            });
            Ok(())
        }
    }
}

/// Installation checks only inspect known files; they never execute an editor CLI.
#[tauri::command]
pub async fn external_editors() -> Result<Vec<ExternalEditor>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        discover()
            .into_iter()
            .map(|editor| ExternalEditor {
                id: editor.definition.id,
                name: editor.definition.name,
                available: editor.definition.id == "system" || editor.application.is_some(),
                supports_folders: editor.definition.supports_folders,
            })
            .collect()
    })
    .await
    .map_err(|_| OPEN_FAILED.into())
}

/// File arguments refer to existing working-copy files, independently of the displayed Git revision.
#[tauri::command]
pub async fn open_external_editor(
    app: tauri::AppHandle,
    repo: String,
    editor_id: String,
    file: Option<String>,
) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let target = validate_target(&repo, file.as_deref())?;
        let editor = discover()
            .into_iter()
            .find(|editor| editor.definition.id == editor_id)
            .ok_or(UNKNOWN_EDITOR)?;
        let plan = launch_plan(Platform::current(), &editor, &target)?;
        execute_plan(plan, &app)
    })
    .await
    .map_err(|_| OPEN_FAILED.to_string())?
}

#[cfg(test)]
mod tests;
