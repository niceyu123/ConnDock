use std::future::Future;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Semaphore, watch};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoteError {
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
impl std::fmt::Display for RemoteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for RemoteError {}

pub(crate) const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone)]
pub struct RemoteCancellation(watch::Sender<bool>);
impl Default for RemoteCancellation {
    fn default() -> Self {
        Self(watch::channel(false).0)
    }
}
impl RemoteCancellation {
    pub fn cancel(&self) {
        self.0.send_replace(true);
    }
    pub async fn run<T: Send + 'static>(
        &self,
        future: impl Future<Output = Result<T, RemoteError>> + Send + 'static,
    ) -> Result<T, RemoteError> {
        let mut cancelled = self.0.subscribe();
        on_runtime(async move {
            tokio::select! {
                biased;
                _ = cancelled.wait_for(|value| *value) => Err(RemoteError::Cancelled),
                result = future => result,
            }
        })
        .await
    }
}

#[derive(Clone)]
pub(crate) struct RemoteContext {
    pub handle: Arc<russh::client::Handle<crate::session::Handler>>,
    pub cancelled: watch::Receiver<bool>,
    pub slots: Arc<Semaphore>,
    pub disconnect: watch::Sender<bool>,
}

pub(crate) struct RemoteChannel {
    pub channel: Option<russh::Channel<russh::client::Msg>>,
    pub permit: Option<tokio::sync::OwnedSemaphorePermit>,
}
impl Drop for RemoteChannel {
    fn drop(&mut self) {
        if let Some(channel) = self.channel.take() {
            let permit = self.permit.take();
            if let Ok(runtime) = crate::session::runtime() {
                runtime.spawn(async move {
                    let _ = tokio::time::timeout(Duration::from_secs(2), channel.close()).await;
                    drop(permit);
                });
            }
        }
    }
}
impl crate::SshSession {
    /// Verify the authenticated transport without running a command or PTY.
    /// A successful channel-open reply is a round trip from the SSH server.
    pub async fn check_connection(&self, operation: RemoteCancellation) -> Result<(), RemoteError> {
        let context = self.remote_context()?;
        operation
            .run(async move {
                let mut disconnected = context.cancelled.clone();
                tokio::select! {
                    biased;
                    _ = disconnected.wait_for(|value| *value) => Err(RemoteError::ConnectionLost),
                    result = tokio::time::timeout(Duration::from_secs(5), async {
                        let channel = context.open_channel().await?;
                        drop(channel); // The lease owns bounded CLOSE and permit release.
                        Ok(())
                    }) => result.map_err(|_| RemoteError::Timeout)?,
                }
            })
            .await
    }
}

impl RemoteContext {
    pub async fn open_channel(&self) -> Result<RemoteChannel, RemoteError> {
        let (mut reply, receiver) = tokio::sync::oneshot::channel();
        let context = self.clone();
        crate::session::runtime().map_err(|_|RemoteError::RemoteFailure)?.spawn(async move {
            let permit = tokio::select! {
                _ = reply.closed() => return,
                permit = context.slots.clone().acquire_owned() => match permit { Ok(value) => value, Err(_) => return },
            };
            // Never abandon the channel-confirmation receiver on caller cancel:
            // if the caller left, deliver-to-closed drops the lease and sends CLOSE.
            // A peer that never confirms is disconnected at the bounded deadline.
            let result = match tokio::time::timeout(REQUEST_TIMEOUT,context.handle.channel_open_session()).await {
                Ok(Ok(channel)) => Ok(RemoteChannel { channel: Some(channel), permit: Some(permit) }),
                Ok(Err(_)) => Err(RemoteError::ConnectionLost),
                Err(_) => { context.disconnect.send_replace(true); Err(RemoteError::Timeout) },
            };
            drop(reply.send(result));
        });
        receiver.await.map_err(|_| RemoteError::ConnectionLost)?
    }
}

/// UniFFI futures are polled by Swift, so all network futures are explicitly
/// driven by the existing Tokio runtime. Dropping the caller aborts its job.
pub(crate) async fn on_runtime<T: Send + 'static>(
    future: impl Future<Output = Result<T, RemoteError>> + Send + 'static,
) -> Result<T, RemoteError> {
    struct AbortOnDrop<T>(tokio::task::JoinHandle<T>);
    impl<T> Drop for AbortOnDrop<T> {
        fn drop(&mut self) {
            self.0.abort();
        }
    }
    let runtime = crate::session::runtime().map_err(|_| RemoteError::RemoteFailure)?;
    let mut job = AbortOnDrop(runtime.spawn(future));
    (&mut job.0).await.map_err(|_| RemoteError::Cancelled)?
}

pub(crate) async fn checked<T>(
    mut cancelled: watch::Receiver<bool>,
    mut local: watch::Receiver<bool>,
    future: impl Future<Output = Result<T, RemoteError>>,
) -> Result<T, RemoteError> {
    tokio::select! {
        biased;
        _ = cancelled.wait_for(|v| *v) => Err(RemoteError::ConnectionLost),
        _ = local.wait_for(|v| *v) => Err(RemoteError::Cancelled),
        result = tokio::time::timeout(REQUEST_TIMEOUT, future) => result.map_err(|_| RemoteError::Timeout)?,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn explicit_cancellation_releases_a_pending_bridge_operation() {
        let operation = RemoteCancellation::default();
        let cancel = operation.clone();
        let running = tokio::spawn(async move {
            operation
                .run(std::future::pending::<Result<(), RemoteError>>())
                .await
        });
        tokio::task::yield_now().await;
        cancel.cancel();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), running)
                .await
                .unwrap()
                .unwrap(),
            Err(RemoteError::Cancelled)
        );
    }
}
