//! SSH sessions. No application logging, persistence, or filesystem access.

mod session;
pub use session::*;
mod remote;
pub use remote::{RemoteCancellation, RemoteError};
mod exec;
pub use exec::{CommandOutput, ServiceStatus};
pub mod monitor;
pub mod sftp;

pub const BRIDGE_PROTOCOL_VERSION: u32 = 2;

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_versioned_bridge_contract() {
        assert_eq!(version(), "0.1.0");
        assert_eq!(BRIDGE_PROTOCOL_VERSION, 2);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn tokio_runtime_executes_and_releases_a_task() {
        let task = tokio::spawn(async {
            tokio::task::yield_now().await;
            version()
        });
        let value = tokio::time::timeout(std::time::Duration::from_secs(1), task)
            .await
            .expect("task should finish")
            .expect("task should not panic");
        assert_eq!(value, version());
    }
}
