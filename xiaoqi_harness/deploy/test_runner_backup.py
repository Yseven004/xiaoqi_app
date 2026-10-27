"""Run the actual backup functions with local mount adapters, no Docker needed."""
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path


ADAPTER = r'''#!/usr/bin/env python3
import os, pathlib, re, shlex, subprocess, sys
args = sys.argv[1:]
mounts = [args[i+1] for i, item in enumerate(args) if item == '-v']
command = args[args.index('-c')+1]
if os.environ.get('FAIL_DATA_BACKUP') == '1' and '/backup/data.tgz' in command and 'tar -czf' in command:
    sys.exit(7)
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
for mount in mounts:
    source, target, *_ = mount.split(':')
    if source in ('app-test', 'runner-test'):
        source = str(root/source)
    command = re.sub(re.escape(target) + r'(?=/|\s|;|$)', lambda _: shlex.quote(source), command)
sys.exit(subprocess.run(['/bin/sh', '-c', command]).returncode)
'''


@unittest.skipUnless(sys.platform.startswith('linux'), 'Requires Linux tar and shell')
class RunnerBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='xiaoqi-backup-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('app-test', 'runner-test', 'backup', 'bin'):
            (self.root/name).mkdir()
        (self.root/'app-test'/'user.txt').write_text('before')
        self.db = self.root/'runner-test'/'executions.sqlite3'
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('CREATE TABLE result(value TEXT)')
            db.execute("INSERT INTO result VALUES ('before')")
            db.commit()
        fake = self.root/'bin'/'docker'
        fake.write_text(ADAPTER)
        fake.chmod(0o700)
        source = (Path(__file__).parent/'release_manager.sh').read_text()
        self.functions = '\n'.join(re.search(r'(?ms)^' + name + r'\(\) \{.*?^\}', source).group(0) for name in ('backup_data', 'restore_data'))

    def run_function(self, name, **extra):
        env = {**os.environ, 'PATH': str(self.root/'bin') + os.pathsep + os.environ['PATH'], 'FIXTURE_ROOT': str(self.root), 'OUTPUT': str(self.root/'backup'), **extra}
        return subprocess.run(['bash', '-c', self.functions + '\nVOLUME=app-test\nRUNNER_VOLUME=runner-test\n' + name + ' "$OUTPUT"'], env=env, capture_output=True, text=True)

    def test_rollback_restores_app_data_but_does_not_rewind_execution_knowledge(self):
        result = self.run_function('backup_data')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root/'backup'/'runner-data.tgz').exists())
        (self.root/'app-test'/'user.txt').write_text('after')
        with closing(sqlite3.connect(self.db)) as db:
            db.execute("UPDATE result SET value='already-executed'")
            db.commit()
        result = self.run_function('restore_data')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root/'app-test'/'user.txt').read_text(), 'before')
        with closing(sqlite3.connect(self.db)) as db:
            self.assertEqual(db.execute('SELECT value FROM result').fetchone()[0], 'already-executed')

    def test_missing_execution_journal_is_restored_from_the_single_snapshot(self):
        self.assertEqual(self.run_function('backup_data').returncode, 0)
        self.db.unlink()
        Path(str(self.db) + '-wal').write_bytes(b'stale WAL')
        Path(str(self.db) + '-shm').write_bytes(b'stale SHM')
        result = self.run_function('restore_data')
        self.assertEqual(result.returncode, 0, result.stderr)
        with closing(sqlite3.connect(self.db)) as db:
            self.assertEqual(db.execute('SELECT value FROM result').fetchone()[0], 'before')

    def test_app_backup_failure_cannot_be_hidden_by_successful_runner_backup(self):
        result = self.run_function('backup_data', FAIL_DATA_BACKUP='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root/'backup'/'runner-data.tgz').exists())
