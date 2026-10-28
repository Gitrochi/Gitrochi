use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum Platform {
    Windows,
    MacOS,
    Linux,
}

impl Platform {
    pub(super) fn current() -> Self {
        if cfg!(windows) {
            Self::Windows
        } else if cfg!(target_os = "macos") {
            Self::MacOS
        } else {
            Self::Linux
        }
    }
}

#[derive(Clone, Copy)]
pub(super) struct Definition {
    pub(super) id: &'static str,
    pub(super) name: &'static str,
    pub(super) supports_folders: bool,
}

pub(super) struct LocatedEditor {
    pub(super) definition: Definition,
    pub(super) application: Option<PathBuf>,
}

fn definition(id: &'static str, name: &'static str, supports_folders: bool) -> Definition {
    Definition {
        id,
        name,
        supports_folders,
    }
}

pub(super) fn definitions(platform: Platform) -> Vec<Definition> {
    let mut result = vec![
        definition("system", "System default", true),
        definition("vscode", "Visual Studio Code", true),
        definition("vscode-insiders", "Visual Studio Code Insiders", true),
    ];
    if platform == Platform::MacOS {
        result.push(definition("xcode", "Xcode", true));
    }
    result.push(definition("intellij", "IntelliJ IDEA", true));
    if platform == Platform::Windows {
        result.push(definition("notepad", "Notepad", false));
        result.push(definition("notepad-plus-plus", "Notepad++", false));
    }
    if platform == Platform::MacOS {
        result.push(definition("textedit", "TextEdit", false));
    }
    result.push(definition("sublime", "Sublime Text", true));
    result
}

pub(super) struct Search {
    pub(super) platform: Platform,
    pub(super) home: Option<PathBuf>,
    pub(super) local: Option<PathBuf>,
    pub(super) programs: Vec<PathBuf>,
    pub(super) system: Option<PathBuf>,
    pub(super) path: Vec<PathBuf>,
}

impl Search {
    fn current() -> Self {
        let env_path = |key| {
            std::env::var_os(key)
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
        };
        Self {
            platform: Platform::current(),
            home: dirs::home_dir(),
            local: env_path("LOCALAPPDATA"),
            programs: ["ProgramFiles", "ProgramFiles(x86)"]
                .into_iter()
                .filter_map(env_path)
                .collect(),
            system: env_path("SystemRoot"),
            path: std::env::var_os("PATH")
                .map(|path| {
                    std::env::split_paths(&path)
                        .filter(|path| path.is_absolute())
                        .collect()
                })
                .unwrap_or_default(),
        }
    }
}

fn in_paths(search: &Search, names: &[&str]) -> Vec<PathBuf> {
    search
        .path
        .iter()
        .flat_map(|directory| names.iter().map(move |name| directory.join(name)))
        .collect()
}

fn versioned_executables(root: &Path, name: &str) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut queue = vec![(root.to_path_buf(), 0)];
    let mut visited = 0;
    while let Some((folder, depth)) = queue.pop() {
        if depth > 6 || visited >= 2_000 {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(folder) else {
            continue;
        };
        for entry in entries.flatten() {
            visited += 1;
            if visited > 2_000 {
                break;
            }
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if kind.is_file()
                && entry
                    .file_name()
                    .to_string_lossy()
                    .eq_ignore_ascii_case(name)
            {
                result.push(entry.path());
            }
            if kind.is_dir() {
                queue.push((entry.path(), depth + 1));
            }
        }
    }
    result.sort();
    result.reverse();
    result
}

fn candidates(search: &Search, id: &str) -> Vec<PathBuf> {
    let mut result = Vec::new();
    match search.platform {
        Platform::MacOS => {
            let names: &[&str] = match id {
                "vscode" => &["Visual Studio Code.app"],
                "vscode-insiders" => &["Visual Studio Code - Insiders.app"],
                "xcode" => &["Xcode.app"],
                "intellij" => &[
                    "IntelliJ IDEA.app",
                    "IntelliJ IDEA CE.app",
                    "IntelliJ IDEA Community Edition.app",
                ],
                "textedit" => &["TextEdit.app"],
                "sublime" => &["Sublime Text.app"],
                _ => &[],
            };
            for directory in [
                Some(PathBuf::from("/Applications")),
                Some(PathBuf::from("/System/Applications")),
                search.home.as_ref().map(|home| home.join("Applications")),
            ]
            .into_iter()
            .flatten()
            {
                result.extend(names.iter().map(|name| directory.join(name)));
            }
        }
        Platform::Windows => {
            let installation = match id {
                "vscode" => Some(("Microsoft VS Code", "Code.exe")),
                "vscode-insiders" => Some(("Microsoft VS Code Insiders", "Code - Insiders.exe")),
                "notepad-plus-plus" => Some(("Notepad++", "notepad++.exe")),
                "sublime" => Some(("Sublime Text", "sublime_text.exe")),
                _ => None,
            };
            if let Some((directory, executable)) = installation {
                if let Some(local) = &search.local {
                    result.push(local.join("Programs").join(directory).join(executable));
                }
                result.extend(
                    search
                        .programs
                        .iter()
                        .map(|programs| programs.join(directory).join(executable)),
                );
                if id == "sublime" {
                    result.extend(
                        search
                            .programs
                            .iter()
                            .map(|programs| programs.join("Sublime Text 3/sublime_text.exe")),
                    );
                }
                result.extend(in_paths(search, &[executable]));
                for path in &search.path {
                    if path
                        .file_name()
                        .is_some_and(|part| part.to_string_lossy().eq_ignore_ascii_case("bin"))
                    {
                        if let Some(parent) = path.parent() {
                            result.push(parent.join(executable));
                        }
                    }
                }
            }
            if id == "notepad" {
                if let Some(system) = &search.system {
                    result.push(system.join("System32/notepad.exe"));
                }
                result.extend(in_paths(search, &["notepad.exe"]));
            }
            if id == "intellij" {
                for programs in &search.programs {
                    result.extend(versioned_executables(
                        &programs.join("JetBrains"),
                        "idea64.exe",
                    ));
                }
                if let Some(local) = &search.local {
                    result.extend(versioned_executables(
                        &local.join("JetBrains/Toolbox/apps"),
                        "idea64.exe",
                    ));
                }
                result.extend(in_paths(search, &["idea64.exe"]));
            }
        }
        Platform::Linux => {
            let names: &[&str] = match id {
                "vscode" => &["code"],
                "vscode-insiders" => &["code-insiders"],
                "intellij" => &["idea"],
                "sublime" => &["subl"],
                _ => &[],
            };
            result.extend(in_paths(search, names));
        }
    }
    result
}

pub(super) fn discover_with(search: &Search) -> Vec<LocatedEditor> {
    definitions(search.platform)
        .into_iter()
        .map(|definition| {
            let application = candidates(search, definition.id).into_iter().find(|path| {
                if search.platform == Platform::MacOS {
                    path.is_dir()
                } else {
                    path.is_file()
                }
            });
            LocatedEditor {
                definition,
                application,
            }
        })
        .collect()
}

pub(super) fn discover() -> Vec<LocatedEditor> {
    discover_with(&Search::current())
}
