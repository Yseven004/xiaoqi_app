"""CI-only: kill the real runner, then recover completed and interrupted jobs."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


SCRIPT = r'''
import base64, json, os, sys, time, urllib.error, urllib.request, uuid
import docker
from docker.errors import NotFound

base = 'http://127.0.0.1:8090'
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def post(path, body):
    request = urllib.request.Request(base + path, data=json.dumps(body).encode(), headers={'Authorization':'Bearer ' + os.environ['SANDBOX_RUNNER_TOKEN'], 'Content-Type':'application/json'})
    return opener.open(request, timeout=25)
def identity(task):
    return {'task_id':task, 'execution_id':uuid.uuid4().hex, 'issued_at':int(time.time()*1000)}
if sys.argv[1] == 'begin':
    complete = identity('restart-completed')
    with post('/v1/execute', {**complete, 'language':'shell', 'code':"printf 'finished-before-restart'"}) as response:
        result = [json.loads(line) for line in response if line][-1]
    assert result['ok'] is True
    active = identity('restart-interrupted')
    response = post('/v1/execute', {**active, 'language':'shell', 'code':"printf 'saved-before-restart' > /workspace/output/restarted.txt\nsleep 60"})
    while True:
        event = json.loads(response.readline())
        if event['type'] == 'sandbox_started':
            break
    client = docker.from_env()
    container = client.containers.get(event['sandbox_id'])
    deadline = time.monotonic() + 15
    while True:
        try:
            stream, _ = container.get_archive('/workspace/output/restarted.txt')
            b''.join(stream)
            break
        except NotFound:
            if time.monotonic() >= deadline:
                raise RuntimeError('Restart fixture never wrote its file')
            time.sleep(0.05)
    response.close()
    client.close()
    print(json.dumps({'completed':complete,'interrupted':active}))
else:
    requests = json.loads(sys.argv[2])
    for kind, identity in requests.items():
        path = '/v1/executions/' + identity['execution_id']
        with post(path + '/result', identity) as response:
            result = json.load(response)
        assert result['finished'] is True
        completion = result['completion']
        assert completion['cleanup_pending'] is False
        if kind == 'completed':
            assert completion['ok'] is True
            assert completion['stdout'] == 'finished-before-restart'
        else:
            assert completion['ok'] is False
            assert 'do not automatically replay' in completion['error']
            artifact, = completion['artifacts']
            assert artifact['name'] == 'restarted.txt'
            assert base64.b64decode(artifact['base64']) == b'saved-before-restart'
        with post(path + '/ack', identity) as response:
            assert json.load(response)['acknowledged'] is True
        with post(path + '/result', identity) as response:
            assert json.load(response)['completion'] is None
        try:
            with post('/v1/execute', {**identity, 'language':'shell', 'code':'true'}):
                raise RuntimeError('Restart allowed duplicate execution')
        except urllib.error.HTTPError as error:
            assert error.code == 409
            error.close()
    print(json.dumps({'gate':'runner-restart','passed':True,'completed_result_preserved':True,'interrupted_files_preserved':True,'duplicate_execution_rejected':True}))
'''


def invoke(runner, *arguments):
    result = subprocess.run(
        ['docker', 'exec', '-i', runner, 'python3', '-', *arguments],
        input=SCRIPT, text=True, capture_output=True, timeout=45,
    )
    if result.returncode:
        raise RuntimeError('Runner restart verification failed: ' + result.stderr[-1800:])
    return result.stdout.strip()


def restart(runner):
    subprocess.run(['docker', 'restart', '--signal', 'SIGKILL', '--timeout', '0', runner], check=True, capture_output=True, timeout=30)
    deadline = time.monotonic() + 30
    while True:
        ready = subprocess.run(['docker', 'exec', runner, 'python3', '-c', "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8090/health',timeout=2).close()"], capture_output=True, timeout=5)
        if ready.returncode == 0:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError('Runner did not recover after restart')
        time.sleep(0.25)


def verify_mcp_restart(runner, info):
    environment = dict(item.split('=', 1) for item in info['Config']['Env'] if '=' in item)
    networks = list(info['NetworkSettings']['Networks'])
    if environment.get('XIAOQI_SANDBOX_OWNER_LABEL') != 'com.xiaoqi.ci-stdio-sandbox' or len(networks) != 1:
        raise RuntimeError('MCP restart gate requires its isolated CI runner')
    name = 'xiaoqi-stdio-restart-probe'
    with tempfile.TemporaryDirectory(prefix='xiaoqi-mcp-restart-') as root:
        path = Path(root) / 'probe.log'
        with path.open('wb') as output:
            process = subprocess.Popen([
                'docker', 'run', '--rm', '--interactive', '--name', name, '--network', networks[0],
                '--env', 'SANDBOX_RUNNER_TOKEN', '--env', f'SANDBOX_RUNNER_URL=http://{runner}:8090',
                '--entrypoint', '/app/bin/verify_stdio_runtime', 'xiaoqi-genkit-server:local', '--mcp-restart-probe',
            ], stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT,
               env={**os.environ, 'SANDBOX_RUNNER_TOKEN': environment['SANDBOX_RUNNER_TOKEN']})
            try:
                deadline = time.monotonic() + 45
                ready = None
                while ready is None:
                    if path.stat().st_size > 2 * 1024 * 1024:
                        raise RuntimeError('MCP restart probe exceeded diagnostic budget')
                    text = path.read_text(errors='replace')
                    for line in text.splitlines(keepends=True):
                        if line.startswith('MCP_RESTART_READY:') and line.endswith('\n'):
                            ready = json.loads(line.split(':', 1)[1])
                    if ready is None:
                        if process.poll() is not None or time.monotonic() >= deadline:
                            raise RuntimeError('MCP restart probe was not ready: ' + text[-1800:])
                        time.sleep(0.1)
                lease = ready['lease_id']
                if not isinstance(lease, str) or not re.fullmatch(r'[a-f0-9]{32}', lease):
                    raise RuntimeError('Invalid original MCP lease marker')
                ids = subprocess.check_output(['docker', 'ps', '-q',
                    '--filter', 'label=com.xiaoqi.ci-stdio-sandbox=true',
                    '--filter', f'label=com.xiaoqi.mcp-lease={lease}',
                    '--filter', 'label=com.xiaoqi.role=mcp-server'], text=True, timeout=10).split()
                if len(ids) != 1:
                    raise RuntimeError('Original MCP process was not uniquely identified')
                initial = json.loads(subprocess.check_output(['docker', 'inspect', ids[0]], text=True, timeout=10))[0]
                if not initial['Config']['OpenStdin'] or initial['Config']['StdinOnce']:
                    raise RuntimeError('Original MCP stdin is not configured for reattachment')
                original = initial['Id']
                restart(runner)
                restored = json.loads(subprocess.check_output(['docker', 'inspect', original], text=True, timeout=10))[0]
                if restored['Id'] != original or not restored['State']['Running']:
                    raise RuntimeError('Runner restart replaced or stopped the original MCP process')
                process.stdin.write(b'CONTINUE\n')
                process.stdin.flush()
                if process.wait(timeout=60) != 0:
                    raise RuntimeError('Original MCP SDK call did not resume: ' + path.read_text(errors='replace')[-2400:])
                passed = [line for line in path.read_text(errors='replace').splitlines() if line.startswith('MCP_RESTART_PASSED:')]
                if len(passed) != 1 or not all(json.loads(passed[0].split(':', 1)[1]).values()):
                    raise RuntimeError('MCP original RPC/process/input/file checks were not verified')
                print(json.dumps({'gate': 'mcp-runner-restart', 'passed': True, 'original_sdk_call_resumed': True,
                                  'one_effect': True, 'original_container': True, 'original_input_snapshot': True,
                                  'original_artifact_integrity': True}))
            except BaseException:
                # Capture the failing isolated runner before the shell trap
                # removes it. Never print environment, tokens or RPC bodies.
                diagnostics = subprocess.run(['docker', 'logs', '--tail', '40', runner],
                    capture_output=True, text=True, timeout=10)
                print('MCP_RESTART_RUNNER_LOG:' + (diagnostics.stdout + diagnostics.stderr)[-8000:], flush=True)
                if ready is not None:
                    state = subprocess.run(['docker', 'exec', runner, 'python3', '-c',
                        "import os,sqlite3,json,sys; d=sqlite3.connect('file:'+os.environ['XIAOQI_MCP_DB']+'?mode=ro',uri=True); "
                        "r=d.execute('SELECT value FROM leases WHERE id=?',(sys.argv[1],)).fetchone(); "
                        "v=json.loads(r[0]) if r else {}; print(json.dumps({k:v.get(k) for k in "
                        "('phase','closed','stopped','error','cursor','stdout_offset','send_sequence')}))", ready['lease_id']],
                        capture_output=True, text=True, timeout=10)
                    print('MCP_RESTART_LEASE_STATE:' + state.stdout[-2000:], flush=True)
                raise
            finally:
                subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=20)
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
                process.stdin.close()


def main():
    runner = sys.argv[1]
    info = json.loads(subprocess.check_output(['docker', 'inspect', runner], text=True, timeout=10))[0]
    environment = dict(item.split('=', 1) for item in info['Config']['Env'] if '=' in item)
    if environment.get('XIAOQI_SANDBOX_OWNER_LABEL') != 'com.xiaoqi.ci-stdio-sandbox':
        raise RuntimeError('Restart verification cannot target a production runner')
    metadata = invoke(runner, 'begin')
    json.loads(metadata)
    restart(runner)
    print(invoke(runner, 'verify', metadata))
    verify_mcp_restart(runner, info)


if __name__ == '__main__':
    main()
