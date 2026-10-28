/// Serial access to Rust metadata; live SSH uses its own owned SshConnection.
/// Reading metadata performs no network or blocking work.
public actor BridgeProbe {
  public static let shared = BridgeProbe()

  public func readInfo() -> CoreInfo {
    coreInfo()
  }
}
