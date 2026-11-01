//! Human terminal presentation is isolated from redirected and protocol output.

mod common;

use common::{app, binary, cli, stderr, stdout, TempDir};
use serde_json::json;

#[test]
fn redirected_output_stays_plain_even_when_color_is_requested() {
    let dir = TempDir::new("terminal-pipe");
    let db = dir.join("ledger.sqlite3");
    let output = binary()
        .env("GITSW_COLOR", "always")
        .env("GITSW_BANNER", "always")
        .env("TERM", "xterm-256color")
        .args(["--db", db.to_str().unwrap(), "overview"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(
        stdout(&output),
        "The ledger has no projects yet. Report a start with a project name to begin.\n"
    );
    assert!(output.stderr.is_empty());
}

#[cfg(unix)]
mod tty {
    use super::*;
    use std::fs::File;
    use std::io::{Read, Write};
    use std::os::fd::FromRawFd;
    use std::os::raw::{c_char, c_int, c_void};
    use std::process::Stdio;

    const EYE: &str = "⣿⣿⠃⢀⡄    ⣠⡔ ⢠⣿⣿⡶";

    #[repr(C)]
    struct Size {
        rows: u16,
        columns: u16,
        x: u16,
        y: u16,
    }

    #[cfg_attr(target_os = "linux", link(name = "util"))]
    unsafe extern "C" {
        fn openpty(
            master: *mut c_int,
            slave: *mut c_int,
            name: *mut c_char,
            term: *const c_void,
            size: *const Size,
        ) -> c_int;
    }

    fn pty(columns: u16) -> (File, File) {
        let (mut master, mut slave) = (-1, -1);
        let size = Size {
            rows: 60,
            columns,
            x: 0,
            y: 0,
        };
        // openpty owns two new descriptors; File closes each exactly once.
        let code = unsafe {
            openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null(),
                &size,
            )
        };
        assert_eq!(code, 0, "{}", std::io::Error::last_os_error());
        unsafe { (File::from_raw_fd(master), File::from_raw_fd(slave)) }
    }

    fn read_pty(mut file: File) -> String {
        let mut bytes = Vec::new();
        let mut buffer = [0; 4096];
        loop {
            match file.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => bytes.extend_from_slice(&buffer[..count]),
                // A PTY reports EIO after its last slave closes on Linux/macOS.
                Err(error) if error.raw_os_error() == Some(5) => break,
                Err(error) => panic!("read PTY: {error}"),
            }
        }
        String::from_utf8(bytes).unwrap().replace("\r\n", "\n")
    }

    struct Reply {
        out: String,
        error: String,
        code: i32,
    }

    fn run(
        db: &std::path::Path,
        args: &[&str],
        width: u16,
        env: &[(&str, &str)],
        input: &str,
    ) -> Reply {
        let (master, slave) = pty(width);
        let (error_master, error_slave) = pty(width);
        let mut command = binary();
        for key in [
            "NO_COLOR",
            "GITSW_COLOR",
            "GITSW_BANNER",
            "GITCH_LOGO",
            "GITCH_STYLE",
            "COLUMNS",
            "LC_ALL",
            "LC_CTYPE",
            "COLORFGBG",
        ] {
            command.env_remove(key);
        }
        command
            .env("TERM", "xterm-256color")
            .env("LANG", "en_US.UTF-8")
            .envs(env.iter().copied())
            .args(["--db", db.to_str().unwrap()])
            .args(args)
            .stdin(Stdio::piped())
            .stdout(slave)
            .stderr(error_slave);
        let mut child = command.spawn().unwrap();
        // Command retains its Stdio handles after spawn; close these parent copies too.
        drop(command);
        let out = std::thread::spawn(move || read_pty(master));
        let error = std::thread::spawn(move || read_pty(error_master));
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        let code = child.wait().unwrap().code().unwrap();
        Reply {
            out: out.join().unwrap(),
            error: error.join().unwrap(),
            code,
        }
    }

    fn without_color(text: &str) -> String {
        let mut plain = String::new();
        let mut chars = text.chars();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                assert_eq!(chars.next(), Some('['));
                for code in chars.by_ref() {
                    if code == 'm' {
                        break;
                    }
                    assert!(
                        code.is_ascii_digit() || code == ';',
                        "only SGR colors are allowed"
                    );
                }
            } else {
                plain.push(c);
            }
        }
        plain
    }

    #[test]
    fn eye_header_adapts_to_real_terminal_width_and_background() {
        let dir = TempDir::new("terminal-width");
        let db = dir.join("ledger.sqlite3");
        for width in [28, 40, 80, 120] {
            for (background, code) in [("0;0", "94"), ("0;15", "34")] {
                let reply = run(&db, &["overview"], width, &[("COLORFGBG", background)], "");
                assert_eq!(reply.code, 0, "{}", reply.error);
                assert!(reply.error.is_empty());
                assert!(reply.out.contains(&format!("\x1b[{code}m{EYE}")));
                let text = without_color(&reply.out);
                assert_eq!(text.matches(EYE).count(), 1);
                assert_eq!(text.matches("Gitrochi Ledger").count(), 1);
                assert!(!text.contains('\r'));
                for line in text.lines() {
                    assert!(
                        line.chars().count() <= usize::from(width),
                        "{width}: {line}"
                    );
                }
                assert_eq!(text.contains("Local agent session ledger"), width >= 58);
            }
            let reply = run(
                &db,
                &["overview"],
                width,
                &[("NO_COLOR", "1"), ("GITSW_COLOR", "always")],
                "",
            );
            assert!(reply.out.contains(EYE));
            assert!(!reply.out.contains('\x1b'));
        }
    }

    #[test]
    fn help_results_sessions_and_errors_keep_channels_and_exit_codes() {
        let dir = TempDir::new("terminal-human");
        let db = dir.join("ledger.sqlite3");
        let help = run(&db, &["--help"], 40, &[], "");
        assert_eq!(help.code, 0);
        assert!(help.out.contains("Gitrochi Ledger"));
        assert!(help.out.contains("report"));
        assert!(help.error.is_empty());

        let reported = run(
            &db,
            &[
                "report",
                "-p",
                "Example App",
                "-s",
                "terminal-demo",
                "-e",
                "start",
                "-t",
                "Review output",
            ],
            80,
            &[],
            "",
        );
        assert_eq!(reported.code, 0, "{}", reported.error);
        assert!(reported.out.contains("\x1b[32mRecorded ✓"));
        let session = run(&db, &["session", "terminal-demo"], 80, &[], "");
        assert_eq!(session.code, 0, "{}", session.error);
        assert!(session.out.contains("Review output"));
        assert!(session.error.is_empty());

        let failed = run(&db, &["--db"], 28, &[], "");
        assert_eq!(failed.code, 2);
        assert!(failed.out.is_empty());
        assert!(failed.error.contains(EYE));
        assert!(failed.error.contains("Command failed"));
        assert!(failed.error.contains("\x1b[1;31m"));
        let missing = run(&db, &["session", "no-such-session"], 40, &[], "");
        assert_eq!(
            missing.code,
            cli(&db, &["session", "no-such-session"])
                .status
                .code()
                .unwrap()
        );
        assert!(missing.out.is_empty());
        assert!(missing.error.contains("Command failed"));
    }

    #[test]
    fn plain_and_logo_preferences_are_respected() {
        let dir = TempDir::new("terminal-preferences");
        let db = dir.join("ledger.sqlite3");
        let expected = stdout(&cli(&db, &["--help"]));
        for env in [
            [("TERM", "dumb")],
            [("GITCH_STYLE", "plain")],
            [("GITSW_BANNER", "never")],
        ] {
            let reply = run(&db, &["--help"], 80, &env, "");
            assert_eq!(reply.out, expected);
            assert!(reply.error.is_empty());
        }
        let reply = run(&db, &["--help"], 80, &[("GITCH_LOGO", "off")], "");
        assert!(!reply.out.contains(EYE));
        assert!(reply.out.contains("Gitrochi Ledger"));
        let ascii = run(
            &db,
            &["overview"],
            80,
            &[("LC_ALL", "C"), ("NO_COLOR", "1")],
            "",
        );
        assert!(ascii.out.starts_with("  o o  Gitrochi Ledger\n"));
        assert!(!ascii.out.contains(EYE));
    }

    #[test]
    fn redirected_stdout_is_plain_when_stderr_is_a_terminal() {
        let dir = TempDir::new("terminal-mixed");
        let db = dir.join("ledger.sqlite3");
        let (master, slave) = pty(80);
        let mut command = binary();
        command
            .env("TERM", "xterm-256color")
            .env("GITSW_COLOR", "always")
            .args(["--db", db.to_str().unwrap(), "overview"])
            .stdout(Stdio::piped())
            .stderr(slave);
        let child = command.spawn().unwrap();
        drop(command);
        let error = std::thread::spawn(move || read_pty(master));
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(stdout(&output), stdout(&cli(&db, &["overview"])));
        assert!(error.join().unwrap().is_empty());
    }

    #[test]
    fn json_mcp_and_hook_are_never_decorated_on_a_terminal() {
        let dir = TempDir::new("terminal-protocol");
        let db = dir.join("ledger.sqlite3");
        for args in [
            vec!["--json", "overview"],
            vec!["--pretty", "overview"],
            vec!["--json=true", "overview"],
            vec!["--pretty=true", "session", "missing"],
            vec!["call", "info"],
            vec!["call", "missing"],
        ] {
            let expected = cli(&db, &args);
            let reply = run(
                &db,
                &args,
                80,
                &[("GITSW_COLOR", "always"), ("GITSW_BANNER", "always")],
                "",
            );
            assert_eq!(reply.code, expected.status.code().unwrap());
            assert_eq!(reply.out, stdout(&expected));
            assert_eq!(reply.error, stderr(&expected));
            serde_json::from_str::<serde_json::Value>(&reply.out).unwrap();
        }
        for args in [vec!["--json=true", "--db"], vec!["mcp", "--db"]] {
            let expected = cli(&db, &args);
            let reply = run(&db, &args, 80, &[], "");
            assert_eq!(reply.code, 2);
            assert_eq!(reply.out, stdout(&expected));
            assert_eq!(reply.error, stderr(&expected));
            assert!(!reply.error.contains('\x1b'));
            assert!(!reply.error.contains(EYE));
        }
        let input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}\n";
        let reply = run(&db, &["mcp"], 80, &[], input);
        assert_eq!(reply.code, 0, "{}", reply.error);
        let response: serde_json::Value = serde_json::from_str(&reply.out).unwrap();
        assert_eq!(response["id"], 1);
        assert!(response["result"]["serverInfo"].is_object());
        assert!(reply.error.is_empty());
        let hook = run(
            &db,
            &["hook", "SessionStart"],
            80,
            &[("GITROCHI_LEDGER", "0")],
            "{}",
        );
        assert_eq!(hook.code, 0);
        assert!(hook.out.is_empty());
        assert!(hook.error.is_empty());
    }

    #[test]
    fn report_text_cannot_inject_terminal_controls() {
        let dir = TempDir::new("terminal-untrusted");
        let db = dir.join("ledger.sqlite3");
        app(
            &db,
            "report",
            json!({"project": "Example App", "session": "unsafe-title", "event": "start", "title": "hello\u{1b}[2Jworld"}),
        );
        let reply = run(
            &db,
            &["session", "unsafe-title"],
            80,
            &[("NO_COLOR", "1")],
            "",
        );
        assert_eq!(reply.code, 0, "{}", reply.error);
        assert!(reply.out.contains("hello\\e[2Jworld"));
        assert!(!reply.out.contains('\x1b'));
        let raw = cli(&db, &["session", "unsafe-title", "--json"]);
        assert!(common::json_of(&raw)["session"]["title"]
            .as_str()
            .unwrap()
            .contains('\x1b'));
    }
}
