#!/bin/bash
# Disposable, loopback-only Linux/OpenSSH fixture. No production credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
MODE="${1:-}"
case "$MODE" in ''|--quick|--apple|--apple-only|--stability|--terminal) ;; *) echo 'Usage: test-linux-services.sh [--quick|--apple|--apple-only|--stability|--terminal]' >&2; exit 2 ;; esac
docker info > /dev/null
mkdir -p build
TEST_DIR="$(mktemp -d "$ROOT/build/linux-ssh-test.XXXXXX")"
chmod 700 "$TEST_DIR"
CONTAINER_ID=''
cleanup() {
    if [[ -n "$CONTAINER_ID" ]]; then docker rm -f -v "$CONTAINER_ID" > /dev/null 2>&1 || true; fi
    rm -f "$TEST_DIR/client" "$TEST_DIR/unauthorized" "$TEST_DIR/server/host"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$TEST_DIR/server"
mkdir "$TEST_DIR/work"
# The parent is 0700. Only this disposable child is shared across the host and
# container UIDs; private keys stay in the separate, unreadable fixture mount.
chmod 777 "$TEST_DIR/work"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/client"
if [[ "$MODE" == --terminal ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/unauthorized"
    export CONNDOCK_TEST_UNAUTHORIZED_KEY_FILE="$TEST_DIR/unauthorized"
fi
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/server/host"
cp "$TEST_DIR/client.pub" "$TEST_DIR/server/client.pub"
cat > "$TEST_DIR/server/dispatch.sh" <<'EOF'
#!/bin/bash
if [[ "${SSH_ORIGINAL_COMMAND:-}" == /usr/lib/openssh/sftp-server ]]; then
    exec /usr/lib/openssh/sftp-server
elif [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
else
    exec /usr/bin/env LC_ALL=C.UTF-8 PS1=__CONNDOCK_TEST_READY__ /bin/bash --noprofile --norc --noediting -i
fi
EOF
cat > "$TEST_DIR/server/sshd_config" <<'EOF'
Port 22
HostKey /run/conndock/host
PidFile /run/conndock/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
UsePAM no
StrictModes yes
AllowUsers conndock
AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp /usr/lib/openssh/sftp-server
ForceCommand /run/conndock/dispatch.sh
PrintMotd no
LogLevel ERROR
EOF
cat > "$TEST_DIR/server/start.sh" <<'EOF'
#!/bin/sh
set -eu
mkdir -p /run/sshd /run/conndock /home/conndock/.ssh
cp /fixture/host /run/conndock/host
chmod 600 /run/conndock/host
cp /fixture/dispatch.sh /run/conndock/dispatch.sh
chmod 755 /run/conndock/dispatch.sh
cp /fixture/client.pub /home/conndock/.ssh/authorized_keys
chmod 700 /home/conndock/.ssh
chmod 600 /home/conndock/.ssh/authorized_keys
chown -R conndock:conndock /home/conndock/.ssh
mkdir "$CONNDOCK_WORK_DIRECTORY/permission-denied"
chmod 000 "$CONNDOCK_WORK_DIRECTORY/permission-denied"
printf 'Isolated real Linux OpenSSH workspace.\n' > "$CONNDOCK_WORK_DIRECTORY/README.txt"
ln -s "$CONNDOCK_WORK_DIRECTORY" /home/conndock/ConnDock-Test
exec /usr/sbin/sshd -D -e -f /fixture/sshd_config
EOF
IMAGE='conndock-phase3-openssh:debian12'
# Fixed official base; package installation belongs only to this test image.
docker build -t "$IMAGE" - > build/phase3-linux-fixture-build.log 2>&1 <<'EOF'
FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server bash procps ca-certificates && rm -rf /var/lib/apt/lists/* && useradd -m -s /bin/bash conndock && passwd -d conndock
EOF
CONTAINER_ID="$(docker run -d --rm -p 127.0.0.1::22 --label conndock.fixture=phase3 \
    --mount "type=bind,source=$TEST_DIR/server,target=/fixture,readonly" \
    --mount "type=bind,source=$TEST_DIR/work,target=$TEST_DIR/work" \
    -e "CONNDOCK_WORK_DIRECTORY=$TEST_DIR/work" "$IMAGE" /bin/sh /fixture/start.sh)"
PORT="$(docker port "$CONTAINER_ID" 22/tcp)"
export CONNDOCK_TEST_HOST=127.0.0.1 CONNDOCK_TEST_PORT="${PORT##*:}" CONNDOCK_TEST_USER=conndock
export CONNDOCK_TEST_KEY_FILE="$TEST_DIR/client"
export CONNDOCK_TEST_FINGERPRINT="$(ssh-keygen -lf "$TEST_DIR/server/host.pub" -E sha256 | awk '{print $2}')"
export CONNDOCK_TEST_WORK_DIRECTORY="$TEST_DIR/work" CONNDOCK_TEST_READY_MARKER=__CONNDOCK_TEST_READY__
export CONNDOCK_TEST_ISOLATED=1 CONNDOCK_TEST_EXPECT_LINUX=1
export CONNDOCK_TEST_PHASE="${CONNDOCK_TEST_PHASE:-phase3}"
export CONNDOCK_TEST_DENIED_PATH="$TEST_DIR/work/permission-denied"
export CONNDOCK_TEST_BASELINE_FILE="$TEST_DIR/baseline.txt"
export CONNDOCK_TEST_CONTAINER_ID="$CONTAINER_ID"
python3 - <<'PY'
import os,socket,time
for attempt in range(100):
    try:
        with socket.create_connection(('127.0.0.1',int(os.environ['CONNDOCK_TEST_PORT'])),timeout=.2) as connection:
            if connection.recv(128).startswith(b'SSH-2.0-'):break
    except OSError:pass
    time.sleep(.1)
else:raise SystemExit('Linux OpenSSH did not become ready')
PY
docker exec "$CONTAINER_ID" sh -c 'awk "/^MemTotal:/ {printf \"%.0f \", \$2*1024}" /proc/meminfo; df -Pk / | awk "NR==2 {printf \"%.0f %.0f \", \$2*1024, \$3*1024}"; awk "{printf \"%.0f\\n\", \$1}" /proc/uptime' > "$CONNDOCK_TEST_BASELINE_FILE"
if [[ "$MODE" != --apple-only ]]; then
    cd "$ROOT/rust-core"
    TEST_TARGET=remote_services
    BUILD_JSON="$ROOT/build/phase3-remote-test-build.jsonl"
    if [[ "$MODE" == --terminal ]]; then TEST_TARGET=openssh; BUILD_JSON="$ROOT/build/phase6-terminal-test-build.jsonl"; fi
    cargo test --locked -p conndock-core --test "$TEST_TARGET" --no-run --message-format=json > "$BUILD_JSON"
    TEST_BINARY="$(python3 - "$BUILD_JSON" "$TEST_TARGET" <<'PY'
import json,sys
for line in open(sys.argv[1]):
    event=json.loads(line)
    if event.get('target',{}).get('name')==sys.argv[2] and event.get('executable'):print(event['executable'])
PY
)"
    ARGS=(--ignored --test-threads=1 --nocapture)
    if [[ "$MODE" == --quick ]]; then ARGS+=(--skip openssh_sftp_two_gib_streaming --skip openssh_stability_multisession_and_channel_reuse); fi
    if [[ "$MODE" == --stability ]]; then ARGS+=(--exact openssh_stability_multisession_and_channel_reuse); fi
    if [[ "$MODE" == --terminal ]]; then ARGS+=(--skip openssh_password_pty_and_wrong_password); fi
    /usr/bin/time -l "$TEST_BINARY" "${ARGS[@]}"
    cd "$ROOT"
fi
if [[ "$MODE" == --apple || "$MODE" == --apple-only ]]; then
    export CONNDOCK_TEST_METHOD="${CONNDOCK_TEST_METHOD:-testSFTPAndLinuxMonitorThroughBridge}"
    export CONNDOCK_TEST_UI_UPLOAD_FILE="$TEST_DIR/UI-upload-中文.txt"
    export CONNDOCK_TEST_UI_EXPORT_DIRECTORY="$TEST_DIR/exports"
    printf 'ConnDock SFTP UI 中文 verification.\n' > "$CONNDOCK_TEST_UI_UPLOAD_FILE"
    mkdir "$CONNDOCK_TEST_UI_EXPORT_DIRECTORY"
    "$ROOT/scripts/test-apple-ssh.sh"
fi
echo 'Linux SFTP/monitor verification finished; fixture and private keys are removed on exit.'
