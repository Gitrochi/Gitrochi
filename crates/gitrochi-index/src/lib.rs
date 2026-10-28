//! Repository index: commits, file changes, change relationships and a search cache in
//! SQLite, shared by both apps, gitch, the Python tools and the Go services. Rust is
//! the only writer; README.md describes the contract readers rely on.
#![cfg(not(target_arch = "wasm32"))]

mod api;
mod cache;
mod db;
mod error;
pub mod ffi;
mod git;
mod query;
mod sync;
mod text;

pub use api::{call, run, version};
pub use db::SCHEMA_VERSION;
pub use error::{Error, Result};

#[cfg(test)]
mod tests;
