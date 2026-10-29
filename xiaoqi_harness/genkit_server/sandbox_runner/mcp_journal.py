"""Private durable lease/message state, separate from plugin workspaces.

Only hashes of startup requests and lease tokens are retained. JSON-RPC messages
are private task data; acknowledged messages are deleted. A recorded send is
never resent merely because the HTTP response or the runner process was lost.
"""
from __future__ import annotations

import hashlib
import json
import math
import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any


class McpJournalError(RuntimeError):
    pass


class McpJournal:
    MAX_BYTES = 64 * 1024 * 1024
    MAX_MESSAGES = 32
    MAX_MESSAGE_BYTES = 2 * 1024 * 1024
    MAX_SENDS = 4096
    FIELDS = frozenset({
        'task_id', 'token_hash', 'fingerprint', 'issued_at', 'created_wall',
        'last_activity_wall', 'finished_wall', 'phase', 'resources', 'stopped',
        'closed', 'error', 'result', 'cursor', 'batch', 'frame_sequence',
        'stdout_offset', 'stdout_hash', 'send_sequence', 'workspace_prepared',
    })

    def __init__(self, path: str | None = None):
        self._lock = threading.RLock()
        self.changed = threading.Condition(self._lock)
        if path is not None:
            Path(path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._db = sqlite3.connect(path or ':memory:', check_same_thread=False)
        if path is not None:
            Path(path).chmod(0o600)
        self._db.execute('PRAGMA auto_vacuum=FULL')
        self._db.execute('PRAGMA journal_mode=WAL')
        self._db.execute('PRAGMA synchronous=FULL')
        self._db.execute('PRAGMA secure_delete=ON')
        self._db.execute('PRAGMA foreign_keys=ON')
        if self._db.execute('PRAGMA user_version').fetchone()[0] not in (0, 1):
            raise McpJournalError('Unsupported MCP journal version')
        self._db.executescript('''
CREATE TABLE IF NOT EXISTS leases (id TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS frames (
 lease TEXT NOT NULL REFERENCES leases(id) ON DELETE CASCADE,
 sequence INTEGER NOT NULL, payload TEXT NOT NULL, bytes INTEGER NOT NULL,
 PRIMARY KEY(lease,sequence));
CREATE TABLE IF NOT EXISTS sends (
 lease TEXT NOT NULL REFERENCES leases(id) ON DELETE CASCADE,
 sequence INTEGER NOT NULL, digest TEXT NOT NULL, request_id TEXT,
 PRIMARY KEY(lease,sequence));
PRAGMA user_version=1;
''')
        if self._db.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
            raise McpJournalError('MCP journal integrity check failed')
        self._check_capacity()

    @staticmethod
    def _json(value: Any) -> str:
        return json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=True, allow_nan=False)

    @staticmethod
    def _id(lease_id: str):
        if not isinstance(lease_id, str) or not re.fullmatch(r'[a-f0-9]{32}', lease_id):
            raise McpJournalError('Invalid MCP lease identity')

    def _read(self, lease_id: str) -> dict[str, Any]:
        self._id(lease_id)
        row = self._db.execute('SELECT value FROM leases WHERE id=?', (lease_id,)).fetchone()
        if row is None:
            raise McpJournalError('MCP journal lease not found')
        return self._validate(json.loads(row[0]))

    def _validate(self, value: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(value, dict) or set(value) - self.FIELDS:
            raise McpJournalError('Invalid MCP journal metadata')
        if (value.get('phase') not in {'prepared', 'active', 'finishing', 'finished'} or
                not isinstance(value.get('task_id'), str) or
                not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', value['task_id']) or
                any(not isinstance(value.get(key), str) or not re.fullmatch(r'[a-f0-9]{64}', value[key])
                    for key in ('token_hash', 'fingerprint', 'stdout_hash')) or
                any(type(value.get(key)) is not int or value[key] < 0 for key in
                    ('issued_at', 'cursor', 'frame_sequence', 'stdout_offset', 'send_sequence')) or
                any(type(value.get(key)) not in (int, float) or not math.isfinite(value[key]) for key in
                    ('created_wall', 'last_activity_wall')) or not isinstance(value.get('resources'), dict)):
            raise McpJournalError('Invalid MCP journal binding')
        resources = value['resources']
        if set(resources) - {'container', 'proxy', 'network', 'volume', 'recovery'} or any(
                resource is not None and (not isinstance(resource, str) or
                not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,254}', resource))
                for resource in resources.values()):
            raise McpJournalError('Invalid MCP resource identity')
        return value

    def _write(self, lease_id: str, value: dict[str, Any]):
        self._validate(value)
        self._db.execute('UPDATE leases SET value=? WHERE id=?', (self._json(value), lease_id))

    def _check_capacity(self):
        count, meta = self._db.execute('SELECT COUNT(*),COALESCE(SUM(LENGTH(CAST(value AS BLOB))),0) FROM leases').fetchone()
        frames = self._db.execute('SELECT COALESCE(SUM(bytes),0) FROM frames').fetchone()[0]
        sends = self._db.execute('SELECT COUNT(*) FROM sends').fetchone()[0] * 128
        if count > 1024 or meta + frames + sends > self.MAX_BYTES:
            raise McpJournalError('MCP journal capacity is exhausted')

    def create(self, lease_id: str, *, task_id: str, token_hash: str,
               fingerprint: str, issued_at: int, now: float):
        self._id(lease_id)
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', task_id):
            raise McpJournalError('Invalid task identity')
        if any(not isinstance(v, str) or not re.fullmatch(r'[a-f0-9]{64}', v) for v in (token_hash, fingerprint)):
            raise McpJournalError('Invalid MCP binding')
        value = dict(task_id=task_id, token_hash=token_hash, fingerprint=fingerprint,
                     issued_at=issued_at, created_wall=now, last_activity_wall=now,
                     phase='prepared', resources={}, closed=False, stopped=False,
                     cursor=0, batch=None, frame_sequence=0, stdout_offset=0,
                     stdout_hash=hashlib.sha256(b'').hexdigest(), send_sequence=0)
        self._validate(value)
        with self.changed, self._db:
            self._db.execute('INSERT INTO leases VALUES (?,?)', (lease_id, self._json(value)))
            self._check_capacity()

    def get(self, lease_id: str) -> dict[str, Any]:
        with self._lock:
            return self._read(lease_id)

    def payload_bytes(self, lease_id: str) -> int:
        with self._lock:
            meta = self._db.execute('SELECT LENGTH(CAST(value AS BLOB)) FROM leases WHERE id=?', (lease_id,)).fetchone()
            frames = self._db.execute('SELECT COALESCE(SUM(bytes),0) FROM frames WHERE lease=?', (lease_id,)).fetchone()[0]
            return (meta[0] if meta else 0) + frames

    def all(self) -> list[tuple[str, dict[str, Any]]]:
        with self._lock:
            return [(key, self._read(key)) for (key,) in self._db.execute('SELECT id FROM leases').fetchall()]

    def patch(self, lease_id: str, **fields):
        with self.changed, self._db:
            original = self._read(lease_id)
            if any(key in fields and fields[key] != original[key] for key in
                   ('task_id', 'token_hash', 'fingerprint', 'issued_at', 'created_wall')):
                raise McpJournalError('Original MCP lease binding is immutable')
            self._write(lease_id, {**original, **fields})
            self._read(lease_id)
            self._check_capacity()
            self.changed.notify_all()

    def claim_send(self, lease_id: str, sequence: int, message: dict[str, Any]) -> bool:
        if type(sequence) is not int or not 1 <= sequence <= self.MAX_SENDS:
            raise McpJournalError('Invalid MCP send sequence')
        payload = self._json(message).encode('utf-8')
        if len(payload) > self.MAX_MESSAGE_BYTES:
            raise McpJournalError('MCP message exceeds transport byte budget')
        digest = hashlib.sha256(payload).hexdigest()
        request_id = self._json(message['id']) if 'method' in message and 'id' in message else None
        with self.changed, self._db:
            state = self._read(lease_id)
            prior = self._db.execute('SELECT digest FROM sends WHERE lease=? AND sequence=?', (lease_id, sequence)).fetchone()
            if prior is not None:
                if prior[0] != digest:
                    raise McpJournalError('Original MCP send arguments changed')
                return False
            if state.get('closed') or state.get('stopped') or state.get('phase') == 'finished':
                raise McpJournalError('MCP process is closed')
            if sequence != state['send_sequence'] + 1:
                raise McpJournalError('MCP send sequence has a gap')
            prior_request = None if request_id is None else self._db.execute(
                'SELECT digest FROM sends WHERE lease=? AND request_id=?', (lease_id, request_id)).fetchone()
            if prior_request is not None and prior_request[0] != digest:
                raise McpJournalError('Original JSON-RPC request arguments changed')
            self._db.execute('INSERT INTO sends VALUES (?,?,?,?)', (lease_id, sequence, digest, request_id if prior_request is None else None))
            self._write(lease_id, {**state, 'send_sequence': sequence})
            self._check_capacity()
            return prior_request is None

    def receive(self, lease_id: str, message: dict[str, Any], offset: int, prefix_hash: str):
        payload = self._json(message)
        size = len(payload.encode('utf-8'))
        if size > self.MAX_MESSAGE_BYTES:
            raise McpJournalError('MCP message exceeds transport byte budget')
        with self.changed, self._db:
            state = self._read(lease_id)
            count, total = self._db.execute('SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM frames WHERE lease=?', (lease_id,)).fetchone()
            if count >= self.MAX_MESSAGES or total + size > 17 * self.MAX_MESSAGE_BYTES:
                raise McpJournalError('MCP pending response budget exhausted')
            if type(offset) is not int or offset <= state['stdout_offset'] or not re.fullmatch(r'[a-f0-9]{64}', prefix_hash):
                raise McpJournalError('Invalid MCP stdout checkpoint')
            sequence = state['frame_sequence'] + 1
            self._db.execute('INSERT INTO frames VALUES (?,?,?,?)', (lease_id, sequence, payload, size))
            self._write(lease_id, {**state, 'frame_sequence': sequence, 'stdout_offset': offset, 'stdout_hash': prefix_hash})
            self._check_capacity()
            self.changed.notify_all()

    def poll(self, lease_id: str, cursor: int, timeout: float = 15) -> dict[str, Any]:
        if type(cursor) is not int or cursor < 0:
            raise McpJournalError('Invalid event cursor')
        deadline = time.monotonic() + timeout
        with self.changed:
            while True:
                with self._db:
                    state = self._read(lease_id)
                    batch = state.get('batch')
                    if batch is not None and cursor == state['cursor'] - 1:
                        rows = self._db.execute('SELECT payload FROM frames WHERE lease=? AND sequence>? AND sequence<=? ORDER BY sequence',
                                                (lease_id, batch['after'], batch['through'])).fetchall()
                        return {**batch['status'], 'cursor': state['cursor'], 'messages': [json.loads(row[0]) for row in rows]}
                    if cursor != state['cursor']:
                        raise McpJournalError('Invalid event cursor')
                    if batch is not None:
                        self._db.execute('DELETE FROM frames WHERE lease=? AND sequence<=?', (lease_id, batch['through']))
                        state['batch'] = None
                    rows = self._db.execute('SELECT sequence,payload,bytes FROM frames WHERE lease=? ORDER BY sequence LIMIT 32', (lease_id,)).fetchall()
                    selected, size = [], 0
                    for row in rows:
                        if selected and size + row[2] > self.MAX_MESSAGE_BYTES:
                            break
                        selected.append(row)
                        size += row[2]
                    status = {'closed': bool(state.get('closed')), **({'error': state['error']} if state.get('error') else {})}
                    if selected or status['closed'] or status.get('error'):
                        state['cursor'] += 1
                        state['batch'] = {'after': selected[0][0] - 1 if selected else state['frame_sequence'],
                                          'through': selected[-1][0] if selected else state['frame_sequence'], 'status': status}
                        self._write(lease_id, state)
                        return {**status, 'cursor': state['cursor'], 'messages': [json.loads(row[1]) for row in selected]}
                    self._write(lease_id, state)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return {'messages': [], 'closed': False, 'cursor': cursor}
                self.changed.wait(remaining)

    def discard(self, lease_id: str):
        with self.changed, self._db:
            state = self._read(lease_id)
            if state.get('phase') != 'finished':
                raise McpJournalError('MCP result is not ready to acknowledge')
            result = {key: value for key, value in (state.get('result') or {}).items()
                      if key in {'ok', 'error', 'cleanup_pending', 'sandbox_id'}}
            self._db.execute('DELETE FROM frames WHERE lease=?', (lease_id,))
            self._db.execute('DELETE FROM sends WHERE lease=?', (lease_id,))
            self._write(lease_id, {**state, 'batch': None, 'result': result})
            self.changed.notify_all()

    def delete(self, lease_id: str):
        self._id(lease_id)
        with self.changed, self._db:
            self._db.execute('DELETE FROM leases WHERE id=?', (lease_id,))

    def close(self):
        with self._lock:
            self._db.close()
