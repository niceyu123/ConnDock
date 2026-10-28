//! Destructive operations are restricted to the script-created loopback fixture.
//! No credential, file content, terminal output, or server message is logged.
use conndock_core::{
    Authentication, ConnectionOptions, ConnectionState, RemoteCancellation, RemoteError,
    SessionEvent, SshSession,
    sftp::{SftpClient, TRANSFER_CHUNK_BYTES, join_remote_name},
};
use std::{
    env,
    time::{Duration, Instant},
};
use zeroize::Zeroizing;

async fn connect() -> SshSession {
    connect_port(env::var("CONNDOCK_TEST_PORT").unwrap().parse().unwrap()).await
}

async fn connect_port(port: u16) -> SshSession {
    assert_eq!(env::var("CONNDOCK_TEST_ISOLATED").as_deref(), Ok("1"));
    assert_eq!(env::var("CONNDOCK_TEST_HOST").as_deref(), Ok("127.0.0.1"));
    let mut options = ConnectionOptions::new(
        "127.0.0.1".into(),
        port,
        env::var("CONNDOCK_TEST_USER").unwrap(),
    );
    options.trusted_fingerprint = Some(env::var("CONNDOCK_TEST_FINGERPRINT").unwrap());
    let key = Zeroizing::new(
        std::fs::read_to_string(env::var("CONNDOCK_TEST_KEY_FILE").unwrap()).unwrap(),
    );
    let session = SshSession::start(
        options,
        Authentication::Ed25519 {
            private_key: key,
            passphrase: None,
        },
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        for event in session.poll_events() {
            match event {
                SessionEvent::State(ConnectionState::Connected) => return session,
                SessionEvent::Ended { reason, error, .. } => {
                    panic!("connection failed: {reason:?}, {error:?}")
                }
                _ => {}
            }
        }
        assert!(Instant::now() < deadline, "connection deadline");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
#[ignore = "cuts a real TCP proxy in the isolated loopback fixture"]
async fn openssh_sftp_abrupt_network_loss_and_retry() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let destination = env::var("CONNDOCK_TEST_PORT")
        .unwrap()
        .parse::<u16>()
        .unwrap();
    let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
    let proxy = tokio::spawn(async move {
        let (mut inbound, _) = listener.accept().await.unwrap();
        let mut outbound = tokio::net::TcpStream::connect(("127.0.0.1", destination))
            .await
            .unwrap();
        tokio::select! { _ = stopped => {}, _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound) => {} }
    });
    let session = connect_port(port).await;
    let client = session.open_sftp().await.unwrap();
    let directory = join_remote_name(&work(), "network-cut-test").unwrap();
    client.create_directory(directory.clone()).await.unwrap();
    let path = join_remote_name(&directory, "interrupted.bin").unwrap();
    let writer = client
        .open_writer(path.clone(), 1024 * 1024, false)
        .await
        .unwrap();
    writer
        .write_chunk(vec![23; TRANSFER_CHUNK_BYTES])
        .await
        .unwrap();
    stop.send(()).unwrap();
    proxy.await.unwrap();
    let result = writer.write_chunk(vec![23; TRANSFER_CHUNK_BYTES]).await;
    assert_eq!(result, Err(RemoteError::ConnectionLost));
    let deadline = Instant::now() + Duration::from_secs(5);
    while !session.is_finished() {
        session.poll_events();
        assert!(
            Instant::now() < deadline,
            "broken transport must release the session"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    drop(writer);
    client.close();
    let retry = connect().await;
    let recovered = retry.open_sftp().await.unwrap();
    let entries = recovered
        .list_directory(directory.clone())
        .await
        .unwrap()
        .entries;
    assert!(
        !entries.iter().any(|entry| entry.name == "interrupted.bin"),
        "partial upload must not be committed"
    );
    // A dead server connection cannot remove its temporary upload; clean only
    // this test-owned directory through the newly authenticated connection.
    for entry in entries {
        recovered
            .remove(join_remote_name(&directory, &entry.name).unwrap())
            .await
            .unwrap();
    }
    upload(
        &recovered,
        path.clone(),
        b"retried after network loss",
        false,
    )
    .await;
    recovered.remove(path).await.unwrap();
    recovered.remove(directory).await.unwrap();
    recovered.close();
    retry.disconnect();
}

fn work() -> String {
    env::var("CONNDOCK_TEST_WORK_DIRECTORY").unwrap()
}

#[tokio::test]
#[ignore = "requires the isolated OpenSSH fixture"]
async fn openssh_mcp_exec_is_separate_bounded_and_cancellable() {
    let session = connect().await;
    let output = session
        .execute_command(
            "printf 'A\\000B'; printf 'separate stderr' >&2; exit 7".into(),
            10,
            RemoteCancellation::default(),
        )
        .await
        .unwrap();
    assert_eq!(output.stdout, b"A\0B");
    assert_eq!(output.stderr, b"separate stderr");
    assert_eq!(output.exit_code, Some(7));
    assert!(!output.truncated);
    let output = session
        .execute_command(
            "dd if=/dev/zero bs=65536 count=2 2>/dev/null".into(),
            10,
            RemoteCancellation::default(),
        )
        .await
        .unwrap();
    assert!(output.truncated);
    assert_eq!(output.stdout.len() + output.stderr.len(), 65_536);
    assert_eq!(output.exit_code, None);
    let started = Instant::now();
    assert!(matches!(
        session
            .execute_command("sleep 10".into(), 1, RemoteCancellation::default())
            .await,
        Err(RemoteError::Timeout)
    ));
    assert!(started.elapsed() < Duration::from_secs(3));
    let operation = RemoteCancellation::default();
    let cancel = operation.clone();
    let cancelling = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(100)).await;
        cancel.cancel();
    });
    let started = Instant::now();
    assert!(matches!(
        session
            .execute_command("sleep 10".into(), 10, operation)
            .await,
        Err(RemoteError::Cancelled)
    ));
    cancelling.await.unwrap();
    assert!(started.elapsed() < Duration::from_secs(3));
    let output = session
        .execute_command(
            "printf 'still connected'".into(),
            10,
            RemoteCancellation::default(),
        )
        .await
        .unwrap();
    assert_eq!(output.stdout, b"still connected");
    assert_eq!(output.exit_code, Some(0));
    session.disconnect();
}

#[tokio::test]
#[ignore = "requires the isolated OpenSSH fixture"]
async fn openssh_mcp_service_status_is_fixed_and_structured() {
    let session = connect().await;
    assert!(matches!(
        session
            .service_status("sshd; id".into(), RemoteCancellation::default())
            .await,
        Err(RemoteError::InvalidServiceName)
    ));
    match session
        .service_status("ssh".into(), RemoteCancellation::default())
        .await
    {
        Ok(status) => {
            assert_eq!(status.name, "ssh.service");
            assert!(!status.load_state.is_empty());
            assert!(status.active_enter_timestamp.len() <= 128);
        }
        Err(error) => assert_eq!(
            error,
            RemoteError::Unsupported,
            "the disposable non-systemd fixture is explicitly unsupported"
        ),
    }
    session.disconnect();
}

#[cfg(unix)]
#[tokio::test]
#[ignore = "creates only test-owned paths in the isolated OpenSSH fixture"]
async fn openssh_mcp_directory_authorization_blocks_symlink_escape_and_large_results() {
    use std::os::unix::fs::symlink;
    let session = connect().await;
    let client = session.open_sftp().await.unwrap();
    let root = std::path::PathBuf::from(work()).join("mcp-authorized-directory");
    let allowed = root.join("allowed");
    let outside = root.join("allowed-other");
    std::fs::create_dir_all(&allowed).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::create_dir(allowed.join(".ssh")).unwrap();
    std::fs::write(allowed.join("visible.txt"), b"fixture").unwrap();
    std::fs::write(outside.join("outside.txt"), b"outside fixture").unwrap();
    symlink(&outside, allowed.join("escape")).unwrap();
    let path = allowed.to_str().unwrap().to_owned();
    let roots = vec![path.clone()];
    let listing = client
        .list_authorized_directory(path.clone(), roots.clone(), RemoteCancellation::default())
        .await
        .unwrap();
    assert!(
        listing
            .entries
            .iter()
            .any(|entry| entry.name == "visible.txt")
    );
    assert!(!listing.entries.iter().any(|entry| entry.name == ".ssh"));
    assert!(matches!(
        client
            .list_authorized_directory(
                outside.to_str().unwrap().into(),
                roots.clone(),
                RemoteCancellation::default()
            )
            .await,
        Err(RemoteError::PermissionDenied)
    ));
    assert!(matches!(
        client
            .list_authorized_directory(
                format!("{path}/escape"),
                roots.clone(),
                RemoteCancellation::default()
            )
            .await,
        Err(RemoteError::PermissionDenied)
    ));
    assert!(matches!(
        client
            .list_authorized_directory(
                format!("{path}/.ssh"),
                roots.clone(),
                RemoteCancellation::default()
            )
            .await,
        Err(RemoteError::InvalidPath)
    ));
    for index in 0..512 {
        std::fs::write(allowed.join(format!("bounded-{index:03}")), []).unwrap();
    }
    assert!(matches!(
        client
            .list_authorized_directory(path, roots, RemoteCancellation::default())
            .await,
        Err(RemoteError::DirectoryTooLarge)
    ));
    client.close();
    session.disconnect();
    std::fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[tokio::test]
#[ignore = "replaces only a test-owned directory in the isolated OpenSSH fixture"]
async fn openssh_mcp_directory_replaced_authorization_root_is_denied() {
    use std::os::unix::fs::symlink;
    let session = connect().await;
    let client = session.open_sftp().await.unwrap();
    let root = std::path::PathBuf::from(work()).join("mcp-replaced-authorization-root");
    let allowed = root.join("allowed");
    let outside = root.join("outside");
    std::fs::create_dir_all(&allowed).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(allowed.join("inside.txt"), b"inside fixture").unwrap();
    std::fs::write(outside.join("outside.txt"), b"outside fixture").unwrap();
    let path = allowed.to_str().unwrap().to_owned();
    let roots = vec![path.clone()];
    let initial = client
        .list_authorized_directory(path.clone(), roots.clone(), RemoteCancellation::default())
        .await
        .unwrap();
    assert!(
        initial
            .entries
            .iter()
            .any(|entry| entry.name == "inside.txt")
    );
    std::fs::rename(&allowed, root.join("original")).unwrap();
    symlink(&outside, &allowed).unwrap();
    // Docker Desktop's bind mount may publish a host-side rename asynchronously.
    // Observe the replacement through an independent unrestricted SFTP query
    // before exercising authorization; otherwise the test can query the old dir.
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let observed = client.list_directory(path.clone()).await.unwrap();
        if observed.path == outside.to_str().unwrap() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "fixture did not publish the symlink replacement"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let result = client
        .list_authorized_directory(path, roots, RemoteCancellation::default())
        .await;
    client.close();
    session.disconnect();
    std::fs::remove_dir_all(root).unwrap();
    assert!(
        matches!(result, Err(RemoteError::PermissionDenied)),
        "a replaced authorization root must never grant its new symlink destination: {:?}",
        result.as_ref().err()
    );
}

fn linux_baseline() -> Option<(Vec<u64>, u64, u64, f64)> {
    let container = env::var("CONNDOCK_TEST_CONTAINER_ID").ok()?;
    assert!(container.len() == 64 && container.bytes().all(|value| value.is_ascii_hexdigit()));
    let output = std::process::Command::new("docker").args(["exec", &container, "sh", "-c",
        "head -n 1 /proc/stat; awk -F '[: ]+' '/:/{if ($1 != \"lo\" && $2 != \"lo\") {rx+=$3;tx+=$11}} END {printf \"%.0f %.0f\\n\",rx,tx}' /proc/net/dev; cat /proc/uptime"])
        .output().unwrap();
    assert!(
        output.status.success(),
        "independent Linux baseline must execute"
    );
    let text = std::str::from_utf8(&output.stdout).unwrap();
    let mut lines = text.lines();
    let cpu = lines
        .next()
        .unwrap()
        .split_whitespace()
        .skip(1)
        .take(8)
        .map(|v| v.parse().unwrap())
        .collect::<Vec<u64>>();
    let network = lines
        .next()
        .unwrap()
        .split_whitespace()
        .map(|v| v.parse::<u64>().unwrap())
        .collect::<Vec<_>>();
    let uptime = lines
        .next()
        .unwrap()
        .split_whitespace()
        .next()
        .unwrap()
        .parse::<f64>()
        .unwrap();
    Some((cpu, network[0], network[1], uptime))
}

async fn upload(client: &SftpClient, path: String, bytes: &[u8], overwrite: bool) {
    let file = client
        .open_writer(path, bytes.len() as u64, overwrite)
        .await
        .unwrap();
    for chunk in bytes.chunks(TRANSFER_CHUNK_BYTES) {
        file.write_chunk(chunk.to_vec()).await.unwrap();
    }
    file.finish().await.unwrap();
}

#[tokio::test]
#[ignore = "requires the isolated OpenSSH fixture"]
async fn openssh_sftp_operations_conflicts_cancel_and_disconnect() {
    let session = connect().await;
    let client = session.open_sftp().await.unwrap();
    let root = client.list_directory(work()).await.unwrap().path;
    let directory = join_remote_name(&root, "SFTP 中文 ' ; $(id)").unwrap();
    client.create_directory(directory.clone()).await.unwrap();
    assert!(
        client
            .list_directory(directory.clone())
            .await
            .unwrap()
            .entries
            .is_empty()
    );
    let path = join_remote_name(&directory, "中文🙂 ' ; $(id).bin").unwrap();
    let bytes: Vec<u8> = (0..200_003).map(|i| (i % 251) as u8).collect();
    upload(&client, path.clone(), &bytes, false).await;
    let listed = client.list_directory(directory.clone()).await.unwrap();
    assert_eq!(listed.entries.len(), 1);
    assert_eq!(listed.entries[0].size, Some(bytes.len() as u64));
    assert!(matches!(
        client.open_writer(path.clone(), 1, false).await,
        Err(RemoteError::AlreadyExists)
    ));
    let reader = client.open_reader(path.clone()).await.unwrap();
    let mut received = Vec::new();
    loop {
        let chunk = reader.read_chunk().await.unwrap();
        if chunk.is_empty() {
            break;
        }
        assert!(chunk.len() <= TRANSFER_CHUNK_BYTES);
        received.extend(chunk);
    }
    reader.finish().await.unwrap();
    assert_eq!(received, bytes);
    let renamed = join_remote_name(&directory, "renamed.bin").unwrap();
    client.rename(path.clone(), renamed.clone()).await.unwrap();
    upload(&client, path.clone(), b"original", false).await;
    assert_eq!(
        client.rename(renamed.clone(), path.clone()).await,
        Err(RemoteError::AlreadyExists)
    );
    upload(&client, path.clone(), b"replacement", true).await;
    #[cfg(unix)]
    for mode in [0o755, 0o640] {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(container) = env::var("CONNDOCK_TEST_CONTAINER_ID") {
            assert!(
                container.len() == 64 && container.bytes().all(|value| value.is_ascii_hexdigit())
            );
            let status = std::process::Command::new("docker")
                .args([
                    "exec",
                    &container,
                    "chmod",
                    &format!("{mode:o}"),
                    "--",
                    &path,
                ])
                .status()
                .unwrap();
            assert!(status.success());
        } else {
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        }
        upload(&client, path.clone(), b"attributes preserved", true).await;
        let entry = client
            .list_directory(directory.clone())
            .await
            .unwrap()
            .entries
            .into_iter()
            .find(|entry| entry.name == "中文🙂 ' ; $(id).bin")
            .unwrap();
        assert_eq!(
            entry.permissions.unwrap() & 0o777,
            mode,
            "Replacing a file must preserve ordinary permissions"
        );
    }
    assert!(
        client.remove(directory.clone()).await.is_err(),
        "nonempty directory must not be deleted recursively"
    );
    let cancelled = join_remote_name(&directory, "cancelled.bin").unwrap();
    let writer = client
        .open_writer(cancelled.clone(), 4 * TRANSFER_CHUNK_BYTES as u64, false)
        .await
        .unwrap();
    writer
        .write_chunk(vec![7; TRANSFER_CHUNK_BYTES])
        .await
        .unwrap();
    writer.cancel();
    assert_eq!(
        writer.write_chunk(vec![7; TRANSFER_CHUNK_BYTES]).await,
        Err(RemoteError::Cancelled)
    );
    drop(writer);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let entries = client
            .list_directory(directory.clone())
            .await
            .unwrap()
            .entries;
        assert!(!entries.iter().any(|entry| entry.name == "cancelled.bin"));
        if !entries
            .iter()
            .any(|entry| entry.name.starts_with(".conndock-"))
        {
            break;
        }
        assert!(Instant::now() < deadline, "temporary upload cleanup");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let retry = client
        .open_writer(cancelled.clone(), 0, false)
        .await
        .unwrap();
    retry.finish().await.unwrap();
    client.remove(cancelled).await.unwrap();
    client.remove(path.clone()).await.unwrap();
    client.remove(renamed).await.unwrap();
    client.remove(directory).await.unwrap();
    let denied = env::var("CONNDOCK_TEST_DENIED_PATH").ok();
    if let Some(path) = denied {
        assert!(matches!(
            client.list_directory(path).await,
            Err(RemoteError::PermissionDenied)
        ));
    }
    let missing = client
        .open_reader(join_remote_name(&root, "does-not-exist.bin").unwrap())
        .await;
    assert!(matches!(missing, Err(RemoteError::NotFound)));
    session.disconnect();
    assert!(matches!(
        client.list_directory(root).await,
        Err(RemoteError::ConnectionLost)
    ));
    client.close();
    let reconnected = connect().await;
    reconnected
        .open_sftp()
        .await
        .unwrap()
        .list_directory(work())
        .await
        .unwrap();
    reconnected.disconnect();
}

#[tokio::test]
#[ignore = "requires a real Linux or macOS OpenSSH fixture"]
async fn openssh_monitor_matches_platform_and_stops() {
    let session = connect().await;
    let monitor = session.linux_monitor().unwrap();
    if env::var("CONNDOCK_TEST_EXPECT_LINUX").as_deref() == Ok("1") {
        let baseline_before = linux_baseline();
        let first = monitor.sample().await.unwrap();
        assert_eq!(first.cpu_percent, None);
        assert_eq!(first.receive_bytes_per_second, None);
        let file_client = session.open_sftp().await.unwrap();
        let rate_path = join_remote_name(&work(), "network-rate-baseline.bin").unwrap();
        upload(
            &file_client,
            rate_path.clone(),
            &vec![17; 4 * 1024 * 1024],
            false,
        )
        .await;
        tokio::time::sleep(Duration::from_millis(500)).await;
        let second = monitor.sample().await.unwrap();
        let baseline_after = linux_baseline();
        file_client.remove(rate_path).await.unwrap();
        file_client.close();
        assert!(second.system.starts_with("Linux "));
        assert!((0.0..=100.0).contains(&second.cpu_percent.unwrap()));
        assert!(second.memory_used <= second.memory_total && second.memory_total > 0);
        assert!(second.disk_used <= second.disk_total && second.disk_total > 0);
        assert!(second.receive_bytes_per_second.is_some());
        if let (Some(before), Some(after)) = (baseline_before, baseline_after) {
            let total: u64 = before.0.iter().zip(&after.0).map(|(a, b)| b - a).sum();
            let idle = after.0[3] + after.0[4] - before.0[3] - before.0[4];
            let cpu = (total - idle) as f64 / total as f64 * 100.0;
            assert!(
                (second.cpu_percent.unwrap() - cpu).abs() <= 10.0,
                "CPU within 10 percentage points of independent bracketing /proc baseline"
            );
            let elapsed = after.3 - before.3;
            for (measured, delta) in [
                (second.receive_bytes_per_second.unwrap(), after.1 - before.1),
                (
                    second.transmit_bytes_per_second.unwrap(),
                    after.2 - before.2,
                ),
            ] {
                let rate = delta as f64 / elapsed;
                assert!(
                    (measured - rate).abs() <= (rate * 0.5).max(128.0 * 1024.0),
                    "network within 50 percent or 128 KiB/s of independent bracketing baseline"
                );
            }
        }
        if let Ok(path) = env::var("CONNDOCK_TEST_BASELINE_FILE") {
            let baseline = std::fs::read_to_string(path).unwrap();
            let fields = baseline
                .split_whitespace()
                .map(|v| v.parse::<u64>().unwrap())
                .collect::<Vec<_>>();
            assert_eq!(second.memory_total, fields[0]);
            assert_eq!(second.disk_total, fields[1]);
            assert!(
                second.disk_used.abs_diff(fields[2]) < 64 * 1024 * 1024,
                "df used within 64 MiB of baseline"
            );
            assert!((second.uptime_seconds - fields[3] as f64).abs() < 300.0);
        }
    } else {
        assert_eq!(
            monitor.sample().await.unwrap_err(),
            RemoteError::Unsupported
        );
    }
    monitor.stop();
    assert_eq!(monitor.sample().await.unwrap_err(), RemoteError::Cancelled);
    let active = session.linux_monitor().unwrap();
    session.disconnect();
    assert_eq!(
        active.sample().await.unwrap_err(),
        RemoteError::ConnectionLost
    );
}

fn block(offset: u64) -> Vec<u8> {
    let mut bytes = (0..TRANSFER_CHUNK_BYTES)
        .map(|i| (i % 251) as u8)
        .collect::<Vec<_>>();
    bytes[..8].copy_from_slice(&offset.to_be_bytes());
    bytes
}
fn checksum(current: u64, bytes: &[u8]) -> u64 {
    bytes.iter().fold(current, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(1_099_511_628_211)
    })
}

#[tokio::test]
#[ignore = "transfers a real 2 GiB file in both directions; run with the measured test script"]
async fn openssh_sftp_two_gib_streaming() {
    const TOTAL: u64 = 2 * 1024 * 1024 * 1024;
    let session = connect().await;
    let client = session.open_sftp().await.unwrap();
    let path = join_remote_name(&work(), "conndock-two-gib.bin").unwrap();
    let writer = client
        .open_writer(path.clone(), TOTAL, false)
        .await
        .unwrap();
    let started = Instant::now();
    let mut uploaded = 0_u64;
    let mut upload_checksum = 14_695_981_039_346_656_037_u64;
    while uploaded < TOTAL {
        let bytes = block(uploaded);
        upload_checksum = checksum(upload_checksum, &bytes);
        writer.write_chunk(bytes).await.unwrap();
        uploaded += TRANSFER_CHUNK_BYTES as u64;
        if uploaded.is_multiple_of(256 * 1024 * 1024) {
            eprintln!("large upload: {uploaded} bytes");
        }
    }
    writer.finish().await.unwrap();
    drop(writer);
    let reader = client.open_reader(path.clone()).await.unwrap();
    assert_eq!(reader.size(), Some(TOTAL));
    let mut downloaded = 0_u64;
    let mut download_checksum = 14_695_981_039_346_656_037_u64;
    loop {
        let bytes = reader.read_chunk().await.unwrap();
        if bytes.is_empty() {
            break;
        }
        assert!(bytes.len() <= TRANSFER_CHUNK_BYTES);
        // Every returned byte is checked, including the offset-specific block header.
        let mut cursor = 0;
        while cursor < bytes.len() {
            let position = downloaded + cursor as u64;
            let expected = block(position - position % TRANSFER_CHUNK_BYTES as u64);
            let inside = (position % TRANSFER_CHUNK_BYTES as u64) as usize;
            let count = (bytes.len() - cursor).min(TRANSFER_CHUNK_BYTES - inside);
            assert_eq!(
                &bytes[cursor..cursor + count],
                &expected[inside..inside + count]
            );
            cursor += count;
        }
        download_checksum = checksum(download_checksum, &bytes);
        downloaded += bytes.len() as u64;
        if downloaded.is_multiple_of(256 * 1024 * 1024) {
            eprintln!("large download: {downloaded} bytes");
        }
    }
    reader.finish().await.unwrap();
    assert_eq!(downloaded, TOTAL);
    assert_eq!(download_checksum, upload_checksum);
    client.remove(path).await.unwrap();
    client.close();
    session.disconnect();
    eprintln!(
        "2 GiB in each direction verified byte-for-byte and by streaming checksum; elapsed={:?}",
        started.elapsed()
    );
}

#[tokio::test]
#[ignore = "requires the isolated loopback OpenSSH fixture"]
async fn openssh_connection_probe_is_nonexecuting_and_cancellable() {
    let session = connect().await;
    session
        .check_connection(RemoteCancellation::default())
        .await
        .unwrap();
    session.set_input_suspended(true);
    assert_eq!(
        session.send_input(b"printf should-not-run\n".to_vec()),
        Err(conndock_core::ErrorCode::NotConnected)
    );
    session
        .check_connection(RemoteCancellation::default())
        .await
        .unwrap();
    session.set_input_suspended(false);
    let cancelled = RemoteCancellation::default();
    cancelled.cancel();
    assert_eq!(
        session.check_connection(cancelled).await,
        Err(RemoteError::Cancelled)
    );
    let client = session.open_sftp().await.unwrap();
    assert!(
        !client
            .list_directory(work())
            .await
            .unwrap()
            .entries
            .is_empty()
    );
    client.close();
    session.disconnect();
    assert!(
        session
            .check_connection(RemoteCancellation::default())
            .await
            .is_err()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "90-second isolated SSH stability run; use scripts/test-stability.sh"]
async fn openssh_stability_multisession_and_channel_reuse() {
    let seconds = env::var("CONNDOCK_TEST_SOAK_SECONDS")
        .ok()
        .map(|s| s.parse::<u64>().unwrap())
        .unwrap_or(90);
    assert!((30..=600).contains(&seconds));
    let sessions = [
        connect().await,
        connect().await,
        connect().await,
        connect().await,
    ];
    let started = Instant::now();
    let mut rounds = 0;
    while started.elapsed() < Duration::from_secs(seconds) {
        for (index, session) in sessions.iter().enumerate() {
            session
                .check_connection(RemoteCancellation::default())
                .await
                .unwrap();
            let result = session
                .execute_command(
                    format!("printf 'stability-{index}'"),
                    3,
                    RemoteCancellation::default(),
                )
                .await
                .unwrap();
            assert_eq!(result.exit_code, Some(0));
            assert_eq!(result.stdout, format!("stability-{index}").as_bytes());
            assert!(!result.truncated);
            session.resize(80 + (rounds % 20) as u32, 24).unwrap();
            // Drain native PTY output as the real UI does, without logging it.
            assert!(
                !session
                    .poll_events()
                    .iter()
                    .any(|event| matches!(event, SessionEvent::Ended { .. }))
            );
        }
        rounds += 1;
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    // Releasing many channel leases must leave SFTP usable on every transport.
    for session in sessions {
        let client = session.open_sftp().await.unwrap();
        assert!(
            !client
                .list_directory(work())
                .await
                .unwrap()
                .entries
                .is_empty()
        );
        client.close();
        session.disconnect();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !session.is_finished() {
            assert!(Instant::now() < deadline, "session worker did not finish");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }
    eprintln!(
        "stability: four authenticated transports, {rounds} rounds, {} seconds; all workers finished",
        started.elapsed().as_secs()
    );
}
