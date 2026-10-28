use conndock_core::{
    Authentication, ConnectionOptions, EndReason, ErrorCode, SessionEvent, SshSession,
};
use std::time::Duration;
use tokio::io::AsyncReadExt;
use zeroize::Zeroizing;

async fn finish(session: &SshSession) -> SessionEvent {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            for event in session.poll_events() {
                if matches!(event, SessionEvent::Ended { .. }) {
                    return event;
                }
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("session must stop within a bounded time")
}

#[tokio::test]
async fn cancellation_during_handshake_closes_the_socket() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut options = ConnectionOptions::new(
        "127.0.0.1".into(),
        listener.local_addr().unwrap().port(),
        "test".into(),
    );
    options.timeout = Duration::from_secs(1);
    let session = SshSession::start(
        options,
        Authentication::Password(Zeroizing::new(String::new())),
    )
    .unwrap();
    let (mut stream, _) = listener.accept().await.unwrap();
    let mut bytes = [0u8; 1024];
    assert!(stream.read(&mut bytes).await.unwrap() > 0);
    session.disconnect();
    assert!(matches!(
        finish(&session).await,
        SessionEvent::Ended {
            reason: EndReason::User,
            error: None,
            ..
        }
    ));
    assert!(session.is_finished());
    let closed = tokio::time::timeout(Duration::from_secs(1), stream.read(&mut bytes))
        .await
        .unwrap();
    assert!(
        matches!(closed, Ok(0) | Err(_)),
        "cancellation must release transport"
    );
    assert_eq!(session.send_input(vec![1]), Err(ErrorCode::NotConnected));
}

#[tokio::test]
async fn a_silent_tcp_peer_cannot_hold_a_session_forever() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut options = ConnectionOptions::new(
        "127.0.0.1".into(),
        listener.local_addr().unwrap().port(),
        "test".into(),
    );
    options.timeout = Duration::from_millis(40);
    options.trust_timeout = Duration::from_secs(1);
    let started = std::time::Instant::now();
    let session = SshSession::start(
        options,
        Authentication::Password(Zeroizing::new(String::new())),
    )
    .unwrap();
    let (_stream, _) = listener.accept().await.unwrap();
    assert!(matches!(
        finish(&session).await,
        SessionEvent::Ended {
            error: Some(ErrorCode::Timeout),
            ..
        }
    ));
    assert!(
        started.elapsed() < Duration::from_millis(500),
        "a peer that has not provided a host key must not get the human trust timeout"
    );
}

#[tokio::test]
async fn refused_connection_reports_a_sanitized_failure() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let options = ConnectionOptions::new("127.0.0.1".into(), port, "test".into());
    let session = SshSession::start(
        options,
        Authentication::Password(Zeroizing::new(String::new())),
    )
    .unwrap();
    assert!(matches!(
        finish(&session).await,
        SessionEvent::Ended {
            error: Some(ErrorCode::ConnectionFailed),
            ..
        }
    ));
}

#[tokio::test]
async fn dropping_the_owner_closes_an_unfinished_handshake() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let options = ConnectionOptions::new(
        "127.0.0.1".into(),
        listener.local_addr().unwrap().port(),
        "test".into(),
    );
    let session = SshSession::start(
        options,
        Authentication::Password(Zeroizing::new(String::new())),
    )
    .unwrap();
    let (mut stream, _) = listener.accept().await.unwrap();
    let mut bytes = [0u8; 1024];
    assert!(stream.read(&mut bytes).await.unwrap() > 0);
    drop(session);
    let closed = tokio::time::timeout(Duration::from_secs(1), stream.read(&mut bytes))
        .await
        .unwrap();
    assert!(matches!(closed, Ok(0) | Err(_)));
}
