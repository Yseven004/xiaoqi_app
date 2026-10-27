from __future__ import annotations

import json
import threading
import time
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from unittest.mock import Mock, patch

import server
from execution_sessions import Executions, ExecutionError


class ExecutionTests(unittest.TestCase):
    def request(self, identifier='a'):
        return {'task_id': 'task-one', 'execution_id': identifier * 32, 'issued_at': int(time.time() * 1000)}

    def test_cancel_before_submission_is_not_lost_and_replay_is_rejected(self):
        registry = Executions()
        request = self.request()
        registry.cancel(request)
        entry = registry.claim(request)
        self.assertTrue(entry.cancelled.is_set())
        registry.finish(entry)
        with self.assertRaises(ExecutionError):
            registry.claim(request)
        self.assertTrue(registry.cancel(request)['finished'])

    def test_cancellation_cannot_target_another_task_or_newer_execution(self):
        registry = Executions()
        request = self.request()
        entry = registry.claim(request)
        other = registry.claim(self.request('b'))
        with self.assertRaises(ExecutionError):
            registry.cancel({**request, 'task_id': 'other-task'})
        with self.assertRaises(ExecutionError):
            registry.cancel({**request, 'issued_at': request['issued_at'] + 1})
        registry.cancel(request)
        self.assertTrue(entry.cancelled.is_set())
        self.assertFalse(other.cancelled.is_set())

    def test_stale_pre_restart_requests_and_capacity_are_rejected(self):
        registry = Executions(capacity=1)
        with self.assertRaises(ExecutionError):
            registry.claim({**self.request(), 'issued_at': registry._started_at - 1})
        registry.claim(self.request())
        with self.assertRaises(ExecutionError):
            registry.cancel(self.request('b'))

    def test_expired_tombstone_pruning_cannot_allow_replay(self):
        registry = Executions(capacity=1)
        old = self.request()
        registry.cancel(old)
        future = old['issued_at'] + 151000
        with patch('execution_sessions.time.time', return_value=future / 1000):
            registry.claim({**self.request('b'), 'issued_at': future})
            with self.assertRaises(ExecutionError):
                registry.claim(old)

    def test_active_cancellation_keeps_result_stream_and_partial_files(self):
        self._http_cancel(queued=False)

    def test_unacknowledged_result_survives_expiry_and_ack_prevents_replay(self):
        registry = Executions(capacity=1)
        request = self.request()
        entry = registry.claim(request)
        result = {'ok': True, 'artifacts': [{'name': 'result.txt', 'base64': 'b2s='}]}
        registry.finish(entry, result)
        with patch('execution_sessions.time.time', return_value=(request['issued_at'] + 200000) / 1000):
            self.assertEqual(registry.read(request)['completion'], result)
            with self.assertRaises(ExecutionError):
                registry.claim({**self.request('b'), 'issued_at': request['issued_at'] + 200000})
            with self.assertRaises(ExecutionError):
                registry.acknowledge({**request, 'task_id': 'foreign'})
            registry.acknowledge(request)
            self.assertIsNone(registry.read(request)['completion'])
            registry.claim({**self.request('b'), 'issued_at': request['issued_at'] + 200000})
            with self.assertRaises(ExecutionError):
                registry.claim(request)

    def test_unacknowledged_payload_applies_backpressure_until_ack(self):
        registry = Executions()
        request = self.request()
        entry = registry.claim(request)
        with self.assertRaises(ExecutionError):
            registry.acknowledge(request)
        registry.finish(entry, {'ok': True})
        entry.payload_bytes = 32 * 1024 * 1024 + 1
        with self.assertRaises(ExecutionError):
            registry.claim(self.request('b'))
        registry.acknowledge(request)
        registry.claim(self.request('b'))

    def test_disconnected_execution_can_be_read_and_acknowledged_without_replay(self):
        registry = Executions()
        release = threading.Event()
        partial = [{'name': 'recovered.txt', 'base64': 'cmVjb3ZlcmVk'}]
        def run(request, send, *, cancellation, checkpoint=None):
            send({'type': 'sandbox_started', 'sandbox_id': 'disconnect-test'})
            self.assertTrue(release.wait(3))
            send({'type': 'heartbeat'})
            send({'type': 'heartbeat'})
            return {'type': 'result', 'ok': True, 'artifacts': partial, 'cleanup_pending': False}
        with patch.object(server, 'RUNNER_TOKEN', 'test-token'), patch.object(server, '_executions', registry), patch.object(server, '_slots', threading.BoundedSemaphore(1)), patch.object(server, '_run_sandbox', side_effect=run) as runner:
            http = ThreadingHTTPServer(('127.0.0.1', 0), server.RunnerHandler)
            thread = threading.Thread(target=http.serve_forever, daemon=True)
            thread.start()
            request = self.request()
            def post(path):
                outgoing = urllib.request.Request(f'http://127.0.0.1:{http.server_port}' + path, data=json.dumps(request).encode(), headers={'Authorization': 'Bearer test-token'})
                return urllib.request.build_opener(urllib.request.ProxyHandler({})).open(outgoing, timeout=5)
            try:
                response = post('/v1/execute')
                self.assertEqual(json.loads(response.readline())['type'], 'sandbox_started')
                response.close()
                release.set()
                deadline = time.monotonic() + 3
                while not registry.read(request)['finished'] and time.monotonic() < deadline:
                    time.sleep(0.01)
                path = f"/v1/executions/{request['execution_id']}"
                with post(path + '/result') as response:
                    completed = json.load(response)
                self.assertTrue(completed['finished'])
                self.assertEqual(completed['completion']['artifacts'], partial)
                with post(path + '/ack') as response:
                    self.assertTrue(json.load(response)['acknowledged'])
                with post(path + '/result') as response:
                    self.assertIsNone(json.load(response)['completion'])
                runner.assert_called_once()
            finally:
                release.set()
                http.shutdown()
                http.server_close()
                thread.join(timeout=3)

    def test_queued_cancellation_never_starts_a_sandbox(self):
        self._http_cancel(queued=True)

    def _http_cancel(self, queued):
        registry = Executions()
        slots = threading.BoundedSemaphore(1)
        if queued:
            slots.acquire()
        started = threading.Event()
        partial = [{'name': 'partial.txt', 'base64': 'cGFydGlhbA=='}]
        def run(request, send, *, cancellation, checkpoint=None):
            started.set()
            send({'type': 'sandbox_started', 'sandbox_id': 'sandbox-test'})
            self.assertTrue(cancellation.wait(3))
            return {'type': 'result', 'ok': False, 'error': 'cancelled', 'artifacts': partial, 'cleanup_pending': False}
        with patch.object(server, 'RUNNER_TOKEN', 'test-token'), patch.object(server, '_executions', registry), patch.object(server, '_slots', slots), patch.object(server, '_run_sandbox', side_effect=run) as runner:
            http = ThreadingHTTPServer(('127.0.0.1', 0), server.RunnerHandler)
            thread = threading.Thread(target=http.serve_forever, daemon=True)
            thread.start()
            base = f'http://127.0.0.1:{http.server_port}'
            request = self.request()
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            def post(path, body, token='test-token'):
                outgoing = urllib.request.Request(base + path, data=json.dumps(body).encode(), headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
                return opener.open(outgoing, timeout=5).read().decode()
            try:
                with ThreadPoolExecutor(max_workers=1) as pool:
                    result = pool.submit(post, '/v1/execute', request)
                    if not queued:
                        self.assertTrue(started.wait(3))
                    # Also exercises cancellation that wins the registration race.
                    path = f"/v1/executions/{request['execution_id']}/cancel"
                    with self.assertRaises(urllib.error.HTTPError) as unauthorized:
                        post(path, request, token='wrong-token')
                    self.assertEqual(unauthorized.exception.code, 401)
                    unauthorized.exception.close()
                    self.assertTrue(json.loads(post(path, request))['ok'])
                    events = [json.loads(line) for line in result.result(timeout=5).splitlines() if line]
                    final = events[-1]
                    self.assertFalse(final['ok'])
                    self.assertFalse(final['cleanup_pending'])
                    self.assertEqual(final['artifacts'], [] if queued else partial)
                    if queued:
                        runner.assert_not_called()
                    else:
                        runner.assert_called_once()
                    with self.assertRaises(urllib.error.HTTPError) as duplicate:
                        post('/v1/execute', request)
                    self.assertEqual(duplicate.exception.code, 409)
                    duplicate.exception.close()
            finally:
                http.shutdown()
                http.server_close()
                thread.join(timeout=3)
                if queued:
                    slots.release()

    def test_running_container_is_killed_before_partial_files_export(self):
        client = Mock()
        volume = Mock(name='volume')
        volume.name = 'xq-code-volume'
        client.volumes.create.return_value = volume
        container = Mock()
        container.put_archive.return_value = True
        container.attrs = {'State': {'Status': 'running', 'Running': True}}
        client.containers.create.return_value = container
        cancellation = threading.Event()
        def send(event):
            if event['type'] == 'sandbox_started':
                cancellation.set()
        def export(actual):
            self.assertIs(actual, container)
            container.kill.assert_called_once()
            return [{'name': 'partial.txt'}]
        with patch.object(server, '_get_client', return_value=client), patch.object(server, '_decode_logs', return_value=''), patch.object(server, '_safe_artifacts', side_effect=export):
            result = server._run_sandbox({'task_id': 'cancel-test', 'language': 'shell', 'code': 'sleep 60'}, send, cancellation=cancellation)
        self.assertFalse(result['ok'])
        self.assertEqual(result['artifacts'], [{'name': 'partial.txt'}])
        self.assertFalse(result['cleanup_pending'])
        volume.remove.assert_called_once_with(force=True)

    def test_preparation_failure_does_not_claim_failed_cleanup_succeeded(self):
        client = Mock()
        volume = Mock()
        volume.name = 'xq-code-volume'
        volume.remove.side_effect = server.DockerException('volume busy')
        client.volumes.create.return_value = volume
        container = Mock()
        container.put_archive.return_value = False
        container.attrs = {'State': {'Running': False}}
        client.containers.create.return_value = container
        with patch.object(server, '_get_client', return_value=client):
            result = server._run_sandbox({'task_id': 'failed-prepare', 'language': 'shell', 'code': 'true'}, Mock())
        self.assertFalse(result['ok'])
        self.assertTrue(result['cleanup_pending'])
        container.start.assert_not_called()
