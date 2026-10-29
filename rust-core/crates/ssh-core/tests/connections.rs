//! Opt-in real SSH protocol tests. Fixture keys and agent live only in ignored build/.
use conndock_core::*;
use std::{env, sync::Arc, time::Duration};
use zeroize::Zeroizing;

fn options() -> ConnectionOptions {
    let mut o = ConnectionOptions::new(
        env::var("CONNDOCK_TEST_HOST").unwrap(),
        env::var("CONNDOCK_TEST_PORT").unwrap().parse().unwrap(),
        env::var("CONNDOCK_TEST_USER").unwrap(),
    );
    o.trusted_fingerprint = Some(env::var("CONNDOCK_TEST_FINGERPRINT").unwrap());
    o.mode = SessionMode::Transport;
    o.timeout = Duration::from_secs(5);
    o.trust_timeout = Duration::from_secs(5);
    o
}
fn key() -> Authentication {
    Authentication::Ed25519 {
        private_key: Zeroizing::new(
            std::fs::read_to_string(env::var("CONNDOCK_TEST_KEY_FILE").unwrap()).unwrap(),
        ),
        passphrase: None,
    }
}
async fn connected(s: &SshSession) {
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            for e in s.poll_events() {
                match e {
                    SessionEvent::State(ConnectionState::Connected) => return,
                    SessionEvent::Ended { error, .. } => panic!("connection ended: {error:?}"),
                    _ => {}
                }
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
}
async fn finished(s: &SshSession) {
    tokio::time::timeout(Duration::from_secs(3), async {
        while !s.is_finished() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
#[ignore = "requires isolated OpenSSH with PermitTTY no"]
async fn transport_only_supports_sftp_exec_and_rejects_terminal_input() {
    let s = SshSession::start(options(), key()).unwrap();
    connected(&s).await;
    assert_eq!(s.send_input(vec![65]), Err(ErrorCode::NotConnected));
    let files = s.open_sftp().await.unwrap();
    let op = RemoteCancellation::default();
    let output = s
        .execute_command("printf transport-ok".into(), 5, op)
        .await
        .unwrap();
    assert_eq!(output.stdout, b"transport-ok");
    drop(files);
    s.disconnect();
    finished(&s).await;
}

#[tokio::test]
#[ignore = "requires isolated OpenSSH forwarding"]
async fn jump_transport_verifies_target_and_closing_child_preserves_parent() {
    let parent = Arc::new(SshSession::start(options(), key()).unwrap());
    connected(&parent).await;
    let mut target = options();
    target.host = "127.0.0.1".into();
    target.port = env::var("CONNDOCK_TEST_TARGET_PORT")
        .ok()
        .map(|s| s.parse().unwrap())
        .unwrap_or(22);
    let child = SshSession::start_via(target.clone(), key(), parent.clone()).unwrap();
    connected(&child).await;
    child.disconnect();
    finished(&child).await;
    assert!(!parent.is_finished());
    target.trusted_fingerprint = Some(format!("SHA256:{}", "A".repeat(43)));
    let changed = SshSession::start_via(target, key(), parent.clone()).unwrap();
    finished(&changed).await;
    assert!(changed.poll_events().iter().any(|e| matches!(
        e,
        SessionEvent::Ended {
            error: Some(ErrorCode::HostKeyChanged),
            ..
        }
    )));
    parent.disconnect();
    finished(&parent).await;
}

#[tokio::test]
#[ignore = "requires isolated ssh-agent with the fixture key"]
async fn agent_uses_only_the_explicit_public_key_fingerprint() {
    let fingerprint = env::var("CONNDOCK_TEST_AGENT_FINGERPRINT").unwrap();
    let socket_path = env::var("SSH_AUTH_SOCK").unwrap();
    let s = SshSession::start(
        options(),
        Authentication::Agent {
            socket_path: socket_path.clone(),
            fingerprint,
        },
    )
    .unwrap();
    connected(&s).await;
    s.disconnect();
    finished(&s).await;
    let denied = SshSession::start(
        options(),
        Authentication::Agent {
            socket_path,
            fingerprint: format!("SHA256:{}", "A".repeat(43)),
        },
    )
    .unwrap();
    finished(&denied).await;
    assert!(denied.poll_events().iter().any(|e| matches!(
        e,
        SessionEvent::Ended {
            error: Some(ErrorCode::AuthenticationFailed),
            ..
        }
    )));
}

struct InteractiveServer {
    round: usize,
    rounds: usize,
}
impl russh::server::Handler for InteractiveServer {
    type Error = russh::Error;
    async fn auth_password(
        &mut self,
        _: &str,
        _: &str,
    ) -> Result<russh::server::Auth, Self::Error> {
        Ok(russh::server::Auth::Reject {
            proceed_with_methods: Some(russh::MethodSet::from(
                &[russh::MethodKind::KeyboardInteractive][..],
            )),
            partial_success: true,
        })
    }
    async fn auth_keyboard_interactive(
        &mut self,
        _: &str,
        _: &str,
        response: Option<russh::server::Response<'_>>,
    ) -> Result<russh::server::Auth, Self::Error> {
        if let Some(mut answers) = response {
            let expected: &[u8] = if self.round == 1 {
                b"first-fixture-answer"
            } else {
                b"second-fixture-answer"
            };
            if answers.next().as_deref() != Some(expected) {
                return Ok(russh::server::Auth::reject());
            }
            if self.round == self.rounds {
                return Ok(russh::server::Auth::Accept);
            }
        }
        self.round += 1;
        Ok(russh::server::Auth::Partial {
            name: "Fixture MFA".into(),
            instructions: "Two rounds".into(),
            prompts: vec![(format!("Round {}", self.round).into(), false)].into(),
        })
    }
}

async fn interactive_server() -> (ConnectionOptions, tokio::task::JoinHandle<()>) {
    interactive_server_rounds(2).await
}

async fn interactive_server_rounds(
    rounds: usize,
) -> (ConnectionOptions, tokio::task::JoinHandle<()>) {
    let key = russh::keys::decode_secret_key(
        &std::fs::read_to_string(env::var("CONNDOCK_TEST_KEY_FILE").unwrap()).unwrap(),
        None,
    )
    .unwrap();
    let fingerprint = key
        .public_key()
        .fingerprint(russh::keys::HashAlg::Sha256)
        .to_string();
    let config = Arc::new(russh::server::Config {
        keys: vec![key],
        auth_rejection_time: Duration::from_millis(1),
        auth_rejection_time_initial: Some(Duration::from_millis(1)),
        ..Default::default()
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut o = options();
    o.port = listener.local_addr().unwrap().port();
    o.trusted_fingerprint = Some(fingerprint);
    o.allow_interactive = true;
    let task = tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let config = config.clone();
            tokio::spawn(async move {
                if let Ok(running) = russh::server::run_stream(
                    config,
                    stream,
                    InteractiveServer { round: 0, rounds },
                )
                .await
                {
                    let _ = running.await;
                }
            });
        }
    });
    (o, task)
}

#[tokio::test]
#[ignore = "requires fixture host key for real SSH keyboard-interactive server"]
async fn mfa_accepts_success_after_the_last_allowed_round() {
    let (o, server) = interactive_server_rounds(16).await;
    let s = SshSession::start(o, Authentication::KeyboardInteractive).unwrap();
    let mut count = 0;
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            for event in s.poll_events() {
                match event {
                    SessionEvent::AuthenticationChallenge { id, .. } => {
                        count += 1;
                        let response = if count == 1 {
                            "first-fixture-answer"
                        } else {
                            "second-fixture-answer"
                        };
                        s.respond_authentication(id, vec![response.into()]).unwrap();
                    }
                    SessionEvent::State(ConnectionState::Connected) => return,
                    SessionEvent::Ended { error, .. } => panic!("last MFA round ended: {error:?}"),
                    _ => {}
                }
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(count, 16);
    s.disconnect();
    finished(&s).await;
    server.abort();
}

#[tokio::test]
#[ignore = "requires fixture host key for real SSH keyboard-interactive server"]
async fn mfa_multiround_rejects_stale_answers_and_cancels_pending_prompts() {
    let (o, server) = interactive_server().await;
    let s = SshSession::start(
        o.clone(),
        Authentication::Password(Zeroizing::new("fixture".into())),
    )
    .unwrap();
    let mut count = 0;
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            for event in s.poll_events() {
                match event {
                    SessionEvent::AuthenticationChallenge { id, prompts, .. } => {
                        count += 1;
                        assert_eq!(prompts.len(), 1);
                        assert!(!prompts[0].echo);
                        assert!(
                            s.respond_authentication(id + 100, vec!["stale".into()])
                                .is_err()
                        );
                        assert!(s.respond_authentication(id, Vec::new()).is_err());
                        let response = if count == 1 {
                            "first-fixture-answer"
                        } else {
                            "second-fixture-answer"
                        };
                        s.respond_authentication(id, vec![response.into()]).unwrap();
                        assert!(s.respond_authentication(id, vec![response.into()]).is_err());
                    }
                    SessionEvent::State(ConnectionState::Connected) => return,
                    SessionEvent::Ended { error, .. } => panic!("MFA ended: {error:?}"),
                    _ => {}
                }
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(count, 2);
    s.disconnect();
    finished(&s).await;
    let pending = SshSession::start(o, Authentication::KeyboardInteractive).unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if pending
                .poll_events()
                .iter()
                .any(|e| matches!(e, SessionEvent::AuthenticationChallenge { .. }))
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    pending.disconnect();
    finished(&pending).await;
    assert!(
        pending
            .respond_authentication(1, vec!["late".into()])
            .is_err()
    );
    server.abort();
}

#[tokio::test]
#[ignore = "requires fixture host key for real SSH keyboard-interactive server"]
async fn mfa_wrong_answers_and_noninteractive_mode_fail_closed() {
    let (o, server) = interactive_server().await;
    let s = SshSession::start(o.clone(), Authentication::KeyboardInteractive).unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(SessionEvent::AuthenticationChallenge { id, .. }) = s
                .poll_events()
                .into_iter()
                .find(|e| matches!(e, SessionEvent::AuthenticationChallenge { .. }))
            {
                s.respond_authentication(id, vec!["incorrect-fixture-answer".into()])
                    .unwrap();
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    finished(&s).await;
    assert!(s.poll_events().iter().any(|e| matches!(
        e,
        SessionEvent::Ended {
            error: Some(ErrorCode::AuthenticationFailed),
            ..
        }
    )));
    let mut automated = o;
    automated.allow_interactive = false;
    let denied = SshSession::start(automated, Authentication::KeyboardInteractive).unwrap();
    finished(&denied).await;
    let events = denied.poll_events();
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, SessionEvent::AuthenticationChallenge { .. }))
    );
    assert!(events.iter().any(|e| matches!(
        e,
        SessionEvent::Ended {
            error: Some(ErrorCode::AuthenticationFailed),
            ..
        }
    )));
    server.abort();
}
