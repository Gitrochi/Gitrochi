//! Gitrochi's session ledger: agents report which baseline their work started from and
//! where it stands; a person answers, confirms and cleans up in the apps. One SQLite
//! database per user, written only by this crate (from any process). CONTRACT.md is the
//! API the apps, the CLI, the MCP server and the hook handler rely on.
#![cfg(not(target_arch = "wasm32"))]

pub mod api;
pub mod backup;
pub mod baseline;
pub mod db;
pub mod demo;
mod error;
pub mod event;
pub mod ffi;
mod git;
pub mod graph;
pub mod hook;
pub mod human;
pub mod import;
pub mod legacy;
pub mod mcp;
pub mod overlap;
pub mod prompts;
pub mod report;
pub mod search;
pub mod session;
pub mod settings;
mod sha1;
pub mod streams;
pub mod text;
pub mod util;
pub mod views;
pub mod vocab;

pub use api::{call, call_as, Caller};
pub use db::{default_db_path, enabled, Db};
pub use error::{Error, Result};

#[cfg(test)]
mod tests;
