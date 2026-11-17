use super::*;
use std::collections::HashMap;

fn run(request: Value) -> Value {
    compute(request).unwrap()
}

#[test]
fn log_preserves_message_boundaries_and_unicode() {
    let out = run(
        json!({"op":"log","text":"a\u{1f}b c\u{1f}Author\u{1f}a@example.com\u{1f}42\u{1f}제목 🚀\u{1f}Co-Authored-By: Someone\n- 본문\u{1f}끝\u{1e}"}),
    );
    assert_eq!(out[0]["parents"], json!(["b", "c"]));
    assert_eq!(out[0]["body"], "본문\u{1f}끝");
    assert_eq!(out[0]["subject"], "제목 🚀");
}

#[test]
fn nul_paths_are_never_split_on_whitespace() {
    let path = "한글\n\t\"[x].txt";
    let status = run(
        json!({"op":"status","text":format!("# branch.head main\0# branch.ab +2 -3\02 R. N... 100644 100644 100644 a b R100 {path}\0old\nname\0? untracked\tfile\0")}),
    );
    assert_eq!(status["staged"][0]["path"], path);
    assert_eq!(status["staged"][0]["oldPath"], "old\nname");
    assert_eq!(status["ahead"], 2);
    assert_eq!(status["behind"], 3);
    let stat =
        run(json!({"op":"numstat","text":format!("3\t2\t\0old\0{path}\0-\t-\timage.png\0")}));
    assert_eq!(stat[path]["added"], 3);
    assert!(stat["image.png"]["added"].is_null());
}

#[test]
fn diff_markers_crlf_and_patch_application_contract() {
    let text="diff --git a/f b/f\nold mode 100644\nnew mode 100755\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\r\n+new\r\n\\ No newline at end of file\n";
    let doc = run(json!({"op":"diff","text":text}));
    assert_eq!(doc["lines"][2]["raw"], "new\r");
    let patch = run(json!({"op":"patch","doc":doc,"hunks":[0],"selected":null,"reverse":false}));
    assert_eq!(patch,"diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,1 +1,1 @@\n-old\r\n+new\r\n\\ No newline at end of file\n");
}

#[test]
fn partial_patch_cannot_include_another_file_or_truncation() {
    let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n";
    for request in [
        json!({"op":"diff","text":format!("{text}{text}")}),
        json!({"op":"diff","text":text,"maxLines":2}),
    ] {
        let doc = run(request);
        assert_eq!(
            run(json!({"op":"patch","doc":doc,"hunks":[0],"selected":null,"reverse":false})),
            Value::Null
        );
    }
}

#[test]
fn unicode_offsets_follow_each_ui_string_model() {
    let request = json!({"op":"wordRanges","a":"prefix 👨‍👩‍👧‍👦 old suffix","b":"prefix 👨‍👩‍👧‍👦 new suffix","scalarOffsets":false});
    let mut scalar = request.clone();
    scalar["scalarOffsets"] = json!(true);
    let grapheme = run(request);
    let scalar = run(scalar);
    assert_eq!(grapheme[0], json!([[9, 12]]));
    assert_eq!(scalar[0], json!([[15, 18]]));
}

#[test]
fn lcs_work_is_bounded_and_malformed_utf8_prefix_does_not_panic() {
    let s = "a ".repeat(500);
    assert_eq!(
        run(json!({"op":"wordRanges","a":s,"b":"a b"})),
        json!([[], []])
    );
    let doc = run(json!({"op":"diff","text":"@@@ -1,1 -1,1 +1,1 @@@\n가"}));
    assert_eq!(doc["combined"], true);
}

#[test]
fn conflicts_preserve_incomplete_blocks_and_marker_width() {
    for text in [
        "before\n<<<<<<< HEAD\nmine\n",
        "<<<<<<<not-a-marker\ntext\n",
    ] {
        let doc = run(json!({"op":"conflict","text":text}));
        assert_eq!(
            run(json!({"op":"resolveConflict","doc":doc,"choices":{}})),
            text
        );
    }
    let doc = run(
        json!({"op":"conflict","text":"<<<<<<<<<< HEAD\r\nmine\r\n|||||||||| base\r\nbase\r\n==========\r\ntheirs\r\n>>>>>>>>>> topic\r\n"}),
    );
    assert_eq!(doc["blocks"][0]["base"], json!(["base"]));
    assert_eq!(
        run(json!({"op":"resolveConflict","doc":doc,"choices":{"0":{"kind":"ours"}}})),
        "mine\r\n"
    );
}

#[test]
fn graph_has_deterministic_merge_lanes_and_wip_dashes() {
    let out = run(
        json!({"op":"graph","commits":[{"id":"__WORKING_TREE__","parents":["m"]},{"id":"m","parents":["a","b"]},{"id":"a","parents":["r"]},{"id":"b","parents":["r"]},{"id":"r","parents":[]}]}),
    );
    assert_eq!(out["rows"].as_array().unwrap().len(), 5);
    assert_eq!(out["maxLanes"], 2);
    assert_eq!(out["rows"][0]["segments"][0]["dashed"], true);
    assert!(out["rows"][4]["segments"]
        .as_array()
        .unwrap()
        .iter()
        .all(|s| s["y2"] == 0.5));
}

#[test]
fn ffi_owns_independent_buffers_under_concurrent_tabs() {
    let handles: Vec<_> = (0..8)
        .map(|n| {
            std::thread::spawn(move || {
                for _ in 0..20 {
                    let request = serde_json::to_vec(
                        &json!({"op":"bodyPreview","text":format!("- tab {n}")}),
                    )
                    .unwrap();
                    unsafe {
                        let output = gitrochi_compute(request.as_ptr(), request.len());
                        let len = u64::from_le_bytes(
                            std::slice::from_raw_parts(output, 8).try_into().unwrap(),
                        ) as usize;
                        let result: Value =
                            serde_json::from_slice(std::slice::from_raw_parts(output.add(8), len))
                                .unwrap();
                        assert_eq!(result["value"], format!("tab {n}"));
                        gitrochi_free(output, len + 8);
                    }
                }
            })
        })
        .collect();
    for handle in handles {
        handle.join().unwrap();
    }
}

#[test]
fn invalid_requests_are_reported_without_source_content() {
    let result: Value = serde_json::from_slice(&process(b"{\"op\":\"unknown\"}")).unwrap();
    assert!(result["error"]
        .as_str()
        .unwrap()
        .contains("Unknown core operation"));
    assert!(serde_json::from_slice::<Value>(&process(b"not json"))
        .unwrap()
        .get("error")
        .is_some());
}

#[test]
fn graph_records_keep_extensions_diagnostics_and_diff_cycles() {
    let text="1\ta\tfile\ta\tts\t\"analysis\":\"static-import\"\n2\ta\tb\timport\t1\th\t\"checked\":true\n0\tdiagnostic\t{\"file\":\"a\",\"line\":2}\n3\tnew\th\ta\u{1c}b\n";
    let meta = HashMap::from([
        ("rel".into(), "files".into()),
        ("diffbase".into(), "abc".into()),
    ]);
    let out = records::to_json(text, &meta).unwrap();
    assert_eq!(out["edges"][0]["checked"], true);
    assert_eq!(out["stats"]["heuristicEdges"], 1);
    assert_eq!(out["diagnostics"][0]["line"], 2);
    assert_eq!(out["cycles"]["new"][0]["nodes"], json!(["a", "b"]));
    assert!(records::to_json("1\ta\tfile\ta\tts\tinvalid", &meta).is_err());
}

#[test]
fn impact_uses_nearest_owner_per_ecosystem_and_base_dependencies() {
    let before =
        "1\tlib/deleted.ts\tfile\tdeleted.ts\tts\t\n2\tlib/use.ts\tlib/deleted.ts\timport\t1\t\t\n";
    let now = "1\tlib/use.ts\tfile\tuse.ts\tts\t\n";
    let modules="1\tnpm:root\tmodule\troot\tnpm\t\n1\tnpm:lib\tmodule\tlib\tnpm\t\n1\tother:root\tmodule\troot\tother\t\n4\tnpm:root\t.\n4\tnpm:lib\tlib\n4\tother:root\t.\n";
    let out = records::affected(records::ImpactInput {
        changed: "lib/deleted.ts\n",
        untracked: "",
        deleted: "lib/deleted.ts\n",
        before,
        before_modules: "",
        now,
        modules,
        base: "abc",
    });
    let summary = out
        .lines()
        .find_map(|l| l.strip_prefix("0\taffected\t"))
        .unwrap();
    let summary: Value = serde_json::from_str(summary).unwrap();
    assert_eq!(summary["files"], json!(["lib/deleted.ts", "lib/use.ts"]));
    assert_eq!(summary["modules"], json!(["npm:lib", "other:root"]));
    assert!(out.contains("D\tlib/deleted.ts\n"));
}

fn detail_of(message: &str, base: &str) -> Value {
    run(
        json!({"op":"detail","issueBase":base,"text":format!("a\u{1f}b\u{1f}Alex Kim\u{1f}alex@example.com\u{1f}1\u{1f}Alex Kim\u{1f}alex@example.com\u{1f}1\u{1f}{message}")}),
    )
}

#[test]
fn trailers_are_the_last_paragraph_and_leave_the_prose_whole() {
    let base = "https://github.com/o/r";
    let out = detail_of(
        "Subject\n\nThe list jumped.\n\n- one\n- two\n\nCloses #42\nCo-authored-by: Sam Lee <sam@example.com>\n",
        base,
    );
    assert_eq!(out["summary"], "Subject");
    assert_eq!(out["prose"], "The list jumped.\n\n- one\n- two");
    assert_eq!(
        out["body"],
        "The list jumped.\n\n- one\n- two\n\nCloses #42\nCo-authored-by: Sam Lee <sam@example.com>"
    );
    assert_eq!(
        out["trailers"],
        json!({"issues":[{"keyword":"closes","number":42}],"coAuthors":[{"name":"Sam Lee","email":"sam@example.com","line":"Co-authored-by: Sam Lee <sam@example.com>"}]})
    );

    // every verb form, a colon, several per line, this repository's own address, and one row per issue
    let out = detail_of(
        "S\n\nFIXED: #1, #2 and resolves #3\nclose https://GitHub.com/o/r/issues/4 #1\nResolved https://github.com/o/r/-/issues/5",
        base,
    );
    assert_eq!(
        out["trailers"]["issues"],
        json!([{"keyword":"fixes","number":1},{"keyword":"fixes","number":2},{"keyword":"resolves","number":3},{"keyword":"closes","number":4},{"keyword":"resolves","number":5}])
    );
    assert_eq!(out["prose"], "");

    // a reference in the prose, or in a paragraph that is not the last, is text
    for message in [
        "S\n\nCloses #3\n\nMore words after it.",
        "S\n\nThis closes #3 for good.",
        "S\n\nCloses #3 by reworking the list",
        "S\n\nWords first\nCloses #3",
        "S\n\nCloses and #3",
        "S\n\nCloses #3 and",
        "S\n\nCloses fixes #3",
    ] {
        let out = detail_of(message, base);
        assert_eq!(
            out["trailers"],
            json!({"issues":[],"coAuthors":[]}),
            "{message}"
        );
        assert_eq!(out["prose"], out["body"], "{message}");
    }

    // what is not recognised stays: other trailers, another repository's issue, a malformed co-author
    let out = detail_of(
        "S\n\nWords.\n\nCloses https://github.com/o/other/issues/9\nReviewed-by: Kim <kim@example.com>\nCo-authored-by: No Email\nCo-Authored-By: dependabot[bot] <bot@example.com>\nSigned-off-by: Alex Kim <alex@example.com>\ncloses #0\nFixes #7",
        base,
    );
    assert_eq!(
        out["trailers"]["issues"],
        json!([{"keyword":"fixes","number":7}])
    );
    assert_eq!(out["trailers"]["coAuthors"][0]["name"], "dependabot[bot]");
    assert_eq!(
        out["prose"],
        "Words.\n\nCloses https://github.com/o/other/issues/9\nReviewed-by: Kim <kim@example.com>\nCo-authored-by: No Email\nSigned-off-by: Alex Kim <alex@example.com>\ncloses #0"
    );

    // an address is an issue only when the repository's own is known
    let out = detail_of("S\n\nCloses https://github.com/o/r/issues/4", "");
    assert_eq!(out["trailers"]["issues"], json!([]));
    assert_eq!(out["prose"], "Closes https://github.com/o/r/issues/4");

    // the same co-author twice is one row; a folded trailer stays text; CRLF bodies read the same
    let out = detail_of(
        "S\r\n\r\nCo-authored-by: Sam Lee <sam@example.com>\r\nCo-authored-by: Sam <SAM@example.com>\r\nCo-authored-by: Pat Doe\r\n <pat@example.com>\r\n",
        base,
    );
    assert_eq!(out["trailers"]["coAuthors"].as_array().unwrap().len(), 1);
    assert_eq!(out["prose"], "Co-authored-by: Pat Doe\n <pat@example.com>");

    // a mixed last paragraph counts only beside a line written by the tool itself, with a quarter trailers
    let out = detail_of(
        "S\n\nBody.\n\nnot a trailer\nSigned-off-by: Alex Kim <alex@example.com>\nFixes #8",
        base,
    );
    assert_eq!(
        out["trailers"]["issues"],
        json!([{"keyword":"fixes","number":8}])
    );
    assert_eq!(
        out["prose"],
        "Body.\n\nnot a trailer\nSigned-off-by: Alex Kim <alex@example.com>"
    );

    // no body, and a body without trailers
    assert_eq!(detail_of("S", base)["prose"], "");
    assert_eq!(
        detail_of("S\n\nJust words.", base)["trailers"]["issues"],
        json!([])
    );
}
