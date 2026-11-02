//! Chrome launches this companion directly; stdout contains native messaging frames only.
use gitrochi_ledger::{browser, browser_install};
use std::io;
use std::process::ExitCode;

fn main() -> ExitCode {
    let origin = std::env::args().nth(1).unwrap_or_default();
    let load = || {
        let config = browser_install::load_config()?;
        let current =
            std::env::current_exe().map_err(|e| gitrochi_ledger::Error::invalid(e.to_string()))?;
        let current = current.canonicalize().map_err(|e| {
            gitrochi_ledger::Error::not_allowed(format!(
                "Could not verify the browser host executable: {e}"
            ))
        })?;
        let installed = config.host_path.canonicalize().map_err(|e| {
            gitrochi_ledger::Error::not_allowed(format!(
                "Could not verify the installed browser host executable: {e}"
            ))
        })?;
        if current != installed {
            return Err(gitrochi_ledger::Error::not_allowed(
                "The browser host executable changed",
            ));
        }
        Ok(config)
    };
    match browser::serve(&origin, io::stdin().lock(), io::stdout().lock(), load) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("gitrochi-ledger-browser: {error}");
            ExitCode::FAILURE
        }
    }
}
