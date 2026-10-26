//! gitch-flow: the engine for composable test and CI flows. It is the execution layer of `gitch flow` and `gitch test`,
//! and the Gitrochi macOS and Windows apps read only its JSON and NDJSON contracts.

pub mod affected;
pub mod blocks;
pub mod cache;
pub mod ci;
pub mod cli;
pub mod codes;
pub mod connect;
pub mod detect;
pub mod docker;
pub mod doctor;
pub mod executor;
pub mod expr;
pub mod gate_check;
pub mod git;
pub mod http;
pub mod keystore;
pub mod mask;
pub mod mock;
pub mod plan;
pub mod process;
pub mod report;
pub mod report_out;
pub mod rollback;
pub mod run;
pub mod schemas;
pub mod secret;
pub mod services;
pub mod spec;
pub mod store;
pub mod trust;
pub mod util;
pub mod verify;
pub mod watch;
pub mod yaml;
