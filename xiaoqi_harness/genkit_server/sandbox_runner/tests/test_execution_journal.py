import sqlite3
import tempfile
import time
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import Mock, patch

import server
from execution_sessions import Executions, ExecutionError


class JournalTests(unittest.TestCase):
    def request(self):
        return {'task_id': 'journal-task', 'execution_id': 'd' * 32, 'issued_at': int(time.time() * 1000)}

    def test_terminal_results_and_acknowledgements_survive_reopening(self):
        with tempfile.TemporaryDirectory() as root:
            path = str(Path(root) / 'journal.sqlite')
            registry = Executions(db_path=path)
            request = self.request()
            entry = registry.claim(request)
            result = {'ok': True, 'execution_id': request['execution_id'], 'artifacts': [{'name': 'report.txt', 'base64': 'c2F2ZWQ='}]}
            registry.finish(entry, result)
            registry.close()
            registry = Executions(db_path=path)
            try:
                self.assertEqual(registry.read(request)['completion'], result)
                with self.assertRaises(ExecutionError):
                    registry.claim(request)
                registry.acknowledge(request)
            finally:
                registry.close()
            registry = Executions(db_path=path)
            try:
                self.assertIsNone(registry.read(request)['completion'])
                with self.assertRaises(ExecutionError):
                    registry.claim(request)
            finally:
                registry.close()

    def test_checkpoint_preserves_files_after_workspace_was_already_removed(self):
        with tempfile.TemporaryDirectory() as root:
            path = str(Path(root) / 'journal.sqlite')
            registry = Executions(db_path=path)
            request = self.request()
            entry = registry.claim(request)
            result = {'type': 'result', 'ok': True, 'execution_id': request['execution_id'], 'stdout': 'done', 'artifacts': [{'name': 'saved.txt'}], 'cleanup_pending': True}
            registry.checkpoint(entry, result)
            registry.close()
            restored = Executions(db_path=path)
            client = Mock()
            client.containers.list.return_value = []
            client.networks.list.return_value = []
            client.volumes.list.return_value = []
            try:
                with patch.object(server, '_executions', restored):
                    server._recover_interrupted_executions(client)
                    server._reconcile_restarted_cleanup(client)
                completion = restored.read(request)['completion']
                self.assertTrue(completion['ok'])
                self.assertEqual(completion['artifacts'], result['artifacts'])
                self.assertFalse(completion['cleanup_pending'])
                self.assertEqual(restored.interrupted(), [])
            finally:
                restored.close()

    def test_restart_exports_owned_workspace_before_removing_it(self):
        with tempfile.TemporaryDirectory() as root:
            path = str(Path(root) / 'journal.sqlite')
            registry = Executions(db_path=path)
            request = self.request()
            registry.claim(request)
            registry.close()
            restored = Executions(db_path=path)
            container = Mock()
            container.id = 'container-to-recover'
            container.labels = {}
            container.attrs = {'State': {'Running': True}}
            removed = False
            def remove(**kwargs):
                nonlocal removed
                completion = restored.read(request)['completion']
                self.assertEqual(completion['artifacts'], [{'name': 'partial.txt'}])
                removed = True
            container.remove.side_effect = remove
            client = Mock()
            client.containers.list.side_effect = lambda **kwargs: [] if removed else [container]
            client.networks.list.return_value = []
            client.volumes.list.return_value = []
            try:
                with patch.object(server, '_executions', restored), patch.object(server, '_safe_artifacts', return_value=[{'name': 'partial.txt'}]), patch.object(server, '_decode_logs', return_value='partial log'):
                    server._recover_interrupted_executions(client)
                    server._remove_stale_resources(client)
                    server._reconcile_restarted_cleanup(client)
                completion = restored.read(request)['completion']
                self.assertFalse(completion['ok'])
                self.assertFalse(completion['cleanup_pending'])
                self.assertIn('do not automatically replay', completion['error'])
                container.kill.assert_called_once()
                self.assertEqual(client.containers.list.call_args_list[0].kwargs['filters']['label'], [f'{server.OWNER_LABEL}=true', 'com.xiaoqi.execution-id=' + request['execution_id'], 'com.xiaoqi.task-id=journal-task'])
            finally:
                restored.close()

    def test_failed_checkpoint_stops_process_but_retains_workspace(self):
        client = Mock()
        volume = Mock()
        volume.name = 'xq-code-volume'
        client.volumes.create.return_value = volume
        container = Mock()
        container.put_archive.return_value = True
        container.attrs = {'State': {'Status': 'exited', 'ExitCode': 0, 'Running': False}}
        client.containers.create.return_value = container
        with patch.object(server, '_get_client', return_value=client), patch.object(server, '_decode_logs', return_value=''), patch.object(server, '_safe_artifacts', return_value=[]):
            with self.assertRaises(OSError):
                server._run_sandbox({**self.request(), 'code': 'true', 'language': 'shell'}, Mock(), checkpoint=Mock(side_effect=OSError('disk full')))
        container.kill.assert_called_once()
        container.remove.assert_not_called()
        volume.remove.assert_not_called()

    def test_failed_acknowledgement_does_not_erase_original_result(self):
        registry = Executions()
        request = self.request()
        entry = registry.claim(request)
        registry.finish(entry, {'ok': True, 'stdout': 'keep me'})
        with patch.object(registry, '_persist', side_effect=sqlite3.OperationalError('disk full')):
            with self.assertRaises(sqlite3.OperationalError):
                registry.acknowledge(request)
        self.assertEqual(registry.read(request)['completion']['stdout'], 'keep me')

    def test_unsupported_journal_version_is_rejected_without_reset(self):
        with tempfile.TemporaryDirectory() as root:
            path = str(Path(root) / 'journal.sqlite')
            registry = Executions(db_path=path)
            registry.close()
            with closing(sqlite3.connect(path)) as db:
                db.execute('PRAGMA user_version=999')
            with self.assertRaises(ExecutionError):
                Executions(db_path=path)
            with closing(sqlite3.connect(path)) as db:
                self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 999)
