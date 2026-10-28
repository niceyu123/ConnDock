mod cli;
mod identity;
mod ipc;
mod request;
mod server;

/// Run the embedded macOS helper. Errors contain fixed machine-readable codes;
/// callers must not print OS, JSON, IPC or Security.framework diagnostics.
pub async fn run_from_env() -> Result<(), String> {
    use tokio::io::AsyncWriteExt;
    use tokio_util::sync::CancellationToken;
    let options = cli::parse(std::env::args_os().skip(1))?;
    let connector = identity::AppConnector::new(options.socket, options.app);
    if options.check {
        let result = match connector {
            Ok(connector) => tokio::time::timeout(
                std::time::Duration::from_secs(5),
                ipc::call(
                    &connector,
                    "list_hosts",
                    serde_json::json!({}),
                    &CancellationToken::new(),
                    &CancellationToken::new(),
                ),
            )
            .await
            .unwrap_or_else(|_| Err("REQUEST_TIMEOUT".into())),
            Err(code) => Err(code.into()),
        };
        // Connectivity diagnostics must never print the hosts returned by App.
        let response = match &result {
            Ok(_) => serde_json::json!({"ok":true}),
            Err(code) => serde_json::json!({"ok":false,"error":{"code":code}}),
        };
        let mut stdout = tokio::io::stdout();
        stdout
            .write_all(format!("{response}\n").as_bytes())
            .await
            .map_err(|_| "MCP_TRANSPORT_ERROR")?;
        stdout.flush().await.map_err(|_| "MCP_TRANSPORT_ERROR")?;
        result.map(|_| ())
    } else {
        let connector = connector?;
        let (read, write) = rmcp::transport::io::stdio();
        server::serve_io(connector, read, write)
            .await
            .map_err(str::to_owned)
    }
}
