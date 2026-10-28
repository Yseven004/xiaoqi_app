import json
import socket
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from unittest.mock import patch

import server
from mcp_sessions import LeaseError, McpSessions


class McpLeaseTests(unittest.TestCase):
    def setUp(self):
        self.slots = threading.BoundedSemaphore(1)
        self.requests = []

        def run(request, event, channel):
            self.requests.append(request)
            client, peer = socket.socketpair()
            channel.attach(client)
            channel.exporter = lambda: [{'name':'sample.txt','base64':'aGVsbG8='}]
            event({'type':'sandbox_started'})
            def echo():
                with peer, peer.makefile('rb') as reader:
                    for line in reader:
                        body = json.loads(line)
                        payload = json.dumps({'jsonrpc':'2.0', 'id':body['id'], 'result':{'ok':True}}).encode() + b'\n'
                        peer.sendall(b'\x01\0\0\0' + len(payload).to_bytes(4, 'big') + payload)
            thread = threading.Thread(target=echo, daemon=True)
            thread.start()
            channel._closed.wait(timeout=5)
            channel.close()
            thread.join(timeout=1)
            return {'ok':True, 'artifacts':[{'name':'sample.txt','base64':'aGVsbG8='}], 'cleanup_pending':False}

        self.registry = McpSessions(run, self.slots)
        self.addCleanup(self.registry.close)
        self.request = {'lease_id':'a'*32, 'lease_token':'b'*64, 'issued_at':int(time.time()), 'task_id':'tenant-task', 'command':['node','/workspace/skill/server.js']}

    def test_duplicate_start_is_idempotent_even_after_cancellation(self):
        lease = self.registry.create(self.request)
        self.assertTrue(lease.ready.wait(timeout=2))
        self.assertIs(self.registry.create(self.request), lease)
        lease.stop()
        self.assertTrue(lease.done.wait(timeout=2))
        self.assertIs(self.registry.create(self.request), lease)
        self.assertEqual(len(self.requests), 1)
        self.assertTrue(self.slots.acquire(blocking=False))
        self.slots.release()

    def test_lease_identity_and_credentials_cannot_be_rebound(self):
        lease = self.registry.create(self.request)
        self.assertTrue(lease.ready.wait(timeout=2))
        for change in [{'lease_token':'c'*64}, {'task_id':'another-task'}, {'command':['bash','-c','changed']}]:
            with self.assertRaises(LeaseError):
                self.registry.create({**self.request, **change})
        with self.assertRaises(LeaseError):
            self.registry.get('a'*32, 'wrong-token')
        with self.assertRaises(LeaseError):
            self.registry.create({**self.request, 'lease_id':'d'*32})

    def test_event_response_replays_until_ack_without_resending_tool(self):
        lease = self.registry.create(self.request)
        self.assertTrue(lease.ready.wait(timeout=2))
        message = {'jsonrpc':'2.0', 'id':1, 'result':{'ok':True}}
        lease.channel._messages.put_nowait(message)
        first = lease.poll_events(0, timeout=0)
        self.assertEqual(first['cursor'], 1)
        self.assertEqual(first['messages'], [message])
        self.assertGreater(lease.payload_bytes, 0)
        self.assertEqual(lease.poll_events(0, timeout=0), first)
        self.assertEqual(lease.poll_events(1, timeout=0)['messages'], [])
        self.assertEqual(lease.payload_bytes, 0)
        for cursor in (0, -1, 2, True, '1'):
            with self.assertRaises(LeaseError):
                lease.poll_events(cursor, timeout=0)
        second = {'jsonrpc':'2.0', 'id':2, 'result':{}}
        lease.channel._messages.put_nowait(second)
        self.assertEqual(lease.poll_events(1, timeout=0)['messages'], [second])
        self.assertEqual(lease.poll_events(1, timeout=0)['cursor'], 2)
        self.assertEqual(len(self.requests), 1)

    def test_real_http_control_authentication_protocol_and_cleanup(self):
        clock = self.use_fake_clock()
        with patch.object(server, '_mcp_sessions', self.registry), patch.object(server, 'RUNNER_TOKEN', 'r'*40):
            http = ThreadingHTTPServer(('127.0.0.1', 0), server.RunnerHandler)
            serving = threading.Thread(target=http.serve_forever, daemon=True)
            serving.start()
            def request(method, path, body=None, token='b'*64, runner='r'*40):
                req = urllib.request.Request(f'http://127.0.0.1:{http.server_port}'+path,
                    method=method, data=json.dumps(body).encode() if body is not None else None,
                    headers={'Authorization':'Bearer '+runner, 'X-Xiaoqi-Lease-Token':token, 'X-Xiaoqi-Event-Cursor':'0', 'Content-Type':'application/json'})
                with urllib.request.urlopen(req, timeout=3) as response:
                    return json.load(response)
            try:
                with self.assertRaises(urllib.error.HTTPError) as error:
                    request('POST','/v1/mcp',self.request,runner='wrong')
                self.assertEqual(error.exception.code,401)
                error.exception.close()
                self.assertEqual(self.requests,[])
                self.assertTrue(request('POST','/v1/mcp',self.request)['ready'])
                clock[0] = 50
                with self.assertRaises(urllib.error.HTTPError) as error:
                    request('POST','/v1/mcp/'+'a'*32+'/messages',{'jsonrpc':'2.0','id':1,'method':'tools/list'},token='c'*64)
                error.exception.close()
                self.assertEqual(self.registry.get('a'*32, 'b'*64).last_activity, 0)
                clock[0] = 60
                request('POST','/v1/mcp/'+'a'*32+'/messages',{'jsonrpc':'2.0','id':1,'method':'tools/list'})
                self.assertEqual(self.registry.get('a'*32, 'b'*64).last_activity, 60)
                clock[0] = 90
                events = request('GET','/v1/mcp/'+'a'*32+'/events')
                self.assertEqual(self.registry.get('a'*32, 'b'*64).last_activity, 90)
                self.assertEqual(events['messages'],[{'jsonrpc':'2.0','id':1,'result':{'ok':True}}])
                self.assertEqual(request('GET','/v1/mcp/'+'a'*32+'/events'), events)
                clock[0] = 100
                self.assertEqual(request('GET','/v1/mcp/'+'a'*32+'/artifacts')['artifacts'],[{'name':'sample.txt','base64':'aGVsbG8='}])
                self.assertEqual(self.registry.get('a'*32, 'b'*64).last_activity, 100)
                closed = request('DELETE','/v1/mcp/'+'a'*32)
                self.assertTrue(closed['closed'])
                self.assertFalse(closed['cleanup_pending'])
                repeated = request('DELETE','/v1/mcp/'+'a'*32)
                self.assertEqual(closed['completion']['artifacts'], repeated['completion']['artifacts'])
                self.assertTrue(request('POST','/v1/mcp/'+'a'*32+'/ack',{})['acknowledged'])
                self.assertNotIn('artifacts', self.registry.get('a'*32, 'b'*64).result)
                self.assertTrue(self.slots.acquire(blocking=False))
                self.slots.release()
            finally:
                http.shutdown()
                http.server_close()
                serving.join(timeout=2)

    def test_expired_startup_cannot_be_replayed_after_tombstone_removal(self):
        with self.assertRaises(LeaseError):
            self.registry.create({**self.request, 'issued_at':int(time.time()) - 180})
        self.assertEqual(self.requests, [])

    def test_lease_expiry_stops_idle_process_and_releases_capacity(self):
        self.registry._lifetime = 0.01
        lease = self.registry.create(self.request)
        self.assertTrue(lease.ready.wait(timeout=2))
        self.assertTrue(lease.done.wait(timeout=3))
        self.assertTrue(self.slots.acquire(blocking=False))
        self.slots.release()

    def use_fake_clock(self):
        elapsed = [0.0]
        wall = time.time()
        self.registry._clock = lambda: elapsed[0]
        self.registry._wall_clock = lambda: wall + elapsed[0]
        return elapsed

    def test_active_event_polling_survives_original_creation_deadline(self):
        clock = self.use_fake_clock()
        lease = self.registry.create(self.request)
        self.assertTrue(lease.ready.wait(timeout=2))
        for seconds in (60, 120, 180, 240):
            clock[0] = seconds
            self.assertEqual(lease.poll_events(0, timeout=0)['messages'], [])
            self.registry._sweep_once()
            self.assertFalse(lease.channel.closed)
        self.assertEqual(len(self.requests), 1)

    def test_missing_heartbeat_expires_from_last_valid_activity(self):
        clock = self.use_fake_clock()
        lease = self.registry.create(self.request)
        self.assertTrue(lease.ready.wait(timeout=2))
        clock[0] = 100
        lease.poll_events(0, timeout=0)
        clock[0] = 219
        with self.assertRaises(LeaseError):
            self.registry.get('a'*32, 'wrong-token')
        with self.assertRaises(LeaseError):
            lease.poll_events(99, timeout=0)
        self.registry._sweep_once()
        self.assertFalse(lease.channel.closed)
        clock[0] = 220
        self.registry._sweep_once()
        self.assertTrue(lease.done.wait(timeout=2))
        self.assertEqual(lease.channel.error, 'MCP lease heartbeat expired')
        self.assertTrue(self.slots.acquire(blocking=False))
        self.slots.release()

    def test_heartbeats_do_not_extend_absolute_session_budget(self):
        clock = self.use_fake_clock()
        self.registry._max_lifetime = 300
        lease = self.registry.create(self.request)
        self.assertTrue(lease.ready.wait(timeout=2))
        for seconds in (60, 120, 180, 240):
            clock[0] = seconds
            lease.poll_events(0, timeout=0)
            self.registry._sweep_once()
            self.assertFalse(lease.channel.closed)
        clock[0] = 300
        lease.poll_events(0, timeout=0)
        self.registry._sweep_once()
        self.assertTrue(lease.done.wait(timeout=2))
        self.assertEqual(lease.channel.error, 'MCP session time budget exhausted')

    def test_long_session_retention_starts_at_completion(self):
        clock = self.use_fake_clock()
        lease = self.registry.create(self.request)
        self.assertTrue(lease.ready.wait(timeout=2))
        clock[0] = 1000
        lease.heartbeat()
        lease.stop()
        self.assertTrue(lease.done.wait(timeout=2))
        clock[0] = 1119
        self.registry._sweep_once()
        self.assertIs(self.registry.get('a'*32, 'b'*64), lease)
        self.assertEqual(lease.result['artifacts'][0]['name'], 'sample.txt')
        clock[0] = 1120
        self.registry._sweep_once()
        with self.assertRaises(LeaseError):
            self.registry.get('a'*32, 'b'*64)

    def test_retention_never_prunes_a_still_valid_startup_replay_guard(self):
        clock = self.use_fake_clock()
        issued = int(self.registry._wall_clock()) + 30
        request = {**self.request, 'issued_at': issued}
        lease = self.registry.create(request)
        self.assertTrue(lease.ready.wait(timeout=2))
        lease.stop()
        self.assertTrue(lease.done.wait(timeout=2))
        clock[0] = 120
        self.registry._sweep_once()
        self.assertIs(self.registry.get('a'*32, 'b'*64), lease)
        clock[0] = 151
        self.registry._sweep_once()
        with self.assertRaises(LeaseError):
            self.registry.create(request)
        self.assertEqual(len(self.requests), 1)
