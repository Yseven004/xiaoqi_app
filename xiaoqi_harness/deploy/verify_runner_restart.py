"""CI-only: kill the real runner, then recover completed and interrupted jobs."""
import json
import subprocess
import sys
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


def main():
    runner = sys.argv[1]
    metadata = invoke(runner, 'begin')
    json.loads(metadata)
    subprocess.run(['docker', 'restart', '--signal', 'SIGKILL', '--timeout', '0', runner], check=True, capture_output=True, timeout=30)
    deadline = time.monotonic() + 30
    while True:
        ready = subprocess.run(['docker', 'exec', runner, 'python3', '-c', "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8090/health',timeout=2).close()"], capture_output=True, timeout=5)
        if ready.returncode == 0:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError('Runner did not recover after restart')
        time.sleep(0.25)
    print(invoke(runner, 'verify', metadata))


if __name__ == '__main__':
    main()
