import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from mcp_journal import McpJournal, McpJournalError


class McpJournalTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.path = str(Path(self.root.name) / 'mcp.sqlite')
        self.journal = McpJournal(self.path)
        self.lease = 'a' * 32
        self.journal.create(self.lease, task_id='tenant-task', token_hash='b' * 64,
                            fingerprint='c' * 64, issued_at=int(time.time()), now=time.time())
        self.wire = b''

    def tearDown(self):
        self.journal.close()
        self.root.cleanup()

    def reopen(self):
        self.journal.close()
        self.journal = McpJournal(self.path)

    def receive(self, message):
        self.wire += json.dumps(message, ensure_ascii=False).encode('utf-8') + b'\n'
        self.journal.receive(self.lease, message, len(self.wire), hashlib.sha256(self.wire).hexdigest())

    def test_lost_poll_response_and_ack_survive_database_reopen(self):
        response = {'jsonrpc': '2.0', 'id': 1, 'result': {'text': '中文🙂'}}
        notice = {'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'}
        self.receive(response)
        self.receive(notice)
        batch = self.journal.poll(self.lease, 0, timeout=0)
        self.assertEqual(batch['messages'], [response, notice])
        self.assertEqual(batch['cursor'], 1)
        self.reopen()
        self.assertEqual(self.journal.poll(self.lease, 0, timeout=0), batch)
        self.assertEqual(self.journal.poll(self.lease, 1, timeout=0), {'messages': [], 'closed': False, 'cursor': 1})
        self.reopen()
        self.assertEqual(self.journal.poll(self.lease, 1, timeout=0)['messages'], [])
        self.assertEqual(self.journal.get(self.lease)['stdout_offset'], len(self.wire))
        self.assertEqual(self.journal.get(self.lease)['stdout_hash'], hashlib.sha256(self.wire).hexdigest())

    def test_sends_cannot_replay_on_response_loss_or_another_sequence(self):
        message = {'jsonrpc': '2.0', 'id': 'send-1', 'method': 'tools/call', 'params': {'tool': 'send'}}
        self.assertTrue(self.journal.claim_send(self.lease, 1, message))
        self.reopen()
        self.assertFalse(self.journal.claim_send(self.lease, 1, dict(reversed(list(message.items())))))
        self.assertFalse(self.journal.claim_send(self.lease, 2, message))
        self.assertEqual(self.journal.get(self.lease)['send_sequence'], 2)
        with self.assertRaises(McpJournalError):
            self.journal.claim_send(self.lease, 3, {**message, 'params': {'tool': 'delete'}})
        self.assertEqual(self.journal.get(self.lease)['send_sequence'], 2)
        self.assertTrue(self.journal.claim_send(self.lease, 3, {**message, 'id': 'send-2'}))
        with self.assertRaises(McpJournalError):
            self.journal.claim_send(self.lease, 5, {**message, 'id': 'send-3'})

    def test_server_response_id_and_client_request_id_are_separate_namespaces(self):
        request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}
        self.assertTrue(self.journal.claim_send(self.lease, 1, request))
        self.assertTrue(self.journal.claim_send(self.lease, 2, {'jsonrpc': '2.0', 'id': 1, 'result': {'roots': []}}))
        # Notifications can repeat legitimately; their send sequence is identity.
        notification = {'jsonrpc': '2.0', 'method': 'notifications/initialized'}
        self.assertTrue(self.journal.claim_send(self.lease, 3, notification))
        self.assertTrue(self.journal.claim_send(self.lease, 4, notification))

    def test_crashed_sender_reservation_is_not_submitted_again(self):
        code = '''
import sys
from mcp_journal import McpJournal
j=McpJournal(sys.argv[1])
assert j.claim_send('a'*32, 1, {'jsonrpc':'2.0','id':1,'method':'tools/call'})
print('CLAIMED',flush=True)
sys.stdin.read(1)
'''
        child = subprocess.Popen([sys.executable, '-B', '-c', code, self.path],
                                 cwd=Path(__file__).resolve().parents[1],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        try:
            self.assertEqual(child.stdout.readline().strip(), b'CLAIMED')
            child.kill()
            child.wait(timeout=10)
            self.reopen()
            self.assertFalse(self.journal.claim_send(self.lease, 1, {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call'}))
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
            child.stdin.close()
            child.stdout.close()
            child.stderr.close()

    def test_invalid_cursor_and_exhausted_frame_budget_preserve_original_checkpoint(self):
        self.receive({'jsonrpc': '2.0', 'id': 1, 'result': {}})
        before = self.journal.get(self.lease)
        with self.assertRaises(McpJournalError):
            self.journal.poll(self.lease, 4, timeout=0)
        self.assertEqual(self.journal.get(self.lease), before)
        with patch.object(McpJournal, 'MAX_MESSAGES', 1), self.assertRaises(McpJournalError):
            self.receive({'jsonrpc': '2.0', 'id': 2, 'result': {}})
        self.assertEqual(self.journal.get(self.lease), before)
        self.assertEqual(len(self.journal.poll(self.lease, 0, timeout=0)['messages']), 1)

    def test_finished_result_retained_until_ack_then_only_private_tombstone_remains(self):
        self.receive({'jsonrpc': '2.0', 'id': 1, 'result': {}})
        with self.assertRaises(McpJournalError):
            self.journal.discard(self.lease)
        result = {'ok': True, 'artifacts': [{'name': 'result.txt', 'base64': 'aGVsbG8='}], 'cleanup_pending': False}
        self.journal.patch(self.lease, phase='finished', result=result, closed=True)
        self.reopen()
        self.assertEqual(self.journal.get(self.lease)['result'], result)
        self.journal.discard(self.lease)
        self.assertNotIn('artifacts', self.journal.get(self.lease)['result'])
        self.assertEqual(self.journal.poll(self.lease, 0, timeout=0)['messages'], [])
        with self.assertRaises(McpJournalError):
            self.journal.claim_send(self.lease, 1, {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call'})

    def test_raw_startup_environment_and_token_cannot_enter_metadata(self):
        with self.assertRaises(McpJournalError):
            self.journal.patch(self.lease, environment={'API_KEY': 'must-not-persist'})
        with self.assertRaises(McpJournalError):
            self.journal.patch(self.lease, lease_token='raw-token-must-not-persist')
        with self.assertRaises(McpJournalError):
            self.journal.patch(self.lease, resources={'environment': {'API_KEY': 'must-not-persist'}})
        with self.assertRaises(McpJournalError):
            self.journal.patch(self.lease, token_hash='d' * 64)
        with self.assertRaises(McpJournalError):
            self.journal.patch(self.lease, task_id='other-task')
        self.reopen()
        self.assertEqual(self.journal.get(self.lease)['token_hash'], 'b' * 64)
        for path in Path(self.root.name).iterdir():
            self.assertNotIn(b'must-not-persist', path.read_bytes())


if __name__ == '__main__':
    unittest.main()
