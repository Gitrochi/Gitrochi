//! Human terminal presentation only. Agent text and protocol output never pass through it.

use std::env;
use std::io::{self, IsTerminal};

// Keep the eye mark identical to tools/gitch/gitch's LOGO_S (trailing spaces omitted).
const EYES: [&str; 3] = ["⣼⣿⣦", "⣿⣿⠃⢀⡄    ⣠⡔ ⢠⣿⣿⡶", "⠈⠻⢦⡾⠃   ⠸⢿⣥⣴⣿⠿⠋"];

#[derive(Clone, Copy)]
enum Channel {
    Out,
    Error,
}

#[derive(Clone, Copy)]
struct Style {
    rich: bool,
    color: bool,
    logo: bool,
    unicode: bool,
    columns: usize,
    light: bool,
}

impl Style {
    fn detect(channel: Channel, protocol: bool) -> Self {
        let terminal = match channel {
            Channel::Out => io::stdout().is_terminal(),
            Channel::Error => io::stderr().is_terminal(),
        };
        let rich = terminal
            && !protocol
            && env::var("TERM").as_deref() != Ok("dumb")
            && env::var("GITCH_STYLE").as_deref() != Ok("plain")
            && env::var("GITSW_BANNER").as_deref() != Ok("never");
        let locale = ["LC_ALL", "LC_CTYPE", "LANG"]
            .iter()
            .find_map(|key| env::var(key).ok().filter(|value| !value.is_empty()));
        let unicode = locale.is_none_or(|locale| {
            let locale = locale.to_ascii_lowercase();
            locale.contains("utf-8") || locale.contains("utf8")
        });
        let columns = env::var("COLUMNS")
            .ok()
            .and_then(|value| value.parse::<usize>().ok())
            .filter(|value| (8..=500).contains(value))
            .or_else(|| terminal.then(|| terminal_columns(channel)).flatten())
            .unwrap_or(80);
        Self {
            rich,
            color: rich
                && supports_ansi(channel)
                && !env::var_os("NO_COLOR").is_some_and(|value| !value.is_empty())
                && env::var("GITSW_COLOR").as_deref() != Ok("never"),
            logo: !matches!(
                env::var("GITCH_LOGO")
                    .unwrap_or_default()
                    .to_ascii_lowercase()
                    .as_str(),
                "off" | "false" | "no" | "0"
            ),
            unicode,
            columns,
            light: env::var("COLORFGBG")
                .ok()
                .and_then(|value| value.rsplit(';').next()?.parse::<u8>().ok())
                .is_some_and(|background| background >= 7),
        }
    }

    fn paint(self, text: &str, code: &str) -> String {
        if self.color {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }

    fn header(self, title: &str) -> String {
        let accent = if self.light { "34" } else { "94" };
        let name = self.paint("Gitrochi Ledger", "1");
        let title = self.paint(title, accent);
        let detail = self.paint("Local agent session ledger", "2");
        let mut lines = Vec::new();
        if self.logo && self.unicode && self.columns >= 58 {
            let width = EYES.iter().map(|row| row.chars().count()).max().unwrap();
            for (eye, label) in EYES.iter().zip([name, title, detail]) {
                lines.push(format!(
                    "  {}{}{}",
                    self.paint(eye, accent),
                    " ".repeat(width - eye.chars().count() + 3),
                    label
                ));
            }
        } else {
            if self.logo && self.unicode && self.columns >= 24 {
                lines.extend(
                    EYES.iter()
                        .map(|row| format!("  {}", self.paint(row, accent))),
                );
            }
            let mark = if self.logo && (!self.unicode || self.columns < 24) {
                "o o  "
            } else {
                ""
            };
            lines.push(format!("  {mark}{name}"));
            lines.push(format!("  {title}"));
        }
        format!("{}\n\n", lines.join("\n"))
    }

    fn render(self, title: &str, text: &str, error: bool) -> String {
        if !self.rich {
            return text.to_string();
        }
        let mut out = self.header(title);
        for (index, line) in text.split('\n').enumerate() {
            if index > 0 {
                out.push('\n');
            }
            let line = visible(line);
            let code = if index == 0 && error {
                "1;31"
            } else if index == 0 && line.starts_with("Recorded ✓") {
                "32"
            } else if index == 0 || line.ends_with(':') {
                "1"
            } else {
                ""
            };
            for (part, line) in wrap(&line, self.columns.saturating_sub(2).max(8))
                .into_iter()
                .enumerate()
            {
                if part > 0 {
                    out.push('\n');
                }
                if !line.is_empty() {
                    out.push_str("  ");
                }
                if code.is_empty() {
                    out.push_str(&line);
                } else {
                    out.push_str(&self.paint(&line, code));
                }
            }
        }
        out
    }
}

/// Decides once before parsing, so even malformed protocol invocations stay undecorated.
pub struct Presentation {
    out: Style,
    error: Style,
}

impl Presentation {
    pub fn detect(arguments: &[String]) -> Self {
        let protocol = arguments.iter().any(|argument| {
            matches!(
                argument.split('=').next().unwrap_or(argument),
                "mcp" | "hook" | "call" | "--json" | "--pretty"
            )
        });
        Self {
            out: Style::detect(Channel::Out, protocol),
            error: Style::detect(Channel::Error, protocol),
        }
    }

    pub fn help(&self, usage: &str) -> String {
        if !self.out.rich {
            return usage.to_string();
        }
        // Retain the parser's complete help, including commands added by other features.
        // Its wide continuation alignment is hard to read on a narrow terminal.
        let compact = usage
            .lines()
            .map(|line| {
                let trimmed = line.trim_start();
                if line.len() - trimmed.len() > 4 {
                    format!("    {trimmed}")
                } else {
                    line.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        self.out.render("Help", &compact, false)
    }

    pub fn text(&self, command: &str, text: &str) -> String {
        let title = match command {
            "report" => "Report",
            "overview" => "Overview",
            "session" => "Session",
            "import" => "Import reports",
            "import-legacy" => "Import from claude-ledger",
            "scan" => "Scan baselines",
            "register" => "Register a baseline",
            "backup" => "Backup",
            "demo" => "Demo data",
            _ => "Ledger",
        };
        self.out.render(title, text, false)
    }

    pub fn error(&self, text: &str) -> String {
        self.error.render("Command failed", text, true)
    }
}

// Wrap at whitespace only: identifiers, paths and URLs must remain copyable in full.
fn wrap(line: &str, columns: usize) -> Vec<String> {
    let indent = line.chars().take_while(|c| *c == ' ').count();
    let continuation = " ".repeat((indent + 2).min(columns / 2));
    let mut rest = line.to_string();
    let mut lines = Vec::new();
    while rest.chars().count() > columns {
        let start = rest.chars().take_while(|c| *c == ' ').count();
        let split = rest
            .char_indices()
            .enumerate()
            .take(columns + 1)
            .filter(|(index, (_, c))| *index > start && c.is_whitespace())
            .map(|(_, (byte, _))| byte)
            .last();
        let Some(split) = split else { break };
        lines.push(rest[..split].to_string());
        rest = format!("{continuation}{}", rest[split..].trim_start());
    }
    lines.push(rest);
    lines
}

// Reports are untrusted text; only our renderer may introduce terminal controls.
fn visible(text: &str) -> String {
    let mut out = String::new();
    for character in text.chars() {
        match character {
            '\x1b' => out.push_str("\\e"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            value if value.is_control() => out.push_str(&format!("\\x{:02x}", value as u32)),
            value => out.push(value),
        }
    }
    out
}

#[cfg(not(windows))]
fn supports_ansi(_: Channel) -> bool {
    true
}

#[cfg(windows)]
fn supports_ansi(channel: Channel) -> bool {
    use std::ffi::c_void;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetStdHandle(kind: u32) -> *mut c_void;
        fn GetConsoleMode(handle: *mut c_void, mode: *mut u32) -> i32;
    }
    let kind = match channel {
        Channel::Out => -11_i32,
        Channel::Error => -12_i32,
    };
    let mut mode = 0;
    // Respect the console's existing VT support; never change its mode for decoration.
    let ok = unsafe { GetConsoleMode(GetStdHandle(kind as u32), &mut mode) };
    ok != 0 && mode & 0x0004 != 0
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn terminal_columns(channel: Channel) -> Option<usize> {
    use std::os::fd::AsRawFd;
    use std::os::raw::{c_int, c_ulong};
    #[repr(C)]
    struct Size {
        rows: u16,
        columns: u16,
        x: u16,
        y: u16,
    }
    unsafe extern "C" {
        fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
    }
    #[cfg(target_os = "macos")]
    const REQUEST: c_ulong = 0x40087468;
    #[cfg(target_os = "linux")]
    const REQUEST: c_ulong = 0x5413;
    let fd = match channel {
        Channel::Out => io::stdout().as_raw_fd(),
        Channel::Error => io::stderr().as_raw_fd(),
    };
    let mut size = Size {
        rows: 0,
        columns: 0,
        x: 0,
        y: 0,
    };
    // TIOCGWINSZ only fills this fixed-size structure; it changes no terminal settings.
    let result = unsafe { ioctl(fd, REQUEST, &mut size) };
    (result == 0 && size.columns > 0).then_some(usize::from(size.columns))
}

#[cfg(windows)]
fn terminal_columns(channel: Channel) -> Option<usize> {
    use std::ffi::c_void;
    #[repr(C)]
    #[derive(Default)]
    struct Coord {
        x: i16,
        y: i16,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Rect {
        left: i16,
        top: i16,
        right: i16,
        bottom: i16,
    }
    #[repr(C)]
    #[derive(Default)]
    struct Info {
        size: Coord,
        cursor: Coord,
        attributes: u16,
        window: Rect,
        maximum: Coord,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetStdHandle(kind: u32) -> *mut c_void;
        fn GetConsoleScreenBufferInfo(handle: *mut c_void, info: *mut Info) -> i32;
    }
    let kind = match channel {
        Channel::Out => -11_i32,
        Channel::Error => -12_i32,
    };
    let mut info = Info::default();
    // These calls read the visible console window without changing its mode or size.
    let ok = unsafe { GetConsoleScreenBufferInfo(GetStdHandle(kind as u32), &mut info) };
    (ok != 0)
        .then(|| {
            usize::try_from(i32::from(info.window.right) - i32::from(info.window.left) + 1).ok()
        })
        .flatten()
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn terminal_columns(_: Channel) -> Option<usize> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrapping_keeps_tokens_and_control_text_intact() {
        assert_eq!(
            wrap("One two three four", 10),
            ["One two", "  three", "  four"]
        );
        let path = "src/long-name/another-long-name/report.md";
        assert!(wrap(&format!("Saved to {path}"), 20)
            .join("\n")
            .contains(path));
        assert_eq!(visible("a\x1b[2J\r\t\x07b"), "a\\e[2J\\r\\t\\x07b");
    }
}
