//! Kernel peer identity plus Security.framework code validation.
//!
//! Primary references: Apple's SecCodeCopyGuestWithAttributes,
//! SecCodeCopyDesignatedRequirement, SecCodeCheckValidity and
//! SecStaticCodeCheckValidity documentation and the macOS SDK SecCode.h,
//! SecStaticCode.h, bsm/libbsm.h and sys/un.h headers. An audit token includes
//! the process incarnation, so PID reuse cannot authenticate another process.
//!
//! https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:)
//! https://developer.apple.com/documentation/security/seccodecheckvalidity(_:_:_:)
//! https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:)

use std::{
    ffi::{CStr, c_void},
    fs,
    os::{
        fd::AsRawFd,
        unix::{ffi::OsStrExt, net::UnixStream},
    },
    path::{Path, PathBuf},
    ptr,
};

type CFRef = *const c_void;

#[derive(Debug, PartialEq)]
enum SigningAuthority {
    AdHoc,
    Team(String),
}

struct OwnedCF(CFRef);
impl OwnedCF {
    fn new(value: CFRef) -> Result<Self, &'static str> {
        if value.is_null() {
            Err("APP_IDENTITY_REJECTED")
        } else {
            Ok(Self(value))
        }
    }
}
impl Drop for OwnedCF {
    fn drop(&mut self) {
        // SAFETY: OwnedCF only wraps a retained non-null result of a CF Create/Copy call.
        unsafe {
            CFRelease(self.0);
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct AuditToken {
    values: [u32; 8],
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: CFRef);
    fn CFGetTypeID(value: CFRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFDictionaryGetValue(dictionary: CFRef, key: CFRef) -> CFRef;
    fn CFStringGetCString(string: CFRef, buffer: *mut i8, size: isize, encoding: u32) -> u8;
    fn CFNumberGetValue(number: CFRef, number_type: isize, value: *mut c_void) -> u8;
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: CFRef,
        bytes: *const u8,
        length: isize,
        is_directory: u8,
    ) -> CFRef;
    fn CFDataCreate(allocator: CFRef, bytes: *const u8, length: isize) -> CFRef;
    fn CFDictionaryCreate(
        allocator: CFRef,
        keys: *const CFRef,
        values: *const CFRef,
        count: isize,
        key_callbacks: CFRef,
        value_callbacks: CFRef,
    ) -> CFRef;
}

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecGuestAttributeAudit: CFRef;
    static kSecCodeInfoTeamIdentifier: CFRef;
    static kSecCodeInfoFlags: CFRef;
    fn SecCodeCopySelf(flags: u32, code: *mut CFRef) -> i32;
    fn SecCodeCopySigningInformation(code: CFRef, flags: u32, information: *mut CFRef) -> i32;
    fn SecStaticCodeCreateWithPath(path: CFRef, flags: u32, code: *mut CFRef) -> i32;
    fn SecStaticCodeCheckValidity(code: CFRef, flags: u32, requirement: CFRef) -> i32;
    fn SecCodeCopyDesignatedRequirement(code: CFRef, flags: u32, requirement: *mut CFRef) -> i32;
    fn SecCodeCopyGuestWithAttributes(
        host: CFRef,
        attributes: CFRef,
        flags: u32,
        code: *mut CFRef,
    ) -> i32;
    fn SecCodeCheckValidity(code: CFRef, flags: u32, requirement: CFRef) -> i32;
}

#[link(name = "bsm")]
unsafe extern "C" {
    fn audit_token_to_pid(token: AuditToken) -> libc::pid_t;
    fn audit_token_to_euid(token: AuditToken) -> libc::uid_t;
}

unsafe extern "C" {
    fn proc_pidpath(pid: libc::pid_t, buffer: *mut c_void, size: u32) -> i32;
}

fn status(code: i32) -> Result<(), &'static str> {
    if code == 0 {
        Ok(())
    } else {
        Err("APP_IDENTITY_REJECTED")
    }
}

fn signing_authority(code: CFRef) -> Result<SigningAuthority, &'static str> {
    // SAFETY: code is a live SecCode/SecStaticCode from the caller. Dictionary
    // values are borrowed only while the retained dictionary remains alive.
    unsafe {
        let mut information = ptr::null();
        status(SecCodeCopySigningInformation(
            code,
            1 << 1,
            &mut information,
        ))?;
        let information = OwnedCF::new(information)?;
        let team = CFDictionaryGetValue(information.0, kSecCodeInfoTeamIdentifier);
        if !team.is_null() {
            if CFGetTypeID(team) != CFStringGetTypeID() {
                return Err("APP_IDENTITY_REJECTED");
            }
            let mut bytes = [0_i8; 128];
            if CFStringGetCString(team, bytes.as_mut_ptr(), bytes.len() as isize, 0x08000100) == 0 {
                return Err("APP_IDENTITY_REJECTED");
            }
            let team = CStr::from_ptr(bytes.as_ptr())
                .to_str()
                .map_err(|_| "APP_IDENTITY_REJECTED")?;
            if team.is_empty() {
                return Err("APP_IDENTITY_REJECTED");
            }
            return Ok(SigningAuthority::Team(team.to_owned()));
        }
        let flags = CFDictionaryGetValue(information.0, kSecCodeInfoFlags);
        let mut value = 0_i64;
        if flags.is_null()
            || CFGetTypeID(flags) != CFNumberGetTypeID()
            || CFNumberGetValue(flags, 4, (&mut value as *mut i64).cast()) == 0
            || value & 2 == 0
        {
            return Err("APP_IDENTITY_REJECTED");
        }
        Ok(SigningAuthority::AdHoc)
    }
}

fn executable_path(pid: libc::pid_t) -> Result<PathBuf, &'static str> {
    let mut path = [0_u8; 4096]; // PROC_PIDPATHINFO_MAXSIZE from sys/proc_info.h.
    // SAFETY: path points to a writable buffer of the declared size; the kernel
    // supplies the executable path for the PID obtained from the connected socket.
    let length = unsafe { proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
    if length <= 0 || length as usize >= path.len() {
        return Err("APP_IDENTITY_REJECTED");
    }
    let path = CStr::from_bytes_until_nul(&path).map_err(|_| "APP_IDENTITY_REJECTED")?;
    fs::canonicalize(Path::new(std::ffi::OsStr::from_bytes(path.to_bytes())))
        .map_err(|_| "APP_IDENTITY_REJECTED")
}

pub(super) fn verify_peer(
    stream: &UnixStream,
    app: &Path,
    main_executable: &Path,
) -> Result<(), &'static str> {
    let fd = stream.as_raw_fd();
    let mut uid = 0;
    let mut gid = 0;
    let mut pid: libc::pid_t = 0;
    let mut pid_length = size_of::<libc::pid_t>() as libc::socklen_t;
    let mut token = AuditToken::default();
    let mut token_length = size_of::<AuditToken>() as libc::socklen_t;
    // SAFETY: all pointers refer to live correctly sized output values and fd is
    // borrowed from a live connected UnixStream. Constants are from sys/un.h.
    unsafe {
        status(libc::getpeereid(fd, &mut uid, &mut gid))?;
        status(libc::getsockopt(
            fd,
            0,
            0x002,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut pid_length,
        ))?;
        status(libc::getsockopt(
            fd,
            0,
            0x006,
            (&mut token as *mut AuditToken).cast(),
            &mut token_length,
        ))?;
        if uid != libc::geteuid()
            || pid <= 0
            || pid_length as usize != size_of::<libc::pid_t>()
            || token_length as usize != size_of::<AuditToken>()
            || audit_token_to_pid(token) != pid
            || audit_token_to_euid(token) != uid
        {
            return Err("APP_IDENTITY_REJECTED");
        }
    }
    let expected = fs::canonicalize(main_executable).map_err(|_| "APP_IDENTITY_REJECTED")?;
    if executable_path(pid)? != expected {
        return Err("APP_IDENTITY_REJECTED");
    }
    let app_bytes = app.as_os_str().as_bytes();
    // SAFETY: byte slices and CF objects stay alive through each synchronous call.
    // The dictionary uses non-retaining callbacks; its sole key is a framework
    // constant and its value is retained in `audit_data` for the entire lookup.
    // No CF object crosses a thread boundary, and each Create/Copy is released.
    unsafe {
        let url = OwnedCF::new(CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            app_bytes.as_ptr(),
            app_bytes.len() as isize,
            1,
        ))?;
        let mut static_code = ptr::null();
        status(SecStaticCodeCreateWithPath(url.0, 0, &mut static_code))?;
        let static_code = OwnedCF::new(static_code)?;
        // Strict resource sealing plus nested-code checking. Do not set
        // kSecCSAllowNetworkAccess: peer checks must remain local and bounded.
        status(SecStaticCodeCheckValidity(
            static_code.0,
            (1 << 4) | (1 << 3),
            ptr::null(),
        ))?;
        let mut own_code = ptr::null();
        status(SecCodeCopySelf(0, &mut own_code))?;
        let own_code = OwnedCF::new(own_code)?;
        status(SecCodeCheckValidity(own_code.0, 0, ptr::null()))?;
        // A Team-signed helper cannot be transplanted into an ad-hoc or a
        // different-Team App to downgrade the trust anchor. Local diagnostics
        // allow ad-hoc only when both the running helper and parent are ad-hoc.
        if signing_authority(own_code.0)? != signing_authority(static_code.0)? {
            return Err("APP_IDENTITY_REJECTED");
        }
        let mut requirement = ptr::null();
        status(SecCodeCopyDesignatedRequirement(
            static_code.0,
            0,
            &mut requirement,
        ))?;
        let requirement = OwnedCF::new(requirement)?;
        // For ad-hoc Local builds this derives the App's code hash requirement;
        // Team-signed builds derive the actual signing authority requirement.
        let audit_data = OwnedCF::new(CFDataCreate(
            ptr::null(),
            (&token as *const AuditToken).cast(),
            size_of::<AuditToken>() as isize,
        ))?;
        let keys = [kSecGuestAttributeAudit];
        let values = [audit_data.0];
        let attributes = OwnedCF::new(CFDictionaryCreate(
            ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            1,
            ptr::null(),
            ptr::null(),
        ))?;
        let mut dynamic_code = ptr::null();
        status(SecCodeCopyGuestWithAttributes(
            ptr::null(),
            attributes.0,
            0,
            &mut dynamic_code,
        ))?;
        let dynamic_code = OwnedCF::new(dynamic_code)?;
        status(SecCodeCheckValidity(dynamic_code.0, 0, requirement.0))?;
    }
    if executable_path(pid)? != expected {
        return Err("APP_IDENTITY_REJECTED");
    }
    Ok(())
}
