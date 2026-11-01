//! Windows CI exercises the real security-descriptor and replacement APIs.
#![cfg(windows)]

mod common;

use serde_json::{json, Value};
use std::io::Write;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::process::Stdio;
use windows_sys::Win32::{
    Foundation::LocalFree,
    Security::{
        Authorization::{
            ConvertSecurityDescriptorToStringSecurityDescriptorW,
            ConvertStringSecurityDescriptorToSecurityDescriptorW, GetNamedSecurityInfoW,
            SetNamedSecurityInfoW, SE_FILE_OBJECT,
        },
        GetSecurityDescriptorDacl, DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION,
    },
};

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

fn restrict_to_owner(path: &Path) {
    let source = "D:P(A;;FA;;;OW)"
        .encode_utf16()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let mut descriptor = std::ptr::null_mut();
    unsafe {
        assert_ne!(
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                source.as_ptr(),
                1,
                &mut descriptor,
                std::ptr::null_mut()
            ),
            0
        );
        let mut present = 0;
        let mut defaulted = 0;
        let mut dacl = std::ptr::null_mut();
        assert_ne!(
            GetSecurityDescriptorDacl(descriptor, &mut present, &mut dacl, &mut defaulted),
            0
        );
        assert_ne!(present, 0);
        let result = SetNamedSecurityInfoW(
            wide(path).as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            dacl,
            std::ptr::null_mut(),
        );
        LocalFree(descriptor);
        assert_eq!(result, 0);
    }
}

fn access_text(path: &Path) -> String {
    let mut descriptor = std::ptr::null_mut();
    let mut text = std::ptr::null_mut();
    let mut length = 0;
    unsafe {
        assert_eq!(
            GetNamedSecurityInfoW(
                wide(path).as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut descriptor
            ),
            0
        );
        let result = ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor,
            1,
            DACL_SECURITY_INFORMATION,
            &mut text,
            &mut length,
        );
        assert_ne!(result, 0);
        let value = String::from_utf16_lossy(std::slice::from_raw_parts(text, length as usize))
            .trim_end_matches('\0')
            .to_owned();
        LocalFree(text.cast());
        LocalFree(descriptor);
        value
    }
}

fn source(fx: &common::Fx, request: Value) -> Value {
    let mut child = fx
        .cmd("script", &["design", "source", "--json", "--lang", "en"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(request.to_string().as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn restricted_dacl_is_preserved_when_related_source_is_replaced() {
    let fx = common::Fx::new(&[("private-source.txt", "original\r\n")]);
    let path = fx.repo().join("private-source.txt");
    restrict_to_owner(&path);
    let before = access_text(&path);
    let opened = source(&fx, json!({"operation":"read","path":"private-source.txt"}));
    assert_eq!(opened["content"], "original\r\n", "{opened}");
    let saved = source(
        &fx,
        json!({"operation":"write","path":"private-source.txt","content":"edited\r\n","expected":opened["fingerprint"]}),
    );
    assert_eq!(saved["saved"], true, "{saved}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "edited\r\n");
    assert_eq!(access_text(&path), before);
    assert!(std::fs::read_dir(fx.repo()).unwrap().all(|entry| !entry
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with(".gitrochi-source-")));
}
