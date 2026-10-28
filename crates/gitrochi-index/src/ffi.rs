//! C ABI for the macOS app. The buffer format matches the shared core's: an 8-byte
//! little-endian length, then UTF-8 JSON.

use crate::api;
use serde_json::{json, Value};

const MAX_REQUEST: usize = 16 * 1024 * 1024;

fn owned_buffer(body: Vec<u8>) -> *mut u8 {
    let mut buffer = Vec::with_capacity(8 + body.len());
    buffer.extend_from_slice(&(body.len() as u64).to_le_bytes());
    buffer.extend_from_slice(&body);
    Box::into_raw(buffer.into_boxed_slice()) as *mut u8
}

fn failure(message: &str) -> Value {
    json!({"error": {"code": "INVALID_ARGUMENT", "message": message}})
}

/// Runs `{"repo", "command", "args"}` and returns `{"result"}` or `{"error"}`. Safe to
/// call from several threads; a long sync blocks only its own caller.
///
/// # Safety
/// `input` must be readable for `length` bytes. Release the result with
/// `gitrochi_index_free` and its full length (8 + the stored body length).
#[no_mangle]
pub unsafe extern "C" fn gitrochi_index_call(input: *const u8, length: usize) -> *mut u8 {
    let response = if input.is_null() || length > MAX_REQUEST {
        failure("Invalid index request buffer")
    } else {
        // SAFETY: checked non-null; the caller guarantees `length` readable bytes.
        let bytes = unsafe { std::slice::from_raw_parts(input, length) };
        match std::panic::catch_unwind(|| {
            serde_json::from_slice::<Value>(bytes).map(|r| api::call(&r))
        }) {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => failure(&format!("Invalid index request: {error}")),
            Err(_) => json!({"error": {"code": "DATABASE", "message": "Index call failed"}}),
        }
    };
    owned_buffer(serde_json::to_vec(&response).unwrap_or_default())
}

/// # Safety
/// `buffer` and `length` must come from one `gitrochi_index_call` result, released once.
#[no_mangle]
pub unsafe extern "C" fn gitrochi_index_free(buffer: *mut u8, length: usize) {
    if !buffer.is_null() {
        // SAFETY: the pointer and length describe the boxed slice made by owned_buffer.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer, length)) });
    }
}
