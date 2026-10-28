#![cfg(target_os = "macos")]

//! Real subprocess/stdin/stdout tests with an explicitly synthetic, ad-hoc
//! signed App. This does not establish App Store sandbox or real SSH acceptance.

use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    os::unix::{fs::PermissionsExt, net::UnixListener},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use uuid::Uuid;

#[test]
fn app_fixture_child() {
    let Some(socket) = std::env::var_os("CONNDOCK_MCP_TEST_APP_SOCKET") else {
        return;
    };
    let listener = UnixListener::bind(&socket).unwrap();
    fs::set_permissions(socket, fs::Permissions::from_mode(0o600)).unwrap();
    for stream in listener.incoming() {
        let mut stream = stream.unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut header = [0_u8; 4];
        if stream.read_exact(&mut header).is_err() {
            continue;
        }
        let length = u32::from_be_bytes(header) as usize;
        assert!(length <= 65536);
        let mut body = vec![0; length];
        stream.read_exact(&mut body).unwrap();
        let request: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(request["version"], 1);
        assert!(Uuid::parse_str(request["id"].as_str().unwrap()).is_ok());
        let response=match request["tool"].as_str().unwrap() {
            "list_hosts"=>json!({"ok":true,"data":{"hosts":[{"host_id":"991b88b1-4871-4cf2-849a-bc421f3c9be4","display_name":"Synthetic fixture host"}]}}),
            "get_server_metrics"=>json!({"ok":true,"data":{"cpu":0.25}}),
            "ssh_exec"=>json!({"ok":false,"error":{"code":"APPROVAL_DENIED","message":"never echo internal details"}}),
            _=>panic!("unexpected fixture tool"),
        }.to_string();
        stream
            .write_all(&(response.len() as u32).to_be_bytes())
            .unwrap();
        stream.write_all(response.as_bytes()).unwrap();
        let mut byte = [0];
        assert_eq!(stream.read(&mut byte).unwrap(), 0);
    }
}

struct Fixture {
    root: PathBuf,
    app: PathBuf,
    helper: PathBuf,
    socket: PathBuf,
    child: Option<Child>,
}
impl Fixture {
    fn new(start_app: bool) -> Self {
        let root = Path::new("/tmp").join(format!("mcp-{}", Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let app = root.join("ConnDock.app");
        let main = app.join("Contents/MacOS/ConnDock");
        let helper_app = app.join("Contents/Helpers/ConnDockMCP.app");
        let helper = helper_app.join("Contents/MacOS/conndock-mcp");
        fs::create_dir_all(main.parent().unwrap()).unwrap();
        fs::create_dir_all(helper.parent().unwrap()).unwrap();
        fs::copy(std::env::current_exe().unwrap(), &main).unwrap();
        fs::copy(env!("CARGO_BIN_EXE_conndock-mcp"), &helper).unwrap();
        for (bundle, id, executable) in [
            (&app, "com.ruohai.termall.mcp-fixture", "ConnDock"),
            (
                &helper_app,
                "com.ruohai.termall.mcp-fixture.helper",
                "conndock-mcp",
            ),
        ] {
            fs::write(bundle.join("Contents/Info.plist"),format!("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>{id}</string><key>CFBundleExecutable</key><string>{executable}</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>")).unwrap();
        }
        for bundle in [&helper_app, &app] {
            assert!(
                Command::new("/usr/bin/codesign")
                    .args(["--force", "--sign", "-", "--timestamp=none"])
                    .arg(bundle)
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .unwrap()
                    .success()
            );
        }
        let socket = root.join("ipc.sock");
        let child = if start_app {
            Some(
                Command::new(main)
                    .args(["--exact", "app_fixture_child"])
                    .env("CONNDOCK_MCP_TEST_APP_SOCKET", &socket)
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            )
        } else {
            None
        };
        if start_app {
            let deadline = Instant::now() + Duration::from_secs(5);
            while !socket.exists() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(10));
            }
            assert!(socket.exists());
        }
        Self {
            root,
            app,
            helper,
            socket,
            child,
        }
    }
    fn command(&self) -> tokio::process::Command {
        let mut command = tokio::process::Command::new(&self.helper);
        command
            .arg("--socket")
            .arg(&self.socket)
            .arg("--app")
            .arg(&self.app)
            .kill_on_drop(true);
        command
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

async fn send(input: &mut tokio::process::ChildStdin, request: Value) {
    input
        .write_all(format!("{request}\n").as_bytes())
        .await
        .unwrap();
}
async fn receive(output: &mut BufReader<tokio::process::ChildStdout>) -> Value {
    let mut line = String::new();
    assert!(
        tokio::time::timeout(Duration::from_secs(5), output.read_line(&mut line))
            .await
            .unwrap()
            .unwrap()
            > 0
    );
    serde_json::from_str(&line).unwrap()
}
async fn initialize(
    input: &mut tokio::process::ChildStdin,
    output: &mut BufReader<tokio::process::ChildStdout>,
) {
    send(input,json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"subprocess-test","version":"1"}}})).await;
    let initialized = receive(output).await;
    assert_eq!(initialized["result"]["serverInfo"]["name"], "conndock-mcp");
    send(
        input,
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
    )
    .await;
}

#[tokio::test]
async fn real_stdio_process_exposes_tools_and_relays_only_signed_app_results() {
    let fixture = Fixture::new(true);
    let mut child = fixture
        .command()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    initialize(&mut input, &mut output).await;
    send(
        &mut input,
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
    )
    .await;
    assert_eq!(
        receive(&mut output).await["result"]["tools"]
            .as_array()
            .unwrap()
            .len(),
        6
    );
    for (id, tool, arguments) in [
        (3, "list_hosts", json!({})),
        (
            4,
            "get_server_metrics",
            json!({"host_id":"991b88b1-4871-4cf2-849a-bc421f3c9be4"}),
        ),
        (
            5,
            "ssh_exec",
            json!({"host_id":"991b88b1-4871-4cf2-849a-bc421f3c9be4","command":"pwd"}),
        ),
    ] {
        send(&mut input,json!({"jsonrpc":"2.0","id":id,"method":"tools/call","params":{"name":tool,"arguments":arguments}})).await;
        let response = receive(&mut output).await;
        if tool == "ssh_exec" {
            assert_eq!(response["result"]["isError"], true);
            assert_eq!(
                response["result"]["structuredContent"]["error"]["code"],
                "APPROVAL_DENIED"
            );
            assert!(!response.to_string().contains("internal details"));
        } else {
            assert_eq!(
                response["result"]["structuredContent"]["untrusted_data"],
                true
            );
        }
    }
    drop(input);
    assert!(
        tokio::time::timeout(Duration::from_secs(5), child.wait())
            .await
            .unwrap()
            .unwrap()
            .success()
    );
    let check = fixture.command().arg("--check").output().await.unwrap();
    assert!(
        check.status.success(),
        "check failed: {}",
        String::from_utf8_lossy(&check.stdout)
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&check.stdout).unwrap(),
        json!({"ok":true})
    );
    assert!(check.stderr.is_empty());
}

#[tokio::test]
async fn same_uid_impostor_receives_no_request_bytes() {
    let fixture = Fixture::new(false);
    let listener = tokio::net::UnixListener::bind(&fixture.socket).unwrap();
    fs::set_permissions(&fixture.socket, fs::Permissions::from_mode(0o600)).unwrap();
    let mut child = fixture
        .command()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    initialize(&mut input, &mut output).await;
    send(&mut input,json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_hosts","arguments":{}}})).await;
    let (mut stream, _) = tokio::time::timeout(Duration::from_secs(5), listener.accept())
        .await
        .unwrap()
        .unwrap();
    let response = receive(&mut output).await;
    assert_eq!(
        response["result"]["structuredContent"]["error"]["code"],
        "APP_IDENTITY_REJECTED"
    );
    let mut bytes = [0; 1];
    assert_eq!(
        tokio::io::AsyncReadExt::read(&mut stream, &mut bytes)
            .await
            .unwrap(),
        0
    );
    drop(input);
    assert!(
        tokio::time::timeout(Duration::from_secs(5), child.wait())
            .await
            .unwrap()
            .unwrap()
            .success()
    );
}
