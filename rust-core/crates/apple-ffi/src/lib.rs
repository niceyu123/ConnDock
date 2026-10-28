uniffi::setup_scaffolding!();

mod ssh;
pub use ssh::*;
mod remote;
pub use remote::*;

/// Public metadata contract; never includes credentials or remote host data.
#[derive(Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreInfo {
    pub version: String,
    pub bridge_protocol: u32,
    pub network_enabled: bool,
}

#[uniffi::export]
pub fn core_info() -> CoreInfo {
    CoreInfo {
        version: conndock_core::version().to_owned(),
        bridge_protocol: conndock_core::BRIDGE_PROTOCOL_VERSION,
        network_enabled: true,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn ffi_metadata_exposes_ssh_contract() {
        let info = super::core_info();
        assert_eq!(info.version, "0.1.0");
        assert_eq!(info.bridge_protocol, 2);
        assert!(info.network_enabled);
    }
}
