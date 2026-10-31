//! C ABI for the macOS app (`include/gitrochi_ledger.h`): a method name and a JSON object
//! in, a JSON string out, released with `gitrochi_ledger_free`. The caller is the app.

use crate::api;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};

fn failure(code: &str, message: &str) -> Value {
    json!({"error": {"code": code, "message": message}})
}

fn into_c(value: &Value) -> *mut c_char {
    // serde_json escapes NUL inside strings, so the text never contains one.
    let text = serde_json::to_string(value).unwrap_or_else(|_| "{}".into());
    CString::new(text)
        .unwrap_or_else(|_| CString::new("{}").expect("no NUL"))
        .into_raw()
}

/// Runs `method` with the JSON object `json` (NULL means `{}`) and returns the result, or
/// `{"error": {"code", "message"}}`. Never returns NULL. Safe from several threads.
///
/// # Safety
/// `method` and `json` must be NULL or point to NUL-terminated strings. Release the result
/// exactly once with `gitrochi_ledger_free`.
#[no_mangle]
pub unsafe extern "C" fn gitrochi_ledger_call(
    method: *const c_char,
    json: *const c_char,
) -> *mut c_char {
    if method.is_null() {
        return into_c(&failure("INVALID_ARGUMENT", "Missing method"));
    }
    // SAFETY: checked non-null; the caller guarantees a NUL-terminated string.
    let method = match unsafe { CStr::from_ptr(method) }.to_str() {
        Ok(method) => method.to_string(),
        Err(_) => return into_c(&failure("INVALID_ARGUMENT", "The method is not UTF-8")),
    };
    let args = if json.is_null() {
        json!({})
    } else {
        // SAFETY: as above.
        let bytes = unsafe { CStr::from_ptr(json) }.to_bytes();
        match serde_json::from_slice::<Value>(bytes) {
            Ok(value) => value,
            Err(error) => {
                return into_c(&failure(
                    "INVALID_ARGUMENT",
                    &format!("The arguments are not JSON: {error}"),
                ))
            }
        }
    };
    let response = std::panic::catch_unwind(|| api::call(&method, &args))
        .unwrap_or_else(|_| failure("DATABASE", "The ledger call failed unexpectedly"));
    into_c(&response)
}

/// Releases a string returned by `gitrochi_ledger_call`. NULL is ignored.
///
/// # Safety
/// `result` must come from `gitrochi_ledger_call` and not have been released before.
#[no_mangle]
pub unsafe extern "C" fn gitrochi_ledger_free(result: *mut c_char) {
    if !result.is_null() {
        // SAFETY: the pointer was made by CString::into_raw in gitrochi_ledger_call.
        drop(unsafe { CString::from_raw(result) });
    }
}
