"""Bounded execution identities and cancellation, including queued requests."""
from __future__ import annotations

import json
import re
import threading
import time
from typing import Any


class ExecutionError(ValueError):
    pass


class Execution:
    def __init__(self, task_id: str, issued_at: int):
        self.task_id = task_id
        self.issued_at = issued_at
        self.cancelled = threading.Event()
        self.claimed = False
        self.done = False
        self.result: dict[str, Any] | None = None
        self.payload_bytes = 0


class Executions:
    def __init__(self, capacity: int = 1024):
        self._lock = threading.Lock()
        self._entries: dict[str, Execution] = {}
        self._capacity = capacity
        # Requests from an earlier runner process must not be silently replayed.
        self._started_at = int(time.time() * 1000)

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
        for key, entry in list(self._entries.items()):
            if ((entry.done and entry.result is None) or not entry.claimed) and now - entry.issued_at > 150000:
                del self._entries[key]
        if len(self._entries) >= self._capacity:
            raise ExecutionError('Execution registry capacity is exhausted')
        entry = Execution(task_id, issued_at)
        self._entries[execution_id] = entry
        return entry

    def claim(self, request: dict[str, Any]) -> Execution:
        with self._lock:
            entry = self._get(request)
            if entry.claimed:
                raise ExecutionError('Execution already submitted; do not replay an unknown result')
            # At most one ordinary sandbox can finish another <=32 MB result.
            # Retain unacknowledged files rather than evicting them for new work.
            if sum(item.payload_bytes for item in self._entries.values()) > 32 * 1024 * 1024:
                raise ExecutionError('Unacknowledged execution results exhaust capacity')
            entry.claimed = True
            return entry

    def cancel(self, request: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            entry = self._get(request)
            entry.cancelled.set()
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

    def read(self, request: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            entry = self._get(request, create=False)
            return {'ok': True, 'finished': entry.done, 'completion': entry.result}

    def acknowledge(self, request: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            entry = self._get(request, create=False)
            if not entry.done:
                raise ExecutionError('Execution is still running')
            entry.result = None
            entry.payload_bytes = 0
            return {'ok': True, 'acknowledged': True}
