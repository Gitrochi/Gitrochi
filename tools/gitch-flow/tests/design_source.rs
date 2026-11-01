//! Source editing uses an isolated repository and never executes the selected text.

mod common;

use common::Fx;
use serde_json::{json, Value};
use std::io::Write;
use std::process::Stdio;

fn source(fx: &Fx, request: Value) -> Value {
    let mut child = fx
        .cmd("script", &["design", "source", "--json", "--lang", "en"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(request.to_string().as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn read(fx: &Fx, path: &str) -> Value {
    source(fx, json!({"operation":"read", "path":path}))
}

fn write(fx: &Fx, path: &str, content: &str, expected: Value) -> Value {
    source(
        fx,
        json!({"operation":"write", "path":path, "content":content, "expected":expected}),
    )
}

fn error(response: &Value, code: &str) {
    assert_eq!(response["saved"], false, "{response}");
    assert!(response["content"].is_null(), "{response}");
    assert!(response["fingerprint"].is_null(), "{response}");
    assert_eq!(
        response["diagnostics"][0]["severity"], "error",
        "{response}"
    );
    assert_eq!(response["diagnostics"][0]["code"], code, "{response}");
}

#[test]
fn exact_utf8_bom_crlf_and_noop_are_preserved_without_execution() {
    let original = "\u{feff}#!/bin/sh\r\necho 'example source'\r\n";
    let fx = Fx::new(&[("scripts/check 'quoted'.sh", original)]);
    let path = fx.repo().join("scripts/check 'quoted'.sh");
    let before = std::fs::metadata(&path).unwrap().modified().unwrap();
    let opened = read(&fx, "scripts/check 'quoted'.sh");
    assert_eq!(opened["content"], original);
    assert_eq!(opened["exists"], true);
    assert_eq!(opened["saved"], false);
    assert_eq!(
        opened["fingerprint"],
        gitch_flow::util::sha256_hex(original.as_bytes())
    );
    let saved = write(
        &fx,
        "scripts/check 'quoted'.sh",
        original,
        opened["fingerprint"].clone(),
    );
    assert_eq!(saved["saved"], true);
    assert_eq!(
        std::fs::metadata(&path).unwrap().modified().unwrap(),
        before
    );
    let edited = "\u{feff}#!/bin/sh\r\ntouch should-never-exist\r\n";
    let saved = write(
        &fx,
        "scripts/check 'quoted'.sh",
        edited,
        opened["fingerprint"].clone(),
    );
    assert_eq!(saved["content"], edited);
    assert_eq!(saved["saved"], true);
    assert_eq!(std::fs::read(path).unwrap(), edited.as_bytes());
    assert!(!fx.repo().join("should-never-exist").exists());
    assert!(!fx.repo().join(".gitch/trusted.json").exists());
    assert!(std::fs::read_dir(fx.repo().join("scripts"))
        .unwrap()
        .all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".gitrochi-source-")));
}

#[test]
fn stale_fingerprint_never_overwrites_changed_or_removed_file() {
    let fx = Fx::new(&[("check.py", "print('original')\n")]);
    let opened = read(&fx, "check.py");
    fx.write("check.py", "print('external change')\n");
    error(
        &write(&fx, "check.py", "draft", opened["fingerprint"].clone()),
        "SOURCE_CONFLICT",
    );
    assert_eq!(
        std::fs::read_to_string(fx.repo().join("check.py")).unwrap(),
        "print('external change')\n"
    );
    std::fs::remove_file(fx.repo().join("check.py")).unwrap();
    error(
        &write(&fx, "check.py", "draft", opened["fingerprint"].clone()),
        "SOURCE_CONFLICT",
    );
    assert!(!fx.repo().join("check.py").exists());
}

#[test]
fn explicit_creation_is_exclusive_and_requires_an_existing_parent() {
    let fx = Fx::new(&[("scripts/existing.sh", "old")]);
    error(&read(&fx, "scripts/new.sh"), "SOURCE_NOT_FOUND");
    let created = write(&fx, "scripts/new.sh", "new\n", Value::Null);
    assert_eq!(created["saved"], true);
    error(
        &write(&fx, "scripts/new.sh", "replacement", Value::Null),
        "SOURCE_CONFLICT",
    );
    assert_eq!(
        std::fs::read_to_string(fx.repo().join("scripts/new.sh")).unwrap(),
        "new\n"
    );
    error(
        &write(&fx, "missing/new.sh", "new", Value::Null),
        "SOURCE_PARENT_NOT_FOUND",
    );
    assert!(!fx.repo().join("missing").exists());
    error(
        &write(&fx, "scripts/existing.sh", "old", Value::Null),
        "SOURCE_CONFLICT",
    );
}

#[test]
fn explicit_new_file_can_create_missing_parent_folders_only_when_requested() {
    let fx = Fx::new(&[(".gitch/flow.yml", "version: 1\nflows: {}\n")]);
    error(
        &read(&fx, ".gitch/blocks/custom.yml"),
        "SOURCE_PARENT_NOT_FOUND",
    );
    assert!(!fx.repo().join(".gitch/blocks").exists());
    let metadata = std::fs::metadata(fx.repo().join(".gitch")).unwrap();
    let created = source(
        &fx,
        json!({"operation":"write","path":".gitch/blocks/nested/custom.yml","content":"custom: example\n","expected":null,"createParents":true}),
    );
    assert_eq!(created["saved"], true, "{created}");
    assert_eq!(
        read(&fx, ".gitch/blocks/nested/custom.yml")["content"],
        "custom: example\n"
    );
    assert_eq!(
        metadata.permissions().readonly(),
        std::fs::metadata(fx.repo().join(".gitch"))
            .unwrap()
            .permissions()
            .readonly()
    );
    error(
        &source(
            &fx,
            json!({"operation":"write","path":".gitch/blocks/nested/custom.yml","content":"replace","expected":created["fingerprint"],"createParents":true}),
        ),
        "SOURCE_REQUEST",
    );
    error(
        &source(
            &fx,
            json!({"operation":"write","path":".gitch/blocks/nested/custom.yml","content":"replace","expected":null,"createParents":true}),
        ),
        "SOURCE_CONFLICT",
    );
    assert_eq!(
        std::fs::read_to_string(fx.repo().join(".gitch/blocks/nested/custom.yml")).unwrap(),
        "custom: example\n"
    );
}

#[test]
fn parent_creation_rejects_invalid_paths_and_requests_before_making_folders() {
    let fx = Fx::new(&[]);
    for path in [
        "new/.git/config",
        "new/../file",
        "/outside/new",
        "new/CONIN$",
    ] {
        error(
            &source(
                &fx,
                json!({"operation":"write","path":path,"content":"draft","expected":null,"createParents":true}),
            ),
            "SOURCE_PATH",
        );
    }
    assert!(!fx.repo().join("new").exists());
    for request in [
        json!({"operation":"read","path":"new/file","createParents":true}),
        json!({"operation":"write","path":"new/file","content":"draft","expected":null,"createParents":"yes"}),
        json!({"operation":"write","path":"new/file","content":"draft","expected":"0".repeat(64),"createParents":true}),
    ] {
        error(&source(&fx, request), "SOURCE_REQUEST");
    }
    error(
        &source(
            &fx,
            json!({"operation":"write","path":"new/file","content":"bad\u{0}text","expected":null,"createParents":true}),
        ),
        "SOURCE_ENCODING",
    );
    assert!(!fx.repo().join("new").exists());
}

#[test]
fn traversal_git_metadata_and_windows_aliases_are_rejected_on_every_platform() {
    let fx = Fx::new(&[(".gitignore", "target\n")]);
    for path in [
        "",
        "/tmp/outside",
        "../outside",
        "folder/../file",
        "folder/./file",
        "folder//file",
        "folder/",
        "C:/file",
        "C:\\file",
        "\\\\server\\file",
        ".git/config",
        "nested/.GiT/config",
        ".git",
        "NUL",
        "aux.txt",
        "nested/COM1.log",
        "CONIN$",
        "conout$.txt",
        "CLOCK$",
        "scripts/COM¹.log",
        "LPT²",
        "LPT³.txt",
        "file.",
        "file ",
        "bad\nname",
        "file:stream",
        "a?b",
    ] {
        error(&read(&fx, path), "SOURCE_PATH");
        error(&write(&fx, path, "no write", Value::Null), "SOURCE_PATH");
    }
    assert_eq!(read(&fx, ".gitignore")["content"], "target\n");
}

#[test]
fn invalid_request_shapes_and_unfingerprinted_saves_are_rejected() {
    let fx = Fx::new(&[("source.txt", "original")]);
    for request in [
        json!({"operation":"execute","path":"source.txt"}),
        json!({"operation":"write","path":"source.txt","content":"draft"}),
        json!({"operation":"write","path":"source.txt","content":"draft","expected":"old text"}),
        json!({"operation":"read","path":"source.txt","expected":null}),
        json!({"operation":"read","path":"source.txt","content":"unexpected"}),
        json!({"operation":"read","path":"source.txt","root":"/"}),
        json!({"operation":"write","path":"source.txt","content":false,"expected":null}),
    ] {
        error(&source(&fx, request), "SOURCE_REQUEST");
    }
    assert_eq!(
        std::fs::read_to_string(fx.repo().join("source.txt")).unwrap(),
        "original"
    );
}

#[test]
fn text_must_be_bounded_strict_utf8_without_nul() {
    let fx = Fx::new(&[]);
    std::fs::write(fx.repo().join("bad.bin"), [0xff, 0xfe]).unwrap();
    error(&read(&fx, "bad.bin"), "SOURCE_ENCODING");
    std::fs::write(fx.repo().join("zero-byte.txt"), b"a\0b").unwrap();
    error(&read(&fx, "zero-byte.txt"), "SOURCE_ENCODING");
    error(
        &write(&fx, "new.txt", "a\0b", Value::Null),
        "SOURCE_ENCODING",
    );
    std::fs::write(fx.repo().join("large.txt"), vec![b'a'; 2 * 1024 * 1024 + 1]).unwrap();
    error(&read(&fx, "large.txt"), "SOURCE_SIZE");
    error(
        &write(
            &fx,
            "new.txt",
            &"a".repeat(2 * 1024 * 1024 + 1),
            Value::Null,
        ),
        "SOURCE_SIZE",
    );
    std::fs::create_dir(fx.repo().join("directory")).unwrap();
    error(&read(&fx, "directory"), "SOURCE_TYPE");
    assert!(!fx.repo().join("new.txt").exists());
}

#[test]
fn full_size_valid_text_is_accepted_even_with_six_byte_json_escaping() {
    let fx = Fx::new(&[]);
    let content = "\u{1}".repeat(2 * 1024 * 1024);
    let saved = write(&fx, "escaped.txt", &content, Value::Null);
    assert_eq!(saved["saved"], true);
    assert_eq!(
        std::fs::read(fx.repo().join("escaped.txt")).unwrap(),
        content.as_bytes()
    );
    assert_eq!(read(&fx, "escaped.txt")["content"], content);
}

#[test]
fn missing_repository_returns_a_structured_error_without_creation() {
    let fx = Fx::new(&[]);
    std::fs::remove_dir_all(fx.repo().join(".git")).unwrap();
    error(
        &write(&fx, "new.txt", "draft", Value::Null),
        "SOURCE_REPOSITORY",
    );
    assert!(!fx.repo().join("new.txt").exists());
}

#[cfg(unix)]
#[test]
fn symlinks_inside_or_outside_the_repository_and_special_files_are_rejected() {
    use std::os::unix::fs::symlink;
    let fx = Fx::new(&[("scripts/check.sh", "original")]);
    std::fs::create_dir(fx.dir.join("outside")).unwrap();
    std::fs::write(fx.dir.join("outside/check.sh"), "outside").unwrap();
    symlink("scripts/check.sh", fx.repo().join("inside-link")).unwrap();
    symlink(
        fx.dir.join("outside/check.sh"),
        fx.repo().join("outside-link"),
    )
    .unwrap();
    symlink("scripts", fx.repo().join("inside-dir")).unwrap();
    symlink(fx.dir.join("outside"), fx.repo().join("outside-dir")).unwrap();
    for path in [
        "inside-link",
        "outside-link",
        "inside-dir/check.sh",
        "outside-dir/check.sh",
        "inside-dir/new.sh",
    ] {
        error(&read(&fx, path), "SOURCE_SYMLINK");
        error(&write(&fx, path, "draft", Value::Null), "SOURCE_SYMLINK");
        error(
            &source(
                &fx,
                json!({"operation":"write","path":path,"content":"draft","expected":null,"createParents":true}),
            ),
            "SOURCE_SYMLINK",
        );
    }
    assert_eq!(
        std::fs::read_to_string(fx.dir.join("outside/check.sh")).unwrap(),
        "outside"
    );
    let fifo =
        std::ffi::CString::new(fx.repo().join("pipe").as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    error(&read(&fx, "pipe"), "SOURCE_TYPE");
}

#[cfg(unix)]
#[test]
fn replacement_preserves_executable_mode_and_does_not_change_other_hard_links() {
    use std::os::unix::fs::PermissionsExt;
    let fx = Fx::new(&[("check.sh", "original\n")]);
    let path = fx.repo().join("check.sh");
    std::fs::hard_link(&path, fx.dir.join("outside-copy")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o751)).unwrap();
    let opened = read(&fx, "check.sh");
    assert_eq!(
        write(&fx, "check.sh", "edited\n", opened["fingerprint"].clone())["saved"],
        true
    );
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o7777,
        0o751
    );
    assert_eq!(
        std::fs::read_to_string(fx.dir.join("outside-copy")).unwrap(),
        "original\n"
    );
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o444)).unwrap();
    let opened = read(&fx, "check.sh");
    error(
        &write(
            &fx,
            "check.sh",
            "replacement",
            opened["fingerprint"].clone(),
        ),
        "SOURCE_READ_ONLY",
    );
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "edited\n");
}

#[cfg(target_vendor = "apple")]
fn mac_acl(path: &std::path::Path) -> Vec<String> {
    let output = std::process::Command::new("/bin/ls")
        .arg("-le")
        .arg(path)
        .output()
        .unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .skip(1)
        .map(str::to_owned)
        .collect()
}

#[cfg(target_vendor = "apple")]
fn add_mac_acl(path: &std::path::Path, entry: &str) {
    let output = std::process::Command::new("/bin/chmod")
        .args(["+a", entry])
        .arg(path)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[cfg(target_vendor = "apple")]
#[test]
fn apple_extended_acl_is_preserved_on_replacement() {
    use std::os::unix::fs::PermissionsExt;
    let fx = Fx::new(&[("script.sh", "original\n")]);
    let path = fx.repo().join("script.sh");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    add_mac_acl(&path, "everyone deny execute");
    let before = mac_acl(&path);
    assert!(!before.is_empty());
    let opened = read(&fx, "script.sh");
    let saved = write(&fx, "script.sh", "edited\n", opened["fingerprint"].clone());
    assert_eq!(saved["saved"], true, "{saved}");
    assert_eq!(mac_acl(&path), before);
    assert_eq!(
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
        0o755
    );
}

#[cfg(target_vendor = "apple")]
#[test]
fn apple_source_without_acl_does_not_inherit_broader_temporary_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let fx = Fx::new(&[("private/example.txt", "original")]);
    let path = fx.repo().join("private/example.txt");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert!(mac_acl(&path).is_empty());
    add_mac_acl(
        &fx.repo().join("private"),
        "everyone allow read,file_inherit",
    );
    let opened = read(&fx, "private/example.txt");
    let saved = write(
        &fx,
        "private/example.txt",
        "edited",
        opened["fingerprint"].clone(),
    );
    assert_eq!(saved["saved"], true, "{saved}");
    assert!(mac_acl(&path).is_empty());
    assert_eq!(
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
        0o600
    );
}
