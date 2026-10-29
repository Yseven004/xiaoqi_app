"""Registry persistence with a retained, socket-backed engine fixture.

Real Docker process continuity is covered separately by verify_runner_restart.py.
"""
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest

from mcp_sessions import LeaseError, McpSessions


class DurableSessionsTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.path = str(Path(self.root.name) / 'mcp.sqlite')
        self.now = time.time()
        self.starts = 0
        self.effects = []
        self.history = b''
        self.recoveries = []
        self.registries = []
        self.request = {'lease_id': 'a' * 32, 'lease_token': 'b' * 64,
                        'task_id': 'original-task', 'issued_at': int(self.now),
                        'command': ['node', '/workspace/skill/server.js']}

    def tearDown(self):
        for registry in reversed(self.registries):
            registry.close()
        self.root.cleanup()

    @staticmethod
    def frame(payload):
        return b'\x01\0\0\0' + len(payload).to_bytes(4, 'big') + payload

    def serve(self, request, event, channel):
        client, peer = socket.socketpair()
        channel.attach(client)
        if self.history:
            peer.sendall(self.frame(self.history))
        event({'type': 'sandbox_started'})

        def echo():
            try:
                with peer, peer.makefile('rb') as reader:
                    for line in reader:
                        body = json.loads(line)
                        self.effects.append(body)
                        payload = json.dumps({'jsonrpc': '2.0', 'id': body['id'],
                                              'result': {'count': len(self.effects)}}).encode() + b'\n'
                        self.history += payload
                        peer.sendall(self.frame(payload))
            except OSError:
                pass

        thread = threading.Thread(target=echo, daemon=True)
        thread.start()
        channel._closed.wait(5)
        channel.close()
        thread.join(1)
        if channel.detached:
            return {'detached': True}
        result = {'ok': True, 'artifacts': [{'name': 'original.txt', 'base64': 'b3JpZ2luYWw='}],
                  'cleanup_pending': False}
        channel.checkpoint(result)
        return result

    def run_process(self, request, event, channel):
        self.starts += 1
        return self.serve(request, event, channel)

    def recover(self, state, event, channel):
        self.recoveries.append((state, channel.closed))
        if channel.closed:
            result = {'ok': False, 'artifacts': [{'name': 'original.txt', 'base64': 'b3JpZ2luYWw='}],
                      'cleanup_pending': False}
            channel.checkpoint(result)
            return result
        return self.serve(state, event, channel)

    def registry(self, **kwargs):
        registry = McpSessions(self.run_process, threading.BoundedSemaphore(1), db_path=self.path,
                               recover=self.recover, wall_clock=lambda: self.now, **kwargs)
        self.registries.append(registry)
        return registry

    def start(self, registry):
        lease = registry.create(self.request)
        self.assertTrue(lease.ready.wait(2))
        return lease

    def test_reopen_replays_unacknowledged_response_without_starting_or_sending_again(self):
        first = self.registry()
        lease = self.start(first)
        message = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call'}
        lease.channel.send(message, sequence=1)
        batch = lease.poll_events(0, timeout=2)
        self.assertEqual(batch['messages'][0]['result']['count'], 1)
        first.close(detach=True)
        restored = self.registry()
        restored.restore()
        original = restored.get(self.request['lease_id'], self.request['lease_token'])
        self.assertTrue(original.ready.wait(2))
        self.assertEqual(original.poll_events(0, timeout=1), batch)
        original.channel.send(message, sequence=1)
        original.channel.send({**message, 'id': 2}, sequence=2)
        next_batch = original.poll_events(batch['cursor'], timeout=2)
        self.assertEqual(next_batch['messages'][0]['result']['count'], 2)
        self.assertEqual(len(self.effects), 2)
        self.assertEqual(self.starts, 1)
        self.assertEqual(self.recoveries[0][0]['task_id'], 'original-task')
        self.assertIs(restored.create(self.request), original)
        for change in ({'task_id': 'other'}, {'command': ['sh']}, {'lease_token': 'c' * 64}):
            with self.assertRaises(LeaseError):
                restored.create({**self.request, **change})
        with self.assertRaises(LeaseError):
            restored.get(self.request['lease_id'], 'c' * 64)

    def test_original_lifetime_is_not_renewed_by_restarting_registry(self):
        first = self.registry(max_lifetime=10)
        lease = self.start(first)
        first.close(detach=True)
        self.now += 11
        restored = self.registry(max_lifetime=10)
        restored.restore()
        original = restored.get(self.request['lease_id'], self.request['lease_token'])
        self.assertTrue(original.done.wait(2))
        self.assertTrue(self.recoveries[0][1])
        self.assertTrue(original.result_ready)
        self.assertEqual(self.starts, 1)
        self.assertEqual(len(self.effects), 0)
        self.assertEqual(original.result['artifacts'][0]['name'], 'original.txt')

    def test_stopped_result_and_ack_survive_reopen_without_recovering_process(self):
        first = self.registry()
        lease = self.start(first)
        lease.stop()
        self.assertTrue(lease.done.wait(2))
        self.assertTrue(lease.result_ready)
        first.close()
        restored = self.registry()
        restored.restore()
        original = restored.get(self.request['lease_id'], self.request['lease_token'])
        self.assertTrue(original.result_ready)
        self.assertEqual(original.result['artifacts'][0]['name'], 'original.txt')
        self.assertEqual(self.recoveries, [])
        original.discard()
        restored.close()
        reopened = self.registry()
        reopened.restore()
        acknowledged = reopened.get(self.request['lease_id'], self.request['lease_token'])
        self.assertEqual(acknowledged.result.get('artifacts', []), [])
        self.assertIs(reopened.create(self.request), acknowledged)
        self.assertEqual(self.starts, 1)

    def test_cleanup_exception_preserves_already_checkpointed_original_files(self):
        def failed_cleanup(request, event, channel):
            event({'type': 'sandbox_started'})
            channel.checkpoint({'ok': True, 'artifacts': [
                {'name': 'original.txt', 'base64': 'b3JpZ2luYWw='}], 'cleanup_pending': True})
            raise OSError('cleanup unavailable')

        self.run_process = failed_cleanup
        registry = self.registry()
        lease = self.start(registry)
        self.assertTrue(lease.done.wait(2))
        self.assertEqual(lease.result['artifacts'][0]['base64'], 'b3JpZ2luYWw=')
        self.assertTrue(lease.result['cleanup_pending'])
        self.assertEqual(registry._journal.get(lease.lease_id)['result']['artifacts'], lease.result['artifacts'])
        registry.reconcile()
        self.assertFalse(lease.result['cleanup_pending'])
        self.assertEqual(lease.result['artifacts'][0]['base64'], 'b3JpZ2luYWw=')


if __name__ == '__main__':
    unittest.main()
