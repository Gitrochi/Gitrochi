use std::env;
use std::path::PathBuf;

// Compiles the C++ tokenizer (native/) against the bundled SQLite's header. The objects
// need no C++ runtime (native/build.sh checks that), so no C++ standard library is linked.
fn main() {
    if env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("wasm32") {
        return;
    }
    let native = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../native");
    for file in [
        "include/gitrochi_text.h",
        "src/tokenizer.cpp",
        "src/fts5.cpp",
    ] {
        println!("cargo:rerun-if-changed={}", native.join(file).display());
    }
    let sqlite = env::var("DEP_SQLITE3_INCLUDE")
        .expect("libsqlite3-sys (bundled) provides DEP_SQLITE3_INCLUDE");
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .cpp_link_stdlib(None)
        .flag_if_supported("-fno-exceptions")
        .flag_if_supported("-fno-rtti")
        .warnings(true)
        .include(native.join("include"))
        .include(sqlite)
        .file(native.join("src/tokenizer.cpp"))
        .file(native.join("src/fts5.cpp"))
        .compile("gitrochi_text");
}
