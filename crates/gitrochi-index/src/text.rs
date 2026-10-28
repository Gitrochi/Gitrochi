//! Rust side of the C++ tokenizer in native/: registration on SQLite connections and
//! direct tokenizing, so query terms are checked with exactly the indexed rules.

use rusqlite::Connection;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_void};

const QUERY: c_int = 1;
const DOCUMENT: c_int = 0;
const COLOCATED: c_int = 1;
// The tokenizer takes an int length; longer text is cut at a character boundary.
const MAX_TEXT: usize = 1 << 30;

type Emit = extern "C" fn(*mut c_void, c_int, *const c_char, c_int, c_int, c_int) -> c_int;

extern "C" {
    fn gitrochi_tokenize(
        text: *const c_char,
        length: c_int,
        mode: c_int,
        context: *mut c_void,
        emit: Emit,
    ) -> c_int;
    fn gitrochi_fts5_register(db: *mut rusqlite::ffi::sqlite3) -> c_int;
    fn gitrochi_text_version() -> *const c_char;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    pub text: String,
    pub start: usize,
    pub end: usize,
    pub colocated: bool,
}

extern "C" fn collect(
    context: *mut c_void,
    flags: c_int,
    token: *const c_char,
    length: c_int,
    start: c_int,
    end: c_int,
) -> c_int {
    // SAFETY: context is the Vec passed by `tokenize`, alive for the whole call, and
    // token points at `length` bytes the tokenizer owns until we return.
    let tokens = unsafe { &mut *(context as *mut Vec<Token>) };
    let bytes = unsafe { std::slice::from_raw_parts(token as *const u8, length.max(0) as usize) };
    tokens.push(Token {
        text: String::from_utf8_lossy(bytes).into_owned(),
        start: start.max(0) as usize,
        end: end.max(0) as usize,
        colocated: flags & COLOCATED != 0,
    });
    0
}

/// Splits text the way the FTS tables index it (`query`: the rules used for searches).
pub fn tokenize(text: &str, query: bool) -> Vec<Token> {
    let mut end = text.len().min(MAX_TEXT);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let mut tokens = Vec::new();
    // SAFETY: the pointer and length describe valid UTF-8 for the duration of the call,
    // and `collect` only touches the Vec behind the context pointer.
    unsafe {
        gitrochi_tokenize(
            text.as_ptr() as *const c_char,
            end as c_int,
            if query { QUERY } else { DOCUMENT },
            &mut tokens as *mut Vec<Token> as *mut c_void,
            collect,
        );
    }
    tokens
}

/// Makes the `gitrochi` tokenizer available to FTS5 tables on this connection.
pub fn register(connection: &Connection) -> rusqlite::Result<()> {
    // SAFETY: the handle stays valid while `connection` is borrowed; the C++ side only
    // prepares one statement and registers the tokenizer on it.
    let rc = unsafe { gitrochi_fts5_register(connection.handle()) };
    if rc == rusqlite::ffi::SQLITE_OK {
        Ok(())
    } else {
        Err(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rc),
            Some("Could not register the gitrochi tokenizer".into()),
        ))
    }
}

pub fn version() -> String {
    // SAFETY: the C++ side returns a static NUL-terminated string.
    unsafe { CStr::from_ptr(gitrochi_text_version()) }
        .to_string_lossy()
        .into_owned()
}
