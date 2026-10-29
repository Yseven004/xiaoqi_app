"""Real docker-py HTTP upgrade, without a Docker daemon or modeled byte stream."""
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import tempfile
import threading
import time
import unittest

import docker
from mcp_journal import McpJournal
from stdio_channel import StdioChannel, DockerAttachStream


class DockerAttachBufferTests(unittest.TestCase):
    def test_prefetched_original_stdout_is_verified_and_live_stdin_still_works(self):
        prior = {'jsonrpc': '2.0', 'id': 1, 'result': {'text': 'original'}}
        reply = {'jsonrpc': '2.0', 'id': 2, 'result': {'text': 'original pending result'}}
        def wire(value):
            return json.dumps(value).encode() + b'\n'
        def frame(data):
            return b'\x01\0\0\0' + len(data).to_bytes(4, 'big') + data
        old_wire = wire(prior)
        data = frame(old_wire) + frame(wire(reply))
        received = []
        ready = threading.Event()
        release = threading.Event()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def do_POST(self):
                self.connection.sendall(b'HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\n'
                                        b'Upgrade: tcp\r\n\r\n' + data)
                ready.set()
                self.connection.settimeout(3)
                try:
                    received.append(json.loads(self.connection.recv(4096)))
                except (OSError, ValueError):
                    pass
                release.wait(3)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client = docker.APIClient(base_url=f'http://127.0.0.1:{server.server_port}', version='1.45')
        attached = None
        channel = None
        with tempfile.TemporaryDirectory() as root:
            journal = McpJournal(root + '/mcp.sqlite')
            lease = 'a' * 32
            journal.create(lease, task_id='task', token_hash='b' * 64, fingerprint='c' * 64,
                           issued_at=int(time.time()), now=time.time())
            journal.receive(lease, prior, len(old_wire), hashlib.sha256(old_wire).hexdigest())
            original = journal.poll(lease, 0, timeout=0)
            try:
                attached = client.attach_socket('original', params={
                    'stdin': True, 'stdout': True, 'stderr': True, 'stream': True, 'logs': True})
                self.assertTrue(ready.wait(1))
                attached._sock.settimeout(.1)
                # The old path sees nothing even though HTTP already read all
                # original frames into its buffered reader during the upgrade.
                with self.assertRaises(TimeoutError):
                    attached._sock.recv(8)
                attached._sock.settimeout(None)
                channel = StdioChannel(journal, lease)
                channel.attach(DockerAttachStream(attached))
                self.assertTrue(channel._replay_verified.wait(1))
                self.assertEqual(journal.poll(lease, original['cursor'], timeout=1)['messages'], [reply])
                request = {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'}
                channel.send(request, sequence=1)
                deadline = time.monotonic() + 1
                while not received and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertEqual(received, [request])
                self.assertIsNone(channel.error)
                self.assertEqual(journal.get(lease)['stdout_hash'],
                                 hashlib.sha256(old_wire + wire(reply)).hexdigest())
            finally:
                release.set()
                if channel is not None:
                    channel.close()
                elif attached is not None:
                    attached._response.close()
                client.close()
                server.shutdown()
                server.server_close()
                thread.join(2)
                journal.close()


if __name__ == '__main__':
    unittest.main()
