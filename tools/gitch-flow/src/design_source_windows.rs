//! Windows replacements retain the source DACL and use the operating system's metadata-preserving replace API.

use std::fs::File;
use std::os::windows::{ffi::OsStrExt, io::AsRawHandle};
use std::path::Path;
use windows_sys::Win32::{
    Foundation::LocalFree,
    Security::{
        Authorization::{GetSecurityInfo, SetSecurityInfo, SE_FILE_OBJECT},
        EqualSid, ACL, DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION,
        PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR,
    },
    Storage::FileSystem::ReplaceFileW,
};

pub(super) struct Access {
    descriptor: PSECURITY_DESCRIPTOR,
    dacl: *mut ACL,
    owner: *mut std::ffi::c_void,
}
impl Access {
    pub(super) fn capture(file: &File) -> std::io::Result<Self> {
        let mut descriptor = std::ptr::null_mut();
        let mut dacl = std::ptr::null_mut();
        let mut owner = std::ptr::null_mut();
        let status = unsafe {
            GetSecurityInfo(
                file.as_raw_handle(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | OWNER_SECURITY_INFORMATION,
                &mut owner,
                std::ptr::null_mut(),
                &mut dacl,
                std::ptr::null_mut(),
                &mut descriptor,
            )
        };
        if status == 0 && !descriptor.is_null() && !owner.is_null() {
            Ok(Self {
                descriptor,
                dacl,
                owner,
            })
        } else {
            Err(std::io::Error::from_raw_os_error(status as i32))
        }
    }
    pub(super) fn protect(&self, file: &File) -> std::io::Result<()> {
        let mut descriptor = std::ptr::null_mut();
        let mut owner = std::ptr::null_mut();
        let status = unsafe {
            GetSecurityInfo(
                file.as_raw_handle(),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION,
                &mut owner,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut descriptor,
            )
        };
        let same_owner =
            status == 0 && !owner.is_null() && unsafe { EqualSid(owner, self.owner) } != 0;
        if !descriptor.is_null() {
            unsafe {
                LocalFree(descriptor);
            }
        }
        if !same_owner {
            return Err(std::io::ErrorKind::PermissionDenied.into());
        }
        // Protection prevents the temporary name from inheriting broader parent permissions.
        let status = unsafe {
            SetSecurityInfo(
                file.as_raw_handle(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                self.dacl,
                std::ptr::null_mut(),
            )
        };
        if status == 0 {
            Ok(())
        } else {
            Err(std::io::Error::from_raw_os_error(status as i32))
        }
    }
}
impl Drop for Access {
    fn drop(&mut self) {
        if !self.descriptor.is_null() {
            unsafe {
                LocalFree(self.descriptor);
            }
        }
    }
}

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

/// A failure that leaves a recovery copy returns its path instead of deleting original data.
pub(super) fn replace(path: &Path, temporary: &Path) -> std::io::Result<Option<String>> {
    let backup = temporary.with_extension("recovery");
    if backup.try_exists()? {
        return Err(std::io::ErrorKind::AlreadyExists.into());
    }
    let result = unsafe {
        ReplaceFileW(
            wide(path).as_ptr(),
            wide(temporary).as_ptr(),
            wide(&backup).as_ptr(),
            0,
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    if result != 0 {
        return if std::fs::remove_file(&backup).is_ok() {
            Ok(None)
        } else {
            Ok(Some(
                backup.file_name().unwrap().to_string_lossy().into_owned(),
            ))
        };
    }
    let error = std::io::Error::last_os_error();
    if backup.exists() {
        // The exclusive link restores a missing name without replacing any concurrent writer.
        if !path.exists() && std::fs::hard_link(&backup, path).is_ok() {
            let _ = std::fs::remove_file(&backup);
        } else {
            return Ok(Some(
                backup.file_name().unwrap().to_string_lossy().into_owned(),
            ));
        }
    }
    Err(error)
}
