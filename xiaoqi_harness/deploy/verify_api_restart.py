"""CI-only: kill the API owner after a real MCP effect, collect its original reply."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def command(*args, timeout=15, check=True):
    return subprocess.run(['docker', *args], capture_output=True, text=True,
                          timeout=timeout, check=check)


def main(runner):
    info = json.loads(command('inspect', runner).stdout)[0]
    env = dict(item.split('=', 1) for item in info['Config']['Env'] if '=' in item)
    networks = list(info['NetworkSettings']['Networks'])
    if env.get('XIAOQI_SANDBOX_OWNER_LABEL') != 'com.xiaoqi.ci-stdio-sandbox' or len(networks) != 1:
        raise RuntimeError('API restart gate requires an isolated CI runner')
    volume = 'xiaoqi-stdio-api-state'
    names = ['xiaoqi-stdio-api-before', 'xiaoqi-stdio-api-after']
    process_env = {**os.environ, 'SANDBOX_RUNNER_TOKEN': env['SANDBOX_RUNNER_TOKEN']}
    base = ['run', '--network', networks[0], '--volume', volume + ':/var/lib/xiaoqi',
            '--env', 'SANDBOX_RUNNER_TOKEN', '--env', f'SANDBOX_RUNNER_URL=http://{runner}:8090',
            '--entrypoint', '/app/bin/verify_stdio_runtime']
    command('volume', 'create', volume)
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix='xiaoqi-api-restart-') as directory:
            path = Path(directory) / 'before.log'
            with path.open('wb') as output:
                process = subprocess.Popen(['docker', *base, '--name', names[0],
                    'xiaoqi-genkit-server:local', '--mcp-api-start', '/var/lib/xiaoqi/probe'],
                    stdout=output, stderr=subprocess.STDOUT, env=process_env)
                deadline = time.monotonic() + 40
                while True:
                    if path.stat().st_size > 2 * 1024 * 1024:
                        raise RuntimeError('API start probe exceeded its diagnostic limit')
                    text = path.read_text(errors='replace')
                    if 'MCP_API_RESTART_READY\n' in text:
                        break
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError('API effect was not ready: ' + text[-1800:])
                    time.sleep(0.05)
                command('kill', '--signal', 'KILL', names[0])
                process.wait(timeout=15)
            path = Path(directory) / 'after.log'
            with path.open('wb') as output:
                process = subprocess.Popen(['docker', *base, '--name', names[1],
                    'xiaoqi-genkit-server:local', '--mcp-api-recover', '/var/lib/xiaoqi/probe'],
                    stdout=output, stderr=subprocess.STDOUT, env=process_env)
                code = process.wait(timeout=75)
            if path.stat().st_size > 2 * 1024 * 1024:
                raise RuntimeError('API recovery probe exceeded its diagnostic limit')
            text = path.read_text(errors='replace')
            passed = [json.loads(line) for line in text.splitlines() if line.startswith('{"gate":"mcp-api-restart"')]
            if code or len(passed) != 1 or not all(passed[0].values()):
                raise RuntimeError('Original API response recovery failed: ' + text[-2400:])
            print(json.dumps(passed[0]))
    finally:
        for name in names:
            command('rm', '-f', name, check=False)
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        command('volume', 'rm', volume, check=False)


if __name__ == '__main__':
    main(sys.argv[1])
