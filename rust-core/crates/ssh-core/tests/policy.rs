use conndock_core::{ConnectionOptions, ErrorCode, HostKeyPolicy, TerminalSize};

#[test]
fn invalid_targets_and_terminal_sizes_are_rejected() {
    let mut options = ConnectionOptions::new("localhost".into(), 22, "tester".into());
    assert_eq!(options.validate(), Ok(()));
    options.port = 0;
    assert_eq!(options.validate(), Err(ErrorCode::InvalidConfiguration));
    options.port = 22;
    options.host = "ssh://localhost".into();
    assert_eq!(options.validate(), Err(ErrorCode::InvalidConfiguration));
    assert!(TerminalSize::new(80, 24).is_ok());
    assert_eq!(
        TerminalSize::new(0, 24),
        Err(ErrorCode::InvalidConfiguration)
    );
    assert_eq!(
        TerminalSize::new(5000, 24),
        Err(ErrorCode::InvalidConfiguration)
    );
}

#[test]
fn a_known_key_cannot_be_overridden_by_accepting_another_key() {
    let trusted = format!("SHA256:{}", "A".repeat(43));
    let changed = format!("SHA256:{}", "B".repeat(43));
    assert_eq!(HostKeyPolicy::evaluate(Some(&trusted), &trusted), Ok(true));
    assert_eq!(
        HostKeyPolicy::evaluate(Some(&trusted), &changed),
        Err(ErrorCode::HostKeyChanged)
    );
    assert_eq!(HostKeyPolicy::evaluate(None, &trusted), Ok(false));
    assert_eq!(
        HostKeyPolicy::evaluate(Some("malformed"), &trusted),
        Err(ErrorCode::InvalidConfiguration)
    );
}
