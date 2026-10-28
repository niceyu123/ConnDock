use std::{
    ffi::OsString,
    path::{Path, PathBuf},
};

#[derive(Debug, PartialEq)]
pub(crate) struct Options {
    pub socket: PathBuf,
    pub app: Option<PathBuf>,
    pub check: bool,
}

pub(crate) fn parse(
    arguments: impl IntoIterator<Item = OsString>,
) -> Result<Options, &'static str> {
    let mut arguments = arguments.into_iter();
    let mut socket = None;
    let mut app = None;
    let mut check = false;
    while let Some(argument) = arguments.next() {
        match argument.to_str() {
            Some("--socket") if socket.is_none() => {
                socket = Some(PathBuf::from(
                    arguments.next().ok_or("INVALID_CONFIGURATION")?,
                ))
            }
            Some("--app") if app.is_none() => {
                app = Some(PathBuf::from(
                    arguments.next().ok_or("INVALID_CONFIGURATION")?,
                ))
            }
            Some("--check") if !check => check = true,
            _ => return Err("INVALID_CONFIGURATION"),
        }
    }
    let socket = socket.ok_or("INVALID_CONFIGURATION")?;
    if !socket.is_absolute() || app.as_ref().is_some_and(|path| !path.is_absolute()) {
        return Err("INVALID_CONFIGURATION");
    }
    Ok(Options { socket, app, check })
}

pub(crate) fn bundle_for_executable(executable: &Path) -> Result<PathBuf, &'static str> {
    let app = executable
        .ancestors()
        .nth(6)
        .ok_or("INVALID_CONFIGURATION")?;
    if !executable.is_absolute()
        || app.join("Contents/Helpers/ConnDockMCP.app/Contents/MacOS/conndock-mcp") != executable
        || app.extension().is_none_or(|extension| extension != "app")
    {
        return Err("INVALID_CONFIGURATION");
    }
    Ok(app.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn accepts_only_absolute_generated_configuration_and_optional_check() {
        let expected = Options {
            socket: "/private/tmp/ipc.sock".into(),
            app: Some("/Applications/ConnDock.app".into()),
            check: true,
        };
        assert_eq!(
            parse(args(&[
                "--check",
                "--socket",
                "/private/tmp/ipc.sock",
                "--app",
                "/Applications/ConnDock.app"
            ])),
            Ok(expected)
        );
        assert_eq!(
            parse(args(&["--socket", "/private/tmp/ipc.sock"])),
            Ok(Options {
                socket: "/private/tmp/ipc.sock".into(),
                app: None,
                check: false
            })
        );
        for values in [
            vec![],
            vec!["--socket"],
            vec!["--socket", "relative"],
            vec!["--socket", "/s", "--app", "relative"],
            vec!["--socket", "/s", "--socket", "/t"],
            vec!["--socket", "/s", "--check", "--check"],
            vec!["--socket", "/s", "--token", "private"],
            vec!["--socket", "/s", "--http"],
        ] {
            assert_eq!(parse(args(&values)), Err("INVALID_CONFIGURATION"));
        }
    }

    #[test]
    fn derives_identity_only_from_the_exact_embedded_helper_location() {
        assert_eq!(
            bundle_for_executable(Path::new(
                "/Applications/ConnDock.app/Contents/Helpers/ConnDockMCP.app/Contents/MacOS/conndock-mcp"
            )),
            Ok(PathBuf::from("/Applications/ConnDock.app"))
        );
        for path in [
            "/tmp/conndock-mcp",
            "/Applications/ConnDock.app/Contents/MacOS/conndock-mcp",
            "/Applications/ConnDock.app/Contents/Helpers/other",
            "/Applications/plain/Contents/Helpers/conndock-mcp",
            "relative.app/Contents/Helpers/ConnDockMCP.app/Contents/MacOS/conndock-mcp",
            "/Applications/ConnDock.app/Contents/Helpers/Other.app/Contents/MacOS/conndock-mcp",
        ] {
            assert_eq!(
                bundle_for_executable(Path::new(path)),
                Err("INVALID_CONFIGURATION")
            );
        }
    }
}
