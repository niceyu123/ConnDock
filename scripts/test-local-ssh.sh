#!/bin/bash
# An isolated, real OpenSSH server; never changes system Remote Login or accounts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
case "$MODE" in ''|--apple|--apple-only|--connections) ;; *) echo 'Usage: test-local-ssh.sh [--apple|--apple-only|--connections]' >&2; exit 2 ;; esac
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
mkdir -p "$ROOT/build"
TEST_DIR="$(mktemp -d "$ROOT/build/ssh-test.XXXXXX")"
chmod 700 "$TEST_DIR"
SERVER_PID=''
CONNDOCK_AGENT_PID=''
CONNDOCK_AGENT_DIRECTORY=''
cleanup() {
    if [[ -n "$CONNDOCK_AGENT_PID" ]]; then kill "$CONNDOCK_AGENT_PID" >/dev/null 2>&1 || true; fi
    if [[ -n "$CONNDOCK_AGENT_DIRECTORY" ]]; then rm -f "$CONNDOCK_AGENT_DIRECTORY/agent.sock"; rmdir "$CONNDOCK_AGENT_DIRECTORY" 2>/dev/null || true; fi
    if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
    rm -f "$TEST_DIR/client" "$TEST_DIR/rejected-client" "$TEST_DIR/host"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/host"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/client"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/rejected-client"
TEST_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1',0))
    print(s.getsockname()[1])
PY
)"
TEST_USER="$(id -un)"
mkdir "$TEST_DIR/work"
printf '%s\n' 'Temporary local OpenSSH integration workspace.' > "$TEST_DIR/work/README.txt"
if [[ "${CONNDOCK_TEST_PHASE:-}" == phase3 ]]; then
    ln -s "$TEST_DIR/work" "$TEST_DIR/work/ConnDock-Test"
    export CONNDOCK_TEST_UI_UPLOAD_FILE="$TEST_DIR/UI-upload-中文.txt"
    export CONNDOCK_TEST_UI_EXPORT_DIRECTORY="$TEST_DIR/exports"
    printf 'Real SFTP file picker and Finder drop verification.\n' > "$CONNDOCK_TEST_UI_UPLOAD_FILE"
    mkdir "$CONNDOCK_TEST_UI_EXPORT_DIRECTORY"
fi
cat > "$TEST_DIR/sshd_config" <<EOF
Port $TEST_PORT
ListenAddress 127.0.0.1
HostKey $TEST_DIR/host
PidFile $TEST_DIR/sshd.pid
AuthorizedKeysFile $TEST_DIR/client.pub
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
AllowUsers $TEST_USER
# A real system shell with deterministic locale, no personal startup hooks,
# and no readline interpretation of UTF-8 test command bytes.
Subsystem sftp /usr/libexec/sftp-server
ForceCommand $TEST_DIR/dispatch.sh
PrintMotd no
LogLevel ERROR
EOF
if [[ "$MODE" == --connections ]]; then
    printf '\nPermitTTY no\nAllowTcpForwarding yes\n' >> "$TEST_DIR/sshd_config"
fi
cat > "$TEST_DIR/dispatch.sh" <<'EOF'
#!/bin/bash
if [[ "${SSH_ORIGINAL_COMMAND:-}" == /usr/libexec/sftp-server ]]; then
    exec /usr/libexec/sftp-server -d "$(dirname "$0")/work"
elif [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
else
    exec /usr/bin/env LC_ALL=en_US.UTF-8 PS1=__CONNDOCK_TEST_READY__ /bin/bash --noprofile --norc --noediting -i
fi
EOF
chmod 700 "$TEST_DIR/dispatch.sh"
/usr/sbin/sshd -t -f "$TEST_DIR/sshd_config"
/usr/sbin/sshd -D -e -f "$TEST_DIR/sshd_config" > "$TEST_DIR/server.log" 2>&1 &
SERVER_PID=$!
export CONNDOCK_TEST_HOST=127.0.0.1 CONNDOCK_TEST_PORT="$TEST_PORT" CONNDOCK_TEST_USER="$TEST_USER"
export CONNDOCK_TEST_KEY_FILE="$TEST_DIR/client"
export CONNDOCK_TEST_UNAUTHORIZED_KEY_FILE="$TEST_DIR/rejected-client"
export CONNDOCK_TEST_WORK_DIRECTORY="$TEST_DIR/work"
export CONNDOCK_TEST_READY_MARKER=__CONNDOCK_TEST_READY__
export CONNDOCK_TEST_FINGERPRINT="$(ssh-keygen -lf "$TEST_DIR/host.pub" -E sha256 | awk '{print $2}')"
if [[ "$MODE" == --connections ]]; then
    export CONNDOCK_TEST_TARGET_PORT="$TEST_PORT" CONNDOCK_TEST_ISOLATED=1
    export SSH_AUTH_SOCK="$TEST_DIR/agent.sock"
    if [[ "${CONNDOCK_TEST_AGENT_IN_CONTAINER:-}" == 1 ]]; then
        CONNDOCK_AGENT_DIRECTORY="$(mktemp -d "$HOME/Library/Containers/local.SSHClient.macOS/Data/Library/Caches/CDa.XXXXXX")"
        chmod 700 "$CONNDOCK_AGENT_DIRECTORY"
        export SSH_AUTH_SOCK="$CONNDOCK_AGENT_DIRECTORY/agent.sock"
    fi
    ssh-agent -D -a "$SSH_AUTH_SOCK" > "$TEST_DIR/agent.log" 2>&1 &
    CONNDOCK_AGENT_PID=$!
    for attempt in {1..100}; do [[ -S "$SSH_AUTH_SOCK" ]] && break; sleep .05; done
    ssh-add "$TEST_DIR/client" > "$TEST_DIR/agent-add.log" 2>&1
    export CONNDOCK_TEST_AGENT_FINGERPRINT="$(ssh-keygen -lf "$TEST_DIR/client.pub" -E sha256 | awk '{print $2}')"
fi
python3 - <<'PY'
import os,socket,time
for attempt in range(50):
    try:
        with socket.create_connection(('127.0.0.1',int(os.environ['CONNDOCK_TEST_PORT'])),timeout=.1):break
    except OSError:time.sleep(.02)
else:raise SystemExit('Local OpenSSH failed to start')
PY
if [[ "$MODE" == --apple-only ]]; then
    "$ROOT/scripts/test-apple-ssh.sh"
    exit
fi
if [[ "$MODE" == --connections ]]; then
    cd "$ROOT/rust-core"
    cargo test --locked -p conndock-core --test connections -- --ignored --test-threads=1
    if [[ "${CONNDOCK_CONNECTIONS_APPLE:-}" == 1 ]]; then
        cd "$ROOT"
        export CONNDOCK_TEST_PHASE=phase8
        export CONNDOCK_TEST_METHOD="${CONNDOCK_TEST_METHOD:-testAdvancedTransportThroughBridge}"
        "$ROOT/scripts/test-apple-ssh.sh"
    fi
    exit
fi
cd "$ROOT/rust-core"
if [[ "${CONNDOCK_TEST_PHASE:-}" == phase3 ]]; then
    export CONNDOCK_TEST_ISOLATED=1
    cargo test --locked -p conndock-core --test remote_services -- --ignored --test-threads=1 --nocapture --skip openssh_sftp_two_gib_streaming
    exit
fi
if [[ -n "${CONNDOCK_TEST_FILTER:-}" ]]; then
    cargo test --locked -p conndock-core --test openssh "$CONNDOCK_TEST_FILTER" -- --ignored --test-threads=1
    exit
fi
cargo test --locked -p conndock-core --test openssh openssh_key_pty_and_lifecycle -- --ignored --test-threads=1
cargo test --locked -p conndock-core --test openssh openssh_abrupt_transport_loss_and_full_output_cancellation -- --ignored --test-threads=1
cargo test --locked -p conndock-core --test openssh openssh_bidirectional_window_flow_control -- --ignored --test-threads=1
cargo test --locked -p conndock-core --test openssh openssh_interactive_top -- --ignored --test-threads=1
cargo test --locked -p conndock-core --test openssh openssh_rejected_authentication -- --ignored --test-threads=1
echo 'Real local OpenSSH: Ed25519, PTY, UTF-8/ANSI, resize, Ctrl+C, trust, reconnect, cancellation passed.'
echo 'Password success still requires a separately configured password-enabled SSH service.'
if [[ "${1:-}" == "--apple" ]]; then
    "$ROOT/scripts/test-apple-ssh.sh"
fi
