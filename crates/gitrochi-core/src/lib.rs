//! OS·UI·Git 쓰기를 모르는 계산 코어. 네이티브 앱과 WebAssembly에서 같은 구현을 쓴다.
mod conflict;
mod diff;
mod graph;
mod parsers;
pub mod records;

#[cfg(test)]
mod tests;

use serde::de::DeserializeOwned;
use serde_json::{json, Value};

fn field<T: DeserializeOwned>(v: &Value, key: &str) -> Result<T, String> {
    serde_json::from_value(
        v.get(key)
            .cloned()
            .ok_or_else(|| format!("Missing {key}"))?,
    )
    .map_err(|e| e.to_string())
}

pub fn compute(request: Value) -> Result<Value, String> {
    let op = request["op"].as_str().ok_or("Missing operation")?;
    let text = request["text"].as_str().unwrap_or("");
    let max = request["maxLines"]
        .as_u64()
        .unwrap_or(20_000)
        .min(1_000_000) as usize;
    let scalar = request["scalarOffsets"].as_bool().unwrap_or(true);
    Ok(match op {
        "log" => parsers::log(text),
        "bodyPreview" => json!(parsers::body_preview(text)),
        "detail" => parsers::detail(text),
        "track" => parsers::track(text),
        "refs" => parsers::refs(text),
        "stashes" => parsers::stashes(text),
        "remotes" => parsers::remotes(text),
        "worktrees" => parsers::worktrees(text),
        "status" => parsers::status(text),
        "nameStatus" => parsers::name_status(text),
        "numstat" => parsers::numstat(text),
        "fileHistory" => parsers::file_history(text),
        "blame" => parsers::blame(text),
        "graph" => serde_json::to_value(graph::layout(&field::<Vec<graph::Commit>>(
            &request, "commits",
        )?))
        .map_err(|e| e.to_string())?,
        "diff" => {
            serde_json::to_value(diff::parse(text, max, scalar)).map_err(|e| e.to_string())?
        }
        "diffBundle" => {
            let doc = diff::parse(text, max, scalar);
            json!({"rows":diff::split_rows(&doc.lines),"sides":{"old":doc.lines.iter().any(|l|l.old_no.is_some()),"new":doc.lines.iter().any(|l|l.new_no.is_some())},"doc":doc})
        }
        "newFile" => serde_json::to_value(diff::new_file(
            text,
            request["truncated"].as_bool().unwrap_or(false),
            max,
        ))
        .map_err(|e| e.to_string())?,
        "tokens" => json!(diff::tokens(text)),
        "wordRanges" => json!(diff::ranges(
            request["a"].as_str().unwrap_or(""),
            request["b"].as_str().unwrap_or(""),
            scalar
        )),
        "markWords" => {
            let mut lines = field::<Vec<diff::Line>>(&request, "lines")?;
            diff::mark(&mut lines, scalar);
            json!(lines)
        }
        "splitRows" => json!(diff::split_rows(&field::<Vec<diff::Line>>(
            &request, "lines"
        )?)),
        "canEdit" => json!(diff::can_edit(&field::<diff::Document>(&request, "doc")?)),
        "patch" => json!(diff::patch(
            &field::<diff::Document>(&request, "doc")?,
            &field::<Vec<usize>>(&request, "hunks")?,
            field::<Option<Vec<usize>>>(&request, "selected")?.as_deref(),
            request["reverse"].as_bool().unwrap_or(false)
        )),
        "conflict" => json!(conflict::parse(text)),
        "resolveConflict" => json!(conflict::resolve(
            &field(&request, "doc")?,
            &field(&request, "choices")?
        )),
        _ => return Err(format!("Unknown core operation: {op}")),
    })
}

/// CLI와 FFI는 같은 오류 계약을 쓴다. 저장소 내용이나 비밀값을 진단에 복사하지 않는다.
pub fn process(bytes: &[u8]) -> Vec<u8> {
    let result = std::panic::catch_unwind(|| {
        serde_json::from_slice(bytes)
            .map_err(|e| format!("Invalid core request: {e}"))
            .and_then(compute)
    });
    let value = match result {
        Ok(Ok(value)) => json!({"value":value}),
        Ok(Err(error)) => json!({"error":error}),
        Err(_) => json!({"error":"Core calculation failed"}),
    };
    serde_json::to_vec(&value).expect("JSON value serializes")
}

/// WebAssembly 입력 버퍼. 호출자가 반환한 포인터·길이 그대로 free에 넘긴다.
#[no_mangle]
pub extern "C" fn gitrochi_alloc(len: usize) -> *mut u8 {
    Box::into_raw(vec![0u8; len].into_boxed_slice()) as *mut u8
}

/// 결과는 8바이트 little-endian 본문 길이와 UTF-8 JSON. 전역 결과 버퍼가 없어 동시 호출도 독립적이다.
///
/// # Safety
/// ptr은 len 바이트 이상 읽을 수 있어야 하며, 반환된 버퍼는 gitrochi_free로 한 번만 해제한다.
#[no_mangle]
pub unsafe extern "C" fn gitrochi_compute(ptr: *const u8, len: usize) -> *mut u8 {
    let result = if ptr.is_null() || len > 128 * 1024 * 1024 {
        br#"{"error":"Invalid core input buffer"}"#.to_vec()
    } else {
        process(unsafe { std::slice::from_raw_parts(ptr, len) })
    };
    owned_buffer(result)
}

fn owned_buffer(result: Vec<u8>) -> *mut u8 {
    let mut buffer = Vec::with_capacity(8 + result.len());
    buffer.extend_from_slice(&(result.len() as u64).to_le_bytes());
    buffer.extend_from_slice(&result);
    Box::into_raw(buffer.into_boxed_slice()) as *mut u8
}

/// # Safety
/// 입력은 compact 그래프 계약에 맞는 len 바이트의 버퍼다. 결과는 compute와 같은 방식으로 해제한다.
#[no_mangle]
pub unsafe extern "C" fn gitrochi_graph(ptr: *const u8, len: usize) -> *mut u8 {
    if ptr.is_null() || len > 128 * 1024 * 1024 {
        return owned_buffer(vec![]);
    }
    let result = std::panic::catch_unwind(|| {
        graph::compact(unsafe { std::slice::from_raw_parts(ptr, len) })
    });
    owned_buffer(result.ok().and_then(Result::ok).unwrap_or_default())
}

/// # Safety
/// ptr·len은 alloc의 결과 또는 compute의 결과와 그 전체 길이여야 한다. 해제 후 다시 쓰면 안 된다.
#[no_mangle]
pub unsafe extern "C" fn gitrochi_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}
