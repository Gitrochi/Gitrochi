//! Terminal host: a small process that owns the pseudo terminals of the Gitrochi apps, so shells and agents keep
//! running after the app quits and the app can reattach to them later. The protocol is described in README.md.

#[cfg(not(target_arch = "wasm32"))]
mod client;
#[cfg(not(target_arch = "wasm32"))]
mod endpoint;
#[cfg(not(target_arch = "wasm32"))]
mod host;
#[cfg(not(target_arch = "wasm32"))]
pub mod protocol;
#[cfg(not(target_arch = "wasm32"))]
mod scrollback;

#[cfg(not(target_arch = "wasm32"))]
pub use client::{Client, Event};
#[cfg(not(target_arch = "wasm32"))]
pub use endpoint::{Endpoint, ENDPOINT_FILE};
#[cfg(not(target_arch = "wasm32"))]
pub use host::{serve, HostOptions};
#[cfg(not(target_arch = "wasm32"))]
pub use protocol::{SessionInfo, SpawnSpec, VERSION};
