//! Access-control metadata is copied before a replacement receives any source bytes.

use super::Result;
use std::fs::File;

#[cfg(windows)]
#[path = "design_source_windows.rs"]
mod platform;

pub(super) struct Access {
    saved: Option<platform::Access>,
    #[cfg(unix)]
    ownership: Option<(u32, u32)>,
}

impl Access {
    pub(super) fn capture(file: &File) -> Self {
        Self {
            saved: platform::Access::capture(file).ok(),
            #[cfg(unix)]
            ownership: {
                use std::os::unix::fs::MetadataExt;
                file.metadata()
                    .ok()
                    .map(|metadata| (metadata.uid(), metadata.gid()))
            },
        }
    }

    pub(super) fn protect(&self, file: &File) -> Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let ownership = file
                .metadata()
                .ok()
                .map(|metadata| (metadata.uid(), metadata.gid()));
            if self.ownership.is_none() || ownership != self.ownership {
                return Err(("SOURCE_METADATA", "This file's access permissions could not be preserved. Its existing contents were kept."));
            }
        }
        if self
            .saved
            .as_ref()
            .is_some_and(|saved| saved.protect(file).is_ok())
        {
            return Ok(());
        }
        Err(("SOURCE_METADATA", "This file's access permissions could not be preserved. Its existing contents were kept."))
    }
}

#[cfg(target_vendor = "apple")]
mod platform {
    use std::ffi::c_void;
    use std::fs::File;
    use std::os::fd::AsRawFd;

    unsafe extern "C" {
        fn acl_init(count: libc::c_int) -> *mut c_void;
        fn acl_get_fd_np(fd: libc::c_int, acl_type: libc::c_int) -> *mut c_void;
        fn acl_set_fd_np(fd: libc::c_int, acl: *mut c_void, acl_type: libc::c_int) -> libc::c_int;
        fn acl_free(acl: *mut c_void) -> libc::c_int;
    }

    pub(super) struct Access(*mut c_void);
    impl Access {
        pub(super) fn capture(file: &File) -> std::io::Result<Self> {
            let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), 0x100) };
            if !acl.is_null() {
                return Ok(Self(acl));
            }
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ENOENT) {
                let empty = unsafe { acl_init(0) };
                return if empty.is_null() {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(Self(empty))
                };
            }
            if error.raw_os_error() == Some(libc::EOPNOTSUPP) {
                Ok(Self(std::ptr::null_mut()))
            } else {
                Err(error)
            }
        }
        pub(super) fn protect(&self, file: &File) -> std::io::Result<()> {
            if self.0.is_null() || unsafe { acl_set_fd_np(file.as_raw_fd(), self.0, 0x100) } == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        }
    }
    impl Drop for Access {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    acl_free(self.0);
                }
            }
        }
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use std::fs::File;
    use std::os::fd::AsRawFd;

    pub(super) struct Access(Option<Vec<u8>>);
    fn attribute(file: &File, name: &std::ffi::CStr) -> std::io::Result<Option<Vec<u8>>> {
        let size =
            unsafe { libc::fgetxattr(file.as_raw_fd(), name.as_ptr(), std::ptr::null_mut(), 0) };
        if size < 0 {
            let error = std::io::Error::last_os_error();
            return if [Some(libc::ENODATA), Some(libc::ENOTSUP)].contains(&error.raw_os_error()) {
                Ok(None)
            } else {
                Err(error)
            };
        }
        if size > 65536 {
            return Err(std::io::ErrorKind::Unsupported.into());
        }
        let mut data = vec![0u8; size as usize];
        let read = unsafe {
            libc::fgetxattr(
                file.as_raw_fd(),
                name.as_ptr(),
                data.as_mut_ptr().cast(),
                data.len(),
            )
        };
        if read != size {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Some(data))
    }
    impl Access {
        pub(super) fn capture(file: &File) -> std::io::Result<Self> {
            if attribute(file, c"system.nfs4_acl")?.is_some() {
                return Err(std::io::ErrorKind::Unsupported.into());
            }
            attribute(file, c"system.posix_acl_access").map(Self)
        }
        pub(super) fn protect(&self, file: &File) -> std::io::Result<()> {
            let result = unsafe {
                if let Some(data) = &self.0 {
                    libc::fsetxattr(
                        file.as_raw_fd(),
                        c"system.posix_acl_access".as_ptr(),
                        data.as_ptr().cast(),
                        data.len(),
                        0,
                    )
                } else {
                    libc::fremovexattr(file.as_raw_fd(), c"system.posix_acl_access".as_ptr())
                }
            };
            if result == 0 {
                return Ok(());
            }
            let error = std::io::Error::last_os_error();
            if self.0.is_none()
                && [Some(libc::ENODATA), Some(libc::ENOTSUP)].contains(&error.raw_os_error())
            {
                Ok(())
            } else {
                Err(error)
            }
        }
    }
}

#[cfg(not(any(windows, target_vendor = "apple", target_os = "linux")))]
mod platform {
    pub(super) struct Access;
    impl Access {
        pub(super) fn capture(_: &std::fs::File) -> std::io::Result<Self> {
            Err(std::io::ErrorKind::Unsupported.into())
        }
        pub(super) fn protect(&self, _: &std::fs::File) -> std::io::Result<()> {
            Err(std::io::ErrorKind::Unsupported.into())
        }
    }
}

#[cfg(windows)]
pub(super) fn replace(
    path: &std::path::Path,
    temporary: &std::path::Path,
) -> std::io::Result<Option<String>> {
    platform::replace(path, temporary)
}

#[cfg(all(test, unix))]
mod tests {
    use super::Access;
    use std::os::unix::fs::MetadataExt;

    #[test]
    fn changed_owner_or_group_is_refused_without_modifying_the_replacement() {
        let path =
            std::env::temp_dir().join(format!("gitch-source-owner-{}", crate::util::random_hex(8)));
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        let metadata = file.metadata().unwrap();
        let mut access = Access::capture(&file);
        for ownership in [
            (metadata.uid().wrapping_add(1), metadata.gid()),
            (metadata.uid(), metadata.gid().wrapping_add(1)),
        ] {
            access.ownership = Some(ownership);
            assert_eq!(access.protect(&file).unwrap_err().0, "SOURCE_METADATA");
            let current = file.metadata().unwrap();
            assert_eq!(
                (current.uid(), current.gid(), current.len()),
                (metadata.uid(), metadata.gid(), 0)
            );
        }
        drop(file);
        std::fs::remove_file(path).unwrap();
    }
}
