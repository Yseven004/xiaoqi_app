import json
import socket
import unittest

from stdio_channel import StdioChannel, MAX_MESSAGE_BYTES


class StdioChannelTests(unittest.TestCase):
    def setUp(self):
        client, self.peer = socket.socketpair()
        self.channel = StdioChannel()
        self.channel.attach(client)
        self.addCleanup(self.channel.close)
        self.addCleanup(self.peer.close)

    def frame(self, kind, payload):
        return bytes([kind, 0, 0, 0]) + len(payload).to_bytes(4, 'big') + payload

    def test_bidirectional_requests_notifications_and_stderr(self):
        outgoing = {'jsonrpc':'2.0', 'id':1, 'method':'tools/list'}
        self.channel.send(outgoing)
        self.assertEqual(json.loads(self.peer.recv(4096)), outgoing)
        response = {'jsonrpc':'2.0', 'id':1, 'result':{'tools':[]}}
        request = {'jsonrpc':'2.0', 'id':'server-1', 'method':'roots/list'}
        wire = json.dumps(response).encode() + b'\n' + json.dumps(request).encode() + b'\n'
        self.peer.sendall(self.frame(2, b'not JSON diagnostics\n') + self.frame(1, wire[:5]) + self.frame(1, wire[5:]))
        observed = []
        for _ in range(4):
            result = self.channel.poll(timeout=1)
            observed.extend(result['messages'])
            if result['closed'] or len(observed) >= 2:
                break
        self.assertEqual(observed, [response, request])
        self.assertIn('not JSON diagnostics', self.channel.diagnostic)
        self.assertIsNone(self.channel.error)

    def test_invalid_stdout_fails_connection_instead_of_becoming_tool_data(self):
        self.peer.sendall(self.frame(1, b'plugin startup banner\n'))
        self.channel._reader.join(timeout=2)
        self.assertTrue(self.channel.closed)
        self.assertIsNotNone(self.channel.error)
        self.assertEqual(self.channel.poll()['messages'], [])

    def test_partial_message_at_exit_is_reported(self):
        self.peer.sendall(self.frame(1, b'{"jsonrpc":"2.0"'))
        self.peer.shutdown(socket.SHUT_WR)
        self.channel._reader.join(timeout=2)
        self.assertIsNotNone(self.channel.error)

    def test_oversized_header_is_rejected_without_allocating_payload(self):
        self.peer.sendall(b'\x01\0\0\0' + (MAX_MESSAGE_BYTES + 1).to_bytes(4, 'big'))
        self.channel._reader.join(timeout=2)
        self.assertTrue(self.channel.closed)
        self.assertIsNotNone(self.channel.error)
