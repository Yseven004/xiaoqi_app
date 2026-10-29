import sqlite3
import tempfile
import time
import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import Mock, patch

import server
from execution_sessions import Executions, ExecutionError, StorageUnavailable


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

    def test_storage_failure_reports_unhealthy_and_cannot_start_new_code(self):
        with tempfile.TemporaryDirectory() as root:
            registry = Executions(db_path=str(Path(root)/'journal.sqlite'))
            request = self.request()
            entry = registry.claim(request)
            registry.finish(entry, {'execution_id': request['execution_id'], 'ok': True, 'stdout': 'durable result'})
            registry._db.execute('PRAGMA query_only=ON')
            with self.assertRaises(StorageUnavailable):
                registry.claim({**request, 'execution_id': 'e'*32})
            self.assertFalse(registry.healthy)
            with patch.object(server, '_executions', registry), patch.object(server, 'RUNNER_TOKEN', 'test-token'), patch.object(server, '_get_client', return_value=Mock()), patch.object(server, '_run_sandbox') as run:
                http = ThreadingHTTPServer(('127.0.0.1', 0), server.RunnerHandler)
                thread = threading.Thread(target=http.serve_forever, daemon=True)
                thread.start()
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                def call(path, body=None):
                    outgoing = urllib.request.Request(f'http://127.0.0.1:{http.server_port}'+path, data=None if body is None else json.dumps(body).encode(), headers={'Authorization':'Bearer test-token'})
                    return opener.open(outgoing, timeout=5)
                try:
                    with self.assertRaises(urllib.error.HTTPError) as unavailable:
                        call('/health')
                    self.assertEqual(unavailable.exception.code, 503)
                    self.assertEqual(json.load(unavailable.exception)['reason'], 'execution_journal_unavailable')
                    unavailable.exception.close()
                    with self.assertRaises(urllib.error.HTTPError) as rejected:
                        call('/v1/execute', {**request, 'execution_id':'f'*32,'code':'true','language':'shell'})
                    self.assertEqual(rejected.exception.code, 503)
                    rejected.exception.close()
                    run.assert_not_called()
                    with call('/v1/executions/'+request['execution_id']+'/result', request) as response:
                        self.assertEqual(json.load(response)['completion']['stdout'], 'durable result')
                    registry._db.execute('PRAGMA query_only=OFF')
                    with call('/v1/executions/'+request['execution_id']+'/ack', request) as response:
                        self.assertTrue(json.load(response)['acknowledged'])
                    self.assertTrue(registry.healthy)
                    with call('/health') as response:
                        self.assertEqual(json.load(response)['status'], 'ready')
                finally:
                    http.shutdown()
                    http.server_close()
                    thread.join(timeout=3)
                    registry.close()

    def test_acknowledgement_releases_files_but_retains_cleanup_across_restart(self):
        with tempfile.TemporaryDirectory() as root:
            path = str(Path(root)/'journal.sqlite')
            registry = Executions(db_path=path)
            request = self.request()
            entry = registry.claim(request)
            registry.finish(entry, {'execution_id':request['execution_id'],'ok':True,'cleanup_pending':True,'sandbox_id':'old-container','artifacts':[{'name':'big.txt','base64':'a'*65536}]})
            self.assertTrue(registry.acknowledge(request)['cleanup_pending'])
            self.assertLess(entry.payload_bytes, 1024)
            self.assertEqual(registry.read(request)['completion']['artifacts'], [])
            registry.close()
            restored = Executions(db_path=path)
            container = Mock()
            removed = False
            attempts = 0
            def remove(**kwargs):
                nonlocal removed, attempts
                attempts += 1
                if attempts == 1:
                    raise server.DockerException('busy')
                removed = True
            container.remove.side_effect = remove
            client = Mock()
            client.containers.list.side_effect = lambda **kwargs: [] if removed else [container]
            client.networks.list.return_value = []
            client.volumes.list.return_value = []
            try:
                with patch.object(server, '_executions', restored):
                    server._reconcile_restarted_cleanup(client)
                    self.assertTrue(restored.read(request)['cleanup_pending'])
                    server._reconcile_restarted_cleanup(client)
                self.assertFalse(restored.read(request)['cleanup_pending'])
                self.assertIsNone(restored.read(request)['completion'])
                self.assertEqual(restored.pending_cleanup(), [])
                for call in client.containers.list.call_args_list:
                    self.assertIn('com.xiaoqi.execution-id='+request['execution_id'], call.kwargs['filters']['label'])
            finally:
                restored.close()
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

    def test_restart_preserves_hook_protocol_and_normal_output_limit(self):
        protocol = json.dumps({'xiaoqi_hook_command_v1': {
            'stdout': '\x00' * 120000, 'exit_code': 2}})
        for profile in ('code', 'plugin_hook', 'plugin_hook_read_only'):
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as root:
                registry = Executions(db_path=str(Path(root) / 'journal.sqlite'))
                request = self.request()
                registry.claim(request)
                container = Mock()
                container.id = 'recover-protocol'
                container.labels = {'com.xiaoqi.execution-profile': profile}
                container.attrs = {'State': {'Running': False}}
                client = Mock()
                client.containers.list.return_value = [container]
                try:
                    with (patch.object(server, '_executions', registry),
                          patch.object(server, '_safe_artifacts', return_value=[{'name': 'ephemeral.txt'}]) as export,
                          patch.object(server, '_decode_logs', return_value=protocol)):
                        server._recover_interrupted_executions(client)
                    stdout = registry.read(request)['completion']['stdout']
                    self.assertEqual(stdout, protocol if profile != 'code' else protocol[-40000:])
                    if profile != 'code':
                        self.assertEqual(json.loads(stdout)['xiaoqi_hook_command_v1']['exit_code'], 2)
                    if profile == 'plugin_hook_read_only':
                        export.assert_not_called()
                        self.assertEqual(registry.read(request)['completion']['artifacts'], [])
                finally:
                    registry.close()

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
