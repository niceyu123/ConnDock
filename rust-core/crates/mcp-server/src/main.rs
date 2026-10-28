#[cfg(all(target_os = "macos", not(target_arch = "aarch64")))]
compile_error!("ConnDock MCP supports Apple Silicon macOS only.");

#[cfg(target_os = "macos")]
#[tokio::main]
async fn main() {
    if conndock_mcp::run_from_env().await.is_err() {
        eprintln!(
            "ConnDock MCP could not start or the connection check failed. Open ConnDock and use the configuration from AI Tools settings."
        );
        std::process::exit(1);
    }
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("ConnDock MCP requires Apple Silicon macOS.");
    std::process::exit(1);
}
