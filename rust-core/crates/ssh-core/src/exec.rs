use crate::remote::RemoteContext;
use crate::{RemoteCancellation, RemoteError, SshSession};
use russh::ChannelMsg;
use std::time::Duration;

const MAX_COMMAND_BYTES: usize = 8192;
const MAX_COMMAND_OUTPUT_BYTES: usize = 65_536;
const SERVICE_TIMEOUT_SECONDS: u32 = 10;

/// Raw remote output is deliberately not Debug or persisted by this layer.
pub struct CommandOutput {
    /// A clipped stream has no reliable exit status yet.
    pub exit_code: Option<u32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub truncated: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServiceStatus {
    pub name: String,
    pub load_state: String,
    pub active_state: String,
    pub sub_state: String,
    pub unit_file_state: String,
    pub active_enter_timestamp: String,
}

pub(crate) fn has_hidden_control(value: &str, allow_command_whitespace: bool) -> bool {
    value.chars().any(|character| {
        (character.is_control()
            && !(allow_command_whitespace && matches!(character, '\n' | '\t')))
            || matches!(character, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
    })
}

fn validate_command(command: &str, timeout_seconds: u32) -> Result<(), RemoteError> {
    if command.is_empty()
        || command.len() > MAX_COMMAND_BYTES
        || !(1..=60).contains(&timeout_seconds)
        || has_hidden_control(command, true)
    {
        return Err(RemoteError::InvalidCommand);
    }
    Ok(())
}

#[derive(Default)]
struct CommandCollector {
    accepted: bool,
    closed: bool,
    exit_code: Option<u32>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    truncated: bool,
}
impl CommandCollector {
    /// true ends collection immediately, including on the first excessive byte.
    fn accept(&mut self, message: ChannelMsg) -> Result<bool, RemoteError> {
        match message {
            ChannelMsg::Success if !self.accepted => self.accepted = true,
            ChannelMsg::Failure if !self.accepted => return Err(RemoteError::Unsupported),
            ChannelMsg::WindowAdjusted { .. } => {}
            ChannelMsg::Success | ChannelMsg::Failure => return Err(RemoteError::MalformedData),
            _ if !self.accepted => return Err(RemoteError::MalformedData),
            ChannelMsg::Data { data } => self.append(&data, false),
            ChannelMsg::ExtendedData { data, ext: 1 } => self.append(&data, true),
            ChannelMsg::ExitStatus { exit_status } if self.exit_code.is_none() => {
                self.exit_code = Some(exit_status);
            }
            ChannelMsg::ExitSignal { .. } => return Err(RemoteError::RemoteFailure),
            ChannelMsg::Eof => {}
            ChannelMsg::Close => {
                self.closed = true;
                return Ok(true);
            }
            _ => return Err(RemoteError::MalformedData),
        }
        Ok(self.truncated)
    }

    fn append(&mut self, data: &[u8], stderr: bool) {
        let remaining = MAX_COMMAND_OUTPUT_BYTES - self.stdout.len() - self.stderr.len();
        let count = remaining.min(data.len());
        let destination = if stderr {
            &mut self.stderr
        } else {
            &mut self.stdout
        };
        destination.extend_from_slice(&data[..count]);
        if count != data.len() {
            self.truncated = true;
            self.exit_code = None;
        }
    }

    fn finish(self) -> Result<CommandOutput, RemoteError> {
        if !self.accepted || (!self.truncated && self.exit_code.is_none()) {
            return Err(RemoteError::MalformedData);
        }
        if !self.closed && !self.truncated {
            return Err(RemoteError::ConnectionLost);
        }
        Ok(CommandOutput {
            exit_code: self.exit_code,
            stdout: self.stdout,
            stderr: self.stderr,
            truncated: self.truncated,
        })
    }
}

impl SshSession {
    /// Uses a new non-PTY channel. The caller supplies a separately authorized
    /// connection, never the user's interactive terminal session.
    pub async fn execute_command(
        &self,
        command: String,
        timeout_seconds: u32,
        operation: RemoteCancellation,
    ) -> Result<CommandOutput, RemoteError> {
        validate_command(&command, timeout_seconds)?;
        let context = self.remote_context()?;
        operation.run(async move {
            let mut disconnected = context.cancelled.clone();
            tokio::select! {
                biased;
                _ = disconnected.wait_for(|value| *value) => Err(RemoteError::ConnectionLost),
                result = tokio::time::timeout(Duration::from_secs(timeout_seconds.into()), execute(context, command)) => {
                    result.map_err(|_| RemoteError::Timeout)?
                }
            }
        }).await
    }

    pub async fn service_status(
        &self,
        service_name: String,
        operation: RemoteCancellation,
    ) -> Result<ServiceStatus, RemoteError> {
        let name = normalize_service_name(&service_name)?;
        // The only interpolated value has an ASCII unit-name grammar, no quote,
        // whitespace, option prefix or shell operator. No status/log text is read.
        let command = format!(
            "LC_ALL=C; export LC_ALL\nif [ \"$(uname -s)\" != Linux ] || ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then exit 72; fi\nSYSTEMD_PAGER=cat systemctl show --no-pager --property=LoadState,ActiveState,SubState,UnitFileState,ActiveEnterTimestamp -- '{name}'"
        );
        let output = self
            .execute_command(command, SERVICE_TIMEOUT_SECONDS, operation)
            .await?;
        if output.truncated {
            return Err(RemoteError::OutputLimit);
        }
        match output.exit_code {
            Some(0) => parse_service_status(&name, &output.stdout),
            Some(72 | 127) => Err(RemoteError::Unsupported),
            Some(126) => Err(RemoteError::PermissionDenied),
            _ => Err(RemoteError::RemoteFailure),
        }
    }
}

async fn execute(context: RemoteContext, command: String) -> Result<CommandOutput, RemoteError> {
    let mut lease = context.open_channel().await?;
    let channel = lease.channel.as_mut().ok_or(RemoteError::ConnectionLost)?;
    channel
        .exec(true, command)
        .await
        .map_err(|_| RemoteError::ConnectionLost)?;
    let mut output = CommandCollector::default();
    while let Some(message) = channel.wait().await {
        if output.accept(message)? {
            break;
        }
    }
    // Dropping the lease schedules bounded CLOSE even when this future was
    // cancelled/timed out; it is independent of the cancelled Swift caller.
    output.finish()
}

fn normalize_service_name(name: &str) -> Result<String, RemoteError> {
    if name.is_empty()
        || name.len() > 128
        || name.starts_with(['-', '.'])
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_-.@".contains(&byte))
    {
        return Err(RemoteError::InvalidServiceName);
    }
    let stem = if let Some(stem) = name.strip_suffix(".service") {
        stem
    } else if name.contains('.') {
        // An explicitly supplied suffix must be .service. Bare names without
        // a unit suffix are normalized, while dotted service stems stay valid.
        return Err(RemoteError::InvalidServiceName);
    } else {
        name
    };
    if stem.is_empty() {
        return Err(RemoteError::InvalidServiceName);
    }
    let normalized = format!("{stem}.service");
    if normalized.len() > 128 {
        return Err(RemoteError::InvalidServiceName);
    }
    Ok(normalized)
}

fn parse_service_status(name: &str, output: &[u8]) -> Result<ServiceStatus, RemoteError> {
    if output.len() > 4096 {
        return Err(RemoteError::OutputLimit);
    }
    let text = std::str::from_utf8(output).map_err(|_| RemoteError::MalformedData)?;
    let mut fields: [Option<&str>; 5] = [None; 5];
    for line in text.lines() {
        let (key, value) = line.split_once('=').ok_or(RemoteError::MalformedData)?;
        let index = match key {
            "LoadState" => 0,
            "ActiveState" => 1,
            "SubState" => 2,
            "UnitFileState" => 3,
            "ActiveEnterTimestamp" => 4,
            _ => return Err(RemoteError::MalformedData),
        };
        if fields[index].is_some()
            || value.len() > if index == 4 { 128 } else { 64 }
            || !value.is_ascii()
            || has_hidden_control(value, false)
            || (index < 3 && value.is_empty())
            || (index < 4
                && !value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte)))
        {
            return Err(RemoteError::MalformedData);
        }
        fields[index] = Some(value);
    }
    let [
        Some(load),
        Some(active),
        Some(sub),
        Some(unit),
        Some(timestamp),
    ] = fields
    else {
        return Err(RemoteError::MalformedData);
    };
    Ok(ServiceStatus {
        name: name.into(),
        load_state: load.into(),
        active_state: active.into(),
        sub_state: sub.into(),
        unit_file_state: unit.into(),
        active_enter_timestamp: timestamp.into(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::RemoteError;
    use russh::ChannelMsg;

    #[test]
    fn command_input_rejects_hidden_control_and_bounds_execution() {
        assert_eq!(validate_command("printf '中文'\n\ttrue", 1), Ok(()));
        assert_eq!(validate_command(&"x".repeat(8192), 60), Ok(()));
        for command in [
            "",
            "a\0b",
            "a\rb",
            "a\u{1b}b",
            "a\u{202e}b",
            "a\u{2067}b",
            &"x".repeat(8193),
        ] {
            assert_eq!(
                validate_command(command, 10),
                Err(RemoteError::InvalidCommand)
            );
        }
        assert_eq!(
            validate_command("true", 0),
            Err(RemoteError::InvalidCommand)
        );
        assert_eq!(
            validate_command("true", 61),
            Err(RemoteError::InvalidCommand)
        );
    }

    #[test]
    fn exec_keeps_streams_separate_and_requires_success_ack_and_exit_status() {
        let mut output = CommandCollector::default();
        assert!(!output.accept(ChannelMsg::Success).unwrap());
        assert!(
            !output
                .accept(ChannelMsg::Data {
                    data: b"out".as_slice().into()
                })
                .unwrap()
        );
        assert!(
            !output
                .accept(ChannelMsg::ExtendedData {
                    ext: 1,
                    data: b"err".as_slice().into()
                })
                .unwrap()
        );
        assert!(
            !output
                .accept(ChannelMsg::ExitStatus { exit_status: 9 })
                .unwrap()
        );
        assert!(output.accept(ChannelMsg::Close).unwrap());
        let result = output.finish().unwrap();
        assert_eq!(result.exit_code, Some(9));
        assert_eq!(result.stdout, b"out");
        assert_eq!(result.stderr, b"err");
        assert!(!result.truncated);
        assert!(matches!(
            CommandCollector::default().finish(),
            Err(RemoteError::MalformedData)
        ));
        let mut missing = CommandCollector::default();
        missing.accept(ChannelMsg::Success).unwrap();
        assert!(matches!(missing.finish(), Err(RemoteError::MalformedData)));
    }

    #[test]
    fn exec_refuses_failed_duplicate_or_out_of_order_acknowledgements() {
        for message in [
            ChannelMsg::Failure,
            ChannelMsg::ExitStatus { exit_status: 0 },
            ChannelMsg::Data {
                data: b"before-ack".as_slice().into(),
            },
        ] {
            let mut output = CommandCollector::default();
            assert!(output.accept(message).is_err());
        }
        let mut duplicate = CommandCollector::default();
        duplicate.accept(ChannelMsg::Success).unwrap();
        assert_eq!(
            duplicate.accept(ChannelMsg::Success),
            Err(RemoteError::MalformedData)
        );
        duplicate
            .accept(ChannelMsg::ExitStatus { exit_status: 0 })
            .unwrap();
        assert_eq!(
            duplicate.accept(ChannelMsg::ExitStatus { exit_status: 1 }),
            Err(RemoteError::MalformedData)
        );
    }

    #[test]
    fn combined_exec_output_is_bounded_and_truncation_never_invents_exit_status() {
        let mut output = CommandCollector::default();
        output.accept(ChannelMsg::Success).unwrap();
        output
            .accept(ChannelMsg::Data {
                data: vec![b'a'; 40_000].into(),
            })
            .unwrap();
        assert!(
            output
                .accept(ChannelMsg::ExtendedData {
                    ext: 1,
                    data: vec![b'b'; 40_000].into()
                })
                .unwrap()
        );
        let result = output.finish().unwrap();
        assert_eq!(result.stdout.len(), 40_000);
        assert_eq!(result.stderr.len(), 25_536);
        assert_eq!(result.stdout.len() + result.stderr.len(), 65_536);
        assert!(result.truncated);
        assert_eq!(result.exit_code, None);
    }

    #[test]
    fn exit_status_without_channel_close_is_not_successful_completion() {
        let mut output = CommandCollector::default();
        output.accept(ChannelMsg::Success).unwrap();
        output
            .accept(ChannelMsg::ExitStatus { exit_status: 0 })
            .unwrap();
        assert!(matches!(output.finish(), Err(RemoteError::ConnectionLost)));
    }

    #[test]
    fn systemd_names_cannot_be_shell_fragments_or_other_unit_types() {
        assert_eq!(normalize_service_name("sshd"), Ok("sshd.service".into()));
        assert_eq!(
            normalize_service_name("postgresql@16-main.service"),
            Ok("postgresql@16-main.service".into())
        );
        assert_eq!(
            normalize_service_name("worker.v2.service"),
            Ok("worker.v2.service".into())
        );
        for name in [
            "",
            "-x",
            ".",
            "..",
            "../ssh",
            "sshd;id",
            "$(id)",
            "a b",
            "a\nb",
            "a.timer",
            "a.socket",
            &"a".repeat(129),
        ] {
            assert_eq!(
                normalize_service_name(name),
                Err(RemoteError::InvalidServiceName)
            );
        }
    }

    #[test]
    fn service_status_returns_only_expected_bounded_structured_fields() {
        let parsed = parse_service_status("sshd.service", b"LoadState=loaded\nActiveState=active\nSubState=running\nUnitFileState=enabled\nActiveEnterTimestamp=Tue 2026-10-27 09:00:00 UTC\n").unwrap();
        assert_eq!(parsed.name, "sshd.service");
        assert_eq!(parsed.load_state, "loaded");
        assert_eq!(parsed.active_state, "active");
        assert_eq!(parsed.sub_state, "running");
        assert_eq!(parsed.unit_file_state, "enabled");
        assert_eq!(parsed.active_enter_timestamp, "Tue 2026-10-27 09:00:00 UTC");
        for text in [
            "LoadState=loaded\n",
            "LoadState=loaded\nLoadState=loaded\n",
            "Description=private log\n",
            "LoadState=loaded\nActiveState=active\nSubState=running\nUnitFileState=enabled\nActiveEnterTimestamp=bad\u{202e}\n",
        ] {
            assert!(parse_service_status("sshd.service", text.as_bytes()).is_err());
        }
    }
}
