use rmcp::model::{Tool, ToolAnnotations};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use uuid::Uuid;

pub(crate) const TOOL_NAMES: [&str; 6] = [
    "list_hosts",
    "get_host_info",
    "get_server_metrics",
    "get_service_status",
    "sftp_list",
    "ssh_exec",
];

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EmptyArguments {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HostArguments {
    host_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ServiceArguments {
    host_id: String,
    service_name: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DirectoryArguments {
    host_id: String,
    path: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CommandArguments {
    host_id: String,
    command: String,
    #[serde(default = "default_timeout")]
    timeout: u8,
}

fn default_timeout() -> u8 {
    20
}

pub(crate) fn validate(
    tool: &str,
    arguments: Option<Map<String, Value>>,
) -> Result<Value, &'static str> {
    let mut arguments = Value::Object(arguments.unwrap_or_default());
    let invalid = |_| "INVALID_ARGUMENTS";
    match tool {
        "list_hosts" => {
            let _: EmptyArguments = serde_json::from_value(arguments.clone()).map_err(invalid)?;
        }
        "get_host_info" | "get_server_metrics" => {
            let args: HostArguments = serde_json::from_value(arguments.clone()).map_err(invalid)?;
            validate_host_id(&args.host_id)?;
        }
        "get_service_status" => {
            let args: ServiceArguments =
                serde_json::from_value(arguments.clone()).map_err(invalid)?;
            validate_host_id(&args.host_id)?;
            if args.service_name.is_empty()
                || args.service_name.len() > 255
                || !args.service_name.as_bytes()[0].is_ascii_alphanumeric()
                || !args
                    .service_name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_.@:-".contains(&b))
            {
                return Err("INVALID_ARGUMENTS");
            }
        }
        "sftp_list" => {
            let args: DirectoryArguments =
                serde_json::from_value(arguments.clone()).map_err(invalid)?;
            validate_host_id(&args.host_id)?;
            if !args.path.starts_with('/')
                || args.path.len() > 4096
                || args
                    .path
                    .chars()
                    .any(|c| c.is_control() || is_bidi_control(c))
                || args.path.split('/').any(|p| p == "." || p == "..")
                || args.path.contains("//")
            {
                return Err("INVALID_ARGUMENTS");
            }
        }
        "ssh_exec" => {
            let args: CommandArguments =
                serde_json::from_value(arguments.clone()).map_err(invalid)?;
            validate_host_id(&args.host_id)?;
            if args.command.is_empty()
                || args.command.len() > 8192
                || !(1..=60).contains(&args.timeout)
                || args
                    .command
                    .chars()
                    .any(|c| (c.is_control() && c != '\n' && c != '\t') || is_bidi_control(c))
            {
                return Err("INVALID_ARGUMENTS");
            }
            arguments["timeout"] = args.timeout.into();
        }
        _ => return Err("UNKNOWN_TOOL"),
    }
    Ok(arguments)
}

fn validate_host_id(id: &str) -> Result<(), &'static str> {
    if id.len() != 36 || Uuid::parse_str(id).is_err() {
        return Err("INVALID_ARGUMENTS");
    }
    Ok(())
}

fn is_bidi_control(c: char) -> bool {
    matches!(c, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
}

pub(crate) fn tools() -> Vec<Tool> {
    TOOL_NAMES.into_iter().map(|name| {
        let mut properties = Map::new();
        let mut required = Vec::new();
        if name != "list_hosts" {
            properties.insert("host_id".into(), json!({"type":"string","format":"uuid","minLength":36,"maxLength":36,"pattern":"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$","description":"Stable UUID of a host explicitly authorized in ConnDock."}));
            required.push("host_id");
        }
        let description = match name {
            "list_hosts" => "List only hosts explicitly authorized in the running ConnDock app.",
            "get_host_info" => "Get non-secret connection information for an authorized host.",
            "get_server_metrics" => "Collect Linux resource metrics through the app's fixed read-only collector.",
            "get_service_status" => {
                properties.insert("service_name".into(), json!({"type":"string","minLength":1,"maxLength":255,"pattern":"^[A-Za-z0-9][A-Za-z0-9_.@:-]*$","description":"Exact systemd unit name authorized in ConnDock."}));
                required.push("service_name");
                "Query an explicitly authorized systemd service through the fixed status collector."
            }
            "sftp_list" => {
                properties.insert("path".into(), json!({"type":"string","minLength":1,"maxLength":4096,"pattern":"^/","description":"Absolute remote directory within the app's allowed roots; no dot or dot-dot components."}));
                required.push("path");
                "List metadata in an explicitly authorized remote directory. The app checks real paths and sensitive directories."
            }
            "ssh_exec" => {
                properties.insert("command".into(), json!({"type":"string","minLength":1,"maxLength":8192,"description":"Exact command for one-time approval in the Mac app. Maximum 8192 UTF-8 bytes; LF and TAB allowed, other controls and bidi controls rejected."}));
                properties.insert("timeout".into(), json!({"type":"integer","minimum":1,"maximum":60,"default":20,"description":"Remote execution deadline in seconds."}));
                required.push("command");
                "Execute the exact command only after a separate one-time user approval in ConnDock. The app enforces host trust, authorization, deadline, cancellation and a combined 65536-byte stdout/stderr cap."
            }
            _ => unreachable!(),
        };
        let schema = json!({"type":"object","properties":properties,"required":required,"additionalProperties":false});
        Tool::new(name, description, schema.as_object().expect("literal object").clone())
            .with_annotations(ToolAnnotations::new().read_only(name != "ssh_exec").destructive(name == "ssh_exec").open_world(true))
    }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const HOST: &str = "991b88b1-4871-4cf2-849a-bc421f3c9be4";

    fn check(tool: &str, args: Value) -> Result<Value, &'static str> {
        validate(tool, args.as_object().cloned())
    }

    #[test]
    fn routes_only_six_tools_with_exact_argument_shapes() {
        for (tool, args) in [
            ("list_hosts", json!({})),
            ("get_host_info", json!({"host_id":HOST})),
            ("get_server_metrics", json!({"host_id":HOST})),
            (
                "get_service_status",
                json!({"host_id":HOST,"service_name":"sshd.service"}),
            ),
            ("sftp_list", json!({"host_id":HOST,"path":"/var/www"})),
            (
                "ssh_exec",
                json!({"host_id":HOST,"command":"printf 'ok'","timeout":20}),
            ),
        ] {
            assert_eq!(check(tool, args.clone()), Ok(args));
        }
        assert_eq!(check("get_password", json!({})), Err("UNKNOWN_TOOL"));
        assert_eq!(
            check("list_hosts", json!({"hostname":"server"})),
            Err("INVALID_ARGUMENTS")
        );
        assert_eq!(
            check(
                "get_host_info",
                json!({"host_id":HOST,"password":"private"})
            ),
            Err("INVALID_ARGUMENTS")
        );
        assert_eq!(
            check("get_host_info", json!({"host_id":"not-a-uuid"})),
            Err("INVALID_ARGUMENTS")
        );
        assert_eq!(check("get_host_info", json!({})), Err("INVALID_ARGUMENTS"));
    }

    #[test]
    fn command_limit_counts_utf8_bytes_and_rejects_hidden_controls() {
        let command = "é".repeat(4096);
        assert!(check("ssh_exec", json!({"host_id":HOST,"command":command})).is_ok());
        for command in [
            "é".repeat(4097),
            String::new(),
            "pwd\u{0}whoami".into(),
            "pwd\rwhoami".into(),
            "pwd\u{1b}[2J".into(),
            "pwd\u{202e}".into(),
            "pwd\u{2066}".into(),
        ] {
            assert_eq!(
                check("ssh_exec", json!({"host_id":HOST,"command":command})),
                Err("INVALID_ARGUMENTS")
            );
        }
        assert_eq!(
            check(
                "ssh_exec",
                json!({"host_id":HOST,"command":"printf 'one'\nprintf '\ttwo'"})
            ),
            Ok(json!({"host_id":HOST,"command":"printf 'one'\nprintf '\ttwo'","timeout":20}))
        );
    }

    #[test]
    fn timeout_is_an_integer_in_seconds_with_explicit_default() {
        assert_eq!(
            check("ssh_exec", json!({"host_id":HOST,"command":"pwd"})),
            Ok(json!({"host_id":HOST,"command":"pwd","timeout":20}))
        );
        for timeout in [
            json!(0),
            json!(61),
            json!(-1),
            json!(1.5),
            json!("20"),
            json!(null),
            json!(true),
        ] {
            assert_eq!(
                check(
                    "ssh_exec",
                    json!({"host_id":HOST,"command":"pwd","timeout":timeout})
                ),
                Err("INVALID_ARGUMENTS")
            );
        }
        assert!(
            check(
                "ssh_exec",
                json!({"host_id":HOST,"command":"pwd","timeout":1})
            )
            .is_ok()
        );
        assert!(
            check(
                "ssh_exec",
                json!({"host_id":HOST,"command":"pwd","timeout":60})
            )
            .is_ok()
        );
    }

    #[test]
    fn service_and_path_reject_shell_fragments_and_ambiguous_paths() {
        for service in ["sshd; id", "$(whoami)", "-bad", "a\nsshd", "../sshd", ""] {
            assert_eq!(
                check(
                    "get_service_status",
                    json!({"host_id":HOST,"service_name":service})
                ),
                Err("INVALID_ARGUMENTS")
            );
        }
        for path in [
            "relative",
            "/tmp/../etc",
            "/tmp/./x",
            "/tmp//x",
            "/tmp\u{0}",
            "",
        ] {
            assert_eq!(
                check("sftp_list", json!({"host_id":HOST,"path":path})),
                Err("INVALID_ARGUMENTS")
            );
        }
        assert!(check("sftp_list", json!({"host_id":HOST,"path":"/var/中文 文件"})).is_ok());
    }
}
