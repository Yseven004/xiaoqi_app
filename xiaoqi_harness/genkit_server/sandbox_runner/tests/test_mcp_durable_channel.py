import hashlib
import json
from pathlib import Path
import socket
import tempfile
import time
import unittest

from mcp_journal import McpJournal
from stdio_channel import StdioChannel


class DurableChannelTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.path = str(Path(self.root.name) / 'mcp.sqlite')
        self.journal = McpJournal(self.path)
        self.lease = 'a' * 32
        self.journal.create(self.lease, task_id='tenant-task', token_hash='b' * 64,
                            fingerprint='c' * 64, issued_at=int(time.time()), now=time.time())
        self.channels = []
        self.peers = []

    def tearDown(self):
        for channel in self.channels:
            channel.close()
        for peer in self.peers:
            peer.close()
        self.journal.close()
        self.root.cleanup()

    def channel(self):
        client, peer = socket.socketpair()
        peer.settimeout(0.1)
        channel = StdioChannel(self.journal, self.lease)
        channel.attach(client)
        self.channels.append(channel)
        self.peers.append(peer)
        return channel, peer

    @staticmethod
    def wire(message):
        return json.dumps(message, ensure_ascii=False).encode('utf-8') + b'\n'

    @staticmethod
    def frame(payload):
        return b'\x01\0\0\0' + len(payload).to_bytes(4, 'big') + payload

    def test_original_stdout_and_lost_batch_resume_without_resending_request(self):
        original, peer = self.channel()
        request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call'}
        response = {'jsonrpc': '2.0', 'id': 1, 'result': {'text': '原结果🙂'}}
        original.send(request, sequence=1)
        self.assertEqual(json.loads(peer.recv(4096)), request)
        first_wire = self.wire(response)
        peer.sendall(self.frame(first_wire))
        lost_batch = self.journal.poll(self.lease, 0, timeout=1)
        self.assertEqual(lost_batch['messages'], [response])
        original.detach()
        self.journal.close()
        self.journal = McpJournal(self.path)
        resumed, resumed_peer = self.channel()
        # Docker attach(logs=True) replays the exact original bytes, including
        # chunk splits through a multi-byte character. Only the unseen tail is new.
        split = first_wire.index('原'.encode('utf-8')) + 1
        resumed_peer.sendall(self.frame(first_wire[:split]) + self.frame(first_wire[split:]))
        resumed.send(request, sequence=1)
        with self.assertRaises(TimeoutError):
            resumed_peer.recv(4096)
        self.assertEqual(self.journal.poll(self.lease, 0, timeout=1), lost_batch)
        next_request = {**request, 'id': 2}
        resumed.send(next_request, sequence=2)
        self.assertEqual(json.loads(resumed_peer.recv(4096)), next_request)
        next_response = {'jsonrpc': '2.0', 'id': 2, 'result': {'text': '下一步'}}
        next_wire = self.wire(next_response)
        resumed_peer.sendall(self.frame(next_wire))
        batch = self.journal.poll(self.lease, lost_batch['cursor'], timeout=1)
        self.assertEqual(batch['messages'], [next_response])
        self.assertEqual(self.journal.get(self.lease)['stdout_offset'], len(first_wire + next_wire))
        self.assertEqual(self.journal.get(self.lease)['stdout_hash'], hashlib.sha256(first_wire + next_wire).hexdigest())

    def test_changed_original_stdout_cannot_become_a_new_session(self):
        response = {'jsonrpc': '2.0', 'id': 1, 'result': {}}
        wire = self.wire(response)
        self.journal.receive(self.lease, response, len(wire), hashlib.sha256(wire).hexdigest())
        resumed, peer = self.channel()
        changed = self.wire({**response, 'id': 9})
        self.assertEqual(len(changed), len(wire))
        peer.sendall(self.frame(changed))
        resumed._reader.join(timeout=2)
        self.assertTrue(resumed.closed)
        self.assertIsNotNone(resumed.error)
        with self.assertRaises(RuntimeError):
            resumed.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call'}, sequence=1)
        self.assertEqual(self.journal.get(self.lease)['stdout_offset'], len(wire))
        self.assertEqual(self.journal.get(self.lease)['stdout_hash'], hashlib.sha256(wire).hexdigest())

    def test_truncated_original_stdout_cannot_authorize_a_new_send(self):
        response = {'jsonrpc': '2.0', 'id': 1, 'result': {}}
        wire = self.wire(response)
        self.journal.receive(self.lease, response, len(wire), hashlib.sha256(wire).hexdigest())
        resumed, peer = self.channel()
        peer.sendall(self.frame(wire[:-1]))
        peer.shutdown(socket.SHUT_WR)
        resumed._reader.join(timeout=2)
        self.assertTrue(resumed.closed)
        self.assertIsNotNone(resumed.error)
        with self.assertRaises(RuntimeError):
            resumed.send({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call'}, sequence=1)
        self.assertEqual(self.journal.get(self.lease)['send_sequence'], 0)


if __name__ == '__main__':
    unittest.main()
