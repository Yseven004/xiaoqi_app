from types import SimpleNamespace
import hashlib
import json
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock

from mcp_journal import McpJournal, McpJournalError
from mcp_recovery import resume_mcp
from stdio_channel import StdioChannel


class McpRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.owner = 'com.xiaoqi.ci-stdio-sandbox'
        self.state = {'lease_id': 'a' * 32, 'task_id': 'tenant-task', 'fingerprint': 'c' * 64,
                      'workspace_prepared': True, 'resources': {'container': 'd' * 64}}
        self.labels = {self.owner: 'true', 'com.xiaoqi.mcp-lease': 'a' * 32,
                       'com.xiaoqi.task-id': 'tenant-task', 'com.xiaoqi.mcp-fingerprint': 'c' * 64}
        self.container = Mock()
        self.container.id = 'd' * 64
        self.container.attrs = {'Config': {'Labels': {**self.labels, 'com.xiaoqi.role': 'mcp-server'}}, 'State': {'Status': 'running'}}
        self.volume = Mock()
        self.volume.name = 'original-volume'
        self.volume.attrs = {'Labels': dict(self.labels)}
        self.client = Mock()
        self.client.containers.list.return_value = [self.container]
        self.client.networks.list.return_value = []
        self.client.volumes.list.return_value = [self.volume]
        self.order = []
        def kill():
            self.order.append('kill')
            self.container.attrs['State']['Status'] = 'exited'
        self.container.kill.side_effect = kill
        self.container.remove.side_effect = lambda **_: self.order.append('remove-container')
        self.volume.remove.side_effect = lambda **_: self.order.append('remove-volume')
        self.files = [{'name': 'saved.txt', 'base64': 'aGVsbG8='}]
        def read(container):
            self.order.append('export')
            return self.files
        self.read = Mock(side_effect=read)
        self.channel = SimpleNamespace(closed=True, detached=False, preserve_recovery=False, error=None,
            checkpoint=Mock(side_effect=lambda _: self.order.append('checkpoint')))

    def recover(self):
        return resume_mcp(self.client, self.state, Mock(), self.channel, owner=self.owner,
                          sandbox_image='fixture-image', read_artifacts=self.read)

    def test_stop_exports_original_files_and_commits_before_resource_cleanup(self):
        result = self.recover()
        self.assertEqual(result['artifacts'], self.files)
        self.assertFalse(result['cleanup_pending'])
        self.assertEqual(self.order, ['kill', 'export', 'checkpoint', 'remove-container', 'remove-volume'])
        self.client.containers.create.assert_not_called()
        self.container.attach_socket.assert_not_called()

    def test_failed_result_storage_retains_exact_workspaces_without_replay(self):
        self.channel.checkpoint.side_effect = McpJournalError('disk unavailable')
        with self.assertRaises(McpJournalError):
            self.recover()
        self.assertTrue(self.channel.preserve_recovery)
        self.container.remove.assert_not_called()
        self.volume.remove.assert_not_called()
        self.client.containers.create.assert_not_called()

    def test_foreign_binding_is_not_attached_stopped_or_removed(self):
        self.container.attrs['Config']['Labels']['com.xiaoqi.task-id'] = 'other-task'
        with self.assertRaises(RuntimeError):
            self.recover()
        self.container.kill.assert_not_called()
        self.container.remove.assert_not_called()
        self.volume.remove.assert_not_called()
        self.read.assert_not_called()

    def test_replaced_original_server_is_frozen_but_not_replayed_or_misreported(self):
        self.state['resources']['container'] = 'e' * 64
        with self.assertRaises(RuntimeError):
            self.recover()
        self.container.kill.assert_called_once()
        self.container.remove.assert_not_called()
        self.volume.remove.assert_not_called()
        self.client.containers.create.assert_not_called()
        self.read.assert_not_called()

    def test_missing_server_reads_only_the_original_volume_with_a_fixed_noop(self):
        self.client.containers.list.return_value = []
        helper = self.client.containers.create.return_value
        helper.id = 'e' * 64
        result = self.recover()
        args = self.client.containers.create.call_args.kwargs
        self.assertEqual(args['command'], ['/bin/true'])
        self.assertEqual(args['network'], 'none')
        self.assertTrue(args['read_only'])
        self.assertEqual(args['user'], '10001:10001')
        self.assertEqual(args['cap_drop'], ['ALL'])
        self.assertEqual(args['volumes'], {'original-volume': {'bind': '/workspace', 'mode': 'ro'}})
        self.assertNotIn('environment', args)
        self.read.assert_called_once_with(helper)
        self.assertEqual(result['artifacts'], self.files)
        self.assertFalse(result['ok'])

    def test_frontend_detach_does_not_stop_or_export_the_original_process(self):
        self.channel.detached = True
        self.assertEqual(self.recover(), {'detached': True})
        self.client.containers.list.assert_not_called()
        self.container.kill.assert_not_called()
        self.container.remove.assert_not_called()
        self.read.assert_not_called()

    def test_running_original_reattaches_verified_history_and_accepts_the_next_request(self):
        with tempfile.TemporaryDirectory() as root:
            journal = McpJournal(root + '/mcp.sqlite')
            lease_id = self.state['lease_id']
            journal.create(lease_id, task_id=self.state['task_id'], token_hash='b' * 64,
                           fingerprint=self.state['fingerprint'], issued_at=int(time.time()), now=time.time())
            prior = {'jsonrpc': '2.0', 'id': 1, 'result': {}}
            wire = json.dumps(prior).encode() + b'\n'
            journal.receive(lease_id, prior, len(wire), hashlib.sha256(wire).hexdigest())
            batch = journal.poll(lease_id, 0, timeout=0)
            channel = StdioChannel(journal, lease_id)
            channel.checkpoint = lambda result: journal.patch(lease_id, phase='finishing', result=result)
            client, peer = socket.socketpair()
            peer.settimeout(2)
            attached = SimpleNamespace(_sock=client, close=client.close)
            self.container.attach_socket.return_value = attached
            results = []
            thread = threading.Thread(target=lambda: results.append(resume_mcp(
                self.client, self.state, Mock(), channel, owner=self.owner,
                sandbox_image='fixture-image', read_artifacts=self.read)), daemon=True)
            thread.start()
            try:
                peer.sendall(b'\x01\0\0\0' + len(wire).to_bytes(4, 'big') + wire)
                self.assertTrue(channel._replay_verified.wait(2))
                request = {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}
                channel.send(request, sequence=1)
                self.assertEqual(json.loads(peer.recv(4096)), request)
                reply = {'jsonrpc': '2.0', 'id': 2, 'result': {'tools': []}}
                payload = json.dumps(reply).encode() + b'\n'
                peer.sendall(b'\x01\0\0\0' + len(payload).to_bytes(4, 'big') + payload)
                self.assertEqual(journal.poll(lease_id, batch['cursor'], timeout=2)['messages'], [reply])
                self.container.start.assert_not_called()
                self.container.kill.assert_not_called()
            finally:
                channel.close()
                thread.join(3)
                peer.close()
                journal.close()
            self.assertFalse(thread.is_alive())
            self.assertEqual(results[0]['artifacts'], self.files)
            self.container.attach_socket.assert_called_once_with(params={
                'stdin': True, 'stdout': True, 'stderr': True, 'stream': True, 'logs': True})


if __name__ == '__main__':
    unittest.main()
