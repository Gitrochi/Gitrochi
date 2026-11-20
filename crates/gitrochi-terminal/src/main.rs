//! gitrochi-terminal-host --state-dir <folder> [--idle-exit <seconds>]
//!
//! Started by the app when no host answers; ends by itself once no app is connected and nothing runs.

#[cfg(not(target_arch = "wasm32"))]
fn main() {
    use gitrochi_terminal::{serve, HostOptions};
    use std::time::Duration;

    let mut state_dir = None;
    let mut idle_exit = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--state-dir" => state_dir = args.next(),
            "--idle-exit" => idle_exit = args.next().and_then(|s| s.parse::<u64>().ok()),
            _ => usage(),
        }
    }
    let Some(state_dir) = state_dir else { usage() };
    let mut options = HostOptions::new(state_dir.into());
    if let Some(seconds) = idle_exit {
        options.idle_exit = Duration::from_secs(seconds);
    }
    if let Err(e) = serve(options) {
        eprintln!("gitrochi-terminal-host: {e}");
        // 3: another host answers already, which the app treats as success
        std::process::exit(if e.kind() == std::io::ErrorKind::AddrInUse {
            3
        } else {
            1
        });
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn usage() -> ! {
    eprintln!("usage: gitrochi-terminal-host --state-dir <folder> [--idle-exit <seconds>]");
    std::process::exit(2);
}

#[cfg(target_arch = "wasm32")]
fn main() {}
