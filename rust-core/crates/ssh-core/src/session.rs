use russh::keys::PublicKeyOrCertificate;
use russh::{ChannelMsg, client, keys};
use std::net::Shutdown;
use std::sync::{
    Arc, Mutex, MutexGuard, OnceLock, Weak,
    atomic::{AtomicBool, Ordering},
};
use std::time::Duration;
use tokio::sync::{Semaphore, mpsc, oneshot, watch};
use zeroize::Zeroizing;

const OUTPUT_CAPACITY: usize = 64;
const INPUT_CAPACITY: usize = 64;
pub const MAX_INPUT_BYTES: usize = 16 * 1024;
const MAX_OUTPUT_BYTES: usize = 32 * 1024;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorCode {
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
    Internal,
}

impl std::fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for ErrorCode {}
impl From<russh::Error> for ErrorCode {
    fn from(_: russh::Error) -> Self {
        Self::ConnectionLost
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConnectionState {
    Connecting,
    VerifyingHostKey,
    Authenticating,
    Connected,
    Disconnecting,
    Disconnected,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndReason {
    User,
    Remote,
    Failure,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionEvent {
    State(ConnectionState),
    HostKey {
        algorithm: String,
        fingerprint: String,
    },
    Output(Vec<u8>),
    AuthenticationChallenge {
        id: u64,
        name: String,
        instructions: String,
        prompts: Vec<AuthenticationPrompt>,
    },
    Ended {
        reason: EndReason,
        error: Option<ErrorCode>,
        exit_status: Option<u32>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthenticationPrompt {
    pub prompt: String,
    pub echo: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionMode {
    Terminal,
    Transport,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerminalSize {
    pub columns: u32,
    pub rows: u32,
}
impl TerminalSize {
    pub fn new(columns: u32, rows: u32) -> Result<Self, ErrorCode> {
        if !(1..=1000).contains(&columns) || !(1..=1000).contains(&rows) {
            return Err(ErrorCode::InvalidConfiguration);
        }
        Ok(Self { columns, rows })
    }
}

#[derive(Clone, Debug)]
pub struct ConnectionOptions {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub trusted_fingerprint: Option<String>,
    pub size: TerminalSize,
    pub timeout: Duration,
    pub trust_timeout: Duration,
    pub mode: SessionMode,
    pub allow_interactive: bool,
}
impl ConnectionOptions {
    pub fn new(host: String, port: u16, username: String) -> Self {
        Self {
            host,
            port,
            username,
            trusted_fingerprint: None,
            size: TerminalSize {
                columns: 80,
                rows: 24,
            },
            timeout: Duration::from_secs(20),
            trust_timeout: Duration::from_secs(120),
            mode: SessionMode::Terminal,
            allow_interactive: false,
        }
    }
    pub fn validate(&self) -> Result<(), ErrorCode> {
        if self.host.is_empty()
            || self.host.len() > 253
            || self
                .host
                .chars()
                .any(|c| c.is_whitespace() || c.is_control() || c == '/' || c == '@')
            || self.port == 0
            || self.username.is_empty()
            || self.username.len() > 256
            || self.username.chars().any(char::is_control)
            || self.timeout.is_zero()
            || self.timeout > Duration::from_secs(120)
            || self.trust_timeout.is_zero()
            || self.trust_timeout > Duration::from_secs(300)
        {
            return Err(ErrorCode::InvalidConfiguration);
        }
        TerminalSize::new(self.size.columns, self.size.rows)?;
        if let Some(fp) = &self.trusted_fingerprint {
            HostKeyPolicy::validate_fingerprint(fp)?;
        }
        Ok(())
    }
}

pub struct HostKeyPolicy;
impl HostKeyPolicy {
    fn validate_fingerprint(fp: &str) -> Result<(), ErrorCode> {
        let hash = fp
            .strip_prefix("SHA256:")
            .ok_or(ErrorCode::InvalidConfiguration)?;
        if hash.len() != 43
            || !hash
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'+' || c == b'/')
        {
            return Err(ErrorCode::InvalidConfiguration);
        }
        Ok(())
    }
    /// false means an explicit user decision is still required, never accept-all.
    pub fn evaluate(trusted: Option<&str>, received: &str) -> Result<bool, ErrorCode> {
        Self::validate_fingerprint(received)?;
        match trusted {
            Some(fp) => {
                Self::validate_fingerprint(fp)?;
                if fp == received {
                    Ok(true)
                } else {
                    Err(ErrorCode::HostKeyChanged)
                }
            }
            None => Ok(false),
        }
    }
}

// Deliberately no Debug or Clone: credentials must never enter diagnostics.
pub enum Authentication {
    Password(Zeroizing<String>),
    Ed25519 {
        private_key: Zeroizing<String>,
        passphrase: Option<Zeroizing<String>>,
    },
    KeyboardInteractive,
    Agent {
        socket_path: String,
        fingerprint: String,
    },
}

struct InputGate(watch::Sender<(u64, bool)>);
impl Default for InputGate {
    fn default() -> Self {
        Self(watch::channel((0, false)).0)
    }
}
impl InputGate {
    fn epoch(&self) -> Option<u64> {
        let state = self.0.borrow();
        if state.1 { None } else { Some(state.0) }
    }
    fn set_suspended(&self, suspended: bool) {
        self.0.send_modify(|state| {
            state.0 = state.0.wrapping_add(1);
            state.1 = suspended;
        });
    }
    fn accepts(&self, epoch: u64) -> bool {
        self.epoch() == Some(epoch)
    }
    async fn run_if_current<F: std::future::Future>(
        &self,
        epoch: u64,
        sending: F,
    ) -> Option<F::Output> {
        let mut changes = self.0.subscribe();
        tokio::select! {
            biased;
            _ = changes.wait_for(|state| state.1 || state.0 != epoch) => None,
            result = sending => Some(result),
        }
    }
}
struct InputPacket {
    bytes: Vec<u8>,
    epoch: u64,
}

struct Control {
    cancelled: watch::Sender<bool>,
    trust_waiting: watch::Sender<bool>,
    decision: watch::Sender<Option<bool>>,
    pending_fingerprint: Mutex<Option<String>>,
    socket: Mutex<Option<std::net::TcpStream>>,
    connected: AtomicBool,
    finished: AtomicBool,
    final_event: Mutex<Option<SessionEvent>>,
    client: Mutex<Option<Weak<client::Handle<Handler>>>>,
    auxiliary_slots: Arc<Semaphore>,
    input_gate: Arc<InputGate>,
    terminal: bool,
    auth_reply: Mutex<Option<PendingAuthentication>>,
}
struct PendingAuthentication {
    id: u64,
    count: usize,
    reply: oneshot::Sender<Zeroizing<Vec<String>>>,
}
impl Control {
    fn close_socket(&self) {
        if let Some(socket) = lock(&self.socket).take() {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
    fn cancel(&self) {
        self.cancelled.send_replace(true);
        self.close_socket();
        lock(&self.auth_reply).take();
    }
}

/// Owned by the Apple session. The worker owns Control, not this object, so Drop
/// cancels even when nobody is polling; it cannot create a self-retaining task.
pub struct SshSession {
    control: Arc<Control>,
    events: Mutex<mpsc::Receiver<SessionEvent>>,
    input: mpsc::Sender<InputPacket>,
    size: watch::Sender<TerminalSize>,
}
impl Drop for SshSession {
    fn drop(&mut self) {
        self.control.cancel();
    }
}

pub(crate) fn runtime() -> Result<&'static tokio::runtime::Runtime, ErrorCode> {
    static RUNTIME: OnceLock<Result<tokio::runtime::Runtime, ErrorCode>> = OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .thread_name("conndock-io")
                .build()
                .map_err(|_| ErrorCode::Internal)
        })
        .as_ref()
        .map_err(|e| *e)
}

impl SshSession {
    pub fn start(options: ConnectionOptions, auth: Authentication) -> Result<Self, ErrorCode> {
        Self::start_routed(options, auth, None)
    }
    pub fn start_via(
        options: ConnectionOptions,
        auth: Authentication,
        jump: Arc<SshSession>,
    ) -> Result<Self, ErrorCode> {
        jump.remote_context().map_err(|_| ErrorCode::NotConnected)?;
        Self::start_routed(options, auth, Some(jump))
    }
    fn start_routed(
        options: ConnectionOptions,
        auth: Authentication,
        jump: Option<Arc<SshSession>>,
    ) -> Result<Self, ErrorCode> {
        options.validate()?;
        if let Authentication::Agent {
            socket_path,
            fingerprint,
        } = &auth
        {
            if !cfg!(target_os = "macos")
                || !socket_path.starts_with('/')
                || socket_path.len() > 1024
                || socket_path.contains('\0')
            {
                return Err(ErrorCode::InvalidConfiguration);
            }
            HostKeyPolicy::validate_fingerprint(fingerprint)?;
        }
        let runtime = runtime()?;
        let (events_tx, events_rx) = mpsc::channel(OUTPUT_CAPACITY);
        let (input_tx, input_rx) = mpsc::channel(INPUT_CAPACITY);
        let (size_tx, size_rx) = watch::channel(options.size);
        let (cancel_tx, cancel_rx) = watch::channel(false);
        let (trust_waiting, _) = watch::channel(false);
        let (decision, _) = watch::channel(None);
        let control = Arc::new(Control {
            cancelled: cancel_tx,
            trust_waiting,
            decision,
            pending_fingerprint: Mutex::new(None),
            socket: Mutex::new(None),
            connected: AtomicBool::new(false),
            finished: AtomicBool::new(false),
            final_event: Mutex::new(None),
            client: Mutex::new(None),
            auxiliary_slots: Arc::new(Semaphore::new(8)),
            input_gate: Arc::new(InputGate::default()),
            terminal: options.mode == SessionMode::Terminal,
            auth_reply: Mutex::new(None),
        });
        runtime.spawn(worker(
            options,
            auth,
            control.clone(),
            events_tx,
            input_rx,
            size_rx,
            cancel_rx,
            jump,
        ));
        Ok(Self {
            control,
            events: Mutex::new(events_rx),
            input: input_tx,
            size: size_tx,
        })
    }
    /// Non-blocking; at most 64 KiB plus one SSH packet per UI frame.
    pub fn poll_events(&self) -> Vec<SessionEvent> {
        let mut receiver = lock(&self.events);
        let mut events = Vec::new();
        let mut bytes = 0;
        while events.len() < 64 && bytes < 64 * 1024 {
            match receiver.try_recv() {
                Ok(event) => {
                    if let SessionEvent::Output(data) = &event {
                        bytes += data.len();
                    }
                    events.push(event);
                }
                Err(_) => break,
            }
        }
        if receiver.is_empty()
            && let Some(event) = lock(&self.control.final_event).take()
        {
            events.push(event);
        }
        events
    }
    pub fn confirm_host_key(&self, fingerprint: &str, accept: bool) -> Result<(), ErrorCode> {
        let mut pending = lock(&self.control.pending_fingerprint);
        if pending.as_deref() != Some(fingerprint) {
            return Err(ErrorCode::HostKeyRejected);
        }
        pending.take();
        self.control.decision.send_replace(Some(accept));
        Ok(())
    }
    pub fn send_input(&self, bytes: Vec<u8>) -> Result<(), ErrorCode> {
        if !self.control.terminal || !self.control.connected.load(Ordering::Acquire) {
            return Err(ErrorCode::NotConnected);
        }
        if bytes.is_empty() {
            return Ok(());
        }
        if bytes.len() > MAX_INPUT_BYTES {
            return Err(ErrorCode::InputBackpressure);
        }
        let epoch = self
            .control
            .input_gate
            .epoch()
            .ok_or(ErrorCode::NotConnected)?;
        self.input
            .try_send(InputPacket { bytes, epoch })
            .map_err(|e| match e {
                mpsc::error::TrySendError::Full(_) => ErrorCode::InputBackpressure,
                mpsc::error::TrySendError::Closed(_) => ErrorCode::NotConnected,
            })
    }
    pub fn respond_authentication(&self, id: u64, responses: Vec<String>) -> Result<(), ErrorCode> {
        let responses = Zeroizing::new(responses);
        let mut pending = lock(&self.control.auth_reply);
        let current = pending.as_ref().ok_or(ErrorCode::AuthenticationFailed)?;
        if current.id != id
            || current.count != responses.len()
            || responses.iter().any(|r| r.len() > 8192)
            || self.is_finished()
        {
            return Err(ErrorCode::AuthenticationFailed);
        }
        pending
            .take()
            .unwrap()
            .reply
            .send(responses)
            .map_err(|_| ErrorCode::AuthenticationFailed)
    }
    pub fn set_input_suspended(&self, suspended: bool) {
        self.control.input_gate.set_suspended(suspended);
    }
    pub fn resize(&self, columns: u32, rows: u32) -> Result<(), ErrorCode> {
        self.size.send_replace(TerminalSize::new(columns, rows)?);
        Ok(())
    }
    pub fn disconnect(&self) {
        self.control.cancel();
    }
    pub fn is_finished(&self) -> bool {
        self.control.finished.load(Ordering::Acquire)
    }
    pub(crate) fn remote_context(
        &self,
    ) -> Result<crate::remote::RemoteContext, crate::RemoteError> {
        if !self.control.connected.load(Ordering::Acquire) {
            return Err(crate::RemoteError::NotConnected);
        }
        let handle = lock(&self.control.client)
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or(crate::RemoteError::NotConnected)?;
        Ok(crate::remote::RemoteContext {
            handle,
            cancelled: self.control.cancelled.subscribe(),
            slots: self.control.auxiliary_slots.clone(),
            disconnect: self.control.cancelled.clone(),
        })
    }
}

pub(crate) struct Handler {
    control: Arc<Control>,
    events: mpsc::Sender<SessionEvent>,
    trusted: Option<String>,
    timeout: Duration,
}
struct TrustWaitGuard(watch::Sender<bool>);
impl Drop for TrustWaitGuard {
    fn drop(&mut self) {
        self.0.send_replace(false);
    }
}
impl client::Handler for Handler {
    type Error = ErrorCode;
    async fn check_server_key(
        &mut self,
        received: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        // Certificate authorities are outside Phase 1; do not accidentally trust
        // an uncertified certificate by hashing only its embedded public key.
        if received.certificate().is_some() {
            return Err(ErrorCode::UnsupportedHostKey);
        }
        let key = received.public_key();
        let fingerprint = key.fingerprint(keys::HashAlg::Sha256).to_string();
        if HostKeyPolicy::evaluate(self.trusted.as_deref(), &fingerprint)? {
            return Ok(true);
        }
        let mut decision = self.control.decision.subscribe();
        self.control.trust_waiting.send_replace(true);
        let _trust_wait = TrustWaitGuard(self.control.trust_waiting.clone());
        *lock(&self.control.pending_fingerprint) = Some(fingerprint.clone());
        self.events
            .send(SessionEvent::State(ConnectionState::VerifyingHostKey))
            .await
            .map_err(|_| ErrorCode::HostKeyRejected)?;
        self.events
            .send(SessionEvent::HostKey {
                algorithm: key.algorithm().to_string(),
                fingerprint: fingerprint.clone(),
            })
            .await
            .map_err(|_| ErrorCode::HostKeyRejected)?;
        let mut cancelled = self.control.cancelled.subscribe();
        let accepted = tokio::select! {
            biased;
            _ = cancelled.wait_for(|v| *v) => false,
            result = tokio::time::timeout(self.timeout, decision.wait_for(|v| v.is_some())) => {
                match result { Ok(Ok(value)) => *value == Some(true), _ => return Err(ErrorCode::Timeout) }
            }
        };
        lock(&self.control.pending_fingerprint).take();
        if !accepted {
            return Err(ErrorCode::HostKeyRejected);
        }
        self.trusted = Some(fingerprint);
        Ok(true)
    }
}

async fn timed<T>(
    duration: Duration,
    future: impl std::future::Future<Output = Result<T, ErrorCode>>,
) -> Result<T, ErrorCode> {
    tokio::time::timeout(duration, future)
        .await
        .map_err(|_| ErrorCode::Timeout)?
}

#[allow(clippy::too_many_arguments)] // Every receiver is independently owned by this session worker.
async fn worker(
    options: ConnectionOptions,
    auth: Authentication,
    control: Arc<Control>,
    events: mpsc::Sender<SessionEvent>,
    input: mpsc::Receiver<InputPacket>,
    size: watch::Receiver<TerminalSize>,
    mut cancelled: watch::Receiver<bool>,
    jump: Option<Arc<SshSession>>,
) {
    let result = tokio::select! {
        biased;
        _ = cancelled.wait_for(|v| *v) => Ok((EndReason::User, None)),
        result = run(options, auth, control.clone(), events.clone(), input, size, jump) => result,
    };
    // The run branch can observe the socket shutdown in the same poll that
    // cancel() sets this flag, after select already polled its cancel branch.
    // Preserve cancellation precedence before publishing the final outcome.
    let result = if *cancelled.borrow() {
        Ok((EndReason::User, None))
    } else {
        result
    };
    control.connected.store(false, Ordering::Release);
    control.cancelled.send_replace(true);
    lock(&control.client).take();
    control.close_socket();
    lock(&control.pending_fingerprint).take();
    lock(&control.auth_reply).take();
    let event = match result {
        Ok((reason, exit_status)) => SessionEvent::Ended {
            reason,
            error: None,
            exit_status,
        },
        Err(error) => SessionEvent::Ended {
            reason: EndReason::Failure,
            error: Some(error),
            exit_status: None,
        },
    };
    // A full output queue must not keep a disconnected task alive.
    *lock(&control.final_event) = Some(event);
    drop(events);
    control.finished.store(true, Ordering::Release);
}

async fn run(
    options: ConnectionOptions,
    auth: Authentication,
    control: Arc<Control>,
    events: mpsc::Sender<SessionEvent>,
    input: mpsc::Receiver<InputPacket>,
    mut size: watch::Receiver<TerminalSize>,
    jump: Option<Arc<SshSession>>,
) -> Result<(EndReason, Option<u32>), ErrorCode> {
    events
        .send(SessionEvent::State(ConnectionState::Connecting))
        .await
        .map_err(|_| ErrorCode::Internal)?;
    let stream: Box<dyn SshStream> = if let Some(parent) = &jump {
        let context = parent
            .remote_context()
            .map_err(|_| ErrorCode::NotConnected)?;
        Box::new(
            timed(options.timeout, async {
                context
                    .handle
                    .channel_open_direct_tcpip(
                        options.host.clone(),
                        options.port.into(),
                        "127.0.0.1",
                        0,
                    )
                    .await
                    .map(|channel| channel.into_stream())
                    .map_err(|_| ErrorCode::ConnectionFailed)
            })
            .await?,
        )
    } else {
        let tcp = timed(options.timeout, async {
            tokio::net::TcpStream::connect((options.host.as_str(), options.port))
                .await
                .map_err(|_| ErrorCode::ConnectionFailed)
        })
        .await?;
        tcp.set_nodelay(true)
            .map_err(|_| ErrorCode::ConnectionFailed)?;
        let socket = tcp.into_std().map_err(|_| ErrorCode::ConnectionFailed)?;
        *lock(&control.socket) = Some(socket.try_clone().map_err(|_| ErrorCode::Internal)?);
        let tcp = tokio::net::TcpStream::from_std(socket).map_err(|_| ErrorCode::Internal)?;
        Box::new(tcp)
    };
    let config = client::Config {
        keepalive_interval: Some(Duration::from_secs(15)),
        keepalive_max: 3,
        channel_buffer_size: 16,
        window_size: 256 * 1024,
        maximum_packet_size: MAX_OUTPUT_BYTES as u32,
        nodelay: true,
        ..Default::default()
    };
    let handler = Handler {
        control: control.clone(),
        events: events.clone(),
        trusted: options.trusted_fingerprint.clone(),
        timeout: options.trust_timeout,
    };
    // Pause only the network handshake budget while a real user trust decision
    // is pending. A silent peer never receives the longer human decision window.
    let mut handle = connect_ssh(
        Arc::new(config),
        stream,
        handler,
        options.timeout,
        control.trust_waiting.subscribe(),
    )
    .await?;
    events
        .send(SessionEvent::State(ConnectionState::Authenticating))
        .await
        .map_err(|_| ErrorCode::Internal)?;
    let result = timed(options.timeout, async {
        match auth {
            Authentication::Password(password) => handle
                .authenticate_password(&options.username, password.as_str())
                .await
                .map_err(|_| ErrorCode::ConnectionLost),
            Authentication::Ed25519 {
                private_key,
                passphrase,
            } => {
                let key =
                    keys::decode_secret_key(&private_key, passphrase.as_ref().map(|p| p.as_str()))
                        .map_err(|_| ErrorCode::InvalidPrivateKey)?;
                if key.algorithm() != keys::Algorithm::Ed25519 {
                    return Err(ErrorCode::UnsupportedPrivateKey);
                }
                handle
                    .authenticate_publickey(
                        &options.username,
                        keys::PrivateKeyWithHashAlg::new(Arc::new(key), None),
                    )
                    .await
                    .map_err(|_| ErrorCode::ConnectionLost)
            }
            Authentication::KeyboardInteractive => Ok(client::AuthResult::Failure {
                remaining_methods: russh::MethodSet::from(
                    &[russh::MethodKind::KeyboardInteractive][..],
                ),
                partial_success: true,
            }),
            Authentication::Agent {
                socket_path,
                fingerprint,
            } => {
                authenticate_agent(&mut handle, &options.username, &socket_path, &fingerprint).await
            }
        }
    })
    .await?;
    let authenticated = if result.success() {
        true
    } else if options.allow_interactive
        && matches!(result, client::AuthResult::Failure { partial_success: true, ref remaining_methods } if remaining_methods.contains(&russh::MethodKind::KeyboardInteractive))
    {
        authenticate_interactive(&mut handle, &options, &control, &events).await?
    } else {
        false
    };
    if !authenticated {
        return Err(ErrorCode::AuthenticationFailed);
    }
    if options.mode == SessionMode::Transport {
        let handle = Arc::new(handle);
        *lock(&control.client) = Some(Arc::downgrade(&handle));
        control.connected.store(true, Ordering::Release);
        events
            .send(SessionEvent::State(ConnectionState::Connected))
            .await
            .map_err(|_| ErrorCode::Internal)?;
        // Retain the authenticated handle and its owned jump until disconnected.
        while !handle.is_closed() {
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        return Err(ErrorCode::ConnectionLost);
    }
    let mut channel = timed(options.timeout, async {
        handle
            .channel_open_session()
            .await
            .map_err(|_| ErrorCode::PtyFailed)
    })
    .await?;
    let initial = *size.borrow_and_update();
    timed(options.timeout, async {
        channel
            .request_pty(
                true,
                "xterm-256color",
                initial.columns,
                initial.rows,
                0,
                0,
                &[],
            )
            .await
            .map_err(|_| ErrorCode::PtyFailed)?;
        expect_success(&mut channel, &events).await?;
        channel
            .request_shell(true)
            .await
            .map_err(|_| ErrorCode::PtyFailed)?;
        expect_success(&mut channel, &events).await
    })
    .await?;
    // Authentication is complete; auxiliary channels only need immutable access.
    // The worker retains the owner and Control keeps a Weak reference, so dropping
    // the Apple session still closes the transport and every auxiliary operation.
    let handle = Arc::new(handle);
    *lock(&control.client) = Some(Arc::downgrade(&handle));
    control.connected.store(true, Ordering::Release);
    events
        .send(SessionEvent::State(ConnectionState::Connected))
        .await
        .map_err(|_| ErrorCode::Internal)?;
    let (mut reader, writer) = channel.split();
    let writing = write_input(
        writer,
        input,
        size,
        options.timeout,
        control.input_gate.clone(),
    );
    tokio::pin!(writing);
    let mut writer_done = false;
    let mut operation_error = None;
    let mut exit_status = None;
    let mut channel_closed = false;
    let mut exit_signal = false;
    loop {
        tokio::select! {
            incoming = reader.wait() => match incoming {
                Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => {
                    for chunk in data.chunks(MAX_OUTPUT_BYTES) {
                        events.send(SessionEvent::Output(chunk.to_vec())).await.map_err(|_| ErrorCode::Internal)?;
                    }
                }
                Some(ChannelMsg::ExitStatus { exit_status: code }) => exit_status = Some(code),
                Some(ChannelMsg::ExitSignal { .. }) => exit_signal = true,
                Some(ChannelMsg::Close) => {
                    channel_closed = true;
                    control.connected.store(false, Ordering::Release);
                }
                None => {
                    if channel_closed && !exit_signal { return Ok((EndReason::Remote, exit_status)); }
                    return Err(operation_error.unwrap_or(ErrorCode::ConnectionLost));
                }
                _ => {}
            },
            // The writer is a separate polled future so a blocked SSH send window
            // never prevents us from draining output and processing WINDOW_ADJUST.
            result = &mut writing, if !writer_done && !handle.is_closed() && !channel_closed => {
                writer_done = true;
                operation_error = Some(result.err().unwrap_or(ErrorCode::ConnectionLost));
                control.connected.store(false, Ordering::Release);
                control.close_socket();
            }
        }
    }
}

async fn write_input(
    writer: russh::ChannelWriteHalf<client::Msg>,
    mut input: mpsc::Receiver<InputPacket>,
    mut size: watch::Receiver<TerminalSize>,
    timeout: Duration,
    input_gate: Arc<InputGate>,
) -> Result<(), ErrorCode> {
    loop {
        tokio::select! {
            data = input.recv() => {
                let Some(packet) = data else { return Ok(()); };
                if !input_gate.accepts(packet.epoch) { continue; }
                if let Some(result) = input_gate.run_if_current(packet.epoch,
                    timed(timeout, async { writer.data_bytes(packet.bytes).await.map_err(|_| ErrorCode::ConnectionLost) })).await {
                    result?;
                }
            },
            changed = size.changed() => {
                changed.map_err(|_| ErrorCode::ConnectionLost)?;
                let new_size = *size.borrow_and_update();
                timed(timeout, async { writer.window_change(new_size.columns, new_size.rows, 0, 0).await.map_err(|_| ErrorCode::ConnectionLost) }).await?;
            }
        }
    }
}

trait SshStream: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send> SshStream for T {}

async fn authenticate_agent(
    handle: &mut client::Handle<Handler>,
    username: &str,
    socket_path: &str,
    fingerprint: &str,
) -> Result<client::AuthResult, ErrorCode> {
    #[cfg(target_os = "macos")]
    {
        use keys::agent::{AgentIdentity, client::AgentClient};
        let mut agent =
            AgentClient::connect_uds(socket_path)
                .await
                .map_err(|error| match error {
                    keys::Error::IO(error)
                        if error.kind() == std::io::ErrorKind::PermissionDenied =>
                    {
                        ErrorCode::AgentAccessDenied
                    }
                    _ => ErrorCode::AgentUnavailable,
                })?;
        let identities = agent
            .request_identities()
            .await
            .map_err(|_| ErrorCode::AgentUnavailable)?;
        if identities.len() > 64 {
            return Err(ErrorCode::AuthenticationFailed);
        }
        let selected = identities
            .into_iter()
            .find_map(|identity| match identity {
                AgentIdentity::PublicKey { key, .. }
                    if key.fingerprint(keys::HashAlg::Sha256).to_string() == fingerprint =>
                {
                    Some(key)
                }
                _ => None,
            })
            .ok_or(ErrorCode::AuthenticationFailed)?;
        let hash = if matches!(selected.algorithm(), keys::Algorithm::Rsa { .. }) {
            Some(keys::HashAlg::Sha512)
        } else {
            None
        };
        handle
            .authenticate_publickey_with(username, selected, hash, &mut agent)
            .await
            .map_err(|_| ErrorCode::AuthenticationFailed)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (handle, username, socket_path, fingerprint);
        Err(ErrorCode::InvalidConfiguration)
    }
}

async fn authenticate_interactive(
    handle: &mut client::Handle<Handler>,
    options: &ConnectionOptions,
    control: &Control,
    events: &mpsc::Sender<SessionEvent>,
) -> Result<bool, ErrorCode> {
    let mut response = timed(options.timeout, async {
        handle
            .authenticate_keyboard_interactive_start(&options.username, None::<String>)
            .await
            .map_err(|_| ErrorCode::ConnectionLost)
    })
    .await?;
    for id in 1..=16 {
        match response {
            client::KeyboardInteractiveAuthResponse::Success => return Ok(true),
            client::KeyboardInteractiveAuthResponse::Failure { .. } => return Ok(false),
            client::KeyboardInteractiveAuthResponse::InfoRequest {
                name,
                instructions,
                prompts,
            } => {
                if prompts.len() > 8
                    || name.len() > 4096
                    || instructions.len() > 8192
                    || prompts.iter().any(|p| p.prompt.len() > 4096)
                {
                    return Err(ErrorCode::AuthenticationFailed);
                }
                let (tx, rx) = oneshot::channel();
                *lock(&control.auth_reply) = Some(PendingAuthentication {
                    id,
                    count: prompts.len(),
                    reply: tx,
                });
                events
                    .send(SessionEvent::AuthenticationChallenge {
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
                    })
                    .await
                    .map_err(|_| ErrorCode::Internal)?;
                let answers = tokio::time::timeout(options.trust_timeout, rx)
                    .await
                    .map_err(|_| ErrorCode::Timeout)?
                    .map_err(|_| ErrorCode::AuthenticationFailed)?;
                response = timed(options.timeout, async {
                    handle
                        .authenticate_keyboard_interactive_respond(
                            answers.iter().cloned().collect(),
                        )
                        .await
                        .map_err(|_| ErrorCode::ConnectionLost)
                })
                .await?;
            }
        }
    }
    // The last permitted answer may already have produced a terminal response.
    // Do not require a seventeenth iteration merely to observe that success.
    Ok(matches!(
        response,
        client::KeyboardInteractiveAuthResponse::Success
    ))
}

async fn connect_ssh(
    config: Arc<client::Config>,
    tcp: Box<dyn SshStream>,
    handler: Handler,
    timeout: Duration,
    mut trust_waiting: watch::Receiver<bool>,
) -> Result<client::Handle<Handler>, ErrorCode> {
    let connecting = client::connect_stream(config, tcp, handler);
    tokio::pin!(connecting);
    let mut remaining = timeout;
    let mut started = tokio::time::Instant::now();
    let mut waiting = false;
    loop {
        tokio::select! {
            biased;
            result = &mut connecting => return result,
            _ = tokio::time::sleep(remaining), if !waiting => return Err(ErrorCode::Timeout),
            changed = trust_waiting.changed() => {
                changed.map_err(|_| ErrorCode::ConnectionLost)?;
                if !waiting { remaining = remaining.saturating_sub(started.elapsed()); }
                waiting = *trust_waiting.borrow_and_update();
                started = tokio::time::Instant::now();
            }
        }
    }
}

async fn expect_success(
    channel: &mut russh::Channel<client::Msg>,
    events: &mpsc::Sender<SessionEvent>,
) -> Result<(), ErrorCode> {
    loop {
        match channel.wait().await {
            Some(ChannelMsg::Success) => return Ok(()),
            Some(ChannelMsg::WindowAdjusted { .. } | ChannelMsg::XonXoff { .. }) => {}
            Some(ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. }) => {
                for chunk in data.chunks(MAX_OUTPUT_BYTES) {
                    events
                        .send(SessionEvent::Output(chunk.to_vec()))
                        .await
                        .map_err(|_| ErrorCode::Internal)?;
                }
            }
            _ => return Err(ErrorCode::PtyFailed),
        }
    }
}

#[cfg(test)]
mod input_lifecycle_tests {
    use super::*;

    #[tokio::test]
    async fn suspension_cancels_a_write_waiting_for_the_remote_window() {
        let gate = Arc::new(InputGate::default());
        let epoch = gate.epoch().unwrap();
        let sent = Arc::new(AtomicBool::new(false));
        let (started, waiting) = tokio::sync::oneshot::channel();
        let (window_adjusted, window) = tokio::sync::oneshot::channel::<()>();
        let writer = {
            let gate = gate.clone();
            let sent = sent.clone();
            tokio::spawn(async move {
                gate.run_if_current(epoch, async move {
                    let _ = started.send(());
                    let _ = window.await;
                    sent.store(true, Ordering::Release);
                })
                .await
            })
        };
        waiting.await.unwrap();
        // A rapid background/foreground pair must still invalidate the old
        // waiting write, even when the window opens before it is polled again.
        gate.set_suspended(true);
        gate.set_suspended(false);
        let _ = window_adjusted.send(());
        let result = tokio::time::timeout(Duration::from_secs(1), writer)
            .await
            .unwrap()
            .unwrap();
        assert!(result.is_none());
        assert!(!sent.load(Ordering::Acquire));
    }

    #[test]
    fn suspension_rejects_already_queued_bytes_after_resume() {
        let gate = InputGate::default();
        let old = gate.epoch().unwrap();
        assert!(gate.accepts(old));
        gate.set_suspended(true);
        assert!(gate.epoch().is_none());
        assert!(!gate.accepts(old));
        gate.set_suspended(false);
        assert!(
            !gate.accepts(old),
            "pre-background bytes must never be replayed"
        );
        assert!(gate.accepts(gate.epoch().unwrap()));
    }
}
