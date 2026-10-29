"""Retained engine fixture for real SDK/HTTP/durable-registry restart tests.

No Docker or plugin process runs here; CI separately verifies real Docker.
"""
import json
from pathlib import Path
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'sandbox_runner'))
from mcp_sessions import McpSessions


class Engine:
    def __init__(self, root):
        self.root = root
        self.lock = threading.Lock()
        self.history = b''
        self.peer = None
        self.effects = 0
        self.starts = 0

    def emit(self, message):
        payload = json.dumps(message).encode() + b'\n'
        with self.lock:
            self.history += payload
            if self.peer is not None:
                try:
                    self.peer.sendall(self.frame(payload))
                except OSError:
                    pass

    @staticmethod
    def frame(payload):
        return b'\x01\0\0\0' + len(payload).to_bytes(4, 'big') + payload

    def run(self, request, event, channel):
        self.starts += 1
        return self.attach(request, event, channel)

    def attach(self, request, event, channel):
        if channel.closed:
            return {'ok': True, 'artifacts': [], 'cleanup_pending': False}
        client, peer = socket.socketpair()
        channel.attach(client)
        with self.lock:
            self.peer = peer
            if self.history:
                peer.sendall(self.frame(self.history))
        event({'type': 'sandbox_started'})

        def read():
            try:
                with peer, peer.makefile('rb') as reader:
                    for line in reader:
                        request = json.loads(line)
                        if 'id' not in request:
                            continue
                        reply = {'jsonrpc': '2.0', 'id': request['id']}
                        method = request['method']
                        if method == 'initialize':
                            reply['result'] = {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}},
                                               'serverInfo': {'name': 'retained-engine', 'version': '1'}}
                        elif method == 'tools/list':
                            reply['result'] = {'tools': [{'name': 'increment', 'inputSchema': {'type': 'object'}}]}
                        elif method == 'tools/call':
                            self.effects += 1
                            (self.root / 'effect').write_text(str(self.effects))
                            reply['result'] = {'content': [{'type': 'text', 'text': str(self.effects)}]}
                            timer = threading.Timer(3, self.emit, args=(reply,))
                            timer.daemon = True
                            timer.start()
                            continue
                        else:
                            reply['error'] = {'code': -32601, 'message': 'Method not found'}
                        self.emit(reply)
            except OSError:
                pass

        thread = threading.Thread(target=read, daemon=True)
        thread.start()
        channel._closed.wait(15)
        channel.close()
        thread.join(1)
        with self.lock:
            if self.peer is peer:
                self.peer = None
        return {'ok': True, 'artifacts': [], 'cleanup_pending': False}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        with self.server.connections_lock:
            self.server.connections.add(self.connection)

    def finish(self):
        with self.server.connections_lock:
            self.server.connections.discard(self.connection)
        super().finish()

    def log_message(self, *_):
        pass

    def handle_request(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or b'{}')
            parts = self.path.split('/')
            if self.path == '/v1/mcp':
                lease = self.server.registry.create(body)
                assert lease.ready.wait(2)
                result = {'ready': True, 'control_version': 2, 'deduplicated_sends': True}
            else:
                lease = self.server.registry.get(parts[3], self.headers['X-Xiaoqi-Lease-Token'])
                action = parts[4] if len(parts) > 4 else None
                if action == 'events':
                    result = lease.poll_events(int(self.headers['X-Xiaoqi-Event-Cursor']), timeout=0.05)
                elif action == 'messages':
                    lease.channel.send(body, sequence=int(self.headers['X-Xiaoqi-Message-Sequence']))
                    result = {'ok': True}
                elif self.command == 'DELETE':
                    lease.stop()
                    lease.done.wait(2)
                    result = {'closed': True, 'completion': lease.result}
                else:
                    raise ValueError('Unexpected fixture request')
            payload = json.dumps(result).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (OSError, ValueError):
            self.close_connection = True

    do_GET = do_POST = do_DELETE = handle_request


def main():
    root = Path(sys.argv[1])
    engine = Engine(root)

    def start(port):
        registry = McpSessions(engine.run, threading.BoundedSemaphore(1),
                               db_path=str(root / 'journal.sqlite'), recover=engine.attach)
        registry.restore()
        http = ThreadingHTTPServer(('127.0.0.1', port), Handler)
        http.daemon_threads = True
        http.registry = registry
        http.connections = set()
        http.connections_lock = threading.Lock()
        thread = threading.Thread(target=http.serve_forever, kwargs={'poll_interval': 0.02}, daemon=True)
        thread.start()
        return http

    def stop(http):
        http.shutdown()
        with http.connections_lock:
            connections = list(http.connections)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
                connection.close()
            except OSError:
                pass
        http.registry.close(detach=True)
        http.server_close()

    http = start(0)
    port = http.server_port
    print(json.dumps({'port': port}), flush=True)
    try:
        for command in sys.stdin:
            if command.strip() != 'restart':
                break
            stop(http)
            http = start(port)
            print(json.dumps({'restarted': True, 'starts': engine.starts}), flush=True)
    finally:
        stop(http)


if __name__ == '__main__':
    main()
