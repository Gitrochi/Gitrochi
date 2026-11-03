//! Gitrochi's session ledger: agents report which baseline their work started from and
//! where it stands; a person answers, confirms and cleans up in the apps. One SQLite
//! database per user, written only by this crate (from any process). CONTRACT.md is the
//! API the apps, the CLI, the MCP server and the hook handler rely on.
#![cfg(not(target_arch = "wasm32"))]

pub mod api;
pub mod backup;
pub mod baseline;
pub mod browser;
pub mod browser_install;
pub mod connection;
pub mod db;
pub mod demo;
pub mod documents;
mod error;
pub mod event;
pub mod external;
pub mod ffi;
mod git;
pub mod graph;
pub mod hook;
pub mod http;
pub mod human;
pub mod import;
pub mod integrations;
pub mod legacy;
mod legacy_extra;
pub mod mcp;
pub mod notebook;
pub mod overlap;
mod prompt_answer;
pub mod prompts;
mod question;
pub mod report;
pub mod search;
pub mod session;
pub mod settings;
mod sha1;
pub mod streams;
pub mod text;
mod toml_lite;
pub mod track;
pub mod util;
pub mod views;
pub mod vocab;
pub mod work;

pub use api::{call, call_as, Caller};
pub use db::{default_db_path, enabled, Db};
pub use error::{Error, Result};

#[cfg(test)]
mod tests;
