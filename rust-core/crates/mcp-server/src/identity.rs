use crate::{cli::bundle_for_executable, ipc::Connector};
use std::{
    fs,
    os::unix::fs::{FileTypeExt, MetadataExt},
    path::{Path, PathBuf},
};

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos::verify_peer;

pub(crate) struct AppConnector {
    socket: PathBuf,
    app: PathBuf,
    main_executable: PathBuf,
}

impl AppConnector {
    pub(crate) fn new(
        socket: PathBuf,
        requested_app: Option<PathBuf>,
    ) -> Result<Self, &'static str> {
        let helper = std::env::current_exe()
            .and_then(fs::canonicalize)
            .map_err(|_| "INVALID_CONFIGURATION")?;
        let app = bundle_for_executable(&helper)?;
        if let Some(requested_app) = requested_app
            && fs::canonicalize(requested_app).map_err(|_| "INVALID_CONFIGURATION")? != app
        {
            return Err("INVALID_CONFIGURATION");
        }
        let main_executable = app.join("Contents/MacOS/ConnDock");
        if fs::canonicalize(&main_executable).map_err(|_| "INVALID_CONFIGURATION")?
            != main_executable
        {
            return Err("INVALID_CONFIGURATION");
        }
        Ok(Self {
            socket,
            app,
            main_executable,
        })
    }
}

impl Connector for AppConnector {
    async fn connect(&self) -> Result<tokio::net::UnixStream, String> {
        socket_permissions(&self.socket)?;
        let stream = tokio::net::UnixStream::connect(&self.socket)
            .await
            .map_err(|_| "APP_NOT_RUNNING")?;
        #[cfg(target_os = "macos")]
        {
            // Security.framework checks local code only, with no network validation.
            // Keep the socket owned by this task while validation runs, so cancellation
            // cannot accidentally leak an authenticated connection to another request.
            let stream = stream.into_std().map_err(|_| "APP_IDENTITY_REJECTED")?;
            let app = self.app.clone();
            let main = self.main_executable.clone();
            let stream = tokio::task::spawn_blocking(move || {
                verify_peer(&stream, &app, &main)?;
                Ok::<_, &'static str>(stream)
            })
            .await
            .map_err(|_| "APP_IDENTITY_REJECTED")??;
            tokio::net::UnixStream::from_std(stream).map_err(|_| "APP_IDENTITY_REJECTED".into())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (&self.app, &self.main_executable, stream);
            Err("UNSUPPORTED_PLATFORM".into())
        }
    }
}

fn socket_permissions(path: &Path) -> Result<(), &'static str> {
    let socket = fs::symlink_metadata(path).map_err(|_| "APP_NOT_RUNNING")?;
    let directory = fs::symlink_metadata(path.parent().ok_or("INVALID_CONFIGURATION")?)
        .map_err(|_| "IPC_PERMISSION_DENIED")?;
    // SAFETY: geteuid has no preconditions and returns this process's effective UID.
    let uid = unsafe { libc::geteuid() };
    if !path.is_absolute()
        || !socket.file_type().is_socket()
        || socket.uid() != uid
        || socket.mode() & 0o7777 != 0o600
        || !directory.file_type().is_dir()
        || directory.uid() != uid
        || directory.mode() & 0o7777 != 0o700
    {
        return Err("IPC_PERMISSION_DENIED");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};
    use uuid::Uuid;

    fn directory() -> PathBuf {
        let path = Path::new("/tmp").join(format!("ssh-mcp-{}", Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    #[test]
    fn socket_and_immediate_directory_must_be_private_and_owned() {
        let path = directory();
        let socket = path.join("ipc.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(socket_permissions(&socket), Ok(()));
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o666)).unwrap();
        assert_eq!(socket_permissions(&socket), Err("IPC_PERMISSION_DENIED"));
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600)).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(socket_permissions(&socket), Err("IPC_PERMISSION_DENIED"));
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        let alias = path.join("alias");
        std::os::unix::fs::symlink(&socket, &alias).unwrap();
        assert_eq!(socket_permissions(&alias), Err("IPC_PERMISSION_DENIED"));
        drop(listener);
        fs::remove_dir_all(path).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn signed_peer_fixture_child() {
        use std::io::{Read, Write};
        let Some(socket) = std::env::var_os("CONNDOCK_MCP_TEST_PEER_SOCKET") else {
            return;
        };
        let listener = UnixListener::bind(socket).unwrap();
        let (mut stream, _) = listener.accept().unwrap();
        stream.write_all(&[1]).unwrap();
        let mut byte = [0];
        let _ = stream.read(&mut byte);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_audit_token_accepts_signed_exact_app_and_rejects_same_uid_other_path() {
        use std::{
            io::Read,
            process::{Command, Stdio},
            time::{Duration, Instant},
        };
        let root = directory();
        let app = root.join("ConnDock.app");
        let main = app.join("Contents/MacOS/ConnDock");
        fs::create_dir_all(main.parent().unwrap()).unwrap();
        fs::copy(std::env::current_exe().unwrap(), &main).unwrap();
        fs::write(app.join("Contents/Info.plist"),b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.ruohai.conndock.mcp-test</string><key>CFBundleExecutable</key><string>ConnDock</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>").unwrap();
        assert!(
            Command::new("/usr/bin/codesign")
                .args(["--force", "--sign", "-", "--timestamp=none"])
                .arg(&app)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success()
        );
        let socket = root.join("peer.sock");
        let child = Command::new(&main)
            .args(["--exact", "identity::tests::signed_peer_fixture_child"])
            .env("CONNDOCK_MCP_TEST_PEER_SOCKET", &socket)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        struct Fixture {
            child: std::process::Child,
            root: PathBuf,
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = self.child.kill();
                let _ = self.child.wait();
                let _ = fs::remove_dir_all(&self.root);
            }
        }
        let _fixture = Fixture { child, root };
        let deadline = Instant::now() + Duration::from_secs(5);
        while !socket.exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let mut stream = UnixStream::connect(&socket).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut ready = [0];
        stream.read_exact(&mut ready).unwrap();
        assert_eq!(verify_peer(&stream, &app, &main), Ok(()));
        assert_eq!(
            verify_peer(&stream, &app, &app.join("Contents/MacOS/other")),
            Err("APP_IDENTITY_REJECTED")
        );
        let (same_uid, _) = UnixStream::pair().unwrap();
        assert_eq!(
            verify_peer(&same_uid, &app, &main),
            Err("APP_IDENTITY_REJECTED")
        );
    }
}
