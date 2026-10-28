#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CONNDOCK_TEST_METHOD=testMCPThroughHelperAndRealSSH
export CONNDOCK_TEST_PLATFORM=macos
export CONNDOCK_TEST_PHASE=phase5
case "${1:-}" in
  '') exec "$ROOT/scripts/test-linux-services.sh" --apple-only ;;
  --codex) export CONNDOCK_TEST_MCP_CODEX=1 ;;
  *) echo 'Usage: test-mcp.sh [--codex]' >&2; exit 2 ;;
esac
command -v codex >/dev/null
python3 - "$ROOT" <<'PY'
import json,os,pathlib,signal,subprocess,sys,tempfile,time
root=pathlib.Path(sys.argv[1])
started=time.time()
fixture=subprocess.Popen([str(root/'scripts/test-linux-services.sh'),'--apple-only'])
folder=pathlib.Path.home()/'Library/Containers/local.SSHClient.macOS/Data/Documents'
try:
    ready=None
    while time.time()-started<240:
        candidates=[p for p in folder.glob('MCPTestReady-*.json') if p.stat().st_mtime>=started and p.stat().st_uid==os.getuid()]
        if candidates:
            if len(candidates)!=1:raise RuntimeError('Ambiguous test endpoint')
            ready=candidates[0];break
        if fixture.poll() is not None:raise RuntimeError('Fixture stopped before Codex setup')
        time.sleep(.2)
    if ready is None:raise RuntimeError('Fixture did not become ready')
    endpoint=json.loads(ready.read_text())
    scratch=pathlib.Path(tempfile.mkdtemp(prefix='phase5-codex-',dir=root/'build'))
    arguments=['codex','exec','--ignore-user-config','--ignore-rules','--ephemeral','--sandbox','read-only','--skip-git-repo-check','--json','-C',str(scratch),
      '-c','mcp_servers.conndock.command='+json.dumps(endpoint['helper']),
      '-c','mcp_servers.conndock.args='+json.dumps(['--socket',endpoint['socket']]),
      '-c','mcp_servers.conndock.tool_timeout_sec=90',
      'Verify the isolated ConnDock MCP test. Use only the conndock MCP tools: call list_hosts, then get_server_metrics for host_id '+endpoint['host_id']+'. Do not run shell commands or other tools. Report whether both succeeded and memory_total is positive.']
    log=root/'build/phase5-codex.log'
    with log.open('w') as output:
        cli=subprocess.Popen(arguments,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:cli.wait(timeout=140)
        except subprocess.TimeoutExpired:
            os.killpg(cli.pid,signal.SIGTERM);cli.wait(timeout=5)
    calls=[]
    for line in log.read_text().splitlines():
        try:event=json.loads(line)
        except ValueError:continue
        item=event.get('item',{})
        if event.get('type')=='item.completed' and item.get('type')=='mcp_tool_call' and item.get('server')=='conndock':calls.append(item)
    successful={item.get('tool') for item in calls if item.get('status')=='completed' and not item.get('error') and not item.get('result',{}).get('isError')}
    ok=cli.returncode==0 and {'list_hosts','get_server_metrics'}<=successful
    done=folder/('MCPTestDone-'+endpoint['run_id']+'.json')
    fd=os.open(done,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as result:json.dump({'ok':ok},result)
    print('Real Codex CLI verification: '+('PASS' if ok else 'FAILED; inspect build/phase5-codex.log'))
    sys.exit(fixture.wait(timeout=60) or (0 if ok else 1))
finally:
    if fixture.poll() is None:
        fixture.terminate()
        try:fixture.wait(timeout=10)
        except subprocess.TimeoutExpired:fixture.kill();fixture.wait()
PY
