use crate::RemoteError;
use crate::remote::{REQUEST_TIMEOUT, RemoteContext, checked, on_runtime};
use russh_sftp::client::{Config, RawSftpSession, error::Error as SftpError};
use russh_sftp::protocol::{FileAttributes, FileType, OpenFlags, Packet, StatusCode};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::{Mutex, OwnedSemaphorePermit, watch};

pub const TRANSFER_CHUNK_BYTES: usize = 64 * 1024;
pub const MAX_DIRECTORY_ENTRIES: usize = 10_000;
const MAX_AUTHORIZED_DIRECTORY_ENTRIES: usize = 512;
const MAX_AUTHORIZED_PATH_BYTES: usize = 4096;
const MAX_AUTHORIZED_ROOTS: usize = 32;

fn sensitive_segment(segment: &str) -> bool {
    let lower = segment.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        ".ssh"
            | ".aws"
            | ".gnupg"
            | ".kube"
            | ".azure"
            | ".credentials"
            | ".docker"
            | ".netrc"
            | ".npmrc"
            | ".pypirc"
            | ".git-credentials"
            | "credentials"
            | "credentials.json"
            | "application_default_credentials.json"
            | "id_rsa"
            | "id_ed25519"
            | "authorized_keys"
    ) || lower == ".env"
        || lower.starts_with(".env.")
}

fn normalize_authorized_path(path: &str) -> Result<String, RemoteError> {
    if !path.starts_with('/')
        || path.len() > MAX_AUTHORIZED_PATH_BYTES
        || crate::exec::has_hidden_control(path, false)
    {
        return Err(RemoteError::InvalidPath);
    }
    let mut parts = Vec::new();
    for part in path.split('/') {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." || part.len() > 1024 || sensitive_segment(part) {
            return Err(RemoteError::InvalidPath);
        }
        parts.push(part);
    }
    let normalized = format!("/{}", parts.join("/"));
    if [
        "/proc",
        "/sys",
        "/dev",
        "/etc/ssh",
        "/private/etc/ssh",
        "/etc/ssl/private",
        "/private/etc/ssl/private",
    ]
    .iter()
    .any(|root| path_within(&normalized, root))
        || parts.windows(2).any(|pair| {
            pair[0].eq_ignore_ascii_case(".config") && pair[1].eq_ignore_ascii_case("gcloud")
        })
    {
        return Err(RemoteError::InvalidPath);
    }
    Ok(normalized)
}

fn path_within(path: &str, root: &str) -> bool {
    root == "/"
        || path == root
        || path
            .strip_prefix(root)
            .is_some_and(|tail| tail.starts_with('/'))
}

fn is_authorized_directory(path: &str, canonical: &str, roots: &[(String, String)]) -> bool {
    roots.iter().any(|(lexical_root, canonical_root)| {
        lexical_root == canonical_root
            && path_within(path, lexical_root)
            && path_within(canonical, canonical_root)
    })
}

pub fn validate_remote_path(path: &str) -> Result<(), RemoteError> {
    if path.is_empty() || path.len() > 16_384 || path.contains('\0') {
        return Err(RemoteError::InvalidPath);
    }
    Ok(())
}

pub fn join_remote_name(directory: &str, name: &str) -> Result<String, RemoteError> {
    validate_remote_path(directory)?;
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.len() > 1024
        || name.contains(['/', '\0'])
    {
        return Err(RemoteError::InvalidPath);
    }
    let joined = format!("{}/{}", directory.trim_end_matches('/'), name);
    validate_remote_path(&joined)?;
    Ok(joined)
}

fn advance_offset(offset: u64, count: usize) -> Result<u64, RemoteError> {
    if count > TRANSFER_CHUNK_BYTES {
        return Err(RemoteError::InvalidTransfer);
    }
    offset
        .checked_add(count as u64)
        .ok_or(RemoteError::InvalidTransfer)
}

fn mapped(error: SftpError) -> RemoteError {
    match error {
        SftpError::Status(status) => match status.status_code {
            StatusCode::NoSuchFile => RemoteError::NotFound,
            StatusCode::PermissionDenied => RemoteError::PermissionDenied,
            StatusCode::OpUnsupported => RemoteError::Unsupported,
            StatusCode::NoConnection | StatusCode::ConnectionLost => RemoteError::ConnectionLost,
            _ => RemoteError::RemoteFailure,
        },
        SftpError::Timeout => RemoteError::Timeout,
        SftpError::IO(_) | SftpError::UnexpectedBehavior(_) => RemoteError::ConnectionLost,
        _ => RemoteError::RemoteFailure,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoteFileKind {
    Directory,
    Regular,
    Symlink,
    Other,
}
#[derive(Clone, Debug)]
pub struct RemoteEntry {
    pub name: String,
    pub kind: RemoteFileKind,
    pub size: Option<u64>,
    pub modified_seconds: Option<u32>,
    pub permissions: Option<u32>,
}
#[derive(Clone, Debug)]
pub struct RemoteDirectory {
    pub path: String,
    pub entries: Vec<RemoteEntry>,
}

struct ClientInner {
    raw: Arc<RawSftpSession>,
    context: RemoteContext,
    cancelled: watch::Sender<bool>,
    posix_rename: bool,
    read_size: usize,
    write_size: usize,
    _permit: OwnedSemaphorePermit,
}
impl Drop for ClientInner {
    fn drop(&mut self) {
        self.cancelled.send_replace(true);
        let _ = self.raw.close_session();
    }
}

#[derive(Clone)]
pub struct SftpClient(Arc<ClientInner>);

struct HandleLease {
    raw: Arc<RawSftpSession>,
    handle: Option<String>,
}
impl HandleLease {
    fn new(raw: Arc<RawSftpSession>, handle: String) -> Self {
        Self {
            raw,
            handle: Some(handle),
        }
    }
}
impl Drop for HandleLease {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            let raw = self.raw.clone();
            if let Ok(runtime) = crate::session::runtime() {
                runtime.spawn(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(5), raw.close(handle)).await;
                });
            }
        }
    }
}

// A cancelled OPENDIR can reach the server before its HANDLE reply reaches us.
// Closing this browser channel is the only reliable way to release that handle.
struct CloseBrowserOnAbort(Option<SftpClient>);
impl Drop for CloseBrowserOnAbort {
    fn drop(&mut self) {
        if let Some(client) = self.0.take() {
            client.close();
        }
    }
}

impl crate::SshSession {
    pub async fn open_sftp(&self) -> Result<SftpClient, RemoteError> {
        let context = self.remote_context()?;
        on_runtime(async move { SftpClient::open(context).await }).await
    }
    pub async fn open_sftp_cancellable(
        &self,
        cancellation: crate::RemoteCancellation,
    ) -> Result<SftpClient, RemoteError> {
        let context = self.remote_context()?;
        cancellation
            .run(async move { SftpClient::open(context).await })
            .await
    }
}

impl SftpClient {
    async fn open(context: RemoteContext) -> Result<Self, RemoteError> {
        let (cancelled, local) = watch::channel(false);
        let mut lease = checked(
            context.cancelled.clone(),
            local.clone(),
            context.open_channel(),
        )
        .await?;
        let channel = lease.channel.as_mut().ok_or(RemoteError::RemoteFailure)?;
        checked(context.cancelled.clone(), local.clone(), async {
            channel
                .request_subsystem(true, "sftp")
                .await
                .map_err(|_| RemoteError::Unsupported)?;
            loop {
                match channel.wait().await {
                    Some(russh::ChannelMsg::Success) => return Ok(()),
                    Some(russh::ChannelMsg::WindowAdjusted { .. }) => {}
                    _ => return Err(RemoteError::Unsupported),
                }
            }
        })
        .await?;
        let stream = lease
            .channel
            .take()
            .ok_or(RemoteError::RemoteFailure)?
            .into_stream();
        let mut raw = RawSftpSession::new_with_config(
            stream,
            Config {
                max_packet_len: 256 * 1024,
                max_concurrent_reads: 1,
                max_concurrent_writes: 1,
                request_timeout_secs: 20,
                ..Default::default()
            },
        );
        let version = checked(context.cancelled.clone(), local.clone(), async {
            raw.init().await.map_err(mapped)
        })
        .await?;
        if version.version != 3 {
            return Err(RemoteError::Unsupported);
        }
        let posix_rename = version
            .extensions
            .get("posix-rename@openssh.com")
            .is_some_and(|v| v == "1");
        let mut read_size = TRANSFER_CHUNK_BYTES;
        let mut write_size = TRANSFER_CHUNK_BYTES;
        if version
            .extensions
            .get("limits@openssh.com")
            .is_some_and(|v| v == "1")
        {
            let limits = checked(context.cancelled.clone(), local.clone(), async {
                raw.limits().await.map_err(mapped)
            })
            .await?;
            let limits = russh_sftp::client::rawsession::Limits::from(limits);
            if let Some(size) = limits.read_len {
                read_size = read_size.min(size as usize);
            }
            if let Some(size) = limits.write_len {
                write_size = write_size.min(size as usize);
            }
            if let Some(size) = limits.packet_len {
                write_size = write_size.min(size.saturating_sub(4096) as usize);
            }
            raw.set_limits(limits);
        }
        if read_size == 0 || write_size == 0 {
            return Err(RemoteError::Unsupported);
        }
        let inner = Arc::new(ClientInner {
            raw: Arc::new(raw),
            context: context.clone(),
            cancelled,
            posix_rename,
            read_size,
            write_size,
            _permit: lease.permit.take().ok_or(RemoteError::RemoteFailure)?,
        });
        let weak = Arc::downgrade(&inner);
        let mut connection_end = context.cancelled;
        let mut local_end = local;
        crate::session::runtime().map_err(|_| RemoteError::RemoteFailure)?.spawn(async move {
            tokio::select! { _ = connection_end.wait_for(|v| *v) => {}, _ = local_end.wait_for(|v| *v) => {} }
            if let Some(client) = weak.upgrade() { let _ = client.raw.close_session(); }
        });
        Ok(Self(inner))
    }

    async fn request<T>(
        &self,
        future: impl std::future::Future<Output = Result<T, SftpError>>,
    ) -> Result<T, RemoteError> {
        checked(
            self.0.context.cancelled.clone(),
            self.0.cancelled.subscribe(),
            async { future.await.map_err(mapped) },
        )
        .await
    }

    pub fn close(&self) {
        self.0.cancelled.send_replace(true);
        let _ = self.0.raw.close_session();
    }

    /// MCP browsing uses an explicit path whitelist and a separate cancellation
    /// handle. The server's REALPATH response is checked before opening a handle.
    /// Callers must grant canonical absolute directories: a root or any of its
    /// components resolving through a symlink to a different path is denied.
    pub async fn list_authorized_directory(
        &self,
        path: String,
        allowed_roots: Vec<String>,
        operation: crate::RemoteCancellation,
    ) -> Result<RemoteDirectory, RemoteError> {
        let path = normalize_authorized_path(&path)?;
        if allowed_roots.is_empty() || allowed_roots.len() > MAX_AUTHORIZED_ROOTS {
            return Err(RemoteError::PermissionDenied);
        }
        let roots = allowed_roots
            .iter()
            .map(|root| normalize_authorized_path(root))
            .collect::<Result<Vec<_>, _>>()?;
        if !roots.iter().any(|root| path_within(&path, root)) {
            return Err(RemoteError::PermissionDenied);
        }
        let client = self.clone();
        operation
            .run(async move {
                tokio::time::timeout(REQUEST_TIMEOUT, async {
                    let mut abort = CloseBrowserOnAbort(Some(client.clone()));
                    let result = async {
                        let mut resolved = Vec::with_capacity(roots.len());
                        for root in roots {
                            if path_within(&path, &root) {
                                let canonical = client.canonical_authorized_path(&root).await?;
                                if canonical != root {
                                    return Err(RemoteError::PermissionDenied);
                                }
                                resolved.push((root, canonical));
                            }
                        }
                        client
                            .list_directory_inner(
                                path,
                                MAX_AUTHORIZED_DIRECTORY_ENTRIES,
                                Some(resolved),
                            )
                            .await
                    }
                    .await;
                    if !matches!(
                        result,
                        Err(RemoteError::Timeout
                            | RemoteError::Cancelled
                            | RemoteError::ConnectionLost)
                    ) {
                        abort.0.take();
                    }
                    result
                })
                .await
                .map_err(|_| RemoteError::Timeout)?
            })
            .await
    }

    async fn canonical_authorized_path(&self, path: &str) -> Result<String, RemoteError> {
        let names = self.request(self.0.raw.realpath(path)).await?;
        if names.files.len() != 1 {
            return Err(RemoteError::MalformedData);
        }
        let canonical = normalize_authorized_path(&names.files[0].filename)?;
        if canonical != names.files[0].filename {
            return Err(RemoteError::MalformedData);
        }
        Ok(canonical)
    }

    pub async fn list_directory(&self, path: String) -> Result<RemoteDirectory, RemoteError> {
        validate_remote_path(&path)?;
        let client = self.clone();
        on_runtime(async move {
            client
                .list_directory_inner(path, MAX_DIRECTORY_ENTRIES, None)
                .await
        })
        .await
    }

    async fn list_directory_inner(
        &self,
        requested_path: String,
        limit: usize,
        authorization: Option<Vec<(String, String)>>,
    ) -> Result<RemoteDirectory, RemoteError> {
        let client = self.clone();
        let mut abort = CloseBrowserOnAbort(Some(client.clone()));
        let result = async {
            let raw = &client.0.raw;
            let names = client.request(raw.realpath(requested_path.clone())).await?;
            if authorization.is_some() && names.files.len() != 1 {
                return Err(RemoteError::MalformedData);
            }
            let path = names
                .files
                .first()
                .ok_or(RemoteError::MalformedData)?
                .filename
                .clone();
            validate_remote_path(&path)?;
            if let Some(roots) = &authorization {
                let canonical = normalize_authorized_path(&path)?;
                if canonical != path || !is_authorized_directory(&requested_path, &canonical, roots)
                {
                    return Err(RemoteError::PermissionDenied);
                }
            }
            let handle = client.request(raw.opendir(path.clone())).await?.handle;
            let mut lease = HandleLease::new(raw.clone(), handle.clone());
            let result = async {
                if authorization.is_some() && client.canonical_authorized_path(&path).await? != path
                {
                    return Err(RemoteError::PermissionDenied);
                }
                let mut entries = Vec::new();
                loop {
                    let batch = checked(
                        client.0.context.cancelled.clone(),
                        client.0.cancelled.subscribe(),
                        async {
                            match raw.readdir(handle.clone()).await {
                                Ok(names) => Ok(Some(names)),
                                Err(SftpError::Status(status))
                                    if status.status_code == StatusCode::Eof =>
                                {
                                    Ok(None)
                                }
                                Err(error) => Err(mapped(error)),
                            }
                        },
                    )
                    .await?;
                    match batch {
                        Some(names) => {
                            if names.files.is_empty() {
                                return Err(RemoteError::MalformedData);
                            }
                            for file in names.files {
                                if file.filename == "." || file.filename == ".." {
                                    continue;
                                }
                                let joined = join_remote_name(&path, &file.filename)?;
                                // Metadata for sensitive/hidden-control paths is omitted;
                                // following any returned symlink still needs full authorization.
                                if authorization.is_some()
                                    && normalize_authorized_path(&joined).is_err()
                                {
                                    continue;
                                }
                                if entries.len() >= limit {
                                    return Err(RemoteError::DirectoryTooLarge);
                                }
                                let kind = match file.attrs.file_type() {
                                    FileType::Dir => RemoteFileKind::Directory,
                                    FileType::File => RemoteFileKind::Regular,
                                    FileType::Symlink => RemoteFileKind::Symlink,
                                    FileType::Other => RemoteFileKind::Other,
                                };
                                entries.push(RemoteEntry {
                                    name: file.filename,
                                    kind,
                                    size: file.attrs.size,
                                    modified_seconds: file.attrs.mtime,
                                    permissions: file.attrs.permissions,
                                });
                            }
                        }
                        None => break,
                    }
                }
                if authorization.is_some() && client.canonical_authorized_path(&path).await? != path
                {
                    return Err(RemoteError::PermissionDenied);
                }
                Ok::<_, RemoteError>(entries)
            }
            .await;
            let close = client.request(raw.close(handle)).await;
            if close.is_ok() {
                lease.handle.take();
            }
            let mut entries = result?;
            close?;
            entries.sort_by(|a, b| {
                (a.kind != RemoteFileKind::Directory, a.name.to_lowercase())
                    .cmp(&(b.kind != RemoteFileKind::Directory, b.name.to_lowercase()))
            });
            Ok(RemoteDirectory { path, entries })
        }
        .await;
        if matches!(
            result,
            Ok(_)
                | Err(RemoteError::PermissionDenied
                    | RemoteError::InvalidPath
                    | RemoteError::NotFound
                    | RemoteError::DirectoryTooLarge)
        ) {
            abort.0.take();
        }
        result
    }

    pub async fn create_directory(&self, path: String) -> Result<(), RemoteError> {
        validate_remote_path(&path)?;
        let client = self.clone();
        on_runtime(async move {
            client.ensure_absent(&path).await?;
            client
                .request(client.0.raw.mkdir(
                    path,
                    FileAttributes {
                        permissions: Some(0o755),
                        ..Default::default()
                    },
                ))
                .await
                .map(|_| ())
        })
        .await
    }
    async fn ensure_absent(&self, path: &str) -> Result<(), RemoteError> {
        match self.request(self.0.raw.lstat(path)).await {
            Ok(_) => Err(RemoteError::AlreadyExists),
            Err(RemoteError::NotFound) => Ok(()),
            Err(error) => Err(error),
        }
    }
    pub async fn rename(&self, source: String, destination: String) -> Result<(), RemoteError> {
        validate_remote_path(&source)?;
        validate_remote_path(&destination)?;
        let client = self.clone();
        on_runtime(async move {
            client.ensure_absent(&destination).await?;
            client
                .request(client.0.raw.rename(source, destination))
                .await
                .map(|_| ())
        })
        .await
    }
    pub async fn remove(&self, path: String) -> Result<(), RemoteError> {
        validate_remote_path(&path)?;
        if path == "/" || path == "." || path == ".." {
            return Err(RemoteError::InvalidPath);
        }
        let client = self.clone();
        on_runtime(async move {
            let attrs = client
                .request(client.0.raw.lstat(path.clone()))
                .await?
                .attrs;
            if attrs.file_type().is_dir() {
                client.request(client.0.raw.rmdir(path)).await?;
            } else {
                client.request(client.0.raw.remove(path)).await?;
            }
            Ok(())
        })
        .await
    }

    pub async fn open_reader(&self, path: String) -> Result<SftpFile, RemoteError> {
        validate_remote_path(&path)?;
        let context = self.0.context.clone();
        on_runtime(async move {
            let client = Self::open(context).await?;
            let handle = client
                .request(
                    client
                        .0
                        .raw
                        .open(path.clone(), OpenFlags::READ, FileAttributes::empty()),
                )
                .await?
                .handle;
            let attrs = client
                .request(client.0.raw.fstat(handle.clone()))
                .await?
                .attrs;
            if attrs.permissions.is_some() && attrs.file_type() != FileType::File {
                return Err(RemoteError::InvalidTransfer);
            }
            Ok(SftpFile::new(client, handle, path, None, false, attrs.size))
        })
        .await
    }
    pub async fn open_writer(
        &self,
        path: String,
        size: u64,
        overwrite: bool,
    ) -> Result<SftpFile, RemoteError> {
        validate_remote_path(&path)?;
        let context = self.0.context.clone();
        on_runtime(async move {
            let client = Self::open(context).await?;
            let preserved = match client.request(client.0.raw.lstat(path.clone())).await {
                Ok(attrs) => {
                    if !overwrite {
                        return Err(RemoteError::AlreadyExists);
                    }
                    if attrs.attrs.file_type() != FileType::File {
                        return Err(RemoteError::InvalidTransfer);
                    }
                    if attrs.attrs.permissions.is_none()
                        || attrs.attrs.uid.is_none()
                        || attrs.attrs.gid.is_none()
                    {
                        return Err(RemoteError::Unsupported);
                    }
                    Some(FileAttributes {
                        permissions: attrs.attrs.permissions.map(|mode| mode & 0o777),
                        uid: attrs.attrs.uid,
                        gid: attrs.attrs.gid,
                        ..Default::default()
                    })
                }
                Err(RemoteError::NotFound) => None,
                Err(error) => return Err(error),
            };
            if overwrite && !client.0.posix_rename {
                return Err(RemoteError::Unsupported);
            }
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|_| RemoteError::RemoteFailure)?
                .as_nanos();
            let parent = path
                .rsplit_once('/')
                .map(|(parent, _)| if parent.is_empty() { "/" } else { parent })
                .unwrap_or(".");
            let temporary = join_remote_name(
                parent,
                &format!(
                    ".conndock-{nonce:x}-{:x}.part",
                    NEXT.fetch_add(1, Ordering::Relaxed)
                ),
            )?;
            let handle = client
                .request(client.0.raw.open(
                    temporary.clone(),
                    OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
                    FileAttributes {
                        permissions: Some(0o600),
                        ..Default::default()
                    },
                ))
                .await?
                .handle;
            let mut file =
                SftpFile::new(client, handle, path, Some(temporary), overwrite, Some(size));
            if let Some(inner) = Arc::get_mut(&mut file.0) {
                inner.preserved = preserved;
            }
            Ok(file)
        })
        .await
    }
}

struct FileInner {
    client: SftpClient,
    handle: String,
    destination: String,
    temporary: Option<String>,
    overwrite: bool,
    size: Option<u64>,
    offset: Mutex<u64>,
    closed: AtomicBool,
    committed: AtomicBool,
    committing: AtomicBool,
    preserved: Option<FileAttributes>,
    cancelled: watch::Sender<bool>,
}
impl Drop for FileInner {
    fn drop(&mut self) {
        self.cancelled.send_replace(true);
        let client = self.client.clone();
        let handle = (!self.closed.swap(true, Ordering::AcqRel)).then(|| self.handle.clone());
        let temporary = if self.committed.load(Ordering::Acquire) {
            None
        } else {
            self.temporary.clone()
        };
        if let Ok(runtime) = crate::session::runtime() {
            runtime.spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(5), async {
                    if let Some(handle) = handle {
                        let _ = client.0.raw.close(handle).await;
                    }
                    if let Some(path) = temporary {
                        let _ = client.0.raw.remove(path).await;
                    }
                })
                .await;
                client.close();
            });
        }
    }
}
#[derive(Clone)]
pub struct SftpFile(Arc<FileInner>);
impl SftpFile {
    fn new(
        client: SftpClient,
        handle: String,
        destination: String,
        temporary: Option<String>,
        overwrite: bool,
        size: Option<u64>,
    ) -> Self {
        let (cancelled, _) = watch::channel(false);
        Self(Arc::new(FileInner {
            client,
            handle,
            destination,
            temporary,
            overwrite,
            size,
            offset: Mutex::new(0),
            closed: AtomicBool::new(false),
            committed: AtomicBool::new(false),
            committing: AtomicBool::new(false),
            preserved: None,
            cancelled,
        }))
    }
    pub fn size(&self) -> Option<u64> {
        self.0.size
    }
    pub fn cancel(&self) {
        if self.0.committing.load(Ordering::Acquire) {
            return;
        }
        self.0.cancelled.send_replace(true);
    }
    async fn request<T>(
        &self,
        future: impl std::future::Future<Output = Result<T, SftpError>>,
    ) -> Result<T, RemoteError> {
        checked(
            self.0.client.0.context.cancelled.clone(),
            self.0.cancelled.subscribe(),
            async { future.await.map_err(mapped) },
        )
        .await
    }
    pub async fn read_chunk(&self) -> Result<Vec<u8>, RemoteError> {
        let file = self.clone();
        on_runtime(async move {
            let mut offset = file.0.offset.lock().await;
            if file.0.closed.load(Ordering::Acquire) || file.0.temporary.is_some() {
                return Err(RemoteError::InvalidTransfer);
            }
            let result = checked(
                file.0.client.0.context.cancelled.clone(),
                file.0.cancelled.subscribe(),
                async {
                    match file
                        .0
                        .client
                        .0
                        .raw
                        .read(
                            file.0.handle.clone(),
                            *offset,
                            file.0.client.0.read_size as u32,
                        )
                        .await
                    {
                        Ok(data) => Ok(data.data),
                        Err(SftpError::Status(status)) if status.status_code == StatusCode::Eof => {
                            Ok(Vec::new())
                        }
                        Err(error) => Err(mapped(error)),
                    }
                },
            )
            .await?;
            if result.len() > file.0.client.0.read_size {
                return Err(RemoteError::OutputLimit);
            }
            let next = advance_offset(*offset, result.len())?;
            if file
                .0
                .size
                .is_some_and(|size| next > size || (result.is_empty() && next != size))
            {
                return Err(RemoteError::InvalidTransfer);
            }
            *offset = next;
            Ok(result)
        })
        .await
    }
    pub async fn write_chunk(&self, bytes: Vec<u8>) -> Result<(), RemoteError> {
        if bytes.is_empty() || bytes.len() > TRANSFER_CHUNK_BYTES {
            return Err(RemoteError::InvalidTransfer);
        }
        let file = self.clone();
        on_runtime(async move {
            let mut offset = file.0.offset.lock().await;
            if file.0.closed.load(Ordering::Acquire) || file.0.temporary.is_none() {
                return Err(RemoteError::InvalidTransfer);
            }
            let next = advance_offset(*offset, bytes.len())?;
            if file.0.size.is_some_and(|size| next > size) {
                return Err(RemoteError::InvalidTransfer);
            }
            for chunk in bytes.chunks(file.0.client.0.write_size) {
                file.request(file.0.client.0.raw.write(
                    file.0.handle.clone(),
                    *offset,
                    chunk.to_vec(),
                ))
                .await?;
                *offset += chunk.len() as u64;
            }
            Ok(())
        })
        .await
    }
    pub async fn finish(&self) -> Result<(), RemoteError> {
        let file = self.clone();
        on_runtime(async move {
            let offset = file.0.offset.lock().await;
            if file.0.closed.load(Ordering::Acquire)
                || file.0.size.is_some_and(|size| *offset != size)
            {
                return Err(RemoteError::InvalidTransfer);
            }
            if let Some(attrs) = &file.0.preserved {
                file.request(
                    file.0
                        .client
                        .0
                        .raw
                        .fsetstat(file.0.handle.clone(), attrs.clone()),
                )
                .await?;
            }
            file.0.closed.store(true, Ordering::Release);
            file.request(file.0.client.0.raw.close(file.0.handle.clone()))
                .await?;
            if let Some(temporary) = &file.0.temporary {
                if *file.0.cancelled.borrow() {
                    return Err(RemoteError::Cancelled);
                }
                file.0.committing.store(true, Ordering::Release);
                let commit = async {
                    if file.0.overwrite {
                        let mut data = Vec::new();
                        for path in [temporary, &file.0.destination] {
                            data.extend_from_slice(&(path.len() as u32).to_be_bytes());
                            data.extend_from_slice(path.as_bytes());
                        }
                        let packet = file
                            .commit_request(
                                file.0
                                    .client
                                    .0
                                    .raw
                                    .extended("posix-rename@openssh.com", data),
                            )
                            .await?;
                        match packet {
                            Packet::Status(status) if status.status_code == StatusCode::Ok => {}
                            Packet::Status(status) => {
                                return Err(mapped(SftpError::Status(status)));
                            }
                            _ => return Err(RemoteError::MalformedData),
                        }
                    } else {
                        file.0.client.ensure_absent(&file.0.destination).await?;
                        file.commit_request(
                            file.0
                                .client
                                .0
                                .raw
                                .rename(temporary.clone(), file.0.destination.clone()),
                        )
                        .await?;
                    }
                    Ok::<_, RemoteError>(())
                }
                .await;
                commit.map_err(|error| match error {
                    RemoteError::ConnectionLost | RemoteError::Timeout | RemoteError::Cancelled => {
                        RemoteError::CommitUnknown
                    }
                    other => other,
                })?;
            }
            file.0.committed.store(true, Ordering::Release);
            file.0.client.close();
            Ok(())
        })
        .await
    }

    async fn commit_request<T>(
        &self,
        future: impl std::future::Future<Output = Result<T, SftpError>>,
    ) -> Result<T, RemoteError> {
        let (_uncancellable, local) = watch::channel(false);
        checked(self.0.client.0.context.cancelled.clone(), local, async {
            future.await.map_err(mapped)
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authorization_paths_reject_parent_traversal_sensitive_segments_and_controls() {
        assert_eq!(
            normalize_authorized_path("/srv//app/./logs/"),
            Ok("/srv/app/logs".into())
        );
        for path in [
            "",
            "relative",
            "/srv/../etc",
            "/srv/a\0b",
            "/srv/a\nb",
            "/srv/a\u{202e}",
            "/home/u/.ssh",
            "/home/u/.aws/keys",
            "/home/u/.env",
            "/home/u/.env.production",
            "/proc/1",
            "/sys",
            "/dev/fd",
            "/etc/ssh",
            "/private/etc/ssh",
        ] {
            assert_eq!(
                normalize_authorized_path(path),
                Err(RemoteError::InvalidPath)
            );
        }
    }

    #[test]
    fn authorized_directory_requires_a_literal_canonical_root() {
        let roots = vec![("/srv/allowed".into(), "/srv/allowed".into())];
        assert!(is_authorized_directory(
            "/srv/allowed/logs",
            "/srv/allowed/logs",
            &roots
        ));
        assert!(is_authorized_directory(
            "/srv/allowed",
            "/srv/allowed",
            &roots
        ));
        assert!(!is_authorized_directory(
            "/srv/allowed-other",
            "/srv/allowed",
            &roots
        ));
        assert!(!is_authorized_directory(
            "/srv/allowed/link",
            "/private/data",
            &roots
        ));
        assert!(!is_authorized_directory(
            "/srv/allowed/link",
            "/srv/allowed-other",
            &roots
        ));
        assert!(!is_authorized_directory(
            "/srv/other",
            "/srv/allowed",
            &roots
        ));
        let redirected_roots = vec![("/srv/allowed".into(), "/srv/outside".into())];
        assert!(!is_authorized_directory(
            "/srv/allowed",
            "/srv/outside",
            &redirected_roots
        ));
    }

    #[tokio::test]
    async fn directory_handle_drop_sends_remote_close() {
        use tokio::io::AsyncReadExt;
        let (stream, mut server) = tokio::io::duplex(4096);
        let raw = Arc::new(RawSftpSession::new(stream));
        let lease = HandleLease::new(raw.clone(), "directory-handle".into());
        drop(lease);
        let length = tokio::time::timeout(Duration::from_secs(1), server.read_u32())
            .await
            .expect("Dropping an opened directory must send CLOSE without its cancelled caller")
            .unwrap();
        assert!(length < 4096);
        let mut packet = vec![0; length as usize];
        server.read_exact(&mut packet).await.unwrap();
        assert_eq!(packet[0], 4, "SSH_FXP_CLOSE");
        assert_eq!(&packet[9..], b"directory-handle");
        raw.close_session().unwrap();
    }

    #[test]
    fn validates_names_without_interpreting_shell_characters() {
        assert_eq!(
            join_remote_name("/tmp", "中文 ' ; $(id).txt").unwrap(),
            "/tmp/中文 ' ; $(id).txt"
        );
        assert_eq!(join_remote_name("/", "file").unwrap(), "/file");
        for name in ["", ".", "..", "a/b", "a\0b"] {
            assert_eq!(
                join_remote_name("/tmp", name),
                Err(RemoteError::InvalidPath)
            );
        }
        for path in ["", "a\0b", &"a".repeat(16_385)] {
            assert_eq!(validate_remote_path(path), Err(RemoteError::InvalidPath));
        }
    }

    #[test]
    fn offsets_remain_64_bit_and_chunks_are_bounded() {
        assert_eq!(
            advance_offset(2 * 1024 * 1024 * 1024, TRANSFER_CHUNK_BYTES).unwrap(),
            2_147_549_184
        );
        assert_eq!(
            advance_offset(u64::MAX, 1),
            Err(RemoteError::InvalidTransfer)
        );
        assert_eq!(
            advance_offset(0, TRANSFER_CHUNK_BYTES + 1),
            Err(RemoteError::InvalidTransfer)
        );
    }
}
