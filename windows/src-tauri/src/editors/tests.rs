use super::*;
use discovery::{definitions, discover_with, LocatedEditor, Search};
use std::sync::atomic::{AtomicU64, Ordering};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::temp_dir().join(format!(
            "gitrochi-editors-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(directory.join("repo/src")).unwrap();
        Self(directory)
    }

    fn file(&self, relative: &str) -> PathBuf {
        let path = self.0.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "fixture").unwrap();
        path
    }

    fn target(&self, relative: Option<&str>) -> Result<Target, String> {
        validate_target(self.0.join("repo").to_str().unwrap(), relative)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn editor(platform: Platform, id: &str, application: Option<PathBuf>) -> LocatedEditor {
    LocatedEditor {
        definition: definitions(platform)
            .into_iter()
            .find(|definition| definition.id == id)
            .unwrap(),
        application,
    }
}

#[test]
fn validates_literal_paths_and_existing_regular_working_files() {
    let fixture = Fixture::new();
    let relative = "src/a 'quote' & 한글.swift";
    let file = fixture.file(&format!("repo/{relative}"));
    assert_eq!(
        fixture.target(Some(relative)).unwrap().path,
        file.canonicalize().unwrap()
    );
    for invalid in [
        "",
        "../outside",
        "src/../a",
        "/absolute",
        "src//a",
        "src/./a",
        "C:\\outside",
        "src/name:stream",
        "src/a\nb",
    ] {
        assert!(!valid_relative_file(invalid), "{invalid}");
        assert!(fixture.target(Some(invalid)).is_err());
    }
    assert_eq!(
        fixture.target(Some("missing.swift")).err().unwrap(),
        MISSING_FILE
    );
    assert_eq!(fixture.target(Some("src")).err().unwrap(), NOT_A_FILE);
    assert!(fixture.target(None).unwrap().folder);
    assert!(validate_target("relative", None).is_err());
}

#[cfg(unix)]
#[test]
fn rejects_symlinks_outside_repository_and_accepts_contained_links() {
    let fixture = Fixture::new();
    let outside = fixture.file("repo-other/private.swift");
    let inside = fixture.file("repo/src/inside.swift");
    std::os::unix::fs::symlink(outside, fixture.0.join("repo/outside-link")).unwrap();
    std::os::unix::fs::symlink(
        inside.canonicalize().unwrap(),
        fixture.0.join("repo/inside-link"),
    )
    .unwrap();
    assert_eq!(
        fixture.target(Some("outside-link")).err().unwrap(),
        INVALID_FILE
    );
    assert_eq!(
        fixture.target(Some("inside-link")).unwrap().path,
        inside.canonicalize().unwrap()
    );
}

#[test]
fn launch_plans_keep_paths_as_single_data_arguments_without_launching_apps() {
    let fixture = Fixture::new();
    fixture.file("repo/src/$(literal) & file.swift");
    let application = fixture.file("installed/Code.exe");
    let target = fixture.target(Some("src/$(literal) & file.swift")).unwrap();
    let plan = launch_plan(
        Platform::Windows,
        &editor(Platform::Windows, "vscode", Some(application.clone())),
        &target,
    )
    .unwrap();
    assert_eq!(
        plan,
        LaunchPlan::Process {
            program: application.canonicalize().unwrap(),
            args: vec![native_argument(&target.path)]
        }
    );
    let bundle = fixture.0.join("installed/Visual Studio Code.app");
    std::fs::create_dir_all(&bundle).unwrap();
    let plan = launch_plan(
        Platform::MacOS,
        &editor(Platform::MacOS, "vscode", Some(bundle.clone())),
        &target,
    )
    .unwrap();
    assert_eq!(
        plan,
        LaunchPlan::Process {
            program: PathBuf::from("/usr/bin/open"),
            args: vec![
                "-a".into(),
                bundle.canonicalize().unwrap().into_os_string(),
                native_argument(&target.path)
            ]
        }
    );
}

#[test]
fn rejects_unavailable_editors_folder_unsupported_editors_and_repository_applications() {
    let fixture = Fixture::new();
    fixture.file("repo/src/main.swift");
    let target = fixture.target(Some("src/main.swift")).unwrap();
    assert_eq!(
        launch_plan(
            Platform::Windows,
            &editor(Platform::Windows, "vscode", None),
            &target
        )
        .err()
        .unwrap(),
        NOT_INSTALLED
    );
    assert_eq!(
        launch_plan(
            Platform::Windows,
            &editor(Platform::Windows, "notepad", None),
            &fixture.target(None).unwrap()
        )
        .err()
        .unwrap(),
        NO_FOLDERS
    );
    let application = fixture.file("repo/tools/Code.exe");
    assert_eq!(
        launch_plan(
            Platform::Windows,
            &editor(Platform::Windows, "vscode", Some(application)),
            &target
        )
        .err()
        .unwrap(),
        UNSAFE_APPLICATION
    );
}

#[test]
fn system_default_never_executes_active_files_and_mac_folders_use_finder() {
    let fixture = Fixture::new();
    let system = editor(Platform::Windows, "system", None);
    for extension in ["exe", "CMD", "ps1", "js", "lnk", "command", "html", "SVG"] {
        let name = format!("run.{extension}");
        fixture.file(&format!("repo/{name}"));
        assert_eq!(
            launch_plan(
                Platform::Windows,
                &system,
                &fixture.target(Some(&name)).unwrap()
            )
            .err()
            .unwrap(),
            UNSAFE_DEFAULT
        );
    }
    fixture.file("repo/source.ts");
    assert!(matches!(
        launch_plan(
            Platform::Windows,
            &system,
            &fixture.target(Some("source.ts")).unwrap()
        )
        .unwrap(),
        LaunchPlan::System(_)
    ));
    let folder = fixture.target(None).unwrap();
    let plan = launch_plan(
        Platform::MacOS,
        &editor(Platform::MacOS, "system", None),
        &folder,
    )
    .unwrap();
    assert!(
        matches!(plan, LaunchPlan::Process { args, .. } if args[1] == "/System/Library/CoreServices/Finder.app")
    );
}

#[test]
fn system_default_rejects_interpreter_files_and_active_document_aliases() {
    let fixture = Fixture::new();
    let system = editor(Platform::Windows, "system", None);
    for extension in [
        "py",
        "pyw",
        "rb",
        "pl",
        "cpl",
        "xhtml",
        "XHT",
        "mhtml",
        "mht",
        "svgz",
        "applescript",
        "csh",
        "ksh",
        "run",
        "pkg",
        "dmg",
    ] {
        let name = format!("untrusted.{extension}");
        fixture.file(&format!("repo/{name}"));
        assert_eq!(
            launch_plan(
                Platform::Windows,
                &system,
                &fixture.target(Some(&name)).unwrap()
            )
            .err()
            .unwrap(),
            UNSAFE_DEFAULT,
            "{extension}"
        );
    }
}

#[cfg(unix)]
#[test]
fn system_default_rejects_extensionless_executable_files() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Fixture::new();
    let file = fixture.file("repo/run");
    std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o755)).unwrap();
    let system = editor(Platform::MacOS, "system", None);
    assert_eq!(
        launch_plan(
            Platform::MacOS,
            &system,
            &fixture.target(Some("run")).unwrap()
        )
        .err()
        .unwrap(),
        UNSAFE_DEFAULT
    );
}

#[test]
fn detection_lists_only_platform_choices_and_never_needs_to_run_a_candidate() {
    let fixture = Fixture::new();
    let local = fixture.0.join("local");
    let programs = fixture.0.join("programs");
    let system = fixture.0.join("system");
    fixture.file("local/Programs/Microsoft VS Code/Code.exe");
    fixture.file("programs/JetBrains/IntelliJ IDEA 2026.1/bin/idea64.exe");
    fixture.file("system/System32/notepad.exe");
    let search = Search {
        platform: Platform::Windows,
        home: None,
        local: Some(local),
        programs: vec![programs],
        system: Some(system),
        path: vec![],
    };
    let found = discover_with(&search);
    for id in ["vscode", "intellij", "notepad"] {
        assert!(found
            .iter()
            .find(|editor| editor.definition.id == id)
            .unwrap()
            .application
            .is_some());
    }
    assert!(found
        .iter()
        .all(|editor| !["xcode", "textedit"].contains(&editor.definition.id)));
    assert!(found
        .iter()
        .find(|editor| editor.definition.id == "vscode-insiders")
        .unwrap()
        .application
        .is_none());
    let mac = definitions(Platform::MacOS);
    assert!(mac.iter().any(|editor| editor.id == "xcode"));
    assert!(mac
        .iter()
        .any(|editor| editor.id == "textedit" && !editor.supports_folders));
    assert!(mac.iter().all(|editor| !editor.id.starts_with("notepad")));
}
