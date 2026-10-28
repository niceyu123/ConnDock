//! Opt-in tests against an actual SSH service. No credentials or terminal output
//! are printed. See scripts/test-local-ssh.sh and docs/PHASE1-TESTING.md.
use conndock_core::{
    Authentication, ConnectionOptions, ConnectionState, EndReason, ErrorCode, SessionEvent,
    SshSession,
};
use std::{env, time::Duration};
use zeroize::Zeroizing;

fn options() -> ConnectionOptions {
    let mut options = ConnectionOptions::new(
        env::var("CONNDOCK_TEST_HOST").expect("test host is required"),
        env::var("CONNDOCK_TEST_PORT")
            .expect("test port is required")
            .parse()
            .unwrap(),
        env::var("CONNDOCK_TEST_USER").expect("test username is required"),
    );
    options.trusted_fingerprint =
        Some(env::var("CONNDOCK_TEST_FINGERPRINT").expect("trusted fingerprint is required"));
    options.timeout = Duration::from_secs(5);
    options.trust_timeout = Duration::from_secs(5);
    options
}
fn key_auth() -> Authentication {
    let content = Zeroizing::new(
        std::fs::read_to_string(
            env::var("CONNDOCK_TEST_KEY_FILE").expect("private key file is required"),
        )
        .expect("private key file must be readable"),
    );
    let passphrase = env::var("CONNDOCK_TEST_PASSPHRASE_FILE").ok().map(|path| {
        Zeroizing::new(
            std::fs::read_to_string(path)
                .expect("passphrase file must be readable")
                .trim_end_matches(['\r', '\n'])
                .to_owned(),
        )
    });
    Authentication::Ed25519 {
        private_key: content,
        passphrase,
    }
}
async fn wait_for(
    session: &SshSession,
    mut predicate: impl FnMut(&SessionEvent) -> bool,
) -> SessionEvent {
    let mut last_state = None;
    let mut output_bytes = 0;
    let result = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            for event in session.poll_events() {
                if let SessionEvent::State(state) = &event { last_state = Some(*state); }
                if let SessionEvent::Output(bytes) = &event { output_bytes += bytes.len(); }
                if predicate(&event) { return event; }
                if let SessionEvent::Ended { reason, error, exit_status } = event {
                    panic!("session ended before the expected event: {reason:?}, {error:?}, status={exit_status:?}");
                }
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }).await;
    assert!(
        result.is_ok(),
        "expected SSH event within deadline: last_state={last_state:?}, output_bytes={output_bytes}"
    );
    result.unwrap()
}
async fn connected(session: &SshSession) {
    if let Ok(marker) = env::var("CONNDOCK_TEST_READY_MARKER") {
        // The SSH shell-request acknowledgement is not a shell-ready signal.
        // The local fixture supplies an actual PS1 prompt so shell startup
        // cannot flush the first test command. Inspect the whole event stream,
        // including output batched with the Connected event.
        let mut authenticated = false;
        let mut output = Vec::new();
        wait_for(session, |event| {
            match event {
                SessionEvent::State(ConnectionState::Connected) => authenticated = true,
                SessionEvent::Output(bytes) => output.extend_from_slice(bytes),
                _ => {}
            }
            assert!(output.len() < 1024 * 1024);
            authenticated
                && output
                    .windows(marker.len())
                    .any(|value| value == marker.as_bytes())
        })
        .await;
        return;
    }
    wait_for(session, |e| {
        matches!(e, SessionEvent::State(ConnectionState::Connected))
    })
    .await;
}
async fn output_contains(session: &SshSession, expected: &[u8]) {
    let mut output = Vec::new();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        for event in session.poll_events() {
            match event {
                SessionEvent::Output(bytes) => output.extend_from_slice(&bytes),
                SessionEvent::Ended { reason, error, .. } => {
                    panic!("SSH ended while waiting for marker: {reason:?}, {error:?}")
                }
                _ => {}
            }
        }
        assert!(output.len() < 1024 * 1024, "test output must stay bounded");
        if output
            .windows(expected.len())
            .any(|window| window == expected)
        {
            return;
        }
        if std::time::Instant::now() > deadline {
            let has = |needle: &[u8]| output.windows(needle.len()).any(|w| w == needle);
            panic!(
                "SSH marker timeout: expected_bytes={}, bytes={}, raw_prefix={}, raw_suffix={}, command_error={}, permission_error={}",
                expected.len(),
                output.len(),
                has(b"__RAW_"),
                has(b"READY__"),
                has(b"not found"),
                has(b"Permission denied")
            );
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}
async fn exercise_pty(session: &SshSession) {
    connected(session).await;
    session
        .send_input(b"stty -echo; printf '\\n__SSH_READY__\\n'\n".to_vec())
        .unwrap();
    output_contains(session, b"\r\n__SSH_READY__\r\n").await;
    if let Ok(directory) = env::var("CONNDOCK_TEST_WORK_DIRECTORY") {
        let quoted = directory.replace('\'', "'\\''");
        session
            .send_input(format!("cd '{quoted}'\n").into_bytes())
            .unwrap();
    }
    session
        .send_input(b"printf '__PWD__'; pwd; ls -la; printf '\\n__LIST_DONE__\\n'\n".to_vec())
        .unwrap();
    output_contains(session, b"\r\n__LIST_DONE__\r\n").await;
    session
        .send_input("printf '\\033[31m中文🙂\\033[0m\\n'\n".as_bytes().to_vec())
        .unwrap();
    output_contains(session, "\u{1b}[31m中文🙂\u{1b}[0m".as_bytes()).await;
    session.resize(101, 37).unwrap();
    session.send_input(b"stty size\n".to_vec()).unwrap();
    output_contains(session, b"37 101\r\n").await;
    session.send_input(b"sleep 10\n".to_vec()).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    session
        .send_input(b"\x03printf '\\n__CTRL_C__\\n'\n".to_vec())
        .unwrap();
    output_contains(session, b"\r\n__CTRL_C__\r\n").await;
}

#[tokio::test]
#[ignore = "requires an explicitly configured real SSH service"]
async fn openssh_key_pty_and_lifecycle() {
    let session = SshSession::start(options(), key_auth()).unwrap();
    exercise_pty(&session).await;
    session
        .send_input(b"printf '\\n__FINAL_OUTPUT__\\n'; exit 7\n".to_vec())
        .unwrap();
    let mut final_output = Vec::new();
    assert!(matches!(
        wait_for(&session, |e| {
            if let SessionEvent::Output(bytes) = e {
                final_output.extend_from_slice(bytes);
            }
            matches!(e, SessionEvent::Ended { .. })
        })
        .await,
        SessionEvent::Ended {
            reason: EndReason::Remote,
            error: None,
            exit_status: Some(7)
        }
    ));
    assert!(
        final_output.windows(16).any(|s| s == b"__FINAL_OUTPUT__"),
        "output sent immediately before exit must not be lost"
    );

    let reconnected = SshSession::start(options(), key_auth()).unwrap();
    connected(&reconnected).await;
    reconnected.disconnect();
    assert!(matches!(
        wait_for(&reconnected, |e| matches!(e, SessionEvent::Ended { .. })).await,
        SessionEvent::Ended {
            reason: EndReason::User,
            error: None,
            ..
        }
    ));

    let mut changed = options();
    changed.trusted_fingerprint = Some(format!("SHA256:{}", "A".repeat(43)));
    let rejected = SshSession::start(changed, key_auth()).unwrap();
    assert!(matches!(
        wait_for(&rejected, |e| matches!(e, SessionEvent::Ended { .. })).await,
        SessionEvent::Ended {
            error: Some(ErrorCode::HostKeyChanged),
            ..
        }
    ));

    let mut unknown = options();
    unknown.trusted_fingerprint = None;
    let untrusted = SshSession::start(unknown.clone(), key_auth()).unwrap();
    let event = wait_for(&untrusted, |e| matches!(e, SessionEvent::HostKey { .. })).await;
    if let SessionEvent::HostKey { fingerprint, .. } = event {
        untrusted.confirm_host_key(&fingerprint, false).unwrap();
    }
    assert!(matches!(
        wait_for(&untrusted, |e| matches!(e, SessionEvent::Ended { .. })).await,
        SessionEvent::Ended {
            error: Some(ErrorCode::HostKeyRejected),
            ..
        }
    ));
    let accepted = SshSession::start(unknown, key_auth()).unwrap();
    let event = wait_for(&accepted, |e| matches!(e, SessionEvent::HostKey { .. })).await;
    if let SessionEvent::HostKey { fingerprint, .. } = event {
        accepted.confirm_host_key(&fingerprint, true).unwrap();
    }
    connected(&accepted).await;
    accepted.disconnect();

    let invalid = SshSession::start(
        options(),
        Authentication::Ed25519 {
            private_key: Zeroizing::new(String::new()),
            passphrase: None,
        },
    )
    .unwrap();
    assert!(matches!(
        wait_for(&invalid, |e| matches!(e, SessionEvent::Ended { .. })).await,
        SessionEvent::Ended {
            error: Some(ErrorCode::InvalidPrivateKey),
            ..
        }
    ));
}

#[tokio::test]
#[ignore = "requires a real SSH service with password authentication enabled"]
async fn openssh_password_pty_and_wrong_password() {
    let password = Zeroizing::new(
        std::fs::read_to_string(
            env::var("CONNDOCK_TEST_PASSWORD_FILE").expect("password file is required"),
        )
        .expect("password file must be readable")
        .trim_end_matches(['\r', '\n'])
        .to_owned(),
    );
    let session = SshSession::start(options(), Authentication::Password(password)).unwrap();
    exercise_pty(&session).await;
    session.disconnect();
    let wrong = format!("invalid-{:?}", std::time::SystemTime::now());
    let failed =
        SshSession::start(options(), Authentication::Password(Zeroizing::new(wrong))).unwrap();
    assert!(matches!(
        wait_for(&failed, |e| matches!(e, SessionEvent::Ended { .. })).await,
        SessionEvent::Ended {
            error: Some(ErrorCode::AuthenticationFailed),
            ..
        }
    ));
}

#[tokio::test]
#[ignore = "requires a real SSH service"]
async fn openssh_abrupt_transport_loss_and_full_output_cancellation() {
    let upstream = options();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut proxied = options();
    proxied.host = "127.0.0.1".into();
    proxied.port = listener.local_addr().unwrap().port();
    let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
    let proxy = tokio::spawn(async move {
        let (mut inbound, _) = listener.accept().await.unwrap();
        let mut outbound = tokio::net::TcpStream::connect((upstream.host.as_str(), upstream.port))
            .await
            .unwrap();
        tokio::select! { _ = stopped => {}, _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound) => {} }
    });
    let interrupted = SshSession::start(proxied, key_auth()).unwrap();
    connected(&interrupted).await;
    stop.send(()).unwrap();
    proxy.await.unwrap();
    assert!(
        matches!(
            wait_for(&interrupted, |e| matches!(e, SessionEvent::Ended { .. })).await,
            SessionEvent::Ended {
                reason: EndReason::Failure,
                error: Some(ErrorCode::ConnectionLost),
                ..
            }
        ),
        "abrupt TCP loss must not be reported as a clean remote close"
    );

    let busy = SshSession::start(options(), key_auth()).unwrap();
    connected(&busy).await;
    busy.send_input(b"head -c 4194304 /dev/zero | tr '\\0' A\n".to_vec())
        .unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    busy.disconnect();
    tokio::time::timeout(Duration::from_secs(2), async {
        while !busy.is_finished() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    // No polling was necessary for cancellation to finish, even with output pending.
}

#[tokio::test]
#[ignore = "requires a real SSH service with stty and cat"]
async fn openssh_bidirectional_window_flow_control() {
    let session = SshSession::start(options(), key_auth()).unwrap();
    connected(&session).await;
    session
        .send_input(
            b"exec /bin/sh -c \"stty raw -echo; printf '__RAW_''READY__'; exec cat\"\n".to_vec(),
        )
        .unwrap();
    output_contains(&session, b"__RAW_READY__").await;
    let total = 4 * 1024 * 1024;
    let mut sent = 0;
    let mut received = 0;
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while received < total {
        assert!(
            std::time::Instant::now() < deadline,
            "bidirectional SSH window flow control must make progress"
        );
        if sent < total {
            let count = (total - sent).min(16 * 1024);
            match session.send_input(vec![b'A'; count]) {
                Ok(()) => sent += count,
                Err(ErrorCode::InputBackpressure) => {}
                Err(_) => panic!("input stream must stay connected"),
            }
        }
        for event in session.poll_events() {
            match event {
                SessionEvent::Output(bytes) => {
                    received += bytes.iter().filter(|&&byte| byte == b'A').count()
                }
                SessionEvent::Ended { .. } => {
                    panic!("duplex session must not end before all bytes return")
                }
                _ => {}
            }
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    assert_eq!(sent, total);
    assert_eq!(received, total);
    session.disconnect();
}

#[tokio::test]
#[ignore = "requires an SSH fixture with a known shell prompt and interactive top"]
async fn openssh_interactive_top() {
    let prompt = env::var("CONNDOCK_TEST_READY_MARKER")
        .expect("interactive top verification requires the fixture shell prompt");
    let session = SshSession::start(options(), key_auth()).unwrap();
    connected(&session).await;
    session
        .send_input(b"stty -echo; printf '\\n__TOP_READY__\\n'\n".to_vec())
        .unwrap();
    output_contains(&session, b"\r\n__TOP_READY__\r\n").await;
    session.send_input(b"top\n".to_vec()).unwrap();
    let mut output = Vec::new();
    wait_for(&session, |event| {
        if let SessionEvent::Output(bytes) = event {
            output.extend_from_slice(bytes);
        }
        assert!(output.len() < 1024 * 1024);
        [b"Processes:".as_slice(), b"Tasks:".as_slice()]
            .iter()
            .any(|label| output.windows(label.len()).any(|window| window == *label))
    })
    .await;
    session.send_input(vec![3]).unwrap();
    // Linux TTYs flush queued input when processing SIGINT. Wait for the shell
    // to regain its PTY before sending the next command, as a user would.
    output_contains(&session, prompt.as_bytes()).await;
    session
        .send_input(b"printf '\\n__TOP_RETURNED__\\n'\n".to_vec())
        .unwrap();
    output_contains(&session, b"\r\n__TOP_RETURNED__\r\n").await;
    session.disconnect();
}

#[tokio::test]
#[ignore = "requires a real SSH service"]
async fn openssh_rejected_authentication() {
    // In the local fixture password auth is disabled. This proves rejection
    // propagation, not successful password login or a password-enabled server.
    let password = Zeroizing::new(format!("invalid-{:?}", std::time::SystemTime::now()));
    let rejected = SshSession::start(options(), Authentication::Password(password)).unwrap();
    assert!(matches!(
        wait_for(&rejected, |e| matches!(e, SessionEvent::Ended { .. })).await,
        SessionEvent::Ended {
            error: Some(ErrorCode::AuthenticationFailed),
            ..
        }
    ));
    if let Ok(path) = env::var("CONNDOCK_TEST_UNAUTHORIZED_KEY_FILE") {
        let key = Zeroizing::new(std::fs::read_to_string(path).unwrap());
        let rejected = SshSession::start(
            options(),
            Authentication::Ed25519 {
                private_key: key,
                passphrase: None,
            },
        )
        .unwrap();
        assert!(matches!(
            wait_for(&rejected, |e| matches!(e, SessionEvent::Ended { .. })).await,
            SessionEvent::Ended {
                error: Some(ErrorCode::AuthenticationFailed),
                ..
            }
        ));
    }
}
