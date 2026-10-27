"""Bounded execution identities and cancellation, including queued requests."""
from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any


class ExecutionError(ValueError):
    pass


class StorageUnavailable(RuntimeError):
    pass


class Execution:
    def __init__(self, task_id: str, issued_at: int, execution_id: str = ''):
        self.execution_id = execution_id
        self.task_id = task_id
        self.issued_at = issued_at
        self.cancelled = threading.Event()
        self.claimed = False
        self.done = False
        self.result: dict[str, Any] | None = None
        self.payload_bytes = 0


class Executions:
    def __init__(self, capacity: int = 1024, db_path: str | None = None):
        self._lock = threading.Lock()
        self._entries: dict[str, Execution] = {}
        self._capacity = capacity
        # Requests from an earlier runner process must not be silently replayed.
        self._started_at = int(time.time() * 1000)
        self._db = None
        self._storage_failed = False
        if db_path is not None:
            try:
                self._open_journal(db_path)
            except Exception:
                self.close()
                raise

    def _open_journal(self, db_path: str):
        Path(db_path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        Path(db_path).chmod(0o600)
        self._db.execute('PRAGMA auto_vacuum=FULL')
        self._db.execute('PRAGMA journal_mode=WAL')
        self._db.execute('PRAGMA synchronous=FULL')
        self._db.execute('PRAGMA secure_delete=ON')
        if self._db.execute('PRAGMA user_version').fetchone()[0] not in (0, 1):
            raise ExecutionError('Unsupported execution journal version')
        self._db.execute('CREATE TABLE IF NOT EXISTS executions (id TEXT PRIMARY KEY, value TEXT NOT NULL)')
        self._db.execute('PRAGMA user_version=1')
        self._db.commit()
        if self._db.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
            raise ExecutionError('Execution journal integrity check failed')
        count, total_bytes = self._db.execute('SELECT COUNT(*), COALESCE(SUM(LENGTH(value)), 0) FROM executions').fetchone()
        if count > self._capacity or total_bytes > 65 * 1024 * 1024:
            raise ExecutionError('Execution journal exceeds storage capacity')
        rows = self._db.execute('SELECT id, value FROM executions LIMIT ?', (self._capacity + 1,)).fetchall()
        if len(rows) > self._capacity:
            raise ExecutionError('Execution journal exceeds entry capacity')
        for identifier, encoded in rows:
            if not re.fullmatch(r'[a-f0-9]{32}', identifier) or len(encoded) > 33 * 1024 * 1024:
                raise ExecutionError('Invalid execution journal entry')
            value = json.loads(encoded)
            if (not isinstance(value, dict) or not isinstance(value.get('task_id'), str)
                    or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', value['task_id'])
                    or type(value.get('issued_at')) is not int
                    or any(type(value.get(key)) is not bool for key in ('claimed', 'done', 'cancelled'))
                    or (value.get('result') is not None and not isinstance(value['result'], dict))):
                raise ExecutionError('Invalid execution journal metadata')
            entry = Execution(value['task_id'], value['issued_at'], identifier)
            entry.claimed, entry.done = value['claimed'], value['done']
            if value['cancelled']:
                entry.cancelled.set()
            entry.result = value['result']
            entry.payload_bytes = len(json.dumps(entry.result, ensure_ascii=False).encode()) if entry.result is not None else 0
            self._entries[identifier] = entry
        if sum(item.payload_bytes for item in self._entries.values()) > 64 * 1024 * 1024:
            raise ExecutionError('Execution journal exceeds result capacity')

    def _persist(self, entry: Execution):
        if self._db is None:
            return
        encoded = json.dumps({'task_id': entry.task_id, 'issued_at': entry.issued_at, 'claimed': entry.claimed, 'done': entry.done, 'cancelled': entry.cancelled.is_set(), 'result': entry.result}, ensure_ascii=False)
        try:
            with self._db:
                self._db.execute('INSERT OR REPLACE INTO executions(id, value) VALUES (?, ?)', (entry.execution_id, encoded))
            self._storage_failed = False
        except sqlite3.Error as error:
            self._storage_failed = True
            raise StorageUnavailable('Execution journal cannot store state') from error

    @property
    def healthy(self) -> bool:
        with self._lock:
            return not self._storage_failed

    def interrupted(self) -> list[Execution]:
        # Called before the HTTP listener starts; no new work can race recovery.
        with self._lock:
            return [entry for entry in self._entries.values() if not entry.done]

    def pending_cleanup(self) -> list[Execution]:
        with self._lock:
            return [entry for entry in self._entries.values() if entry.done and entry.result is not None and entry.result.get('cleanup_pending')]

    def cleaned(self, entry: Execution):
        with self._lock:
            if entry.result is not None:
                entry.result = None if entry.result.get('acknowledged') else {**entry.result, 'cleanup_pending': False, 'sandbox_id': None}
                entry.payload_bytes = len(json.dumps(entry.result, ensure_ascii=False).encode()) if entry.result is not None else 0
                self._persist(entry)

    def checkpoint(self, entry: Execution, result: dict[str, Any]):
        with self._lock:
            entry.result = result
            entry.payload_bytes = len(json.dumps(result, ensure_ascii=False).encode())
            self._persist(entry)

    def close(self):
        with self._lock:
            if self._db is not None:
                self._db.close()
                self._db = None

    def _get(self, request: dict[str, Any], *, create: bool = True) -> Execution:
        execution_id = request.get('execution_id')
        task_id = request.get('task_id')
        issued_at = request.get('issued_at')
        if not isinstance(execution_id, str) or not re.fullmatch(r'[a-f0-9]{32}', execution_id):
            raise ExecutionError('Invalid execution ID')
        if not isinstance(task_id, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', task_id):
            raise ExecutionError('Invalid task ID')
        if type(issued_at) is not int:
            raise ExecutionError('Invalid execution timestamp')
        existing = self._entries.get(execution_id)
        if existing is not None:
            if existing.task_id != task_id or existing.issued_at != issued_at:
                raise ExecutionError('Execution belongs to another request')
            return existing
        if not create:
            raise ExecutionError('Execution result is unavailable; do not replay it')
        now = time.time() * 1000
        if issued_at < self._started_at or not -30000 <= now - issued_at <= 120000:
            raise ExecutionError('Execution request has expired; do not replay an unknown result')
        # Finished/cancel-before-start tombstones outlive the startup acceptance
        # window. Pruning cannot make the old request eligible to execute again.
        expired = [key for key, entry in self._entries.items()
                   if ((entry.done and entry.result is None) or not entry.claimed) and now - entry.issued_at > 150000]
        if self._db is not None and expired:
            try:
                with self._db:
                    self._db.executemany('DELETE FROM executions WHERE id=?', [(key,) for key in expired])
            except sqlite3.Error as error:
                self._storage_failed = True
                raise StorageUnavailable('Execution journal cannot prune expired entries') from error
        for key in expired:
            del self._entries[key]
        if len(self._entries) >= self._capacity:
            raise ExecutionError('Execution registry capacity is exhausted')
        entry = Execution(task_id, issued_at, execution_id)
        self._entries[execution_id] = entry
        self._persist(entry)
        return entry

    def claim(self, request: dict[str, Any]) -> Execution:
        with self._lock:
            if self._storage_failed:
                raise StorageUnavailable('Execution journal is unavailable; no new execution started')
            entry = self._get(request)
            if entry.claimed:
                raise ExecutionError('Execution already submitted; do not replay an unknown result')
            # At most one ordinary sandbox can finish another <=32 MB result.
            # Retain unacknowledged files rather than evicting them for new work.
            if sum(item.payload_bytes for item in self._entries.values()) > 32 * 1024 * 1024:
                raise ExecutionError('Unacknowledged execution results exhaust capacity')
            entry.claimed = True
            self._persist(entry)
            return entry

    def cancel(self, request: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            entry = self._get(request)
            entry.cancelled.set()
            self._persist(entry)
            return {'ok': True, 'cancel_requested': True, 'finished': entry.done}

    def finish(self, entry: Execution, result: dict[str, Any] | None = None) -> None:
        with self._lock:
            if entry.done:
                return
            if result is not None:
                size = len(json.dumps(result, ensure_ascii=False).encode())
                if size > 32 * 1024 * 1024:
                    result = {'type': 'result', 'ok': False, 'error': 'Execution result exceeds capacity', 'artifacts': [], 'cleanup_pending': result.get('cleanup_pending', True), 'sandbox_id': result.get('sandbox_id')}
                    size = len(json.dumps(result).encode())
                entry.result = result
                entry.payload_bytes = size
            entry.done = True
            # Interrupted/cancel-before-start entries must never become fresh
            # executions after journal recovery.
            entry.claimed = True
            self._persist(entry)

    def read(self, request: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            entry = self._get(request, create=False)
            return {'ok': True, 'finished': entry.done, 'completion': entry.result, 'cleanup_pending': bool(entry.result and entry.result.get('cleanup_pending'))}

    def acknowledge(self, request: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            entry = self._get(request, create=False)
            if not entry.done:
                raise ExecutionError('Execution is still running')
            previous, previous_size = entry.result, entry.payload_bytes
            pending_cleanup = bool(entry.result and entry.result.get('cleanup_pending'))
            entry.result = {'type': 'result', 'execution_id': entry.execution_id, 'cleanup_pending': True, 'sandbox_id': entry.result.get('sandbox_id'), 'acknowledged': True, 'artifacts': []} if pending_cleanup else None
            entry.payload_bytes = len(json.dumps(entry.result).encode()) if entry.result is not None else 0
            try:
                self._persist(entry)
            except Exception:
                entry.result, entry.payload_bytes = previous, previous_size
                raise
            if self._db is not None:
                try:
                    self._db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
                except sqlite3.Error as error:
                    self._storage_failed = True
                    raise StorageUnavailable('Execution journal cannot release its write-ahead log') from error
            return {'ok': True, 'acknowledged': True, 'cleanup_pending': pending_cleanup}
