//! gitch-flow — 조립형 테스트 · CI 흐름 엔진. `gitch flow` · `gitch test` 의 실행 계층이고,
//! Gitrochi 맥 · Windows 앱은 이 엔진의 JSON · NDJSON 계약만 읽는다.

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
pub mod expr;
pub mod gate_check;
pub mod git;
pub mod http;
pub mod keystore;
pub mod mask;
pub mod plan;
pub mod process;
pub mod report;
pub mod report_out;
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
