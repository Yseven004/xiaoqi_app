"""Exercise release/recovery with a fake Docker in an isolated /tmp root."""
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

if sys.platform.startswith('linux'):
    import fcntl

from test_release_artifact import COMMIT, make_bundle
from release_artifact import sha

HERE = Path(__file__).parent
DOCKER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
a = sys.argv[1:]
r = pathlib.Path(os.environ['XIAOQI_DEPLOY_ROOT'])
with (r/'docker.calls').open('a') as log: log.write(' '.join(a)+'\n')
if a[0] == 'inspect':
    print('healthy' if '--format' in a else json.dumps([dict(Id='sha256:'+'b'*64, Os='linux', Architecture='amd64')]))
elif a[0] == 'compose':
    if 'ps' in a: print('container-'+a[-1])
    if 'up' in a and os.environ.get('FAIL_ALL_UP') == '1': sys.exit(9)
    if 'up' in a and os.environ.get('FAIL_ACTIVATE') == '1' and not (r/'failed-once').exists():
        (r/'failed-once').touch(); sys.exit(9)
elif a[0] == 'run':
    if 'du' in a: print('10 /data')
    elif '/app/bin/verify_capability_chain' in a:
        if os.environ.get('FAIL_PROBE') == '1': sys.exit(8)
    elif '/app/bin/verify_official_catalog' in a:
        if os.environ.get('FAIL_CURATED_PROBE') == '1': sys.exit(8)
    else:
        mounts = [a[i+1] for i,x in enumerate(a) if x == '-v']
        for mount in mounts:
            if ':/backup' in mount:
                output = pathlib.Path(mount.split(':/backup')[0])
                if '--output' in a: (output/'store.json').write_text('{}')
                if any('tar -czf' in x for x in a): (output/'data.tgz').write_bytes(b'backup')
'''
CURL = '#!/usr/bin/env python3\nprint(\'{"status":"ok","release_id":"test","api_contract_version":"18"}\')\n'
DF = '#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\n/dev/test 40000000 1 %s 1%% /\\n" "${FAKE_FREE_KB:-30000000}"\n'


@unittest.skipUnless(sys.platform.startswith('linux'), 'isolated shell recovery tests run on the Linux build runner')
class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='xiaoqi-deploy-test-', dir='/tmp'))
        self.addCleanup(lambda: shutil.rmtree(self.root))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name, text in [('docker', DOCKER), ('curl', CURL), ('df', DF)]:
            path = self.bin / name
            path.write_text(text)
            path.chmod(0o755)
        for name in ('config', 'restore', 'incoming', 'logs', 'current/genkit_server/lib/src', 'current/deploy'):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        (self.root / 'config/single-server.env').write_text('XIAOQI_PUBLIC_HOST=example.com\n')
        (self.root / 'current/genkit_server/pubspec.yaml').write_text('name: old\n')
        (self.root / 'current/deploy/compose.yaml').write_text('services: {}\n')
        (self.root / 'current/deploy/Caddyfile.docker').write_text('example.com { respond 200 }\n')
        (self.root / 'current/.xiaoqi-release').write_text('old-release\n')
        self.bundle = make_bundle(self.root)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], XIAOQI_DEPLOY_TEST='1', XIAOQI_DEPLOY_ROOT=str(self.root))

    def deploy(self, **extra):
        return subprocess.run(['bash', str(HERE/'release_manager.sh'), 'deploy', str(self.bundle), 'new-release', sha(self.bundle), COMMIT, 'test', '18'],
                              env=dict(self.env, **extra), capture_output=True, text=True, timeout=25)

    def test_success_only_loads_prebuilt_images_and_keeps_one_restore(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PUBLIC_RELEASE_VERIFIED', result.stdout)
        self.assertEqual((self.root/'current/.xiaoqi-release').read_text().strip(), 'new-release')
        self.assertTrue((self.root/'restore/latest-good/data.tgz').is_file())
        calls = (self.root/'docker.calls').read_text().splitlines()
        self.assertFalse(any(' build ' in ' '+c+' ' for c in calls))
        self.assertTrue(all('--no-build' in c and '--pull never' in c for c in calls if ' up ' in c))
        curated = next(c for c in calls if '/app/bin/verify_official_catalog' in c)
        self.assertIn('--network xiaoqi-single-server_default', curated)
        self.assertIn('--network xiaoqi-single-server_sandbox-control', curated)
        self.assertIn('--env SANDBOX_RUNNER_URL=http://sandbox-runner:8090', curated)

    def test_failed_probe_preserves_running_release(self):
        result = self.deploy(FAIL_PROBE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root/'current/.xiaoqi-release').read_text().strip(), 'old-release')
        self.assertFalse((self.root/'restore/next').exists())
        self.assertNotIn(' stop app', (self.root/'docker.calls').read_text())

    def test_failed_curated_probe_preserves_running_release(self):
        result = self.deploy(FAIL_CURATED_PROBE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root/'current/.xiaoqi-release').read_text().strip(), 'old-release')
        self.assertFalse((self.root/'restore/next').exists())
        self.assertNotIn(' stop app', (self.root/'docker.calls').read_text())

    def test_failed_activation_restores_source_version_and_data(self):
        result = self.deploy(FAIL_ACTIVATE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ROLLBACK_VERIFIED', result.stdout, result.stdout + result.stderr)
        self.assertEqual((self.root/'current/.xiaoqi-release').read_text().strip(), 'old-release')
        self.assertEqual((self.root/'current/genkit_server/pubspec.yaml').read_text(), 'name: old\n')
        self.assertFalse((self.root/'restore/next').exists())

    def test_low_disk_and_corrupt_bundle_stop_before_switch(self):
        result = self.deploy(FAKE_FREE_KB='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not enough disk', result.stderr)
        self.bundle.write_bytes(b'bad archive')
        result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root/'current/.xiaoqi-release').read_text().strip(), 'old-release')
        self.assertFalse((self.root/'restore/next').exists())

    def test_concurrent_deploy_is_rejected(self):
        with (self.root/'.deploy.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.deploy()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('another deployment', result.stderr)

    def test_rollback_failure_keeps_emergency_snapshot(self):
        result = self.deploy(FAIL_ALL_UP='1')
        self.assertEqual(result.returncode, 70, result.stdout + result.stderr)
        self.assertIn('ROLLBACK_FAILED', result.stderr)
        self.assertTrue((self.root/'restore/next/data.tgz').is_file())
        self.assertTrue((self.root/'restore/next/images.json').is_file())

    def test_write_hold_covers_snapshot_and_verification(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        phases = [line.split('PHASE=')[1] for line in result.stdout.splitlines() if 'PHASE=' in line]
        self.assertLess(phases.index('HOLD_WRITES'), phases.index('BACKUP_DATA'))
        self.assertLess(phases.index('VERIFY_HEALTH_AND_DATA'), phases.index('RESUME_TRAFFIC'))

    def test_complete_interrupted_snapshot_recovers_before_new_deploy(self):
        next_dir = self.root/'restore/next'
        next_dir.mkdir()
        with tarfile.open(next_dir/'source.tgz', 'w:gz') as tar:
            for path in (self.root/'current').iterdir():
                tar.add(path, arcname=path.name)
        (next_dir/'rollback-ready').touch()
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('RECOVER_INTERRUPTED_DEPLOYMENT', result.stdout)


if __name__ == '__main__':
    unittest.main()
