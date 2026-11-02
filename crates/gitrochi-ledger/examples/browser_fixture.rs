//! Development-only native framing fixture; never packaged or registered with a browser.
use gitrochi_ledger::{browser, browser_install::HostConfig};
use std::io;
use std::path::PathBuf;
use std::process::ExitCode;

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let db_path = arguments
        .next()
        .map(PathBuf::from)
        .ok_or("Give an isolated absolute database path")?;
    if !db_path.is_absolute() || arguments.next().is_some() {
        return Err("Give exactly one isolated absolute database path".into());
    }
    let config = HostConfig {
        extension_id: "abcdefghijklmnopabcdefghijklmnop".into(),
        allowed_origin: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/".into(),
        db_path,
        host_path: std::env::current_exe()?,
    };
    browser::serve(
        &config.allowed_origin,
        io::stdin().lock(),
        io::stdout().lock(),
        || Ok(config.clone()),
    )?;
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("browser_fixture: {error}");
            ExitCode::FAILURE
        }
    }
}
