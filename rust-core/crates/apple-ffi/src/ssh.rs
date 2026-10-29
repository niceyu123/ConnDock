use conndock_core as core;
use std::sync::Arc;
use std::time::Duration;
use zeroize::Zeroizing;

macro_rules! mapped_enum {
    ($name:ident, $source:ty, $($variant:ident),+ $(,)?) => {
        #[derive(Clone, Copy, Debug, uniffi::Enum)]
        pub enum $name { $($variant),+ }
        impl From<$source> for $name {
            fn from(value: $source) -> Self { match value { $(<$source>::$variant => Self::$variant),+ } }
        }
    }
}
mapped_enum!(
    FailureCode,
    core::ErrorCode,
    InvalidConfiguration,
    ConnectionFailed,
    Timeout,
    HostKeyRejected,
    HostKeyChanged,
    UnsupportedHostKey,
    AuthenticationFailed,
    AgentUnavailable,
    AgentAccessDenied,
    InvalidPrivateKey,
    UnsupportedPrivateKey,
    PtyFailed,
    ConnectionLost,
    NotConnected,
    InputBackpressure,
    Internal
);
mapped_enum!(
    SessionState,
    core::ConnectionState,
    Connecting,
    VerifyingHostKey,
    Authenticating,
    Connected,
    Disconnecting,
    Disconnected,
    Failed
);
mapped_enum!(DisconnectReason, core::EndReason, User, Remote, Failure);

#[derive(Debug, uniffi::Error)]
pub enum SshError {
    Failure { code: FailureCode },
}
impl std::fmt::Display for SshError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for SshError {}
impl From<core::ErrorCode> for SshError {
    fn from(value: core::ErrorCode) -> Self {
        Self::Failure { code: value.into() }
    }
}

#[derive(uniffi::Record)]
pub struct ConnectionRequest {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub trusted_fingerprint: Option<String>,
    pub columns: u32,
    pub rows: u32,
    pub timeout_seconds: u32,
}

// No Debug: these values contain secrets and are not metadata.
#[derive(uniffi::Enum)]
pub enum AuthenticationRequest {
    Password {
        password: String,
    },
    Ed25519 {
        private_key: String,
        passphrase: Option<String>,
    },
    KeyboardInteractive,
    Agent {
        socket_path: String,
        fingerprint: String,
    },
}

#[derive(uniffi::Record)]
pub struct AuthenticationPrompt {
    pub prompt: String,
    pub echo: bool,
}

#[derive(uniffi::Enum)]
pub enum SshEvent {
    AuthenticationChallenge {
        id: u64,
        name: String,
        instructions: String,
        prompts: Vec<AuthenticationPrompt>,
    },
    StateChanged {
        state: SessionState,
    },
    HostKey {
        algorithm: String,
        fingerprint: String,
    },
    Output {
        data: Vec<u8>,
    },
    Ended {
        reason: DisconnectReason,
        error: Option<FailureCode>,
        exit_status: Option<u32>,
    },
}
impl From<core::SessionEvent> for SshEvent {
    fn from(value: core::SessionEvent) -> Self {
        match value {
            core::SessionEvent::AuthenticationChallenge {
                id,
                name,
                instructions,
                prompts,
            } => Self::AuthenticationChallenge {
                id,
                name,
                instructions,
                prompts: prompts
                    .into_iter()
                    .map(|p| AuthenticationPrompt {
                        prompt: p.prompt,
                        echo: p.echo,
                    })
                    .collect(),
            },
            core::SessionEvent::State(state) => Self::StateChanged {
                state: state.into(),
            },
            core::SessionEvent::HostKey {
                algorithm,
                fingerprint,
            } => Self::HostKey {
                algorithm,
                fingerprint,
            },
            core::SessionEvent::Output(data) => Self::Output { data },
            core::SessionEvent::Ended {
                reason,
                error,
                exit_status,
            } => Self::Ended {
                reason: reason.into(),
                error: error.map(Into::into),
                exit_status,
            },
        }
    }
}

#[derive(uniffi::Object)]
pub struct SshConnection {
    inner: Arc<core::SshSession>,
}

#[uniffi::export]
impl SshConnection {
    #[uniffi::constructor]
    pub fn new(
        request: ConnectionRequest,
        authentication: AuthenticationRequest,
    ) -> Result<Arc<Self>, SshError> {
        connect_advanced(request, authentication, false, false, None)
    }
    pub fn respond_authentication(&self, id: u64, responses: Vec<String>) -> Result<(), SshError> {
        self.inner
            .respond_authentication(id, responses)
            .map_err(Into::into)
    }
    pub fn poll_events(&self) -> Vec<SshEvent> {
        self.inner
            .poll_events()
            .into_iter()
            .map(Into::into)
            .collect()
    }
    pub fn confirm_host_key(&self, fingerprint: String, accept: bool) -> Result<(), SshError> {
        self.inner
            .confirm_host_key(&fingerprint, accept)
            .map_err(Into::into)
    }
    pub fn send_input(&self, bytes: Vec<u8>) -> Result<(), SshError> {
        self.inner.send_input(bytes).map_err(Into::into)
    }
    pub fn set_input_suspended(&self, suspended: bool) {
        self.inner.set_input_suspended(suspended);
    }
    pub fn resize(&self, columns: u32, rows: u32) -> Result<(), SshError> {
        self.inner.resize(columns, rows).map_err(Into::into)
    }
    pub fn disconnect(&self) {
        self.inner.disconnect();
    }
    pub fn is_finished(&self) -> bool {
        self.inner.is_finished()
    }
    pub async fn check_connection(
        &self,
        operation: Arc<crate::RemoteOperation>,
    ) -> Result<(), crate::RemoteFailure> {
        self.inner
            .check_connection(operation.inner.clone())
            .await
            .map_err(Into::into)
    }
    pub async fn execute_command(
        &self,
        command: String,
        timeout_seconds: u32,
        operation: Arc<crate::RemoteOperation>,
    ) -> Result<crate::CommandOutput, crate::RemoteFailure> {
        Ok(self
            .inner
            .execute_command(command, timeout_seconds, operation.inner.clone())
            .await?
            .into())
    }
    pub async fn service_status(
        &self,
        service_name: String,
        operation: Arc<crate::RemoteOperation>,
    ) -> Result<crate::ServiceStatus, crate::RemoteFailure> {
        Ok(self
            .inner
            .service_status(service_name, operation.inner.clone())
            .await?
            .into())
    }
    pub async fn open_files(&self) -> Result<Arc<crate::RemoteFiles>, crate::RemoteFailure> {
        Ok(crate::RemoteFiles::wrap(self.inner.open_sftp().await?))
    }
    pub async fn open_files_cancellable(
        &self,
        operation: Arc<crate::RemoteOperation>,
    ) -> Result<Arc<crate::RemoteFiles>, crate::RemoteFailure> {
        Ok(crate::RemoteFiles::wrap(
            self.inner
                .open_sftp_cancellable(operation.inner.clone())
                .await?,
        ))
    }
    pub fn start_linux_monitor(&self) -> Result<Arc<crate::RemoteMonitor>, crate::RemoteFailure> {
        Ok(crate::RemoteMonitor::wrap(self.inner.linux_monitor()?))
    }
}

#[uniffi::export]
pub fn connect_advanced(
    request: ConnectionRequest,
    authentication: AuthenticationRequest,
    transport_only: bool,
    allow_interactive: bool,
    jump: Option<Arc<SshConnection>>,
) -> Result<Arc<SshConnection>, SshError> {
    let mut options = core::ConnectionOptions::new(request.host, request.port, request.username);
    options.trusted_fingerprint = request.trusted_fingerprint;
    options.size = core::TerminalSize::new(request.columns, request.rows)?;
    options.timeout = Duration::from_secs(request.timeout_seconds.into());
    options.mode = if transport_only {
        core::SessionMode::Transport
    } else {
        core::SessionMode::Terminal
    };
    options.allow_interactive = allow_interactive;
    let auth = match authentication {
        AuthenticationRequest::KeyboardInteractive => core::Authentication::KeyboardInteractive,
        AuthenticationRequest::Agent {
            socket_path,
            fingerprint,
        } => core::Authentication::Agent {
            socket_path,
            fingerprint,
        },
        AuthenticationRequest::Password { password } => {
            core::Authentication::Password(Zeroizing::new(password))
        }
        AuthenticationRequest::Ed25519 {
            private_key,
            passphrase,
        } => core::Authentication::Ed25519 {
            private_key: Zeroizing::new(private_key),
            passphrase: passphrase.map(Zeroizing::new),
        },
    };
    let session = match jump {
        Some(parent) => core::SshSession::start_via(options, auth, parent.inner.clone())?,
        None => core::SshSession::start(options, auth)?,
    };
    Ok(Arc::new(SshConnection {
        inner: Arc::new(session),
    }))
}
