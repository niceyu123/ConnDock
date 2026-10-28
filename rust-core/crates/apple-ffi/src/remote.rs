use conndock_core::{self as core, monitor, sftp};
use std::sync::Arc;

#[derive(uniffi::Object)]
pub struct RemoteOperation {
    pub(crate) inner: core::RemoteCancellation,
}
impl Drop for RemoteOperation {
    fn drop(&mut self) {
        self.inner.cancel();
    }
}
#[uniffi::export]
impl RemoteOperation {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: core::RemoteCancellation::default(),
        })
    }
    pub fn cancel(&self) {
        self.inner.cancel();
    }
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum RemoteFailureCode {
    NotConnected,
    Cancelled,
    Timeout,
    PermissionDenied,
    NotFound,
    AlreadyExists,
    Unsupported,
    InvalidPath,
    InvalidCommand,
    InvalidServiceName,
    DirectoryTooLarge,
    OutputLimit,
    MalformedData,
    ConnectionLost,
    RemoteFailure,
    InvalidTransfer,
    CommitUnknown,
}
impl From<core::RemoteError> for RemoteFailureCode {
    fn from(value: core::RemoteError) -> Self {
        match value {
            core::RemoteError::NotConnected => Self::NotConnected,
            core::RemoteError::Cancelled => Self::Cancelled,
            core::RemoteError::Timeout => Self::Timeout,
            core::RemoteError::PermissionDenied => Self::PermissionDenied,
            core::RemoteError::NotFound => Self::NotFound,
            core::RemoteError::AlreadyExists => Self::AlreadyExists,
            core::RemoteError::Unsupported => Self::Unsupported,
            core::RemoteError::InvalidPath => Self::InvalidPath,
            core::RemoteError::InvalidCommand => Self::InvalidCommand,
            core::RemoteError::InvalidServiceName => Self::InvalidServiceName,
            core::RemoteError::DirectoryTooLarge => Self::DirectoryTooLarge,
            core::RemoteError::OutputLimit => Self::OutputLimit,
            core::RemoteError::MalformedData => Self::MalformedData,
            core::RemoteError::ConnectionLost => Self::ConnectionLost,
            core::RemoteError::RemoteFailure => Self::RemoteFailure,
            core::RemoteError::InvalidTransfer => Self::InvalidTransfer,
            core::RemoteError::CommitUnknown => Self::CommitUnknown,
        }
    }
}
#[derive(Debug, uniffi::Error)]
pub enum RemoteFailure {
    Failure { code: RemoteFailureCode },
}
impl std::fmt::Display for RemoteFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for RemoteFailure {}
impl From<core::RemoteError> for RemoteFailure {
    fn from(value: core::RemoteError) -> Self {
        Self::Failure { code: value.into() }
    }
}

#[derive(uniffi::Record)]
pub struct CommandOutput {
    pub exit_code: Option<u32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub truncated: bool,
}
impl From<core::CommandOutput> for CommandOutput {
    fn from(value: core::CommandOutput) -> Self {
        Self {
            exit_code: value.exit_code,
            stdout: value.stdout,
            stderr: value.stderr,
            truncated: value.truncated,
        }
    }
}

#[derive(uniffi::Record)]
pub struct ServiceStatus {
    pub name: String,
    pub load_state: String,
    pub active_state: String,
    pub sub_state: String,
    pub unit_file_state: String,
    pub active_enter_timestamp: String,
}
impl From<core::ServiceStatus> for ServiceStatus {
    fn from(value: core::ServiceStatus) -> Self {
        Self {
            name: value.name,
            load_state: value.load_state,
            active_state: value.active_state,
            sub_state: value.sub_state,
            unit_file_state: value.unit_file_state,
            active_enter_timestamp: value.active_enter_timestamp,
        }
    }
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum RemoteEntryKind {
    Directory,
    Regular,
    Symlink,
    Other,
}
#[derive(uniffi::Record)]
pub struct RemoteFileEntry {
    pub name: String,
    pub kind: RemoteEntryKind,
    pub size: Option<u64>,
    pub modified_seconds: Option<u32>,
    pub permissions: Option<u32>,
}
#[derive(uniffi::Record)]
pub struct RemoteDirectoryListing {
    pub path: String,
    pub entries: Vec<RemoteFileEntry>,
}
impl From<sftp::RemoteDirectory> for RemoteDirectoryListing {
    fn from(directory: sftp::RemoteDirectory) -> Self {
        Self {
            path: directory.path,
            entries: directory
                .entries
                .into_iter()
                .map(|entry| RemoteFileEntry {
                    name: entry.name,
                    kind: match entry.kind {
                        sftp::RemoteFileKind::Directory => RemoteEntryKind::Directory,
                        sftp::RemoteFileKind::Regular => RemoteEntryKind::Regular,
                        sftp::RemoteFileKind::Symlink => RemoteEntryKind::Symlink,
                        sftp::RemoteFileKind::Other => RemoteEntryKind::Other,
                    },
                    size: entry.size,
                    modified_seconds: entry.modified_seconds,
                    permissions: entry.permissions,
                })
                .collect(),
        }
    }
}

#[derive(uniffi::Object)]
pub struct RemoteFiles {
    inner: sftp::SftpClient,
}
impl RemoteFiles {
    pub(crate) fn wrap(inner: sftp::SftpClient) -> Arc<Self> {
        Arc::new(Self { inner })
    }
}
#[uniffi::export]
impl RemoteFiles {
    pub async fn list_authorized_directory(
        &self,
        path: String,
        allowed_roots: Vec<String>,
        operation: Arc<RemoteOperation>,
    ) -> Result<RemoteDirectoryListing, RemoteFailure> {
        Ok(self
            .inner
            .list_authorized_directory(path, allowed_roots, operation.inner.clone())
            .await?
            .into())
    }
    pub async fn list_directory(
        &self,
        path: String,
    ) -> Result<RemoteDirectoryListing, RemoteFailure> {
        Ok(self.inner.list_directory(path).await?.into())
    }
    pub async fn create_directory(&self, path: String) -> Result<(), RemoteFailure> {
        self.inner.create_directory(path).await.map_err(Into::into)
    }
    pub async fn rename(&self, source: String, destination: String) -> Result<(), RemoteFailure> {
        self.inner
            .rename(source, destination)
            .await
            .map_err(Into::into)
    }
    pub async fn remove(&self, path: String) -> Result<(), RemoteFailure> {
        self.inner.remove(path).await.map_err(Into::into)
    }
    pub async fn open_reader(&self, path: String) -> Result<Arc<RemoteFile>, RemoteFailure> {
        Ok(Arc::new(RemoteFile {
            inner: self.inner.open_reader(path).await?,
        }))
    }
    pub async fn open_reader_cancellable(
        &self,
        path: String,
        operation: Arc<RemoteOperation>,
    ) -> Result<Arc<RemoteFile>, RemoteFailure> {
        let client = self.inner.clone();
        let file = operation
            .inner
            .run(async move { client.open_reader(path).await })
            .await?;
        Ok(Arc::new(RemoteFile { inner: file }))
    }
    pub async fn open_writer_cancellable(
        &self,
        path: String,
        size: u64,
        overwrite: bool,
        operation: Arc<RemoteOperation>,
    ) -> Result<Arc<RemoteFile>, RemoteFailure> {
        let client = self.inner.clone();
        let file = operation
            .inner
            .run(async move { client.open_writer(path, size, overwrite).await })
            .await?;
        Ok(Arc::new(RemoteFile { inner: file }))
    }
    pub async fn open_writer(
        &self,
        path: String,
        size: u64,
        overwrite: bool,
    ) -> Result<Arc<RemoteFile>, RemoteFailure> {
        Ok(Arc::new(RemoteFile {
            inner: self.inner.open_writer(path, size, overwrite).await?,
        }))
    }
    pub fn close(&self) {
        self.inner.close();
    }
}

#[derive(uniffi::Object)]
pub struct RemoteFile {
    inner: sftp::SftpFile,
}
#[uniffi::export]
impl RemoteFile {
    pub fn size(&self) -> Option<u64> {
        self.inner.size()
    }
    pub async fn read_chunk(&self) -> Result<Vec<u8>, RemoteFailure> {
        self.inner.read_chunk().await.map_err(Into::into)
    }
    pub async fn write_chunk(&self, bytes: Vec<u8>) -> Result<(), RemoteFailure> {
        self.inner.write_chunk(bytes).await.map_err(Into::into)
    }
    pub async fn finish(&self) -> Result<(), RemoteFailure> {
        self.inner.finish().await.map_err(Into::into)
    }
    pub fn cancel(&self) {
        self.inner.cancel();
    }
}

#[derive(uniffi::Record)]
pub struct ServerMetrics {
    pub system: String,
    pub uptime_seconds: f64,
    pub cpu_percent: Option<f64>,
    pub memory_total: u64,
    pub memory_used: u64,
    pub disk_total: u64,
    pub disk_used: u64,
    pub disk_percent: f64,
    pub receive_bytes_per_second: Option<f64>,
    pub transmit_bytes_per_second: Option<f64>,
}
impl From<monitor::LinuxMetrics> for ServerMetrics {
    fn from(value: monitor::LinuxMetrics) -> Self {
        Self {
            system: value.system,
            uptime_seconds: value.uptime_seconds,
            cpu_percent: value.cpu_percent,
            memory_total: value.memory_total,
            memory_used: value.memory_used,
            disk_total: value.disk_total,
            disk_used: value.disk_used,
            disk_percent: value.disk_percent,
            receive_bytes_per_second: value.receive_bytes_per_second,
            transmit_bytes_per_second: value.transmit_bytes_per_second,
        }
    }
}
#[derive(uniffi::Object)]
pub struct RemoteMonitor {
    inner: monitor::LinuxMonitor,
}
impl RemoteMonitor {
    pub(crate) fn wrap(inner: monitor::LinuxMonitor) -> Arc<Self> {
        Arc::new(Self { inner })
    }
}
#[uniffi::export]
impl RemoteMonitor {
    pub async fn sample(&self) -> Result<ServerMetrics, RemoteFailure> {
        Ok(self.inner.sample().await?.into())
    }
    pub fn stop(&self) {
        self.inner.stop();
    }
}
